<#
.SYNOPSIS
    TranscribeIt progress window - native Windows taskbar progress, ETA and completion flash.

.DESCRIPTION
    Track E of TranscribeIt. Consumes the FROZEN progress contract described in
    contracts\CONTRACTS.md / contracts\progress.schema.json (JSON Lines, one compact
    object per line) and drives:

      * TaskbarItemInfo.ProgressValue  - the real native green taskbar fill
                                         (bound straight to overallPercent / 100)
      * TaskbarItemInfo.ProgressState  - Normal / Indeterminate / Error / None
      * TaskbarItemInfo.Description    - taskbar thumbnail tooltip, carries the ETA
      * Window.Title                   - taskbar hover text, carries the ETA
      * TaskbarItemInfo.Overlay        - tick / alert badge on the taskbar icon
      * TaskbarItemInfo.ThumbButtonInfos - Cancel (then Open) in the thumbnail preview
      * user32!FlashWindowEx           - FLASHW_ALL | FLASHW_TIMERNOFG on completion,
                                         so the button keeps flashing until focused

    WPF is used deliberately: TaskbarItemInfo gives genuine ITaskbarList3 behaviour
    with no P/Invoke, and this machine has no .NET SDK so nothing can be compiled
    ahead of time. The only compiled code is a tiny in-memory Add-Type helper
    (FlashWindowEx + a background line pump).

.PARAMETER Path
    A .jsonl file to read and then tail. Omit to read the progress stream from stdin
    (this is how the engine drives it:  Transcribe.ps1 ... | pwsh -File Progress.ps1 ).

.PARAMETER CancelFile
    Sentinel file written when the user cancels. THE LAUNCHER OWNS THIS PATH: only
    Transcribe-Entry.ps1 starts both the engine and this UI, so it passes the same path
    to both (-CancelSignalFile to the engine, -CancelFile here) and treats the sentinel
    as cancelling the whole batch. This script writes exactly where it is told and never
    rewrites the path.

    If nothing passes it, the order is: -CancelFile, then $env:TRANSCRIBEIT_CANCEL_FILE,
    then %LOCALAPPDATA%\TranscribeIt\run\cancel.flag as a last-resort default for running
    the UI by hand. Which one was used is written to the log at startup and again on
    cancel, because a self-derived path that nobody is polling is the worst possible
    failure mode for a cancel button - it looks like it worked and does nothing.
    -EnginePid is the belt-and-braces answer to that; see below.
    Any stale sentinel is deleted at startup so a previous run cannot cancel this one.

.PARAMETER EnginePid
    Optional, and the anchor for this window's whole lifetime. The launcher passes its
    OWN pid, which lives for the entire batch. Two jobs:
      * if the engine ignores the cancel sentinel for -KillAfterSeconds, the UI kills
        that process tree (taskkill /T /F) as a fallback;
      * the watchdog in section 9b polls it, so this window can never outlive the run
        that started it. See -LingerSeconds.
    The pid is paired with the process START TIME at startup, so a recycled pid landing
    on some unrelated long-lived process can never keep the window alive for ever.
    Off unless supplied.

.PARAMETER LingerSeconds
    How long the window stays up after the run has ended - done, failed, cancelled or
    stopped - without the user acknowledging it. Default 600 (10 minutes). Activating the
    window replaces this countdown with the idle clock in -AcknowledgedIdleSeconds.

    0 disables the auto-close, which is the behaviour this script shipped with, and the
    bug that caused: four completed windows from four batches were still resident hours
    later holding ~300 MB each, because the only thing that ever closed this window was
    a click. Nothing is lost when it closes - the PDF is already next to its source.
    Falls back to $env:TRANSCRIBEIT_UI_LINGER_SECONDS when not passed.

.PARAMETER AcknowledgedIdleSeconds
    How long an ACKNOWLEDGED window may sit idle before it closes anyway. Default 1800
    (30 minutes). Every activation restarts the clock, and it is also restarted on every
    poll while this is the foreground window, so a window being read or used never closes
    under the user - but one they glanced at and abandoned still goes.

    This exists because cancelling the auto-close outright was not enough. Measured on the
    live install 2026-08-27: a finished window that had been clicked once held 386 MB of
    working set and 247 MB committed, engine long gone. One click should not buy a window
    the right to outlive the session. 0 restores the cancel-for-good behaviour.
    Falls back to $env:TRANSCRIBEIT_UI_IDLE_SECONDS when not passed.

.PARAMETER EngineGraceSeconds
    How long the engine must be gone AND the stream quiet before the run counts as over.
    Default 6. Two jobs: it rides out a momentary process-stat glitch, and it gives the
    last events a dying engine flushed time to be read and displayed, so a crash is
    never reported as a clean finish or vice versa.

.PARAMETER LogFile
    UI diagnostics log. Default %LOCALAPPDATA%\TranscribeIt\logs\progress-ui.log.
    Malformed stream lines are logged here and skipped.

.EXAMPLE
    .\Transcribe.ps1 -Path 'meeting.mp4' | pwsh -NoProfile -File .\app\Progress.ps1

.EXAMPLE
    pwsh -NoProfile -File .\app\Progress.ps1 -Path .\run.jsonl

.NOTES
    Owner: Track E. Files owned: app\Progress.ps1, test\replay-progress.ps1, test\progress\**
    Never writes to the registry (it only reads the light/dark theme preference).
#>
[CmdletBinding()]
param(
    [string] $Path,
    [string] $CancelFile,
    [int]    $EnginePid = 0,
    [int]    $KillAfterSeconds = 8,
    [int]    $LingerSeconds = -1,          # -1 = not supplied; resolved in section 0b
    [int]    $AcknowledgedIdleSeconds = -1,
    [int]    $EngineGraceSeconds = 6,
    [string] $LogFile,
    [string] $AppName = 'Heresay'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off   # the stream is untrusted data; missing properties must be soft

# ---------------------------------------------------------------------------
# 0. Paths and logging (must never throw)
# ---------------------------------------------------------------------------
$localAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = $env:TEMP }
$stateRoot = Join-Path $localAppData 'TranscribeIt'

if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $stateRoot 'logs\progress-ui.log'
}
# Where the cancel sentinel goes, and - just as important - who decided. The launcher
# is the only process that knows the path the engine is actually polling.
$script:CancelFileSource = 'launcher (-CancelFile)'
if ([string]::IsNullOrWhiteSpace($CancelFile)) {
    if (-not [string]::IsNullOrWhiteSpace($env:TRANSCRIBEIT_CANCEL_FILE)) {
        $CancelFile = $env:TRANSCRIBEIT_CANCEL_FILE
        $script:CancelFileSource = 'env:TRANSCRIBEIT_CANCEL_FILE'
    } else {
        $CancelFile = Join-Path $stateRoot 'run\cancel.flag'
        $script:CancelFileSource = 'SELF-DERIVED DEFAULT - nobody passed a path, so nothing may be polling it'
    }
}

function Confirm-Directory([string] $filePath) {
    try {
        $dir = [System.IO.Path]::GetDirectoryName($filePath)
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
        return $true
    } catch { return $false }
}

$script:LogOk = Confirm-Directory $LogFile
try {
    if ($script:LogOk -and [System.IO.File]::Exists($LogFile) -and
        (([System.IO.FileInfo]::new($LogFile)).Length -gt 2MB)) {
        [System.IO.File]::WriteAllText($LogFile, '')
    }
} catch { }

function Write-UiLog([string] $message) {
    if (-not $script:LogOk) { return }
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $message
        [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine)
    } catch { }
}

Write-UiLog "--- progress UI start (path='$Path' enginePid=$EnginePid) ---"
Write-UiLog "cancel sentinel: '$CancelFile'  [source: $($script:CancelFileSource)]"

# Remove any stale cancel sentinel from a previous run before the engine can see it.
try {
    if ([System.IO.File]::Exists($CancelFile)) {
        [System.IO.File]::Delete($CancelFile)
        Write-UiLog 'removed stale cancel sentinel'
    }
} catch { Write-UiLog "could not remove stale cancel sentinel: $($_.Exception.Message)" }

# ---------------------------------------------------------------------------
# 0b. Lifetime - this window must not outlive the run that started it
#
#     It used to. A finished window waited for a click that never came, and a window
#     whose engine died without writing a terminal event tailed a file nobody was
#     writing, for ever. Both cost ~300 MB of resident pwsh, invisibly, and they
#     accumulated one per batch. -EnginePid is the anchor: while that process lives the
#     window stays, and once it is gone the window is on a deadline. Section 9b acts.
# ---------------------------------------------------------------------------
if ($LingerSeconds -lt 0) {
    $LingerSeconds = 600
    $envLinger = $env:TRANSCRIBEIT_UI_LINGER_SECONDS
    if (-not [string]::IsNullOrWhiteSpace($envLinger)) {
        $parsed = 0
        if ([int]::TryParse($envLinger.Trim(), [ref]$parsed) -and $parsed -ge 0) {
            $LingerSeconds = $parsed
            Write-UiLog "linger from env: $LingerSeconds s"
        } else {
            Write-UiLog "ignored unusable TRANSCRIBEIT_UI_LINGER_SECONDS='$envLinger'"
        }
    }
}
if ($AcknowledgedIdleSeconds -lt 0) {
    $AcknowledgedIdleSeconds = 1800
    $envIdle = $env:TRANSCRIBEIT_UI_IDLE_SECONDS
    if (-not [string]::IsNullOrWhiteSpace($envIdle)) {
        $parsedIdle = 0
        if ([int]::TryParse($envIdle.Trim(), [ref]$parsedIdle) -and $parsedIdle -ge 0) {
            $AcknowledgedIdleSeconds = $parsedIdle
            Write-UiLog "acknowledged-idle from env: $AcknowledgedIdleSeconds s"
        } else {
            Write-UiLog "ignored unusable TRANSCRIBEIT_UI_IDLE_SECONDS='$envIdle'"
        }
    }
}
if ($LingerSeconds -lt 0)           { $LingerSeconds = 0 }
if ($AcknowledgedIdleSeconds -lt 0) { $AcknowledgedIdleSeconds = 0 }
if ($EngineGraceSeconds -lt 1)      { $EngineGraceSeconds = 1 }

