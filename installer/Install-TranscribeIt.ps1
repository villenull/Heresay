<#
.SYNOPSIS
    Installs TranscribeIt for the current user. No admin rights, ever.

.DESCRIPTION
    Track C. Everything lands under %LOCALAPPDATA%\Programs\TranscribeIt and
    HKCU\Software\Classes. Nothing is written to HKLM or C:\Program Files, and no
    elevation is attempted at any point.

    Order of work:
      1. preflight - refuse to start if the machine cannot support the app
      2. download  - manifest-driven, resumable, SHA-256 verified
      3. extract   - into bin\, models\
      3b. derive   - quantise the DEFAULT speech model from hash-verified f16 weights,
                     then delete the 1.55 GiB source. It is derived rather than downloaded
                     because no upstream publishes a q4_0 large-v3-turbo, and shipping a
                     file that exists only on one laptop is not an install.
      4. app files - copy app\*, write app\config.json from Track A's defaults
      5. register  - the Explorer right-click verb
      6. manifest  - record every file and registry key created
      7. smoke test - prove the binaries actually run on this machine

    Run with -WhatIf first to see exactly what it would do.

.PARAMETER InstallRoot
    Defaults to %LOCALAPPDATA%\Programs\TranscribeIt.

.PARAMETER RegistryRoot
    Where the shell verb is registered. Defaults to the live per-user class root. Pass
    a scratch root to rehearse without touching the real right-click menu.

.PARAMETER SkipDownloads
    Install the scripts and the shell verb but do not fetch binaries or models. Useful
    while the other tracks are still in flight.

.PARAMETER SkipShellRegistration
    Install everything but leave the right-click menu alone.

.PARAMETER SkipSendTo
    Install everything but leave the four "Send to -> Heresay" entries alone. Use this
    together with a scratch -InstallRoot to rehearse a full install without repointing the
    real Send To entries - they live at a fixed path outside the install root, so a
    rehearsal would otherwise aim the live menu at a temporary directory.

.PARAMETER Repair
    Re-copy app files and re-register even if the install already looks complete.

.EXAMPLE
    .\Install-TranscribeIt.ps1 -WhatIf
.EXAMPLE
    .\Install-TranscribeIt.ps1 -SkipDownloads -RegistryRoot 'HKCU:\Software\TranscribeIt-TEST\Classes'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $InstallRoot  = (Join-Path $env:LOCALAPPDATA 'Programs\TranscribeIt'),
    [string] $RegistryRoot = 'HKCU:\Software\Classes',
    [string] $SourceRoot,
    [string] $ManifestPath,
    [string] $DownloadCache,
    [string] $Version = '2.0.0',
    # 7, not 2. A clean install now peaks near 5.9 GB because the DEFAULT speech model is
    # quantised locally from 1.55 GiB of f16 weights that are deleted afterwards - see
    # section 3b. 2 GB was already marginal before that; it would now let an install start
    # that cannot finish.
    [int]    $MinFreeGB = 7,
    [switch] $SkipDownloads,
    [switch] $SkipShellRegistration,
    # The Send To entries are the only UI this tool actually has on this machine, and they
    # live OUTSIDE the install root at a fixed path - so a rehearsal into a scratch
    # InstallRoot would otherwise overwrite the four real ones and point them at a
    # temporary directory. -RegistryRoot already exists to keep a rehearsal off the real
    # right-click menu; this is the same idea for the menu that is actually used.
    [switch] $SkipSendTo,
    [switch] $SkipSmokeTest,
    [switch] $Repair,
    [switch] $Force,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Install-Common.ps1')
$script:TI_Quiet = [bool]$Quiet

$dryRun = -not $PSCmdlet.ShouldProcess($InstallRoot, 'Install TranscribeIt')

if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if (-not $DownloadCache) { $DownloadCache = Join-Path $env:LOCALAPPDATA 'TranscribeIt\downloads' }

