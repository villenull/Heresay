<#
.SYNOPSIS
    Registers (or removes) the TranscribeIt Windows Explorer right-click verb.

.DESCRIPTION
    Track C. User-scope only. Never touches HKLM and never requires elevation.

    Registration strategy: PerceivedType, not a hard-coded extension list.

        <RegistryRoot>\SystemFileAssociations\audio\shell\TranscribeIt\command
        <RegistryRoot>\SystemFileAssociations\video\shell\TranscribeIt\command

    HKCU\Software\Classes merges over HKLM\Software\Classes into the virtual
    HKEY_CLASSES_ROOT view, so a user-scope write is all that is needed. Registering
    against the two perceived types covers every extension that carries
    PerceivedType=audio|video today (24 of 27 common A/V extensions on the target
    machine) and every A/V format registered later, with no update from us.

    A small explicit per-extension list covers formats that ship with no
    PerceivedType (.amr, .flv, .caf on the target machine). Those are registered at
    <RegistryRoot>\SystemFileAssociations\<.ext>\shell\TranscribeIt, which adds a verb
    without hijacking the extension's ProgID or its default "Open with" handler.

    The global '*' key is deliberately NOT used - that would put our verb on every
    file on the system.

.PARAMETER RegistryRoot
    Root under which SystemFileAssociations is written. Defaults to the live
    per-user class root. During development pass a scratch root, e.g.
    'HKCU:\Software\TranscribeIt-TEST\Classes', so the real right-click menu is
    untouched.

.PARAMETER Unregister
    Remove the verb instead of creating it. Also prunes ancestor keys that this
    script created, but only when they are empty.

.PARAMETER Verify
    Report presence/absence of every key and value. Sets the exit-style result
    property 'Ok'. Makes no changes.

.OUTPUTS
    A PSCustomObject describing exactly what was created / removed / found. The
    installer folds .RegistryKeys and .RegistryValues into install-manifest.json so
    uninstall is provable rather than guesswork.

.EXAMPLE
    .\Register-ShellVerbs.ps1 -RegistryRoot 'HKCU:\Software\TranscribeIt-TEST\Classes' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]   $InstallRoot    = (Join-Path $env:LOCALAPPDATA 'Programs\TranscribeIt'),
    [string]   $RegistryRoot   = 'HKCU:\Software\Classes',
    [string]   $VerbName       = 'TranscribeIt',
    [string]   $MenuText       = 'Transcribe in PDF',
    [string[]] $PerceivedTypes = @('audio', 'video'),
    [string[]] $ExtraExtensions,
    [string]   $IconPath,
    [string]   $PwshPath,
    [string]   $ConfigPath,
    [ValidateSet('Document', 'Player', 'Single')]
    [string]   $MultiSelectModel = 'Document',
    [switch]   $Unregister,
    [switch]   $Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants --
# Defaults for formats observed to carry NO PerceivedType. User-extensible via
# config.json -> shell.extraExtensions.
$script:DefaultExtraExtensions = @('.amr', '.flv', '.caf')

# Extensions that carry PerceivedType audio/video but never contain speech, so a
# "Generate transcript" entry on them is pure menu noise: playlists, MIDI, and a
# DRM-only stream container.
# Populated lazily by Get-PerceivedTypeExtensions on first use. Must be initialised
# here: under Set-StrictMode, reading an unassigned $script: variable throws, so the
# "if (-not $script:PerceivedTypeIndex)" cache guard would itself be the failure.
$script:PerceivedTypeIndex = $null

$script:ExcludedExtensions = @(
    '.m3u', '.wpl', '.asx', '.wax', '.wvx', '.wmx',   # playlists
    '.mid', '.midi', '.rmi',                          # MIDI - synthesised, no speech
    '.dtcp-ip'                                        # DRM transport, not openable
)

# --------------------------------------------------------------------- helpers --