# Pin WHICH process the pid means. Pids are recycled; without the start time a recycled
# one could keep this window open indefinitely, which is the failure being fixed.
$script:EngineStart = $null
$script:StreamPath  = $null
if ($EnginePid -gt 0) {
    try {
        $p0 = [System.Diagnostics.Process]::GetProcessById($EnginePid)
        try { $script:EngineStart = $p0.StartTime } catch { }
        try { $p0.Dispose() } catch { }
        if ($null -ne $script:EngineStart) {
            Write-UiLog ("watchdog armed: engine pid={0} started {1}, linger {2}s, grace {3}s" -f `
                         $EnginePid, $script:EngineStart.ToString('yyyy-MM-dd HH:mm:ss.fff'),
                         $LingerSeconds, $EngineGraceSeconds)
        } else {
            Write-UiLog "watchdog armed: engine pid=$EnginePid (start time unreadable - no recycled-pid check), linger $LingerSeconds s"
        }
    } catch {
        Write-UiLog "engine pid=$EnginePid was not running at startup ($($_.Exception.Message)) - this window will close after the linger"
    }
} else {
    Write-UiLog 'no -EnginePid: the run counts as ended only when the input stream closes'
}

# ---------------------------------------------------------------------------
# 1. Native helper + background line pump (compiled in memory, no SDK needed)
#    Compiled and STARTED FIRST so that nothing the engine writes is lost or
#    blocked while the WPF window is still being built.
# ---------------------------------------------------------------------------
$nativeSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TranscribeIt.Ui
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct FLASHWINFO
    {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    public static class Native
    {
        public const uint FLASHW_STOP       = 0x00000000;
        public const uint FLASHW_CAPTION    = 0x00000001;
        public const uint FLASHW_TRAY       = 0x00000002;
        public const uint FLASHW_ALL        = 0x00000003; // CAPTION | TRAY
        public const uint FLASHW_TIMERNOFG  = 0x0000000C;

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

        private static bool Flash(IntPtr hwnd, uint flags, uint count)
        {
            if (hwnd == IntPtr.Zero) { return false; }
            FLASHWINFO fi = new FLASHWINFO();
            fi.cbSize   = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            fi.hwnd     = hwnd;
            fi.dwFlags  = flags;
            fi.uCount   = count;
            fi.dwTimeout = 0;              // 0 = system default blink rate
            return FlashWindowEx(ref fi);
        }

        /// <summary>
        /// Flash the caption AND the taskbar button and KEEP flashing until the user
        /// actually brings the window to the foreground (FLASHW_TIMERNOFG). This is
        /// the behaviour TranscribeIt was asked for: the user walks away, and the
        /// taskbar keeps nagging until they come back - it does not blink 3 times
        /// while they are in another application and then give up.
        /// </summary>
        public static bool FlashUntilFocused(IntPtr hwnd)
        {
            return Flash(hwnd, FLASHW_ALL | FLASHW_TIMERNOFG, uint.MaxValue);
        }

        public static bool StopFlash(IntPtr hwnd)
        {
            return Flash(hwnd, FLASHW_STOP, 0);
        }

        private static readonly IntPtr HWND_TOP = IntPtr.Zero;
        private const uint SWP_NOSIZE     = 0x0001;
        private const uint SWP_NOMOVE     = 0x0002;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_SHOWWINDOW = 0x0040;

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
                                                int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        private const int SW_SHOWNOACTIVATE = 4;

        /// <summary>
        /// Make the window visible at the top of the Z order WITHOUT giving it keyboard
        /// focus, so the user can see the progress but their typing still goes where they
        /// left it. Not topmost - the user can put anything they like in front of it.
        ///
        /// The explicit ShowWindow matters: if our parent process was launched with
        /// STARTF_USESHOWWINDOW/SW_HIDE (exactly what a shell verb does to suppress the
        /// console flash), Win32 applies that value to the FIRST ShowWindow call in the
        /// process instead of the one WPF asked for, and the window would silently never
        /// appear. The second call is honoured normally.
        /// </summary>
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        /// <summary>
        /// Is this the window the user is actually looking at? The lifetime watchdog uses
        /// it to keep refreshing the idle clock of a window in the foreground, so a result
        /// somebody is reading is never closed out from under them.
        /// </summary>
        public static bool IsForeground(IntPtr hwnd)
        {
            return hwnd != IntPtr.Zero && GetForegroundWindow() == hwnd;
        }

        public static bool RaiseWithoutFocus(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) { return false; }
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            return SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                                SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
    }

    /// <summary>
    /// Reads JSON Lines off stdin (or tails a file) on a background thread and parks
    /// them in a lock-free queue. The UI thread drains the queue from a DispatcherTimer,
    /// so a slow UI can never block the engine's stdout and a blocking read can never
    /// freeze the window.
    /// </summary>
    public class LinePump
    {
        private readonly ConcurrentQueue<string> _queue = new ConcurrentQueue<string>();
        private volatile bool _eof;
        private volatile bool _stop;
        private volatile bool _discard;
        private int _lines;
        private Thread _thread;

        public volatile string LastError;

        public bool Eof       { get { return _eof; } }
        public int  Pending   { get { return _queue.Count; } }
        public int  LineCount { get { return _lines; } }

        public void Stop()          { _stop = true; }
        public void DiscardOnward() { _discard = true; DiscardAll(); }

        public void DiscardAll()
        {
            string junk;
            while (_queue.TryDequeue(out junk)) { }
        }

        public string[] Drain(int max)
        {
            List<string> taken = new List<string>();
            string line;
            while (taken.Count < max && _queue.TryDequeue(out line)) { taken.Add(line); }
            return taken.ToArray();
        }

        private void Emit(string line)
        {
            Interlocked.Increment(ref _lines);
            if (_discard) { return; }
            _queue.Enqueue(line);
        }

        public void StartStdin()
        {
            _thread = new Thread(RunStdin);
            _thread.IsBackground = true;
            _thread.Name = "TranscribeIt.StdinPump";
            _thread.Start();
        }

        public void StartFile(string path, int pollMs)
        {
            _thread = new Thread(delegate () { RunFile(path, pollMs); });
            _thread.IsBackground = true;
            _thread.Name = "TranscribeIt.FilePump";
            _thread.Start();
        }

        private void RunStdin()
        {
            try
            {
                using (Stream stdin = Console.OpenStandardInput())
                using (StreamReader reader = new StreamReader(stdin, new UTF8Encoding(false), true, 4096))
                {
                    string line;
                    while (!_stop && (line = reader.ReadLine()) != null) { Emit(line); }
                }
            }
            catch (Exception ex) { LastError = ex.Message; }
            finally { _eof = true; }
        }

        // Tail a file the engine is still appending to. Bytes are decoded manually and
        // split on '\n' so a half-written line is never handed to the parser.
        private void RunFile(string path, int pollMs)
        {
            try
            {
                while (!_stop && !File.Exists(path)) { Thread.Sleep(pollMs); }
                if (_stop) { return; }

                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                                      FileShare.ReadWrite | FileShare.Delete))
                {
                    byte[] buffer = new byte[8192];
                    char[] chars  = new char[16384];
                    Decoder decoder = new UTF8Encoding(false).GetDecoder();
                    StringBuilder partial = new StringBuilder();

                    while (!_stop)
                    {
                        int read = fs.Read(buffer, 0, buffer.Length);
                        if (read == 0) { Thread.Sleep(pollMs); continue; }

                        int count = decoder.GetChars(buffer, 0, read, chars, 0);
                        for (int i = 0; i < count; i++)
                        {
                            char c = chars[i];
                            if (c == '\n')      { Emit(partial.ToString()); partial.Length = 0; }
                            else if (c != '\r') { partial.Append(c); }
                        }
                    }
                    if (partial.Length > 0) { Emit(partial.ToString()); }
                }
            }
            catch (Exception ex) { LastError = ex.Message; }
            finally { _eof = true; }
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
} catch {
    Write-UiLog "FATAL: could not compile native helper: $($_.Exception.Message)"
    throw
}

$script:Pump = [TranscribeIt.Ui.LinePump]::new()
$script:InputMode = 'stdin'
if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $script:InputMode = 'file'
    $resolved = $Path
    try { $resolved = [System.IO.Path]::GetFullPath($Path) } catch { }
    $script:StreamPath = $resolved
    $script:Pump.StartFile($resolved, 150)
    Write-UiLog "tailing file: $resolved"
} else {
    $script:Pump.StartStdin()
    Write-UiLog "reading stdin (redirected=$([Console]::IsInputRedirected))"
}

# ---------------------------------------------------------------------------
# 2. WPF
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# The taskbar groups buttons by AppUserModelID and gives the default group the HOST
# PROCESS exe's icon, so without an explicit AppID this window files under pwsh.exe
# and gets the PowerShell icon no matter what $win.Icon says (that only reaches the
# title bar). Must be set before the HWND exists; a failure costs the icon, nothing
# else, so it never takes the UI down.
try {
    if (-not ('TranscribeIt.Ui.AppUserModelId' -as [Type])) {
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System.Runtime.InteropServices;

namespace TranscribeIt.Ui
{
    public static class AppUserModelId
    {
        [DllImport("shell32.dll", ExactSpelling = true)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string appId);
    }
}
'@
    }
    $hr = [TranscribeIt.Ui.AppUserModelId]::SetCurrentProcessExplicitAppUserModelID('Heresay.TranscribeIt.Progress')
    if ($hr -ne 0) { Write-UiLog ('SetCurrentProcessExplicitAppUserModelID returned 0x{0:X8}' -f $hr) }
} catch {
    Write-UiLog "AppUserModelID failed - taskbar button keeps the pwsh icon: $($_.Exception.Message)"
}

# Non-ASCII glyphs are built from code points so this file stays pure ASCII and
# behaves identically under pwsh 7 and Windows PowerShell 5.1 regardless of BOM.
$G = @{
    Ellipsis = [string][char]0x2026   # ...
    Dash     = [string][char]0x2013   # en dash
    Dot      = [string][char]0x00B7   # middle dot
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Heresay" Width="440" SizeToContent="Height"
        WindowStartupLocation="Manual" ResizeMode="CanMinimize"
        ShowActivated="False" ShowInTaskbar="True"
        Background="#FFF6F6F6" Foreground="#FF1A1A1A"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent"    Color="#FF0067C0"/>
    <SolidColorBrush x:Key="AccentDim" Color="#FF1975C5"/>
    <SolidColorBrush x:Key="Track"     Color="#FFDCDCDC"/>
    <SolidColorBrush x:Key="Muted"     Color="#FF5F5F5F"/>
    <SolidColorBrush x:Key="Faint"     Color="#FF767676"/>
    <SolidColorBrush x:Key="Danger"    Color="#FFC42B1C"/>
    <SolidColorBrush x:Key="Warn"      Color="#FF8A5300"/>
    <SolidColorBrush x:Key="Success"   Color="#FF107C10"/>

    <!-- Flat progress bar: no gradient, no glow sweep, with a real marquee for
         the indeterminate (stagePercent == null) case. -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Background" Value="{StaticResource Track}"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid ClipToBounds="True">
              <Border Background="{TemplateBinding Background}" CornerRadius="3"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left"
                      Background="{TemplateBinding Foreground}" CornerRadius="3"/>
              <Border x:Name="Marquee" Width="86" HorizontalAlignment="Left"
                      Background="{TemplateBinding Foreground}" CornerRadius="3"
                      Visibility="Collapsed">
                <Border.RenderTransform>
                  <TranslateTransform x:Name="MarqueeShift" X="-86"/>
                </Border.RenderTransform>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="Marquee" Property="Visibility" Value="Visible"/>
                <Trigger.EnterActions>
                  <BeginStoryboard Name="MarqueeStory">
                    <Storyboard RepeatBehavior="Forever">
                      <DoubleAnimation Storyboard.TargetName="MarqueeShift"
                                       Storyboard.TargetProperty="X"
                                       From="-86" To="412" Duration="0:0:1.5"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <StopStoryboard BeginStoryboardName="MarqueeStory"/>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Height" Value="28"/>
      <Setter Property="MinWidth" Value="86"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Foreground" Value="#FF1A1A1A"/>
      <Setter Property="Background" Value="#FFFDFDFD"/>
      <Setter Property="BorderBrush" Value="#FFD2D2D2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="4" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFF2F2F2"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFE9E9E9"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#FFF7F7F7"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFE2E2E2"/>
                <Setter Property="Foreground" Value="#FFA6A6A6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="#FFFFFFFF"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="4" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentDim}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF00559E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="16,14,16,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- 0 item name        -->
      <RowDefinition Height="Auto"/>   <!-- 1 stage / file x/y -->
      <RowDefinition Height="Auto"/>   <!-- 2 bar              -->
      <RowDefinition Height="Auto"/>   <!-- 3 eta + percent    -->
      <RowDefinition Height="*"/>      <!-- 4 notice           -->
      <RowDefinition Height="Auto"/>   <!-- 5 buttons          -->
    </Grid.RowDefinitions>

    <TextBlock x:Name="TbItem" Grid.Row="0" FontSize="13" FontWeight="SemiBold"
               TextTrimming="CharacterEllipsis" Text="Starting"/>
    <TextBlock x:Name="TbSub" Grid.Row="1" Margin="0,3,0,0" FontSize="11"
               Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"
               Text="Preparing"/>

    <ProgressBar x:Name="Bar" Grid.Row="2" Margin="0,12,0,0" Value="0"/>

    <Grid Grid.Row="3" Margin="0,10,0,0">
      <TextBlock x:Name="TbEta" FontSize="15" HorizontalAlignment="Left"
                 VerticalAlignment="Center" Text="estimating"/>
      <TextBlock x:Name="TbPct" FontSize="11" Foreground="{StaticResource Faint}"
                 HorizontalAlignment="Right" VerticalAlignment="Center" Text="0%"/>
    </Grid>

    <StackPanel Grid.Row="4" Margin="0,8,0,0">
      <TextBlock x:Name="TbNotice" FontSize="11" TextWrapping="Wrap" MaxHeight="46"
                 Foreground="{StaticResource Warn}" Visibility="Collapsed"/>
      <TextBlock x:Name="TbLogWrap" FontSize="11" Margin="0,3,0,0" Visibility="Collapsed">
        <Hyperlink x:Name="LnkLog" Foreground="{StaticResource Accent}">View log</Hyperlink>
      </TextBlock>
    </StackPanel>

    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnOpenFolder" Content="Open folder" Visibility="Collapsed"/>
      <Button x:Name="BtnOpenPdf" Content="Open PDF" Visibility="Collapsed"
              Style="{StaticResource AccentButton}"/>
      <Button x:Name="BtnCancel" Content="Cancel"/>
      <Button x:Name="BtnClose" Content="Close" Visibility="Collapsed"/>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
$win = [System.Windows.Markup.XamlReader]::Load($reader)
$win.Title = $AppName

$UI = @{
    Win        = $win
    TbItem     = $win.FindName('TbItem')
    TbSub      = $win.FindName('TbSub')
    Bar        = $win.FindName('Bar')
    TbEta      = $win.FindName('TbEta')
    TbPct      = $win.FindName('TbPct')
    TbNotice   = $win.FindName('TbNotice')
    TbLogWrap  = $win.FindName('TbLogWrap')
    LnkLog     = $win.FindName('LnkLog')
    BtnOpenPdf = $win.FindName('BtnOpenPdf')
    BtnFolder  = $win.FindName('BtnOpenFolder')
    BtnCancel  = $win.FindName('BtnCancel')
    BtnClose   = $win.FindName('BtnClose')
}
$UI.TbEta.Text = 'estimating' + $G.Ellipsis

function Get-Brush([string] $key) { return $win.FindResource($key) }

# Calm, out of the way: bottom-right of the work area rather than dead centre of
# whatever the user is actually working on.
#
# The height is SizeToContent (a fixed 170 measured off-screen still clipped the
# buttons row on the real display - DPI and font metrics differ from a headless
# Measure pass, so no hardcoded number is trustworthy). That means $win.Height is
# NaN until first layout, so the vertical anchor cannot be computed here. Left is
# safe now (Width is fixed); Top is set from ActualHeight in a SizeChanged
# handler, which fires at first show AND whenever content changes the height -
# a failure notice appearing, the log link, the buttons row swapping - so the
# window always grows UPWARD from its bottom-right anchor instead of sliding
# off the bottom of the work area. ResizeMode is CanMinimize, so the user can
# never resize it and SizeToContent stays in effect for the window's life.
try {
    $work = [System.Windows.SystemParameters]::WorkArea
    $win.Left = [Math]::Max($work.Left, $work.Right - $win.Width - 24)
    $win.add_SizeChanged({
        param($s, $e)
        try {
            $wa = [System.Windows.SystemParameters]::WorkArea
            $win.Top = [Math]::Max($wa.Top, $wa.Bottom - $win.ActualHeight - 24)
        } catch { }
    })
} catch {
    $win.WindowStartupLocation = 'CenterScreen'
}

# ---------------------------------------------------------------------------
# 3. Taskbar presence: progress bar, tooltip, overlay badge, thumbnail buttons
# ---------------------------------------------------------------------------
$tbi = [System.Windows.Shell.TaskbarItemInfo]::new()
$win.TaskbarItemInfo = $tbi

function New-MediaColor([string] $hex) {
    return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}

# Geometry mini-language is culture-invariant; never let the current locale turn
# "9.5" into "9,5" and corrupt a path string.
function Format-Invariant([string] $format, [object[]] $values) {
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $format, $values)
}

function New-IconBitmap([scriptblock] $draw, [int] $size = 32) {
    $visual = [System.Windows.Media.DrawingVisual]::new()
    $dc = $visual.RenderOpen()
    try { $null = & $draw $dc $size } finally { $dc.Close() }
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)
    $rtb.Freeze()

    # Round-trip through PNG. A raw RenderTargetBitmap is a perfectly good ImageSource
    # for on-screen use, but the shell interop that turns TaskbarItemInfo.Overlay and
    # ThumbButtonInfo.ImageSource into HICONs is fussier; a decoded BitmapFrame is what
    # it expects. Cheap insurance, done once at startup.
    try {
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $stream = [System.IO.MemoryStream]::new()
        $encoder.Save($stream)
        $stream.Position = 0
        $img = [System.Windows.Media.Imaging.BitmapImage]::new()
        $img.BeginInit()
        $img.CacheOption = 'OnLoad'
        $img.StreamSource = $stream
        $img.EndInit()
        $img.Freeze()
        $stream.Dispose()
        return $img
    } catch {
        Write-UiLog "icon PNG round-trip failed, using the raw bitmap: $($_.Exception.Message)"
        return $rtb
    }
}

function New-BadgeIcon([string] $fillHex, [string] $glyph) {
    return New-IconBitmap {
        param($dc, $size)
        $half = $size / 2.0
        $fill = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor $fillHex))
        $ring = [System.Windows.Media.Pen]::new(
            [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FFFFFFFF')), $size * 0.06)
        $dc.DrawEllipse($fill, $ring,
            [System.Windows.Point]::new($half, $half), $half * 0.94, $half * 0.94)

        $white = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FFFFFFFF'))
        $pen = [System.Windows.Media.Pen]::new($white, $size * 0.13)
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $s = $size / 32.0
        if ($glyph -eq 'tick') {
            $geo = [System.Windows.Media.Geometry]::Parse((Format-Invariant 'M {0},{1} L {2},{3} L {4},{5}' @(
                (9*$s),(17*$s),(14*$s),(22*$s),(23*$s),(11*$s))))
            $dc.DrawGeometry($null, $pen, $geo)
        } else {
            $geo = [System.Windows.Media.Geometry]::Parse((Format-Invariant 'M {0},{1} L {2},{3}' @(
                (16*$s),(8*$s),(16*$s),(19*$s))))
            $dc.DrawGeometry($null, $pen, $geo)
            $dc.DrawEllipse($white, $null,
                [System.Windows.Point]::new(16*$s, 24*$s), 1.9*$s, 1.9*$s)
        }
    } 32
}

# Thumbnail-toolbar glyphs. The thumbnail strip follows the system theme, so pick a
# glyph colour that reads against it. (Registry READ only - this script never writes
# to the registry.)
$systemUsesLightTheme = $true
try {
    $v = Get-ItemPropertyValue -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                               -Name 'SystemUsesLightTheme' -ErrorAction Stop
    $systemUsesLightTheme = ([int]$v -eq 1)
} catch { $systemUsesLightTheme = $false }
$glyphHex = if ($systemUsesLightTheme) { '#FF2B2B2B' } else { '#FFF2F2F2' }

# Window/taskbar icon, drawn at runtime so this track ships no binary assets: a
# teal speech bubble with two knocked-out lines of text on a slate tile. Without it the
# taskbar button shows a bare PowerShell prompt, which looks like something went wrong on
# a corporate laptop. Carries no lettering, so it survives a rename. The same geometry is
# mirrored in installer\assets\New-AppMark.ps1 for the Explorer verb icon - change both.
$appIcon = New-IconBitmap {
    param($dc, $size)
    $s = $size / 32.0
    $ink    = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FF12333F'))
    $accent = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FF19B0AE'))
    $dc.DrawRoundedRectangle($ink, $null,
        [System.Windows.Rect]::new(0, 0, $size, $size), (7.0*$s), (7.0*$s))
    # Bubble body and tail as one filled silhouette. Verified legible down to 16 px.
    # Note {1} does double duty as the top edge y AND the tail-end x; the numbers happen
    # to coincide. Do not "tidy" this string without re-rendering and comparing.
    $bub = [System.Windows.Media.Geometry]::Parse((Format-Invariant `
        'M {0},{1} H {2} A {3},{3} 0 0 1 {4},{5} V {6} A {3},{3} 0 0 1 {2},{7} H {8} L {9},{10} L {11},{7} H {1} A {3},{3} 0 0 1 {12},{6} V {5} A {3},{3} 0 0 1 {0},{1} Z' @(
        (8.2*$s),(6.4*$s),(23.8*$s),(3.4*$s),(27.2*$s),(9.8*$s),(16.4*$s),(19.8*$s),
        (14.6*$s),(11.4*$s),(25.6*$s),(10.4*$s),(4.8*$s))))
    $dc.DrawGeometry($accent, $null, $bub)
    foreach ($line in @(@(9.6, 10.4, 12.6), @(9.6, 14.2, 8.4))) {
        $dc.DrawRoundedRectangle($ink, $null, [System.Windows.Rect]::new(
            ($line[0]*$s), ($line[1]*$s), ($line[2]*$s), (2.6*$s)), (1.3*$s), (1.3*$s))
    }
} 64
try { $win.Icon = $appIcon } catch { Write-UiLog "window icon failed: $($_.Exception.Message)" }

$iconCancel = New-IconBitmap {
    param($dc, $size)
    $pen = [System.Windows.Media.Pen]::new(
        [System.Windows.Media.SolidColorBrush]::new((New-MediaColor $glyphHex)), $size * 0.10)
    $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'
    $s = $size / 32.0
    $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse(
        (Format-Invariant 'M {0},{1} L {2},{3}' @((10*$s),(10*$s),(22*$s),(22*$s)))))
    $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse(
        (Format-Invariant 'M {0},{1} L {2},{3}' @((22*$s),(10*$s),(10*$s),(22*$s)))))
} 32

