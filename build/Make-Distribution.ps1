<#
.SYNOPSIS
    Packages this repo into the distributable Heresay-Setup folder (and zip) that a
    non-technical colleague can install from.

.DESCRIPTION
    Stages exactly what the double-click install path needs and nothing else:

        Install Heresay.vbs     the entry point: opens the graphical installer
                                with no console window (from the repo root)
        Install Heresay.cmd     the console fallback entry point (repo root)
        app\                    every app file
        contracts\              every contract file
        installer\              the five install scripts plus assets\ - never tests\
        README.txt              generated here, written for the recipient
        dist-manifest.json      traceability: commit, timestamp, file count
        download-cache\         only with -IncludeDownloadCache: the archives and
                                models the download manifest references, so the
                                install needs little or no network

    A bundled cache is safe to ship because the installer verifies every cache entry
    by SHA-256 against contracts\download-manifest.json before using it - a corrupted
    or tampered file is re-downloaded, never installed.

.PARAMETER OutputDir
    Where the staging folder and the zip land. Default: build\dist beside this script.

.PARAMETER IncludeDownloadCache
    Bundle the pre-seeded component cache for offline installs. The resulting zip is
    around 2.7 GB.

.PARAMETER DownloadCacheSource
    Where cache files are taken from. The default mirrors the installer's own
    -DownloadCache default (installer\Install-TranscribeIt.ps1), so "install once on
    this machine, then build the offline package" needs no extra flags.

.PARAMETER ZipName
    Defaults to Heresay-Setup.zip, or Heresay-Setup-offline.zip when the cache is
    bundled.

.PARAMETER NoZip
    Stage the folder only.

.EXAMPLE
    pwsh -NoProfile -File build\Make-Distribution.ps1

.EXAMPLE
    pwsh -NoProfile -File build\Make-Distribution.ps1 -IncludeDownloadCache

.EXAMPLE
    pwsh -NoProfile -File build\Make-Distribution.ps1 -NoZip -OutputDir C:\temp\dist
#>
[CmdletBinding()]
param(
    [string] $OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [switch] $IncludeDownloadCache,
    [string] $DownloadCacheSource = (Join-Path $env:LOCALAPPDATA 'TranscribeIt\downloads'),
    [string] $ZipName,
    [switch] $NoZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Same console voice as the installer, minus its log plumbing - this script runs on a
# maintainer's machine, where the console IS the log.
function Write-Step { param([string] $m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Info { param([string] $m) Write-Host "    $m" }
function Write-Ok   { param([string] $m) Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Wrn  { param([string] $m) Write-Host "    WARN $m" -ForegroundColor Yellow }
function Write-Fail { param([string] $m) Write-Host "    FAIL $m" -ForegroundColor Red }

function Format-Bytes {
    param([long] $n)
    if ($n -ge 1GB) { return '{0:N2} GB' -f ($n / 1GB) }
    if ($n -ge 1MB) { return '{0:N1} MB' -f ($n / 1MB) }
    if ($n -ge 1KB) { return '{0:N1} KB' -f ($n / 1KB) }
    return "$n bytes"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ZipName) { $ZipName = if ($IncludeDownloadCache) { 'Heresay-Setup-offline.zip' } else { 'Heresay-Setup.zip' } }

Write-Host ''
Write-Host '  Heresay distribution builder' -ForegroundColor White
Write-Host "  source: $repoRoot"
Write-Host ''

# ================================================================ 1. PREFLIGHT ==

Write-Step 'Verifying the source tree'

# The app files the installer records in install-manifest.json files[]. The authority
# is $appFiles in installer\Install-TranscribeIt.ps1 - keep this list in step with it.
# A file missing HERE ships a package whose installer warns or dies on the recipient's
# machine, so the build dies here instead.
$requiredAppFiles = @(
    'Transcribe-Entry.ps1', 'Register-ShellVerbs.ps1', 'Transcribe.ps1',
    'Merge-Diarization.ps1', 'Render-Pdf.ps1', 'template.html', 'Progress.ps1',
    'config.default.json', 'SendTo-Heresay.ps1', 'Compress-ForWord.ps1', 'Run-Hidden.vbs',
    # Required in $appFiles too. Without it the package still downloads and verifies the
    # two naudio components, so a recipient gets the capture library and nothing that
    # loads it - a broken feature that installs cleanly. Fail the build instead.
    'Record-Conversation.ps1',
    'Register-RecordVerb.ps1',
    # The home window the "Heresay" Start Menu shortcut opens. Register-RecordVerb.ps1
    # creates that shortcut on every install, so a package without this file installs a
    # Start entry that points at nothing.
    'Heresay-Home.ps1'
)

$required = @(
    # Built by other tracks. A package without its entry points (the .vbs that opens
    # the graphical installer, the .cmd console fallback) or the scripts they run is a
    # folder of scripts a non-technical person cannot run, so their absence is fatal.
    'Install Heresay.vbs'
    'Install Heresay.cmd'
    'installer\Install-Gui.ps1'
    'installer\Bootstrap-Pwsh.ps1'
    'installer\Install-TranscribeIt.ps1'
    'installer\Install-Common.ps1'
    'installer\Uninstall-TranscribeIt.ps1'
    'installer\assets'
    'contracts\download-manifest.json'
) + @($requiredAppFiles | ForEach-Object { "app\$_" })

$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_)) })
if ($missing.Count) {
    foreach ($m in $missing) { Write-Fail "missing: $m" }
    throw "The source tree is missing $($missing.Count) required item(s): $($missing -join ', '). Nothing was staged."
}

