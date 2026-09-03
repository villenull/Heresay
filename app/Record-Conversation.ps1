#requires -Version 7
<#
.SYNOPSIS
    Records the conversation happening on this PC - system audio AND microphone -
    then saves an MP3 into Downloads and hands it to the transcription pipeline.

.DESCRIPTION
    Captures two independent WASAPI streams and writes each to its own WAV under
    %TEMP%, shows a small window that lives in the notification area while it runs,
    and on Stop mixes the two WAVs with ffmpeg, encodes an MP3 into the user's
    Downloads folder and hands that MP3 to app\Transcribe-Entry.ps1. The transcript
    PDF, the progress window and every error message downstream of the MP3 belong to
    the existing engine; nothing here reimplements any of it.

      WasapiLoopbackCapture(default RENDER endpoint)  -> sys.wav   (what you hear)
      WasapiCapture(chosen CAPTURE endpoint)          -> mic.wav   (what you say)
                              |
                    ffmpeg amix, 16 kHz mono          -> mixed.wav
                    ffmpeg libmp3lame, mono           -> Downloads\Conversation ....mp3
                              |
                    Transcribe-Entry.ps1 (quality from settings.json) -> ...transcript.pdf

    HALF A CONVERSATION BEATS NOTHING. Either leg may fail to start - no microphone
    plugged in, an exclusive-mode application holding the render endpoint - and the
    recording continues on whichever one works, saying so in the window. Only both
    legs failing aborts.

    A MUTED MICROPHONE IS NOT A FAILED ONE, which is why it gets its own treatment.
    WasapiCapture opens a muted endpoint without complaint and keeps delivering
    packets from it - measured: 3.7 MB over 9.8 s, every sample zero - so Start()
    succeeding says nothing about whether the microphone can hear anything, and
    without help the user finds out when the transcript comes back empty. So the
    endpoint's Mute flag is read up front and re-read on every tick, and when it is
    set the user is offered a button that clears it: once in a dialog before the
    recorder window appears, and thereafter in the recorder window itself, since
    mute is a keyboard key and can be pressed halfway through a call. Clearing Mute
    on a live capture takes effect immediately, so the button never has to restart
    the leg. Skipped under -TestSeconds, where no one is there to answer a dialog.

.PARAMETER MaxHours
    Safety cap. The window hides itself in the notification area, so a forgotten
    recorder is a real risk: at 48 kHz float stereo each leg costs about 23 MB per
    minute of WAV, so 4 hours of both legs is roughly 11 GB of temporary files.
    When the cap fires the recording is stopped and transcribed normally and the
    reason is shown in the window and written to the log. Default 4.

.PARAMETER Model
    OVERRIDE ONLY. Normally absent, and then the hand-off carries nothing but the
    MP3 path: Transcribe-Entry.ps1 picks the model and the speaker switch from the
    quality level the home window saved to settings.json, the same way it does for
    a right-clicked file, so a recording follows the same setting as everything
    else. When a Whisper model filename IS given here it is forwarded together with
    -NoDiarization, exactly as this recorder always did, and the saved setting is
    bypassed for this one recording. The recorder itself never reads the mapping;
    Transcribe-Entry.ps1 is its single home.

.PARAMETER OutputDirectory
    Where the MP3 goes. Default is the real Downloads known folder (see
    Get-DownloadsDirectory - Downloads can be relocated, so the profile path is
    the last resort, not the first choice). Exists so the tests can point at a
    scratch directory.

.PARAMETER FfmpegPath
    ffmpeg.exe. Default comes from config paths.ffmpeg, resolved the way the
    sibling app scripts resolve it. Exists so the tests can run without an install.

.PARAMETER NAudioDir
    Directory holding NAudio.Core.dll and NAudio.Wasapi.dll. Default
    <InstallRoot>\bin\naudio. Exists so the tests can run without an install.

.PARAMETER Mp3Kbps
    MP3 bitrate. Default 64, which is already generous for 16 kHz mono speech.

.PARAMETER MinFreeGB
    Refuse to start below this much free space on the temporary drive. Default 2.

.PARAMETER TestSeconds
    TEST HOOK. Auto-stop after this many seconds. 0 (default) = off.

.PARAMETER NoTranscribe
    TEST HOOK. Save the MP3 but log the hand-off command instead of running it.

.EXAMPLE
    wscript.exe app\Run-Hidden.vbs app\Record-Conversation.ps1

.EXAMPLE
    pwsh -NoProfile -File app\Record-Conversation.ps1 -MaxHours 1

.NOTES
    SPIKE FINDINGS, all measured on this machine. Do not rediscover them.

    * System audio needs NO admin, NO driver and NO Stereo Mix. NAudio's
      WasapiLoopbackCapture on MMDeviceEnumerator().GetDefaultAudioEndpoint(
      DataFlow.Render, Role.Multimedia) produced 2.4 MB in 5 s with real signal at
      -35 dB. THIS MACHINE HAS NO STEREO MIX DEVICE - do not try a dshow input for
      system audio, there is nothing for it to open.
    * The microphone starts from GetDefaultAudioEndpoint(DataFlow.Capture,
      Role.Communications), which picks the right one when no headset is paired (it
      selected "Microphone Array (2- Intel Smart Sound Technology...)" here). WITH A
      BLUETOOTH HEADSET PAIRED IT DOES NOT. Measured with JBL Vibe Buds 2: they
      expose "Headphones (JBL Vibe Buds 2)" (A2DP render, 48 kHz stereo) and
      "Headset (JBL Vibe Buds 2)" (hands-free capture, 16 kHz mono); Windows makes
      the Headset the default microphone, and opening it forces the earbuds out of
      stereo A2DP into hands-free mode for the whole recording - the user heard the
      call go flat. So RecordLeg.PickMicrophone applies one rule: when the default
      capture endpoint is Bluetooth and another active, non-Bluetooth capture
      endpoint exists, use that one and say so in DeviceNote; when the Bluetooth
      microphone is the only one, use it as before and say that instead.
      Detection basis, both read best-effort so a missing property can never stop
      a recording: PKEY_Device_EnumeratorName (a45c254e-df1c-4efd-8020-67d146a850e0,
      pid 24) reads "INTELAUDIO" / "HDAUDIO" for the built-in devices and starts
      with "BTH" for Bluetooth ("BTHENUM" for A2DP, "BTHHFENUM" for hands-free);
      PKEY_AudioEndpoint_FormFactor (1da5d803-d492-4edd-8c23-e0c0ffee7f0e, pid 0)
      is 5 = Headset for the hands-free endpoint. Either test marks an endpoint
      as Bluetooth.
    * Both endpoints deliver 32-bit IEEE float, 48000 Hz, 2 channels.
    * A POWERSHELL SCRIPTBLOCK ATTACHED TO A .NET EVENT NEVER FIRES while the main
      thread sleeps. $cap.add_DataAvailable({...}) captured 0 bytes. That is why the
      entire capture path - the event handlers, the WaveFileWriter, the counters -
      lives inside the Add-Type class below and PowerShell only calls Start/Stop and
      reads properties. Do not move any of it back out.
      (The WinForms NotifyIcon handlers below are NOT subject to this: they fire on
      the thread that owns the WPF Dispatcher, and Dispatcher.Run pumps the Win32
      messages that deliver them.)
    * Add-Type needs each NAudio DLL loaded with -Path FIRST and then passed again,
      with netstandard, in -ReferencedAssemblies. System.Threading.Thread is NOT
      available inside the Add-Type compile context (CS1069), so all sleeping and
      polling happens in PowerShell.
    * Mixing two live streams by hand is fragile. Two WAVs plus one proven ffmpeg
      amix afterwards is not.
    * MEASURED HERE, and the reason RecordLeg pads: WasapiLoopbackCapture delivers
      NO PACKETS AT ALL while nothing is rendering - a 3 s capture with the machine
      silent produced a 58-byte header-only WAV, not 3 s of zeros. Left alone that
      desynchronises the mix, because amix aligns both inputs at t=0: click record,
      join the call a minute later, and every word of system audio lands a minute
      early against the microphone. So each leg compares bytes written against
      wall-clock elapsed and pads the shortfall with silence.
    * ffmpeg's shipped LGPL build does have libmp3lame; app\Compress-ForWord.ps1
      already encodes MP3 with it.

    KNOWN LIMITATION: the ffmpeg mix and encode run on the UI thread, so the window
    is unresponsive while "Saving the recording" is displayed. Moving that work off
    the thread would mean marshalling progress back onto it for a wait that is a few
    seconds on a normal call, which is not worth the machinery.
#>
[CmdletBinding()]
param(
    [ValidateRange(0.05, 24)] [double] $MaxHours = 4,
    [string] $Model,
    [string] $OutputDirectory,
    [string] $FfmpegPath,
    [string] $NAudioDir,
    [ValidateRange(24, 320)] [int] $Mp3Kbps = 64,
    [ValidateRange(0, 1000)] [double] $MinFreeGB = 2,
    [ValidateRange(0, 86400)] [int] $TestSeconds = 0,
    [switch] $NoTranscribe,
    [string] $LogFile,
    [string] $AppName = 'Heresay'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. Paths and logging. Nothing in this section may throw: a recorder that dies
#    because it could not open its log file has destroyed a conversation.
# ---------------------------------------------------------------------------
$AppDir      = Split-Path -Parent $PSCommandPath
$InstallRoot = Split-Path -Parent $AppDir

$localAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = $env:TEMP }
$StateRoot = Join-Path $localAppData 'TranscribeIt'