$iconOpen = New-IconBitmap {
    param($dc, $size)
    $brush = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor $glyphHex))
    $pen = [System.Windows.Media.Pen]::new($brush, $size * 0.085)
    $pen.LineJoin = 'Round'; $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'
    $s = $size / 32.0
    # a page with an arrow leaving it - the conventional "open" glyph
    $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse(
        (Format-Invariant 'M {0},{1} L {0},{2} L {3},{2} L {3},{4}' @((9*$s),(13*$s),(24*$s),(23*$s),(19*$s)))))
    $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse(
        (Format-Invariant 'M {0},{1} L {2},{3}' @((14*$s),(15*$s),(23*$s),(7*$s)))))
    $dc.DrawGeometry($brush, $null, [System.Windows.Media.Geometry]::Parse(
        (Format-Invariant 'M {0},{1} L {2},{1} L {2},{3} Z' @((16*$s),(7*$s),(24*$s),(15*$s)))))
} 32

# Thumbnail buttons must all be registered BEFORE the taskbar button is created -
# Windows only accepts ThumbBarAddButtons once per window. Both buttons are declared
# up front and later only toggled between visible and hidden.
$thumbCancel = [System.Windows.Shell.ThumbButtonInfo]::new()
$thumbCancel.Description = 'Cancel transcription'
$thumbCancel.ImageSource = $iconCancel
$thumbCancel.DismissWhenClicked = $true