# The manifest gates the cache stage here and every download at install time, so it has
# to parse before anything is copied.
$manifestPath = Join-Path $repoRoot 'contracts\download-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Write-Ok "$($required.Count) required item(s) present; download manifest parses"

# ================================================================== 2. STAGING ==

Write-Step "Staging into $OutputDir"

if (-not (Test-Path -LiteralPath $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }
$stageRoot = Join-Path (Resolve-Path -LiteralPath $OutputDir).ProviderPath 'Heresay-Setup'
if (Test-Path -LiteralPath $stageRoot) {
    Write-Info 'removing the previous staging folder'
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $stageRoot -Force

Copy-Item -LiteralPath (Join-Path $repoRoot 'Install Heresay.vbs') -Destination $stageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'Install Heresay.cmd') -Destination $stageRoot

# app\ and contracts\ ship whole - the contract says every file - then development
# debris (*.bak*, *.log, logs\) is pruned from the STAGED copy, never from the repo.
Copy-Item -LiteralPath (Join-Path $repoRoot 'app')       -Destination (Join-Path $stageRoot 'app') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'contracts') -Destination (Join-Path $stageRoot 'contracts') -Recurse

# installer\ is picked file by file rather than copied-then-pruned: tests\ must never
# ship, and a copy-then-delete would still ship it if the delete broke.
$stageInstaller = (New-Item -ItemType Directory -Path (Join-Path $stageRoot 'installer') -Force).FullName
foreach ($f in @('Install-Gui.ps1', 'Install-TranscribeIt.ps1', 'Install-Common.ps1', 'Uninstall-TranscribeIt.ps1', 'Bootstrap-Pwsh.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "installer\$f") -Destination $stageInstaller
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'installer\assets') -Destination (Join-Path $stageInstaller 'assets') -Recurse

# vendor\, test\, docs\, .git and installer\tests were never copied in the first place.
$pruned = 0
foreach ($item in @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force |
            Where-Object { $_.Name -like '*.bak*' -or $_.Name -like '*.log' -or ($_.PSIsContainer -and $_.Name -eq 'logs') })) {
    if (Test-Path -LiteralPath $item.FullName) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
        $pruned++
    }
}

$stagedCount = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File).Count
Write-Ok "$stagedCount file(s) staged ($pruned development item(s) pruned)"

# =========================================================== 3. DOWNLOAD CACHE ==

$cacheBundled = $false
if ($IncludeDownloadCache) {
    Write-Step "Bundling the download cache from $DownloadCacheSource"

    # Only what the manifest actually references, matched on its filename field - never
    # the whole directory, which can hold retired components and partial *.part files.
    # derivedComponents[] have no filename: they are produced at install time, so there
    # is nothing to bundle for them.
    $wanted = @($manifest.components | Where-Object { $_.PSObject.Properties['filename'] -and $_.filename })
    $cacheDir = Join-Path $stageRoot 'download-cache'
    $copied = 0
    $cacheBytes = [long] 0
    $absent = New-Object System.Collections.Generic.List[string]

    foreach ($c in $wanted) {
        $src = Join-Path $DownloadCacheSource $c.filename
        if (Test-Path -LiteralPath $src) {
            if (-not (Test-Path -LiteralPath $cacheDir)) { $null = New-Item -ItemType Directory -Path $cacheDir -Force }
            Copy-Item -LiteralPath $src -Destination $cacheDir
            $cacheBytes += (Get-Item -LiteralPath $src).Length
            $copied++
        }
        else { $absent.Add([string] $c.filename) }
    }

    # Absent entries are a warning, not a failure: the installer downloads whatever the
    # cache does not supply, so the package still works - it is just not fully offline.
    if ($copied) {
        $cacheBundled = $true
        Write-Ok ("{0} of {1} manifest file(s) bundled - {2}" -f $copied, $wanted.Count, (Format-Bytes $cacheBytes))
        Write-Info 'every entry is SHA-256 verified against the manifest at install time before use'
    }
    else {
        Write-Wrn "no manifest-referenced file was found in '$DownloadCacheSource' - the package will install online"
    }
    foreach ($a in $absent) { Write-Wrn "not in the local cache, will be downloaded at install time: $a" }
}

# ================================================================ 4. README.txt ==