$TempRoot = Join-Path $env:TEMP 'TranscribeIt'
$WorkDir  = Join-Path $TempRoot ('rec-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 12)))
$LockPath = Join-Path $TempRoot 'recorder.lock'

if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $StateRoot ('logs\record-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$script:LogOk = $false
try {
    $logDir = [System.IO.Path]::GetDirectoryName($LogFile)
    if ($logDir -and -not [System.IO.Directory]::Exists($logDir)) {
        [void][System.IO.Directory]::CreateDirectory($logDir)
    }
    $script:LogOk = $true
} catch { $script:LogOk = $false }

function Write-RecLog {
    param([string] $Message, [string] $Level = 'INFO')
    if (-not $script:LogOk) { return }
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine)
    } catch { }
}

# -Model is an override, so "was it given" matters more than its value: an absent or
# blank -Model means the hand-off carries only the path and Transcribe-Entry.ps1
# applies the saved quality setting. Decided once here because the hand-off in
# section 9 and the two log lines below must agree.
$script:ExplicitModel = ''
if ($PSBoundParameters.ContainsKey('Model') -and -not [string]::IsNullOrWhiteSpace($Model)) {
    $script:ExplicitModel = $Model.Trim()
}

Write-RecLog ("--- recorder start (pid=$PID maxHours=$MaxHours model={0} testSeconds=$TestSeconds) ---" -f
    $(if ($script:ExplicitModel) { "'$($script:ExplicitModel)' (explicit override)" } else { '(follows the saved quality setting)' }))

# Read-only peek at the quality the home window saved, so this log can be read against
# the user's belief. The recorder deliberately does NOT know what the level maps to:
# Transcribe-Entry.ps1 resolves it at hand-off and its entry.log records the result,
# and a second copy of the table here would be the one that goes stale. Never fatal,
# like everything else in this section: a broken settings file must not cost a
# conversation.
$qualityLine = 'quality setting: none saved (Transcribe-Entry applies its default at hand-off)'
try {
    $settingsPath = Join-Path $StateRoot 'settings.json'
    if ([System.IO.File]::Exists($settingsPath)) {
        $settings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
        $quality  = [string]$settings.quality
        if (-not [string]::IsNullOrWhiteSpace($quality)) {
            $qualityLine = "quality setting: $quality (from settings.json; resolved by Transcribe-Entry at hand-off)"
        }
    }
} catch { }
if ($script:ExplicitModel) {
    $qualityLine = "quality setting bypassed: -Model '$($script:ExplicitModel)' given, so the hand-off will pass -Model and -NoDiarization"
}
Write-RecLog $qualityLine

# The whole of section 9 depends on these existing before any early exit path can
# read them; Set-StrictMode -Version Latest throws on an unassigned variable and
# this tree has been bitten by that repeatedly.
$script:SysLeg        = $null
$script:MicLeg        = $null
$script:Recorder      = $null
$script:Finishing     = $false
$script:Finished      = $false
$script:AllowClose    = $false
$script:StopReason    = ''
$script:Mutex         = $null
$script:MutexOwned    = $false
$script:ShowEvent     = $null
$script:TrayIcon      = $null
$script:TrayHIcon     = [IntPtr]::Zero
$script:Started       = Get-Date
$script:Notice        = ''
$script:HandoffCmd    = ''
$script:SavedMp3      = ''

# ---------------------------------------------------------------------------
# 1. Fatal-error reporting. A GUI process launched through Run-Hidden.vbs has no
#    console, so an unreported failure is a silent one: every abort goes through
#    here and becomes a dialog.
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-RecMessage {
    param([string] $Text, [string] $Icon = 'Information')
    try {
        [void][System.Windows.Forms.MessageBox]::Show($Text, $AppName, 'OK', $Icon)
    } catch { }
}

function Stop-WithError {
    param([string] $Text, [string] $Detail = '')
    Write-RecLog "ABORT: $Text $(if ($Detail) { "| $Detail" })" 'ERROR'
    if ($script:LogOk) { $Text = $Text + "`n`nLog: $LogFile" }
    Show-RecMessage $Text 'Error'
    exit 1
}

# ---------------------------------------------------------------------------
# 2. One recorder at a time.
#
#    A named mutex, for the same reason Transcribe-Entry.ps1 uses one: the OS
#    releases it when the owning process dies, so a crashed recorder cannot lock
#    out the next one. The companion lock FILE is diagnostics only.
#
#    A second launch does not start a rival capture - it would fight the first for
#    the endpoints and produce two half recordings. Instead it sets a named event
#    that the live recorder polls, so the existing window comes back to the front
#    and the user sees the recording they already have. That is cheaper and far more
#    reliable than trying to find and raise another process's HWND.
# ---------------------------------------------------------------------------
$showEventName = 'Local\Heresay.Recorder.Show'
try {
    $createdNew = $false
    $script:Mutex = [System.Threading.Mutex]::new($false, 'Local\Heresay.Recorder', [ref]$createdNew)
    try {
        $script:MutexOwned = $script:Mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $script:MutexOwned = $true
        Write-RecLog 'recovered an abandoned recorder mutex (previous recorder died); taking over.' 'WARN'
    }
} catch {
    # No mutex means no guard, which is worse than a wrong guard: carry on rather
    # than refusing to record at all.
    Write-RecLog "could not create the recorder mutex ($($_.Exception.Message)); single-instance guard is off." 'WARN'
    $script:MutexOwned = $true
}

if (-not $script:MutexOwned) {
    $existing = ''
    try {
        if ([System.IO.File]::Exists($LockPath)) {
            $info = [System.IO.File]::ReadAllText($LockPath) | ConvertFrom-Json
            $existing = " (pid $($info.pid), started $($info.startedLocal))"
        }
    } catch { }
    Write-RecLog "another recorder already holds the lock$existing; surfacing its window and exiting."
    $signalled = $false
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting($showEventName)
        $signalled = $ev.Set()
        $ev.Dispose()
    } catch { Write-RecLog "could not signal the running recorder: $($_.Exception.Message)" 'WARN' }
    if (-not $signalled) {
        Show-RecMessage ('Heresay is already recording' + $existing +
            ".`n`nLook for the red recording icon in the notification area, next to the clock.") 'Information'
    }
    exit 0
}

try {
    if (-not [System.IO.Directory]::Exists($TempRoot)) { [void][System.IO.Directory]::CreateDirectory($TempRoot) }
    $script:ShowEvent = [System.Threading.EventWaitHandle]::new($false, 'AutoReset', $showEventName)
} catch {
    Write-RecLog "could not create the show-window event ($($_.Exception.Message)); a second launch will only show a dialog." 'WARN'
    $script:ShowEvent = $null
}

# ---------------------------------------------------------------------------
# 3. Preflight: disk, ffmpeg, NAudio. All three before a single byte is captured,
#    because discovering a missing ffmpeg after a 40-minute call is unforgivable.
# ---------------------------------------------------------------------------
try {
    if (-not [System.IO.Directory]::Exists($WorkDir)) { [void][System.IO.Directory]::CreateDirectory($WorkDir) }
} catch {
    Stop-WithError "Heresay could not create its temporary folder:`n`n$WorkDir" $_.Exception.Message
}

$freeGB = -1.0
try {
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($WorkDir))
    $freeGB = [math]::Round([System.IO.DriveInfo]::new($root).AvailableFreeSpace / 1GB, 2)
} catch { Write-RecLog "free space check skipped: $($_.Exception.Message)" 'WARN' }

if ($freeGB -ge 0 -and $freeGB -lt $MinFreeGB) {
    Stop-WithError ("There is not enough free disk space to record. Recording needs room for " +
        "about 2.7 GB per hour of temporary files, and only $freeGB GB is free.`n`n" +
        'Free some space and try again.') "free=$freeGB GB min=$MinFreeGB GB"
}
Write-RecLog ("temp work dir: $WorkDir (free {0} GB on the temp drive; a recording costs about 2.7 GB/hour here)" -f $freeGB)

function Get-InstalledConfig {
    <# Same order as the sibling app scripts: install root first, then the app dir,
       then the shipped defaults. An unreadable overlay is not fatal - the defaults
       carry the ffmpeg path this script needs. #>
    foreach ($cand in @((Join-Path $InstallRoot 'config.json'),
                        (Join-Path $AppDir 'config.json'),
                        (Join-Path $AppDir 'config.default.json'))) {
        if (Test-Path -LiteralPath $cand) {
            try { return (Get-Content -LiteralPath $cand -Raw -Encoding UTF8 | ConvertFrom-Json) }
            catch { Write-RecLog "unreadable config '$cand': $($_.Exception.Message)" 'WARN' }
        }
    }
    return $null
}

function Resolve-Ffmpeg {
    <# The relative path in config is written for the development tree
       (vendor\ffmpeg\ffmpeg.exe) and the installer lays it down at
       bin\ffmpeg\ffmpeg.exe, so try both layouts exactly as Transcribe.ps1 does
       rather than depend on the installer rewriting the config. #>
    if (-not [string]::IsNullOrWhiteSpace($FfmpegPath)) { return $FfmpegPath }

    $rel = 'vendor/ffmpeg/ffmpeg.exe'
    $cfg = Get-InstalledConfig
    if ($null -ne $cfg -and
        $cfg.PSObject.Properties.Name -contains 'paths' -and
        $cfg.paths.PSObject.Properties.Name -contains 'ffmpeg') {
        $rel = [string]$cfg.paths.ffmpeg
    }
    $rel = $rel -replace '/', '\'
    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel }

    $cands = [System.Collections.Generic.List[string]]::new()
    $cands.Add($rel)
    if ($rel -like 'vendor\*') {
        $tail = $rel.Substring(7)
        $cands.Add("bin\$tail")
        $cands.Add($tail)
    } else {
        $cands.Add("vendor\$rel")
        $cands.Add("bin\$rel")
    }
    foreach ($base in @($InstallRoot, $AppDir)) {
        foreach ($c in $cands) {
            $p = Join-Path $base $c
            if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).ProviderPath }
        }
    }
    return (Join-Path $InstallRoot $rel)
}