$thumbOpen = [System.Windows.Shell.ThumbButtonInfo]::new()
$thumbOpen.Description = 'Open transcript'
$thumbOpen.ImageSource = $iconOpen
$thumbOpen.DismissWhenClicked = $true
$thumbOpen.Visibility = 'Collapsed'

[void]$tbi.ThumbButtonInfos.Add($thumbCancel)
[void]$tbi.ThumbButtonInfos.Add($thumbOpen)

$script:IconTick  = $null
$script:IconAlert = $null

# ---------------------------------------------------------------------------
# 4. State
# ---------------------------------------------------------------------------
$script:S = @{
    Phase          = 'running'      # running | done | failed | cancelled | stopped
    Stage          = 'queued'
    Message        = ''
    Overall        = 0.0
    Granular       = $false         # stagePercent present and non-null
    ItemIndex      = 1
    ItemTotal      = 1
    ItemName       = ''
    EtaSmooth      = $null
    EtaShown       = $null
    EtaHold        = 0
    Failures       = [System.Collections.Generic.List[object]]::new()
    PdfPaths       = [System.Collections.Generic.List[string]]::new()
    WarningCount   = 0
    LastLogPath    = $null
    Flashed        = $false
    CancelRequested= $false
    Elapsed        = $null
    Events         = 0
    BadLines       = 0
    Hwnd           = [IntPtr]::Zero
}

function Get-EventProp($obj, [string] $name) {
    if ($null -eq $obj) { return $null }
    try {
        $p = $obj.PSObject.Properties[$name]
        if ($null -eq $p) { return $null }
        return $p.Value
    } catch { return $null }
}

function ConvertTo-Number($value) {
    if ($null -eq $value) { return $null }
    try { return [double]$value } catch { return $null }
}

