<#
    Generates installer\assets\TranscribeIt.ico.

    Written by hand as an uncompressed 32-bit BGRA icon rather than drawn with
    System.Drawing, because System.Drawing.Common is not part of the .NET 8 shared
    framework and there is no SDK on this machine to add the package. Raw ICO is a
    simple, well-specified container, so this needs no dependencies at all.

    Design: a document page with text lines and a speech bubble, in the accent blue.
    Sizes 16-64 so Explorer never rescales a context-menu glyph. Uncompressed 32bpp,
    so larger sizes are not worth their bytes here.
#>
[CmdletBinding()]
param(
    [string] $OutFile = (Join-Path $PSScriptRoot 'TranscribeIt.ico'),
    [int[]]  $Sizes = @(16, 20, 24, 32, 40, 48, 64)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Palette (BGRA order, as ICO/DIB stores it).
$colPage      = @(255, 255, 255, 255)   # white page
$colPageEdge  = @(190, 178, 166, 255)   # warm grey edge
$colFold      = @(225, 216, 208, 255)   # folded corner
$colText      = @(150, 130, 110, 255)   # text lines
$colAccent    = @(196, 108,  32, 255)   # speech bubble  (BGRA -> #206CC4)
$colAccentDk  = @(150,  80,  20, 255)

function New-Canvas {
    param([int] $W, [int] $H)
    # Row-major, top-down while drawing; flipped to bottom-up on write.
    $c = New-Object 'byte[][]' $H
    for ($y = 0; $y -lt $H; $y++) { $c[$y] = New-Object byte[] ($W * 4) }
    return $c
}

function Set-Pixel {
    param($Canvas, [int] $X, [int] $Y, [int[]] $Bgra, [double] $Alpha = 1.0)
    if ($Y -lt 0 -or $Y -ge $Canvas.Length) { return }
    $row = $Canvas[$Y]
    $w = $row.Length / 4
    if ($X -lt 0 -or $X -ge $w) { return }
    $i = $X * 4
    $a = $Bgra[3] * $Alpha
    if ($a -le 0) { return }
    $sa = $a / 255.0
    # Source-over onto whatever is already there.
    $dstA = $row[$i + 3] / 255.0
    $outA = $sa + $dstA * (1 - $sa)
    if ($outA -le 0) { return }
    for ($ch = 0; $ch -lt 3; $ch++) {
        $s = $Bgra[$ch] * $sa
        $d = $row[$i + $ch] * $dstA * (1 - $sa)
        $row[$i + $ch] = [byte][Math]::Min(255, [Math]::Round(($s + $d) / $outA))
    }
    $row[$i + 3] = [byte][Math]::Min(255, [Math]::Round($outA * 255))
}

function Fill-Rect {
    param($Canvas, [double] $X0, [double] $Y0, [double] $X1, [double] $Y1, [int[]] $Bgra)
    $xa = [int][Math]::Round($X0); $xb = [int][Math]::Round($X1)
    $ya = [int][Math]::Round($Y0); $yb = [int][Math]::Round($Y1)
    for ($y = $ya; $y -lt $yb; $y++) { for ($x = $xa; $x -lt $xb; $x++) { Set-Pixel -Canvas $Canvas -X $x -Y $y -Bgra $Bgra } }
}

function Fill-Disc {
    param($Canvas, [double] $Cx, [double] $Cy, [double] $R, [int[]] $Bgra)
    $x0 = [int][Math]::Floor($Cx - $R - 1); $x1 = [int][Math]::Ceiling($Cx + $R + 1)
    $y0 = [int][Math]::Floor($Cy - $R - 1); $y1 = [int][Math]::Ceiling($Cy + $R + 1)
    for ($y = $y0; $y -le $y1; $y++) {
        for ($x = $x0; $x -le $x1; $x++) {
            # 3x3 supersample for a smooth edge.
            $hits = 0
            for ($sy = 0; $sy -lt 3; $sy++) {
                for ($sx = 0; $sx -lt 3; $sx++) {
                    $px = $x + ($sx + 0.5) / 3.0
                    $py = $y + ($sy + 0.5) / 3.0
                    if ((($px - $Cx) * ($px - $Cx) + ($py - $Cy) * ($py - $Cy)) -le ($R * $R)) { $hits++ }
                }
            }
            if ($hits -gt 0) { Set-Pixel -Canvas $Canvas -X $x -Y $y -Bgra $Bgra -Alpha ($hits / 9.0) }
        }
    }
}

function Draw-Icon {
    param([int] $S)
    $c = New-Canvas -W $S -H $S
    $u = $S / 32.0    # design grid is 32x32

    # --- page ---------------------------------------------------------------
    $px0 = 6 * $u; $px1 = 24 * $u
    $py0 = 3 * $u; $py1 = 29 * $u
    $fold = 6 * $u
    Fill-Rect -Canvas $c -X0 ($px0 - [Math]::Max(1, $u)) -Y0 ($py0 - [Math]::Max(1, $u)) -X1 ($px1 + [Math]::Max(1, $u)) -Y1 ($py1 + [Math]::Max(1, $u)) -Bgra $colPageEdge
    Fill-Rect -Canvas $c -X0 $px0 -Y0 $py0 -X1 $px1 -Y1 $py1 -Bgra $colPage

    # folded top-right corner
    $steps = [int][Math]::Max(2, [Math]::Round($fold))
    for ($i = 0; $i -lt $steps; $i++) {
        $y = $py0 + $i
        $x = $px1 - $fold + $i
        Fill-Rect -Canvas $c -X0 $x -Y0 $y -X1 $px1 -Y1 ($y + 1) -Bgra $colFold
    }

    # --- text lines ---------------------------------------------------------
    # Uneven lengths so it reads as prose, not a table.
    $lineDefs = @(
        @{ Y = 9;  L = 0.62 }, @{ Y = 12; L = 0.86 }, @{ Y = 15; L = 0.74 },
        @{ Y = 18; L = 0.90 }, @{ Y = 21; L = 0.55 }
    )
    $lh = [Math]::Max(1, [Math]::Round(1.6 * $u))
    foreach ($ld in $lineDefs) {
        $x0 = $px0 + 2.5 * $u
        $x1 = $x0 + ($px1 - $x0 - 2.0 * $u) * $ld.L
        Fill-Rect -Canvas $c -X0 $x0 -Y0 ($ld.Y * $u) -X1 $x1 -Y1 ($ld.Y * $u + $lh) -Bgra $colText
    }

    # --- speech bubble (bottom-right) ---------------------------------------
    $bcx = 22.5 * $u; $bcy = 22.5 * $u; $br = 7.5 * $u
    Fill-Disc -Canvas $c -Cx $bcx -Cy $bcy -R $br -Bgra $colAccentDk
    Fill-Disc -Canvas $c -Cx $bcx -Cy $bcy -R ($br - [Math]::Max(0.6, 0.7 * $u)) -Bgra $colAccent
    # tail
    $t = [int][Math]::Max(2, [Math]::Round(3 * $u))
    for ($i = 0; $i -lt $t; $i++) {
        Fill-Rect -Canvas $c -X0 ($bcx - 6.0 * $u + $i * 0.5) -Y0 ($bcy + $br - 1.5 * $u + $i) -X1 ($bcx - 3.0 * $u + $i * 0.9) -Y1 ($bcy + $br - 1.0 * $u + $i + 1) -Bgra $colAccent
    }
    # three dots, only where there is room to render them
    if ($S -ge 24) {
        $dr = [Math]::Max(0.8, 1.05 * $u)
        foreach ($dx in @(-3.2, 0.0, 3.2)) {
            Fill-Disc -Canvas $c -Cx ($bcx + $dx * $u) -Cy $bcy -R $dr -Bgra @(255, 255, 255, 255)
        }
    }
    else {
        Fill-Rect -Canvas $c -X0 ($bcx - 3.4 * $u) -Y0 ($bcy - 0.9 * $u) -X1 ($bcx + 3.4 * $u) -Y1 ($bcy + 0.9 * $u) -Bgra @(255, 255, 255, 255)
    }

    return ,$c
}

function Get-DibBytes {
    <# BITMAPINFOHEADER + bottom-up BGRA pixels + a (zeroed, byte-aligned) AND mask.
       Height in the header is doubled: that is how ICO declares colour+mask. #>
    param($Canvas, [int] $S)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]40)          # biSize
    $bw.Write([int32]$S)           # biWidth
    $bw.Write([int32]($S * 2))     # biHeight (colour + mask)
    $bw.Write([uint16]1)           # biPlanes
    $bw.Write([uint16]32)          # biBitCount
    $bw.Write([uint32]0)           # BI_RGB
    $bw.Write([uint32]($S * $S * 4))
    $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)
    # Explicit [byte[]] casts throughout: given an Object[] of bytes, PowerShell picks a
    # scalar BinaryWriter.Write overload and silently writes one byte instead of the row.
    for ($y = $S - 1; $y -ge 0; $y--) { $bw.Write([byte[]]$Canvas[$y]) }   # bottom-up
    $maskRow = [int][Math]::Ceiling($S / 32.0) * 4                 # 32-bit aligned
    $zero = New-Object byte[] $maskRow
    for ($y = 0; $y -lt $S; $y++) { $bw.Write([byte[]]$zero) }
    $bw.Flush()
    return ,([byte[]]$ms.ToArray())
}