$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$logPath = Join-Path $InstallRoot 'logs\install.log'
# Log to a temp file until preflight passes, then relocate. Creating <root>\logs\ before
# we know the install can proceed would leave debris behind on an abort.
if (-not $dryRun) {
    Initialize-TiLog -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("TranscribeIt-install-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $PID))
}

# App scripts owned by the various tracks. Missing ones are reported, not fatal, so the
# installer is usable before every track has landed.
$appFiles = @(
    @{ Name = 'Transcribe-Entry.ps1';    Owner = 'Track C'; Required = $true  }
    @{ Name = 'Register-ShellVerbs.ps1'; Owner = 'Track C'; Required = $true  }
    @{ Name = 'Transcribe.ps1';          Owner = 'Track A'; Required = $false }
    @{ Name = 'Merge-Diarization.ps1';   Owner = 'Track A'; Required = $false }
    @{ Name = 'Render-Pdf.ps1';          Owner = 'Track B'; Required = $false }
    @{ Name = 'template.html';           Owner = 'Track B'; Required = $false }
    @{ Name = 'Progress.ps1';            Owner = 'Track E'; Required = $false }
    # The engine loads config.default.json as its REQUIRED base and overlays config.json
    # on top, so the base must ship too - otherwise the engine throws "Missing
    # config.default.json" on the very first run of an otherwise successful install.
    @{ Name = 'config.default.json';     Owner = 'Track A'; Required = $true  }
    # v2. The Send To wrapper is how the tool is actually reached on this machine -
    # Explorer's context-menu verb is suppressed by the endpoint security hooks - so it
    # is REQUIRED, not optional.
    @{ Name = 'SendTo-Heresay.ps1';      Owner = 'v2';      Required = $true  }
    @{ Name = 'Compress-ForWord.ps1';    Owner = 'v2';      Required = $false }
    # v2. GUI-subsystem launch shim: the Send To .lnk targets wscript.exe running this
    # file (a console-subsystem pwsh target flashes its console for ~2.3 s before
    # -WindowStyle Hidden takes effect). REQUIRED because a missing shim leaves the
    # menu entry pointing at nothing.
    @{ Name = 'Run-Hidden.vbs';          Owner = 'v2';      Required = $true  }
    # v2. Records system audio (WASAPI loopback) plus the microphone through the NAudio
    # assemblies in bin\naudio\. REQUIRED: naudio-core and naudio-wasapi are required
    # components in contracts\download-manifest.json, so an install that fetches and
    # verifies 415627 bytes of capture library and then ships no script that loads it
    # has paid the whole cost of the feature and delivered none of it.
    @{ Name = 'Record-Conversation.ps1'; Owner = 'v2';      Required = $true  }
    # Registers the recorder's launchers. Required: without it the recorder ships with
    # no way to start it, which installs cleanly and looks like a missing feature.
    @{ Name = 'Register-RecordVerb.ps1';  Owner = 'v2';      Required = $true  }
    # The home window the "Heresay" Start Menu shortcut opens. Required because
    # Register-RecordVerb.ps1 creates that shortcut unconditionally; shipping the .lnk
    # without its target puts a dead entry in Start on an otherwise clean install.
    @{ Name = 'Heresay-Home.ps1';         Owner = 'v2';      Required = $true  }
)

$layout = @('bin', 'bin\whisper', 'bin\sherpa', 'bin\ffmpeg', 'models', 'app', 'logs')

$banner = if ($dryRun) { 'DRY RUN - nothing will be changed' } else { "Installing $script:TI_ProductName $Version" }
if (-not $Quiet) {
    Write-Host ''
    Write-Host "  $script:TI_ProductName installer" -ForegroundColor White
    Write-Host "  $banner" -ForegroundColor $(if ($dryRun) { 'Yellow' } else { 'White' })
    Write-Host "  target: $InstallRoot"
    Write-Host ''
}

# =============================================================== 1. PREFLIGHT ==

Write-TiStep 'Preflight checks'
$problems = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList

# --- disk ---------------------------------------------------------------------
$driveLetter = ([System.IO.Path]::GetPathRoot($InstallRoot)).TrimEnd('\', ':')
$freeGB = $null
try {
    $psd = Get-PSDrive -Name $driveLetter -ErrorAction Stop
    $freeGB = [Math]::Round($psd.Free / 1GB, 1)
}
catch { [void]$warnings.Add("Could not read free space on drive $driveLetter.") }
if ($null -ne $freeGB) {
    if ($freeGB -lt $MinFreeGB) {
        [void]$problems.Add("Not enough disk space on $driveLetter`: - $freeGB GB free, at least $MinFreeGB GB needed. A clean install peaks at about 5.9 GB: 2.7 GB of downloads held in the cache, 1.7 GB installed, and a transient 1.6 GB while the f16 source model sits on disk waiting to be quantised into the default model. It settles at 1.7 GB installed plus the 2.7 GB download cache, and the cache is removed by the uninstaller. Free up space and run this again.")
    }
    else { Write-TiOk "disk: $freeGB GB free on $driveLetter`: (need $MinFreeGB GB)" }
}

# --- %LOCALAPPDATA% writable --------------------------------------------------
$programsDir = Split-Path -Parent $InstallRoot
if (Test-TiDirectoryWritable -Path $programsDir) { Write-TiOk "writable: $programsDir" }
else { [void]$problems.Add("Cannot write to '$programsDir'. TranscribeIt installs per-user and needs write access there. If this folder is locked down by policy, the app cannot be installed without help from IT.") }

# --- pwsh ---------------------------------------------------------------------
$pwsh = Find-TiPwsh
if ($pwsh) { Write-TiOk "PowerShell 7: $pwsh" }
else { [void]$problems.Add('PowerShell 7 (pwsh.exe) was not found. The Explorer right-click command and the transcription engine both run under pwsh. Run Install Heresay.cmd, which sets PowerShell 7 up automatically, or install it yourself: winget install Microsoft.PowerShell') }

# --- Edge (needed for PDF rendering) -----------------------------------------
$edge = Find-TiEdge
if ($edge) { Write-TiOk "Microsoft Edge: $edge" }
else { [void]$problems.Add('Microsoft Edge was not found. TranscribeIt renders the transcript PDF using Edge in headless mode, so it cannot produce a PDF without it.') }

# --- .NET 8 Desktop runtime (needed for the WPF progress window) -------------
$runtimes = Get-TiDotnetRuntimes
$desktop8 = @($runtimes | Where-Object { $_.Framework -eq 'Microsoft.WindowsDesktop.App' -and $_.Version -like '8.*' })
$core8    = @($runtimes | Where-Object { $_.Framework -eq 'Microsoft.NETCore.App' -and $_.Version -like '8.*' })
if ($desktop8.Count) { Write-TiOk ".NET Desktop 8 runtime: $($desktop8[0].Version)" }
else {
    [void]$problems.Add('The .NET 8 Desktop runtime (Microsoft.WindowsDesktop.App 8.x) was not found. The progress window is a WPF app and needs it. Install it with: winget install Microsoft.DotNet.DesktopRuntime.8')
}
if (-not $core8.Count) { [void]$warnings.Add('Microsoft.NETCore.App 8.x was not found alongside the Desktop runtime; this is unusual and may indicate a partial .NET install.') }

# --- registry -----------------------------------------------------------------
if (-not $SkipShellRegistration) {
    if ($RegistryRoot -match '^(HKLM|HKEY_LOCAL_MACHINE)') {
        [void]$problems.Add("RegistryRoot '$RegistryRoot' is machine-scope. This installer is user-scope only and will not attempt elevation.")
    }
    elseif ($dryRun) { Write-TiInfo "registry: would write under $RegistryRoot (not tested in dry run)" }
    elseif (Test-TiRegistryWritable -KeyPath $RegistryRoot) { Write-TiOk "writable: $RegistryRoot" }
    else { [void]$problems.Add("Cannot create keys under '$RegistryRoot'. The right-click menu entry cannot be registered.") }
}

# --- existing install ---------------------------------------------------------
$existingManifestPath = Get-TiInstallManifestPath -InstallRoot $InstallRoot
$existing = $null
if (Test-Path -LiteralPath $existingManifestPath) {
    try {
        $existing = Read-TiJsonFile -Path $existingManifestPath
        $msg = "An existing install is present: version $($existing.version), installed $($existing.installedUtc). This run will upgrade/repair it in place."
        [void]$warnings.Add($msg)
    }
    catch { [void]$warnings.Add("An install-manifest.json exists at '$existingManifestPath' but could not be read ($($_.Exception.Message)). It will be replaced.") }
}
elseif (Test-Path -LiteralPath $InstallRoot) {
    $n = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) { [void]$warnings.Add("'$InstallRoot' already exists and holds $n file(s) but has no install manifest. Files will be overwritten; anything not listed in the new manifest will be left behind.") }
}

# --- app sources --------------------------------------------------------------
$srcApp = Join-Path $SourceRoot 'app'
$missingApp = New-Object System.Collections.ArrayList
foreach ($f in $appFiles) {
    $p = Join-Path $srcApp $f.Name
    if (Test-Path -LiteralPath $p) { continue }
    [void]$missingApp.Add($f)
    if ($f.Required) { [void]$problems.Add("Required app file missing from the source tree: $p ($($f.Owner)).") }
    else { [void]$warnings.Add("Not built yet, will be skipped: app\$($f.Name) ($($f.Owner)).") }
}

# ---- source-tree guard -------------------------------------------------------
#
# MEASURED FAILURE, 2026-08-27: a run logged "10 app file(s) copied" while two files
# were not deployed at all - Progress.ps1 and Transcribe-Entry.ps1 stayed at their old
# sizes, so Track E's ~300 MB-per-window leak fix was absent from the live install for
# about ninety minutes with no error anywhere.
#
# Cause: -SourceRoot is optional and defaults to Split-Path -Parent $PSScriptRoot, so
# it is inferred from wherever the installer happens to be invoked from. Resolve it to
# the INSTALL root and every Copy-Item copies a file onto itself: nothing changes, no
# error is raised, and $copied counts them all. The report is truthful and useless.
#
# So the source tree is now proven rather than assumed, before anything is written.
$resolvedSource = try { (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).ProviderPath }
                  catch { $SourceRoot }
Write-TiInfo "source tree: $resolvedSource$(if ($PSBoundParameters.ContainsKey('SourceRoot')) { '' } else { '  (inferred from the installer location - pass -SourceRoot to be explicit)' })"

$srcAppFull = [System.IO.Path]::GetFullPath((Join-Path $resolvedSource 'app'))
$dstAppFull = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot 'app'))

# 1. The source must not BE the destination. This is the failure above.
if ($srcAppFull.TrimEnd('\') -ieq $dstAppFull.TrimEnd('\')) {
    [void]$problems.Add(
        "The source tree resolves to the install itself ($resolvedSource), so every app " +
        "file would be copied over itself and the installer would report success while " +
        "deploying nothing. Run the installer from the development tree, or pass " +
        "-SourceRoot explicitly.")
}

# 2. It must actually look like a tree we can install from, not just contain an app\
#    folder. TWO legitimate shapes exist:
#      - the development tree (has test\ alongside app\, contracts\, installer\)
#      - a DISTRIBUTION built by build\Make-Distribution.ps1, which deliberately ships
#        WITHOUT test\ and identifies itself with dist-manifest.json at its root.
#    The first shipped zip failed a real colleague's install here on 2026-08-28: the
#    guard demanded test\ and the distribution correctly does not carry it. The guard
#    had only ever been exercised against the dev tree. Both shapes carry everything
#    the install actually reads (app\, contracts\, installer\); staleness is guarded
#    separately by the post-copy hash verification, not by this shape check.
$commonMarkers = @('contracts\download-manifest.json', 'installer\Install-TranscribeIt.ps1')
$missingMarkers = @($commonMarkers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $resolvedSource $_)) })
$distManifestPath = Join-Path $resolvedSource 'dist-manifest.json'
$isDistribution = Test-Path -LiteralPath $distManifestPath
if ($missingMarkers.Count) {
    [void]$problems.Add(
        "The source tree '$resolvedSource' is not installable - " +
        "missing: $($missingMarkers -join ', '). Refusing to guess, because installing " +
        "from the wrong tree fails silently. Pass -SourceRoot explicitly.")
}
elseif ($isDistribution) {
    # Traceability: every distribution records the commit it was built from.
    try {
        $dm = Read-TiJsonFile -Path $distManifestPath
        $dmCommit = Get-TiFieldValue -Object $dm -Names @('gitCommit', 'commit') -Default '(unrecorded)'
        $dmBuilt  = Get-TiFieldValue -Object $dm -Names @('builtUtc', 'built') -Default '(unrecorded)'
        Write-TiOk "distribution package: built $dmBuilt from commit $dmCommit"
    }
    catch { [void]$warnings.Add("dist-manifest.json exists but could not be read: $($_.Exception.Message)") }
}
elseif (-not (Test-Path -LiteralPath (Join-Path $resolvedSource 'test'))) {
    [void]$problems.Add(
        "The source tree '$resolvedSource' looks like neither the development tree " +
        "(no test\) nor a built distribution (no dist-manifest.json). Refusing to " +
        "guess, because installing from the wrong tree fails silently. Pass " +
        "-SourceRoot explicitly, or rebuild the package with build\Make-Distribution.ps1.")
}

