<#
.SYNOPSIS
    Removes Heresay, driven by install-manifest.json.

.DESCRIPTION
    Removes exactly what the installer recorded creating - every file, every
    directory, every registry key and value - so the removal is provable rather than a
    best guess at what an install probably looked like.

    Deliberate behaviours:
      * Safe to run twice. A second run finds nothing and says so.
      * Anything it cannot remove is reported explicitly, not swallowed.
      * Files present in the install root but NOT in the manifest are left alone and
        listed, because deleting unknown files under a user profile is not this
        script's call to make. -RemoveUnlisted opts in.
      * The right-click entry is verified gone from both perceived types afterwards.
      * The Start Menu is swept for BOTH the current "Heresay" shortcut and the retired
        "Heresay - Transcribe new conversation" one, whether or not the manifest lists
        them, so an uninstall over an upgraded install leaves no dead Start entry.
      * If the manifest is missing or corrupt, -Fallback removes the well-known keys
        and paths instead, and says clearly that it is guessing.

.PARAMETER KeepLogs
    Leave logs\ behind for troubleshooting.

.PARAMETER RemoveUnlisted
    Also delete files under the install root that the manifest does not mention.

.PARAMETER LogPath
    Durable diagnostic log. Defaults to a timestamped Heresay-uninstall log in
    the current user's temporary directory, outside the install tree being removed.

.EXAMPLE
    .\Uninstall-Heresay.ps1 -WhatIf
#>
# ConfirmImpact is deliberately Medium, not High. With High, ShouldProcess prompts
# because $ConfirmPreference defaults to High, and the prompt throws outright under
# -NonInteractive - measured: "PowerShell is in NonInteractive mode". The user already
# chose to run an uninstaller by name; -WhatIf is the safe preview, and -Confirm still
# works for anyone who wants the prompt.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $InstallRoot  = (Join-Path $env:LOCALAPPDATA 'Programs\Heresay'),
    [string] $RegistryRoot,
    [string] $ManifestPath,
    [string] $LogPath,
    [switch] $KeepLogs,
    [switch] $RemoveUnlisted,
    [switch] $KeepDownloadCache,
    [switch] $Fallback,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install-Common.ps1 sits next to this script both in the source tree and in the
# install root, because the installer stages both.
$common = Join-Path $PSScriptRoot 'Install-Common.ps1'
if (-not (Test-Path -LiteralPath $common)) { throw "Cannot find Install-Common.ps1 next to this script ($PSScriptRoot)." }
. $common
$script:HERESAY_Quiet = [bool]$Quiet