# ------------------------------------------------------------------ assemble --
$images = @()
foreach ($s in ($Sizes | Sort-Object)) {
    $images += [pscustomobject]@{ Size = $s; Data = (Get-DibBytes -Canvas (Draw-Icon -S $s) -S $s) }
    Write-Verbose "rendered ${s}x${s}"
}

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$fs = [System.IO.File]::Create($OutFile)
try {
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$images.Count)   # ICONDIR
    $offset = 6 + 16 * $images.Count
    foreach ($img in $images) {
        $bw.Write([byte]($(if ($img.Size -ge 256) { 0 } else { $img.Size })))      # 0 means 256
        $bw.Write([byte]($(if ($img.Size -ge 256) { 0 } else { $img.Size })))
        $bw.Write([byte]0)      # palette count
        $bw.Write([byte]0)      # reserved
        $bw.Write([uint16]1)    # planes
        $bw.Write([uint16]32)   # bpp
        $bw.Write([uint32]$img.Data.Length)
        $bw.Write([uint32]$offset)
        $offset += $img.Data.Length
    }
    foreach ($img in $images) { $bw.Write([byte[]]$img.Data) }
    $bw.Flush()
}
finally { $fs.Dispose() }

$fi = Get-Item -LiteralPath $OutFile
Write-Host "wrote $($fi.FullName) - $($images.Count) sizes, $([Math]::Round($fi.Length/1KB,1)) KB"