$FFMPEG = Resolve-Ffmpeg
if (-not (Test-Path -LiteralPath $FFMPEG -PathType Leaf)) {
    Stop-WithError ("Heresay is not installed correctly - the audio converter is missing:`n`n$FFMPEG`n`n" +
        'Please re-run the installer.') 'ffmpeg not found'
}
Write-RecLog "ffmpeg: $FFMPEG"

# Both layouts, for the same reason Resolve-Ffmpeg tries both: the installer lays the
# DLLs down at bin\naudio (the manifest's extract target) while the development tree
# keeps vendored binaries under vendor\. Without the second candidate the recorder works
# only on an install, and fails in the dev tree with a "not installed correctly" message
# that is actively misleading to whoever is developing it.
if ([string]::IsNullOrWhiteSpace($NAudioDir)) {
    $naudioRoot = $null
    foreach ($base in @($InstallRoot, $AppDir)) {
        foreach ($leaf in @('bin\naudio', 'vendor\naudio')) {
            $cand = Join-Path $base $leaf
            if (Test-Path -LiteralPath (Join-Path $cand 'NAudio.Wasapi.dll') -PathType Leaf) { $naudioRoot = $cand; break }
        }
        if ($naudioRoot) { break }
    }
    if (-not $naudioRoot) { $naudioRoot = Join-Path $InstallRoot 'bin\naudio' }
} else {
    $naudioRoot = $NAudioDir
}
$naudioCore   = Join-Path $naudioRoot 'NAudio.Core.dll'
$naudioWasapi = Join-Path $naudioRoot 'NAudio.Wasapi.dll'
foreach ($dll in @($naudioCore, $naudioWasapi)) {
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        Stop-WithError ("Heresay is not installed correctly - the audio recording component is missing:`n`n$dll`n`n" +
            'Please re-run the installer.') 'NAudio not found'
    }
}
Write-RecLog "naudio: $naudioRoot"

