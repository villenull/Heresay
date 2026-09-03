#requires -Version 7
<#
.SYNOPSIS
    Registers (or removes) the "Transcribe new conversation" right-click entry on the
    desktop and folder backgrounds, plus the single "Heresay" Start Menu shortcut that
    opens the app's home window.

.DESCRIPTION
    Deliberately SEPARATE from app\Register-ShellVerbs.ps1, which owns the per-file
    verb. That script's every invariant is about file types - it expands PerceivedType
    into concrete per-extension keys because the shell ignores the per-user overlay for
    PerceivedType, and its Verify mode is built on that expansion. A background verb
    shares none of that: different key roots, no file argument, one key per root. Bolting
    it on would have meant threading a per-target command through a loop built for one
    global command, so it lives here instead.

    TWO LAUNCH SURFACES, on purpose:

      1. Background verbs, which is what was asked for:
             <RegistryRoot>\DesktopBackground\Shell\<Verb>        (right-click the desktop)
             <RegistryRoot>\Directory\Background\shell\<Verb>     (right-click inside a folder)

      2. A Start Menu shortcut named "Heresay", which opens the app's HOME window
         (app\Heresay-Home.ps1), not the recorder.

    The Start Menu entry exists because the background verb alone is not a reliable
    surface. This fleet's endpoint security hooks Explorer and hides newly registered
    verbs from the Windows 11 MODERN context menu - proven with five labelled probe
    verbs, and the per-file verb only ever renders in the CLASSIC menu ("Show more
    options"). Whether the BACKGROUND roots behave the same way could not be established
    from a script: enumerating them programmatically returns keys the shell may still
    decline to draw, so only a human right-click is authoritative. A Start Menu shortcut
    has no such doubt, is reachable from Windows Search by typing a few letters, and
    costs one .lnk. Pass -NoStartMenu to skip it.

    Why the shortcut opens the home window rather than the recorder (2026-09-03, on the
    maintainer's request): someone who types "Heresay" into Start expects to find THE
    APP, not one of its verbs. The previous shortcut, "Heresay - Transcribe new
    conversation", started a recording the instant it was clicked, which is a surprising
    thing for a Start Menu entry to do and left no way to reach anything else the app
    offers. The recorder is still one click away from the home window and from the
    right-click verb. That retired shortcut name is swept on every run, create or
    -Unregister, so an upgrade over an older install leaves exactly ONE "Heresay" entry.

    Both surfaces launch through the same wscript shim the file verb and the installer
    use, so no console window ever appears; only the script they hand it differs:

        verb:      wscript.exe "<root>\app\Run-Hidden.vbs" "<root>\app\Record-Conversation.ps1"
        shortcut:  wscript.exe "<root>\app\Run-Hidden.vbs" "<root>\app\Heresay-Home.ps1"

    No "%1" anywhere: a background verb is invoked with no file. (The shell offers "%V"
    for the folder being right-clicked; the recorder does not want it, because its output
    goes to Downloads regardless of where the click happened.)

    User scope only. Everything lands under HKCU and %APPDATA%, so no admin rights are
    needed and nothing is written that another user could see.

    EVERYTHING THIS CREATES MUST BE REPORTED BACK, because the caller records it in
    install-manifest.json and the uninstaller replays that list. The Start Menu shortcut
    especially: it lives OUTSIDE the install root, so an unrecorded one survives
    uninstall as a dead menu entry - the exact failure the Send To entries caused twice.

.PARAMETER InstallRoot
    Root of the installed app. app\Run-Hidden.vbs, app\Record-Conversation.ps1 and
    app\Heresay-Home.ps1 are resolved beneath it.

.PARAMETER RegistryRoot
    Class root to write under. Defaults to the live per-user root. Point it at a scratch
    key to test without touching the real menu.

.PARAMETER MenuText
    Menu label. Defaults to 'Transcribe new conversation'.

.PARAMETER IconPath
    Icon for the entries. Defaults to app\TranscribeIt.ico beside the recorder.

.PARAMETER Position
    Where in the menu the entry sits. The shell understands only 'Top', 'Bottom', or
    the value being absent - there is no way to request a specific slot such as "just
    below Refresh". Default is absent, which files the entry in the shell's third-party
    group below the built-in View / Sort by / Refresh block, beside "Open in Terminal".

.PARAMETER NoStartMenu
    Register the background verbs only; create no "Heresay" Start Menu shortcut. The
    retired shortcut name is still swept, because leaving it behind would keep offering
    the recorder under the app's name.

.PARAMETER StartMenuDir
    Folder the shortcut is written to. Defaults to the per-user Start Menu Programs
    folder, which is the only place it should ever go in a real install; the parameter
    exists so tests can redirect the .lnk to a scratch folder instead of the real menu.

.PARAMETER Unregister
    Remove everything this script creates, pruning ancestor keys it owns.

.PARAMETER Verify
    Report what is present without changing anything.

.OUTPUTS
    One object: Ok, Action, Verb, MenuText, Command, RegistryKeys, VerbKeys,
    RegistryValues, ShortcutPaths, Removed, NotRemoved, Findings. Removed is populated
    on -Unregister AND on a create run, because a create run also sweeps the retired
    shortcut name.

.EXAMPLE
    .\Register-RecordVerb.ps1 -InstallRoot "$env:LOCALAPPDATA\Programs\TranscribeIt"

.EXAMPLE
    .\Register-RecordVerb.ps1 -InstallRoot C:\x -RegistryRoot 'HKCU:\Software\ScratchTest' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string] $InstallRoot,
    [string] $RegistryRoot = 'HKCU:\Software\Classes',
    [string] $Verb         = 'HeresayRecordConversation',
    [string] $MenuText     = 'Transcribe new conversation',
    [string] $IconPath,
    # '' (default) lets the shell place the entry in its third-party group, below the
    # built-in View / Sort by / Refresh block. Top and Bottom are the only other values
    # the shell understands; there is no arbitrary index.
    [ValidateSet('', 'Top', 'Bottom')]
    [string] $Position = '',
    [switch] $NoStartMenu,
    # Test seam only. The default is the real per-user Start Menu; a test passes a
    # scratch folder so the real menu is never touched.
    [string] $StartMenuDir = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Start Menu\Programs'),
    [switch] $Unregister,
    [switch] $Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The two background roots. Note the casing difference is Windows' own, not a typo:
# DesktopBackground uses "Shell", Directory\Background uses "shell". The registry is
# case-insensitive so it does not matter functionally, but matching the documented
# spelling keeps a reader from "fixing" one of them.
$script:BackgroundRoots = @(
    [pscustomobject]@{ Kind = 'DesktopBackground'; KeyPath = "$RegistryRoot\DesktopBackground\Shell\$Verb" }
    [pscustomobject]@{ Kind = 'FolderBackground';  KeyPath = "$RegistryRoot\Directory\Background\shell\$Verb" }
)

$script:StartMenuDir = $StartMenuDir
# Plain "Heresay": a Start-menu search for the app's name should offer the app, and the
# shortcut opens the home window, so there is nothing to qualify the name with.
$script:StartMenuLnk = Join-Path $script:StartMenuDir 'Heresay.lnk'

# Names this script USED to create. Retired shortcuts must be swept by their old names,
# or they survive every future install AND uninstall as dead menu entries: both the
# create path and -Unregister only know about the CURRENT $script:StartMenuLnk. The
# first entry is the recorder shortcut retired on 2026-09-03 when the Start Menu entry
# was pointed at the home window instead; existing installs carry it and must have it
# removed on the next run, or Start keeps offering two Heresay entries.
$script:RetiredStartMenuNames = @(
    'Heresay - Transcribe new conversation'
)

# Shared by the create path and -Unregister. Removals are recorded in $result.Removed so
# the caller can see them; they are deliberately NOT ShortcutPaths, because the installer
# records ShortcutPaths in install-manifest.json as files it created, which these are not.
function Remove-RetiredStartMenuShortcuts {
    # SupportsShouldProcess so the script's -WhatIf reaches the delete: $WhatIfPreference
    # is inherited from the script scope, and the function's own $PSCmdlet honours it.
    [CmdletBinding(SupportsShouldProcess)]
    param([System.Collections.Generic.List[string]] $Removed, [System.Collections.Generic.List[object]] $NotRemoved)
    foreach ($legacy in $script:RetiredStartMenuNames) {
        $lnk = Join-Path $script:StartMenuDir ($legacy + '.lnk')
        if (-not (Test-Path -LiteralPath $lnk)) { continue }
        if ($PSCmdlet.ShouldProcess($lnk, 'Remove retired Start Menu shortcut')) {
            try { Remove-Item -LiteralPath $lnk -Force -ErrorAction Stop; [void]$Removed.Add($lnk) }
            catch { [void]$NotRemoved.Add([pscustomobject]@{ Path = $lnk; Reason = $_.Exception.Message }) }
        }
    }
}

$result = [ordered]@{
    Ok              = $true
    Action          = if ($Verify) { 'Verify' } elseif ($Unregister) { 'Unregister' } else { 'Register' }
    Verb            = $Verb
    MenuText        = $MenuText
    Command         = ''
    RegistryKeys    = @()
    VerbKeys        = @()
    RegistryValues  = @()
    ShortcutPaths   = @()
    Removed         = @()
    NotRemoved      = @()
    Findings        = @()
}

function Resolve-RecordIcon {
    if ($IconPath) { return $IconPath }
    $ico = Join-Path $InstallRoot 'app\TranscribeIt.ico'
    if (Test-Path -LiteralPath $ico) { return "$ico,0" }
    return ''
}

# ---------------------------------------------------------------------- verify --

if ($Verify) {
    foreach ($t in $script:BackgroundRoots) {
        $keyPresent = Test-Path -LiteralPath $t.KeyPath
        $cmdPath    = Join-Path $t.KeyPath 'command'
        $cmdPresent = Test-Path -LiteralPath $cmdPath
        $cmdValue   = ''
        $label      = ''
        if ($cmdPresent) {
            try { $cmdValue = [string](Get-ItemProperty -LiteralPath $cmdPath -ErrorAction Stop).'(default)' } catch { }
        }
        if ($keyPresent) {
            try { $label = [string](Get-ItemProperty -LiteralPath $t.KeyPath -ErrorAction Stop).MUIVerb } catch { }
        }
        $result.Findings += [pscustomobject]@{
            Kind = $t.Kind; Subject = $t.KeyPath
            KeyPresent = $keyPresent; CommandPresent = $cmdPresent
            Command = $cmdValue; MUIVerb = $label
        }
    }
    $result.Findings += [pscustomobject]@{
        Kind = 'StartMenu'; Subject = $script:StartMenuLnk
        KeyPresent = (Test-Path -LiteralPath $script:StartMenuLnk)
        CommandPresent = (Test-Path -LiteralPath $script:StartMenuLnk)
        Command = ''; MUIVerb = ''
    }
    $result.Ok = @($result.Findings | Where-Object { -not $_.KeyPresent }).Count -eq 0
    return [pscustomobject]$result
}

# ------------------------------------------------------------------ unregister --

if ($Unregister) {
    $removed = New-Object System.Collections.Generic.List[string]
    # ::new() for the same measured reason as $createdValues below.
    $notRemoved = [System.Collections.Generic.List[object]]::new()

    foreach ($t in $script:BackgroundRoots) {
        if (-not (Test-Path -LiteralPath $t.KeyPath)) { continue }
        if ($PSCmdlet.ShouldProcess($t.KeyPath, 'Remove registry key (recurse)')) {
            try { Remove-Item -LiteralPath $t.KeyPath -Recurse -Force -ErrorAction Stop; [void]$removed.Add($t.KeyPath) }
            catch { [void]$notRemoved.Add([pscustomobject]@{ Path = $t.KeyPath; Reason = $_.Exception.Message }); $result.Ok = $false }
        }
    }

    # Prune the containers we created, but ONLY while they are empty - another
    # application's verbs can share DesktopBackground\Shell and must survive.
    foreach ($container in @(
            "$RegistryRoot\DesktopBackground\Shell",
            "$RegistryRoot\DesktopBackground",
            "$RegistryRoot\Directory\Background\shell",
            "$RegistryRoot\Directory\Background")) {
        if (-not (Test-Path -LiteralPath $container)) { continue }
        $hasChildren = @(Get-ChildItem -LiteralPath $container -ErrorAction SilentlyContinue).Count -gt 0
        $hasValues   = @((Get-Item -LiteralPath $container -ErrorAction SilentlyContinue).GetValueNames() |
                          Where-Object { $_ -ne '' }).Count -gt 0
        if ($hasChildren -or $hasValues) { continue }
        if ($PSCmdlet.ShouldProcess($container, 'Remove empty container key')) {
            try { Remove-Item -LiteralPath $container -Force -ErrorAction Stop; [void]$removed.Add($container) } catch { }
        }
    }

    if (Test-Path -LiteralPath $script:StartMenuLnk) {
        if ($PSCmdlet.ShouldProcess($script:StartMenuLnk, 'Remove Start Menu shortcut')) {
            try { Remove-Item -LiteralPath $script:StartMenuLnk -Force -ErrorAction Stop; [void]$removed.Add($script:StartMenuLnk) }
            catch { [void]$notRemoved.Add([pscustomobject]@{ Path = $script:StartMenuLnk; Reason = $_.Exception.Message }); $result.Ok = $false }
        }
    }

    # An uninstall of a newer version over an older install's leftovers must also take
    # the retired name with it, or the dead recorder entry outlives the app.
    Remove-RetiredStartMenuShortcuts -Removed $removed -NotRemoved $notRemoved
    if ($notRemoved.Count) { $result.Ok = $false }

    $result.Removed = @($removed)
    $result.NotRemoved = @($notRemoved)
    return [pscustomobject]$result
}

# -------------------------------------------------------------------- register --

$shim     = Join-Path $InstallRoot 'app\Run-Hidden.vbs'
$recorder = Join-Path $InstallRoot 'app\Record-Conversation.ps1'
$homeApp  = Join-Path $InstallRoot 'app\Heresay-Home.ps1'
foreach ($needed in @($shim, $recorder, $homeApp)) {
    if (-not (Test-Path -LiteralPath $needed)) {
        Write-Warning "Not present yet: $needed. Registering anyway; the entry will fail until the installer copies app files into place."
    }
}

# wscript.exe is a GUI-subsystem host, so no console window is ever created. Targeting
# pwsh.exe directly here would flash a console for the ~2-3 s interpreter startup this
# fleet's endpoint security imposes - measured, and the reason Run-Hidden.vbs exists.
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$command = '"{0}" "{1}" "{2}"' -f $wscript, $shim, $recorder
$icon    = Resolve-RecordIcon
$result.Command = $command

$createdKeys   = New-Object System.Collections.Generic.List[string]
$verbKeys      = New-Object System.Collections.Generic.List[string]
# ::new() rather than New-Object, deliberately. MEASURED on PowerShell 7.6.1:
# `[void]$l.Add($x)` on a list built with `New-Object ...List[object]` throws
# "Argument types do not match", while the identical call on `List[string]`, or on a
# `List[object]` built with ::new(), works. It cost an hour here: the keys were already
# written when it threw, so the script looked half-successful and the stack pointed at
# the harmless assignment that consumed the list, not at the Add that broke it.
$createdValues = [System.Collections.Generic.List[object]]::new()

foreach ($t in $script:BackgroundRoots) {
    if (-not $PSCmdlet.ShouldProcess($t.KeyPath, "Register '$MenuText' on $($t.Kind)")) { continue }
    try {
        $null = New-Item -Path $t.KeyPath -Force
        [void]$createdKeys.Add($t.KeyPath)
        [void]$verbKeys.Add($t.KeyPath)

        # Ordered name/value PAIRS rather than an [ordered]@{} indexed by name.
        # OrderedDictionary exposes both Item[int] and Item[object], and PowerShell's
        # overload resolution can bind a STRING key to the integer indexer and throw
        # "Argument types do not match" - which it did here, after the keys had already
        # been written, so the script failed while looking like it had half-worked.
        #
        # POSITION: the shell honours only 'Top', 'Bottom', or the value being ABSENT.
        # There is no way to ask for a specific slot such as "just below Refresh".
        # Absent is the default here, on the maintainer's request to move it off the top
        # (2026-09-01): with no Position the shell files the entry in its default
        # third-party group, which on the desktop background lands below the built-in
        # View / Sort by / Refresh block, beside entries like "Open in Terminal" and the
        # Git ones. That is the closest reachable answer to "under Refresh". Pass
        # -Position Top or -Position Bottom to override.
        $vals = @(
            [pscustomobject]@{ Name = 'MUIVerb'; Value = $MenuText }
        )
        if ($Position) { $vals += [pscustomobject]@{ Name = 'Position'; Value = $Position } }
        if ($icon) { $vals += [pscustomobject]@{ Name = 'Icon'; Value = $icon } }
        foreach ($v in $vals) {
            $null = New-ItemProperty -LiteralPath $t.KeyPath -Name $v.Name -Value $v.Value -PropertyType String -Force
            [void]$createdValues.Add([pscustomobject]@{ Key = $t.KeyPath; Name = $v.Name; Value = $v.Value; Type = 'String' })
        }

        $cmdKey = Join-Path $t.KeyPath 'command'
        $null = New-Item -Path $cmdKey -Force
        [void]$createdKeys.Add($cmdKey)
        $null = New-ItemProperty -LiteralPath $cmdKey -Name '(default)' -Value $command -PropertyType String -Force
        [void]$createdValues.Add([pscustomobject]@{ Key = $cmdKey; Name = '(default)'; Value = $command; Type = 'String' })
    }
    catch {
        $result.Ok = $false
        Write-Warning "Could not register on $($t.Kind): $($_.Exception.Message)"
    }
}

# Sweep the retired shortcut name BEFORE creating the current one, and regardless of
# -NoStartMenu: the point of the sweep is that an upgrade over an older install ends
# with exactly one "Heresay" entry in Start, and skipping the new shortcut is no reason
# to keep offering the old one.
$removedRetired    = New-Object System.Collections.Generic.List[string]
$notRemovedRetired = [System.Collections.Generic.List[object]]::new()
Remove-RetiredStartMenuShortcuts -Removed $removedRetired -NotRemoved $notRemovedRetired
foreach ($n in $notRemovedRetired) { Write-Warning "Could not remove the retired Start Menu shortcut $($n.Path): $($n.Reason)" }

$shortcuts = New-Object System.Collections.Generic.List[string]
if (-not $NoStartMenu) {
    if ($PSCmdlet.ShouldProcess($script:StartMenuLnk, 'Create Start Menu shortcut')) {
        $shell = $null
        try {
            if (-not (Test-Path -LiteralPath $script:StartMenuDir)) {
                $null = New-Item -ItemType Directory -Path $script:StartMenuDir -Force
            }
            $shell = New-Object -ComObject WScript.Shell
            $sc = $shell.CreateShortcut($script:StartMenuLnk)
            $sc.TargetPath       = $wscript
            # The home window, not the recorder: see the header. Same quoting as the
            # verb command so a space in the install root survives both.
            $sc.Arguments        = '"{0}" "{1}"' -f $shim, $homeApp
            $sc.Description      = 'Heresay'
            $sc.WorkingDirectory = Join-Path $InstallRoot 'app'
            if ($icon) { $sc.IconLocation = $icon }
            $sc.Save()
            [void]$shortcuts.Add($script:StartMenuLnk)
        }
        catch {
            $result.Ok = $false
            Write-Warning "Could not create the Start Menu shortcut: $($_.Exception.Message)"
        }
        finally {
            if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        }
    }
}

$result.RegistryKeys   = @($createdKeys)
$result.VerbKeys       = @($verbKeys)
$result.RegistryValues = @($createdValues)
$result.ShortcutPaths  = @($shortcuts)
$result.Removed        = @($removedRetired)
$result.NotRemoved     = @($notRemovedRetired)
return [pscustomobject]$result