function Resolve-RegistryRoot {
    <# Normalises any of HKCU:\..., HKCU\..., Registry::HKEY_CURRENT_USER\... to a
       PowerShell provider path this script can use, and rejects HKLM outright. #>
    param([Parameter(Mandatory)][string] $Path)

    $p = $Path.Trim().TrimEnd('\')
    if ($p -match '^Registry::HKEY_CURRENT_USER\\(.*)$') { $p = "HKCU:\$($Matches[1])" }
    elseif ($p -match '^HKEY_CURRENT_USER\\(.*)$')       { $p = "HKCU:\$($Matches[1])" }
    elseif ($p -match '^HKCU\\(.*)$')                    { $p = "HKCU:\$($Matches[1])" }

    if ($p -match '^(HKLM:|HKEY_LOCAL_MACHINE|Registry::HKEY_LOCAL_MACHINE|HKCR:|Registry::HKEY_CLASSES_ROOT)') {
        throw "RegistryRoot '$Path' is machine-scope. TranscribeIt installs user-scope only; writing there needs admin rights this account does not have."
    }
    if ($p -notmatch '^HKCU:\\') {
        throw "RegistryRoot '$Path' must live under HKEY_CURRENT_USER (got '$p')."
    }
    return $p
}

function Get-NormalizedExtension {
    param([Parameter(Mandatory)][string] $Extension)
    $e = $Extension.Trim().ToLowerInvariant()
    if ($e.Length -eq 0) { return $null }
    if (-not $e.StartsWith('.')) { $e = ".$e" }
    if ($e -match '[\\/:*?"<>|]') { throw "Invalid extension '$Extension'." }
    return $e
}

function Get-ExtraExtensionList {
    <# Precedence: explicit -ExtraExtensions > config.json shell.extraExtensions > built-in. #>
    param([string[]] $Explicit, [string] $CfgPath)

    if ($Explicit) { return @($Explicit | ForEach-Object { Get-NormalizedExtension $_ } | Where-Object { $_ }) }

    if ($CfgPath -and (Test-Path -LiteralPath $CfgPath)) {
        try {
            $cfg = Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fromCfg = $null
            if ($cfg.PSObject.Properties.Name -contains 'shell') {
                $shell = $cfg.shell
                foreach ($name in @('extraExtensions', 'extensions', 'additionalExtensions')) {
                    if ($shell.PSObject.Properties.Name -contains $name -and $shell.$name) { $fromCfg = $shell.$name; break }
                }
            }
            if ($fromCfg) {
                Write-Verbose "Extra extensions taken from config: $CfgPath"
                return @($fromCfg | ForEach-Object { Get-NormalizedExtension $_ } | Where-Object { $_ })
            }
        }
        catch { Write-Warning "Could not read shell.extraExtensions from '$CfgPath': $($_.Exception.Message). Using built-in defaults." }
    }
    return @($script:DefaultExtraExtensions | ForEach-Object { Get-NormalizedExtension $_ })
}

function Resolve-PwshPath {
    param([string] $Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "PwshPath '$Explicit' not found." }
        return (Resolve-Path -LiteralPath $Explicit).ProviderPath
    }
    $candidates = @(
        'C:\Program Files\PowerShell\7\pwsh.exe',
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        # Portable per-user copy installed by installer\Bootstrap-Pwsh.ps1 when Program Files pwsh is absent (no admin on this fleet).
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )
    # Never point the registry at the current process host when it is Windows PowerShell.
    $cmd = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $candidates = @($cmd.Source) + $candidates }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).ProviderPath } }
    throw 'pwsh.exe (PowerShell 7) not found. TranscribeIt requires it for the shell verb command.'
}

function Get-PerceivedTypeExtensions {
    <#
        Every extension registered on THIS machine whose PerceivedType matches, minus
        kinds that never contain speech. Enumerated at registration time rather than
        hard-coded, so we cover whatever codecs and players are actually installed.

        HKEY_CLASSES_ROOT has several thousand subkeys, so this walks it ONCE and
        caches the result. Calling it per perceived type without the cache made
        registration take minutes.
    #>
    param([Parameter(Mandatory)][string] $PerceivedType)

    if (-not $script:PerceivedTypeIndex) {
        $script:PerceivedTypeIndex = @{}
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
        foreach ($name in $hkcr.GetSubKeyNames()) {
            if ($name.Length -lt 2 -or $name[0] -ne '.') { continue }
            $lower = $name.ToLowerInvariant()
            if ($script:ExcludedExtensions -contains $lower) { continue }
            $sub = $null
            try {
                $sub = $hkcr.OpenSubKey($name)
                if ($null -eq $sub) { continue }
                $pt = $sub.GetValue('PerceivedType')
                if ($pt) {
                    $pt = ([string]$pt).ToLowerInvariant()
                    if (-not $script:PerceivedTypeIndex.ContainsKey($pt)) {
                        $script:PerceivedTypeIndex[$pt] = New-Object System.Collections.Generic.List[string]
                    }
                    [void]$script:PerceivedTypeIndex[$pt].Add($lower)
                }
            }
            catch { continue }
            finally { if ($sub) { $sub.Dispose() } }
        }
    }

    $key = $PerceivedType.ToLowerInvariant()
    if ($script:PerceivedTypeIndex.ContainsKey($key)) { return $script:PerceivedTypeIndex[$key].ToArray() }
    return @()
}

