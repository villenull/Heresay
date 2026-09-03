#requires -Version 7
<#
.SYNOPSIS
    The Heresay home window: the one Start Menu entry. Choose a transcription
    quality, record a new conversation, pick recordings to transcribe, or remove
    Heresay from the computer.

.DESCRIPTION
    Before this window existed the Start Menu entry launched the recorder outright,
    which made "open Heresay" and "start recording" the same gesture. This window
    separates them. It is deliberately small and does nothing itself: both buttons
    hand off to the scripts the Explorer right-click entries already run, through
    the same console-free launcher, and then close this window.

      Transcribe new conversation -> wscript Run-Hidden.vbs Record-Conversation.ps1
      Transcribe a file...        -> wscript Run-Hidden.vbs Transcribe-Entry.ps1 -Path <file>
                                     once per selected file; Transcribe-Entry's queue
                                     coalesces them into one batch exactly as it does
                                     when Explorer starts one copy per selected item.
      Uninstall Heresay           -> a Yes/No confirmation, then a detached hidden pwsh
                                     that runs <InstallRoot>\Uninstall-TranscribeIt.ps1
                                     -Quiet and reports the outcome in a message box.

    The quality choice is saved the moment it is clicked to
    %LOCALAPPDATA%\TranscribeIt\settings.json as
    { "quality": "fastest" | "moderate" | "thorough", "updatedUtc": "<ISO 8601>" }.

    THE QUALITY DESCRIPTIONS ARE A CONTRACT. Transcribe-Entry.ps1 and the recorder read
    the setting and map each level to an engine configuration; this window only stores
    it. The words under each option state that mapping (which model, whether speakers
    are told apart, roughly how fast) so the user can choose without knowing model
    names. If the mapping changes, the text here must change with it, or the window
    will promise something the engine no longer does.

    Reading the settings file never fails loudly: a missing, empty or corrupt file
    means "fastest", because a home window that will not open over a bad JSON file
    would lock the user out of both buttons for the sake of one radio button.
    "fastest" is also what Heresay did before the levels existed, so a user who
    never touches the radios gets exactly the behaviour they had.

    WHY THE UNINSTALL IS A DETACHED PROCESS THAT WAITS. The uninstaller deletes the
    install root, and this window's own pwsh may hold that root as its working
    directory or have app\ scripts open. Running the uninstaller from inside this
    process would therefore either fail on a locked directory or delete files from
    under the process that is running. So the click starts a separate hidden pwsh
    whose working directory is %TEMP%, which waits for this window's PID to exit,
    then runs the uninstaller and shows the result. This window closes right after
    the launch so the wait is short. The launch survives this process exiting
    because a child process started with ProcessStartInfo is not tied to its parent.

.PARAMETER InstallRoot
    The install root, the directory that holds app\ and bin\. Default is the parent
    of the directory this script lives in, which is right for an installed copy and
    for a checkout alike.

.PARAMETER SettingsPath
    Where the quality choice is stored. Default %LOCALAPPDATA%\TranscribeIt\settings.json.
    Exists so the tests can point at a scratch file.

.PARAMETER LogFile
    Where this window writes its few log lines. Default
    %LOCALAPPDATA%\TranscribeIt\logs\home-<timestamp>.log, beside the recorder's.

.PARAMETER SelfTest
    TEST HOOK. Build the window without showing it, check that every named element
    resolves, exercise the settings read and write paths against -SettingsPath (a
    temporary file when none is given), exercise the three launch paths with
    -DryRunLaunch forced on, print PASS/FAIL lines and exit 0 or 1. The uninstall
    path is exercised with the confirmation dialog replaced by scriptblocks that
    answer No and Yes, so no message box ever opens and nothing is uninstalled.

.PARAMETER DryRunLaunch
    TEST HOOK. Log the exact command line a button would run instead of starting
    wscript or the uninstall helper. Starting the recorder from a test would record
    for real; starting the uninstaller would remove the install.

.EXAMPLE
    wscript.exe app\Run-Hidden.vbs app\Heresay-Home.ps1

.EXAMPLE
    pwsh -NoProfile -File app\Heresay-Home.ps1 -SelfTest -SettingsPath $env:TEMP\heresay-settings.json

.NOTES
    * The launch pattern (wscript.exe + Run-Hidden.vbs, every argument passed as its
      own ArgumentList entry) is copied from the recorder's hand-off, which is the
      one known to work. Run-Hidden.vbs re-quotes each argument itself, so paths with
      spaces survive without any quoting here.
    * The look is the resource dictionary from Progress.ps1: same brushes, same
      Button and AccentButton templates. The RadioButton template is new, because
      neither sibling window has one, and follows the same flat palette.
    * The taskbar files a window under its host exe's AppUserModelID unless told
      otherwise, so without SetCurrentProcessExplicitAppUserModelID the taskbar
      button would show the PowerShell icon whatever $win.Icon says. Same fix as the
      progress window and the recorder, with its own ID so the three do not group.
    * Non-ASCII glyphs are built from code points so this file stays pure ASCII and
      is not at the mercy of a BOM, as in Progress.ps1.
