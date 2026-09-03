<#
.SYNOPSIS
    Renders a TranscribeIt transcript JSON document into a finished PDF.

.DESCRIPTION
    Track B (renderer). Consumes the FROZEN transcript contract in
    contracts/turns.schema.json and produces a print-ready PDF via
    app/template.html and headless Microsoft Edge (--print-to-pdf).

    The PDF contains the transcript only - no header block, no metadata, no
    warnings box, no speakers table, no legend - and the footer is a page
    number (decision 2026-08-26, recorded in contracts/CONTRACTS.md).
    warnings[] are read and reported on the console but are deliberately NOT
    rendered; they reach the user through the completion UI instead.

    100% offline. The generated HTML declares a Content-Security-Policy of
    default-src 'none' and references no external resource of any kind, so the
    render cannot reach the network. Edge is additionally launched with an
    isolated --user-data-dir in a temp folder so it can never collide with, or
    write to, the user's real browser profile.

.PARAMETER TurnsJson
    Path to the transcript JSON (contracts/turns.schema.json, schemaVersion 1).

.PARAMETER OutputPdf
    Path of the PDF to write. Parent directory is created if missing. An
    existing file is replaced only after a successful render.

.PARAMETER TemplatePath
    Override the HTML template. Defaults to template.html beside this script.

.PARAMETER EdgePath
    Override the Edge executable. Defaults to the standard install locations.

.PARAMETER KeepHtml
    Also write the intermediate HTML next to OutputPdf (same base name, .html).
    Useful for design work and for the manual Ctrl+P fallback route.

.PARAMETER KeepTemp
    Do not delete the temp working directory. Debugging only.

.PARAMETER TimeoutSeconds
    Hard limit on each headless Edge print attempt. Default 180.

.PARAMETER PostExitGraceSeconds
    How long to keep waiting for the PDF AFTER the launched Edge process exits.
    Default 30. The process we start is a launcher: it hands the print to a
    detached child and exits, so its exit says nothing about whether the
    document is written. Measured with Edge 151.0.4129.107: launcher out at
    393 ms, PDF complete at 2504 ms. Treating exit as final is what broke every
    render on 2026-08-27. Only ever spent when the PDF is not yet on disk, and
    it is clamped to -TimeoutSeconds. 0 restores the old exit-is-final
    behaviour, which is wrong on this Edge build and exists only for bisecting.

.PARAMETER MaxAttempts
    How many times to try the print before giving up. Default 2. Headless Edge
    was observed to stall once in roughly 25 renders on a loaded machine; each
    attempt gets a fresh browser profile. A print refused by enterprise policy
    is treated as permanent and is never retried.

.PARAMETER Quiet
    Suppress progress chatter on stdout. Errors still go to stderr.

.OUTPUTS
    Exit codes:
      0  success
      2  bad usage / input not found
      3  transcript JSON could not be parsed or failed contract checks
      4  no usable Microsoft Edge executable found
      5  headless Edge did not produce a usable PDF
      6  could not write the intermediate HTML or move the PDF into place

.EXAMPLE
    .\Render-Pdf.ps1 -TurnsJson ".\turns.json" -OutputPdf "C:\Cases\Weekly steerco 2026-08-19.pdf"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $TurnsJson,
    [Parameter(Mandatory = $true)] [string] $OutputPdf,
    [string] $TemplatePath,
    [string] $EdgePath,
    [switch] $KeepHtml,
    [switch] $KeepTemp,
    [int]    $TimeoutSeconds = 180,
    [ValidateRange(1, 5)]
    [int]    $MaxAttempts = 2,
    [ValidateRange(0, 120)]
    [int]    $PostExitGraceSeconds = 30,
    [switch] $Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ExitCode = 0

# --------------------------------------------------------------------------
#  render telemetry
#
#  The engine throws this script's stdout away on a SUCCESSFUL render (see
#  Invoke-Render in app/Transcribe.ps1: stdout and stderr are logged only when
#  the exit code is non-zero). A retry that eventually succeeds is therefore
#  completely invisible - it just looks like a slow render, which is precisely
#  why the 11.2 s - 94.7 s spread Track B2 measured on identical input could
#  never be attributed. Every render now appends one JSON line to a durable log
#  of its own, carrying the attempt count, the per-attempt duration and the
#  split between interpreter startup, document preparation and Edge itself.
#
#  Best effort throughout. Telemetry must never be able to fail a render, so
#  every part of it is wrapped and its failure is swallowed.
#
#  All of these MUST be assigned here: under Set-StrictMode, reading an
#  unassigned $script: variable throws, and the finally block at the end of the
#  script reads them on every exit path, including the failures.
# --------------------------------------------------------------------------
$script:T0                = [System.Diagnostics.Stopwatch]::StartNew()
$script:TelemetryDir      = Join-Path $env:LOCALAPPDATA 'TranscribeIt\render'
$script:TelemetryPath     = Join-Path $script:TelemetryDir 'render-timings.jsonl'
$script:TelemetryWritten  = $false
$script:Attempts          = [System.Collections.Generic.List[object]]::new()
$script:PwshStartupMs     = -1.0
$script:PrepMs            = -1.0
$script:SweepMs           = -1.0
$script:MoveMs            = -1.0
$script:PdfBytes          = -1
$script:TurnCount         = -1