$cfgDefault = Join-Path $srcApp 'config.default.json'
if (Test-Path -LiteralPath $cfgDefault) {
    try { $null = Read-TiJsonFile -Path $cfgDefault; Write-TiOk 'app\config.default.json present and valid JSON (Track A)' }
    catch { [void]$problems.Add("app\config.default.json exists but is not valid JSON: $($_.Exception.Message)") }
}
else { [void]$warnings.Add('app\config.default.json (Track A) is not present yet; a minimal config.json holding only the installer/shell settings will be written instead.') }

# --- download manifest --------------------------------------------------------
$components = @()
if (-not $SkipDownloads) {
    if (-not $ManifestPath) {
        $candidates = @(
            (Join-Path $SourceRoot 'contracts\download-manifest.json'),
            (Join-Path $PSScriptRoot 'manifest.example.json')
        )
        $ManifestPath = @($candidates | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    }
    if (-not $ManifestPath) { [void]$problems.Add('No download manifest found. Expected contracts\download-manifest.json (Track A) or installer\manifest.example.json.') }
    else {
        try {
            $components = Resolve-TiDownloadManifest -Path $ManifestPath
            $isPlaceholder = ($ManifestPath -like '*manifest.example.json')
            $total = ($components | Measure-Object -Property SizeBytes -Sum).Sum
            Write-TiOk "download manifest: $(Split-Path -Leaf $ManifestPath) - $($components.Count) component(s), $(Format-TiBytes $total)"
            if ($isPlaceholder) {
                [void]$warnings.Add("Using the PLACEHOLDER manifest installer\manifest.example.json. Its URLs point at example.invalid and its hashes are zeros, so real downloads will fail. Track A's contracts\download-manifest.json is what makes this work for real.")
            }
            $noHash = @($components | Where-Object { -not $_.Sha256 })
            if ($noHash.Count -and -not $isPlaceholder) {
                [void]$problems.Add("These components have no SHA-256 in the manifest, so their downloads could not be verified: $(($noHash | ForEach-Object { $_.Name }) -join ', '). Refusing to install unverified binaries. Re-run with -Force to override.")
            }
    }
        catch { [void]$problems.Add("Download manifest '$ManifestPath' could not be read: $($_.Exception.Message)") }
    }
}
else { Write-TiInfo 'downloads: skipped (-SkipDownloads)' }

# --- derived components -------------------------------------------------------
# Not every component is downloaded. The DEFAULT speech model is quantised here from f16
# weights, because no upstream publishes a q4_0 large-v3-turbo. Declared before the
# $dryRun branch so the dry run can report it too.
$derived      = @()
$derivedState = @{}
if (-not $SkipDownloads -and $ManifestPath) {
    try {
        $derived = Resolve-TiDerivedModels -Path $ManifestPath
        foreach ($d in $derived) {
            if (-not $d.Target)    { [void]$problems.Add("Derived component '$($d.Name)' has no target path in the manifest.") }
            if (-not $d.Tool)      { [void]$problems.Add("Derived component '$($d.Name)' names no tool to produce it.") }
            if (-not $d.QuantType) { [void]$problems.Add("Derived component '$($d.Name)' names no quantisation type.") }
            if (-not $d.Sha256)    { [void]$warnings.Add("Derived component '$($d.Name)' pins no SHA-256, so what the installer produces cannot be compared against a reference.") }
            if ($d.SourceComponent -and -not @($components | Where-Object { $_.Name -eq $d.SourceComponent }).Count) {
                [void]$problems.Add("Derived component '$($d.Name)' is derived from '$($d.SourceComponent)', but no component of that name exists in the manifest, so its source would never be downloaded.")
            }
    }
        if ($derived.Count) {
            Write-TiOk "derived at install time: $(($derived | ForEach-Object { $_.Name }) -join ', ')"
    }
    }
    catch { [void]$problems.Add("The derivedComponents section of '$ManifestPath' could not be read: $($_.Exception.Message)") }
}

# --- does anything actually provide the model the config asks for? -------------
# This is the check whose absence was the whole defect: config.default.json named a
# default speech model that no component in the manifest installed, so a clean install
# completed successfully and then could not transcribe anything.
if (-not $SkipDownloads -and (Test-Path -LiteralPath $cfgDefault)) {
    $wantModel = ''
    try {
        $cfgPeek = Read-TiJsonFile -Path $cfgDefault
        if ($cfgPeek.PSObject.Properties.Name -contains 'transcription' -and
            $cfgPeek.transcription.PSObject.Properties.Name -contains 'model') {
            $wantModel = [string]$cfgPeek.transcription.model
    }
    }
    catch { [void]$warnings.Add("Could not read the default speech model out of app\config.default.json: $($_.Exception.Message)") }

    if ($wantModel) {
        $provided = New-Object System.Collections.Generic.List[string]
        foreach ($c in $components) {
            # An install-time-only source is deleted before the install finishes, so it
            # does not count as providing anything.
            if ($c.InstallTimeOnly) { continue }
            foreach ($e in @($c.Extract)) {
                $to = Get-TiFieldValue -Object $e -Names @('to', 'dest', 'destination')
                if ($to) { $provided.Add((Split-Path -Leaf ([string]$to))) }
            }
    }
        foreach ($d in $derived) { if ($d.Target) { $provided.Add((Split-Path -Leaf $d.Target)) } }

        if ($provided -notcontains $wantModel) {
            [void]$problems.Add("app\config.default.json sets transcription.model = '$wantModel', but nothing in the download manifest installs or derives a file of that name. The install would report success and then fail on the first transcription. The manifest provides: $(($provided | Sort-Object -Unique) -join ', ').")
    }
        else { Write-TiOk "default speech model '$wantModel' is provided by the manifest" }
    }
}

# --- verdict ------------------------------------------------------------------
foreach ($w in $warnings) { Write-TiWarn $w }
if ($problems.Count) {
    foreach ($p in $problems) { Write-TiFail $p }
    if ($Force) { Write-TiWarn "-Force given: continuing despite $($problems.Count) failed preflight check(s)." }
    else {
        Write-Host ''
        Write-Host "Install aborted: $($problems.Count) preflight check(s) failed. Nothing was changed." -ForegroundColor Red
        Write-Host 'Fix the items marked FAIL above and run the installer again.'
        exit 1
    }
}
else { Write-TiOk 'all preflight checks passed' }

if ($dryRun) {
    Write-Host ''
    Write-TiStep 'Dry run - planned actions'
    Write-TiInfo "create directories under $InstallRoot`:"
    foreach ($d in $layout) { Write-TiInfo "    $d\" }
    if (-not $SkipDownloads -and $components.Count) {
        # Which install-time-only sources would be skipped because what they produce is
        # already present? Report the same decision the real run will make.
        $planSkip = @{}
        foreach ($d in $derived) {
            $st = Get-TiDerivedModelState -Spec $d -InstallRoot $InstallRoot -PreviousManifest $existing
            $derivedState[$d.Name] = $st
            if ($st.Ok -and $d.SourceComponent) { $planSkip[$d.SourceComponent] = $true }
    }
        Write-TiInfo 'download and verify:'
        foreach ($c in $components) {
            # $c.Target is empty for the components that map individual archive members;
            # show where those members actually land instead of an empty arrow.
            $dest = $c.Target
            if (-not $dest -and @($c.Extract).Count) {
                $tos = @(foreach ($e in @($c.Extract)) { Get-TiFieldValue -Object $e -Names @('to', 'toDir', 'destDir', 'dest') })
                $tos = @($tos | Where-Object { $_ })
                $dest = if (@($tos).Count -eq 1) { [string]$tos[0] } else { "$(@($tos).Count) mapped path(s)" }
            }
            $note = ''
            if ($c.InstallTimeOnly) { $note = '  [install-time source, deleted afterwards]' }
            if ($planSkip.ContainsKey($c.Name)) { $note = '  [SKIPPED - what it produces is already present and verified]' }
            Write-TiInfo ("    {0,-42} {1,10}  -> {2}{3}" -f $c.Name, (Format-TiBytes $c.SizeBytes), $dest, $note)
    }
    }
    if (-not $SkipDownloads -and $derived.Count) {
        Write-TiInfo 'derive at install time (nothing upstream publishes these):'
        foreach ($d in $derived) {
            $st    = if ($derivedState.ContainsKey($d.Name)) { $derivedState[$d.Name] } else { Get-TiDerivedModelState -Spec $d -InstallRoot $InstallRoot -PreviousManifest $existing }
            $srcC  = @($components | Where-Object { $_.Name -eq $d.SourceComponent }) | Select-Object -First 1
            $srcSz = if ($srcC) { Format-TiBytes $srcC.SizeBytes } else { 'unknown size' }
            Write-TiInfo ("    {0,-42} {1,10}  -> {2}" -f $d.Name, (Format-TiBytes $d.SizeBytes), $d.Target)
            if ($st.Ok) {
                Write-TiInfo "        SKIP: already present and correct - $($st.Reason)"
                Write-TiInfo "        so '$($d.SourceComponent)' ($srcSz) would not be downloaded either"
            }
            else {
                Write-TiInfo "        would derive because $($st.Reason)"
                Write-TiInfo "        run: $($d.Tool) `"$($d.SourcePath)`" `"$($d.Target)`" $($d.QuantType)"
                Write-TiInfo "        then check the size, compare against the pinned SHA-256, and record the measured hash"
                if ($d.DeleteSourceAfter) {
                    Write-TiInfo "        then DELETE the $srcSz install-time source '$($d.SourcePath)' - installed footprint does not grow"
                }
            }
    }
    }
    Write-TiInfo 'copy app files:'
    foreach ($f in $appFiles) {
        $state = if (Test-Path -LiteralPath (Join-Path $srcApp $f.Name)) { 'present' } else { 'MISSING - will skip' }
        Write-TiInfo ("    {0,-26} {1,-8} {2}" -f $f.Name, $f.Owner, $state)
    }
    Write-TiInfo "write $InstallRoot\app\config.json"
    if (-not $SkipShellRegistration) {
        # -IconPath so the plan shows the icon the real run will use. Without it the plan
        # falls back to the pwsh.exe icon, because app\TranscribeIt.ico does not exist in
        # an install root that has not been created yet.
        $planIcon = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'assets\TranscribeIt.ico')) { "$InstallRoot\app\TranscribeIt.ico,0" } else { $null }
        $plan = & (Join-Path $srcApp 'Register-ShellVerbs.ps1') -InstallRoot $InstallRoot -RegistryRoot $RegistryRoot -IconPath $planIcon -WhatIf -WarningAction SilentlyContinue
        Write-TiInfo 'register shell verb:'
        foreach ($v in $plan.RegistryValues) {
            $n = if ($v.Name) { $v.Name } else { '(default)' }
            Write-TiInfo ("    {0}  [{1}] = {2}" -f ($v.Key -replace '^HKCU:', 'HKCU'), $n, $v.Value)
    }
        # The recorder's launchers, asked of the script that creates them for the same
        # reason the Send To list is below: a preview that restates its own copy of what
        # will happen drifts, and a dry run that under-reports is worse than none because
        # it gets believed. -WhatIf propagates, so nothing is created here.
        $recPlanScript = Join-Path $srcApp 'Register-RecordVerb.ps1'
        if (Test-Path -LiteralPath $recPlanScript) {
            $recPlan = & $recPlanScript -InstallRoot $InstallRoot -RegistryRoot $RegistryRoot -IconPath $planIcon -WhatIf -WarningAction SilentlyContinue
            Write-TiInfo 'register the "Transcribe new conversation" verb and the "Heresay" Start Menu shortcut:'
            Write-TiInfo ("    background verb on the desktop and folder backgrounds, label '{0}'" -f $recPlan.MenuText)
            Write-TiInfo ("    command: {0}" -f $recPlan.Command)
            Write-TiInfo '    Start Menu shortcut: Heresay.lnk (opens the Heresay home window)'
            Write-TiInfo '    sweep the retired shortcut: Heresay - Transcribe new conversation.lnk'
        }
    }
    Write-TiInfo "write $InstallRoot\install-manifest.json"
    Write-TiInfo "copy  $InstallRoot\Uninstall-TranscribeIt.ps1"
    Write-Host ''
    if ($SkipSendTo) {
        Write-TiInfo '    leave the Send To entries alone (-SkipSendTo)'
    }
    else {
        Write-TiInfo '    create Send To entries under %APPDATA%\Microsoft\Windows\SendTo:'
        # Asked of the function that actually creates them, rather than restated here.
        # This list WAS restated here and had drifted to four names while six were being
        # installed, so the dry run quietly under-reported its own effects.
        foreach ($n in @(New-TiSendToShortcuts -InstallRoot $InstallRoot -ListOnly)) { Write-TiInfo "        $n" }
    }
    Write-Host ''
    Write-Host 'Dry run complete. Nothing was changed. Re-run without -WhatIf to install.' -ForegroundColor Yellow
    exit 0
}