Write-Step 'Writing README.txt for the recipient'

$downloadLine = if ($cacheBundled) {
    'This is the OFFLINE package: the components ship in the download-cache'
    'folder, so installing needs little or no internet connection.'
} else {
    'The first install downloads about 2.7 GB of speech models and tools, so'
    'allow some time on a slow connection. It resumes if interrupted.'
}

$readmeLines = @(
    'Heresay - transcripts on your own machine'
    '=========================================='
    ''
    'WHAT THIS IS'
    ''
    '  Heresay is an internal tool that turns an audio or video recording into'
    '  a timestamped transcript PDF, fast. Everything runs on your own'
    '  computer: recordings are never uploaded anywhere.'
    ''
    'HOW TO INSTALL'
    ''
    '  1. If you received this as a .zip file: right-click it, choose'
    '     "Extract All...", and extract it anywhere (Downloads is fine).'
    '     Do not skip this - it will not install from inside the zip.'
    '  2. Open the extracted "Heresay-Setup" folder.'
    '  3. Double-click "Install Heresay" - a setup window will open;'
    '     click Install. (There are two "Install Heresay" files; either one'
    '     opens the same setup window, so it does not matter which you pick.)'
    ''
    '  You do NOT need administrator rights.'
    "  $($downloadLine[0])"
    "  $($downloadLine[1])"
    '  If Windows shows a blue "protected your PC" message, click "More info"'
    '  and then "Run anyway".'
    ''
    'HOW TO USE IT'
    ''
    '  1. In File Explorer, right-click any recording (mp3, m4a, mp4, wav, ...).'
    '  2. Choose "Send to", then "Heresay - Generate transcript (PDF)".'
    '  3. A progress window opens. When it finishes, the PDF is saved next to'
    '     the recording.'
    ''
    '  The "Send to" menu also offers faster variants with lower accuracy, a'
    '  "Solo recording" mode for a single speaker, and "Save as PDF" /'
    '  "Compress for Word" helpers for existing documents.'
    ''
    'HOW TO UNINSTALL'
    ''
    '  Paste %LOCALAPPDATA%\Programs\TranscribeIt into the File Explorer'
    '  address bar, right-click Uninstall-TranscribeIt.ps1, and choose'
    '  "Run with PowerShell". This removes the tool and its menu entries;'
    '  your recordings and PDFs are not touched.'
    ''
    'IF SOMETHING GOES WRONG'
    ''
    '  The installer and the app write logs to:'
    '      %LOCALAPPDATA%\Programs\TranscribeIt\logs'
    '  (paste that into the File Explorer address bar). If the install failed'
    '  so early that this folder does not exist, look for a file named'
    '  TranscribeIt-install-*.log in %TEMP% instead. Send the newest log to'
    '  whoever gave you this package.'
    ''
)

# CRLF explicitly, because Notepad is the realistic reader here.
[System.IO.File]::WriteAllText((Join-Path $stageRoot 'README.txt'),
    (($readmeLines -join "`r`n") + "`r`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Ok 'README.txt written'

# ========================================================= 5. DIST MANIFEST ==

Write-Step 'Writing dist-manifest.json'

$commit = $null
try {
    $commit = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { $commit = $null }
}
catch { $commit = $null }
if (-not $commit) {
    Write-Wrn 'the git commit could not be determined; recording "unknown"'
    $commit = 'unknown'
}

# +1 counts dist-manifest.json itself, so fileCount matches what the recipient unpacks.
$fileCount = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File).Count + 1
$distManifest = [ordered]@{
    product               = 'Heresay'
    builtUtc              = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    gitCommit             = $commit
    fileCount             = $fileCount
    downloadCacheBundled  = $cacheBundled
}
[System.IO.File]::WriteAllText((Join-Path $stageRoot 'dist-manifest.json'),
    (($distManifest | ConvertTo-Json) + "`r`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Ok "commit $commit, $fileCount file(s), cache bundled: $cacheBundled"

# ===================================================================== 6. ZIP ==

if ($NoZip) {
    Write-Step 'Skipping the zip (-NoZip)'
    Write-Info "distribute the folder as-is: $stageRoot"
}
else {
    Write-Step "Zipping to $ZipName"
    if ($cacheBundled) { Write-Wrn 'the offline zip is ~2.7 GB when fully seeded; this can take a few minutes' }
    $zipPath = Join-Path (Split-Path -Parent $stageRoot) $ZipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    # -Path, not -LiteralPath: the staged root is one wildcard-free folder, and zipping
    # the FOLDER (not its contents) is what makes "Extract All -> open the folder" true.
    Compress-Archive -Path $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Ok ("{0} - {1}" -f $zipPath, (Format-Bytes (Get-Item -LiteralPath $zipPath).Length))
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host "  staging: $stageRoot"
if (-not $NoZip) { Write-Host "  zip:     $(Join-Path (Split-Path -Parent $stageRoot) $ZipName)" }
Write-Host ''