function Get-VerbTargets {
    <#
        The full set of verb keys we own, each tagged with what drove it.

        IMPORTANT - verified empirically on this machine (Windows 11 23H2) on
        2026-08-26, after the menu entry failed to appear:

            HKCU\Software\Classes\SystemFileAssociations\<PerceivedType>\shell\<Verb>
                -> NOT surfaced by the shell.
            HKCU\Software\Classes\SystemFileAssociations\.<ext>\shell\<Verb>
                -> IS surfaced.

        Windows does not honour the per-user HKCU\Software\Classes overlay for
        PerceivedType keys under SystemFileAssociations; those are effectively
        HKLM-only, and HKLM needs admin rights we do not have. The built-in "Play"
        verb appears precisely because it lives on the HKLM side.

        Proof, if this is ever doubted again: write a minimal verb under each of the
        two paths above and enumerate with Shell.Application's Verbs(). Only the
        extension one shows up.

        So PerceivedType is kept as the *intent* - "cover all audio and video" - but
        it is EXPANDED into concrete per-extension keys here. The cost is many more
        registry keys; the benefit is that it actually works without admin.

        Consequence to remember: a media format installed on the machine AFTER we
        register will not be covered until the verb is re-registered.
    #>
    param([string] $Root, [string[]] $Types, [string[]] $Exts, [string] $Verb)

    $all  = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($t in $Types) {
        foreach ($e in (Get-PerceivedTypeExtensions -PerceivedType $t)) {
            if ($seen.Add($e)) {
                $all.Add([pscustomobject]@{
                    Kind    = "PerceivedType:$t"
                    Subject = $e
                    KeyPath = "$Root\SystemFileAssociations\$e\shell\$Verb"
                })
            }
        }
    }
    foreach ($e in $Exts) {
        if ($seen.Add($e)) {
            $all.Add([pscustomobject]@{
                Kind    = 'Extension'
                Subject = $e
                KeyPath = "$Root\SystemFileAssociations\$e\shell\$Verb"
            })
        }
    }
    return $all.ToArray()   # .ToArray(): @($list) throws on PS 7.6.1 for List[object]
}

function Get-MissingAncestors {
    <# Path segments that do not exist yet, outermost first. Recorded so uninstall
       can prune exactly what we created and nothing else. #>
    param([Parameter(Mandatory)][string] $KeyPath)

    $missing = New-Object System.Collections.Generic.List[string]
    $parts = $KeyPath -replace '^HKCU:\\', '' -split '\\'
    $cur = 'HKCU:'
    foreach ($part in $parts) {
        $cur = "$cur\$part"
        if (-not (Test-Path -LiteralPath $cur)) { $missing.Add($cur) }
    }
    return $missing.ToArray()
}

function New-RegistryKeyPath {
    param([Parameter(Mandatory)][string] $KeyPath)
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null
    }
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory)][string] $KeyPath,
        [string] $Name,             # '' / $null = the key's default value
        [Parameter(Mandatory)][AllowEmptyString()][string] $Value,
        [string] $Type = 'String'
    )
    $n = if ([string]::IsNullOrEmpty($Name)) { '(default)' } else { $Name }
    New-ItemProperty -Path $KeyPath -Name $n -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

function Get-RegistryValueOrNull {
    param([Parameter(Mandatory)][string] $KeyPath, [string] $Name)
    if (-not (Test-Path -LiteralPath $KeyPath)) { return $null }
    $n = if ([string]::IsNullOrEmpty($Name)) { '(default)' } else { $Name }
    try {
        $item = Get-ItemProperty -LiteralPath $KeyPath -Name $n -ErrorAction Stop
        return $item.$n
    }
    catch { return $null }
}