if (-not $LogPath) {
    $LogPath = Join-Path ([System.IO.Path]::GetTempPath()) ("Heresay-uninstall-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $PID)
}
Initialize-HeresayLog -Path $LogPath -Activity 'uninstaller'

# The installer stages a copy of this script INSIDE the install root. When that copy is
# run, it must uninstall the install it belongs to - not whatever happens to live at the
# default location. Without this, uninstalling a custom-location install silently reports
# "nothing to do" and leaves everything in place.
if (-not $PSBoundParameters.ContainsKey('InstallRoot')) {
    $sibling = Join-Path $PSScriptRoot 'install-manifest.json'
    if (Test-Path -LiteralPath $sibling) {
        $InstallRoot = $PSScriptRoot
        Write-Verbose "Running from inside an install; targeting $InstallRoot"
    }
}

$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$dryRun = -not $PSCmdlet.ShouldProcess($InstallRoot, 'Uninstall Heresay')

if (-not $Quiet) {
    Write-Host ''
    Write-Host "  $script:HERESAY_ProductName uninstaller" -ForegroundColor White
    if ($dryRun) { Write-Host '  DRY RUN - nothing will be removed' -ForegroundColor Yellow }
    Write-Host "  target: $InstallRoot"
    Write-Host ''
}

$removed    = New-Object System.Collections.ArrayList
$notRemoved = New-Object System.Collections.ArrayList
$leftAlone  = New-Object System.Collections.ArrayList

function Remove-HeresayPath {
    param([string] $Path, [string] $Kind = 'file')
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if ($dryRun) { Write-HeresayInfo "would remove $Kind`: $Path"; return $true }
    try {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop
        [void]$removed.Add([pscustomobject]@{ Kind = $Kind; Path = $Path })
        return $true
    }
    catch {
        [void]$notRemoved.Add([pscustomobject]@{ Kind = $Kind; Path = $Path; Reason = $_.Exception.Message })
        return $false
    }
}

# =============================================================== 1. MANIFEST ==

if (-not $ManifestPath) { $ManifestPath = Get-HeresayInstallManifestPath -InstallRoot $InstallRoot }
$manifest = $null
if (Test-Path -LiteralPath $ManifestPath) {
    try {
        $manifest = Read-HeresayJsonFile -Path $ManifestPath
        Write-HeresayStep "Reading $ManifestPath"
        Write-HeresayInfo "installed $($manifest.installedUtc) as version $($manifest.version)"
        Write-HeresayInfo "records $(@($manifest.files).Count) file(s), $(@($manifest.registryKeys).Count) registry key(s)"
    }
    catch { Write-HeresayWarn "install-manifest.json is unreadable ($($_.Exception.Message))." }
}

if (-not $manifest) {
    if (-not (Test-Path -LiteralPath $InstallRoot) -and -not $Fallback) {
        Write-HeresayLog "nothing to do: '$InstallRoot' does not exist and there is no manifest"
        Write-Host "  Nothing to do: '$InstallRoot' does not exist and there is no manifest." -ForegroundColor Green
        Write-Host '  (This script is safe to run repeatedly.)'
        Write-Host "  log: $LogPath"
        exit 0
    }
    if (-not $Fallback) {
        Write-HeresayFail "No usable install-manifest.json at '$ManifestPath'."
        Write-Host ''
        Write-Host '  Without the manifest this script cannot prove what belongs to Heresay.' -ForegroundColor Yellow
        Write-Host '  Re-run with -Fallback to remove the well-known paths and registry keys instead.' -ForegroundColor Yellow
        Write-HeresayLog 'uninstall stopped because no usable manifest was available' 'ERROR'
        Write-Host "  log: $LogPath"
        exit 1
    }
    Write-HeresayWarn 'Running in -Fallback mode: removing well-known locations rather than a recorded manifest. This is a best guess.'
}

# Registry root: prefer what the manifest recorded, so an install into a scratch root
# uninstalls from that same scratch root.
if (-not $RegistryRoot) {
    $RegistryRoot = 'HKCU:\Software\Classes'
    if ($manifest -and @($manifest.registryValues).Count) {
        $sample = @($manifest.registryValues)[0].key
        if ($sample -match '^(?<root>.*?)\\SystemFileAssociations\\') { $RegistryRoot = $Matches['root'] }
    }
    elseif ($manifest -and @($manifest.registryKeys).Count) {
        $sample = @($manifest.registryKeys | Where-Object { $_ -like '*SystemFileAssociations*' }) | Select-Object -First 1
        if ($sample -and $sample -match '^(?<root>.*?)\\SystemFileAssociations') { $RegistryRoot = $Matches['root'] }
    }
}
Write-HeresayInfo "registry root: $RegistryRoot"

# ========================================================== 2. SHELL VERB ==

Write-HeresayStep 'Removing the Explorer right-click verb'
$regScript = @(
    (Join-Path $InstallRoot 'app\Register-ShellVerbs.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'app\Register-ShellVerbs.ps1')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$verbRemovalOk = $true
# Declared out here because the verification step below also needs it.
$extraExts = @('.amr', '.flv', '.caf')
if ($regScript) {
    if ($manifest -and (@($manifest.registryKeys).Count -or (($manifest.PSObject.Properties.Name -contains 'verbKeys') -and @($manifest.verbKeys).Count))) {
        # Recover the exact extension set this install registered, rather than assuming
        # today's defaults match what was installed months ago.
        # verbKeys is preferred: registryKeys only lists ancestor keys this install
        # actually created, so a repair install over an existing registration records none.
        $src = @()
        if ($manifest.PSObject.Properties.Name -contains 'verbKeys') { $src = @($manifest.verbKeys) }
        if (-not $src.Count) { $src = @($manifest.registryKeys) }
        $found = @($src |
            ForEach-Object {
                if ($_ -match '\\SystemFileAssociations\\(?<s>\.[^\\]+)(\\|$)') { $Matches['s'] }
            } |
            Select-Object -Unique)
        if ($found.Count) { $extraExts = $found }
    }
    Write-HeresayInfo "extensions recorded by this install: $($extraExts -join ', ')"
    $u = & $regScript -InstallRoot $InstallRoot -RegistryRoot $RegistryRoot -ExtraExtensions $extraExts -Unregister -WhatIf:$dryRun
    foreach ($r in $u.Removed) {
        if ($r.Status -eq 'AlreadyAbsent') { Write-HeresayInfo "already gone: $($r.KeyPath)" }
        else { Write-HeresayOk "$($r.Status): $($r.KeyPath)"; [void]$removed.Add([pscustomobject]@{ Kind = 'registry key'; Path = $r.KeyPath }) }
    }
    foreach ($r in $u.NotRemoved) {
        Write-HeresayFail "could not remove $($r.KeyPath): $($r.Reason)"
        [void]$notRemoved.Add([pscustomobject]@{ Kind = 'registry key'; Path = $r.KeyPath; Reason = $r.Reason })
        $verbRemovalOk = $false
    }
}
else {
    Write-HeresayWarn 'Register-ShellVerbs.ps1 not found; removing the recorded keys directly.'
    $keys = @()
    if ($manifest) { $keys = @($manifest.registryKeys | Where-Object { $_ -like '*\shell\Heresay*' }) }
    if (-not $keys.Count) {
        $keys = @('audio', 'video', '.amr', '.flv', '.caf') | ForEach-Object { "$RegistryRoot\SystemFileAssociations\$_\shell\Heresay" }
    }
    foreach ($k in ($keys | Sort-Object -Property Length -Descending)) {
        if (-not (Remove-HeresayPath -Path $k -Kind 'registry key')) { $verbRemovalOk = $false }
    }
}


# --- recorder background verb (Register-RecordVerb.ps1) ----------------------
# Register-RecordVerb.ps1 owns the DesktopBackground and Directory\Background
# right-click keys. They share no keys with Register-ShellVerbs.ps1 (which owns
# the per-file verb), so they must be cleaned up separately.
$recordVerbScript = @(
    (Join-Path $InstallRoot 'app\Register-RecordVerb.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'app\Register-RecordVerb.ps1')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($recordVerbScript) {
    $rv = & $recordVerbScript -InstallRoot $InstallRoot -RegistryRoot $RegistryRoot -Unregister -WhatIf:$dryRun
    foreach ($r in $rv.Removed) {
        Write-HeresayOk "removed: $r"
        [void]$removed.Add([pscustomobject]@{ Kind = 'registry key'; Path = $r })
    }
    foreach ($r in $rv.NotRemoved) {
        Write-HeresayFail "could not remove $($r.Path): $($r.Reason)"
        [void]$notRemoved.Add([pscustomobject]@{ Kind = 'registry key'; Path = $r.Path; Reason = $r.Reason })
    }
}
else {
    Write-HeresayWarn 'Register-RecordVerb.ps1 not found; removing the known background-verb keys directly.'
    foreach ($k in @(
            'HKCU:\Software\Classes\DesktopBackground\Shell\HeresayRecordConversation',
            'HKCU:\Software\Classes\Directory\Background\shell\HeresayRecordConversation')) {
        Remove-HeresayPath -Path $k -Kind 'registry key' | Out-Null
    }
}
# ============================================================== 3. FILES ==

Write-HeresayStep 'Removing installed files'
$knownFiles = @()
if ($manifest) { $knownFiles = @($manifest.files | ForEach-Object { $_.path }) }

$removedFiles = 0
foreach ($f in $knownFiles) {
    if ($KeepLogs -and $f -like (Join-Path $InstallRoot 'logs\*')) { [void]$leftAlone.Add($f); continue }
    if (Test-Path -LiteralPath $f) { if (Remove-HeresayPath -Path $f -Kind 'file') { $removedFiles++ } }
}
Write-HeresayOk "$removedFiles recorded file(s) removed"

# Runtime artefacts the installer could not have recorded, because they are created
# when the app runs: logs, the queue, batch event streams, the staged uninstaller.
$runtime = @(
    (Join-Path $InstallRoot 'logs\queue'),
    (Join-Path $InstallRoot 'logs\queue.lock'),
    (Join-Path $InstallRoot 'logs\batch-state.json'),
    (Join-Path $InstallRoot 'install-manifest.json')
)
if (-not $KeepLogs) {
    $runtime += @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'logs') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
foreach ($r in $runtime) { Remove-HeresayPath -Path $r -Kind 'runtime file' | Out-Null }

# --- Start Menu ---------------------------------------------------------------
# The manifest's files[] already carries the shortcut this install created, and the
# loop above removed it. This sweep exists for what the manifest CANNOT know: an older
# install's 'Heresay - Transcribe new conversation.lnk' that a later install swept and
# therefore never recorded, or a current 'Heresay.lnk' left by an install whose manifest
# was lost. Both live outside the install root, so nothing else here would ever reach
# them, and a Start entry that outlives the app is the exact failure the Send To names
# caused twice. Remove-HeresayPath honours the dry run and records what it removed.
$startMenuDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Start Menu\Programs'
foreach ($lnkName in @('Heresay', 'Heresay - Transcribe new conversation')) {
    Remove-HeresayPath -Path (Join-Path $startMenuDir ($lnkName + '.lnk')) -Kind 'Start Menu shortcut' | Out-Null
}

# Anything still under the install root that the manifest never mentioned.
if (Test-Path -LiteralPath $InstallRoot) {
    $known = @{}
    foreach ($f in $knownFiles) { $known[$f.ToLowerInvariant()] = $true }
    $unlisted = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { -not $known.ContainsKey($_.FullName.ToLowerInvariant()) })
    if ($unlisted.Count) {
        if ($RemoveUnlisted) {
            Write-HeresayWarn "$($unlisted.Count) unlisted file(s) found; -RemoveUnlisted was given, removing them."
            foreach ($u in $unlisted) { Remove-HeresayPath -Path $u.FullName -Kind 'unlisted file' | Out-Null }
        }
        else {
            Write-HeresayWarn "$($unlisted.Count) file(s) under the install root are not in the manifest and were LEFT IN PLACE:"
            foreach ($u in ($unlisted | Select-Object -First 15)) {
                Write-HeresayInfo "    $($u.FullName)"
                [void]$leftAlone.Add($u.FullName)
            }
            if ($unlisted.Count -gt 15) { Write-HeresayInfo "    ... and $($unlisted.Count - 15) more" }
            Write-HeresayInfo 'Re-run with -RemoveUnlisted to delete these too.'
        }
    }
}

# ========================================================= 4. DIRECTORIES ==

Write-HeresayStep 'Removing empty directories'
$dirs = @()
if ($manifest) { $dirs = @($manifest.directories) }
if (-not $dirs.Count -and (Test-Path -LiteralPath $InstallRoot)) {
    $dirs = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $dirs += $InstallRoot
}
# Deepest first, so a parent is empty by the time we reach it.
foreach ($d in ($dirs | Sort-Object -Property Length -Descending)) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    $remaining = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) { Remove-HeresayPath -Path $d -Kind 'directory' | Out-Null }
    else { Write-HeresayInfo "kept (not empty): $d" ; [void]$leftAlone.Add($d) }
}
if ((Test-Path -LiteralPath $InstallRoot) -and @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
    Remove-HeresayPath -Path $InstallRoot -Kind 'directory' | Out-Null
}

# --- download cache -----------------------------------------------------------
$cache = Join-Path $env:LOCALAPPDATA 'Heresay\downloads'
if (Test-Path -LiteralPath $cache) {
    if ($KeepDownloadCache) { Write-HeresayInfo "download cache kept: $cache" ; [void]$leftAlone.Add($cache) }
    else {
        $size = (Get-ChildItem -LiteralPath $cache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        Write-HeresayInfo "removing download cache ($(Format-HeresayBytes ([long]$size))): $cache"
        Remove-HeresayPath -Path (Join-Path $env:LOCALAPPDATA 'Heresay') -Kind 'download cache' | Out-Null
    }
}


# --- per-user state -----------------------------------------------------------
# settings.json lives outside the install root and is never recorded in the
# manifest, so nothing above would remove it. Delete it, then prune the
# containing directory if it is now empty.
$userStateDir     = Join-Path $env:LOCALAPPDATA 'Heresay'
$userSettingsFile = Join-Path $userStateDir 'settings.json'
if (Test-Path -LiteralPath $userSettingsFile) {
    Write-HeresayInfo "removing per-user settings: $userSettingsFile"
    Remove-HeresayPath -Path $userSettingsFile -Kind 'settings file' | Out-Null
}
if ((Test-Path -LiteralPath $userStateDir) -and
    @(Get-ChildItem -LiteralPath $userStateDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
    Write-HeresayInfo "removing empty per-user state directory: $userStateDir"
    Remove-HeresayPath -Path $userStateDir -Kind 'directory' | Out-Null
}
# ============================================================ 5. VERIFY ==

Write-HeresayStep 'Verifying removal'
$verifyOk = $true

# Verify with plain Test-Path against the recorded key list, NOT by re-invoking
# Register-ShellVerbs.ps1 - by this point that script has itself been deleted, so
# calling it again would either fail or silently verify nothing.
if (-not $dryRun) {
    $checkKeys = New-Object System.Collections.ArrayList
    foreach ($s in @('audio', 'video')) {
        [void]$checkKeys.Add([pscustomobject]@{ Kind = 'PerceivedType'; Subject = $s; KeyPath = "$RegistryRoot\SystemFileAssociations\$s\shell\Heresay" })
    }
    foreach ($e in $extraExts) {
        [void]$checkKeys.Add([pscustomobject]@{ Kind = 'Extension'; Subject = $e; KeyPath = "$RegistryRoot\SystemFileAssociations\$e\shell\Heresay" })
    }
    foreach ($c in $checkKeys) {
        if (Test-Path -LiteralPath $c.KeyPath) {
            Write-HeresayFail "right-click entry STILL PRESENT for $($c.Kind) '$($c.Subject)': $($c.KeyPath)"
            $verifyOk = $false
        }
        else { Write-HeresayOk "right-click entry gone for $($c.Kind) '$($c.Subject)'" }
    }
}

if (-not $dryRun) {
    if (Test-Path -LiteralPath $InstallRoot) {
        $left = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue)
        if ($left.Count) { Write-HeresayWarn "$InstallRoot still exists with $($left.Count) item(s) (see the list above)." }
        else { Write-HeresayOk 'install root is empty' }
    }
    else { Write-HeresayOk "install root removed: $InstallRoot" }
}

# =========================================================== 6. SUMMARY ==

Write-Host ''
if ($dryRun) {
    Write-HeresayLog 'dry run complete; nothing was removed'
    Write-Host '  Dry run complete. Nothing was removed.' -ForegroundColor Yellow
    Write-Host "  log: $LogPath"
    Write-Host ''
    exit 0
}

if ($notRemoved.Count -eq 0 -and $verifyOk) {
    Write-HeresayLog "uninstall finished successfully; $($removed.Count) item(s) deleted"
    Write-Host "  $script:HERESAY_ProductName removed. $($removed.Count) item(s) deleted." -ForegroundColor Green
}
else {
    Write-HeresayLog "uninstall incomplete; $($notRemoved.Count) item(s) could not be removed; verification=$verifyOk" 'ERROR'
    Write-Host "  $script:HERESAY_ProductName removal incomplete." -ForegroundColor Red
    foreach ($n in $notRemoved) { Write-Host "    could not remove $($n.Kind): $($n.Path)  ($($n.Reason))" -ForegroundColor Red }
    if (@($notRemoved | Where-Object { $_.Kind -eq 'file' }).Count) {
        Write-Host '    A file in use is the usual cause. Close any running transcription and try again.' -ForegroundColor Yellow
    }
}
if ($leftAlone.Count) {
    Write-Host "  $($leftAlone.Count) item(s) intentionally left in place." -ForegroundColor Yellow
}
Write-Host "  log: $LogPath"
Write-Host ''
if ($notRemoved.Count -or -not $verifyOk) { exit 1 }
exit 0
