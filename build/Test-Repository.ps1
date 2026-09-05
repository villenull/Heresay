<# Validates source contracts and builds the embedded installer in a temporary folder. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string] $Message) {
    $failures.Add($Message)
    Write-Host "FAIL $Message" -ForegroundColor Red
}

function Test-Condition([bool] $Condition, [string] $Message) {
    if (-not $Condition) { Add-Failure $Message }
}

Write-Host 'Parsing PowerShell files'
foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notlike '*\build\dist\*' })) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) { Add-Failure "$($file.FullName): $($error.Message)" }
}

Write-Host 'Parsing JSON and JSON Lines files'
foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.json' |
        Where-Object { $_.FullName -notlike '*\build\dist\*' })) {
    try { $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Add-Failure "$($file.FullName): $($_.Exception.Message)" }
}
foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.jsonl')) {
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
        $lineNumber++
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try { $null = $line | ConvertFrom-Json -ErrorAction Stop }
            catch { Add-Failure "$($file.FullName):${lineNumber}: $($_.Exception.Message)" }
        }
    }
}

Write-Host 'Checking transcript fixture against its schema'
$turnsJson = Get-Content -LiteralPath (Join-Path $repoRoot 'contracts\turns.example.json') -Raw
$turnsSchema = Join-Path $repoRoot 'contracts\turns.schema.json'
Test-Condition ($turnsJson | Test-Json -SchemaFile $turnsSchema) 'turns.example.json does not satisfy turns.schema.json'

Write-Host 'Checking download-manifest invariants'
$manifestPath = Join-Path $repoRoot 'contracts\download-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$components = @($manifest.components)
$requiredBytes = [long](($components | Where-Object { $_.required -ne $false } | Measure-Object sizeBytes -Sum).Sum)
$allBytes = [long](($components | Measure-Object sizeBytes -Sum).Sum)
Test-Condition ($manifest.totalRequiredBytes -eq $requiredBytes) 'totalRequiredBytes does not match required components'
Test-Condition ($manifest.totalAllBytes -eq $allBytes) 'totalAllBytes does not match all components'
foreach ($component in $components) {
    Test-Condition ([string]$component.sha256 -match '^[0-9a-f]{64}$') "$($component.name) has an invalid SHA256"
    Test-Condition ([uri]::IsWellFormedUriString([string]$component.url, [System.UriKind]::Absolute)) "$($component.name) has an invalid URL"
}

. (Join-Path $repoRoot 'installer\Install-Common.ps1')
$normalised = @(Resolve-TiDownloadManifest -Path $manifestPath)
$expectedOptional = @($components | Where-Object { $_.required -eq $false }).Count
$actualOptional = @($normalised | Where-Object Optional).Count
Test-Condition ($actualOptional -eq $expectedOptional) "installer saw $actualOptional optional components; manifest declares $expectedOptional"

Write-Host 'Checking repository hygiene'
$rootInstallers = @(Get-ChildItem -LiteralPath $repoRoot -File | Where-Object { $_.Name -match '(?i)^install.*\.(vbs|cmd|ps1)$' })
Test-Condition ($rootInstallers.Count -eq 1 -and $rootInstallers[0].Name -eq 'Install-Heresay.vbs') 'repository root must contain only Install-Heresay.vbs'
foreach ($retired in @('app\SendTo-Heresay.ps1', 'app\Compress-ForWord.ps1', 'app\Save-AsPdf.ps1', 'installer\manifest.example.json')) {
    Test-Condition (-not (Test-Path -LiteralPath (Join-Path $repoRoot $retired))) "$retired should not exist"
}

Write-Host 'Building and inspecting the installer package'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('heresay-validation-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $tempInstaller = Join-Path $tempRoot 'Install-Heresay.vbs'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'Install-Heresay.vbs') -Destination $tempInstaller
    & (Join-Path $repoRoot 'build\Make-Installer-Vbs.ps1') -OutputPath $tempInstaller -DistributionOutputDir (Join-Path $tempRoot 'dist')
    $zipPath = Join-Path $tempRoot 'dist\Heresay-Setup.zip'
    Test-Condition (Test-Path -LiteralPath $zipPath) 'package build did not produce Heresay-Setup.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($zip.Entries | ForEach-Object FullName)
        Test-Condition ($names -contains 'Heresay-Setup/THIRD_PARTY_NOTICES.md') 'package is missing THIRD_PARTY_NOTICES.md'
        foreach ($leaf in @('SendTo-Heresay.ps1', 'Compress-ForWord.ps1', 'Save-AsPdf.ps1', 'manifest.example.json')) {
            Test-Condition (-not @($names | Where-Object { $_ -like "*/$leaf" }).Count) "package contains retired $leaf"
        }
    }
    finally { $zip.Dispose() }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if ($failures.Count) { throw "$($failures.Count) repository validation check(s) failed." }
Write-Host 'All repository checks passed.' -ForegroundColor Green