# ================================================================ 2. DIRECTORIES ==

Write-TiStep 'Creating the install layout'
$manifest = New-TiInstallManifest -InstallRoot $InstallRoot -Version $Version
$createdDirs = New-Object System.Collections.ArrayList
foreach ($rel in @('') + $layout) {
    $d = if ($rel) { Join-Path $InstallRoot $rel } else { $InstallRoot }
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [void]$createdDirs.Add($d)
    }
}
$manifest.directories = $createdDirs.ToArray()
Write-TiOk "$($createdDirs.Count) directory/ies created ($($layout.Count) in the layout)"

# The install root exists now, so the log can live where the operator expects it.
Move-TiLog -To $logPath

# ================================================================== 3. DOWNLOADS ==

$componentRecords = New-Object System.Collections.ArrayList
if (-not $SkipDownloads -and $components.Count) {
    Write-TiStep "Downloading components to $DownloadCache"
    if (-not (Test-Path -LiteralPath $DownloadCache)) { New-Item -ItemType Directory -Path $DownloadCache -Force | Out-Null }

    # Decide up front which install-time-only sources are unnecessary. Without this, a
    # re-run would fetch 1.55 GiB of f16 weights, copy them into models\, quantise a model
    # that is already correct, and delete them again. Idempotency has to reach back into
    # the download stage, not just the derivation.
    $skipSources = @{}
    foreach ($d in $derived) {
        $st = Get-TiDerivedModelState -Spec $d -InstallRoot $InstallRoot -PreviousManifest $existing
        $derivedState[$d.Name] = $st
        if ($st.Ok -and $d.SourceComponent) {
            $skipSources[$d.SourceComponent] = "$($d.Name) is already present and verified ($($st.Reason))"
    }
    }

    $i = 0
    foreach ($c in $components) {
        $i++
        Write-TiInfo "[$i/$($components.Count)] $($c.Name) - $(Format-TiBytes $c.SizeBytes)"
        if ($skipSources.ContainsKey($c.Name)) {
            Write-TiOk "not needed: $($skipSources[$c.Name]); skipping this download entirely"
            continue
    }
        $outFile = Join-Path $DownloadCache $c.FileName
        try {
            $dl = Invoke-TiDownload -Uri $c.Uri -OutFile $outFile -Sha256 $c.Sha256 -ExpectedBytes $c.SizeBytes
    }
        catch {
            if ($c.Optional) { Write-TiWarn "optional component '$($c.Name)' failed: $($_.Exception.Message)"; continue }
            Write-TiFail $_.Exception.Message
            Write-Host ''
            Write-Host "Install aborted while fetching '$($c.Name)'." -ForegroundColor Red
            Write-Host "Already-downloaded files are cached in $DownloadCache, so re-running resumes rather than starting over."
            exit 2
    }

        if (@($c.Extract).Count -gt 0) {
            # Track A's manifest maps individual members to exact destinations, which is
            # more precise than "unpack this archive into that folder" - the whisper
            # archive, for instance, puts Release/*.dll into bin\whisper\.
            Write-TiInfo "        installing $(@($c.Extract).Count) mapped path(s)"
            $paths = Install-TiComponentFiles -SourcePath $dl.Path -InstallRoot $InstallRoot `
                                              -Extract $c.Extract -ArchiveType $c.ArchiveType
            $added  = @($paths | ForEach-Object { Get-Item -LiteralPath $_ })
            $target = $InstallRoot
    }
        else {
            $target = if ($c.Target) { Join-Path $InstallRoot ($c.Target -replace '/', '\') } else { $InstallRoot }
            Write-TiInfo "        extracting to $target"
            $before = @{}
            if (Test-Path -LiteralPath $target) {
                Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.FullName] = $true }
            }
            Expand-TiArchive -ArchivePath $dl.Path -Destination $target -ArchiveType $c.ArchiveType -StripComponents $c.StripComponents

            $added = @(Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not $before.ContainsKey($_.FullName) })
    }
        foreach ($f in $added) { Add-TiManifestFile -Manifest $manifest -Path $f.FullName -Component $c.Name -NoHash }
        Write-TiOk "$($c.Name): $($added.Count) file(s) installed"

        [void]$componentRecords.Add([pscustomobject]@{
            name = $c.Name; fileName = $c.FileName; sha256 = $c.Sha256
            sizeBytes = $dl.Bytes; target = $target; fileCount = $added.Count
            smokeExe = $c.SmokeExe; smokeArgs = @($c.SmokeArgs)
            installTimeOnly = [bool]$c.InstallTimeOnly
        })
    }
}
else { Write-TiStep 'Downloads skipped'; Write-TiWarn 'bin\ and models\ will be empty; transcription will not run until they are populated.' }
$manifest.components = $componentRecords.ToArray()

# ========================================================= 3b. DERIVED MODELS ==
#
# The DEFAULT speech model is not downloaded, because nobody publishes it: there is no
# q4_0 large-v3-turbo anywhere in the upstream repo. It is quantised here from the f16
# weights just downloaded and SHA-256 verified, with whisper-quantize.exe out of the same
# verified whisper.cpp archive that whisper-cli.exe came from.
#
# Then the 1.55 GiB f16 source is deleted from the install tree. It is an install-time
# input, not a shipped artefact - which is the whole reason this approach is affordable:
# one extra download, no lasting footprint.
#
# Placed here, before app files and before anything user-visible is registered, so that a
# failed derivation aborts without leaving dead Send To entries and without disturbing an
# existing working install.

$derivedRecords = New-Object System.Collections.ArrayList
if (-not $SkipDownloads -and $derived.Count) {
    Write-TiStep 'Deriving the default speech model'
    foreach ($d in $derived) {
        $outPath  = Join-Path $InstallRoot ($d.Target -replace '/', '\')
        $srcPath  = if ($d.SourcePath) { Join-Path $InstallRoot ($d.SourcePath -replace '/', '\') } else { '' }
        $toolPath = if ($d.Tool)       { Join-Path $InstallRoot ($d.Tool       -replace '/', '\') } else { '' }

        $st = if ($derivedState.ContainsKey($d.Name)) { $derivedState[$d.Name] }
              else { Get-TiDerivedModelState -Spec $d -InstallRoot $InstallRoot -PreviousManifest $existing }

        # Initialise before use: Set-StrictMode -Version Latest makes reading an unassigned
        # variable a terminating error, and this codebase has been bitten by that five times.
        $hash       = ''
        $secs       = 0.0
        $wasDerived = $false
        $failed     = $false
        $failMsg    = ''
        $outBytes   = 0L

        if ($st.Ok) {
            Write-TiOk "$($d.Name): already correct, not re-derived - $($st.Reason)"
            $hash     = $st.Sha256
            $outBytes = $st.SizeBytes
    }
        else {
            if ($st.Present) { Write-TiWarn "$($d.Name) is present but $($st.Reason); re-deriving it." }
            Write-TiInfo "$($d.Name): quantising to $($d.QuantType)"
            Write-TiInfo "        $(Split-Path -Leaf $toolPath) `"$($d.SourcePath)`" `"$($d.Target)`" $($d.QuantType)"

            $q = Invoke-TiQuantizeModel -ExePath $toolPath -SourcePath $srcPath -OutPath $outPath -QuantType $d.QuantType
            $secs = $q.Seconds
            if (-not $q.Ok) {
                $failed  = $true
                $failMsg = $q.Error
                $tail = @($q.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | '
                if ($tail) { $failMsg = "$failMsg. Last output: $tail" }
            }
            else {
                $outBytes = (Get-Item -LiteralPath $outPath).Length
                # Size is the hard gate. A quantised model's size is fixed by the tensor
                # shapes and the quant type, so it cannot legitimately differ.
                if ($d.SizeBytes -gt 0 -and $outBytes -ne $d.SizeBytes) {
                    Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
                    $failed  = $true
                    $failMsg = "the derived file is $outBytes bytes but the manifest pins $($d.SizeBytes). That size is fixed by the model's tensor shapes, so this is not a rounding difference - the derivation did not produce the model the manifest describes. The bad output has been deleted."
                }
                else {
                    $hash       = Get-TiFileHash256 -Path $outPath
                    $wasDerived = $true
                    Write-TiOk "$($d.Name) derived in $secs s: $(Format-TiBytes $outBytes)"
                }
            }
    }

        # --- hash: compared and reported, deliberately not a gate -------------
        $matchesPinned = [bool]($d.Sha256 -and $hash -and $hash -eq $d.Sha256.ToLowerInvariant())
        if (-not $failed) {
            if ($matchesPinned) {
                Write-TiOk "$($d.Name): SHA-256 matches the pinned hash - $hash"
            }
            elseif (-not $d.Sha256) {
                Write-TiWarn "$($d.Name): the manifest pins no SHA-256, so the result could not be compared against a reference. Measured $hash."
            }
            else {
                Write-TiWarn "$($d.Name): SHA-256 does NOT match the hash pinned in the manifest."
                Write-TiWarn "    pinned   : $($d.Sha256.ToLowerInvariant())"
                Write-TiWarn "    measured : $hash"
                Write-TiWarn "    size     : $outBytes bytes, which DOES match the pinned size."
                Write-TiWarn '    Not treated as a failure, on purpose. whisper-quantize loads whichever ggml-cpu-*.dll'
                Write-TiWarn '    matches this CPU, so byte-identical output on a different microarchitecture is likely'
                Write-TiWarn '    but not guaranteed, and aborting here would make a clean install impossible on exactly'
                Write-TiWarn '    the machines this step exists to support. The artefact is still accounted for: both of'
                Write-TiWarn '    its inputs were SHA-256 verified against the manifest, and the size gate passed. The'
                Write-TiWarn '    measured hash is recorded in install-manifest.json.'
            }
    }

        # --- delete the install-time source, whichever way this went ----------
        # On success it has served its purpose. On failure, leaving 1.55 GiB behind would
        # mean a failed install that also cost the disk.
        if ($srcPath -and $d.DeleteSourceAfter -and (Test-Path -LiteralPath $srcPath)) {
            $srcBytes = (Get-Item -LiteralPath $srcPath).Length
            Remove-Item -LiteralPath $srcPath -Force
            # It was recorded when the component was extracted. It is not there any more,
            # so it must not stay in the manifest - an uninstaller that reports a file it
            # cannot find is an uninstaller nobody trusts.
            $lowerSrc = $srcPath.ToLowerInvariant()
            $manifest.files = @(@($manifest.files) | Where-Object { $_.path -and $_.path.ToLowerInvariant() -ne $lowerSrc })
            Write-TiOk "install-time source deleted: $(Split-Path -Leaf $srcPath) - $(Format-TiBytes $srcBytes) reclaimed, installed footprint unchanged"
            Write-TiInfo "        it stays in the download cache ($DownloadCache) so a future re-derive needs no re-download"
    }

        if ($failed) {
            Write-TiFail "could not derive $($d.Name): $failMsg"
            if (-not $d.Optional -and -not $Force) {
                Write-Host ''
                Write-Host "Install aborted: the default speech model could not be derived." -ForegroundColor Red
                Write-Host "  tool   : $toolPath"
                Write-Host "  source : $srcPath"
                Write-Host "  target : $outPath"
                Write-Host '  Nothing user-visible has been registered yet, so an existing install is untouched.'
                Write-Host "  Downloads are cached in $DownloadCache, so a re-run resumes rather than starting over."
                exit 4
            }
            Write-TiWarn "-Force given: continuing without $($d.Name). Transcription will fail until it exists."
            continue
    }

        Add-TiManifestFile -Manifest $manifest -Path $outPath -Component $d.Name -ForceHash
        [void]$derivedRecords.Add([pscustomobject]@{
            name            = $d.Name
            path            = $outPath
            sizeBytes       = $outBytes
            sha256          = $hash
            pinnedSha256    = $d.Sha256
            matchesPinned   = $matchesPinned
            derivedThisRun  = $wasDerived
            seconds         = $secs
            quantType       = $d.QuantType
            tool            = $toolPath
            sourceComponent = $d.SourceComponent
            sourceDeleted   = [bool]$d.DeleteSourceAfter
        })
    }
}
elseif ($derived.Count) { Write-TiStep 'Model derivation skipped (-SkipDownloads)' }
$manifest.derivedModels = $derivedRecords.ToArray()

# =================================================================== 4. APP FILES ==

Write-TiStep 'Installing app files'
$dstApp = Join-Path $InstallRoot 'app'
$copied = 0
foreach ($f in $appFiles) {
    $src = Join-Path $srcApp $f.Name
    if (-not (Test-Path -LiteralPath $src)) { Write-TiWarn "skipped app\$($f.Name) - not built yet ($($f.Owner))"; continue }
    $dst = Join-Path $dstApp $f.Name
    Copy-Item -LiteralPath $src -Destination $dst -Force

    # Verify the copy landed, rather than trusting that Copy-Item not throwing means the
    # destination changed. These are small scripts, so hashing both sides is cheap - and a
    # deployment that reports success while leaving stale code in place is the failure that
    # hid Track E's memory-leak fix from the live install for ninety minutes.
    $srcHash = Get-TiFileHash256 -Path $src
    $dstHash = Get-TiFileHash256 -Path $dst
    if ($srcHash -ne $dstHash) {
        Write-TiFail ("app\{0} did not deploy: destination content differs from the source after copying. source {1}, destination {2}." -f $f.Name, $srcHash.Substring(0, 12), $dstHash.Substring(0, 12))
        exit 4
    }

    Add-TiManifestFile -Manifest $manifest -Path $dst -Component 'app'
    $copied++
}
Write-TiOk "$copied app file(s) copied"

# Any other files the tracks dropped in app\ that we do not know about by name.
foreach ($extra in @(Get-ChildItem -LiteralPath $srcApp -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notin @($appFiles.Name) -and $_.Name -ne 'config.default.json' })) {
    Copy-Item -LiteralPath $extra.FullName -Destination (Join-Path $dstApp $extra.Name) -Force
    Add-TiManifestFile -Manifest $manifest -Path (Join-Path $dstApp $extra.Name) -Component 'app'
    Write-TiInfo "also copied app\$($extra.Name)"
}

