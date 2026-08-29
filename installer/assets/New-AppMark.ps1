<#
.SYNOPSIS
    Generates the multi-size application .ico from the SAME geometry the progress
    window draws at runtime.

.DESCRIPTION
    Supersedes New-AppIcon.ps1 (Track C's original three-line page mark).

    The point of this script is that the icon geometry is single-sourced. Rather than
    duplicating the drawing code here - which would silently drift the moment either
    copy was touched - it extracts the `$appIcon` drawing block and its helper
    functions out of `app\Progress.ps1` using the PowerShell AST, and renders that.

    So: to change the logo, edit the `$appIcon` block in app\Progress.ps1 and re-run
    this script. There is exactly one definition of the mark.

    Frames are PNG-compressed inside the .ico, which Windows has supported since
    Vista. That keeps the file small (~14 KB for 8 sizes) and avoids hand-rolling
    BITMAPINFOHEADER plus an AND mask.

.PARAMETER OutFile
    Where to write the .ico. Defaults to TranscribeIt.ico beside this script.

.PARAMETER Sizes
    Icon frame sizes. 16/20/24/32 cover the title bar, taskbar and Explorer list
    views; 48/64 cover tiles; 128/256 cover the extra-large view and Alt-Tab.
#>
[CmdletBinding()]
param(
    [string] $OutFile = (Join-Path $PSScriptRoot 'TranscribeIt.ico'),
    [int[]]  $Sizes   = @(16, 20, 24, 32, 48, 64, 128, 256),
    [string] $SourceScript = (Join-Path $PSScriptRoot '..\..\app\Progress.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$src = [System.IO.Path]::GetFullPath($SourceScript)
if (-not (Test-Path -LiteralPath $src)) { throw "cannot find the geometry source: $src" }
Write-Host "geometry source : $src"

$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)

# Lift the helpers the drawing block depends on, straight out of the shipped file.
$needed = 'New-MediaColor', 'Format-Invariant', 'New-IconBitmap'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($needed -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
$missing = @($needed | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missing.Count) { throw "could not extract helper(s) from ${src}: $($missing -join ', ')" }

# New-IconBitmap logs through Write-UiLog on its fallback path; the progress window owns
# that function, so stub it here.
function Write-UiLog([string] $Message) { Write-Verbose "  [from Progress.ps1] $Message" }

$assign = @($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$appIcon' }, $true)) | Select-Object -First 1
if (-not $assign) { throw "could not find the `$appIcon assignment in $src" }

# "New-IconBitmap { ... } 64" -> swap the trailing size per frame.
$callText = $assign.Right.Extent.Text
if ($callText -notmatch '\}\s*\d+\s*$') { throw 'the $appIcon call does not end in a literal size; cannot re-render at other sizes' }

function Get-MarkPng([int] $Size) {
    $sb  = [scriptblock]::Create(($callText -replace '\}\s*\d+\s*$', "} $Size"))
    $bmp = & $sb
    if ($null -eq $bmp) { throw "render at ${Size}px returned nothing" }
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $ms = [System.IO.MemoryStream]::new()
    $enc.Save($ms)
    return $ms.ToArray()
}

# NB: build this as a typed list. "foreach { ,(...) }" wraps each byte[] in an outer
# array, so Length later reports 1 and every frame in the .ico ends up 1 byte long.
$frames = [System.Collections.Generic.List[byte[]]]::new()
foreach ($s in $Sizes) {
    $png = [byte[]](Get-MarkPng $s)
    $frames.Add($png)
    Write-Host ("  {0,3}px -> {1,6} bytes" -f $s, $png.Length)
}

$ms = [System.IO.MemoryStream]::new()
$bw = [System.IO.BinaryWriter]::new($ms)
$bw.Write([uint16]0)             # reserved
$bw.Write([uint16]1)             # type 1 = icon
$bw.Write([uint16]$Sizes.Count)
$offset = 6 + (16 * $Sizes.Count)
for ($i = 0; $i -lt $Sizes.Count; $i++) {
    $s = $Sizes[$i]; $d = $frames[$i]
    $dim = if ($s -ge 256) { 0 } else { $s }   # 0 means 256 in the ICO dir entry
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)
    $bw.Write([byte]0)               # palette count
    $bw.Write([byte]0)               # reserved
    $bw.Write([uint16]1)             # colour planes
    $bw.Write([uint16]32)            # bits per pixel
    $bw.Write([uint32]$d.Length)
    $bw.Write([uint32]$offset)
    $offset += $d.Length
}
foreach ($d in $frames) { $bw.Write($d) }
$bw.Flush()

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllBytes($OutFile, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

$info = Get-Item -LiteralPath $OutFile
Write-Host ("`nwrote {0}" -f $info.FullName)
Write-Host ("  {0} frames, {1:N0} bytes" -f $Sizes.Count, $info.Length)

# Read it back through the shell's own icon loader as a sanity check - if Windows
# cannot decode it, the Explorer verb would fall back to a blank page icon.
try {
    $dec = [System.Windows.Media.Imaging.IconBitmapDecoder]::new(
        [Uri]::new($info.FullName),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    Write-Host ("  verified: Windows decoded {0} frame(s): {1}" -f $dec.Frames.Count,
        (($dec.Frames | ForEach-Object { "$($_.PixelWidth)px" }) -join ' '))
} catch {
    throw "the .ico was written but Windows could not decode it: $($_.Exception.Message)"
}