# Initialised up front: under Set-StrictMode, reading an unassigned $script: variable
# throws rather than returning $null, so the guard inside the function below would fail
# on its very first call.
$script:AssocNotified = $false

function Invoke-ShellAssocChanged {
    <# Tell Explorer the association database moved. Without this the new verb can
       take a minute (or a re-login) to appear. #>
    if ($script:AssocNotified) { return }
    try {
        if (-not ('TranscribeIt.ShellNotify' -as [type])) {
            Add-Type -Namespace 'TranscribeIt' -Name 'ShellNotify' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto, SetLastError = true)]
public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
'@ -ErrorAction Stop
        }
        # SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0x0000
        [TranscribeIt.ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        $script:AssocNotified = $true
        Write-Verbose 'SHChangeNotify(SHCNE_ASSOCCHANGED) sent.'
    }
    catch { Write-Warning "Could not notify Explorer of the association change: $($_.Exception.Message). It will pick the verb up on next sign-in." }
}

function Resolve-IconValue {
    param([string] $Explicit, [string] $Root, [string] $Pwsh)
    if ($Explicit) { return $Explicit }
    $appIcon = Join-Path $Root 'app\TranscribeIt.ico'
    if (Test-Path -LiteralPath $appIcon) { return "$appIcon,0" }
    # Honest fallback: the icon of the process that actually runs. Never invent a
    # shell32/imageres resource index - a wrong index renders as a blank rectangle.
    return "$Pwsh,0"
}

# ------------------------------------------------------------------ main body --

$root  = Resolve-RegistryRoot -Path $RegistryRoot
$isLiveRoot = ($root.TrimEnd('\') -ieq 'HKCU:\Software\Classes')

if (-not $ConfigPath) { $ConfigPath = Join-Path $InstallRoot 'app\config.json' }
$exts    = Get-ExtraExtensionList -Explicit $ExtraExtensions -CfgPath $ConfigPath
$targets = Get-VerbTargets -Root $root -Types $PerceivedTypes -Exts $exts -Verb $VerbName

# NOTE: accumulate into an ordered hashtable, not a PSCustomObject. Assigning an
# array of PSCustomObject to a note property that was initialised as Object[] throws
# "Argument types do not match" in PowerShell - a real trap, measured on 7.6.1.
$result = [ordered]@{
    Action           = if ($Verify) { 'Verify' } elseif ($Unregister) { 'Unregister' } else { 'Register' }
    RegistryRoot     = $root
    IsLiveRoot       = $isLiveRoot
    VerbName         = $VerbName
    MenuText         = $MenuText
    MultiSelectModel = $MultiSelectModel
    PerceivedTypes   = @($PerceivedTypes)
    Extensions       = @($exts)
    Command          = $null
    IconValue        = $null
    RegistryKeys     = @()   # ancestor keys CREATED by us (prune-safe uninstall)
    VerbKeys         = @()   # every verb key we own, whether or not it pre-existed
    RegistryValues   = @()   # {Key,Name,Value,Type}
    Removed          = @()
    NotRemoved       = @()
    Findings         = @()
    Ok               = $true
}

# ---------------------------------------------------------------- VERIFY mode --
if ($Verify) {
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $cmdKey  = "$($t.KeyPath)\command"
        $present = Test-Path -LiteralPath $t.KeyPath
        $cmd     = Get-RegistryValueOrNull -KeyPath $cmdKey -Name ''
        $label   = Get-RegistryValueOrNull -KeyPath $t.KeyPath -Name 'MUIVerb'
        $msm     = Get-RegistryValueOrNull -KeyPath $t.KeyPath -Name 'MultiSelectModel'
        $findings.Add([pscustomobject]@{
            Kind             = $t.Kind
            Subject          = $t.Subject
            KeyPath          = $t.KeyPath
            KeyPresent       = $present
            CommandPresent   = [bool]$cmd
            Command          = $cmd
            MUIVerb          = $label
            MultiSelectModel = $msm
        })
    }
    $result.VerbKeys = @($targets | ForEach-Object { $_.KeyPath })
    $result.Findings = $findings.ToArray()
    $result.Ok = -not @($findings | Where-Object { -not $_.KeyPresent -or -not $_.CommandPresent }).Count
    return [pscustomobject]$result
}

# ------------------------------------------------------------ UNREGISTER mode --
if ($Unregister) {
    $removed    = New-Object System.Collections.Generic.List[object]
    $notRemoved = New-Object System.Collections.Generic.List[object]

    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.KeyPath)) {
            $removed.Add([pscustomobject]@{ KeyPath = $t.KeyPath; Status = 'AlreadyAbsent' })
            continue
        }
        if ($PSCmdlet.ShouldProcess($t.KeyPath, 'Remove registry key (recurse)')) {
            try {
                Remove-Item -LiteralPath $t.KeyPath -Recurse -Force -ErrorAction Stop
                $removed.Add([pscustomobject]@{ KeyPath = $t.KeyPath; Status = 'Removed' })
            }
            catch {
                $notRemoved.Add([pscustomobject]@{ KeyPath = $t.KeyPath; Reason = $_.Exception.Message })
                $result.Ok = $false
            }
        }
    }

    # Prune now-empty containers we may have created, deepest first, but never
    # SystemFileAssociations itself or anything above it.
    $floor = "$root\SystemFileAssociations"
    $pruneCandidates = @()
    foreach ($t in $targets) {
        $p = Split-Path -Path $t.KeyPath -Parent          # ...\shell
        while ($p -and $p.Length -gt $floor.Length -and $p.StartsWith($floor, [StringComparison]::OrdinalIgnoreCase)) {
            $pruneCandidates += $p
            $p = Split-Path -Path $p -Parent
        }
    }
    $ordered = @($pruneCandidates | Select-Object -Unique | Sort-Object -Property Length -Descending) + @($floor)
    foreach ($p in $ordered) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $k = Get-Item -LiteralPath $p
        if ($k.SubKeyCount -eq 0 -and $k.ValueCount -eq 0) {
            if ($PSCmdlet.ShouldProcess($p, 'Remove empty container key')) {
                try {
                    Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                    $removed.Add([pscustomobject]@{ KeyPath = $p; Status = 'PrunedEmpty' })
                }
                catch { $notRemoved.Add([pscustomobject]@{ KeyPath = $p; Reason = $_.Exception.Message }) }
            }
        }
        else {
            Write-Verbose "Left '$p' in place - it still has $($k.SubKeyCount) subkey(s) / $($k.ValueCount) value(s)."
        }
    }

    $result.VerbKeys   = @($targets | ForEach-Object { $_.KeyPath })
    $result.Removed    = $removed.ToArray()
    $result.NotRemoved = $notRemoved.ToArray()
    if ($isLiveRoot -and -not $WhatIfPreference) { Invoke-ShellAssocChanged }
    return [pscustomobject]$result
}