# --- icon ---------------------------------------------------------------------
$srcIcon = Join-Path $PSScriptRoot 'assets\TranscribeIt.ico'
if (Test-Path -LiteralPath $srcIcon) {
    $dstIcon = Join-Path $dstApp 'TranscribeIt.ico'
    Copy-Item -LiteralPath $srcIcon -Destination $dstIcon -Force
    Add-TiManifestFile -Manifest $manifest -Path $dstIcon -Component 'app'
    Write-TiOk 'menu icon installed'
}
else { Write-TiWarn 'installer\assets\TranscribeIt.ico missing; the menu entry will fall back to the pwsh.exe icon.' }

# --- config.json --------------------------------------------------------------
# Track A owns app\config.default.json - it is READ, never rewritten. The runtime
# app\config.json is the installer's to produce, so the shell/queue sections that
# Register-ShellVerbs.ps1 and Transcribe-Entry.ps1 read are merged in here if Track A's
# defaults do not carry them. Merging only ADDS absent sections; anything Track A has
# already specified wins.
$dstCfg = Join-Path $dstApp 'config.json'

$shellDefaults = [ordered]@{
    extraExtensions = @('.amr', '.flv', '.caf')
    '$comment'      = 'Formats with no PerceivedType on this machine. Add extensions here and re-run app\Register-ShellVerbs.ps1 to give them the right-click entry too.'
}
$queueDefaults = [ordered]@{
    coalesceMs = 700; coalesceSliceMs = 350; maxCoalesceMs = 8000
    graceMs = 1200; hungWorkerSeconds = 1800
    rewriteItemFields = $true; rescaleOverallPercent = $true
    emitQueuedEvent = $true; keepEventLogs = 20
    '$comment' = 'Multi-select queue behaviour. Explorer invokes the verb once per selected file; these govern how those invocations are coalesced into one serialised batch.'
}