#>
[CmdletBinding()]
param(
    [string] $InstallRoot,
    [string] $SettingsPath,
    [string] $LogFile,
    [switch] $SelfTest,
    [switch] $DryRunLaunch,
    [string] $AppName = 'Heresay'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. Paths and logging. Nothing in this section may throw: a home window that dies
#    before it appears leaves the user with a Start Menu entry that does nothing.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Split-Path -Parent $PSScriptRoot   # app\ -> install root
}
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$AppDir      = Join-Path $InstallRoot 'app'

$localAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = $env:TEMP }
$StateRoot = Join-Path $localAppData 'TranscribeIt'

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $StateRoot 'settings.json'
}
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $StateRoot ('logs\home-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$script:LogOk = $false
try {
    $logDir = [System.IO.Path]::GetDirectoryName($LogFile)
    if ($logDir -and -not [System.IO.Directory]::Exists($logDir)) {
        [void][System.IO.Directory]::CreateDirectory($logDir)
    }
    $script:LogOk = $true
} catch { $script:LogOk = $false }

function Write-HomeLog {
    param([string] $Message, [string] $Level = 'INFO')
    if (-not $script:LogOk) { return }
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine)
    } catch { }
}

Write-HomeLog "--- home start (pid=$PID installRoot='$InstallRoot' settings='$SettingsPath' selfTest=$SelfTest dryRun=$DryRunLaunch) ---"

# ---------------------------------------------------------------------------
# 1. The quality setting. Three values, one default, and a reader that treats
#    every kind of bad file as "no choice made yet".
# ---------------------------------------------------------------------------
$script:QualityLevels  = @('fastest', 'moderate', 'thorough')
$script:DefaultQuality = 'fastest'

function Get-QualitySetting {
    <# Never throws. Missing, empty, malformed, or holding an unknown value all
       come back as the default: the window must open whatever is in that file. #>
    param([string] $Path = $SettingsPath)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $script:DefaultQuality }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $script:DefaultQuality }
        $json = $raw | ConvertFrom-Json
        if ($null -eq $json -or -not ($json.PSObject.Properties.Name -contains 'quality')) {
            return $script:DefaultQuality
        }
        $value = ([string]$json.quality).Trim().ToLowerInvariant()
        if ($script:QualityLevels -contains $value) { return $value }
        Write-HomeLog "settings.json holds unknown quality '$value'; using '$($script:DefaultQuality)'." 'WARN'
        return $script:DefaultQuality
    } catch {
        Write-HomeLog "settings.json unreadable ($($_.Exception.Message)); using '$($script:DefaultQuality)'." 'WARN'
        return $script:DefaultQuality
    }
}