# ---------------------------------------------------------------------------
# 5. ETA: formatting and defensive smoothing
# ---------------------------------------------------------------------------
function Format-EtaText($seconds) {
    # NEVER returns "0 min left". null means the engine cannot estimate yet.
    if ($null -eq $seconds) { return 'estimating' + $G.Ellipsis }
    $s = [double]$seconds
    if ($s -lt 0)    { $s = 0 }
    if ($s -lt 45)   { return 'less than a minute' }
    if ($s -lt 90)   { return 'about 1 min left' }
    if ($s -lt 3600) {
        $m = [int][Math]::Round($s / 60.0, [MidpointRounding]::AwayFromZero)
        if ($m -lt 2) { $m = 2 }
        return "about $m min left"
    }
    $h = [int][Math]::Floor($s / 3600)
    $m = [int][Math]::Round(($s - ($h * 3600)) / 60.0, [MidpointRounding]::AwayFromZero)
    if ($m -ge 60) { $h++; $m = 0 }
    if ($m -eq 0)  { return "about $h hr left" }
    return "about $h hr $m min left"
}

function Update-EtaEstimate($raw) {
    # The engine already smooths; this is belt and braces so the number the user stares
    # at does not jitter or creep BACKWARDS (i.e. the remaining time growing) between
    # events. Falling is the direction the user wants to see, so it is followed almost
    # exactly - lagging a countdown is its own kind of lie. Under 60 s we stop smoothing
    # altogether: that is where a stale figure is most obvious and least forgivable.
    $value = ConvertTo-Number $raw
    if ($null -eq $value) {
        # Not estimable. If we have never had a figure for this item, say so; if we
        # have, keep showing the last one rather than flickering to "estimating...".
        return
    }
    if ($null -eq $script:S.EtaSmooth -or $value -le 60) {
        $script:S.EtaSmooth = $value
    } elseif ($value -gt $script:S.EtaSmooth) {
        $script:S.EtaSmooth = $script:S.EtaSmooth + (0.25 * ($value - $script:S.EtaSmooth))
    } else {
        $script:S.EtaSmooth = $script:S.EtaSmooth + (0.85 * ($value - $script:S.EtaSmooth))
    }

    if ($null -eq $script:S.EtaShown -or $script:S.EtaSmooth -le $script:S.EtaShown -or $value -le 60) {
        $script:S.EtaShown = $script:S.EtaSmooth
        $script:S.EtaHold = 0
    } elseif ($script:S.EtaHold -ge 2) {
        # The increase has persisted across several events, so it is a real re-estimate
        # rather than one noisy reading. Stop holding - a stale number is also a lie.
        $script:S.EtaShown = $script:S.EtaSmooth
        $script:S.EtaHold = 0
    } else {
        # One reading saying "longer than I thought" is not enough to make the number
        # the user is watching go backwards.
        $script:S.EtaHold++
    }
}

function Reset-EtaEstimate {
    $script:S.EtaSmooth = $null
    $script:S.EtaShown  = $null
    $script:S.EtaHold   = 0
}

# ---------------------------------------------------------------------------
# 6. Rendering
# ---------------------------------------------------------------------------
function Set-Notice([string] $text, [string] $brushKey = 'Warn') {
    if ([string]::IsNullOrWhiteSpace($text)) {
        $UI.TbNotice.Visibility = 'Collapsed'
        return
    }
    $UI.TbNotice.Text = $text
    $UI.TbNotice.Foreground = Get-Brush $brushKey
    $UI.TbNotice.Visibility = 'Visible'
    # No manual resize here: the window is SizeToContent="Height", so making the
    # notice visible grows it automatically and the SizeChanged handler re-anchors
    # it bottom-right. Setting $win.Height by hand would CANCEL SizeToContent and
    # bring back the fixed-height clipping this replaced.
}

function Get-RunningNotice {
    $n = $script:S.Failures.Count
    if ($n -le 0) { return '' }
    $noun = if ($n -eq 1) { 'file' } else { 'files' }
    return "$n $noun could not be transcribed; continuing with the rest."
}

function Update-Display {
    try {
        switch ($script:S.Phase) {
            'running' {
                $pct = [int][Math]::Floor([Math]::Max(0, [Math]::Min(100, $script:S.Overall)))
                $etaText = Format-EtaText $script:S.EtaShown
                if ($script:S.CancelRequested) { $etaText = 'cancelling' + $G.Ellipsis }

                $UI.TbItem.Text = if ([string]::IsNullOrWhiteSpace($script:S.ItemName)) {
                    'Preparing' + $G.Ellipsis
                } else { $script:S.ItemName }

                $sub = @()
                if (-not [string]::IsNullOrWhiteSpace($script:S.Message)) { $sub += $script:S.Message }
                if ($script:S.ItemTotal -gt 1) { $sub += "File $($script:S.ItemIndex) of $($script:S.ItemTotal)" }
                if ($sub.Count -eq 0) { $sub += 'Working' }
                $UI.TbSub.Text = ($sub -join "  $($G.Dot)  ")

                $UI.TbEta.Text = $etaText
                $UI.TbPct.Text = "$pct%"
                $UI.Bar.Value  = $script:S.Overall
                $UI.Bar.IsIndeterminate = (-not $script:S.Granular)

                $batchTag = if ($script:S.ItemTotal -gt 1) { " ($($script:S.ItemIndex)/$($script:S.ItemTotal))" } else { '' }
                $win.Title = "$pct%$batchTag $($G.Dash) $etaText $($G.Dash) $AppName"

                $tbi.ProgressValue = [Math]::Max(0.0, [Math]::Min(1.0, $script:S.Overall / 100.0))
                $tbi.ProgressState = if ($script:S.CancelRequested) { 'Paused' }
                                     elseif ($script:S.Granular)    { 'Normal' }
                                     else                           { 'Indeterminate' }

                $desc = @()
                if (-not [string]::IsNullOrWhiteSpace($script:S.Message)) { $desc += $script:S.Message }
                $desc += $etaText
                if ($script:S.ItemTotal -gt 1) { $desc += "file $($script:S.ItemIndex) of $($script:S.ItemTotal)" }
                $tbi.Description = ($desc -join " $($G.Dash) ")

                if ($script:S.CancelRequested) {
                    Set-Notice 'Cancelling - waiting for the engine to stop cleanly.' 'Muted'
                } else {
                    Set-Notice (Get-RunningNotice) 'Warn'
                }
            }
        }
    } catch {
        Write-UiLog "Update-Display error: $($_.Exception.Message)"
    }
}

function Set-Buttons([string] $mode) {
    $UI.BtnCancel.Visibility    = 'Collapsed'
    $UI.BtnOpenPdf.Visibility   = 'Collapsed'
    $UI.BtnFolder.Visibility    = 'Collapsed'
    $UI.BtnClose.Visibility     = 'Collapsed'
    switch ($mode) {
        'running' { $UI.BtnCancel.Visibility = 'Visible' }
        'done' {
            $UI.BtnClose.Visibility = 'Visible'
            if ($script:S.PdfPaths.Count -eq 1) {
                $UI.BtnOpenPdf.Visibility = 'Visible'
                $UI.BtnFolder.Visibility  = 'Visible'
            } elseif ($script:S.PdfPaths.Count -gt 1) {
                # Multi-file batch: offer the containing folder, that is the useful one.
                $UI.BtnFolder.Content    = 'Open folder'
                $UI.BtnFolder.Visibility = 'Visible'
                $UI.BtnFolder.Style      = $win.FindResource('AccentButton')
            }
        }
        default { $UI.BtnClose.Visibility = 'Visible' }
    }
}

function Show-LogLink([string] $logPath) {
    if ([string]::IsNullOrWhiteSpace($logPath)) { return }
    $script:S.LastLogPath = $logPath
    $UI.TbLogWrap.Visibility = 'Visible'
}

# ---------------------------------------------------------------------------
# 7. Flash + terminal states
# ---------------------------------------------------------------------------
function Invoke-CompletionFlash {
    # INVARIANT: at most ONE FlashWindowEx for the whole life of this process, and only
    # from a terminal event (batchComplete, or a fatal error). The launcher already
    # guarantees exactly one batchComplete per batch, and this guard means that even if a
    # fatal error is followed by a batchComplete the user is nagged once, not twice.
    # Do not add further callers.
    if ($script:S.Flashed) { return }
    $script:S.Flashed = $true
    try {
        if ($script:S.Hwnd -eq [IntPtr]::Zero) {
            $script:S.Hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($win)).Handle
        }
        $ok = [TranscribeIt.Ui.Native]::FlashUntilFocused($script:S.Hwnd)
        Write-UiLog "FlashWindowEx(FLASHW_ALL|FLASHW_TIMERNOFG) hwnd=$($script:S.Hwnd) returned $ok"
    } catch {
        Write-UiLog "flash failed: $($_.Exception.Message)"
    }
}