if (Test-Path -LiteralPath $cfgDefault) {
    $cfgObj = Read-TiJsonFile -Path $cfgDefault
    $added = @()
    foreach ($pair in @(@{ N = 'shell'; V = $shellDefaults }, @{ N = 'queue'; V = $queueDefaults })) {
        if ($cfgObj.PSObject.Properties.Name -notcontains $pair.N) {
            $cfgObj | Add-Member -NotePropertyName $pair.N -NotePropertyValue ([pscustomobject]$pair.V) -Force
            $added += $pair.N
    }
    }
    # Track A's defaults point at their vendor\ development layout; the install layout is
    # bin\ + models\. Reconcile, or the engine cannot find its own tools at run time.
    $pathReport = Repair-TiConfigPaths -Config $cfgObj -InstallRoot $InstallRoot
    foreach ($m in $pathReport.Remapped) { Write-TiInfo "config paths.$($m.name): '$($m.from)' -> '$($m.to)'" }
    if (@($pathReport.Remapped).Count) { Write-TiOk "$(@($pathReport.Remapped).Count) tool path(s) remapped to the install layout" }
    foreach ($u in $pathReport.Unresolved) {
        Write-TiWarn "config paths.$($u.name) = '$($u.value)' does not exist under $InstallRoot and no replacement was found. The engine will fail on this tool until it is installed."
    }

    Write-TiJsonFile -Object $cfgObj -Path $dstCfg
    if ($added.Count) { Write-TiOk "app\config.json written from Track A defaults, with installer-owned section(s) merged in: $($added -join ', ')" }
    else { Write-TiOk 'app\config.json written from Track A defaults (shell/queue sections already present)' }
    if (@($pathReport.Remapped).Count) {
        $manifest.notes = @($manifest.notes) + @(
            "config.json tool paths remapped from Track A's vendor\ development layout to the install layout: " +
            (($pathReport.Remapped | ForEach-Object { "$($_.name)=$($_.to)" }) -join '; '))
    }
}
else {
    $fallback = [ordered]@{
        '$comment' = 'Minimal config written by the installer because app/config.default.json (Track A) was not available. Only the installer-owned sections are present; engine settings will use their built-in defaults.'
        shell      = [pscustomobject]$shellDefaults
        queue      = [pscustomobject]$queueDefaults
    }
    Write-TiJsonFile -Object ([pscustomobject]$fallback) -Path $dstCfg
    Write-TiWarn 'app\config.json written with installer defaults only (Track A config.default.json absent)'
}
# -Mutable, not a plain record: this file is generated just above and then tuned by the
# user afterwards (queue.rewriteItemFields and performance.realTimeFactor are documented
# knobs). Recording a hash for it guarantees a false positive the first time a seed is
# adjusted - it drifted within two hours of the first install for exactly that reason.
# The flag says "expected to change" so a future integrity check can skip it knowingly
# rather than the manifest merely happening not to carry a hash.
Add-TiManifestFile -Manifest $manifest -Path $dstCfg -Component 'app' -Mutable

# --- uninstaller --------------------------------------------------------------
foreach ($n in @('Uninstall-TranscribeIt.ps1', 'Install-Common.ps1')) {
    $src = Join-Path $PSScriptRoot $n
    if (-not (Test-Path -LiteralPath $src)) { Write-TiWarn "installer\$n not found; uninstall will need the source tree."; continue }
    $dst = Join-Path $InstallRoot $n
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Add-TiManifestFile -Manifest $manifest -Path $dst -Component 'installer'
}
Write-TiOk 'uninstaller staged in the install root'

# ============================================================= 5. SHELL VERB ==