# ---------------------------------------------------------------------------
# 4. Native helpers: the real Downloads folder, and freeing the tray HICON.
# ---------------------------------------------------------------------------
if (-not ('Heresay.Rec.Native' -as [Type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Heresay.Rec
{
    public static class Native
    {
        // FOLDERID_Downloads. The registry value under User Shell Folders is the
        // fallback, but this is the authority - it is what Explorer itself asks.
        private static readonly Guid FolderIdDownloads =
            new Guid("374DE290-123F-4565-9164-39C4925E467B");

        [DllImport("shell32.dll")]
        private static extern int SHGetKnownFolderPath(
            [MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint dwFlags, IntPtr hToken,
            out IntPtr ppszPath);

        public static string GetDownloadsPath()
        {
            IntPtr p = IntPtr.Zero;
            try
            {
                if (SHGetKnownFolderPath(FolderIdDownloads, 0, IntPtr.Zero, out p) != 0) { return null; }
                return Marshal.PtrToStringUni(p);
            }
            catch { return null; }
            finally { if (p != IntPtr.Zero) { Marshal.FreeCoTaskMem(p); } }
        }

        // Bitmap.GetHicon() hands out a handle the caller owns. One leaked icon for
        // the life of a process is nothing, but the recorder's process life is a
        // whole meeting, so it gets freed properly.
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("shell32.dll", ExactSpelling = true)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string appId);
    }
}
'@
}

function Get-DownloadsDirectory {
    <# Downloads can be relocated - onto another drive, into OneDrive - so the
       profile path is the last resort rather than the answer. #>
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        try {
            if (-not [System.IO.Directory]::Exists($OutputDirectory)) {
                [void][System.IO.Directory]::CreateDirectory($OutputDirectory)
            }
            return (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
        } catch {
            Write-RecLog "unusable -OutputDirectory '$OutputDirectory': $($_.Exception.Message)" 'WARN'
        }
    }

    $known = $null
    try { $known = [Heresay.Rec.Native]::GetDownloadsPath() } catch { }
    if (-not [string]::IsNullOrWhiteSpace($known) -and [System.IO.Directory]::Exists($known)) {
        Write-RecLog "downloads folder from SHGetKnownFolderPath: $known"
        return $known
    }

    try {
        $raw = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' `
                                     -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$raw)
        if (-not [string]::IsNullOrWhiteSpace($expanded) -and [System.IO.Directory]::Exists($expanded)) {
            Write-RecLog "downloads folder from User Shell Folders: $expanded"
            return $expanded
        }
    } catch { }

    $fallback = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    try { if (-not [System.IO.Directory]::Exists($fallback)) { [void][System.IO.Directory]::CreateDirectory($fallback) } } catch { }
    Write-RecLog "downloads folder fell back to the profile path: $fallback" 'WARN'
    return $fallback
}

function Get-UniquePath {
    <# " (2)", " (3)" ... exactly as Explorer would, so two recordings in the same
       minute cannot silently overwrite each other. #>
    param([string] $Directory, [string] $BaseName, [string] $Extension)
    $candidate = Join-Path $Directory ($BaseName + $Extension)
    $n = 2
    while ([System.IO.File]::Exists($candidate) -and $n -lt 1000) {
        $candidate = Join-Path $Directory ('{0} ({1}){2}' -f $BaseName, $n, $Extension)
        $n++
    }
    return $candidate
}

# ---------------------------------------------------------------------------
# 5. The capture engine.
#
#    EVERYTHING to do with capture is in here on purpose. See .NOTES: a PowerShell
#    scriptblock attached to DataAvailable never fires while the main thread is
#    asleep, and the first attempt captured 0 bytes because of it. PowerShell below
#    only calls Start/Stop/Cleanup and reads properties.
# ---------------------------------------------------------------------------
Add-Type -Path $naudioCore
Add-Type -Path $naudioWasapi
$netstandard = [System.Reflection.Assembly]::Load(
    'netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location

$recorderSource = @'
using System;
using NAudio.Wave;
using NAudio.CoreAudioApi;

namespace Heresay.Rec
{
    /// <summary>
    /// One capture endpoint writing one WAV. Loopback and microphone differ only in
    /// which endpoint they open, so they share this class.
    ///
    /// No lock anywhere: each leg has its own capture thread and its own writer, and
    /// NAudio stops delivering DataAvailable before it raises RecordingStopped, so
    /// the writer is only ever touched by one thread at a time. (System.Threading is
    /// mostly unavailable in the Add-Type compile context anyway - CS1069.)
    /// </summary>
    public class RecordLeg
    {
        private IWaveIn _cap;
        private WaveFileWriter _writer;
        private volatile bool _stopping;
        private volatile bool _done;
        private DateTime _t0;
        private int _bytesPerSecond;
        private long _bytes;
        private long _padded;
        private MMDevice _dev;

        public string Name = "";
        public string Device = "";
        public string Format = "";
        public string Error = "";
        public string WavPath = "";

        /// <summary>
        /// The endpoint reported Mute=True when the leg opened. MEASURED and the
        /// reason this exists: a muted microphone does NOT fail to open and does
        /// NOT stop delivering packets - WasapiCapture happily produced 3.7 MB
        /// over 9.8 s, every sample zero (ffmpeg volumedetect max_volume -91.0 dB).
        /// So Start() returning true says nothing about whether the microphone can
        /// hear anything, and the user finds out only when the transcript comes
        /// back empty. Read the flag up front instead and tell them while they can
        /// still do something about it.
        /// </summary>
        public bool Muted = false;

        /// <summary>
        /// Why the microphone leg opened the endpoint it did, in words fit for the
        /// log, or empty when the default endpoint was simply used. Set by
        /// PickMicrophone; the loopback leg never sets it.
        /// </summary>
        public string DeviceNote = "";

        // PKEY_Device_EnumeratorName: the bus that enumerated the device. MEASURED
        // here: "INTELAUDIO" and "HDAUDIO" for the built-in devices, "BTHENUM" for the
        // earbuds' A2DP (stereo render) endpoint and "BTHHFENUM" for their hands-free
        // (16 kHz mono capture) endpoint. Anything starting with "BTH" is Bluetooth.
        private static readonly PropertyKey EnumeratorNameKey =
            new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 24);

        // PKEY_AudioEndpoint_FormFactor. 5 is EndpointFormFactor.Headset, which is
        // what a Bluetooth hands-free capture endpoint reports; it is the second
        // test so a stack that hides its enumerator name is still caught.
        private static readonly PropertyKey FormFactorKey =
            new PropertyKey(new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e"), 0);
        private const int FormFactorHeadset = 5;

        /// <summary>
        /// True when the endpoint looks like a Bluetooth headset. Every property read
        /// is best-effort: a device that lacks either property is treated as not
        /// Bluetooth, because a missing property must never stop a recording.
        /// </summary>
        private static bool IsBluetooth(MMDevice d)
        {
            try
            {
                if (d.Properties.Contains(EnumeratorNameKey))
                {
                    string bus = d.Properties[EnumeratorNameKey].Value as string;
                    if (bus != null && bus.StartsWith("BTH", StringComparison.OrdinalIgnoreCase)) { return true; }
                }
            }
            catch { }
            try
            {
                if (d.Properties.Contains(FormFactorKey))
                {
                    object ff = d.Properties[FormFactorKey].Value;
                    if (ff != null && Convert.ToInt32(ff) == FormFactorHeadset) { return true; }
                }
            }
            catch { }
            return false;
        }

        /// <summary>
        /// The microphone to record from. The default communications endpoint, unless
        /// it is a Bluetooth headset and another active, non-Bluetooth microphone
        /// exists, in which case that one.
        ///
        /// MEASURED and the reason this exists: Windows makes a paired headset the
        /// default microphone, and opening its hands-free capture endpoint forces the
        /// headset out of stereo A2DP into hands-free mode for the whole recording -
        /// the user heard the call go flat. The laptop's own microphone array records
        /// the user just as well and leaves the headset alone. When the headset is the
        /// only microphone it is used as before, and the note says so, so that a flat
        /// sounding call has an explanation in the log.
        /// </summary>
        public static MMDevice PickMicrophone(MMDeviceEnumerator e, out string note)
        {
            note = "";
            MMDevice def = e.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            if (!IsBluetooth(def)) { return def; }

            MMDevice other = null;
            try
            {
                foreach (MMDevice d in e.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
                {
                    if (d.ID == def.ID || IsBluetooth(d)) { continue; }
                    other = d;
                    break;
                }
            }
            catch { other = null; }

            if (other == null)
            {
                note = "the default microphone '" + def.FriendlyName + "' is a Bluetooth headset and no other " +
                       "microphone is available, so it is used anyway; the headset will be in hands-free " +
                       "mode, which sounds flat, for the length of the recording";
                return def;
            }
            note = "the default microphone '" + def.FriendlyName + "' is a Bluetooth headset; using '" +
                   other.FriendlyName + "' instead so the headset stays in stereo mode";
            return other;
        }

        /// <summary>Audio bytes delivered by the device, excluding padded silence.</summary>
        public long Bytes { get { return _bytes; } }
        /// <summary>Silence written to keep this WAV aligned to the wall clock.</summary>
        public long PaddedBytes { get { return _padded; } }
        public int BytesPerSecond { get { return _bytesPerSecond; } }
        public bool Done { get { return _done; } }
        public bool Started { get { return _bytesPerSecond > 0; } }

        /// <summary>Seconds of real audio captured, ignoring padding.</summary>
        public double AudioSeconds
        {
            get { return _bytesPerSecond > 0 ? (double)_bytes / _bytesPerSecond : 0.0; }
        }

        public bool Start(string name, bool loopback, string wavPath)
        {
            Name = name;
            WavPath = wavPath;
            try
            {
                MMDeviceEnumerator enumerator = new MMDeviceEnumerator();
                string note = "";
                MMDevice device = loopback
                    ? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
                    : PickMicrophone(enumerator, out note);
                DeviceNote = note;
                Device = device.FriendlyName;
                // _dev is the device actually opened, so IsMuted() and Unmute() below act
                // on the microphone that is recording, not on the default one.
                _dev = device;
                // Best-effort: not every endpoint exposes a volume interface, and a
                // missing mute flag must never stop a recording from starting.
                try { Muted = device.AudioEndpointVolume.Mute; } catch { Muted = false; }

                _cap = loopback
                    ? (IWaveIn)new WasapiLoopbackCapture(device)
                    : (IWaveIn)new WasapiCapture(device);

                WaveFormat wf = _cap.WaveFormat;
                _bytesPerSecond = wf.AverageBytesPerSecond;
                Format = string.Format("{0} Hz, {1} ch, {2}-bit {3}",
                    wf.SampleRate, wf.Channels, wf.BitsPerSample, wf.Encoding);

                _writer = new WaveFileWriter(wavPath, wf);
                _cap.DataAvailable += OnDataAvailable;
                _cap.RecordingStopped += OnRecordingStopped;
                _t0 = DateTime.UtcNow;
                _cap.StartRecording();
                return true;
            }
            catch (Exception ex)
            {
                Error = ex.GetType().Name + ": " + ex.Message;
                Cleanup();
                return false;
            }
        }

        /// <summary>
        /// Write enough zeros to bring this WAV up to <paramref name="upToSeconds"/>
        /// of wall clock, less whatever the next packet is about to add.
        ///
        /// MEASURED: loopback capture delivers NOTHING while nothing is rendering, so
        /// without this a recording started before the call joined would be shorter
        /// than the microphone's and amix - which aligns both inputs at t=0 - would
        /// play the system audio early by the length of the gap. The threshold keeps
        /// ordinary packet jitter from being mistaken for a gap.
        /// </summary>
        private void PadTo(double upToSeconds, int excludeBytes)
        {
            WaveFileWriter w = _writer;
            if (w == null || _bytesPerSecond <= 0) { return; }
            long expected = (long)(upToSeconds * _bytesPerSecond);
            long have = _bytes + _padded + excludeBytes;
            long gap = expected - have;
            if (gap < _bytesPerSecond / 5) { return; }        // under 200 ms: jitter, not a gap

            // Whole frames only, or the WAV's channel interleave would shift.
            int blockAlign = w.WaveFormat.BlockAlign;
            if (blockAlign > 0) { gap -= gap % blockAlign; }
            if (gap <= 0) { return; }

            byte[] silence = new byte[Math.Min(gap, 65536)];
            long remaining = gap;
            while (remaining > 0)
            {
                int chunk = (int)Math.Min(remaining, silence.Length);
                w.Write(silence, 0, chunk);
                remaining -= chunk;
            }
            _padded += gap;
        }

        private void OnDataAvailable(object sender, WaveInEventArgs e)
        {
            if (_stopping) { return; }
            try
            {
                WaveFileWriter w = _writer;
                if (w == null) { return; }
                PadTo((DateTime.UtcNow - _t0).TotalSeconds, e.BytesRecorded);
                w.Write(e.Buffer, 0, e.BytesRecorded);
                _bytes += e.BytesRecorded;
            }
            catch (Exception ex)
            {
                // A failed write means this leg is finished - a full disk, most
                // likely. Stop it rather than spin, and let the other leg carry on.
                Error = "write failed: " + ex.Message;
                _stopping = true;
                try { if (_cap != null) { _cap.StopRecording(); } } catch { }
            }
        }

        private void OnRecordingStopped(object sender, StoppedEventArgs e)
        {
            if (e != null && e.Exception != null)
            {
                Error = "capture stopped: " + e.Exception.Message;
            }
            Cleanup();
        }

        public void Stop()
        {
            if (_stopping) { return; }
            _stopping = true;
            try
            {
                // Trailing silence counts too: it keeps the saved MP3 the length of
                // the meeting instead of the length of the last thing that made noise.
                PadTo((DateTime.UtcNow - _t0).TotalSeconds, 0);
            }
            catch { }
            try { if (_cap != null) { _cap.StopRecording(); } }
            catch (Exception ex) { Error = "stop failed: " + ex.Message; Cleanup(); }
        }

        /// <summary>
        /// Read the endpoint's mute flag NOW instead of trusting the reading taken at
        /// Start(). On most laptops mute is a keyboard key - F4 on this fleet - so it can
        /// be pressed at any point in a two-hour call, and a recording that went silent
        /// thirty seconds in is indistinguishable afterwards from one that was silent all
        /// along. Best-effort by design: an endpoint with no volume interface reports "not
        /// muted" rather than derailing a recording that is otherwise healthy.
        /// </summary>
        public bool IsMuted()
        {
            MMDevice d = _dev;
            if (d == null) { return false; }
            try { return d.AudioEndpointVolume.Mute; } catch { return false; }
        }

        /// <summary>
        /// Clear the mute flag. Returns true only after reading the endpoint back, so the
        /// caller can tell the user what actually happened rather than assuming the click
        /// worked - a managed endpoint can expose the property and ignore writes to it.
        ///
        /// The level rescue is deliberate, not scope creep: unmuting a microphone whose
        /// level sits at zero produces exactly the silent recording the button was pressed
        /// to prevent, and the user has no way to tell the two apart. Only a level that is
        /// effectively off is touched, it is reported through RaisedLevelFrom so the caller
        /// can say so out loud, and any level the user has actually chosen is left alone.
        /// </summary>
        public bool Unmute()
        {
            MMDevice d = _dev;
            if (d == null) { UnmuteError = "this microphone did not expose a volume control"; return false; }
            try
            {
                d.AudioEndpointVolume.Mute = false;
                if (d.AudioEndpointVolume.MasterVolumeLevelScalar < 0.05f)
                {
                    RaisedLevelFrom = d.AudioEndpointVolume.MasterVolumeLevelScalar;
                    d.AudioEndpointVolume.MasterVolumeLevelScalar = 0.6f;
                }
                Muted = d.AudioEndpointVolume.Mute;
                return !Muted;
            }
            catch (Exception ex)
            {
                UnmuteError = ex.GetType().Name + ": " + ex.Message;
                return false;
            }
        }

        /// <summary>Why Unmute() failed. Separate from Error, which reports capture faults.</summary>
        public string UnmuteError = "";

        /// <summary>The level Unmute() found and raised, or -1 if it left the level alone.</summary>
        public float RaisedLevelFrom = -1f;

        /// <summary>Idempotent; called from RecordingStopped and again from PowerShell.</summary>
        public void Cleanup()
        {
            _stopping = true;
            WaveFileWriter w = _writer; _writer = null;
            try { if (w != null) { w.Flush(); w.Dispose(); } } catch { }
            IWaveIn c = _cap; _cap = null;
            try { if (c != null) { c.Dispose(); } } catch { }
            _done = true;
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $recorderSource -ReferencedAssemblies $naudioCore, $naudioWasapi, $netstandard
} catch {
    Stop-WithError ("Heresay could not start its audio recorder on this computer.`n`n" +
        'Please send the log file to IT.') $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 6. Start capturing. This happens BEFORE the window is built: the user already
#    chose to record by clicking the menu item, and the first seconds of a
#    conversation are the ones with the introductions in them.
# ---------------------------------------------------------------------------
$SysWav   = Join-Path $WorkDir 'sys.wav'
$MicWav   = Join-Path $WorkDir 'mic.wav'
$MixedWav = Join-Path $WorkDir 'mixed.wav'

$script:SysLeg = [Heresay.Rec.RecordLeg]::new()
$script:MicLeg = [Heresay.Rec.RecordLeg]::new()

$sysOk = $script:SysLeg.Start('system audio', $true,  $SysWav)
$micOk = $script:MicLeg.Start('microphone',   $false, $MicWav)
$script:Started = Get-Date

Write-RecLog ("system audio: ok=$sysOk device='$($script:SysLeg.Device)' format='$($script:SysLeg.Format)'" +
              $(if ($script:SysLeg.Error) { " error='$($script:SysLeg.Error)'" } else { '' }))
Write-RecLog ("microphone:   ok=$micOk muted=$($script:MicLeg.Muted) device='$($script:MicLeg.Device)' format='$($script:MicLeg.Format)'" +
              $(if ($script:MicLeg.Error) { " error='$($script:MicLeg.Error)'" } else { '' }))
# INFO, not WARN: choosing the laptop microphone over a Bluetooth headset is the
# recorder working as designed, and the line is here so a flat-sounding or
# unexpectedly quiet recording can be read against which microphone was open.
if (-not [string]::IsNullOrWhiteSpace($script:MicLeg.DeviceNote)) {
    Write-RecLog "microphone choice: $($script:MicLeg.DeviceNote)"
}

if (-not $sysOk -and -not $micOk) {
    try { [System.IO.Directory]::Delete($WorkDir, $true) } catch { }
    Stop-WithError ("Heresay could not record any audio on this computer. Neither the sound " +
        "coming out of the speakers nor the microphone could be opened.`n`n" +
        "Check that a microphone is connected and that Windows sound settings are working, then try again.") `
        "sys='$($script:SysLeg.Error)' mic='$($script:MicLeg.Error)'"
}

# Half a conversation beats nothing, but the user must know which half they have.
# A muted microphone counts as a missing half even though its leg opened fine, so
# it is reported here alongside the two legs that failed outright.
$micMuted = $micOk -and $script:MicLeg.Muted
if ($micMuted) { Write-RecLog 'microphone endpoint reports Mute=True; only system audio will have content.' 'WARN' }
# The muted case deliberately sets no text here. It is the one problem the user can
# fix without stopping, so it gets a live notice and a button further down instead of
# a line of advice that would be wrong the moment they press the button.
$script:Notice = ''
if ($micMuted -and -not $sysOk) {
    Write-RecLog 'nothing will be captured yet: system audio failed and the microphone is muted.' 'WARN'
} elseif (-not $sysOk) {
    $script:Notice = 'Only your microphone is being recorded - the sound from this computer could not be captured.'
    Write-RecLog 'continuing with the microphone only.' 'WARN'
} elseif (-not $micOk) {
    $script:Notice = 'Only this computer''s sound is being recorded - the microphone could not be opened.'
    Write-RecLog 'continuing with system audio only.' 'WARN'
}

try {
    $lockBody = [pscustomobject]@{
        pid          = $PID
        startedUtc   = $script:Started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        startedLocal = $script:Started.ToString('yyyy-MM-dd HH:mm:ss')
        workDir      = $WorkDir
        log          = $LogFile
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($LockPath, $lockBody, [System.Text.UTF8Encoding]::new($false))
} catch { Write-RecLog "could not write the lock file '$LockPath': $($_.Exception.Message)" 'WARN' }

# ---------------------------------------------------------------------------
# 7. The window. Same design language as app\Progress.ps1: Segoe UI Variable Text,
#    #FFF6F6F6 on #FF1A1A1A with the #FF0067C0 accent, runtime-drawn icon, and an
#    explicit AppUserModelID so the taskbar button is the app and not pwsh.
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# The taskbar files windows under the host exe's AppUserModelID unless told
# otherwise, which would show the PowerShell icon whatever $win.Icon says. Must be
# set before the HWND exists. A failure costs the icon and nothing else.
try {
    $hr = [Heresay.Rec.Native]::SetCurrentProcessExplicitAppUserModelID('Heresay.TranscribeIt.Recorder')
    if ($hr -ne 0) { Write-RecLog ('SetCurrentProcessExplicitAppUserModelID returned 0x{0:X8}' -f $hr) 'WARN' }
} catch { Write-RecLog "AppUserModelID failed - taskbar keeps the pwsh icon: $($_.Exception.Message)" 'WARN' }

# Built from code points so this file stays pure ASCII, as Progress.ps1 does.
$G = @{
    Dash = [string][char]0x2013   # en dash
    Dot  = [string][char]0x00B7   # middle dot
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Heresay" Width="420" SizeToContent="Height"
        WindowStartupLocation="Manual" ResizeMode="CanMinimize"
        ShowInTaskbar="True"
        Background="#FFF6F6F6" Foreground="#FF1A1A1A"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent"    Color="#FF0067C0"/>
    <SolidColorBrush x:Key="AccentDim" Color="#FF1975C5"/>
    <SolidColorBrush x:Key="Muted"     Color="#FF5F5F5F"/>
    <SolidColorBrush x:Key="Faint"     Color="#FF767676"/>
    <SolidColorBrush x:Key="Danger"    Color="#FFC42B1C"/>
    <SolidColorBrush x:Key="Warn"      Color="#FF8A5300"/>

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
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#FFBFD8ED"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFBFD8ED"/>
                <Setter Property="Foreground" Value="#FFF0F0F0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="16,14,16,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- 0 headline + red dot -->
      <RowDefinition Height="Auto"/>   <!-- 1 elapsed            -->
      <RowDefinition Height="Auto"/>   <!-- 2 sources            -->
      <RowDefinition Height="Auto"/>   <!-- 3 notice             -->
      <RowDefinition Height="Auto"/>   <!-- 4 tray hint          -->
      <RowDefinition Height="Auto"/>   <!-- 5 buttons            -->
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Orientation="Horizontal">
      <Ellipse x:Name="Dot" Width="10" Height="10" Fill="{StaticResource Danger}"
               VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBlock x:Name="TbHead" FontSize="13" FontWeight="SemiBold"
                 VerticalAlignment="Center" Text="Recording this conversation"/>
    </StackPanel>

    <TextBlock x:Name="TbElapsed" Grid.Row="1" Margin="18,6,0,0" FontSize="22"
               Text="00:00"/>

    <TextBlock x:Name="TbSources" Grid.Row="2" Margin="18,6,0,0" FontSize="11"
               TextWrapping="Wrap" Foreground="{StaticResource Muted}" Text="Starting"/>

    <StackPanel Grid.Row="3" Margin="18,8,0,0">
      <TextBlock x:Name="TbNotice" FontSize="11"
                 TextWrapping="Wrap" Foreground="{StaticResource Warn}" Visibility="Collapsed"/>
      <Button x:Name="BtnUnmute" Content="Unmute my microphone" Style="{StaticResource AccentButton}"
              HorizontalAlignment="Left" Margin="0,8,0,0" Visibility="Collapsed"/>
    </StackPanel>

    <TextBlock x:Name="TbTray" Grid.Row="4" Margin="18,10,0,0" FontSize="11"
               TextWrapping="Wrap" Foreground="{StaticResource Faint}"
               Text="Closing this window keeps the recording going. Find it again on the red icon in the notification area, next to the clock."/>

    <StackPanel Grid.Row="5" Margin="0,14,0,0" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnCancel" Content="Cancel (discard)"/>
      <Button x:Name="BtnStop" Content="Stop and transcribe" Style="{StaticResource AccentButton}"/>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
$win = [System.Windows.Markup.XamlReader]::Load($reader)
$win.Title = $AppName

$UI = @{
    Win       = $win
    Dot       = $win.FindName('Dot')
    TbHead    = $win.FindName('TbHead')
    TbElapsed = $win.FindName('TbElapsed')
    TbSources = $win.FindName('TbSources')
    TbNotice  = $win.FindName('TbNotice')
    BtnUnmute = $win.FindName('BtnUnmute')
    TbTray    = $win.FindName('TbTray')
    BtnStop   = $win.FindName('BtnStop')
    BtnCancel = $win.FindName('BtnCancel')
}

# Bottom-right of the work area, out of the way. Height is SizeToContent, so
# $win.Height is NaN until first layout and Top has to come from ActualHeight in a
# SizeChanged handler - same reasoning, and same bug avoided, as Progress.ps1.
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
} catch { $win.WindowStartupLocation = 'CenterScreen' }

function New-MediaColor([string] $hex) {
    return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}

function New-IconBitmap([scriptblock] $draw, [int] $size = 64) {
    $visual = [System.Windows.Media.DrawingVisual]::new()
    $dc = $visual.RenderOpen()
    try { $null = & $draw $dc $size } finally { $dc.Close() }
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)
    $rtb.Freeze()
    return $rtb
}

# Drawn at runtime so this file ships no binary asset: the app's slate tile with a
# red record dot on it. Carries no lettering, so it survives a rename.
$appIcon = New-IconBitmap {
    param($dc, $size)
    $s = $size / 32.0
    $ink = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FF12333F'))
    $red = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FFC42B1C'))
    $rim = [System.Windows.Media.Pen]::new(
        [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FFFFFFFF')), (1.6 * $s))
    $dc.DrawRoundedRectangle($ink, $null,
        [System.Windows.Rect]::new(0, 0, $size, $size), (7.0 * $s), (7.0 * $s))
    $dc.DrawEllipse($red, $rim, [System.Windows.Point]::new((16.0 * $s), (16.0 * $s)), (8.6 * $s), (8.6 * $s))
} 64
try { $win.Icon = $appIcon } catch { Write-RecLog "window icon failed: $($_.Exception.Message)" 'WARN' }

# ---------------------------------------------------------------------------
# 7b. Notification area.
#
#     NotifyIcon is WinForms, which is fine here: it creates its message window on
#     the thread that constructs it, and that thread is the one running the WPF
#     Dispatcher, so Dispatcher.Run pumps the messages that deliver its events.
#     (This is why the tray handlers CAN be PowerShell scriptblocks while the
#     capture handlers cannot - see .NOTES.)
#
#     The icon is drawn with System.Drawing rather than reused from $appIcon
#     because NotifyIcon wants a System.Drawing.Icon, and Bitmap.GetHicon is the
#     only route to one without shipping a .ico file. A red dot inside a white ring
#     reads on both a light and a dark taskbar.
# ---------------------------------------------------------------------------
function New-TrayIcon {
    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)
            $ring = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
            $red  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 196, 43, 28))
            try {
                $g.FillEllipse($ring, 2, 2, 28, 28)
                $g.FillEllipse($red,  6, 6, 20, 20)
            } finally { $ring.Dispose(); $red.Dispose() }
        } finally { $g.Dispose() }
        $script:TrayHIcon = $bmp.GetHicon()
        return [System.Drawing.Icon]::FromHandle($script:TrayHIcon)
    } finally { $bmp.Dispose() }
}

$script:TrayIcon = [System.Windows.Forms.NotifyIcon]::new()
try {
    $script:TrayIcon.Icon = New-TrayIcon
} catch {
    Write-RecLog "could not draw the tray icon ($($_.Exception.Message)); using the system default." 'WARN'
    try { $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application } catch { }
}
$script:TrayIcon.Text = "$AppName - recording 00:00"
$script:TrayIcon.Visible = $true

# ---------------------------------------------------------------------------
# 8. Window state, elapsed clock and the tray menu
# ---------------------------------------------------------------------------
function Format-Elapsed([TimeSpan] $span) {
    # Floor, not a cast: PowerShell's [int] rounds to nearest, so 46 s displayed as
    # 01:46 and 1 h 40 min as 2:40:00 (seen in real logs). Only whole units belong here.
    if ($span.TotalHours -ge 1) {
        return ('{0}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
    }
    return ('{0:00}:{1:00}' -f [Math]::Floor($span.TotalMinutes), $span.Seconds)
}

function Show-RecorderWindow {
    try {
        $win.Show()
        if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
        [void]$win.Activate()
        [void]$win.Focus()
    } catch { Write-RecLog "could not restore the window: $($_.Exception.Message)" 'WARN' }
}

function Hide-ToTray {
    <# Hiding must never stop the capture: the legs are not touched here. #>
    try {
        $win.Hide()
        Write-RecLog 'window hidden to the notification area; recording continues.'
    } catch { Write-RecLog "could not hide the window: $($_.Exception.Message)" 'WARN' }
}

function Set-SourcesText {
    $parts = @()
    if ($script:SysLeg.Started) {
        $parts += ('This computer''s sound {0} {1}' -f $G.Dash, $script:SysLeg.Device)
    }
    if ($script:MicLeg.Started) {
        $parts += ('Microphone {0} {1}' -f $G.Dash, $script:MicLeg.Device)
    }
    if (@($parts).Count -eq 0) { $parts = @('No audio source') }
    $UI.TbSources.Text = ($parts -join [Environment]::NewLine)
}

Set-SourcesText

# ---------------------------------------------------------------------------
#    The muted microphone, and the one button that fixes it.
#
#    MEASURED, and the reason this is a live poll rather than one reading taken at
#    the start: on 2026-09-02 a 41-minute recording began with the endpoint
#    reporting Mute=True, the user unmuted it about 8 seconds in, and the remaining
#    2,455 seconds captured normally - 6,910 words of transcript. The mute flag is
#    a snapshot of something the user can flip with one keystroke at any moment,
#    in either direction, so it has to be re-read.
#
#    That same recording settled the other open question: clearing Mute on a LIVE
#    WasapiCapture takes effect immediately, so the button below does not have to
#    tear the leg down and start it again - which would have cost the seconds it
#    takes to reopen the endpoint, in the middle of a conversation.
# ---------------------------------------------------------------------------
$script:MuteShown = $false

function Invoke-Unmute {
    <#
      Clear the mute flag and report whether it actually cleared. Never throws:
      this runs from a click handler and from the one-second tick, and a failure
      here must not be allowed to end a recording that is otherwise healthy.
    #>
    if ($null -eq $script:MicLeg) { return $false }
    $ok = $false
    try { $ok = $script:MicLeg.Unmute() }
    catch { Write-RecLog "unmute threw: $($_.Exception.Message)" 'WARN'; return $false }
    if ($ok) {
        Write-RecLog 'the microphone was unmuted at the user''s request.'
        if ($script:MicLeg.RaisedLevelFrom -ge 0) {
            $lvl = [int][Math]::Round($script:MicLeg.RaisedLevelFrom * 100)
            Write-RecLog "the microphone level was $lvl% - effectively off - so it was raised to 60%." 'WARN'
        }
    } else {
        Write-RecLog "could not unmute the microphone: $($script:MicLeg.UnmuteError)" 'WARN'
    }
    return $ok
}

function Set-MuteNotice {
    # Two situations, and the difference matters: with system audio working the user
    # is still capturing the other side of the call, without it they have nothing.
    $UI.TbNotice.Text = if ($sysOk) {
        'Your microphone is muted, so your own voice is not being recorded. Press the button and Heresay will unmute it - everything from that moment on includes your voice.'
    } else {
        'Your microphone is muted and this computer''s sound could not be captured either, so nothing at all is being recorded. Press the button and Heresay will unmute the microphone.'
    }
    $UI.TbNotice.Visibility  = 'Visible'
    $UI.BtnUnmute.IsEnabled  = $true
    $UI.BtnUnmute.Visibility = 'Visible'
}

function Clear-MuteNotice {
    param([string] $Text = 'Your microphone is on. Everything from here on includes your voice.')
    $UI.BtnUnmute.Visibility = 'Collapsed'
    $UI.TbNotice.Text        = $Text
    $UI.TbNotice.Visibility  = 'Visible'
}

function Show-MuteDialog {
    <#
      The unmissable version of the notice, shown once at start-up, because a muted
      microphone at start-up is a question and not just news: fix it now, or record
      knowing your own voice is missing. The passive corner notice is not enough on
      its own - it is what shipped first, and the recording it warned about still
      came back with an empty transcript.

      Buttons rather than a MessageBox, because a MessageBox cannot do the unmuting.
      The look comes out of the recorder window's own resource dictionary so there
      is one copy of it in this file and not two to drift apart.
    #>
    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="470" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="False" Topmost="True"
        WindowStyle="SingleBorderWindow"
        Background="#FFF6F6F6" Foreground="#FF1A1A1A"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Grid Margin="18,16,18,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="DlgHead" Grid.Row="0" FontSize="14" FontWeight="SemiBold"
               TextWrapping="Wrap" Text="Your microphone is muted"/>
    <TextBlock x:Name="DlgBody" Grid.Row="1" Margin="0,10,0,0" FontSize="12"
               TextWrapping="Wrap"/>
    <StackPanel Grid.Row="2" Margin="0,18,0,0"
                Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="DlgSkip"   Content="Record without my voice"/>
      <Button x:Name="DlgUnmute" Content="Unmute and record"/>
    </StackPanel>
  </Grid>
</Window>
'@
    try {
        $dlg = [System.Windows.Markup.XamlReader]::Load(
            [System.Xml.XmlNodeReader]::new(([xml]$dlgXaml)))
    } catch {
        # No dialog is survivable - the corner notice and the button are still there.
        Write-RecLog "could not build the muted-microphone dialog: $($_.Exception.Message)" 'WARN'
        return
    }
    $dlg.Title = $AppName
    try { $dlg.Icon = $win.Icon } catch { }

    $dHead   = $dlg.FindName('DlgHead')
    $dBody   = $dlg.FindName('DlgBody')
    $dSkip   = $dlg.FindName('DlgSkip')
    $dUnmute = $dlg.FindName('DlgUnmute')

    # Borrowed, not copied. A failure here costs the styling and nothing else.
    try {
        $dlg.Resources = $win.Resources
        $dSkip.Style   = $win.Resources[[System.Windows.Controls.Button]]
        $dUnmute.Style = $win.FindResource('AccentButton')
    } catch {
        Write-RecLog "the muted-microphone dialog kept the default button look: $($_.Exception.Message)" 'WARN'
    }

    $dBody.Text = if ($sysOk) {
        'Heresay has started recording, but Windows reports your microphone as muted - so your own voice is not going into the recording, only the sound coming out of this computer.'
    } else {
        'Heresay has started recording, but Windows reports your microphone as muted and the sound from this computer could not be captured either, so nothing at all is going into the recording yet.'
    }

    $dUnmute.Add_Click({
        $dUnmute.IsEnabled = $false
        if (Invoke-Unmute) {
            $script:MuteShown = $false
            $dlg.Tag = 'unmuted'
            $dlg.Close()
        } else {
            # Tell them how to do it by hand rather than leaving a dead button.
            $dHead.Text = 'Windows would not unmute it'
            $dBody.Text = 'Heresay was not allowed to change the microphone setting on this computer. Unmute it yourself - on many laptops that is the F4 key, or right-click the speaker icon next to the clock and open Sound settings. The recording is already running and will pick your voice up the moment the microphone is on.'
            $dSkip.Content = 'Close'
            $dUnmute.Visibility = 'Collapsed'
        }
    })
    $dSkip.Add_Click({ $dlg.Close() })

    Write-RecLog 'the microphone is muted; asking before the recording goes any further.'
    [void]$dlg.ShowDialog()
    if ($dlg.Tag -eq 'unmuted') {
        $msg = 'Your microphone is on. Everything from here on includes your voice.'
        if ($script:MicLeg.RaisedLevelFrom -ge 0) {
            $msg = 'Your microphone is on, and its level was turned up from almost nothing. Everything from here on includes your voice.'
        }
        Clear-MuteNotice $msg
    } else {
        Write-RecLog 'the user chose to carry on recording with the microphone muted.' 'WARN'
    }
}

$UI.BtnUnmute.Add_Click({
    $UI.BtnUnmute.IsEnabled = $false
    if (Invoke-Unmute) {
        $script:MuteShown = $false
        $msg = 'Your microphone is on. Everything from here on includes your voice.'
        if ($script:MicLeg.RaisedLevelFrom -ge 0) {
            $msg = 'Your microphone is on, and its level was turned up from almost nothing. Everything from here on includes your voice.'
        }
        Clear-MuteNotice $msg
    } else {
        $UI.TbNotice.Text = 'Windows would not let Heresay unmute the microphone. Unmute it yourself - on many laptops that is the F4 key, or right-click the speaker icon next to the clock and open Sound settings. The recording is still running.'
        $UI.BtnUnmute.IsEnabled = $true
    }
})

if ($micMuted) {
    $script:MuteShown = $true
    Set-MuteNotice
} elseif ($script:Notice) {
    $UI.TbNotice.Text = $script:Notice
    $UI.TbNotice.Visibility = 'Visible'
}


# ---------------------------------------------------------------------------
# 9. Finishing: mix, encode, hand off. Called by Stop, by the safety cap and by
#    the test hook; Cancel takes the discard path instead.
# ---------------------------------------------------------------------------
function Invoke-Ffmpeg {
    <# ProcessStartInfo rather than the call operator: CreateNoWindow guarantees no
       console flash from a process that was itself started hidden, and stderr is
       wanted in the log when ffmpeg refuses. #>
    param([string[]] $Arguments, [string] $Tag)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FFMPEG
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.WorkingDirectory       = [System.IO.Path]::GetDirectoryName($FFMPEG)

    Write-RecLog "$Tag EXEC ffmpeg $($Arguments -join ' ')" 'DEBUG'
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    [void]$p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $code = $p.ExitCode
    $stderr = ''
    try { $stderr = $errTask.GetAwaiter().GetResult() } catch { }
    $p.Dispose()
    if ($code -ne 0) {
        $tail = (($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 4) -join ' | ')
        Write-RecLog "$Tag exit=$code stderr: $tail" 'ERROR'
    }
    return $code
}

function Get-UsableLeg {
    <# A leg that started but produced less than a second of real audio has nothing
       in it. That is the normal state of loopback capture on a silent machine
       (MEASURED: a header-only 58-byte WAV), so it is not an error - it just must
       not be handed to amix, which would weight a silent input equally. #>
    param($Leg)
    if ($null -eq $Leg -or -not $Leg.Started) { return $false }
    if (-not [System.IO.File]::Exists($Leg.WavPath)) { return $false }
    return ($Leg.AudioSeconds -ge 1.0)
}

function Stop-Capture {
    foreach ($leg in @($script:SysLeg, $script:MicLeg)) {
        try { $leg.Stop() } catch { Write-RecLog "stop '$($leg.Name)' threw: $($_.Exception.Message)" 'WARN' }
    }
    # NAudio raises RecordingStopped on its own thread, and the WAV header is only
    # correct once the writer has been disposed there. Poll rather than assume; the
    # forced Cleanup below is the backstop for a leg that never gets there.
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if ($script:SysLeg.Done -and $script:MicLeg.Done) { break }
        Start-Sleep -Milliseconds 100
    }
    foreach ($leg in @($script:SysLeg, $script:MicLeg)) {
        try { $leg.Cleanup() } catch { }
        Write-RecLog ("captured '{0}': {1} bytes audio ({2:N1}s) + {3} bytes padded silence{4}" -f
            $leg.Name, $leg.Bytes, $leg.AudioSeconds, $leg.PaddedBytes,
            $(if ($leg.Error) { " error='$($leg.Error)'" } else { '' }))
    }
}

function Remove-WorkDir {
    try {
        if ([System.IO.Directory]::Exists($WorkDir)) {
            [System.IO.Directory]::Delete($WorkDir, $true)
            Write-RecLog "removed temporary files: $WorkDir"
        }
    } catch { Write-RecLog "could not remove '$WorkDir': $($_.Exception.Message)" 'WARN' }
}

function Remove-LockFile {
    try { if ([System.IO.File]::Exists($LockPath)) { [System.IO.File]::Delete($LockPath) } } catch { }
}

function Close-Recorder {
    $script:AllowClose = $true
    try { if ($null -ne $script:TrayIcon) { $script:TrayIcon.Visible = $false } } catch { }
    try { $win.Close() } catch { }
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
}

function Set-BusyState([string] $Headline, [string] $Detail) {
    $UI.TbHead.Text = $Headline
    $UI.TbSources.Text = $Detail
    $UI.Dot.Fill = $win.FindResource('Accent')
    $UI.BtnStop.IsEnabled = $false
    $UI.BtnCancel.IsEnabled = $false
    Show-RecorderWindow
    # Force a repaint before the synchronous ffmpeg work starts. See the KNOWN
    # LIMITATION in .NOTES: the window freezes during the mix, so it had better be
    # frozen showing the right words.
    try {
        $win.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{ })
    } catch { }
}

function Complete-Recording {
    param([string] $Reason)
    if ($script:Finishing -or $script:Finished) { return }
    $script:Finishing = $true
    $script:StopReason = $Reason
    $elapsed = (Get-Date) - $script:Started
    Write-RecLog ("stopping after {0} - reason: {1}" -f (Format-Elapsed $elapsed), $Reason)

    Set-BusyState 'Saving the recording' 'Mixing the audio - this takes a moment.'

    try {
        Stop-Capture

        $legs = @(@($script:SysLeg, $script:MicLeg) | Where-Object { Get-UsableLeg $_ })
        if (@($legs).Count -eq 0) {
            Write-RecLog 'nothing was captured; there is no recording to save.' 'ERROR'
            $script:Finished = $true
            Remove-WorkDir
            Show-RecMessage ("Nothing was recorded. No sound reached Heresay from either the " +
                "microphone or this computer's speakers, so there is nothing to transcribe.`n`n" +
                "Log: $LogFile") 'Warning'
            Close-Recorder
            return
        }

        # The PROVEN mix command; do not reshape it. With one usable leg amix has
        # nothing to mix, so the same resample/downmix is done without it.
        if (@($legs).Count -eq 2) {
            $mixArgs = @(
                '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
                '-i', $script:SysLeg.WavPath,
                '-i', $script:MicLeg.WavPath,
                '-filter_complex', '[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0[a]',
                '-map', '[a]',
                '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', $MixedWav)
            Write-RecLog 'mixing both sources.'
        } else {
            $only = @($legs)[0]
            $mixArgs = @(
                '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
                '-i', $only.WavPath,
                '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', $MixedWav)
            Write-RecLog "only '$($only.Name)' has usable audio; no mix needed."
        }

        if ((Invoke-Ffmpeg -Arguments $mixArgs -Tag 'mix') -ne 0 -or
            -not [System.IO.File]::Exists($MixedWav)) {
            throw 'the two audio streams could not be combined'
        }
        $mixedLen = ([System.IO.FileInfo]::new($MixedWav)).Length
        Write-RecLog ('mixed.wav: {0} bytes, {1:N1}s of 16 kHz mono' -f $mixedLen, (($mixedLen - 44) / 32000.0))
        if ($mixedLen -le 1024) { throw 'the combined audio is empty' }

        $outDir  = Get-DownloadsDirectory
        $baseName = 'Conversation {0}' -f $script:Started.ToString('yyyy-MM-dd HH-mm')
        $mp3 = Get-UniquePath -Directory $outDir -BaseName $baseName -Extension '.mp3'

        # Mono at the source rate: whisper wants 16 kHz mono anyway, so resampling
        # up for the sake of the MP3 and back down for the engine would only add
        # loss. Same shape of encode as Compress-ForWord.ps1.
        $mp3Args = @(
            '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
            '-i', $MixedWav, '-vn', '-ac', '1', '-c:a', 'libmp3lame',
            '-b:a', ('{0}k' -f $Mp3Kbps), $mp3)
        if ((Invoke-Ffmpeg -Arguments $mp3Args -Tag 'mp3') -ne 0 -or
            -not [System.IO.File]::Exists($mp3)) {
            throw 'the recording could not be converted to MP3'
        }
        $mp3Len = ([System.IO.FileInfo]::new($mp3)).Length
        Write-RecLog ('saved: {0} ({1:N1} MB, {2} kbps mono; wav was {3:N1} MB)' -f
            $mp3, ($mp3Len / 1MB), $Mp3Kbps, ($mixedLen / 1MB))
        $script:SavedMp3 = $mp3

        # Hand off exactly as the right-click verb does: through Run-Hidden.vbs, so no
        # console appears, and to Transcribe-Entry.ps1, which owns the queue lock,
        # the engine and the progress window. The PDF lands beside the MP3. Only the
        # path is passed, so the model and the speaker switch come from the quality
        # level the home window saved, resolved by the entry point - unless the user
        # gave -Model, which is forwarded with -NoDiarization as this script always did.
        $entry  = Join-Path $AppDir 'Transcribe-Entry.ps1'
        $hidden = Join-Path $AppDir 'Run-Hidden.vbs'
        $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $handoffArgs = @($hidden, $entry, '-Path', $mp3)
        if ($script:ExplicitModel) { $handoffArgs += @('-Model', $script:ExplicitModel, '-NoDiarization') }
        $script:HandoffCmd = ('"{0}" {1}' -f $wscript,
            (($handoffArgs | ForEach-Object { '"{0}"' -f $_ }) -join ' '))

        if ($NoTranscribe) {
            Write-RecLog "-NoTranscribe: hand-off NOT run. Command would be: $($script:HandoffCmd)"
        } elseif (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
            Write-RecLog "hand-off skipped - launcher missing: $entry" 'ERROR'
            Show-RecMessage ("The recording was saved to:`n`n$mp3`n`nBut Heresay could not start the " +
                "transcription because part of the installation is missing. You can still transcribe " +
                'it: right-click the MP3 and choose "Transcribe in PDF" (you may need "Show more ' +
                'options" first). If that entry is missing too, re-run the installer.') 'Warning'
        } else {
            Write-RecLog "hand-off: $($script:HandoffCmd)"
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $wscript
            foreach ($a in $handoffArgs) { [void]$psi.ArgumentList.Add([string]$a) }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow  = $true
            [void][System.Diagnostics.Process]::Start($psi)
            Write-RecLog 'transcription started; the engine owns the progress window from here.'
        }

        $script:Finished = $true
    }
    catch {
        $script:Finished = $true
        Write-RecLog "FAILED to save the recording: $($_.Exception.Message)" 'ERROR'
        # The raw WAVs are the only copy of the conversation, so they are NOT deleted
        # on this path - a failed mix must not also destroy the recording.
        Show-RecMessage ("Heresay recorded the conversation but could not save it: " +
            "$($_.Exception.Message).`n`nThe raw recording is still here, so nothing is lost:`n`n" +
            "$WorkDir`n`nLog: $LogFile") 'Error'
        Remove-LockFile
        Close-Recorder
        return
    }

    Remove-WorkDir
    Remove-LockFile
    Close-Recorder
}

function Cancel-Recording {
    <# Destroys the recording, so it asks first. #>
    if ($script:Finishing -or $script:Finished) { return }
    $answer = 'Yes'
    try {
        $answer = [string][System.Windows.Forms.MessageBox]::Show(
            ('Discard this recording?' + [Environment]::NewLine + [Environment]::NewLine +
             'The last ' + (Format-Elapsed ((Get-Date) - $script:Started)) +
             ' will be deleted and nothing will be transcribed. This cannot be undone.'),
            $AppName, 'YesNo', 'Warning')
    } catch { }
    if ($answer -ne 'Yes') {
        Write-RecLog 'cancel declined at the confirmation; still recording.'
        return
    }

    $script:Finishing = $true
    Write-RecLog ('cancelled by the user after {0}; discarding.' -f (Format-Elapsed ((Get-Date) - $script:Started)))
    Set-BusyState 'Discarding the recording' 'Deleting the temporary files.'
    Stop-Capture
    $script:Finished = $true
    Remove-WorkDir
    Remove-LockFile
    Close-Recorder
}

# ---------------------------------------------------------------------------
# 10. Wiring
# ---------------------------------------------------------------------------
$UI.BtnStop.Add_Click({ Complete-Recording -Reason 'the Stop and transcribe button' })
$UI.BtnCancel.Add_Click({ Cancel-Recording })

# The X is minimise, not stop. Losing a meeting to a misread button is the failure
# this whole tool exists to avoid, so the only two ways to end a recording are the
# two labelled buttons (and the safety cap).
$win.add_Closing({
    param($s, $e)
    if (-not $script:AllowClose) {
        $e.Cancel = $true
        Hide-ToTray
    }
})
$win.add_StateChanged({
    if ($win.WindowState -eq 'Minimized' -and -not $script:AllowClose) { Hide-ToTray }
})

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$miShow = $menu.Items.Add('Show the recorder')
$miShow.add_Click({ Show-RecorderWindow })
[void]$menu.Items.Add('-')
$miStop = $menu.Items.Add('Stop and transcribe')
$miStop.add_Click({ Complete-Recording -Reason 'the notification-area menu' })
$miCancel = $menu.Items.Add('Cancel recording')
$miCancel.add_Click({ Cancel-Recording })
$script:TrayIcon.ContextMenuStrip = $menu

# Left click and double click both restore. Left click alone is what most people
# try first; MouseClick fires for the right button too, so the button is checked.
$script:TrayIcon.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-RecorderWindow }
})
$script:TrayIcon.add_MouseDoubleClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-RecorderWindow }
})

# ---------------------------------------------------------------------------
# 11. The one-second tick: elapsed clock, tray tooltip, safety cap, second-launch
#     signal, and a leg that has died since it started.
# ---------------------------------------------------------------------------
$script:MaxSeconds  = [int][Math]::Round($MaxHours * 3600)
$script:LoggedLegs  = @{}
$script:Ticker = [System.Windows.Threading.DispatcherTimer]::new()
$script:Ticker.Interval = [TimeSpan]::FromSeconds(1)
$script:Ticker.Add_Tick({
    try {
        if ($script:Finishing -or $script:Finished) { return }
        $elapsed = (Get-Date) - $script:Started
        $text = Format-Elapsed $elapsed
        $UI.TbElapsed.Text = $text
        try { $script:TrayIcon.Text = "$AppName - recording $text" } catch { }

        # A second launch asks for this window instead of starting a rival capture.
        if ($null -ne $script:ShowEvent -and $script:ShowEvent.WaitOne(0)) {
            Write-RecLog 'a second launch asked for this window; restoring it.'
            Show-RecorderWindow
        }

        # A leg that stopped on its own - device unplugged, disk full. Report it once.
        foreach ($leg in @($script:SysLeg, $script:MicLeg)) {
            if ($leg.Started -and $leg.Done -and -not $script:LoggedLegs.ContainsKey($leg.Name)) {
                $script:LoggedLegs[$leg.Name] = $true
                Write-RecLog "'$($leg.Name)' stopped on its own after $text : $($leg.Error)" 'WARN'
                $UI.TbNotice.Text = "The $($leg.Name) stopped part way through. Everything up to that point is still being recorded."
                $UI.TbNotice.Visibility = 'Visible'
            }
        }

        # Mute is a keyboard key, so it can be pressed - or released - at any point
        # in a call. $script:MuteShown is the last state the window was told about,
        # so this reports the change and not the state: once, rather than every
        # second for two hours.
        if ($micOk -and -not $script:MicLeg.Done) {
            $nowMuted = $script:MicLeg.IsMuted()
            if ($nowMuted -ne $script:MuteShown) {
                $script:MuteShown = $nowMuted
                if ($nowMuted) {
                    Write-RecLog "the microphone was muted $text into the recording." 'WARN'
                    Set-MuteNotice
                    # A balloon and not a forced window: this can land in the middle
                    # of a screen share, and the tray icon is where they already look.
                    try {
                        $script:TrayIcon.ShowBalloonTip(10000,
                            "$AppName $($G.Dash) microphone muted",
                            'Your voice is not being recorded. Open Heresay and press Unmute my microphone.',
                            [System.Windows.Forms.ToolTipIcon]::Warning)
                    } catch { }
                } else {
                    Write-RecLog "the microphone is no longer muted, $text in."
                    Clear-MuteNotice
                }
            }
        }

        if ($TestSeconds -gt 0 -and $elapsed.TotalSeconds -ge $TestSeconds) {
            Complete-Recording -Reason "-TestSeconds $TestSeconds"
            return
        }
        if ($elapsed.TotalSeconds -ge $script:MaxSeconds) {
            $UI.TbNotice.Text = "Recording reached the $MaxHours-hour limit and stopped by itself."
            $UI.TbNotice.Visibility = 'Visible'
            Write-RecLog "SAFETY CAP: reached the $MaxHours-hour limit; stopping and transcribing." 'WARN'
            Complete-Recording -Reason "the $MaxHours-hour safety limit"
        }
    } catch {
        Write-RecLog "tick error: $($_.Exception.Message)" 'WARN'
    }
})

# ---------------------------------------------------------------------------
# 12. Run. The finally block is the guarantee that no capture, no HICON and no
#     lock file outlives this process, whatever happens above.
# ---------------------------------------------------------------------------
try {
    # Before the recorder window rather than after: a muted microphone at start-up is
    # a question, and this is the one moment the user is certainly still looking at
    # the screen. Skipped under -TestSeconds, where nobody is there to answer and a
    # modal dialog would hang the automated run until the safety cap.
    if ($micMuted) {
        if ($TestSeconds -gt 0) {
            Write-RecLog 'the microphone is muted; skipping the dialog because -TestSeconds is set.' 'WARN'
        } else {
            Show-MuteDialog
        }
    }
    $win.Show()
    $script:Ticker.Start()
    Write-RecLog 'window shown, dispatcher running.'
    [System.Windows.Threading.Dispatcher]::Run()
}
finally {
    try { $script:Ticker.Stop() } catch { }
    foreach ($leg in @($script:SysLeg, $script:MicLeg)) {
        if ($null -ne $leg) { try { $leg.Cleanup() } catch { } }
    }
    if (-not $script:Finished) {
        # Reached only if the dispatcher ended without Stop or Cancel - a crash, or
        # a logoff. The WAVs stay: they are the conversation.
        Write-RecLog 'dispatcher ended without a stop or a cancel; leaving the raw audio in place.' 'WARN'
        Write-RecLog "raw audio: $WorkDir"
    }
    try { if ($null -ne $script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } } catch { }
    if ($script:TrayHIcon -ne [IntPtr]::Zero) {
        try { [void][Heresay.Rec.Native]::DestroyIcon($script:TrayHIcon) } catch { }
    }
    Remove-LockFile
    try { if ($script:MutexOwned -and $null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() } } catch { }
    try { if ($null -ne $script:Mutex) { $script:Mutex.Dispose() } } catch { }
    try { if ($null -ne $script:ShowEvent) { $script:ShowEvent.Dispose() } } catch { }
    Write-RecLog "--- recorder end (saved='$($script:SavedMp3)' reason='$($script:StopReason)') ---"
}