function Set-PhaseDone($ev) {
    $script:S.Phase = 'done'
    $UI.Bar.IsIndeterminate = $false
    $UI.Bar.Value = 100
    $UI.Bar.Foreground = Get-Brush 'Success'

    $succeeded = ConvertTo-Number (Get-EventProp $ev 'succeeded')
    $failed    = ConvertTo-Number (Get-EventProp $ev 'failed')
    if ($null -eq $failed) { $failed = $script:S.Failures.Count }
    if ($null -eq $succeeded) { $succeeded = $script:S.PdfPaths.Count }
    $elapsed = ConvertTo-Number (Get-EventProp $ev 'elapsedSeconds')

    foreach ($p in @(Get-EventProp $ev 'pdfPaths')) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and -not $script:S.PdfPaths.Contains([string]$p)) {
            [void]$script:S.PdfPaths.Add([string]$p)
        }
    }

    $headline = if ($failed -ge 1) {
        'Finished with problems'
    } elseif ($succeeded -gt 1) {
        "$([int]$succeeded) transcripts ready"
    } else {
        'Transcript ready'
    }
    $UI.TbItem.Text = $headline

    $sub = @()
    if ($script:S.PdfPaths.Count -eq 1) {
        $sub += [System.IO.Path]::GetFileName($script:S.PdfPaths[0])
    } elseif ($script:S.PdfPaths.Count -gt 1) {
        $sub += "$($script:S.PdfPaths.Count) PDFs in $([System.IO.Path]::GetDirectoryName($script:S.PdfPaths[0]))"
    }
    if ($failed -ge 1) { $sub += "$([int]$failed) failed" }
    $UI.TbSub.Text = ($sub -join "  $($G.Dot)  ")

    $UI.TbEta.Text = if ($null -ne $elapsed) { 'Done in ' + (Format-Duration $elapsed) } else { 'Done' }
    $UI.TbPct.Text = '100%'

    $notice = @()
    if ($script:S.Failures.Count -gt 0) {
        $notice += $script:S.Failures[0].Message
        if ($script:S.Failures.Count -gt 1) { $notice += "(+$($script:S.Failures.Count - 1) more)" }
    }
    # Attribution warnings are deliberately never surfaced in this window (user decision 2026-08-27) - they stay in the PDF/JSON and the UI log.
    if ($notice.Count -gt 0) { Set-Notice ($notice -join ' ') 'Warn' }

    # Taskbar: clear the progress bar, badge the icon, tell the tooltip.
    $tbi.ProgressState = 'None'
    $tbi.ProgressValue = 1.0
    try {
        if ($null -eq $script:IconTick) { $script:IconTick = New-BadgeIcon '#FF107C10' 'tick' }
        $tbi.Overlay = $script:IconTick
    } catch { Write-UiLog "overlay (tick) failed: $($_.Exception.Message)" }
    $tbi.Description = if ($failed -ge 1) { "$headline $($G.Dash) $([int]$failed) failed" } else { $headline }
    $win.Title = "$headline $($G.Dash) $AppName"

    $thumbCancel.Visibility = 'Collapsed'
    $thumbOpen.Description  = if ($script:S.PdfPaths.Count -gt 1) { 'Open transcript folder' } else { 'Open PDF' }
    $thumbOpen.Visibility   = 'Visible'

    Set-Buttons 'done'
    $script:Pump.Stop()
    Write-UiLog "batchComplete succeeded=$succeeded failed=$failed pdfs=$($script:S.PdfPaths.Count)"
    Invoke-CompletionFlash
}

function Set-PhaseFatal([string] $message, [string] $logPath) {
    $script:S.Phase = 'failed'
    $UI.Bar.IsIndeterminate = $false
    $UI.Bar.Value = 100
    $UI.Bar.Foreground = Get-Brush 'Danger'
    $UI.TbItem.Text = 'Transcription failed'
    $UI.TbSub.Text  = if ([string]::IsNullOrWhiteSpace($script:S.ItemName)) { '' } else { $script:S.ItemName }
    $UI.TbEta.Visibility = 'Collapsed'   # the message below says it better than a big word
    $UI.TbPct.Text  = ''
    Set-Notice $message 'Danger'
    Show-LogLink $logPath

    # Error state paints the taskbar bar RED. It only renders with a non-zero value,
    # so fill it - a half-empty red bar reads as "still going".
    $tbi.ProgressState = 'Error'
    $tbi.ProgressValue = 1.0
    try {
        if ($null -eq $script:IconAlert) { $script:IconAlert = New-BadgeIcon '#FFC42B1C' 'alert' }
        $tbi.Overlay = $script:IconAlert
    } catch { Write-UiLog "overlay (alert) failed: $($_.Exception.Message)" }
    $tbi.Description = "Transcription failed $($G.Dash) $message"
    $win.Title = "Failed $($G.Dash) $AppName"

    $thumbCancel.Visibility = 'Collapsed'
    Set-Buttons 'failed'
    $script:Pump.Stop()
    Write-UiLog "FATAL: $message (log=$logPath)"
    Invoke-CompletionFlash
}

function Set-PhaseCancelled {
    $script:S.Phase = 'cancelled'
    $UI.Bar.IsIndeterminate = $false
    $UI.Bar.Foreground = Get-Brush 'Faint'      # a blue bar frozen mid-run reads as "still working"
    $UI.TbItem.Text = 'Cancelled'
    # The launcher discards anything still queued rather than starting it.
    $UI.TbSub.Text  = 'The file in progress was abandoned and nothing further was started.'
    $UI.TbEta.Visibility = 'Collapsed'
    $UI.TbPct.Text  = ''
    Set-Notice ''                               # the "Cancelling..." notice is now stale
    $tbi.ProgressState = 'None'
    $tbi.Description   = 'Cancelled'
    $win.Title = "Cancelled $($G.Dash) $AppName"
    $thumbCancel.Visibility = 'Collapsed'
    if ($script:S.PdfPaths.Count -gt 0) {
        Set-Buttons 'done'
        $noun = if ($script:S.PdfPaths.Count -eq 1) { 'transcript' } else { 'transcripts' }
        $UI.TbSub.Text = "$($script:S.PdfPaths.Count) $noun finished before cancelling; the rest were skipped."
    } else {
        Set-Buttons 'cancelled'
    }
    $script:Pump.Stop()
    Write-UiLog 'cancelled (no flash - the user is already here)'
}

function Set-PhaseStopped([string] $reason = 'the stream ended') {
    # The run ended without a terminal event - the stream closed, or the engine died.
    # Say so plainly; do NOT flash and do NOT claim success.
    $script:S.Phase = 'stopped'
    $UI.Bar.IsIndeterminate = $false
    $UI.TbItem.Text = 'Stopped'
    $UI.TbSub.Text  = 'The transcription process ended without reporting completion.'
    $UI.TbEta.Visibility = 'Collapsed'
    $UI.TbPct.Text  = ''
    Set-Notice ''
    $tbi.ProgressState = 'Paused'
    $tbi.ProgressValue = [Math]::Max(0.02, $script:S.Overall / 100.0)
    $tbi.Description = 'Stopped'
    $win.Title = "Stopped $($G.Dash) $AppName"
    $thumbCancel.Visibility = 'Collapsed'
    if ($script:S.PdfPaths.Count -gt 0) { Set-Buttons 'done' } else { Set-Buttons 'stopped' }
    # Nothing more can arrive: let the tail thread go rather than poll a dead file.
    $script:Pump.Stop()
    Write-UiLog "stopped - $reason, no terminal event after $($script:S.Events) events"
}

function Format-Duration($seconds) {
    $s = [int][Math]::Round([double]$seconds)
    if ($s -lt 60) { return "$s s" }
    $m = [int][Math]::Floor($s / 60)
    $r = $s - ($m * 60)
    if ($m -lt 60) { return "$m min $r s" }
    $h = [int][Math]::Floor($m / 60)
    return "$h hr $($m - ($h * 60)) min"
}