# Interpreter startup + script parse: everything that happened before the first
# line of this script executed. The engine spawns a whole new pwsh for every
# render and docs/pipeline-optimisation.md 6 estimates ~1.2 s for it without
# ever having measured it. This is that measurement.
#
# Only meaningful when this pwsh was launched FOR this script, which is how the
# engine invokes it (-File Render-Pdf.ps1). When the script is called inside a
# host that was already running - Track B's own test harness does exactly that -
# the process start time is unrelated to this render and the number would
# silently grow all session. Detected from the process command line, which
# GetCommandLineArgs returns for free; asking CIM would cost more than the
# measurement is worth on a 2 s render.
try {
    $selfName = [System.IO.Path]::GetFileName($PSCommandPath)
    $launched = $false
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -and $a -like "*$selfName") { $launched = $true; break }
    }
    if ($launched) {
        $script:PwshStartupMs = [math]::Round(
            ([datetime]::UtcNow - (Get-Process -Id $PID).StartTime.ToUniversalTime()).TotalMilliseconds, 1)
    }
} catch { }

function Write-RenderTelemetry([int] $Code, [string] $Failure) {
    if ($script:TelemetryWritten) { return }
    $script:TelemetryWritten = $true
    try {
        $rec = [ordered]@{
            ts            = [datetime]::UtcNow.ToString('o')
            procId        = $PID
            exit          = $Code
            totalMs       = [math]::Round($script:T0.Elapsed.TotalMilliseconds, 1)
            pwshStartupMs = $script:PwshStartupMs
            prepMs        = $script:PrepMs
            sweepMs       = $script:SweepMs
            moveMs        = $script:MoveMs
            attemptCount  = $script:Attempts.Count
            attempts      = @($script:Attempts)
            turns         = $script:TurnCount
            bytes         = $script:PdfBytes
            failure       = $Failure
        }
        $line = ($rec | ConvertTo-Json -Depth 6 -Compress)
        New-Item -ItemType Directory -Force -Path $script:TelemetryDir | Out-Null
        # FileMode.Append seeks to the end on open, and FileShare.ReadWrite lets
        # a concurrent render append its own line rather than failing outright.
        $fs = [System.IO.File]::Open($script:TelemetryPath, [System.IO.FileMode]::Append,
                                     [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $buf = [System.Text.Encoding]::UTF8.GetBytes($line + "`n")
            $fs.Write($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
    } catch { }
}

# --------------------------------------------------------------------------
#  small helpers
# --------------------------------------------------------------------------

function Write-Step([string] $Message) {
    if (-not $Quiet) { Write-Host $Message }
}

# Write to stderr and exit. Deliberately does not use Write-Error, because
# $ErrorActionPreference = 'Stop' would turn that into a throw and lose the
# exit code we are trying to hand back to the caller.
function Fail([int] $Code, [string] $Message) {
    Write-RenderTelemetry $Code $Message
    [Console]::Error.WriteLine("Render-Pdf: $Message")
    exit $Code
}

# Does a PSCustomObject actually carry this property?
function Test-Prop($Object, [string] $Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [psobject]) { return $false }
    return [bool]($Object.PSObject.Properties.Name -contains $Name)
}

# Read a property with a fallback, tolerating absent members and JSON nulls.
function Get-Prop($Object, [string] $Name, $Default = $null) {
    if (-not (Test-Prop $Object $Name)) { return $Default }
    $v = $Object.$Name
    if ($null -eq $v) { return $Default }
    return $v
}

function Get-Num($Object, [string] $Name, [double] $Default = 0) {
    $v = Get-Prop $Object $Name $null
    if ($null -eq $v) { return $Default }
    try { return [double]$v } catch { return $Default }
}

# HTML text-node / attribute escaping. Ampersand first, always.
function Esc([string] $Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $s = $Text
    $s = $s.Replace('&', '&amp;')
    $s = $s.Replace('<', '&lt;')
    $s = $s.Replace('>', '&gt;')
    $s = $s.Replace('"', '&quot;')
    $s = $s.Replace("'", '&#39;')
    return $s
}

# Windows command-line quoting for a single argument. Doubles any run of
# backslashes that immediately precedes the closing quote, per CommandLineToArgvW.
function QuoteArg([string] $Argument) {
    if ($null -eq $Argument) { return '""' }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $Argument.Length) {
        $slashes = 0
        while ($i -lt $Argument.Length -and $Argument[$i] -eq '\') { $slashes++; $i++ }
        if ($i -eq $Argument.Length) { [void]$sb.Append('\' * ($slashes * 2)); break }
        if ($Argument[$i] -eq '"') {
            [void]$sb.Append('\' * ($slashes * 2 + 1)); [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $slashes); [void]$sb.Append($Argument[$i])
        }
        $i++
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Length of the file if it is a structurally complete PDF, otherwise 0.
# A PDF ends with the %%EOF trailer, so its presence means Edge has finished
# writing even if the process is still winding itself down. Opened with
# FileShare.ReadWrite because Edge may still hold the handle.
function Get-PdfCompleteLength([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read,
                                     [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -lt 64) { return 0L }
            $n = [int][math]::Min(2048, $len)
            [void]$fs.Seek(-$n, [System.IO.SeekOrigin]::End)
            $buf = New-Object byte[] $n
            [void]$fs.Read($buf, 0, $n)
            $tail = [System.Text.Encoding]::ASCII.GetString($buf)
            if ($tail -match '%%EOF\s*$') { return [long]$len }
            return 0L
        } finally { $fs.Dispose() }
    } catch { return 0L }
}

# End a process and its children. Chromium spawns a tree, and .NET's
# Kill($true) does not exist on the .NET Framework that PowerShell 5.1 uses,
# so taskkill (present on every Windows install) is the portable route.
function Stop-ProcessTree([int] $ProcessId) {
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskkill) {
        try {
            & $taskkill '/PID' ([string]$ProcessId) '/T' '/F' 2>&1 | Out-Null
            return
        } catch { }
    }
    try { (Get-Process -Id $ProcessId -ErrorAction Stop).Kill() } catch { }
}

# --------------------------------------------------------------------------
#  time formatting  (the contract hands us float seconds; display is our job)
# --------------------------------------------------------------------------

# Bracketed turn timestamp. $UseHours is decided once per document so the
# whole left-hand column stays a constant width and scans cleanly.
function Format-Stamp([double] $Seconds, [bool] $UseHours) {
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0) { $Seconds = 0 }
    $t = [int][math]::Floor($Seconds)
    $h = [int][math]::Floor($t / 3600)
    $m = [int][math]::Floor(($t % 3600) / 60)
    $s = [int]($t % 60)
    if ($UseHours) { return ('[{0}:{1:00}:{2:00}]' -f $h, $m, $s) }
    return ('[{0:00}:{1:00}]' -f ($h * 60 + $m), $s)
}

# --------------------------------------------------------------------------
#  speaker palette
#
#  Eight entries. Colour is only ever a *secondary* cue: the speaker label is
#  always printed verbatim, and every entry also has a distinct border
#  style/width pair so a greyscale print still separates the speakers.
# --------------------------------------------------------------------------
$Palette = @(
    @{ Colour = '#1f3a5f'; Style = 'solid';  Width = '3pt'   },  # navy
    @{ Colour = '#7a3b2e'; Style = 'dashed'; Width = '3pt'   },  # brick
    @{ Colour = '#2f5d4a'; Style = 'dotted'; Width = '3pt'   },  # forest
    @{ Colour = '#5c4a7a'; Style = 'double'; Width = '3.5pt' },  # plum
    @{ Colour = '#8a6d1f'; Style = 'solid';  Width = '1.2pt' },  # ochre
    @{ Colour = '#3d5a6c'; Style = 'dashed'; Width = '1.2pt' },  # slate
    @{ Colour = '#6b2f4a'; Style = 'dotted'; Width = '1.2pt' },  # maroon
    @{ Colour = '#4b5560'; Style = 'solid';  Width = '5pt'   }   # graphite
)

# --------------------------------------------------------------------------
#  locate Edge
# --------------------------------------------------------------------------
function Resolve-Edge([string] $Override) {
    if ($Override) {
        if (Test-Path -LiteralPath $Override -PathType Leaf) { return (Resolve-Path -LiteralPath $Override).Path }
        Fail 4 "Edge executable not found at the supplied -EdgePath: $Override"
    }
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles          'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA          'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { $_ -and $_ -notlike '\*' }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    $cmd = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ==========================================================================
#  1. validate inputs
# ==========================================================================

if (-not (Test-Path -LiteralPath $TurnsJson -PathType Leaf)) {
    Fail 2 "Transcript JSON not found: $TurnsJson"
}
$TurnsJson = (Resolve-Path -LiteralPath $TurnsJson).Path

if (-not $TemplatePath) { $TemplatePath = Join-Path $PSScriptRoot 'template.html' }
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
    Fail 2 "Template not found: $TemplatePath"
}
$TemplatePath = (Resolve-Path -LiteralPath $TemplatePath).Path

# Resolve OutputPdf to an absolute path without requiring it to exist yet.
try {
    if (-not [System.IO.Path]::IsPathRooted($OutputPdf)) {
        $OutputPdf = Join-Path (Get-Location).ProviderPath $OutputPdf
    }
    $OutputPdf = [System.IO.Path]::GetFullPath($OutputPdf)
} catch {
    Fail 2 "-OutputPdf is not a usable path: $OutputPdf"
}
$outDir = [System.IO.Path]::GetDirectoryName($OutputPdf)
if ([string]::IsNullOrEmpty($outDir)) { Fail 2 "-OutputPdf has no directory component: $OutputPdf" }
if (-not (Test-Path -LiteralPath $outDir)) {
    try { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    catch { Fail 6 "Could not create output directory: $outDir" }
}

$edge = Resolve-Edge $EdgePath
if (-not $edge) {
    Fail 4 ("Microsoft Edge was not found. Looked in Program Files (x86), Program Files, " +
            "LOCALAPPDATA and PATH. Pass -EdgePath to point at msedge.exe explicitly.")
}

# ==========================================================================
#  2. parse the transcript
# ==========================================================================

try {
    # ReadAllText with an explicit encoding still honours a byte-order mark,
    # so this copes with UTF-8 both with and without a BOM.
    $raw = [System.IO.File]::ReadAllText($TurnsJson, [System.Text.Encoding]::UTF8)
} catch {
    Fail 3 "Could not read transcript JSON: $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace($raw)) { Fail 3 "Transcript JSON is empty: $TurnsJson" }

try { $doc = $raw | ConvertFrom-Json } catch {
    Fail 3 "Transcript JSON is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $doc -or $doc -isnot [psobject]) { Fail 3 'Transcript JSON did not parse to an object.' }

$schemaVersion = Get-Num $doc 'schemaVersion' (-1)
if ($schemaVersion -ne 1) {
    if ($schemaVersion -lt 0) {
        Fail 3 'Transcript JSON has no schemaVersion. Expected schemaVersion 1.'
    }
    Write-Warning "Transcript declares schemaVersion $schemaVersion; this renderer targets version 1. Rendering anyway."
}

$source     = Get-Prop $doc 'source'
$processing = Get-Prop $doc 'processing'
if ($null -eq $source)     { Fail 3 'Transcript JSON is missing the required "source" object.' }
if ($null -eq $processing) { Fail 3 'Transcript JSON is missing the required "processing" object.' }

# Array normalisation. Two traps here, and both bite on real documents:
#   * ConvertFrom-Json yields $null for an absent array, and a bare object
#     rather than a one-element array for "speakers": [ { ... } ].
#   * a PowerShell function that returns an array has it unrolled by the
#     pipeline, so a helper cannot hand one back intact.
# Wrapping the read in @( ) at the point of use sidesteps both, and is the
# only form that gives a real array for the absent, single and many cases.
$speakers = @(Get-Prop $doc 'speakers' @())
$turns    = @(Get-Prop $doc 'turns'    @())
$warnings = @(Get-Prop $doc 'warnings' @())

$srcFileName = [string](Get-Prop $source 'fileName' '')
$srcPath     = [string](Get-Prop $source 'path' '')
if ([string]::IsNullOrWhiteSpace($srcFileName)) {
    if ($srcPath) { $srcFileName = [System.IO.Path]::GetFileName($srcPath) }
    if ([string]::IsNullOrWhiteSpace($srcFileName)) { $srcFileName = '(source filename unavailable)' }
}
$durationSeconds = Get-Num $source 'durationSeconds' 0

Write-Step "Transcript : $srcFileName"
Write-Step "Turns      : $($turns.Count)   Speakers: $($speakers.Count)   Warnings: $($warnings.Count)"

# ==========================================================================
#  3. build the HTML fragments
# ==========================================================================

# --- speaker -> palette slot. speakers[] is ordered by first appearance, so
#     the slot order matches the order the reader meets each voice. Any turn
#     referencing an id that is absent from speakers[] still gets a slot.
$slotOf = @{}
$next = 0
foreach ($sp in $speakers) {
    $id = [string](Get-Prop $sp 'id' '')
    if ($id -and -not $slotOf.ContainsKey($id)) { $slotOf[$id] = $next; $next++ }
}
foreach ($t in $turns) {
    $id = [string](Get-Prop $t 'speaker' '')
    if ($id -and -not $slotOf.ContainsKey($id)) { $slotOf[$id] = $next; $next++ }
}

# --- label-free mode. A document whose turns print ONE distinct label gains
#     nothing from repeating it, so the label element, the per-speaker rule and
#     the attribution-uncertainty marks (uncertainty is only meaningful against
#     other speakers) are all omitted: timestamps and text only (user decision
#     2026-08-27). Keyed on the turns data, never on how the pipeline was
#     invoked, so a diarized solo recording that detected one speaker gets the
#     same treatment as -NoDiarization. Distinctness is counted on the same
#     effective label the body loop prints, because the printed text is what
#     carries (or fails to carry) the information.
$distinctLabels = @{}
foreach ($t in $turns) {
    $id  = [string](Get-Prop $t 'speaker' '')
    $lab = [string](Get-Prop $t 'speakerLabel' '')
    if ([string]::IsNullOrWhiteSpace($lab)) { $lab = if ($id) { $id } else { 'Unattributed' } }
    $distinctLabels[$lab] = $true
}
$labelFree = ($distinctLabels.Count -le 1)
if ($labelFree -and $turns.Count -gt 0) {
    Write-Step 'Labels     : one distinct speaker - labels omitted from the document'
}

$sbCss = New-Object System.Text.StringBuilder
if ($labelFree) {
    # @@SPEAKER_CSS@@ must be filled on EVERY path - the leftover-placeholder
    # check fails the render otherwise. Same specificity as the template's
    # base .turn > .col rule and later in the sheet, so it wins: no left rule,
    # no per-speaker colour, and the text column closes up to the grid edge.
    [void]$sbCss.AppendLine('.turn > .col { border-left: none; padding-left: 0; }')
} else {
    for ($i = 0; $i -lt [math]::Max($next, 1); $i++) {
        $p = $Palette[$i % $Palette.Count]
        [void]$sbCss.AppendLine((".s{0} > .col {{ border-left-color: {1}; border-left-style: {2}; border-left-width: {3}; }}" -f $i, $p.Colour, $p.Style, $p.Width))
        [void]$sbCss.AppendLine((".s{0} .lab    {{ color: {1}; }}" -f $i, $p.Colour))
    }
}
$speakerCss = $sbCss.ToString().TrimEnd()

# --- one timestamp format for the whole document, chosen from the longest
#     time we will actually print.
$maxSeconds = $durationSeconds
foreach ($t in $turns) {
    $e = Get-Num $t 'end' 0
    $s = Get-Num $t 'start' 0
    if ($e -gt $maxSeconds) { $maxSeconds = $e }
    if ($s -gt $maxSeconds) { $maxSeconds = $s }
}
$useHours = ($maxSeconds -ge 3600)

# --- language, only for the html lang attribute. Everything else that used
#     to be read out of processing[] and speakers[] for the front matter
#     (model, dates, elapsed time, speaker statistics) is no longer rendered:
#     the PDF carries the transcript and nothing else.
$language = [string](Get-Prop $processing 'language' '')
if (-not $language) { $language = 'en' }

# --- transcript body
$uncertainCount = 0
$sbBody = New-Object System.Text.StringBuilder

if ($turns.Count -eq 0) {
    [void]$sbBody.AppendLine('  <div class="empty">')
    [void]$sbBody.AppendLine('    <strong>No speech was transcribed from this recording.</strong>')
    [void]$sbBody.AppendLine('    <span>The file was processed successfully but produced no transcribable turns. This usually means the audio track is silent, contains only noise, or is absent.</span>')
    [void]$sbBody.AppendLine('  </div>')
} else {
    foreach ($t in $turns) {
        $id    = [string](Get-Prop $t 'speaker' '')
        $slot  = if ($id -and $slotOf.ContainsKey($id)) { $slotOf[$id] } else { 0 }

        # speakerLabel is display-ready and is printed verbatim - never derived.
        $label = [string](Get-Prop $t 'speakerLabel' '')
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = if ($id) { $id } else { 'Unattributed' }
        }

        $start = Get-Num $t 'start' 0
        $text  = [string](Get-Prop $t 'text' '')

        # In label-free mode the tint and dagger are dropped with the label:
        # they flag doubt about WHICH speaker, and there is only one.
        $unc = Get-Prop $t 'speakerUncertain' $false
        $isUnc = ($unc -is [bool] -and $unc -and -not $labelFree)
        if ($isUnc) { $uncertainCount++ }

        # Very long turns are allowed to break across pages - refusing would
        # leave a page mostly blank. The label is still glued to its first line
        # by break-after:avoid on .lab.
        $classes = @("turn")
        if (-not $labelFree)      { $classes += "s$slot" }
        if ($text.Length -gt 900) { $classes += 'long' }
        if ($isUnc)               { $classes += 'unc' }

        # Break a genuinely long monologue into paragraphs at sentence
        # boundaries. Purely typographic - not one character of text changes.
        $paras = @()
        if ($text.Length -gt 700) {
            $sentences = [regex]::Split($text, '(?<=[.!?][")\u2019\u201D]?)\s+')
            $buf = ''
            foreach ($sn in $sentences) {
                if ([string]::IsNullOrWhiteSpace($sn)) { continue }
                if ($buf.Length -eq 0) { $buf = $sn } else { $buf = "$buf $sn" }
                if ($buf.Length -ge 420) { $paras += $buf; $buf = '' }
            }
            if ($buf.Length -gt 0) {
                if ($paras.Count -gt 0 -and $buf.Length -lt 120) { $paras[$paras.Count - 1] = $paras[$paras.Count - 1] + ' ' + $buf }
                else { $paras += $buf }
            }
        }
        if ($paras.Count -eq 0) { $paras = @($text) }

        $dagger = if ($isUnc) { '<sup class="dag" title="speaker attribution uncertain">&#8224;</sup>' } else { '' }

        [void]$sbBody.AppendLine(('  <article class="{0}">' -f ($classes -join ' ')))
        [void]$sbBody.AppendLine(('    <div class="ts">{0}</div>' -f (Esc (Format-Stamp $start $useHours))))
        [void]$sbBody.AppendLine('    <div class="col">')
        if (-not $labelFree) {
            [void]$sbBody.AppendLine(('      <div class="lab">{0}{1}</div>' -f (Esc $label), $dagger))
        }
        [void]$sbBody.AppendLine('      <div class="txt">')
        foreach ($p in $paras) {
            $body = Esc $p
            if ([string]::IsNullOrWhiteSpace($body)) { $body = '<em>[no text for this turn]</em>' }
            [void]$sbBody.AppendLine(('        <p>{0}</p>' -f $body))
        }
        [void]$sbBody.AppendLine('      </div>')
        [void]$sbBody.AppendLine('    </div>')
        [void]$sbBody.AppendLine('  </article>')
    }
}
$bodyHtml = $sbBody.ToString().TrimEnd()

# Surfaced on the console, not in the document: the reader sees only the dagger.
if ($uncertainCount -gt 0) { Write-Step "Uncertain  : $uncertainCount turn(s) marked with a dagger" }
if ($warnings.Count -gt 0) {
    Write-Step "Warnings   : $($warnings.Count) present in the JSON, not rendered into the PDF by design"
}

# The dagger on an uncertain turn is deliberately left unexplained in the
# document: Diego asked for the marker to stay but for no legend or footnote
# anywhere (decision 2026-08-26). The count is reported on the console instead.
$langAttr = 'en'
if ($language -match '^[A-Za-z][A-Za-z0-9-]{0,34}$') { $langAttr = $language }

# ==========================================================================
#  4. fill the template
# ==========================================================================

try { $tpl = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.Encoding]::UTF8) }
catch { Fail 2 "Could not read template: $($_.Exception.Message)" }

$docTitle = "Transcript - $srcFileName"

$replacements = [ordered]@{
    '@@LANG_ATTR@@'   = (Esc $langAttr)
    '@@DOC_TITLE@@'   = (Esc $docTitle)
    '@@SPEAKER_CSS@@' = $speakerCss
    '@@BODY@@'        = $bodyHtml
}
foreach ($k in $replacements.Keys) { $tpl = $tpl.Replace($k, [string]$replacements[$k]) }

$leftover = [regex]::Matches($tpl, '@@[A-Z_]+@@')
if ($leftover.Count -gt 0) {
    $names = ($leftover | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '
    Fail 3 "Template contains placeholders this renderer does not fill: $names"
}

# ==========================================================================
#  5. print via headless Edge
# ==========================================================================

# Everything Edge touches lives under one throwaway directory: the staged
# HTML, the staged PDF, and the isolated browser profile. Staging the output
# with an ASCII name also keeps awkward characters out of the command line.
# --- shared render profile: initialised once, see the attempt loop ---
# All five MUST be assigned before the try/finally below: under Set-StrictMode,
# reading an unassigned $script: variable throws, and the finally block touches
# SharedProfileLock on every exit path - including failures.
$script:SharedProfileRoot        = Join-Path $env:LOCALAPPDATA 'TranscribeIt\render'
$script:SharedProfileDir         = Join-Path $script:SharedProfileRoot 'edge-profile'
$script:SharedProfileLockPath    = Join-Path $script:SharedProfileRoot 'profile.lock'
$script:SharedProfileLock        = $null
$script:SharedProfileUnavailable = $false

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('TranscribeIt-render-' + [guid]::NewGuid().ToString('N'))

# Self-healing sweep.
#
# After a force-killed Edge, Windows releases its handles on the browser
# profile asynchronously and takes longer than it is worth making every render
# wait for. So rather than blocking on cleanup, each run clears the debris left
# by earlier ones. The cutoff is derived from this run's own worst-case
# lifetime, so a directory older than that cannot belong to a render still in
# flight - which keeps this safe if the engine ever renders two files at once.
# Best effort only: never allowed to affect this render.
$sweepCutoffSeconds = [math]::Max(600, $MaxAttempts * $TimeoutSeconds * 2)
$sweepSw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $cutoff = [datetime]::UtcNow.AddSeconds(-$sweepCutoffSeconds)
    $stale = Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory `
                           -Filter 'TranscribeIt-render-*' -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTimeUtc -lt $cutoff }
    $swept = 0
    foreach ($s in @($stale)) {
        try { Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction Stop; $swept++ }
        catch { }
    }
    if ($swept -gt 0) { Write-Verbose "Swept $swept stale render temp director(ies) from earlier runs." }
} catch { }
$sweepSw.Stop()
$script:SweepMs   = [math]::Round($sweepSw.Elapsed.TotalMilliseconds, 1)
$script:TurnCount = $turns.Count
$stagedHtml = Join-Path $tempRoot 'transcript.html'

try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    try {
        # UTF-8 with BOM: the strongest possible signal to the renderer, so
        # accented names and curly quotes survive regardless of locale.
        [System.IO.File]::WriteAllText($stagedHtml, $tpl, (New-Object System.Text.UTF8Encoding($true)))
    } catch { Fail 6 "Could not write intermediate HTML: $($_.Exception.Message)" }

    $uri = (New-Object System.Uri $stagedHtml).AbsoluteUri

  # Headless Edge occasionally just stalls on this machine - observed once in
  # ~25 renders, on a heavily loaded box, where a one-page print had not
  # appeared after 180s while the same input rendered in 9s moments later.
  # A stall is not worth failing a user's transcript over, so each attempt
  # gets a completely fresh profile and staged output.
  $stagedPdf = $null
  $lastFailure = ''
  # Everything up to here - argument validation, JSON parse, HTML build, sweep -
  # is preparation. Recorded separately so a slow render can be attributed to
  # document size rather than to Edge.
  $script:PrepMs = [math]::Round($script:T0.Elapsed.TotalMilliseconds, 1)
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $attemptPdf = Join-Path $tempRoot ("transcript-$attempt.pdf")
    $attemptSw  = [System.Diagnostics.Stopwatch]::StartNew()
    $attemptRec = [ordered]@{
        n = $attempt; profile = 'throwaway'; ms = -1.0; spawnMs = -1.0
        pdfFirstMs = -1.0; pdfDoneMs = -1.0; killMs = -1.0
        selfExit = $false; pdfComplete = $false; rescuedAtExit = $false; outcome = 'unknown'
    }

    # Browser profile: reuse a persistent one on the first attempt, fall back to a
    # throwaway afterwards.
    #
    # Why: Track B2 measured this stage swinging 11.2 -> 94.7 s on IDENTICAL input,
    # an 8.5x spread larger than every saving that track made. A brand-new
    # --user-data-dir forces Chromium to build a profile from scratch every render -
    # create the directory tree, initialise preferences, and on a managed machine
    # apply enterprise policy - none of which is work we need done more than once.
    #
    # Isolation is unchanged. This profile lives under our own install-local folder,
    # is never the user's real Edge profile, and is never shared with their browser.
    #
    # Two safety properties matter here:
    #   1. A poisoned profile must not wedge us permanently, so attempt 2+ always
    #      uses a fresh throwaway - the original self-healing behaviour.
    #   2. Chromium single-instance-locks a profile directory, so two concurrent
    #      renders must not share it. We take an exclusive lock file; whoever loses
    #      silently uses a throwaway and is no worse off than before this change.
    $useShared = ($attempt -eq 1) -and (-not $script:SharedProfileUnavailable)
    if ($useShared -and $null -eq $script:SharedProfileLock) {
        try {
            New-Item -ItemType Directory -Force -Path $script:SharedProfileRoot | Out-Null
            $script:SharedProfileLock = [System.IO.File]::Open(
                $script:SharedProfileLockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch {
            # Another render holds it, or the folder is not writable.
            $script:SharedProfileUnavailable = $true
            $useShared = $false
            Write-Verbose "Shared render profile unavailable ($($_.Exception.Message)); using a throwaway profile."
        }
    }

    if ($useShared) {
        $userData = $script:SharedProfileDir
        $attemptRec['profile'] = 'shared'
        Write-Verbose "Using persistent render profile: $userData"
    } else {
        $userData = Join-Path $tempRoot ("edge-profile-$attempt")
    }
    New-Item -ItemType Directory -Force -Path $userData | Out-Null
    if ($attempt -gt 1) {
        Write-Step "Retrying   : attempt $attempt of $MaxAttempts ($lastFailure)"
    }

    $edgeArgs = @(
        '--headless=new'
        '--disable-gpu'
        '--no-first-run'
        '--no-default-browser-check'
        '--no-service-autorun'
        '--disable-default-apps'
        '--disable-sync'
        '--disable-extensions'
        '--disable-background-networking'
        '--disable-component-update'
        '--disable-domain-reliability'
        '--disable-client-side-phishing-detection'
        '--safebrowsing-disable-auto-update'
        '--metrics-recording-only'
        '--disable-breakpad'
        '--disable-features=Translate,OptimizationHints,MediaRouter,InterestFeedContentSuggestions'
        '--no-pdf-header-footer'
        "--user-data-dir=$userData"
        "--print-to-pdf=$attemptPdf"
        $uri
    )
    $cmdLine = ($edgeArgs | ForEach-Object { QuoteArg $_ }) -join ' '

    $stdOutFile = Join-Path $tempRoot "edge-stdout-$attempt.log"
    $stdErrFile = Join-Path $tempRoot "edge-stderr-$attempt.log"

    Write-Step "Printing   : headless Edge -> PDF"
    $spawnSw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $edge -ArgumentList $cmdLine -PassThru -NoNewWindow `
                          -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile
    $spawnSw.Stop()
    $attemptRec['spawnMs'] = [math]::Round($spawnSw.Elapsed.TotalMilliseconds, 1)
    $edgeSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Wait on the ARTEFACT, not on the process.
    #
    # On this managed machine Edge writes the finished PDF in 7-22s but then
    # spends a further 30-120s on its own teardown (measured; highly variable,
    # and worse under PowerShell 5.1). Waiting for the process to exit made a
    # two-page render take up to 145s, which would blow the render stage's
    # share of the progress budget for no benefit whatsoever.
    #
    # A PDF whose tail carries the %%EOF trailer is structurally complete, so
    # once we see that - stable across two polls - the job is genuinely done.
    $deadline  = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $pdfDone   = $false
    $selfExit  = $false
    $lastLen   = -1L
    $stable    = 0

    $firstSeenMs = -1.0
    $rescued     = $false

    while ([datetime]::UtcNow -lt $deadline) {
        $len = Get-PdfCompleteLength $attemptPdf
        if ($len -gt 0) {
            if ($firstSeenMs -lt 0) { $firstSeenMs = [math]::Round($edgeSw.Elapsed.TotalMilliseconds, 1) }
            if ($len -eq $lastLen) { $stable++ } else { $stable = 0; $lastLen = $len }
            if ($stable -ge 1) { $pdfDone = $true; break }
        }
        if ($proc.HasExited) {
            # Edge can flush the %%EOF trailer and exit inside the same 150 ms
            # window, and the loop above wants the length STABLE across two
            # polls before it will trust it. That combination used to throw a
            # finished document away: the first poll saw a complete PDF, the
            # process-exit check fired 2 ms later, and the attempt was recorded
            # as "PDF was left incomplete" - which then cost a FULL RETRY, i.e.
            # a doubled render stage. Measured in the wild: 1 render in 80 on an
            # idle machine, and the doubling is the mechanism behind the 77.2 s
            # and 94.7 s readings in docs/pipeline-optimisation.md 4.3.
            #
            # This block used to take a single reading here and break, on the
            # reasoning that "once Edge has exited it cannot append another
            # byte". THAT REASONING IS FALSE, and it took every render on this
            # machine down on 2026-08-27: the process we launch is a LAUNCHER
            # which hands the job to a detached child and exits, so the writer
            # outlives the process we are waiting on. Measured with Edge
            # 151.0.4129.107 on the real render HTML: launcher exited at 393 ms,
            # the PDF appeared at 2466 ms and completed at 2504 ms - a 2.1 s gap
            # in which the old code declared "no PDF produced, Edge exit 0",
            # burned both attempts, and failed a render whose PDF was on disk
            # moments later.
            #
            # So process exit demotes to a HINT: keep polling the artefact for a
            # bounded grace period. Costs nothing when the PDF is already
            # complete - the first reading breaks out.
            $selfExit = $true
            $graceDeadline = [datetime]::UtcNow.AddSeconds($PostExitGraceSeconds)
            if ($graceDeadline -gt $deadline) { $graceDeadline = $deadline }
            $graceSw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                $len = Get-PdfCompleteLength $attemptPdf
                if ($len -gt 0) {
                    if ($firstSeenMs -lt 0) { $firstSeenMs = [math]::Round($edgeSw.Elapsed.TotalMilliseconds, 1) }
                    $pdfDone  = $true
                    $rescued  = $true
                    break
                }
                if ([datetime]::UtcNow -ge $graceDeadline) { break }
                Start-Sleep -Milliseconds 150
            }
            $graceSw.Stop()
            $attemptRec['postExitWaitMs'] = [math]::Round($graceSw.Elapsed.TotalMilliseconds, 1)
            break
        }
        Start-Sleep -Milliseconds 150
    }

    $attemptRec['rescuedAtExit'] = [bool]$rescued
    $attemptRec['pdfFirstMs']  = $firstSeenMs
    $attemptRec['pdfDoneMs']   = [math]::Round($edgeSw.Elapsed.TotalMilliseconds, 1)
    $attemptRec['selfExit']    = [bool]$selfExit
    $attemptRec['pdfComplete'] = [bool]$pdfDone

    # This Edge instance is entirely ours - isolated --user-data-dir inside our
    # own temp directory - so ending it cannot disturb the user's browser or
    # profile. Give it a moment to leave of its own accord first.
    $killSw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $proc.HasExited) {
        if ($pdfDone) { Start-Sleep -Milliseconds 300 }
        if (-not $proc.HasExited) {
            Write-Verbose 'PDF complete; ending the isolated Edge instance rather than waiting out its teardown.'
            Stop-ProcessTree $proc.Id
        }
    }
    $killSw.Stop()
    $attemptRec['killMs'] = [math]::Round($killSw.Elapsed.TotalMilliseconds, 1)

    # ExitCode is not reliably populated by Start-Process -PassThru on
    # PowerShell 5.1, so it is only ever used for diagnostics.
    $edgeExit = 'n/a'
    try { if ($proc.HasExited) { $edgeExit = [string]$proc.ExitCode } } catch { }

    $edgeStdErr = ''
    if (Test-Path -LiteralPath $stdErrFile) { $edgeStdErr = (Get-Content -LiteralPath $stdErrFile -Raw -ErrorAction SilentlyContinue) }
    if ($null -eq $edgeStdErr) { $edgeStdErr = '' }
    Write-Verbose "Edge exit code: $edgeExit (self-exited: $selfExit, pdf complete: $pdfDone)"
    if ($edgeStdErr) { Write-Verbose "Edge stderr:`n$edgeStdErr" }

    # Decide whether this attempt gave us a usable document. A policy block is
    # not transient, so that one fails immediately rather than retrying.
    if ($edgeStdErr -match 'not allowed|disabled by policy|Printing is disabled') {
        Fail 5 ("Headless Edge refused to print: it reported a policy restriction, so --print-to-pdf " +
                "appears to be blocked by enterprise policy on this machine. Edge stderr:`n$edgeStdErr")
    }

    if (-not (Test-Path -LiteralPath $attemptPdf)) {
        $lastFailure = "no PDF produced, Edge exit $edgeExit"
        if (-not $selfExit -and -not $pdfDone) { $lastFailure = "Edge stalled for ${TimeoutSeconds}s without producing a PDF" }
    } elseif (-not $pdfDone) {
        $lastFailure = 'PDF was left incomplete (no %%EOF trailer)'
    } elseif ((Get-Item -LiteralPath $attemptPdf).Length -lt 1000) {
        $lastFailure = "PDF was only $((Get-Item -LiteralPath $attemptPdf).Length) bytes"
    } else {
        # Confirm it really is a PDF before overwriting anything the user has.
        $sigText = ''
        try {
            $fs = [System.IO.File]::OpenRead($attemptPdf)
            try {
                $sig = New-Object byte[] 5
                [void]$fs.Read($sig, 0, 5)
                $sigText = [System.Text.Encoding]::ASCII.GetString($sig)
            } finally { $fs.Dispose() }
        } catch { $sigText = '' }

        if ($sigText -ne '%PDF-') {
            $lastFailure = "output was not a PDF (header '$sigText')"
        } else {
            $stagedPdf = $attemptPdf          # success
        }
    }

    # Close the record before leaving the loop, so a successful attempt is
    # logged on exactly the same terms as a failed one. Without this a retry is
    # indistinguishable from a slow render, which is the whole problem.
    if ($stagedPdf) { $attemptRec['outcome'] = 'ok' } else { $attemptRec['outcome'] = $lastFailure }
    $attemptSw.Stop()
    $attemptRec['ms'] = [math]::Round($attemptSw.Elapsed.TotalMilliseconds, 1)
    [void]$script:Attempts.Add([pscustomobject]$attemptRec)

    if ($stagedPdf) { break }

    Write-Verbose "Attempt $attempt failed: $lastFailure"
  }

  if (-not $stagedPdf) {
      Fail 5 ("Headless Edge did not produce a usable PDF after $MaxAttempts attempt(s). " +
              "Last failure: $lastFailure. Re-run with -KeepTemp -Verbose to inspect $tempRoot.")
  }

    # Retry briefly: we may have just ended the Edge process that owned the
    # file handle, and Windows releases those asynchronously.
    $moveError = $null
    $moveSw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            if (Test-Path -LiteralPath $OutputPdf) { [System.IO.File]::Delete($OutputPdf) }
            [System.IO.File]::Move($stagedPdf, $OutputPdf)
            $moveError = $null
            break
        } catch {
            $moveError = $_.Exception.Message
            Start-Sleep -Milliseconds 200
        }
    }
    $moveSw.Stop()
    $script:MoveMs = [math]::Round($moveSw.Elapsed.TotalMilliseconds, 1)
    if ($moveError) {
        Fail 6 "Could not move the rendered PDF to '$OutputPdf': $moveError"
    }

    if ($KeepHtml) {
        $sidecar = [System.IO.Path]::ChangeExtension($OutputPdf, '.html')
        try { [System.IO.File]::Copy($stagedHtml, $sidecar, $true) }
        catch { Write-Warning "Could not write the HTML sidecar: $($_.Exception.Message)" }
    }

    $finalLen = (Get-Item -LiteralPath $OutputPdf).Length
    $script:PdfBytes = [int]$finalLen
    Write-Step ("Wrote      : {0}  ({1:N0} bytes)" -f $OutputPdf, $finalLen)
    if ($script:Attempts.Count -gt 1) {
        # Say it out loud too. This is the line whose absence made a retry look
        # like nothing more than a slow machine.
        Write-Step ("Retried    : {0} attempt(s) used" -f $script:Attempts.Count)
    }
    $script:ExitCode = 0
}
finally {
    # Release the shared-profile lock so a queued render can take it. The profile
    # directory itself is deliberately left behind - that is the entire point.
    if ($null -ne $script:SharedProfileLock) {
        try { $script:SharedProfileLock.Dispose() } catch { }
        $script:SharedProfileLock = $null
    }

    if ($KeepTemp) {
        Write-Host "Temp kept  : $tempRoot"
    } elseif (Test-Path -LiteralPath $tempRoot) {
        # A short, cheap try. The force-killed Edge often still holds handles on
        # its profile for longer than this, and making the user wait for that
        # would be a poor trade - so if it does not go quickly we leave it for
        # the next run's sweep rather than padding out every single render.
        for ($i = 0; $i -lt 6; $i++) {
            try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 250 }
        }
        if (Test-Path -LiteralPath $tempRoot) {
            Write-Verbose "Leaving $tempRoot for the next run's sweep; Edge still holds handles on it."
        }
    }

    # Last thing in the block, so totalMs covers the temp cleanup as well - the
    # engine pays for that too. A Fail path has already written its own record
    # and Write-RenderTelemetry is idempotent, so this is a no-op there.
    Write-RenderTelemetry $script:ExitCode ''
}

exit $script:ExitCode