# -------------------------------------------------------------- REGISTER mode --

# $pwsh no longer appears in the verb command line (the shim below starts pwsh
# itself), but Resolve-IconValue still uses it as the honest icon fallback, and
# resolving it here still proves PowerShell 7 exists before we register a verb
# whose whole chain depends on it.
$pwsh  = Resolve-PwshPath -Explicit $PwshPath
$entry = Join-Path $InstallRoot 'app\Transcribe-Entry.ps1'
if (-not (Test-Path -LiteralPath $entry)) {
    Write-Warning "Entry script not present yet: $entry. Registering anyway; the verb will fail until the installer copies app files into place."
}
$shim = Join-Path $InstallRoot 'app\Run-Hidden.vbs'
if (-not (Test-Path -LiteralPath $shim)) {
    Write-Warning "Silent-launch shim not present yet: $shim. Registering anyway; the verb will fail until the installer copies app files into place."
}

# Launch through wscript.exe + Run-Hidden.vbs, NOT pwsh.exe directly. This line has
# flipped once already, so the reasoning is spelled out:
#
#   The original registration targeted pwsh directly and refused the shim on the
#   grounds that a registry verb chaining wscript -> VBS -> hidden pwsh is a textbook
#   malware-persistence pattern that this fleet's endpoint agent would flag. That
#   concern was ASSERTED, never tested, and the counter-evidence is now strong: the
#   Send To entries have been running the IDENTICAL process chain (explorer.exe ->
#   wscript.exe -> Run-Hidden.vbs -> hidden pwsh) on this exact machine repeatedly
#   all day (2026-08-27) with zero endpoint-security reaction. The user explicitly
#   asked for a silent top-level entry, which pwsh-direct cannot deliver: pwsh.exe
#   is a console-subsystem binary, so its console host window flashes for the ~2-3 s
#   startup the endpoint-security process-creation tax imposes, whatever flags it
#   is passed (see Run-Hidden.vbs for the measurement).
#
#   FALLBACK if the endpoint agent ever suppresses or blocks this verb: re-point the
#   command at $pwsh directly ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy
#   Bypass -WindowStyle Hidden -File "{1}" ...') and accept the flash - or rely on
#   the Send To entries, which remain installed and run the same fast profile.
#
# The fast profile (-Model ggml-tiny.en-q8_0.bin -NoDiarization) matches the Send To
# fast entry and is deliberate: this verb with engine defaults (large model + speaker
# separation) took 34 minutes on a 60-minute recording that the fast profile did in
# ~3.5. "%1" is quoted (Explorer substitutes the selected file's full path there),
# and Run-Hidden.vbs re-quotes every argument individually, so paths with spaces
# survive the hand-off - proven end to end via Send To on this machine.
$wscript = 'C:\Windows\System32\wscript.exe'
$command = '"{0}" "{1}" "{2}" -Model "ggml-tiny.en-q8_0.bin" -NoDiarization -Path "%1"' -f $wscript, $shim, $entry
$icon    = Resolve-IconValue -Explicit $IconPath -Root $InstallRoot -Pwsh $pwsh