# ---------------------------------------------------------------------------
# 8. Event handling - unknown types and unknown fields are ignored, by contract
# ---------------------------------------------------------------------------
function Invoke-ProgressEvent($ev) {
    $type = Get-EventProp $ev 'type'
    if ([string]::IsNullOrWhiteSpace($type)) {
        Write-UiLog 'ignored: event with no type'
        return
    }

    # Once terminal, later events are logged but must not resurrect the UI.
    if ($script:S.Phase -ne 'running' -and $type -ne 'result') {
        Write-UiLog "ignored '$type' after terminal state '$($script:S.Phase)'"
        return
    }

    switch ($type) {

        'progress' {
            $idx = ConvertTo-Number (Get-EventProp $ev 'itemIndex')
            if ($null -ne $idx -and [int]$idx -ne $script:S.ItemIndex) {
                $script:S.ItemIndex = [int]$idx
                Reset-EtaEstimate          # a new file means a brand new estimate
            }
            $tot = ConvertTo-Number (Get-EventProp $ev 'itemTotal')
            if ($null -ne $tot) { $script:S.ItemTotal = [int]$tot }

            $name = Get-EventProp $ev 'itemName'
            if (-not [string]::IsNullOrWhiteSpace($name)) { $script:S.ItemName = [string]$name }

            $stage = Get-EventProp $ev 'stage'
            if (-not [string]::IsNullOrWhiteSpace($stage)) { $script:S.Stage = [string]$stage }

            $msg = Get-EventProp $ev 'message'
            if (-not [string]::IsNullOrWhiteSpace($msg)) { $script:S.Message = [string]$msg }

            # overallPercent is authoritative. We never compute our own.
            $overall = ConvertTo-Number (Get-EventProp $ev 'overallPercent')
            if ($null -ne $overall) {
                $script:S.Overall = [Math]::Max(0.0, [Math]::Min(100.0, $overall))
            }

            # stagePercent null (or absent) => this stage cannot report granular
            # progress => marquee, never 0%.
            $script:S.Granular = ($null -ne (ConvertTo-Number (Get-EventProp $ev 'stagePercent')))

            Update-EtaEstimate (Get-EventProp $ev 'etaSeconds')

            if ($script:S.Stage -eq 'cancelled') { Set-PhaseCancelled; return }
            if ($script:S.Stage -eq 'error') { Write-UiLog "progress event with stage=error: $($script:S.Message)" }
        }

        'result' {
            $pdf = Get-EventProp $ev 'pdfPath'
            if (-not [string]::IsNullOrWhiteSpace($pdf) -and -not $script:S.PdfPaths.Contains([string]$pdf)) {
                [void]$script:S.PdfPaths.Add([string]$pdf)
            }
            $warnings = @(Get-EventProp $ev 'warnings')
            $script:S.WarningCount += @($warnings | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
            Write-UiLog "result: $pdf (warnings=$($warnings.Count))"
        }

        'error' {
            $msg = [string](Get-EventProp $ev 'message')
            if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'The engine reported an error.' }
            $logPath = Get-EventProp $ev 'logPath'
            $fatalRaw = Get-EventProp $ev 'fatal'
            $fatal = if ($null -eq $fatalRaw) { $true } else { [bool]$fatalRaw }   # schema default: true

            if ($fatal) {
                Set-PhaseFatal $msg ([string]$logPath)
            } else {
                [void]$script:S.Failures.Add(@{
                    Item    = $script:S.ItemName
                    Message = $msg
                    LogPath = [string]$logPath
                })
                Show-LogLink ([string]$logPath)
                Write-UiLog "non-fatal error (batch continues): $msg"
            }
        }

        'batchComplete' { Set-PhaseDone $ev }

        default { Write-UiLog "ignored unknown event type '$type'" }
    }
}

$script:TrimChars = [char[]]@([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x00)

function Invoke-StreamLine([string] $line) {
    if ($null -eq $line) { return }
    $trimmed = $line.Trim($script:TrimChars)
    if ($trimmed.Length -eq 0) { return }
    if (-not ($trimmed.StartsWith('{'))) {
        $script:S.BadLines++
        Write-UiLog "skipped non-JSON line: $($trimmed.Substring(0, [Math]::Min(160, $trimmed.Length)))"
        return
    }
    $ev = $null
    try {
        $ev = $trimmed | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $script:S.BadLines++
        Write-UiLog "skipped malformed JSON: $($trimmed.Substring(0, [Math]::Min(160, $trimmed.Length)))"
        return
    }
    if ($ev -is [System.Array]) { $ev = $ev[0] }
    $script:S.Events++
    try {
        Invoke-ProgressEvent $ev
    } catch {
        Write-UiLog "event handler error: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 9. Commands: cancel, open
# ---------------------------------------------------------------------------
function Start-CancelRequest {
    if ($script:S.Phase -ne 'running' -or $script:S.CancelRequested) { return }
    $script:S.CancelRequested = $true
    $UI.BtnCancel.IsEnabled = $false
    $UI.BtnCancel.Content = 'Cancelling' + $G.Ellipsis
    $thumbCancel.IsEnabled = $false

    # Write exactly where we were told - no path rewriting. The launcher gave the same
    # path to the engine, so this is what stops the batch.
    $sentinelOk = $false
    try {
        [void](Confirm-Directory $CancelFile)
        $payload = "cancelled-by-user`t$(Get-Date -Format o)`tui-pid=$PID"
        [System.IO.File]::WriteAllText($CancelFile, $payload)
        $sentinelOk = [System.IO.File]::Exists($CancelFile)
        Write-UiLog "cancel sentinel written: '$CancelFile' [source: $($script:CancelFileSource)] exists=$sentinelOk"
    } catch {
        Write-UiLog "could not write cancel sentinel '$CancelFile': $($_.Exception.Message)"
    }
    if ($script:CancelFileSource -like 'SELF-DERIVED*' -and $EnginePid -le 0) {
        Write-UiLog 'WARNING: the sentinel path was self-derived and no -EnginePid was supplied, so cancellation cannot be guaranteed.'
    }

    if ($EnginePid -gt 0) {
        # script-scoped: an event handler cannot see a function's locals when it fires
        $script:KillTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:KillTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $KillAfterSeconds))
        $script:KillTimer.Add_Tick({
            $script:KillTimer.Stop()
            if ($script:S.Phase -eq 'running') {
                try {
                    Write-UiLog "engine did not stop within $KillAfterSeconds s - taskkill /T /F $EnginePid"
                    Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $EnginePid /T /F" `
                                  -WindowStyle Hidden -ErrorAction Stop
                } catch { Write-UiLog "taskkill failed: $($_.Exception.Message)" }
            }
        })
        $script:KillTimer.Start()
    }
    Update-Display
}

function Invoke-ShellOpen([string] $target, [switch] $Reveal) {
    if ([string]::IsNullOrWhiteSpace($target)) { return }
    try {
        if ($Reveal) {
            if ([System.IO.File]::Exists($target)) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $target)
                return
            }
            $dir = [System.IO.Path]::GetDirectoryName($target)
            if ([System.IO.Directory]::Exists($dir)) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir)
            } else {
                Set-Notice "That folder is no longer there: $dir" 'Danger'
            }
            return
        }
        if (-not [System.IO.File]::Exists($target)) {
            Set-Notice "That file is no longer there: $([System.IO.Path]::GetFileName($target))" 'Danger'
            Write-UiLog "open failed, missing: $target"
            return
        }
        Start-Process -FilePath $target
    } catch {
        Set-Notice "Windows could not open it: $($_.Exception.Message)" 'Danger'
        Write-UiLog "open failed: $($_.Exception.Message)"
    }
}

function Invoke-PrimaryOpen {
    if ($script:S.PdfPaths.Count -eq 1) { Invoke-ShellOpen $script:S.PdfPaths[0] }
    elseif ($script:S.PdfPaths.Count -gt 1) { Invoke-ShellOpen $script:S.PdfPaths[0] -Reveal }
}

# ---------------------------------------------------------------------------
# 9b. Lifetime watchdog - see section 0b for why this exists
#
#     Two questions, polled every couple of seconds:
#       1. has the run ended?  The engine pid is gone (and still gone, and the stream
#          quiet with it) or - when nobody gave us a pid - stdin has closed.
#       2. if it has, is anyone looking?  A terminal window the user never acknowledges
#          gets -LingerSeconds and then closes itself.
#     The bias throughout is one-directional: anything that cannot be determined counts
#     as "still running", because closing a live run's window is far worse than leaving
#     one more window up.
# ---------------------------------------------------------------------------
$script:Life = @{
    GoneSince     = $null    # first tick that saw the engine gone
    QuietSince    = $null    # first tick that saw nothing new on the stream
    EndedSince    = $null    # first tick that saw a terminal phase
    LastLineCount = -1
    LastLength    = [long]-1
    Acknowledged  = $false   # the user activated the window after the run ended
    LastTouch     = $null    # ...and when they last did, or last had it in the foreground
    Closing       = $false
}

function Test-EngineGone {
    if ($EnginePid -le 0) { return $false }
    $p = $null
    try { $p = [System.Diagnostics.Process]::GetProcessById($EnginePid) }
    catch { return $true }                      # no such pid: gone
    try {
        if ($p.HasExited) { return $true }
        if ($null -ne $script:EngineStart) {
            try {
                $moved = [Math]::Abs(($p.StartTime - $script:EngineStart).TotalMilliseconds)
                if ($moved -gt 250) {
                    Write-UiLog "pid $EnginePid is a different process now (start time moved $([int]$moved) ms) - engine gone"
                    return $true
                }
            } catch { }                         # unreadable: assume it is still ours
        }
        return $false
    }
    catch   { return $false }                   # cannot tell: never close over a live run
    finally { try { $p.Dispose() } catch { } }
}

function Update-StreamQuiet {
    # Quiet = no line pumped, none queued, and (file mode) the .jsonl has not grown.
    # This is what stops us closing before the events a dying engine flushed are shown.
    $moved = $false
    $lines = $script:Pump.LineCount
    if ($lines -ne $script:Life.LastLineCount) { $script:Life.LastLineCount = $lines; $moved = $true }
    if ($script:Pump.Pending -gt 0) { $moved = $true }
    if (-not [string]::IsNullOrWhiteSpace($script:StreamPath)) {
        try {
            $len = [long]-1
            $fi = [System.IO.FileInfo]::new($script:StreamPath)
            if ($fi.Exists) { $len = $fi.Length }
            if ($len -ne $script:Life.LastLength) { $script:Life.LastLength = $len; $moved = $true }
        } catch { }
    }
    if ($moved) { $script:Life.QuietSince = $null }
    elseif ($null -eq $script:Life.QuietSince) { $script:Life.QuietSince = Get-Date }
}