# HISTORY - all of it happened on 2026-08-27, and every flip was evidence-driven.
# Future readers: do NOT "simplify" this stage back to pwsh-direct-with-defaults;
# that exact configuration is the one that burned the user.
#
#   1. REGISTERED originally as 'Generate transcript (PDF)': pwsh.exe launched
#      directly, engine DEFAULTS (large-v3-turbo + speaker separation). Believed
#      harmless because the verb was thought suppressed on this fleet (Cortex XDR +
#      BeyondTrust hook Explorer; five labelled probe verbs never showed).
#   2. Half right: Windows 11's MODERN menu does suppress it, but the verb renders
#      fine in the CLASSIC menu ("Show more options" / Shift+F10) - which is what
#      the user actually uses. It burned him: his 60-minute screen recording took
#      34 minutes (the Send To fast path does it in ~3.5), diarized system audio
#      into 31 "speakers", and flashed a console for the ~2-3 s pwsh startup tax.
#      RETIRED that morning (commit b28fc9f): this stage swept the keys and the
#      smoke test failed on the verb's PRESENCE.
#   3. REINSTATED the same evening at the user's explicit request - he wants the
#      top-level entry and uses the classic menu - with all three defects fixed:
#      label 'Transcribe in PDF', the FAST profile (-Model ggml-tiny.en-q8_0.bin
#      -NoDiarization), and silent launch via wscript.exe -> Run-Hidden.vbs ->
#      hidden pwsh.
#
# On the shim: the retirement called a registry verb chaining wscript -> VBS -> pwsh
# a textbook malware-persistence signature this fleet's endpoint agent would flag.
# That was asserted, never tested; the Send To entries have run the IDENTICAL
# process chain on this machine all day with zero endpoint-security reaction. If the
# agent ever suppresses or blocks the verb anyway, the fallback is to re-point the
# command in Register-ShellVerbs.ps1 at pwsh.exe directly (accepting the console
# flash), or to lean on Send To, which remains installed with the same fast profile.
if ($SkipShellRegistration) { Write-TiStep 'Shell registration skipped (-SkipShellRegistration)' }
else {
    Write-TiStep 'Registering the Explorer right-click verb'
    $regScript = Join-Path $dstApp 'Register-ShellVerbs.ps1'
    if (-not (Test-Path -LiteralPath $regScript)) { $regScript = Join-Path $srcApp 'Register-ShellVerbs.ps1' }
    $reg = & $regScript -InstallRoot $InstallRoot -RegistryRoot $RegistryRoot -ConfigPath $dstCfg
    if (-not $reg.Ok) { throw 'Shell verb registration reported a failure; see the messages above.' }

    $manifest.registryKeys   = @($reg.RegistryKeys)
    $manifest.verbKeys       = @($reg.VerbKeys)
    $manifest.registryValues = @($reg.RegistryValues | ForEach-Object {
        [pscustomobject]@{ key = $_.Key; name = $_.Name; value = $_.Value; type = $_.Type }
    })
    $manifest.notes = @($manifest.notes) + @(
        "Shell verb '$($reg.VerbName)' ('$($reg.MenuText)') registered for perceived types [$($reg.PerceivedTypes -join ', ')] and extensions [$($reg.Extensions -join ', ')].",
        "MultiSelectModel=$($reg.MultiSelectModel): Explorer invokes the verb once per selected file; Transcribe-Entry.ps1 serialises them through a lockfile queue."
    )
    Write-TiOk "verb registered on $($reg.PerceivedTypes.Count) perceived type(s) + $($reg.Extensions.Count) extension(s)"
    Write-TiInfo "command: $($reg.Command)"

    # The conversation recorder's background verb on the desktop and inside folders,
    # plus the single "Heresay" Start Menu shortcut, which opens the home window rather
    # than the recorder (a Start-menu search for the app's name should offer the app,
    # not one verb of it). A SEPARATE script because that one owns per-file verbs and
    # every invariant in it is about file types - see the header of
    # Register-RecordVerb.ps1.
    #
    # Its results are APPENDED to the same manifest collections rather than replacing
    # them, so the uninstaller removes both sets from the one list it already replays.
    # Getting this wrong would strand registry keys or the Start Menu shortcut - which
    # lives outside the install root - and this project has already shipped dead menu
    # entries twice by creating something on a path that did not also record it.
    $recScript = Join-Path $dstApp 'Register-RecordVerb.ps1'
    if (-not (Test-Path -LiteralPath $recScript)) { $recScript = Join-Path $srcApp 'Register-RecordVerb.ps1' }
    if (Test-Path -LiteralPath $recScript) {
        Write-TiStep 'Registering the "Transcribe new conversation" verb and the "Heresay" Start Menu shortcut'
        $rec = & $recScript -InstallRoot $InstallRoot -RegistryRoot $RegistryRoot
        if (-not $rec.Ok) { Write-TiWarn 'the recorder launchers reported a problem; see the messages above. The rest of the install is unaffected.' }
        # The retired recorder shortcut is swept by the script on every create run, so an
        # upgrade ends with one Start entry. Say so when it happened, because the person
        # upgrading is the one who will otherwise wonder where the old entry went.
        foreach ($gone in @($rec.Removed)) { Write-TiInfo "removed retired Start Menu shortcut: $gone" }

        $manifest.registryKeys = @($manifest.registryKeys) + @($rec.RegistryKeys)
        $manifest.verbKeys     = @($manifest.verbKeys)     + @($rec.VerbKeys)
        $manifest.registryValues = @($manifest.registryValues) + @($rec.RegistryValues | ForEach-Object {
            [pscustomobject]@{ key = $_.Key; name = $_.Name; value = $_.Value; type = $_.Type }
        })
        foreach ($lnk in @($rec.ShortcutPaths)) {
            Add-TiManifestFile -Manifest $manifest -Path $lnk -Component 'shortcut' -NoHash
        }
        $manifest.notes = @($manifest.notes) + @(
            "Recorder launchers: background verb '$($rec.Verb)' ('$($rec.MenuText)') on the desktop and folder backgrounds, plus $(@($rec.ShortcutPaths).Count) Start Menu shortcut(s) named 'Heresay' opening the home window. The Start Menu shortcut is recorded in files[] because it lives outside the install root."
        )
        Write-TiOk "recorder verb and Start Menu shortcut registered ($(@($rec.VerbKeys).Count) background verb key(s), $(@($rec.ShortcutPaths).Count) Start Menu shortcut(s))"
    }
    else { Write-TiWarn 'app\Register-RecordVerb.ps1 not found; the "Transcribe new conversation" verb and the "Heresay" Start Menu shortcut were not created.' }
}

# =============================================================== 6. MANIFEST ==

# ================================================================ 6b. SEND TO ==
# The Send To entries render in BOTH the modern Win11 menu (which suppresses the
# stage-5 verb) and the classic one, so they stay installed alongside the verb. They
# live outside the install root, so they MUST be recorded in the manifest or uninstall
# leaves dead menu entries and the IT package's "provably complete removal" claim is
# false.
if ($SkipSendTo) {
    Write-TiStep 'Send To entries skipped (-SkipSendTo)'
    Write-TiInfo 'the four existing entries, wherever they point, are left exactly as they are'
}
elseif ($PSCmdlet.ShouldProcess($InstallRoot, 'Create Send To entries')) {
    Write-TiStep 'Creating the Send To entries'
    try {
        $lnks = @(New-TiSendToShortcuts -InstallRoot $InstallRoot)
        foreach ($lnk in $lnks) { Add-TiManifestFile -Manifest $manifest -Path $lnk -Component 'sendto' }
        Write-TiOk ("{0} Send To entr{1} created" -f $lnks.Count, $(if ($lnks.Count -eq 1) { 'y' } else { 'ies' }))
        foreach ($lnk in $lnks) { Write-TiInfo ('        ' + [System.IO.Path]::GetFileNameWithoutExtension($lnk)) }
    }
    catch {
        Write-TiWarn "could not create the Send To entries: $($_.Exception.Message). The tool is installed; add them by re-running the installer."
    }
}
else {
    Write-TiStep 'Creating the Send To entries'
    Write-TiInfo '    would create 4 Send To entries under %APPDATA%\Microsoft\Windows\SendTo'
}

Write-TiStep 'Writing install-manifest.json'
$manifestPath = Get-TiInstallManifestPath -InstallRoot $InstallRoot
Write-TiJsonFile -Object ([pscustomobject]$manifest) -Path $manifestPath
$fileCount = @($manifest.files).Count
Write-TiOk "$fileCount file(s), $(@($manifest.registryKeys).Count) registry key(s), $(@($manifest.registryValues).Count) registry value(s) recorded"

# ============================================================ 7. SMOKE TESTS ==

