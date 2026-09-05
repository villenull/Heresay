<#
.SYNOPSIS
    Regenerates the self-contained Install-Heresay.vbs release asset.

.DESCRIPTION
    Builds Heresay-Setup.zip, then replaces the comment-only base64 payload in the
    existing Install-Heresay.vbs. The executable VBScript above the payload marker is
    kept verbatim, making the release asset regenerable from committed sources.
#>
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-Heresay.vbs'),
    [string] $DistributionOutputDir = (Join-Path $PSScriptRoot 'dist'),
    [switch] $IncludeDownloadCache,
    [string] $DownloadCacheSource = (Join-Path $env:LOCALAPPDATA 'TranscribeIt\downloads')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$marker = "'@@@HERESAY-PAYLOAD-BEGIN@@@"
$sourcePath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Installer template not found: $sourcePath"
}

$sourceLines = [System.IO.File]::ReadAllLines($sourcePath)
$markerIndexes = @(for ($i = 0; $i -lt $sourceLines.Length; $i++) {
    if ($sourceLines[$i] -eq $marker) { $i }
})
if ($markerIndexes.Count -ne 1) {
    throw "Expected exactly one payload marker in $sourcePath; found $($markerIndexes.Count)."
}
$header = @($sourceLines[0..$markerIndexes[0]])

$distributionArgs = @{
    OutputDir = $DistributionOutputDir
}
if ($IncludeDownloadCache) {
    $distributionArgs.IncludeDownloadCache = $true
    $distributionArgs.DownloadCacheSource = $DownloadCacheSource
}
& (Join-Path $PSScriptRoot 'Make-Distribution.ps1') @distributionArgs

$zipName = if ($IncludeDownloadCache) { 'Heresay-Setup-offline.zip' } else { 'Heresay-Setup.zip' }
$zipPath = Join-Path $DistributionOutputDir $zipName
if (-not (Test-Path -LiteralPath $zipPath)) { throw "Distribution build did not produce $zipPath" }

$payload = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zipPath))
$payloadLines = New-Object System.Collections.Generic.List[string]
for ($offset = 0; $offset -lt $payload.Length; $offset += 500) {
    $length = [Math]::Min(500, $payload.Length - $offset)
    $payloadLines.Add("'" + $payload.Substring($offset, $length))
}

$outputLines = @($header) + $payloadLines.ToArray()
[System.IO.File]::WriteAllText(
    $sourcePath,
    (($outputLines -join "`r`n") + "`r`n"),
    [System.Text.UTF8Encoding]::new($false)
)

# Decode the result again and compare bytes. A successful build must prove that the
# payload in the file is exactly the ZIP just produced, not merely valid base64.
$writtenLines = [System.IO.File]::ReadAllLines($sourcePath)
$writtenMarker = [Array]::IndexOf($writtenLines, $marker)
$encoded = (($writtenLines[($writtenMarker + 1)..($writtenLines.Length - 1)] |
    ForEach-Object { $_.Substring(1) }) -join '')
$decoded = [Convert]::FromBase64String($encoded)
$original = [System.IO.File]::ReadAllBytes($zipPath)
if ($decoded.Length -ne $original.Length -or
    -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$decoded, [byte[]]$original)) {
    throw 'Generated installer payload does not match the distribution ZIP.'
}

$hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
Write-Host "Generated: $sourcePath"
Write-Host "Payload:   $zipPath ($($original.Length) bytes)"
Write-Host "SHA256:    $hash"