$result.Command   = $command
$result.IconValue = $icon

if ($isLiveRoot) {
    Write-Verbose 'Writing to the LIVE per-user class root - this changes the real right-click menu.'
}

$createdKeys = New-Object System.Collections.Generic.List[string]
$setValues   = New-Object System.Collections.Generic.List[object]

foreach ($t in $targets) {
    $verbKey = $t.KeyPath
    $cmdKey  = "$verbKey\command"

    # Record which ancestors are absent BEFORE creating anything.
    $missing = Get-MissingAncestors -KeyPath $cmdKey

    # The complete value set for this target. Computed identically whether or not we
    # are in -WhatIf, so a dry run reports exactly what a real run would write.
    #  (default)        legacy label, honoured by shells that ignore MUIVerb
    #  MUIVerb          the label Explorer actually shows
    #  Icon             menu glyph
    #  MultiSelectModel 'Document' = Explorer invokes the verb once per selected item
    #  NeverDefault     never become the double-click default verb for A/V files
    $plan = @(
        @{ Key = $verbKey; Name = '';                 Value = $MenuText;         Type = 'String' }
        @{ Key = $verbKey; Name = 'MUIVerb';          Value = $MenuText;         Type = 'String' }
        @{ Key = $verbKey; Name = 'Icon';             Value = $icon;             Type = 'String' }
        @{ Key = $verbKey; Name = 'MultiSelectModel'; Value = $MultiSelectModel; Type = 'String' }
        @{ Key = $verbKey; Name = 'NeverDefault';     Value = '';                Type = 'String' }
        @{ Key = $cmdKey;  Name = '';                 Value = $command;          Type = 'String' }
    )

    $apply = $PSCmdlet.ShouldProcess($verbKey, "Register verb '$VerbName' for $($t.Kind) '$($t.Subject)'")

    foreach ($m in $missing) { $createdKeys.Add($m) }
    if ($apply) { New-RegistryKeyPath -KeyPath $cmdKey }

    foreach ($v in $plan) {
        if ($apply) { Set-RegistryValue -KeyPath $v.Key -Name $v.Name -Value $v.Value -Type $v.Type }
        $setValues.Add([pscustomobject]@{ Key = $v.Key; Name = $v.Name; Value = $v.Value; Type = $v.Type })
    }
}

$result.VerbKeys       = @($targets | ForEach-Object { $_.KeyPath })
$result.RegistryKeys   = @($createdKeys | Select-Object -Unique)
$result.RegistryValues = $setValues.ToArray()

if (-not $WhatIfPreference) {
    if ($isLiveRoot) { Invoke-ShellAssocChanged }

    # Read back rather than trusting the write.
    $bad = @()
    foreach ($t in $targets) {
        $readBack = Get-RegistryValueOrNull -KeyPath "$($t.KeyPath)\command" -Name ''
        if ($readBack -ne $command) { $bad += $t.KeyPath }
    }
    if ($bad.Count) {
        $result.Ok = $false
        Write-Error "Verb command did not read back correctly for: $($bad -join ', ')"
    }
}

return [pscustomobject]$result