function Save-QualitySetting {
    <# Returns $true on success. The whole file is rewritten: it holds this one
       setting, so there is nothing to merge and no partial state to preserve. #>
    param([Parameter(Mandatory)][string] $Quality, [string] $Path = $SettingsPath)
    if ($script:QualityLevels -notcontains $Quality) { throw "unknown quality '$Quality'" }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
        $body = [ordered]@{
            quality    = $Quality
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json
        [System.IO.File]::WriteAllText($Path, $body + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        Write-HomeLog "setting changed: quality=$Quality"
        return $true
    } catch {
        Write-HomeLog "could not save quality=$Quality to '$Path': $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
# 2. Launching. One function, one pattern, copied from the recorder's hand-off.
# ---------------------------------------------------------------------------
function Get-LaunchCommand {
    <# Builds the launch as a list (what ProcessStartInfo wants) and as the quoted
       one-line form (what the log and the dry run show). Both come from the same
       list so the logged command is the command. #>
    param([Parameter(Mandatory)][string] $ScriptName, [string[]] $Arguments = @())
    $target  = Join-Path $AppDir $ScriptName
    $hidden  = Join-Path $AppDir 'Run-Hidden.vbs'
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $list    = @($hidden, $target) + @($Arguments)
    return [pscustomobject]@{
        Wscript = $wscript
        Target  = $target
        Hidden  = $hidden
        List    = $list
        Text    = ('"{0}" {1}' -f $wscript, (($list | ForEach-Object { '"{0}"' -f $_ }) -join ' '))
    }
}

function Start-HeresayScript {
    <# Starts <AppDir>\<ScriptName> with no console through Run-Hidden.vbs, exactly
       as the Explorer verbs do. Throws when part of the install is missing so the
       caller can tell the user instead of failing silently. Returns the command
       line that was (or under -DryRunLaunch would have been) run. #>
    param([Parameter(Mandatory)][string] $ScriptName, [string[]] $Arguments = @())
    $cmd = Get-LaunchCommand -ScriptName $ScriptName -Arguments $Arguments
    foreach ($p in @($cmd.Hidden, $cmd.Target)) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            throw "part of the installation is missing: $p"
        }
    }
    if ($DryRunLaunch) {
        Write-HomeLog "-DryRunLaunch: NOT started. Command would be: $($cmd.Text)"
        return $cmd.Text
    }
    Write-HomeLog "launched $ScriptName`: $($cmd.Text)"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $cmd.Wscript
    foreach ($a in $cmd.List) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    [void][System.Diagnostics.Process]::Start($psi)
    return $cmd.Text
}

# ---------------------------------------------------------------------------
# 2b. Uninstalling. The uninstaller is a console script that deletes the install
#     root, so it cannot run inside this process (see the header). A detached pwsh
#     waits for this PID, runs it, and reports in a message box of its own.
# ---------------------------------------------------------------------------
function Get-UninstallerPath {
    <# The installer stages Uninstall-TranscribeIt.ps1 and Install-Common.ps1 at the
       install root, next to app\ and bin\. There is deliberately no fallback to the
       checkout's installer\ copy: run from there, that script would default to the
       real install under %LOCALAPPDATA% and remove it, which is not what a developer
       clicking around a checkout means. #>
    return (Join-Path $InstallRoot 'Uninstall-TranscribeIt.ps1')
}

function Get-UninstallCommand {
    <# Builds the detached helper's command line as a list for ProcessStartInfo and
       as one quoted line for the log and the dry run. The helper's script is a
       single -Command string built from single-quoted PowerShell fragments, so it
       contains no double quote at all: that keeps the quoted one-line form a
       faithful rendering of what the process receives. Embedded single quotes in
       paths and names are doubled, which is PowerShell's own escape. #>
    param([Parameter(Mandatory)][string] $UninstallerPath)
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $q = { param([string] $s) return "'" + $s.Replace("'", "''") + "'" }
    $path = & $q $UninstallerPath
    $name = & $q $AppName
    $nl   = '[Environment]::NewLine'

    # Write-Host output lives on the information stream in pwsh 7, so plain 2>&1
    # would capture nothing of what the uninstaller prints. *>&1 folds every stream
    # into the string that the failure box shows. The try/catch is for the case
    # where the uninstaller throws before it can exit (its Install-Common.ps1
    # missing, for instance): that is a failure too and must not be reported as
    # success, so it is given exit code 1 and the exception text.
    $steps = @(
        'Set-Location -LiteralPath $env:TEMP',
        ('Wait-Process -Id {0} -ErrorAction SilentlyContinue' -f $PID),
        ('try { $out = & ' + $path + ' -Quiet *>&1 | Out-String; $code = $LASTEXITCODE } catch { $out = ($_ | Out-String); $code = 1 }'),
        'if ($null -eq $code) { $code = 0 }',
        'Add-Type -AssemblyName PresentationFramework',
        ('if ($code -eq 0) { [void][System.Windows.MessageBox]::Show(' + (& $q "$AppName has been removed from this computer.") +
            ', ' + $name + ", 'OK', 'Information') } else { " +
            '$t = $out.Trim(); if ($t.Length -gt 1500) { $t = $t.Substring(0, 1500) + ''...'' }; ' +
            '[void][System.Windows.MessageBox]::Show((' + (& $q "$AppName could not be fully removed.") + ' + ' + $nl + ' + ' + $nl + ' + $t), ' +
            $name + ", 'OK', 'Error') }")
    )
    # No MessageBoxOptions on purpose. DefaultDesktopOnly looked like the way to keep
    # the box on top, but measured from a windowless pwsh it never became visible at
    # all, while the plain overload appeared within two seconds.
    $command = $steps -join '; '
    if ($command.Contains('"')) { throw 'the uninstall helper command must not contain a double quote' }

    $list = @('-WindowStyle', 'Hidden', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $command)
    return [pscustomobject]@{
        Pwsh    = $pwsh
        Target  = $UninstallerPath
        List    = $list
        Text    = ('"{0}" {1}' -f $pwsh, (($list | ForEach-Object { '"{0}"' -f $_ }) -join ' '))
    }
}

function Start-Uninstaller {
    <# Starts the detached helper. Throws when pwsh.exe cannot be found, which the
       caller turns into a message. Returns the command line that was (or under
       -DryRunLaunch would have been) run. The working directory is %TEMP% so the
       helper itself never holds the install root open. #>
    param([Parameter(Mandatory)][string] $UninstallerPath)
    $cmd = Get-UninstallCommand -UninstallerPath $UninstallerPath
    if (-not (Test-Path -LiteralPath $cmd.Pwsh -PathType Leaf)) {
        throw "pwsh.exe was not found at $($cmd.Pwsh)"
    }
    if ($DryRunLaunch) {
        Write-HomeLog "-DryRunLaunch: NOT started. Uninstall command would be: $($cmd.Text)"
        return $cmd.Text
    }
    Write-HomeLog "launched uninstall helper: $($cmd.Text)"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $cmd.Pwsh
    foreach ($a in $cmd.List) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true
    $psi.WorkingDirectory = $env:TEMP
    [void][System.Diagnostics.Process]::Start($psi)
    return $cmd.Text
}

# The confirmation lives in a replaceable scriptblock so the self test can answer
# Yes or No without a message box ever opening. It receives the owning window (or
# $null) and returns $true only when the user chose Yes; No is the default button
# because an accidental Enter must not remove the application.
$script:ConfirmUninstall = {
    param($Window)
    $text = ("Remove $AppName from this computer?`n`n" +
             "This deletes the app, its right-click entries and the Start Menu entry. " +
             "Your recordings and transcripts in Downloads are not touched.")
    $answer = if ($null -ne $Window) {
        [System.Windows.MessageBox]::Show($Window, $text, $AppName, 'YesNo', 'Warning', 'No')
    } else {
        [System.Windows.MessageBox]::Show($text, $AppName, 'YesNo', 'Warning', 'No')
    }
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-UninstallRequest {
    <# The whole uninstall click, minus the window operations, so the self test can
       drive it. Returns an object whose Outcome is one of:
         'missing'  the uninstaller file is not there; Message says so
         'declined' the user answered No; nothing happened
         'launched' the helper was started (or dry-run logged); Command has the line
         'failed'   the launch itself threw; Message has the reason
       The caller decides what to show and whether to close the window. #>
    param($Window, [string] $UninstallerPath = (Get-UninstallerPath))
    if (-not (Test-Path -LiteralPath $UninstallerPath -PathType Leaf)) {
        Write-HomeLog "uninstall requested but the uninstaller is missing: $UninstallerPath" 'WARN'
        return [pscustomobject]@{
            Outcome = 'missing'; Command = $null
            Message = ("$AppName could not find its uninstaller.`n`n$UninstallerPath`n`n" +
                       "Re-run the installer, which puts it back, or delete the folder by hand.")
        }
    }
    if (-not (& $script:ConfirmUninstall $Window)) {
        Write-HomeLog 'uninstall declined at the confirmation.'
        return [pscustomobject]@{ Outcome = 'declined'; Command = $null; Message = $null }
    }
    Write-HomeLog "uninstall confirmed by the user; handing off to $UninstallerPath"
    try {
        $line = Start-Uninstaller -UninstallerPath $UninstallerPath
        return [pscustomobject]@{ Outcome = 'launched'; Command = $line; Message = $null }
    } catch {
        Write-HomeLog "uninstall launch failed: $($_.Exception.Message)" 'ERROR'
        return [pscustomobject]@{
            Outcome = 'failed'; Command = $null
            Message = "$AppName could not start the uninstaller.`n`n$($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Native helpers: the real Downloads folder and the taskbar AppUserModelID.
# ---------------------------------------------------------------------------
if (-not ('Heresay.Home.Native' -as [Type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Heresay.Home
{
    public static class Native
    {
        // FOLDERID_Downloads. Downloads can be relocated, so this is asked first
        // and the profile path is the last resort, as in the recorder.
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

        [DllImport("shell32.dll", ExactSpelling = true)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string appId);
    }
}
'@
}

function Get-DownloadsDirectory {
    <# The folder the file picker opens in. Returns $null rather than inventing a
       directory: the dialog then falls back to its own default, which is fine. #>
    $known = $null
    try { $known = [Heresay.Home.Native]::GetDownloadsPath() } catch { }
    if (-not [string]::IsNullOrWhiteSpace($known) -and [System.IO.Directory]::Exists($known)) { return $known }

    try {
        $raw = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' `
                                     -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$raw)
        if (-not [string]::IsNullOrWhiteSpace($expanded) -and [System.IO.Directory]::Exists($expanded)) { return $expanded }
    } catch { }

    $fallback = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    if ([System.IO.Directory]::Exists($fallback)) { return $fallback }
    return $null
}

# The file picker's filter. Register-ShellVerbs.ps1 derives the registered set from
# each machine's PerceivedType index, which is the right thing for a shell verb but
# overkill for a dialog: this fixed list covers the same formats on the target fleet,
# and "All files" is there for anything it misses.
$script:MediaExtensions = @(
    'mp3', 'm4a', 'wav', 'wma', 'aac', 'flac', 'ogg', 'opus', 'amr', 'caf',
    'mp4', 'm4v', 'mov', 'mkv', 'avi', 'wmv', 'webm', 'flv', '3gp', '3g2'
)

function Get-FileDialogFilter {
    $pattern = ($script:MediaExtensions | ForEach-Object { "*.$_" }) -join ';'
    return "Audio and video files|$pattern|All files|*.*"
}

# ---------------------------------------------------------------------------
# 4. WPF
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# Must be set before the HWND exists. A failure costs the taskbar icon and nothing
# else, so it never takes the window down.
try {
    $hr = [Heresay.Home.Native]::SetCurrentProcessExplicitAppUserModelID('Heresay.TranscribeIt.Home')
    if ($hr -ne 0) { Write-HomeLog ('SetCurrentProcessExplicitAppUserModelID returned 0x{0:X8}' -f $hr) 'WARN' }
} catch { Write-HomeLog "AppUserModelID failed - taskbar keeps the pwsh icon: $($_.Exception.Message)" 'WARN' }

# Built from code points so this file stays pure ASCII, as Progress.ps1 does.
$G = @{
    Ellipsis = [string][char]0x2026   # ...
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Heresay" Width="420" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        ShowInTaskbar="True"
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

    <!-- A button that looks like a line of muted text: for the one action that must
         be findable but never inviting. It has its own template rather than
         BasedOn the Button style so it inherits none of the height or border. -->
    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="4,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
              <TextBlock x:Name="Tx" Foreground="{TemplateBinding Foreground}"
                         Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Tx" Property="TextDecorations" Value="Underline"/>
                <Setter TargetName="Tx" Property="Foreground" Value="#FF1A1A1A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Flat radio button in the same palette: a ring that fills with the accent
         when checked. The content sits to the right and may be two lines tall. -->
    <Style TargetType="RadioButton">
      <Setter Property="Margin" Value="0,8,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Ellipse x:Name="Ring" Grid.Column="0" Width="16" Height="16" Margin="0,1,0,0"
                       VerticalAlignment="Top" Fill="#FFFDFDFD" Stroke="#FF8A8A8A"
                       StrokeThickness="1"/>
              <Ellipse x:Name="Dot" Grid.Column="0" Width="6" Height="6" Margin="5,6,0,0"
                       VerticalAlignment="Top" HorizontalAlignment="Left" Fill="#FFFFFFFF"
                       Visibility="Collapsed"/>
              <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Top"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource AccentDim}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Ring" Property="Fill" Value="{StaticResource Accent}"/>
                <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource Accent}"/>
                <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="18,16,18,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- 0 quality heading   -->
      <RowDefinition Height="Auto"/>   <!-- 1 quality options   -->
      <RowDefinition Height="Auto"/>   <!-- 2 scope note        -->
      <RowDefinition Height="Auto"/>   <!-- 3 rule              -->
      <RowDefinition Height="Auto"/>   <!-- 4 record button     -->
      <RowDefinition Height="Auto"/>   <!-- 5 file button       -->
      <RowDefinition Height="Auto"/>   <!-- 6 uninstall link    -->
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" FontSize="13" FontWeight="SemiBold" Text="Transcription quality"/>

    <!-- The descriptions state what each level does in the engine. They are part of
         the contract with Transcribe-Entry.ps1 (see the header): change them when
         the mapping changes. -->
    <StackPanel Grid.Row="1" Margin="0,2,0,0">
      <RadioButton x:Name="RbFastest" GroupName="Quality">
        <StackPanel>
          <TextBlock Text="Fastest (default)"/>
          <TextBlock FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                     Text="What Heresay does today. Small English model, no speaker separation. About nine times faster than the meeting."/>
        </StackPanel>
      </RadioButton>
      <RadioButton x:Name="RbModerate" GroupName="Quality">
        <StackPanel>
          <TextBlock Text="Moderate"/>
          <TextBlock FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                     Text="Better words and timing, and speakers are told apart. About four times faster than the meeting."/>
        </StackPanel>
      </RadioButton>
      <RadioButton x:Name="RbThorough" GroupName="Quality">
        <StackPanel>
          <TextBlock Text="Slower, more capable"/>
          <TextBlock FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                     Text="The most accurate words, with speakers told apart. Roughly one and a half times faster than the meeting."/>
        </StackPanel>
      </RadioButton>
    </StackPanel>

    <TextBlock x:Name="TbQualityScope" Grid.Row="2" Margin="0,12,0,0" FontSize="11"
               Foreground="{StaticResource Faint}" TextWrapping="Wrap"
               Text="Applies to both right-click entries and to recordings."/>

    <Border Grid.Row="3" Height="1" Margin="0,14,0,14" Background="{StaticResource Track}"/>

    <Button x:Name="BtnRecord" Grid.Row="4" Height="32" Margin="0"
            HorizontalAlignment="Stretch" Style="{StaticResource AccentButton}"
            Content="Transcribe new conversation"/>
    <Button x:Name="BtnFile" Grid.Row="5" Height="32" Margin="0,8,0,0"
            HorizontalAlignment="Stretch" Content="Transcribe a file"/>

    <!-- Secondary on purpose: muted text, centred, well below the two real actions,
         so it is found when looked for and never mistaken for a step in the flow. -->
    <Button x:Name="BtnUninstall" Grid.Row="6" Margin="0,12,0,0"
            HorizontalAlignment="Center" Style="{StaticResource LinkButton}"
            Content="Uninstall Heresay"/>
  </Grid>
</Window>
'@

function New-HomeWindow {
    <# Builds the window and resolves every named element. Throws on a missing
       element so a typo in the XAML fails at startup, not at first click. #>
    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $w = [System.Windows.Markup.XamlReader]::Load($reader)
    $w.Title = $AppName

    $ui = @{ Win = $w }
    foreach ($name in @('RbFastest', 'RbModerate', 'RbThorough', 'TbQualityScope', 'BtnRecord', 'BtnFile', 'BtnUninstall')) {
        $el = $w.FindName($name)
        if ($null -eq $el) { throw "XAML element '$name' did not resolve." }
        $ui[$name] = $el
    }
    $ui.BtnFile.Content      = 'Transcribe a file' + $G.Ellipsis
    $ui.BtnUninstall.Content = 'Uninstall ' + $AppName
    return $ui
}

function New-MediaColor([string] $hex) {
    return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}

function Get-AppIcon {
    <# The shipped .ico first (app\TranscribeIt.ico in an install; the checkout keeps
       it under installer\assets). If neither can be loaded, draw the app's slate
       tile at runtime so the title bar never shows the PowerShell icon. #>
    foreach ($candidate in @((Join-Path $AppDir 'TranscribeIt.ico'),
                             (Join-Path $InstallRoot 'installer\assets\TranscribeIt.ico'))) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                [Uri]::new($candidate), 'None', 'OnLoad')
            Write-HomeLog "window icon: $candidate"
            return $frame
        } catch { Write-HomeLog "could not load icon '$candidate': $($_.Exception.Message)" 'WARN' }
    }

    $size = 64
    $visual = [System.Windows.Media.DrawingVisual]::new()
    $dc = $visual.RenderOpen()
    try {
        $s = $size / 32.0
        $ink = [System.Windows.Media.SolidColorBrush]::new((New-MediaColor '#FF12333F'))
        $dc.DrawRoundedRectangle($ink, $null,
            [System.Windows.Rect]::new(0, 0, $size, $size), (7.0 * $s), (7.0 * $s))
    } finally { $dc.Close() }
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)
    $rtb.Freeze()
    Write-HomeLog 'window icon: drawn at runtime (no .ico found)'
    return $rtb
}

# ---------------------------------------------------------------------------
# 5. Self test. Exits here; the window is built but never shown.
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $failures = 0
    function Report([bool] $ok, [string] $what) {
        if ($ok) { Write-Output "PASS  $what" } else { Write-Output "FAIL  $what"; $script:failures++ }
    }

    # The launch paths must never start anything from a test.
    $DryRunLaunch = $true

    $ownTemp = $false
    if (-not $PSBoundParameters.ContainsKey('SettingsPath')) {
        $SettingsPath = Join-Path $env:TEMP ('heresay-home-selftest-{0}.json' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $ownTemp = $true
    }
    if (Test-Path -LiteralPath $SettingsPath) { Remove-Item -LiteralPath $SettingsPath -Force }

    try {
        try {
            $ui = New-HomeWindow
            Report $true 'window built and every named element resolved'
            try { $ui.Win.Icon = Get-AppIcon; Report $true 'window icon set' }
            catch { Report $false "window icon: $($_.Exception.Message)" }
        } catch { Report $false "window build: $($_.Exception.Message)" }

        Report ((Get-QualitySetting) -eq 'fastest') 'missing settings file reads as fastest'
        try {
            $label = $ui.RbFastest.Content.Children[0].Text
            Report ($label -eq 'Fastest (default)') "first radio is labelled '$label'"
        } catch { Report $false "first radio label: $($_.Exception.Message)" }

        foreach ($q in $script:QualityLevels) {
            $saved = Save-QualitySetting -Quality $q
            $back  = Get-QualitySetting
            Report ($saved -and $back -eq $q) "save '$q' then read back -> '$back'"
        }
        try {
            # Checked on the raw text: pwsh 7's ConvertFrom-Json turns an ISO 8601
            # string into a local DateTime, which would hide a missing Z suffix.
            $raw = Get-Content -LiteralPath $SettingsPath -Raw
            $json = $raw | ConvertFrom-Json
            $stamp = if ($raw -match '"updatedUtc":\s*"([^"]*)"') { $Matches[1] } else { '(missing)' }
            $shapeOk = ($json.PSObject.Properties.Name -contains 'quality') -and
                       ($json.PSObject.Properties.Name -contains 'updatedUtc') -and
                       ($stamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$')
            Report $shapeOk "settings.json shape { quality, updatedUtc } with an ISO 8601 UTC timestamp: $stamp"
        } catch { Report $false "settings.json shape: $($_.Exception.Message)" }

        [System.IO.File]::WriteAllText($SettingsPath, '{ this is not json')
        Report ((Get-QualitySetting) -eq 'fastest') 'corrupt settings file reads as fastest'
        [System.IO.File]::WriteAllText($SettingsPath, '{ "quality": "turbo" }')
        Report ((Get-QualitySetting) -eq 'fastest') 'unknown quality value reads as fastest'
        [System.IO.File]::WriteAllText($SettingsPath, '')
        Report ((Get-QualitySetting) -eq 'fastest') 'empty settings file reads as fastest'

        $filter = Get-FileDialogFilter
        Report ($filter -like 'Audio and video files|*.mp3;*' -and $filter -like '*|All files|*.*') "file dialog filter: $filter"

        $dl = Get-DownloadsDirectory
        Report ($null -eq $dl -or (Test-Path -LiteralPath $dl -PathType Container)) "downloads folder: $(if ($dl) { $dl } else { '(none, dialog default)' })"

        try {
            $recCmd = Start-HeresayScript -ScriptName 'Record-Conversation.ps1'
            Report ($recCmd -like '*wscript.exe*Run-Hidden.vbs*Record-Conversation.ps1"') "dry-run record launch: $recCmd"
        } catch { Report $false "dry-run record launch: $($_.Exception.Message)" }
        try {
            $sample  = 'C:\call recordings\a b.m4a'
            $fileCmd = Start-HeresayScript -ScriptName 'Transcribe-Entry.ps1' -Arguments @('-Path', $sample)
            Report ($fileCmd -like ('*Transcribe-Entry.ps1" "-Path" "{0}"' -f $sample)) "dry-run file launch: $fileCmd"
        } catch { Report $false "dry-run file launch: $($_.Exception.Message)" }

        # --- uninstall: no message box may open and nothing may be removed ----------
        # The confirmation scriptblock is swapped for counters that answer No and
        # Yes. -DryRunLaunch is already on, so a Yes logs the helper command instead
        # of starting it. A checkout has no root-level uninstaller, so the missing
        # path is exercised against the real location and the present path against
        # a scratch file when the real one is not there.
        $confirmCalls = 0
        $realUninstaller = Get-UninstallerPath
        $missingPath = Join-Path $env:TEMP ('heresay-no-such-uninstaller-{0}.ps1' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $script:ConfirmUninstall = { param($Window) $script:confirmCalls++; return $false }
        $r = Invoke-UninstallRequest -Window $null -UninstallerPath $missingPath
        Report ($r.Outcome -eq 'missing' -and $confirmCalls -eq 0 -and $r.Message -like '*could not find its uninstaller*') "uninstall with the file missing: outcome '$($r.Outcome)', confirm not asked"

        $presentPath = $realUninstaller
        $ownStub = $false
        if (-not (Test-Path -LiteralPath $presentPath -PathType Leaf)) {
            $presentPath = Join-Path $env:TEMP ('heresay-stub-uninstaller-{0}.ps1' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
            [System.IO.File]::WriteAllText($presentPath, "exit 0`r`n")
            $ownStub = $true
        }
        try {
            $r = Invoke-UninstallRequest -Window $null -UninstallerPath $presentPath
            Report ($r.Outcome -eq 'declined' -and $confirmCalls -eq 1 -and $null -eq $r.Command) "uninstall answered No: outcome '$($r.Outcome)', nothing launched"

            $script:ConfirmUninstall = { param($Window) $script:confirmCalls++; return $true }
            $r = Invoke-UninstallRequest -Window $null -UninstallerPath $presentPath
            $okShape = $r.Outcome -eq 'launched' -and $confirmCalls -eq 2 -and
                       $r.Command -like '*pwsh.exe" "-WindowStyle" "Hidden" "-NoProfile" "-NonInteractive" "-ExecutionPolicy" "Bypass" "-Command" "*' -and
                       $r.Command -like ('*Wait-Process -Id {0} *' -f $PID) -and
                       $r.Command -like ('*& ''{0}'' -Quiet *' -f $presentPath.Replace("'", "''")) -and
                       $r.Command -like '*has been removed from this computer*' -and
                       $r.Command -like '*could not be fully removed*' -and
                       (@($r.Command.ToCharArray() | Where-Object { $_ -eq '"' }).Count -eq 18)   # pwsh + 8 args quoted; none inside -Command
            Report $okShape "uninstall answered Yes: outcome '$($r.Outcome)', dry-run helper command below"
            Write-Output "      $($r.Command)"
        }
        finally {
            if ($ownStub) { try { [System.IO.File]::Delete($presentPath) } catch { } }
        }
    }
    finally {
        if ($ownTemp) { try { Remove-Item -LiteralPath $SettingsPath -Force -ErrorAction SilentlyContinue } catch { } }
    }

    Write-Output ("{0}: {1} failure(s). Log: {2}" -f $(if ($failures -eq 0) { 'SELFTEST PASS' } else { 'SELFTEST FAIL' }), $failures, $LogFile)
    Write-HomeLog "--- home exit (selftest failures=$failures) ---"
    exit $(if ($failures -eq 0) { 0 } else { 1 })
}

# ---------------------------------------------------------------------------
# 6. The live window.
# ---------------------------------------------------------------------------
try {
    $UI = New-HomeWindow
} catch {
    Write-HomeLog "could not build the window: $($_.Exception.Message)" 'ERROR'
    try {
        [void][System.Windows.MessageBox]::Show(
            "Heresay could not open its window.`n`n$($_.Exception.Message)`n`nLog: $LogFile",
            $AppName, 'OK', 'Error')
    } catch { }
    exit 1
}
$win = $UI.Win
try { $win.Icon = Get-AppIcon } catch { Write-HomeLog "window icon failed: $($_.Exception.Message)" 'WARN' }

function Show-HomeMessage([string] $Text, [string] $Icon = 'Warning') {
    try { [void][System.Windows.MessageBox]::Show($win, $Text, $AppName, 'OK', $Icon) } catch { }
}

# --- quality radios: reflect the saved choice, then save every click ---------
# $script:Loading gates the Checked handlers while the initial state is applied,
# otherwise reading the setting would immediately rewrite it with a new timestamp.
$script:Loading = $true
$current = Get-QualitySetting
switch ($current) {
    'moderate' { $UI.RbModerate.IsChecked = $true }
    'thorough' { $UI.RbThorough.IsChecked = $true }
    default    { $UI.RbFastest.IsChecked  = $true }
}
$script:Loading = $false
Write-HomeLog "quality shown: $current"

function Set-QualityFromClick([string] $Quality) {
    if ($script:Loading) { return }
    if (-not (Save-QualitySetting -Quality $Quality)) {
        Show-HomeMessage ("Heresay could not save your choice.`n`nIt will still be used for this window, " +
            "but the next time Heresay opens it will show the previous setting.`n`nLog: $LogFile")
    }
}
$UI.RbFastest.add_Checked({  Set-QualityFromClick 'fastest'  })
$UI.RbModerate.add_Checked({ Set-QualityFromClick 'moderate' })
$UI.RbThorough.add_Checked({ Set-QualityFromClick 'thorough' })

# --- record ------------------------------------------------------------------
$UI.BtnRecord.add_Click({
    try {
        [void](Start-HeresayScript -ScriptName 'Record-Conversation.ps1')
        $win.Close()
    } catch {
        Write-HomeLog "record launch failed: $($_.Exception.Message)" 'ERROR'
        Show-HomeMessage ("Heresay could not start the recorder.`n`n$($_.Exception.Message)`n`n" +
            "If part of the installation is missing, re-run the installer.`n`nLog: $LogFile")
    }
})

# --- transcribe a file -------------------------------------------------------
$UI.BtnFile.add_Click({
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title       = 'Transcribe a file'
    $dlg.Multiselect = $true
    $dlg.Filter      = Get-FileDialogFilter
    $dlg.FilterIndex = 1
    $dlg.CheckFileExists = $true
    $downloads = Get-DownloadsDirectory
    if ($downloads) { $dlg.InitialDirectory = $downloads }

    $picked = $false
    try { $picked = [bool]$dlg.ShowDialog($win) } catch { Write-HomeLog "file dialog failed: $($_.Exception.Message)" 'ERROR' }
    if (-not $picked -or @($dlg.FileNames).Count -eq 0) {
        Write-HomeLog 'file dialog cancelled; staying open.'
        return
    }

    # One launch per file, as Explorer does for a multi-select: Transcribe-Entry.ps1
    # coalesces the invocations into a single batch, so the progress window says
    # "File 2 of 5" without any batch logic living here.
    $started = 0
    $failed  = @()
    foreach ($f in $dlg.FileNames) {
        try {
            [void](Start-HeresayScript -ScriptName 'Transcribe-Entry.ps1' -Arguments @('-Path', $f))
            $started++
        } catch {
            Write-HomeLog "file launch failed for '$f': $($_.Exception.Message)" 'ERROR'
            $failed += $f
        }
    }
    Write-HomeLog "file launches: started=$started failed=$($failed.Count)"

    if ($started -gt 0) {
        $win.Close()
    } else {
        Show-HomeMessage ("Heresay could not start the transcription.`n`n" +
            "If part of the installation is missing, re-run the installer.`n`nLog: $LogFile")
    }
})

# --- uninstall ---------------------------------------------------------------
# Invoke-UninstallRequest asks, logs and launches; only the window operations live
# here. The window closes on 'launched' so the helper's wait for this PID ends at
# once; on every other outcome it stays open, with a message where one is due.
$UI.BtnUninstall.add_Click({
    $r = Invoke-UninstallRequest -Window $win
    switch ($r.Outcome) {
        'launched' { $win.Close() }
        'declined' { }
        default    { Show-HomeMessage ("$($r.Message)`n`nLog: $LogFile") }
    }
})

$win.add_Loaded({ try { [void]$win.Activate() } catch { } })

Write-HomeLog 'window shown'
try {
    [void]$win.ShowDialog()
} finally {
    Write-HomeLog '--- home exit ---'
}