function Invoke-LifeTick {
    if ($script:Life.Closing) { return }
    Update-StreamQuiet
    $now = Get-Date

    if (Test-EngineGone) {
        if ($null -eq $script:Life.GoneSince) {
            $script:Life.GoneSince = $now
            Write-UiLog "engine pid=$EnginePid is gone"
        }
    } elseif ($null -ne $script:Life.GoneSince) {
        $script:Life.GoneSince = $null
        Write-UiLog "engine pid=$EnginePid answered again - deadline cleared"
    }

    $ended = ($null -ne $script:Life.GoneSince -and
              ($now - $script:Life.GoneSince).TotalSeconds -ge $EngineGraceSeconds) -or
             ($EnginePid -le 0 -and $script:InputMode -eq 'stdin' -and $script:Pump.Eof)
    $quiet = ($null -ne $script:Life.QuietSince -and
              ($now - $script:Life.QuietSince).TotalSeconds -ge $EngineGraceSeconds)

    if ($script:S.Phase -eq 'running') {
        if ($ended -and $quiet) {
            # The engine died without a terminal event. Stop tailing a file nobody is
            # writing, and report exactly that - never a success we did not see.
            $timer.Stop()
            if ($script:S.CancelRequested) { Set-PhaseCancelled }
            else { Set-PhaseStopped 'the engine exited' }
        }
        return
    }

    if ($null -eq $script:Life.EndedSince) {
        $script:Life.EndedSince = $now
        $plan = if ($LingerSeconds -le 0) { 'no auto-close (-LingerSeconds 0)' }
                else { "auto-close in $LingerSeconds s, or $AcknowledgedIdleSeconds s idle once acknowledged" }
        Write-UiLog "phase '$($script:S.Phase)' is terminal - $plan"
    }
    if ($LingerSeconds -le 0) { return }   # auto-close disabled outright
    if (-not $ended) { return }            # the engine is still there: it can still speak

    $why = $null
    if ($script:Life.Acknowledged) {
        # The user has been here. Give them an idle clock rather than a free pass: keep it
        # while they are looking at it, close it once they have plainly moved on.
        if ($AcknowledgedIdleSeconds -le 0) { return }
        try {
            if ([TranscribeIt.Ui.Native]::IsForeground($script:S.Hwnd)) {
                $script:Life.LastTouch = $now
            }
        } catch { }
        if ($null -eq $script:Life.LastTouch) { $script:Life.LastTouch = $now; return }
        $idle = ($now - $script:Life.LastTouch).TotalSeconds
        if ($idle -lt $AcknowledgedIdleSeconds) { return }
        $why = "acknowledged but untouched for {0:n0} s" -f $idle
    } else {
        $age = ($now - $script:Life.EndedSince).TotalSeconds
        if ($age -lt $LingerSeconds) { return }
        $why = "never acknowledged, up {0:n0} s past the end" -f $age
    }

    $script:Life.Closing = $true
    Write-UiLog ("auto-closing: phase '{0}', engine gone, {1}" -f $script:S.Phase, $why)
    try {
        if ($script:S.Flashed -and $script:S.Hwnd -ne [IntPtr]::Zero) {
            [void][TranscribeIt.Ui.Native]::StopFlash($script:S.Hwnd)
        }
    } catch { }
    try { $win.Close() } catch { Write-UiLog "auto-close failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# 10. Wiring
# ---------------------------------------------------------------------------
$UI.BtnCancel.Add_Click({ Start-CancelRequest })
$UI.BtnClose.Add_Click({ $win.Close() })
$UI.BtnOpenPdf.Add_Click({ if ($script:S.PdfPaths.Count -gt 0) { Invoke-ShellOpen $script:S.PdfPaths[0] } })
$UI.BtnFolder.Add_Click({ if ($script:S.PdfPaths.Count -gt 0) { Invoke-ShellOpen $script:S.PdfPaths[0] -Reveal } })
$UI.LnkLog.Add_Click({
    $p = $script:S.LastLogPath
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    if ([System.IO.File]::Exists($p)) {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $p) }
        catch { Invoke-ShellOpen $p -Reveal }
    } else {
        Set-Notice "The log is no longer there: $p" 'Danger'
    }
})

$thumbCancel.Add_Click({ Start-CancelRequest })
$thumbOpen.Add_Click({ Invoke-PrimaryOpen })

$win.Add_SourceInitialized({
    $script:S.Hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($win)).Handle
    Write-UiLog "window hwnd=$($script:S.Hwnd)"
})

# Focusing the window is the user acknowledging the flash. Windows stops
# FLASHW_TIMERNOFG itself; clearing explicitly also resets the caption.
$win.Add_Activated({
    # Acknowledgement counts only once there is a result to acknowledge: activating the
    # window mid-run (to click Cancel, or alt-tabbing past it) must not disarm the
    # watchdog, or a run the user glanced at once would leak its window again.
    if ($script:S.Phase -ne 'running') {
        $script:Life.LastTouch = Get-Date          # every activation restarts the idle clock
        if (-not $script:Life.Acknowledged) {
            $script:Life.Acknowledged = $true
            Write-UiLog "window activated after the run ended - the linger is replaced by a ${AcknowledgedIdleSeconds}s idle clock"
        }
    }
    if ($script:S.Flashed -and $script:S.Hwnd -ne [IntPtr]::Zero) {
        try {
            [void][TranscribeIt.Ui.Native]::StopFlash($script:S.Hwnd)
            Write-UiLog 'window activated by the user - flash cleared'
        } catch { }
    }
})

$win.Add_Closed({
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
})

# ---------------------------------------------------------------------------
# 11. Pump the stream from the UI thread - never a blocking read on the UI
# ---------------------------------------------------------------------------
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
    try {
        $lines = $script:Pump.Drain(500)
        if ($lines.Length -gt 0) {
            foreach ($line in $lines) { Invoke-StreamLine $line }
            Update-Display
        }
        if ($script:Pump.Eof -and $script:Pump.Pending -eq 0) {
            $timer.Stop()
            if ($script:S.Phase -eq 'running') {
                if ($script:S.CancelRequested) { Set-PhaseCancelled } else { Set-PhaseStopped }
            }
            if ($script:Pump.LastError) { Write-UiLog "pump error: $($script:Pump.LastError)" }
        }
    } catch {
        Write-UiLog "tick error: $($_.Exception.Message)"
    }
})

# NB $lifeTimer, not $life: PowerShell variable names are case-insensitive, so a $life
# here would BE $script:Life and the timer would silently clobber the watchdog state.
# Slow, cheap, and independent of the stream timer, which stops at EOF: the question
# "is the engine still there" outlives the question "is there anything left to read".
$lifeTimer = [System.Windows.Threading.DispatcherTimer]::new()
$lifeTimer.Interval = [TimeSpan]::FromMilliseconds(2000)
$lifeTimer.Add_Tick({
    try { Invoke-LifeTick } catch { Write-UiLog "life tick error: $($_.Exception.Message)" }
})

Set-Buttons 'running'
Update-Display
$win.Show()          # ShowActivated=False: appears without stealing keyboard focus
$timer.Start()
$lifeTimer.Start()

# Visible but not intrusive: top of the Z order, no focus change, never topmost.
try {
    if ($script:S.Hwnd -eq [IntPtr]::Zero) {
        $script:S.Hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($win)).Handle
    }
    $raised = [TranscribeIt.Ui.Native]::RaiseWithoutFocus($script:S.Hwnd)
    Write-UiLog "raised without focus: $raised"
} catch { Write-UiLog "raise failed: $($_.Exception.Message)" }

Write-UiLog 'window shown, dispatcher running'

try {
    [System.Windows.Threading.Dispatcher]::Run()
} finally {
    $timer.Stop()
    $lifeTimer.Stop()
    Write-UiLog "dispatcher stopped (events=$($script:S.Events) badLines=$($script:S.BadLines) phase=$($script:S.Phase))"
}

# The window may have been closed while the engine is still writing. Keep draining
# stdin so the engine's writes never block on a full pipe, then exit quietly. Only
# while the run is still live - after a terminal event there is nothing left to read.
# Only STDIN needs this: a full pipe would block the engine's next write. A tailed
# FILE has no pipe and nothing to unblock, so draining it was pure waiting - up to two
# hours of resident pwsh for a window the user had already closed. And even on stdin,
# once the engine is gone there is nobody left to unblock.
if ((-not $script:Pump.Eof) -and $script:S.Phase -eq 'running') {
    if ($script:InputMode -ne 'stdin') {
        $script:Pump.Stop()
        Write-UiLog 'window closed mid-run in file mode - nothing to drain, tail stopped'
    } else {
        $script:Pump.DiscardOnward()
        $deadline = (Get-Date).AddMinutes(120)
        $spin = 0
        while (-not $script:Pump.Eof -and (Get-Date) -lt $deadline) {
            $script:Pump.DiscardAll()
            # Every ~2 s, not every 250 ms: the pid lookup is the costly part here.
            if ((++$spin % 8) -eq 0 -and (Test-EngineGone)) {
                Write-UiLog 'engine gone - post-close drain stopped'
                break
            }
            Start-Sleep -Milliseconds 250
        }
        Write-UiLog "post-close drain finished (lines seen=$($script:Pump.LineCount))"
    }
}
Write-UiLog '--- progress UI exit ---'
