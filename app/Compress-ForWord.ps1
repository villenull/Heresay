<#
.SYNOPSIS
    "Send to -> Compress for Word transcription" - strips any audio/video file down to a
    compact mono MP3 that fits comfortably under Word for the web's ~300 MB upload limit.

.DESCRIPTION
    Diego transcribes with Word for the web, which works well, but two things get in the
    way: video files above ~300 MB are rejected outright, so they have to be converted by
    hand first; and the whole flow is a lot of clicking.

    This removes the conversion step. Point it at anything ffmpeg can read - .mp4 from a
    phone, .mov, .mkv, .m4a, .wav - and it produces "<name> (for Word).mp3" beside the
    original, ready to upload.

    Sizing: speech is intelligible far below music bitrates, and Word's transcription
    accuracy does not benefit from a fat file. 64 kbps mono at 22.05 kHz is generous for
    voice and yields ~28.8 MB per hour, so a recording would have to run past nine hours
    before it threatened the limit. If one ever does, the bitrate is reduced to fit
    (floor 24 kbps) rather than failing.

    A file that is ALREADY an accepted format and already small enough is left alone -
    re-encoding it would only lose quality for no reason.

.PARAMETER Paths
    Files to convert. Explorer's Send To passes every selected item as a separate
    argument, so this collects them all.

.PARAMETER TargetMB
    Size ceiling to aim under. Default 280, leaving headroom below Word's ~300 MB.

.PARAMETER MaxKbps
    Upper bitrate. Default 64, which is already generous for speech.

.PARAMETER OpenWord
    After converting, open a new Word for the web document in the default browser, so the
    only remaining steps are the upload itself. Off by default so the script never
    launches a browser unless asked; the Send To shortcut passes it.

.NOTES
    PositionalBinding = $false is load-bearing, exactly as in SendTo-Heresay.ps1: with
    default binding, a named parameter silently captures the FIRST selected file and drops
    it from $Paths. That was found by probing, and it is invisible data loss.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]    $TargetMB = 280,
    [int]    $MaxKbps  = 64,
    [switch] $OpenWord,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Paths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Initialise before use - Set-StrictMode throws on unassigned $script: variables, and
# this codebase has been bitten by that five times.
$script:Converted = New-Object System.Collections.Generic.List[string]
$script:Failed    = New-Object System.Collections.Generic.List[string]

$installRoot = Split-Path -Parent $PSScriptRoot
$ffmpeg      = Join-Path $installRoot 'bin\ffmpeg\ffmpeg.exe'
$ffprobe     = Join-Path $installRoot 'bin\ffmpeg\ffprobe.exe'
$logDir      = Join-Path $installRoot 'logs'
$log         = Join-Path $logDir 'compress-for-word.log'

# Leave a file alone ONLY if it is already compressed audio and already small. Word also
# accepts .wav and .mp4, but both are worth converting anyway: .wav is uncompressed, and
# stripping the video track off an .mp4 turns a 250 MB upload into ~27 MB, which is a 10x
# faster upload even when Word would have taken the original.
$skipIfSmall = @('.mp3', '.m4a')

function Write-CfwLog([string] $Message) {
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -LiteralPath $log -Value ('{0} [ForWord] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    } catch { }
}

function Show-Message([string] $Text, [string] $Icon = 'Information') {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [System.Windows.Forms.MessageBox]::Show($Text, 'Compress for Word', 'OK', $Icon) | Out-Null
}

foreach ($tool in @($ffmpeg, $ffprobe)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        Write-CfwLog "missing tool: $tool"
        Show-Message "Heresay is not installed correctly - missing:`n`n$tool" 'Error'
        exit 1
    }
}

$files = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
if (-not $files.Count) {
    Show-Message 'Select one or more audio or video files, then use Send to > Compress for Word.'
    exit 2
}

Write-CfwLog ("invoked with {0} file(s)" -f $files.Count)

foreach ($f in $files) {
    $src  = (Resolve-Path -LiteralPath $f).ProviderPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $dir  = Split-Path -Parent $src
    $ext  = [System.IO.Path]::GetExtension($src).ToLowerInvariant()
    $srcMB = [math]::Round((Get-Item -LiteralPath $src).Length / 1MB, 1)

    # Already fine as-is? Don't re-encode for the sake of it.
    if (($skipIfSmall -contains $ext) -and ($srcMB -lt $TargetMB)) {
        Write-CfwLog "skipped (already Word-ready, $srcMB MB): $src"
        $script:Converted.Add($src)
        continue
    }

    try {
        $durRaw = & $ffprobe -v error -show_entries format=duration -of csv=p=0 -- $src 2>&1
        $duration = 0.0
        [void][double]::TryParse(($durRaw | Select-Object -First 1), [ref]$duration)
        if ($duration -le 0) { throw 'could not read a duration (no audio track, or unreadable file)' }

        # Pick the bitrate: generous for speech, but stepped down if the recording is long
        # enough that MaxKbps would breach the ceiling.
        $kbps = $MaxKbps
        $fitKbps = [int][math]::Floor(($TargetMB * 1024 * 8) / $duration)
        if ($fitKbps -lt $kbps) { $kbps = [math]::Max(24, $fitKbps) }

        $out = Join-Path $dir ("$name (for Word).mp3")
        Write-CfwLog ("converting {0} ({1} MB, {2:N0}s) at {3} kbps -> {4}" -f (Split-Path -Leaf $src), $srcMB, $duration, $kbps, (Split-Path -Leaf $out))

        # -vn drops any video stream; mono at 22.05 kHz is plenty for speech.
        $null = & $ffmpeg -y -loglevel error -i $src -vn -ac 1 -ar 22050 -b:a "${kbps}k" -- $out 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw "ffmpeg failed (exit $LASTEXITCODE)" }

        $outMB = [math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)
        if ($outMB -ge $TargetMB) {
            Write-CfwLog "WARNING: output is $outMB MB, still at or above the ${TargetMB} MB target"
        }
        Write-CfwLog ("done: {0} MB -> {1} MB" -f $srcMB, $outMB)
        $script:Converted.Add($out)
    }
    catch {
        Write-CfwLog "FAILED '$src': $($_.Exception.Message)"
        $script:Failed.Add("$(Split-Path -Leaf $src): $($_.Exception.Message)")
    }
}

# Put the results on the clipboard so the Word upload dialog can be filled by pasting the
# path instead of navigating to it.
if ($script:Converted.Count) {
    try { Set-Clipboard -Value ($script:Converted -join [Environment]::NewLine) } catch { }
}

if ($OpenWord -and $script:Converted.Count) {
    # A blank Word for the web document, ready for Home > Dictate > Transcribe.
    try { Start-Process 'https://word.new' } catch { Write-CfwLog "could not open Word: $($_.Exception.Message)" }
}

# Deliberately SILENT on success. A modal dialog is a click, and removing clicks is the
# entire point of this script - an early version blocked for 61 s waiting to be dismissed.
# The completion signals are the browser opening and the file appearing beside the source.
# Failures still interrupt, because a silent failure would leave the user waiting for a
# file that is never coming.
if ($script:Failed.Count) {
    $summary = "Could not convert:`n" + ($script:Failed -join "`n")
    if ($script:Converted.Count) {
        $ok = $script:Converted | ForEach-Object { Split-Path -Leaf $_ }
        $summary += "`n`nDid convert:`n" + ($ok -join "`n")
    }
    $summary += "`n`nLog: $log"
    Show-Message $summary 'Warning'
}

exit $(if ($script:Failed.Count) { 1 } else { 0 })