$smoke = New-Object System.Collections.ArrayList
if ($SkipSmokeTest) { Write-TiStep 'Post-install smoke test skipped (-SkipSmokeTest)' }
else {
    Write-TiStep 'Post-install smoke test'

    # --- binaries -------------------------------------------------------------
    $exeChecks = New-Object System.Collections.ArrayList
    foreach ($c in $componentRecords) {
        if ($c.smokeExe) {
            [void]$exeChecks.Add([pscustomobject]@{ Name = $c.name; Exe = (Join-Path $InstallRoot ($c.smokeExe -replace '/', '\')); Args = @($c.smokeArgs) })
    }
    }
    # Fall back to finding the usual suspects if the manifest declared no smoke tests.
    if (-not $exeChecks.Count) {
        foreach ($guess in @(
            @{ Name = 'ffmpeg';  Pattern = 'ffmpeg.exe';      Args = @('-version') }
            @{ Name = 'whisper'; Pattern = 'whisper*.exe';     Args = @('--help')   }
            @{ Name = 'sherpa';  Pattern = 'sherpa-onnx*.exe'; Args = @('--help')   }
        )) {
            $hit = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'bin') -Recurse -Filter $guess.Pattern -File -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($hit) { [void]$exeChecks.Add([pscustomobject]@{ Name = $guess.Name; Exe = $hit.FullName; Args = $guess.Args }) }
    }
    }

    if (-not $exeChecks.Count) { Write-TiWarn 'no binaries present to smoke test (downloads were skipped or the manifest declared none)' }
    foreach ($chk in $exeChecks) {
        $r = Invoke-TiSmokeTest -ExePath $chk.Exe -Arguments $chk.Args
        [void]$smoke.Add([pscustomobject]@{ name = $chk.Name; exe = $chk.Exe; ok = $r.Ok; exitCode = $r.ExitCode; firstLine = $r.FirstLine; error = $r.Error })
        if ($r.Ok) { Write-TiOk "$($chk.Name) runs: $($r.FirstLine)" }
        else { Write-TiFail "$($chk.Name) did NOT run ($(if ($r.Error) { $r.Error } else { "exit $($r.ExitCode), no output" })): $($chk.Exe)" }
    }

    # --- models ---------------------------------------------------------------
    $modelDir = Join-Path $InstallRoot 'models'
    $models = @(Get-ChildItem -LiteralPath $modelDir -File -ErrorAction SilentlyContinue)
    $expectedModels = @($componentRecords | Where-Object { $_.target -like '*\models' })
    if ($expectedModels.Count) {
        foreach ($m in $expectedModels) {
            $f = Join-Path $modelDir $m.fileName
            if (-not (Test-Path -LiteralPath $f)) {
                Write-TiFail "model missing: $($m.fileName)"
                [void]$smoke.Add([pscustomobject]@{ name = $m.name; exe = $f; ok = $false; exitCode = $null; firstLine = ''; error = 'missing' })
                continue
            }
            $actual = (Get-Item -LiteralPath $f).Length
            if ($m.sizeBytes -gt 0 -and $actual -ne $m.sizeBytes) {
                Write-TiWarn "model $($m.fileName) is $(Format-TiBytes $actual), manifest said $(Format-TiBytes $m.sizeBytes)"
            }
            else { Write-TiOk "model $($m.fileName): $(Format-TiBytes $actual)" }
            [void]$smoke.Add([pscustomobject]@{ name = $m.name; exe = $f; ok = $true; exitCode = $null; firstLine = "$(Format-TiBytes $actual)"; error = '' })
    }
    }
    elseif ($models.Count) { Write-TiOk "$($models.Count) model file(s) present in models\" }
    else { Write-TiWarn 'models\ is empty' }

    # --- derived models -------------------------------------------------------
    foreach ($dr in $derivedRecords) {
        $ok = (Test-Path -LiteralPath $dr.path -PathType Leaf)
        if ($ok -and $dr.sizeBytes -gt 0) { $ok = ((Get-Item -LiteralPath $dr.path).Length -eq $dr.sizeBytes) }
        if ($ok) {
            $verdict = if ($dr.matchesPinned) { 'matches the pinned hash' } else { 'does NOT match the pinned hash - see the warning above' }
            Write-TiOk "derived model $(Split-Path -Leaf $dr.path): $(Format-TiBytes $dr.sizeBytes), $verdict"
    }
        else { Write-TiFail "derived model missing or the wrong size: $($dr.path)" }
        [void]$smoke.Add([pscustomobject]@{ name = $dr.name; exe = $dr.path; ok = $ok; exitCode = $null; firstLine = "$(Format-TiBytes $dr.sizeBytes)"; error = $(if ($ok) { '' } else { 'missing or wrong size' }) })
    }

    # --- install-time sources really are gone ---------------------------------
    # The whole economy of deriving the default model rests on this: +1.55 GiB of download,
    # ~0 net installed size. Asserting it here makes it a tested property rather than an
    # intention.
    foreach ($d in $derived) {
        if (-not $d.DeleteSourceAfter -or -not $d.SourcePath) { continue }
        $sp   = Join-Path $InstallRoot ($d.SourcePath -replace '/', '\')
        $gone = -not (Test-Path -LiteralPath $sp)
        if ($gone) { Write-TiOk "install-time source gone from the install tree: $($d.SourcePath)" }
        else { Write-TiFail "install-time source STILL PRESENT, inflating the install by $(Format-TiBytes (Get-Item -LiteralPath $sp).Length): $sp" }
        [void]$smoke.Add([pscustomobject]@{ name = "$($d.SourceComponent)-consumed"; exe = $sp; ok = $gone; exitCode = $null; firstLine = ''; error = $(if ($gone) { '' } else { 'still present' }) })
    }

    # --- the model the engine will actually ask for ----------------------------
    # This is the assertion whose absence WAS the defect: an install could report complete
    # success while config.json named a speech model nothing had installed, and the failure
    # only surfaced on the user's first transcription.
    $cfgModelName = ''
    $cfgModelOk   = $false
    try {
        $cfgLive = Read-TiJsonFile -Path $dstCfg
        if ($cfgLive.PSObject.Properties.Name -contains 'transcription' -and
            $cfgLive.transcription.PSObject.Properties.Name -contains 'model') {
            $cfgModelName = [string]$cfgLive.transcription.model
    }
        $md = ''
        if ($cfgLive.PSObject.Properties.Name -contains 'paths' -and
            $cfgLive.paths.PSObject.Properties.Name -contains 'modelDir') {
            $md = [string]$cfgLive.paths.modelDir -replace '/', '\'
    }
        if (-not $md) { $md = 'models' }
        $mdFull = if ([System.IO.Path]::IsPathRooted($md)) { $md } else { Join-Path $InstallRoot $md }
        if ($cfgModelName) {
            $mp = Join-Path $mdFull $cfgModelName
            $cfgModelOk = Test-Path -LiteralPath $mp -PathType Leaf
            if ($cfgModelOk) { Write-TiOk "config.json's default speech model resolves: $mp" }
            else { Write-TiFail "config.json sets transcription.model = '$cfgModelName' but it is NOT at $mp; the first transcription will fail" }
    }
    }
    catch { Write-TiWarn "could not check config.json's default speech model: $($_.Exception.Message)" }
    if ($cfgModelName) {
        [void]$smoke.Add([pscustomobject]@{ name = 'default-model'; exe = $cfgModelName; ok = $cfgModelOk; exitCode = $null; firstLine = ''; error = $(if ($cfgModelOk) { '' } else { 'not installed' }) })
    }

    # --- shell verb -----------------------------------------------------------
    # Presence is REQUIRED. This block was inverted (presence = failure) for part of
    # 2026-08-27 while the verb was retired; the verb was reinstated the same evening
    # (see the stage 5 history) and the original semantics came back with it.
    if (-not $SkipShellRegistration) {
        $regScript = Join-Path $dstApp 'Register-ShellVerbs.ps1'
        $v = & $regScript -InstallRoot $InstallRoot -RegistryRoot $RegistryRoot -Verify
        foreach ($f in $v.Findings) {
            if ($f.KeyPresent -and $f.CommandPresent) { Write-TiOk "verb present for $($f.Kind) '$($f.Subject)'" }
            else { Write-TiFail "verb MISSING for $($f.Kind) '$($f.Subject)'" }
        }
        [void]$smoke.Add([pscustomobject]@{ name = 'shell-verb'; exe = $RegistryRoot; ok = $v.Ok; exitCode = $null; firstLine = "$(@($v.Findings).Count) target(s)"; error = '' })
    }

    # --- launcher -------------------------------------------------------------
    $entry = Join-Path $dstApp 'Transcribe-Entry.ps1'
    $entryOk = Test-Path -LiteralPath $entry
    if ($entryOk) {
        $errs = $null; $tok = $null
        [System.Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tok, [ref]$errs) | Out-Null
        $entryOk = (@($errs).Count -eq 0)
    }
    if ($entryOk) { Write-TiOk 'launcher app\Transcribe-Entry.ps1 parses cleanly' } else { Write-TiFail 'launcher app\Transcribe-Entry.ps1 is missing or has syntax errors' }
    [void]$smoke.Add([pscustomobject]@{ name = 'launcher'; exe = $entry; ok = $entryOk; exitCode = $null; firstLine = ''; error = '' })
}

$manifest.smokeTests = $smoke.ToArray()
Write-TiJsonFile -Object ([pscustomobject]$manifest) -Path $manifestPath

# ================================================================= 8. SUMMARY ==

$failed = @($smoke | Where-Object { -not $_.ok })
Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host "  $script:TI_ProductName $Version installed." -ForegroundColor Green
}
else {
    Write-Host "  $script:TI_ProductName $Version installed, but $($failed.Count) smoke test(s) failed." -ForegroundColor Yellow
    foreach ($f in $failed) { Write-Host "    - $($f.name): $(if ($f.error) { $f.error } else { 'did not run' })" -ForegroundColor Yellow }
}
Write-Host ''
Write-Host "  location    $InstallRoot"
Write-Host "  logs        $InstallRoot\logs"
Write-Host "  manifest    $manifestPath"
Write-Host "  uninstall   pwsh -File `"$InstallRoot\Uninstall-TranscribeIt.ps1`""
Write-Host ''
if (-not $SkipShellRegistration -or -not $SkipSendTo) {
    if (-not $SkipShellRegistration) {
        Write-Host '  Right-click any audio or video file (classic menu / "Show more options"): "Transcribe in PDF".'
    }
    if (-not $SkipSendTo) {
        Write-Host '  Also available under Send to -> "Transcribe in PDF".'
    }
    Write-Host ''
}
Write-TiLog "install finished; smoke failures=$($failed.Count)"
if ($failed.Count) { exit 3 }
exit 0
