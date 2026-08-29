#requires -Version 7
<#
.SYNOPSIS
  TranscribeIt engine entry point. Turns an audio/video file into a speaker-
  separated transcript, 100% locally, and hands off to the PDF renderer.

.DESCRIPTION
  Track A owns this file; Track B2 owns the concurrency and the stage timing.
  Pipeline:

    ffprobe     -> duration, container, codec
    ffmpeg      -> 16 kHz mono 16-bit PCM WAV
                     |
            +--------+--------+
            |                 |
    whisper.cpp         sherpa-onnx        <- these two run CONCURRENTLY
    (transcript,        (speaker segments)
     token timings)          |
            |                 |
            +--------+--------+
                     |
    merge       -> contracts/turns.schema.json document
    render      -> PDF (Track B)

  whisper and sherpa consume only the WAV and neither reads the other's output,
  so the diarizer is launched as soon as the WAV exists and collected after
  transcription. That takes its whole wall clock off the critical path - 8 s on a
  short clip, 31-61 s on a long one.

  Per-stage wall clock is written to the LOG as "STAGE <name> = <seconds>" and
  summarised as one "STAGES {...}" line per item. It never goes to stdout.

  stdout is RESERVED for the JSON Lines progress contract
  (contracts/progress.schema.json). Nothing else may be written there. Human
  diagnostics go to the log file and to stderr.

  Every intermediate file lives under %TEMP%. The source file's folder only
  ever gains the final PDF. If rendering fails after a successful
  transcription, the transcript is preserved under %LOCALAPPDATA% rather than
  thrown away, and the error message says where.

.PARAMETER Path
  One or more media files. Accepts spaces and non-ASCII names.

.PARAMETER Speakers
  Known speaker count. When supplied the diarizer is pinned to exactly this
  many clusters; otherwise it auto-detects with a distance threshold.

.PARAMETER CancelSignalFile
  Cooperative cancellation. When this file appears the engine stops the current
  child process, reports stage 'cancelled' and exits cleanly.

.EXAMPLE
  ./Transcribe.ps1 -Path 'C:\Recordings\Weekly steerco 2026-08-19.mp4'

.EXAMPLE
  ./Transcribe.ps1 -Path a.m4a,b.mkv -Speakers 3 -Model ggml-small-q5_1.bin
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)][string[]]$Path,
  # A Windows shell verb hands multiple selected files over as separate argv
  # entries, not as one comma-joined value, so accept both -Path a,b and
  # -Path a b rather than making Track C reshape the command line.
  [Parameter(ValueFromRemainingArguments)][string[]]$AdditionalPaths,
  [ValidateRange(0, 20)][int]$Speakers = 0,
  [string]$Model,
  [string]$Language,
  [ValidateRange(0, 128)][int]$Threads = 0,
  [switch]$KeepIntermediate,
  [string]$ConfigPath,
  [string]$OutputDirectory,
  [string]$CancelSignalFile,
  [switch]$NoRender,
  # Skip speaker separation entirely. For a solo recording - a dictated note, a phone
  # memo with one voice - diarization is pure cost: it is the stage that now bounds the
  # pipeline, and there are no speakers to tell apart. Overrides diarization.enabled.
  [switch]$NoDiarization
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================== plumbing ====

# stdout is the progress contract: a dedicated UTF-8 (no BOM) autoflushing
# writer guarantees one compact JSON object per line, delivered immediately
# rather than buffered until exit.
$script:Out = [System.IO.StreamWriter]::new(
  [System.Console]::OpenStandardOutput(), [System.Text.UTF8Encoding]::new($false))
$script:Out.AutoFlush = $true

$AppRoot  = Split-Path -Parent $PSCommandPath
$InstRoot = Split-Path -Parent $AppRoot
$DataRoot = Join-Path $env:LOCALAPPDATA 'TranscribeIt'

$script:LogDir = Join-Path $DataRoot 'logs'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:LogPath = Join-Path $script:LogDir ("run-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Level, $Message
  try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8 } catch { }
  if ($Level -in @('ERROR', 'WARN')) { try { [Console]::Error.WriteLine($line) } catch { } }
}

function Get-Utc { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# --------------------------------------------------------- stage timing ------

# Per-stage time attribution. The progress stream carries
# whole-second UTC timestamps, which cannot resolve a 3 s stage, so stage cost is
# measured here instead and written to the LOG - stdout is the progress contract
# and may not carry diagnostics. Independent named stopwatches rather than a
# single cursor, because diarization deliberately overlaps transcription.
$script:StageClocks = @{}
$script:StageTimes  = [ordered]@{}

function Start-Stage {
  param([Parameter(Mandatory)][string]$Name)
  $script:StageClocks[$Name] = [System.Diagnostics.Stopwatch]::StartNew()
}

function Stop-Stage {
  param([Parameter(Mandatory)][string]$Name)
  if (-not $script:StageClocks.ContainsKey($Name)) { return }
  $s = $script:StageClocks[$Name].Elapsed.TotalSeconds
  $script:StageTimes[$Name] = [math]::Round($s, 3)
  Write-Log ("STAGE {0} = {1:N3}s" -f $Name, $s) 'DEBUG'
}

function Write-StageSummary {
  if ($script:StageTimes.Count -eq 0) { return }
  try {
    Write-Log ("STAGES " + (([pscustomobject]$script:StageTimes) | ConvertTo-Json -Compress))
  } catch { }
}

# pwsh start -> here: interpreter startup, script parse, config load and vendor
# resolution. Nothing above this line can be measured from inside the script.
try {
  $script:StageTimes['startup'] =
    [math]::Round(((Get-Date) - (Get-Process -Id $PID).StartTime).TotalSeconds, 3)
} catch { }

function Send-Event {
  param([Parameter(Mandatory)][hashtable]$Payload)
  $json = [pscustomobject]$Payload | ConvertTo-Json -Compress -Depth 6
  $script:Out.WriteLine($json)
}

# ------------------------------------------------------- error taxonomy ------

# Every failure the user can actually hit gets its own plain-language message.
# The kind also decides whether continuing to the next file makes any sense:
# an install-level problem (a quarantined binary, a damaged model) is fatal
# even mid-batch, because the next file would fail identically.
class PipelineError : System.Exception {
  [string]$Stage
  [string]$Kind
  [bool]$InstallLevel
  [string]$Detail
  PipelineError([string]$stage, [string]$kind, [string]$message, [bool]$installLevel, [string]$detail)
    : base($message) {
    $this.Stage = $stage; $this.Kind = $kind
    $this.InstallLevel = $installLevel; $this.Detail = $detail
  }
}
class CancelledException : System.Exception {
  CancelledException() : base('Cancelled by user') { }
}

function New-Failure {
  param(
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$Message,
    [switch]$InstallLevel,
    [string]$Detail = ''
  )
  return [PipelineError]::new($Stage, $Kind, $Message, [bool]$InstallLevel, $Detail)
}

# ------------------------------------------------------------ cancellation ---

$script:CancelRequested = $false
$script:CurrentProc = $null
$script:BgProcs = [System.Collections.Generic.List[object]]::new()

try {
  # Ctrl+C in a console; Track E would normally use -CancelSignalFile instead
  [Console]::add_CancelKeyPress({
    param($sender, $e)
    $e.Cancel = $true
    $script:CancelRequested = $true
  })
} catch { }

function Test-Cancelled {
  if ($script:CancelRequested) { return $true }
  if ($CancelSignalFile -and (Test-Path -LiteralPath $CancelSignalFile)) {
    $script:CancelRequested = $true
    return $true
  }
  return $false
}

function Stop-CurrentProcess {
  # Both the foreground child and any process running alongside it (the
  # concurrent diarizer) have to die, or cancelling would leave sherpa-onnx
  # chewing a core after the UI says "cancelled".
  foreach ($p in @($script:CurrentProc) + @($script:BgProcs)) {
    if ($null -ne $p) {
      try { if (-not $p.HasExited) { $p.Kill($true) } } catch { }
    }
  }
}

# ------------------------------------------------------------ config ---------

function Merge-ConfigDefaults {
  param($Target, $Defaults)
  foreach ($p in $Defaults.PSObject.Properties) {
    if ($null -eq $Target.PSObject.Properties[$p.Name]) {
      Add-Member -InputObject $Target -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    } elseif ($p.Value -is [System.Management.Automation.PSCustomObject] -and
              $Target.($p.Name) -is [System.Management.Automation.PSCustomObject]) {
      Merge-ConfigDefaults -Target $Target.($p.Name) -Defaults $p.Value
    }
  }
}

Start-Stage 'init'
$defaultCfgPath = Join-Path $AppRoot 'config.default.json'
if (-not (Test-Path -LiteralPath $defaultCfgPath)) { throw "Missing $defaultCfgPath" }
$cfg = Get-Content -LiteralPath $defaultCfgPath -Raw | ConvertFrom-Json

foreach ($cand in @($ConfigPath, (Join-Path $InstRoot 'config.json'), (Join-Path $AppRoot 'config.json'))) {
  if ($cand -and (Test-Path -LiteralPath $cand)) {
    $user = Get-Content -LiteralPath $cand -Raw | ConvertFrom-Json
    Merge-ConfigDefaults -Target $user -Defaults $cfg
    $cfg = $user
    Write-Log "Config overlay: $cand"
    break
  }
}

function Resolve-Vendor {
  <#
    Resolves a tool or model path at RUNTIME, relative to this script's location,
    so one shipped config works in more than one tree layout.

    The development tree is  vendor\{whisper,sherpa,ffmpeg}\  and vendor\models\.
    The installed tree is       bin\{whisper,sherpa,ffmpeg}\  and     models\.
    Rather than depend on the installer rewriting this file - which would mean a
    successful-looking install with an engine that cannot find its own binaries -
    try the equivalent locations in both layouts, then fall back to locating the
    leaf filename anywhere beneath the install root.
  #>
  param([string]$Relative)
  if ([System.IO.Path]::IsPathRooted($Relative)) { return $Relative }

  $rel = $Relative -replace '/', '\'
  $cands = [System.Collections.Generic.List[string]]::new()
  $cands.Add($rel)
  # vendor\X  <->  bin\X   and   vendor\models  <->  models
  if ($rel -like 'vendor\*') {
    $tail = $rel.Substring(7)
    $cands.Add("bin\$tail")
    $cands.Add($tail)
  } else {
    $cands.Add("vendor\$rel")
    $cands.Add("bin\$rel")
  }

  foreach ($root in @($InstRoot, $AppRoot)) {
    if (-not $root) { continue }
    foreach ($c in $cands) {
      $p = Join-Path $root $c
      if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
    }
  }

  # last resort: find the leaf name somewhere under the install root
  $leaf = [System.IO.Path]::GetFileName($rel)
  if ($leaf -and $leaf -match '\.') {
    $hit = Get-ChildItem -LiteralPath $InstRoot -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($hit) {
      Write-Log "Resolved '$Relative' by search to $($hit.FullName)" 'WARN'
      return $hit.FullName
    }
  }
  return (Join-Path $InstRoot $rel)
}

$FFPROBE  = Resolve-Vendor $cfg.paths.ffprobe
$FFMPEG   = Resolve-Vendor $cfg.paths.ffmpeg
$WHISPER  = Resolve-Vendor $cfg.paths.whisperCli
$DIARIZER = Resolve-Vendor $cfg.paths.diarizer
$MODELDIR = Resolve-Vendor $cfg.paths.modelDir
$MERGER   = Resolve-Vendor $cfg.paths.merger
$RENDERER = Resolve-Vendor $cfg.paths.renderer

# An explicit -NoDiarization beats whatever config says. Applied here, alongside the
# other command-line overrides, so the engine's two diarization branches (concurrent and
# sequential) both simply do not fire - the merge's no-speakers path is already a tested
# edge case, so nothing downstream needs to change.
if ($NoDiarization) {
  $cfg.diarization.enabled = $false
  Write-Log 'Diarization disabled by -NoDiarization; transcript will have a single speaker.'
}

$modelName = if ($Model)    { $Model }    else { $cfg.transcription.model }
$language  = if ($Language) { $Language } else { $cfg.transcription.language }
$modelPath = if ([System.IO.Path]::IsPathRooted($modelName)) { $modelName } else { Join-Path $MODELDIR $modelName }

$logicalCores = [Environment]::ProcessorCount
if ($Threads -gt 0)                       { $nThreads = $Threads }
elseif ($cfg.transcription.threads -gt 0) { $nThreads = [int]$cfg.transcription.threads }
else {
  # MEASURED optimum on this 14-thread hybrid CPU is logicalCores - 2 (=12);
  # using all 14 was slower. See the _threadsComment in config.default.json.
  $nThreads = [math]::Max(4, $logicalCores - 2)
}

$diarThreads = if ($cfg.diarization.threads -gt 0) { [int]$cfg.diarization.threads }
               else { [math]::Max(4, [math]::Min(10, $logicalCores - 2)) }

# --- concurrency: diarization alongside transcription ------------------------
# The two stages share only the WAV, so the diarizer's wall clock can come off
# the critical path entirely. They do compete for cores, so each gets its own
# thread budget while overlapped; MEASURED values are in config.default.json.
$diarConcurrent = $true
if ($null -ne $cfg.diarization.PSObject.Properties['concurrentWithTranscription']) {
  $diarConcurrent = [bool]$cfg.diarization.concurrentWithTranscription
}
$diarConcThreads = $diarThreads
if ($null -ne $cfg.diarization.PSObject.Properties['concurrentThreads'] -and
    [int]$cfg.diarization.concurrentThreads -gt 0) {
  $diarConcThreads = [int]$cfg.diarization.concurrentThreads
}
# 0 = leave transcription's thread count alone while the diarizer runs.
$asrConcThreads = 0
if ($null -ne $cfg.transcription.PSObject.Properties['threadsWhenConcurrent']) {
  $asrConcThreads = [int]$cfg.transcription.threadsWhenConcurrent
}
if ($Threads -gt 0) { $asrConcThreads = 0 }   # an explicit -Threads wins outright

$segModel = Join-Path $MODELDIR ($cfg.diarization.segmentationModel -replace '/', '\')
$embModel = Join-Path $MODELDIR ($cfg.diarization.embeddingModel   -replace '/', '\')
$vadModel = Join-Path $MODELDIR ($cfg.transcription.vadModel       -replace '/', '\')

Stop-Stage 'init'
Write-Log "TranscribeIt $($cfg.toolVersion) | model=$modelName threads=$nThreads diarThreads=$diarThreads lang=$language"

# ------------------------------------------------------- progress / ETA ------

# Cumulative offsets derived from the frozen stageWeights:
# probe 1, decode 2, transcribe 85, diarize 9, merge 1, render 2 -> 100.
$StageWeight = [ordered]@{ probe = 1.0; decode = 2.0; transcribe = 85.0; diarize = 9.0; merge = 1.0; render = 2.0 }
$StageOffset = [ordered]@{}
$acc = 0.0
foreach ($k in $StageWeight.Keys) { $StageOffset[$k] = $acc; $acc += $StageWeight[$k] }

$script:Item = $null

function Start-Item {
  param([string]$Name, [int]$Index, [int]$Total)
  $script:Item = [pscustomobject]@{
    Name       = $Name
    Index      = $Index
    Total      = $Total
    Watch      = [System.Diagnostics.Stopwatch]::StartNew()
    Duration   = 0.0
    MaxOverall = 0.0
    EtaEma     = $null
    LastEmit   = [datetime]::MinValue
    LastStage  = ''
    TransStart = $null
    RtfWindow  = [System.Collections.Generic.Queue[double]]::new()
    BaseRtf    = 0.0
  }
}

function Get-BaseRtf {
  $tbl = $cfg.performance.realTimeFactor
  $p = $tbl.PSObject.Properties[$modelName]
  if ($p -and [double]$p.Value -gt 0) { return [double]$p.Value }
  $d = $tbl.PSObject.Properties['_default']
  if ($d -and [double]$d.Value -gt 0) { return [double]$d.Value }
  return 1.0
}

function Get-EtaSeconds {
  <#
    Seconds remaining for the CURRENT item.

    Three independent estimates of total pipeline wall-clock, in increasing
    order of trustworthiness:
      1. seed        - mediaDuration / calibrated realTimeFactor from config
      2. throughput  - observed transcribe rate, extrapolated over the pipeline
      3. progressRate- elapsed / fractionDone, the purely empirical view

    Where observation is available we take the MAX of the observed estimates.
    That asymmetry is deliberate: underestimating is what produces the
    "0 min left" pathology while the job is visibly still running, and the
    contract calls that out as the worst possible bug in this app. A pessimistic
    estimate merely finishes early.

    Returns $null while genuinely not estimable, 0 only at completion, and
    otherwise never less than 1.
  #>
  param([double]$OverallPercent)
  $it = $script:Item
  if ($null -eq $it -or $it.Duration -le 0) { return $null }
  if ($OverallPercent -ge 99.999) { $it.EtaEma = 0.0; return 0 }

  $elapsed = $it.Watch.Elapsed.TotalSeconds
  $frac    = $OverallPercent / 100.0
  $share   = [double]$cfg.performance.transcribeStageShare
  if ($share -le 0 -or $share -ge 1) { $share = 0.85 }

  $observed = [System.Collections.Generic.List[double]]::new()

  if ($it.RtfWindow.Count -gt 0) {
    $avg = ($it.RtfWindow | Measure-Object -Average).Average
    if ($avg -gt 0) { $observed.Add(($it.Duration / $avg) / $share) }
  }
  # needs enough elapsed time and progress for the ratio to mean anything
  if ($frac -gt 0.02 -and $elapsed -gt 3) { $observed.Add($elapsed / $frac) }

  if ($observed.Count -gt 0) {
    $estTotal = ($observed | Measure-Object -Maximum).Maximum
  } elseif ($it.BaseRtf -gt 0) {
    $estTotal = $it.Duration / $it.BaseRtf
  } else {
    return $null
  }

  # floor of 1s: work remains, so "0 min left" would be a lie
  $raw = [math]::Max(1.0, $estTotal - $elapsed)

  $alpha = [double]$cfg.performance.etaSmoothingAlpha
  if ($alpha -le 0 -or $alpha -gt 1) { $alpha = 0.3 }
  if ($null -eq $it.EtaEma) {
    $it.EtaEma = $raw
  } elseif ($raw -gt 2.5 * $it.EtaEma) {
    # the seed was badly wrong; snap rather than crawl up over 30 ticks
    $it.EtaEma = $raw
  } else {
    $it.EtaEma = $alpha * $raw + (1 - $alpha) * $it.EtaEma
  }
  return [math]::Max(1.0, [math]::Round($it.EtaEma, 0))
}

function Send-Progress {
  param(
    [Parameter(Mandatory)][string]$Stage,
    [AllowNull()][System.Nullable[double]]$StagePercent,
    [string]$Message,
    [switch]$Force
  )
  $it = $script:Item

  if ($StageOffset.Contains($Stage)) {
    $sp = if ($null -eq $StagePercent) { 0.0 } else { [math]::Max(0.0, [math]::Min(100.0, [double]$StagePercent)) }
    $overall = $StageOffset[$Stage] + ($StageWeight[$Stage] * $sp / 100.0)
  } else {
    $overall = $it.MaxOverall
  }

  # authoritative and monotonically non-decreasing, per the contract
  if ($overall -lt $it.MaxOverall) { $overall = $it.MaxOverall } else { $it.MaxOverall = $overall }
  $overall = [math]::Round([math]::Min(100.0, $overall), 1)

  $now = Get-Date
  $interval = [double]$cfg.performance.progressIntervalSeconds
  $stageChanged = ($Stage -ne $it.LastStage)
  $atEnd = ($null -ne $StagePercent -and [double]$StagePercent -ge 100)
  if (-not ($Force -or $stageChanged -or $atEnd)) {
    if (($now - $it.LastEmit).TotalSeconds -lt $interval) { return }
  }
  $it.LastEmit = $now
  $it.LastStage = $Stage

  Send-Event @{
    type           = 'progress'
    stage          = $Stage
    stagePercent   = if ($null -eq $StagePercent) { $null } else { [math]::Round([double]$StagePercent, 1) }
    overallPercent = $overall
    etaSeconds     = Get-EtaSeconds -OverallPercent $overall
    message        = $Message
    itemIndex      = $it.Index
    itemTotal      = $it.Total
    itemName       = $it.Name
    timestamp      = Get-Utc
  }
}

# ------------------------------------------------------------ process run ----

function Invoke-Tool {
  <#
    Runs a native tool via ArgumentList, so spaces and non-ASCII characters in
    paths need no manual quoting. Exactly one stream is read line-by-line; the
    other is drained in the background, which is what prevents a full pipe
    buffer from deadlocking the child. OnTick fires whenever that stream goes
    quiet, letting the progress bar keep moving and cancellation be noticed.
  #>
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$Arguments,
    [scriptblock]$OnStdErrLine,
    [scriptblock]$OnStdOutLine,
    [scriptblock]$OnTick,
    [int]$TickMs = 500,
    [string]$Tag = 'tool',
    [string]$ComponentName = 'A required component'
  )

  if (-not (Test-Path -LiteralPath $FilePath)) {
    throw (New-Failure -Stage $Tag -Kind 'binaryMissing' -InstallLevel `
      -Message "$ComponentName is missing or was blocked by endpoint security. It may have been quarantined. Please send the log file to IT." `
      -Detail "not found: $FilePath")
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FilePath
  foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add([string]$a) }
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput  = $true
  $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
  $psi.WorkingDirectory       = [System.IO.Path]::GetDirectoryName($FilePath)

  Write-Log "$Tag EXEC $FilePath $($Arguments -join ' ')" 'DEBUG'

  $p = [System.Diagnostics.Process]::new()
  $p.StartInfo = $psi
  try { [void]$p.Start() }
  catch [System.ComponentModel.Win32Exception] {
    # The native error code matters. Sending someone to IT for a quarantined
    # binary is right; sending them there because a path was too long wastes
    # everybody's time, and both surface here as a failed CreateProcess.
    $code = $_.Exception.NativeErrorCode
    $detail = "Win32Exception $code starting '$FilePath': $($_.Exception.Message)"
    switch ($code) {
      5 {
        throw (New-Failure -Stage $Tag -Kind 'binaryBlocked' -InstallLevel `
          -Message "$ComponentName was blocked from running by endpoint security or antivirus. It may have been quarantined. Please send the log file to IT." -Detail $detail)
      }
      1260 {
        throw (New-Failure -Stage $Tag -Kind 'binaryBlockedByPolicy' -InstallLevel `
          -Message "$ComponentName was blocked by a software restriction policy on this computer. Please send the log file to IT and ask for TranscribeIt to be allowed." -Detail $detail)
      }
      { $_ -in @(2, 3) } {
        # the file passed Test-Path a moment ago, so this is a dependency or a
        # path Windows itself cannot open
        if ($FilePath.Length -ge 250) {
          throw (New-Failure -Stage $Tag -Kind 'pathTooLong' -InstallLevel `
            -Message "TranscribeIt is installed in a folder whose path is too long for Windows to launch its programs ($($FilePath.Length) characters). Please reinstall it somewhere shorter." -Detail $detail)
        }
        throw (New-Failure -Stage $Tag -Kind 'dependencyMissing' -InstallLevel `
          -Message "$ComponentName is present but could not start because a supporting file is missing. The installation looks incomplete - please reinstall TranscribeIt." -Detail $detail)
      }
      { $_ -in @(193, 216) } {
        throw (New-Failure -Stage $Tag -Kind 'badImage' -InstallLevel `
          -Message "$ComponentName is not compatible with this computer, or the file is damaged. Please reinstall TranscribeIt." -Detail $detail)
      }
      default {
        throw (New-Failure -Stage $Tag -Kind 'binaryBlocked' -InstallLevel `
          -Message "$ComponentName could not be started. It may have been blocked or quarantined by endpoint security. Please send the log file to IT." -Detail $detail)
      }
    }
  }
  $script:CurrentProc = $p
  try { $p.StandardInput.Close() } catch { }

  $lineReader = if ($OnStdOutLine) { $p.StandardOutput } else { $p.StandardError }
  $drainTask  = if ($OnStdOutLine) { $p.StandardError.ReadToEndAsync() } else { $p.StandardOutput.ReadToEndAsync() }
  $lineBuf    = [System.Text.StringBuilder]::new()
  $cancelled  = $false

  $readTask = $lineReader.ReadLineAsync()
  $ticksSinceExit = 0
  while ($true) {
    if ($readTask.Wait($TickMs)) {
      $line = $readTask.Result
      if ($null -eq $line) { break }
      if ($lineBuf.Length -lt 200000) { [void]$lineBuf.AppendLine($line) }
      if ($OnStdOutLine) { & $OnStdOutLine $line } elseif ($OnStdErrLine) { & $OnStdErrLine $line }
      $readTask = $lineReader.ReadLineAsync()
    } else {
      if (Test-Cancelled) { $cancelled = $true; Stop-CurrentProcess; break }
      if ($OnTick) { & $OnTick }
      # Normally the stream closing (null line) ends this loop. Guard against a
      # grandchild inheriting the pipe and holding it open after the child exits,
      # which would otherwise spin here forever.
      if ($p.HasExited) {
        $ticksSinceExit++
        if ($ticksSinceExit -ge 20) {
          Write-Log "$Tag exited but output pipe stayed open; abandoning reader" 'WARN'
          break
        }
      } else { $ticksSinceExit = 0 }
    }
  }

  if (-not $p.WaitForExit(15000)) {
    Write-Log "$Tag did not exit within 15s of stream close; killing" 'WARN'
    try { $p.Kill($true) } catch { }
    [void]$p.WaitForExit(5000)
  }
  $script:CurrentProc = $null
  $drained = ''
  try { $drained = $drainTask.GetAwaiter().GetResult() } catch { }

  $exitCode = -1
  try { $exitCode = $p.ExitCode } catch { }
  $result = [pscustomobject]@{
    ExitCode = $exitCode
    StdOut   = if ($OnStdOutLine) { $lineBuf.ToString() } else { $drained }
    StdErr   = if ($OnStdOutLine) { $drained } else { $lineBuf.ToString() }
  }
  $p.Dispose()
  if ($cancelled) { throw [CancelledException]::new() }
  if ($result.ExitCode -ne 0) {
    Write-Log "$Tag exit=$($result.ExitCode)" 'WARN'
    Write-Log "$Tag stderr tail: $(($result.StdErr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 8) -join ' | ')" 'WARN'
  }
  return $result
}

# ---------------------------------------------------------- preflight --------

function Assert-SourceReadable {
  param([string]$MediaPath)
  if (-not (Test-Path -LiteralPath $MediaPath)) {
    throw (New-Failure -Stage 'probe' -Kind 'notFound' `
      -Message 'That file could not be found. It may have been moved, renamed, or not yet finished syncing.' `
      -Detail $MediaPath)
  }
  try {
    $fs = [System.IO.File]::Open($MediaPath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $fs.Dispose()
  }
  catch [System.UnauthorizedAccessException] {
    throw (New-Failure -Stage 'probe' -Kind 'accessDenied' `
      -Message 'You do not have permission to read this file.' -Detail $_.Exception.Message)
  }
  catch [System.IO.IOException] {
    throw (New-Failure -Stage 'probe' -Kind 'locked' `
      -Message 'This file is in use by another application. Close it (or wait for it to finish syncing) and try again.' `
      -Detail $_.Exception.Message)
  }
}

function Assert-ModelUsable {
  param([string]$FilePath, [string]$Label)
  if (-not (Test-Path -LiteralPath $FilePath)) {
    throw (New-Failure -Stage 'transcribe' -Kind 'modelMissing' -InstallLevel `
      -Message "The $Label file is missing. The installation looks incomplete - please reinstall TranscribeIt." `
      -Detail $FilePath)
  }
  # a quantised whisper model is tens of MB at minimum; anything smaller is a
  # truncated download from a previous install
  $len = (Get-Item -LiteralPath $FilePath).Length
  if ($len -lt 10MB) {
    throw (New-Failure -Stage 'transcribe' -Kind 'modelTruncated' -InstallLevel `
      -Message "The $Label file is damaged or was only partly downloaded ($([math]::Round($len/1MB,1)) MB). Please reinstall TranscribeIt." `
      -Detail "$FilePath is $len bytes")
  }
}

function Assert-DiskSpace {
  param([string]$WorkDir, [double]$DurationSeconds)
  # 16 kHz mono 16-bit PCM is 32 000 bytes/second, about 115 MB per hour
  $needed = [int64]($DurationSeconds * 32000) + 64MB
  try {
    $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $WorkDir).Path)
    $free = [System.IO.DriveInfo]::new($root).AvailableFreeSpace
    if ($free -lt $needed) {
      $needMb = [math]::Round($needed / 1MB)
      $freeMb = [math]::Round($free / 1MB)
      throw (New-Failure -Stage 'decode' -Kind 'diskFull' `
        -Message "Not enough free disk space. This recording needs about $needMb MB of temporary space on $root but only $freeMb MB is free." `
        -Detail "need=$needed free=$free")
    }
  } catch [PipelineError] { throw }
  catch { Write-Log "Disk space check skipped: $($_.Exception.Message)" 'WARN' }
}

# ================================================================ stages =====

function Invoke-Probe {
  param([string]$MediaPath)
  Send-Progress -Stage 'probe' -StagePercent $null -Message 'Inspecting file' -Force

  $a = @('-v', 'error', '-print_format', 'json', '-show_format',
         '-select_streams', 'a:0', '-show_streams', $MediaPath)
  $r = Invoke-Tool -FilePath $FFPROBE -Arguments $a -Tag 'probe' -ComponentName 'The media inspector (ffprobe.exe)'

  $meta = $null
  if ($r.ExitCode -eq 0) { try { $meta = $r.StdOut | ConvertFrom-Json } catch { } }
  if ($null -eq $meta) {
    throw (New-Failure -Stage 'probe' -Kind 'corrupt' `
      -Message 'This file could not be read. It appears to be corrupt or is not an audio or video file.' `
      -Detail (($r.StdErr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 3) -join ' | '))
  }

  $streams = @()
  if ($null -ne $meta.PSObject.Properties['streams'] -and $null -ne $meta.streams) { $streams = @($meta.streams) }
  $audio = $streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
  if ($null -eq $audio) {
    throw (New-Failure -Stage 'probe' -Kind 'noAudio' `
      -Message 'This file has no audio track, so there is nothing to transcribe.' -Detail 'ffprobe found no audio stream')
  }

  $dur = 0.0
  foreach ($src in @($meta.format.duration, $audio.duration)) {
    $parsed = 0.0
    if ($src -and [double]::TryParse([string]$src, [ref]$parsed) -and $parsed -gt 0) { $dur = $parsed; break }
  }

  $sizeBytes = $null
  try { $sizeBytes = [int64](Get-Item -LiteralPath $MediaPath).Length } catch { }

  [pscustomobject]@{
    DurationSeconds = $dur
    Container       = if ($meta.format.format_name) { [string]$meta.format.format_name } else { $null }
    AudioCodec      = if ($audio.codec_name) { [string]$audio.codec_name } else { $null }
    SizeBytes       = $sizeBytes
  }
}

function Invoke-Decode {
  param([string]$MediaPath, [string]$WavPath, [double]$DurationSeconds)

  Send-Progress -Stage 'decode' -StagePercent 0 -Message 'Extracting audio' -Force
  $a = @('-hide_banner', '-nostdin', '-loglevel', 'error',
         '-progress', 'pipe:2', '-nostats', '-y',
         '-i', $MediaPath, '-vn', '-map', '0:a:0',
         '-ac', '1', '-ar', '16000', '-acodec', 'pcm_s16le',
         '-f', 'wav', $WavPath)

  $onErr = {
    param($line)
    if ($line -match '^out_time_us=(-?\d+)' -or $line -match '^out_time_ms=(-?\d+)') {
      $sec = [double]$Matches[1] / 1000000.0
      if ($DurationSeconds -gt 0 -and $sec -ge 0) {
        Send-Progress -Stage 'decode' -StagePercent ([math]::Min(99.0, 100.0 * $sec / $DurationSeconds)) -Message 'Extracting audio'
      }
    }
  }

  $r = Invoke-Tool -FilePath $FFMPEG -Arguments $a -OnStdErrLine $onErr -Tag 'decode' -ComponentName 'The audio decoder (ffmpeg.exe)'
  if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $WavPath)) {
    $tail = ($r.StdErr -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\w+=' } | Select-Object -Last 3) -join ' | '
    if ($tail -match 'No space left|not enough space') {
      throw (New-Failure -Stage 'decode' -Kind 'diskFull' `
        -Message 'Ran out of disk space while extracting the audio. Free some space and try again.' -Detail $tail)
    }
    throw (New-Failure -Stage 'decode' -Kind 'decodeFailed' `
      -Message 'The audio track could not be decoded. The file may be partly corrupt or use an unsupported codec.' -Detail $tail)
  }
  $len = (Get-Item -LiteralPath $WavPath).Length
  if ($len -le 1024) {
    throw (New-Failure -Stage 'decode' -Kind 'emptyAudio' `
      -Message 'The audio track is silent or empty, so there is nothing to transcribe.' -Detail "wav=$len bytes")
  }
  Send-Progress -Stage 'decode' -StagePercent 100 -Message 'Extracting audio' -Force
  # authoritative duration: 16-bit mono at 16 kHz, minus the 44-byte header
  return ($len - 44) / 32000.0
}

function Invoke-Transcribe {
  param([string]$WavPath, [string]$OutPrefix, [double]$DurationSeconds, [int]$ThreadCount = 0)

  Assert-ModelUsable -FilePath $modelPath -Label 'speech recognition model'
  if ($ThreadCount -le 0) { $ThreadCount = $nThreads }
  $it = $script:Item
  $it.TransStart = [System.Diagnostics.Stopwatch]::StartNew()
  Send-Progress -Stage 'transcribe' -StagePercent 0 -Message 'Transcribing audio' -Force

  $t = $cfg.transcription
  $a = [System.Collections.Generic.List[string]]::new()
  $a.AddRange([string[]]@(
    '-m', $modelPath, '-f', $WavPath,
    '-of', $OutPrefix, '-oj', '-ojf',
    '-t', "$ThreadCount", '-p', "$([int]$t.processors)",
    '-l', $language, '-pp',
    '-bs', "$([int]$t.beamSize)", '-bo', "$([int]$t.bestOf)",
    '-mc', "$([int]$t.maxContext)",
    '-nth', "$([double]$t.noSpeechThreshold)",
    '-et',  "$([double]$t.entropyThreshold)",
    '-lpt', "$([double]$t.logprobThreshold)",
    '-tp',  "$([double]$t.temperature)",
    '-tpi', "$([double]$t.temperatureInc)"
  ))
  if ($t.suppressNonSpeechTokens) { $a.Add('-sns') }
  if ($t.useVad) {
    if (Test-Path -LiteralPath $vadModel) {
      $a.AddRange([string[]]@(
        '--vad', '-vm', $vadModel,
        '-vt',   "$([double]$t.vadThreshold)",
        '-vspd', "$([int]$t.vadMinSpeechDurationMs)",
        '-vsd',  "$([int]$t.vadMinSilenceDurationMs)",
        '-vp',   "$([int]$t.vadSpeechPadMs)",
        '-vmsd', "$([double]$t.vadMaxSpeechDurationSeconds)"
      ))
    } else {
      Write-Log "VAD requested but model missing at $vadModel - continuing without it" 'WARN'
    }
  }

  # whisper reports progress in 5% steps, and not at all until its first 30 s
  # chunk completes; interpolate between ticks so a long file never looks
  # frozen for minutes at a time
  $script:LastPct = 0.0
  $script:SeenRealTick = $false
  $onErr = {
    param($line)
    if ($line -match 'progress\s*=\s*(\d+)\s*%') {
      $pct = [double]$Matches[1]
      $script:LastPct = $pct
      $script:SeenRealTick = $true
      $el = $script:Item.TransStart.Elapsed.TotalSeconds
      if ($el -gt 3 -and $pct -gt 0) {
        $rtf = ($DurationSeconds * $pct / 100.0) / $el
        if ($rtf -gt 0) {
          $script:Item.RtfWindow.Enqueue($rtf)
          $w = [math]::Max(2, [int]$cfg.performance.etaThroughputWindow)
          while ($script:Item.RtfWindow.Count -gt $w) { [void]$script:Item.RtfWindow.Dequeue() }
        }
      }
      Send-Progress -Stage 'transcribe' -StagePercent $pct -Message 'Transcribing audio' -Force
    }
  }

  $onTick = {
    $el = $script:Item.TransStart.Elapsed.TotalSeconds
    if ($el -le 0 -or $DurationSeconds -le 0) { return }
    $obs = if ($script:Item.RtfWindow.Count -gt 0) { ($script:Item.RtfWindow | Measure-Object -Average).Average }
           else { $script:Item.BaseRtf / [double]$cfg.performance.transcribeStageShare }
    if ($obs -le 0) { return }
    $projected = 100.0 * ($el * $obs) / $DurationSeconds
    # Once whisper has given us a real checkpoint, stay inside the next one so
    # the bar cannot overshoot. Before the first checkpoint there is nothing to
    # anchor to, so trust the throughput projection - otherwise the bar sticks
    # at whatever LastPct happens to be (0) for the whole first chunk.
    $cap = if ($script:SeenRealTick) { [math]::Min(99.0, $script:LastPct + 4.9) } else { 95.0 }
    Send-Progress -Stage 'transcribe' -Message 'Transcribing audio' `
      -StagePercent ([math]::Max($script:LastPct, [math]::Min($cap, $projected)))
  }

  $r = Invoke-Tool -FilePath $WHISPER -Arguments $a.ToArray() -OnStdErrLine $onErr -OnTick $onTick `
        -TickMs 1000 -Tag 'transcribe' -ComponentName 'The speech recognition engine (whisper-cli.exe)'

  $jsonPath = "$OutPrefix.json"
  if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $jsonPath)) {
    $err = $r.StdErr
    if ($err -match 'failed to load|whisper_init.*failed|invalid model|bad magic|unknown model') {
      throw (New-Failure -Stage 'transcribe' -Kind 'modelTruncated' -InstallLevel `
        -Message 'The speech recognition model could not be loaded; it is damaged or incomplete. Please reinstall TranscribeIt.' `
        -Detail (($err -split "`r?`n" | Select-Object -Last 4) -join ' | '))
    }
    if ($err -match 'alloc|out of memory|bad_alloc|ggml_new_tensor') {
      throw (New-Failure -Stage 'transcribe' -Kind 'outOfMemory' `
        -Message 'The computer ran out of memory while transcribing. Close some applications and try again, or choose a smaller model.' `
        -Detail (($err -split "`r?`n" | Select-Object -Last 4) -join ' | '))
    }
    throw (New-Failure -Stage 'transcribe' -Kind 'transcribeFailed' `
      -Message 'Transcription failed. The audio may be unusable; the log file has the details.' `
      -Detail (($err -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6) -join ' | '))
  }
  Send-Progress -Stage 'transcribe' -StagePercent 100 -Message 'Transcribing audio' -Force

  # Only the detected language is wanted from this file, and the merger is about
  # to read the whole thing anyway. With -ojf the JSON carries token-level
  # timings and runs to ~300 KB, so a full ConvertFrom-Json here is a parse of
  # the entire transcript to retrieve one string. When the language was pinned
  # there is nothing to detect; when it was not, whisper writes "result" ahead of
  # "transcription", so the head of the file is enough.
  $detected = $language
  if ($language -eq 'auto') {
    try {
      $head = [System.IO.File]::ReadAllBytes($jsonPath)
      $n    = [math]::Min(8192, $head.Length)
      $txt  = [System.Text.Encoding]::UTF8.GetString($head, 0, $n)
      if ($txt -match '"result"\s*:\s*\{[^}]*?"language"\s*:\s*"([^"]+)"') { $detected = $Matches[1] }
      elseif ($txt -match '"language"\s*:\s*"([^"]+)"')                    { $detected = $Matches[1] }
    } catch { }
  }
  [pscustomobject]@{ JsonPath = $jsonPath; Language = $detected }
}

function Test-DiarizeModels {
  foreach ($m in @($segModel, $embModel)) {
    if (-not (Test-Path -LiteralPath $m)) {
      Write-Log "Diarization model missing: $m - continuing as single speaker" 'WARN'
      return $false
    }
  }
  return $true
}

function Get-DiarizeArguments {
  param([string]$WavPath, [int]$ThreadCount)
  $d = $cfg.diarization
  $a = [System.Collections.Generic.List[string]]::new()
  $a.AddRange([string[]]@(
    '--print-args=false',
    "--segmentation.pyannote-model=$segModel",
    "--segmentation.num-threads=$ThreadCount",
    "--segmentation.pyannote-window-shift-ratio=$([double]$d.windowShiftRatio)",
    "--embedding.model=$embModel",
    "--embedding.num-threads=$ThreadCount",
    "--min-duration-on=$([double]$d.minDurationOn)",
    "--min-duration-off=$([double]$d.minDurationOff)"
  ))
  if ($Speakers -gt 0) { $a.Add("--clustering.num-clusters=$Speakers") }
  else                 { $a.Add("--clustering.cluster-threshold=$([double]$d.clusterThreshold)") }
  $a.Add($WavPath)
  return $a.ToArray()
}

function ConvertTo-DiarizeSegment {
  <# sherpa prints one "start -- end speaker_N" line per segment on stdout. #>
  param([string]$Text)
  $segs = [System.Collections.Generic.List[object]]::new()
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*([0-9]+\.?[0-9]*)\s+--\s+([0-9]+\.?[0-9]*)\s+speaker_([0-9]+)\s*$') {
      $segs.Add([pscustomobject]@{
        start   = [math]::Round([double]$Matches[1], 3)
        end     = [math]::Round([double]$Matches[2], 3)
        speaker = "speaker_$($Matches[3])"
      })
    }
  }
  # Comma operator: PowerShell enumerates a returned collection, and an EMPTY
  # list would come back as $null, so the caller's $segs.Count would throw under
  # Set-StrictMode. That path is reachable - it is exactly what a diarizer that
  # produced nothing looks like - and it must degrade to a single-speaker
  # transcript, not blow up the item.
  return , $segs
}

function Save-DiarizeSegment {
  param($Segments, [string]$SegmentsPath)
  $json = @($Segments | Sort-Object start) | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText($SegmentsPath, $json, [System.Text.UTF8Encoding]::new($false))
  Write-Log "Diarization: $($Segments.Count) segments, $((@($Segments.speaker | Sort-Object -Unique)).Count) speakers"
}

function Start-DiarizeBackground {
  <#
    Launch the diarizer to run ALONGSIDE transcription and return a handle, or
    $null if it could not be started concurrently.

    Diarization and transcription both consume only the 16 kHz WAV and neither
    reads the other's output - only the merge needs both - so the diarizer's
    whole wall clock can come off the critical path. It is a fixed ~8 s on a
    short clip and 30-44 s on a long one, which is pure saving if the two do not
    starve each other for cores; hence the separate, smaller thread budget.

    Any failure to START concurrently returns $null and the caller falls back to
    the synchronous path, so the install-level error taxonomy in Invoke-Tool
    (quarantined binary, blocked by policy, missing dependency) still gets to
    produce the message the user sees.
  #>
  param([string]$WavPath, [int]$ThreadCount)

  if (-not (Test-DiarizeModels)) { return $null }
  if (-not (Test-Path -LiteralPath $DIARIZER)) {
    Write-Log 'Diarizer not found; deferring to the synchronous path so it can report the install error' 'WARN'
    return $null
  }

  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $DIARIZER
    foreach ($x in (Get-DiarizeArguments -WavPath $WavPath -ThreadCount $ThreadCount)) { [void]$psi.ArgumentList.Add([string]$x) }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    # sherpa-onnx resolves onnxruntime.dll from beside its own executable
    $psi.WorkingDirectory       = [System.IO.Path]::GetDirectoryName($DIARIZER)

    Write-Log "diarize EXEC(bg) $DIARIZER threads=$ThreadCount" 'DEBUG'
    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()
    try { $p.StandardInput.Close() } catch { }
    $script:BgProcs.Add($p)

    # Both pipes are drained continuously from the start: a full 64 KB buffer
    # would otherwise block the diarizer until transcription happened to finish.
    return [pscustomobject]@{
      Proc    = $p
      OutTask = $p.StandardOutput.ReadToEndAsync()
      ErrTask = $p.StandardError.ReadToEndAsync()
      Watch   = [System.Diagnostics.Stopwatch]::StartNew()
    }
  }
  catch {
    Write-Log "Could not start the diarizer alongside transcription ($($_.Exception.Message)); falling back to sequential" 'WARN'
    return $null
  }
}

function Complete-DiarizeBackground {
  <# Collect a Start-DiarizeBackground handle. Returns $true when segments were written. #>
  param($Handle, [string]$SegmentsPath)

  Send-Progress -Stage 'diarize' -StagePercent 0 -Message 'Identifying speakers' -Force
  $p = $Handle.Proc

  # Poll rather than block, so Cancel still lands within half a second even if
  # the diarizer is the only thing left running.
  while (-not $p.HasExited) {
    if (Test-Cancelled) { Stop-CurrentProcess; throw [CancelledException]::new() }
    [void]$p.WaitForExit(500)
    Send-Progress -Stage 'diarize' -StagePercent 50 -Message 'Identifying speakers'
  }
  [void]$p.WaitForExit(5000)

  $out = ''; $errText = ''
  try { $out     = $Handle.OutTask.GetAwaiter().GetResult() } catch { }
  try { $errText = $Handle.ErrTask.GetAwaiter().GetResult() } catch { }
  $code = -1
  try { $code = $p.ExitCode } catch { }
  # The handle's stopwatch only measures time-to-collection, which is really the
  # transcribe stage. The diarizer's OWN wall clock is what says whether it
  # finished inside the transcribe window (the whole point) or became the new
  # long pole and needs a bigger thread budget.
  $selfSeconds = $null
  try { $selfSeconds = ($p.ExitTime - $p.StartTime).TotalSeconds } catch { }
  try { [void]$script:BgProcs.Remove($p) } catch { }
  $p.Dispose()

  if ($null -ne $selfSeconds) { $script:StageTimes['diarizeProcess'] = [math]::Round($selfSeconds, 3) }
  Write-Log ("diarize(bg) ran {0:N1}s of its own, collected after {1:N1}s, exit={2}" -f `
    $(if ($null -ne $selfSeconds) { $selfSeconds } else { -1 }), $Handle.Watch.Elapsed.TotalSeconds, $code)
  $segs = ConvertTo-DiarizeSegment -Text $out
  if ($code -ne 0 -or $segs.Count -eq 0) {
    Write-Log "diarize(bg) stderr tail: $(($errText -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6) -join ' | ')" 'WARN'
    Write-Log "Diarization unusable (exit=$code, segments=$($segs.Count)); continuing as single speaker" 'WARN'
    return $false
  }

  Save-DiarizeSegment -Segments $segs -SegmentsPath $SegmentsPath
  Send-Progress -Stage 'diarize' -StagePercent 100 -Message 'Identifying speakers' -Force
  return $true
}

function Invoke-Diarize {
  <#
    Sequential fallback. Returns $true when speaker segments were written.
    Diarization is best-effort: if it fails we still ship a single-speaker
    transcript rather than losing the whole run, and the merger warns.
  #>
  param([string]$WavPath, [string]$SegmentsPath, [int]$ThreadCount)

  Send-Progress -Stage 'diarize' -StagePercent 0 -Message 'Identifying speakers' -Force
  if (-not (Test-DiarizeModels)) { return $false }

  $segs = [System.Collections.Generic.List[object]]::new()
  $onOut = {
    param($line)
    if ($line -match '^\s*progress\s+([0-9.]+)\s*%') {
      Send-Progress -Stage 'diarize' -StagePercent ([math]::Min(99.0, [double]$Matches[1])) -Message 'Identifying speakers'
    } elseif ($line -match '^\s*([0-9]+\.?[0-9]*)\s+--\s+([0-9]+\.?[0-9]*)\s+speaker_([0-9]+)\s*$') {
      $segs.Add([pscustomobject]@{
        start   = [math]::Round([double]$Matches[1], 3)
        end     = [math]::Round([double]$Matches[2], 3)
        speaker = "speaker_$($Matches[3])"
      })
    }
  }

  # A quarantined diarizer is an install problem worth naming, so let
  # binaryMissing/binaryBlocked propagate; anything else degrades gracefully.
  try {
    $r = Invoke-Tool -FilePath $DIARIZER -Arguments (Get-DiarizeArguments -WavPath $WavPath -ThreadCount $ThreadCount) `
          -OnStdOutLine $onOut -TickMs 1000 -Tag 'diarize' -ComponentName 'The speaker separation engine (sherpa-onnx)'
  }
  catch [CancelledException] { throw }
  catch [PipelineError] {
    if ($_.Exception.InstallLevel) { throw }
    Write-Log "Diarization error: $($_.Exception.Message) - continuing as single speaker" 'WARN'
    return $false
  }

  if ($r.ExitCode -ne 0 -or $segs.Count -eq 0) {
    Write-Log "Diarization unusable (exit=$($r.ExitCode), segments=$($segs.Count)); continuing as single speaker" 'WARN'
    return $false
  }

  Save-DiarizeSegment -Segments $segs -SegmentsPath $SegmentsPath
  Send-Progress -Stage 'diarize' -StagePercent 100 -Message 'Identifying speakers' -Force
  return $true
}

function Invoke-Merge {
  param([string]$WhisperJson, [string]$SegmentsPath, [string]$ContextPath, [string]$TurnsPath)
  Send-Progress -Stage 'merge' -StagePercent 0 -Message 'Aligning speakers to transcript' -Force
  $m = $cfg.merge

  $inProcess = $true
  if ($null -ne $m.PSObject.Properties['inProcess']) { $inProcess = [bool]$m.inProcess }

  if ($inProcess) {
    # A fresh pwsh costs ~2.3 s on this machine before the merger's first
    # statement runs (test/perf/results-stage-startup.json, AC, quiet), which
    # was most of the merge stage's wall clock. The call operator runs the
    # script in a child scope: its Set-StrictMode and preference variables do
    # not reach this scope, an `exit` inside it would not end this process, and
    # its output was verified identical apart from processedAtUtc. What is
    # given up is mid-merge cancellation - the child path polled the cancel
    # sentinel while the merger ran; in-process the check waits for the merger
    # to finish, an acceptable window at sub-second merge times.
    # merge.inProcess=false in config.json restores the child-process path.
    $mergeArgs = @{
      WhisperJson            = $WhisperJson
      OutJson                = $TurnsPath
      ContextJson            = $ContextPath
      PauseSplitSeconds      = [double]$m.pauseSplitSeconds
      SoftMaxTurnCharacters  = [int]$m.softMaxTurnCharacters
      HardMaxTurnCharacters  = [int]$m.hardMaxTurnCharacters
      AmbiguityMarginSeconds = [double]$m.ambiguityMarginSeconds
      MinOverlapRatio        = [double]$m.minOverlapRatio
      MaxExpectedSpeakers    = [int]$cfg.diarization.maxExpectedSpeakers
      LongSilenceWarnSeconds = [double]$m.longSilenceWarnSeconds
    }
    if ($SegmentsPath -and (Test-Path -LiteralPath $SegmentsPath)) {
      $mergeArgs.SegmentsJson = $SegmentsPath
    }
    try {
      # The merger reports its one-line JSON summary on the information stream;
      # 6>&1 folds it into the captured output so the log keeps the same line
      # the child-process path always recorded.
      $mergeOut = @(& $MERGER @mergeArgs 6>&1 | ForEach-Object { "$_" })
      if (-not (Test-Path -LiteralPath $TurnsPath)) {
        throw "merger completed without writing $TurnsPath"
      }
      Write-Log "merge: $(@($mergeOut | Where-Object { $_ -match '^\{' }) | Select-Object -Last 1)"
    }
    catch [CancelledException] { throw }
    catch {
      Write-Log "merge (in-process) failed: $($_.Exception.Message)" 'ERROR'
      throw (New-Failure -Stage 'merge' -Kind 'mergeFailed' `
        -Message 'Speaker alignment failed, so no transcript could be produced. The log file has the details.' `
        -Detail $_.Exception.Message)
    }
    Send-Progress -Stage 'merge' -StagePercent 100 -Message 'Aligning speakers to transcript' -Force
    return
  }

  $a = [System.Collections.Generic.List[string]]::new()
  $a.AddRange([string[]]@(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MERGER,
    '-WhisperJson', $WhisperJson,
    '-OutJson', $TurnsPath,
    '-ContextJson', $ContextPath,
    '-PauseSplitSeconds',      "$([double]$m.pauseSplitSeconds)",
    '-SoftMaxTurnCharacters',  "$([int]$m.softMaxTurnCharacters)",
    '-HardMaxTurnCharacters',  "$([int]$m.hardMaxTurnCharacters)",
    '-AmbiguityMarginSeconds', "$([double]$m.ambiguityMarginSeconds)",
    '-MinOverlapRatio',        "$([double]$m.minOverlapRatio)",
    '-MaxExpectedSpeakers',    "$([int]$cfg.diarization.maxExpectedSpeakers)",
    '-LongSilenceWarnSeconds', "$([double]$m.longSilenceWarnSeconds)"
  ))
  if ($SegmentsPath -and (Test-Path -LiteralPath $SegmentsPath)) {
    $a.AddRange([string[]]@('-SegmentsJson', $SegmentsPath))
  }

  $r = Invoke-Tool -FilePath $script:PwshPath -Arguments $a.ToArray() -Tag 'merge' -ComponentName 'PowerShell'
  if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $TurnsPath)) {
    Write-Log "merge stdout: $($r.StdOut)" 'ERROR'
    Write-Log "merge stderr: $($r.StdErr)" 'ERROR'
    throw (New-Failure -Stage 'merge' -Kind 'mergeFailed' `
      -Message 'Speaker alignment failed, so no transcript could be produced. The log file has the details.' `
      -Detail (($r.StdErr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 5) -join ' | '))
  }
  Write-Log "merge: $(($r.StdOut -split "`r?`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1))"
  Send-Progress -Stage 'merge' -StagePercent 100 -Message 'Aligning speakers to transcript' -Force
}

function Save-RecoveredTranscript {
  <#
    Rendering is the last 2% of the pipeline. If it fails we must not throw
    away a transcript that may have taken half an hour to produce - but the
    contract also says the source folder may only ever gain the final PDF, so
    the rescue copy goes to %LOCALAPPDATA%.
  #>
  param([string]$TurnsPath, [string]$MediaPath)
  try {
    $dir = Join-Path $DataRoot 'recovered'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $name = '{0}-{1}.transcript.json' -f
      [System.IO.Path]::GetFileNameWithoutExtension($MediaPath), (Get-Date -Format 'yyyyMMdd-HHmmss')
    $dest = Join-Path $dir $name
    Copy-Item -LiteralPath $TurnsPath -Destination $dest -Force
    Write-Log "Transcript preserved at $dest"
    return $dest
  } catch {
    Write-Log "Could not preserve transcript: $($_.Exception.Message)" 'WARN'
    return $null
  }
}

function Invoke-Render {
  param([string]$TurnsPath, [string]$PdfPath, [string]$MediaPath)
  Send-Progress -Stage 'render' -StagePercent 0 -Message 'Writing PDF' -Force

  if (-not (Test-Path -LiteralPath $RENDERER)) {
    $saved = Save-RecoveredTranscript -TurnsPath $TurnsPath -MediaPath $MediaPath
    throw (New-Failure -Stage 'render' -Kind 'rendererMissing' `
      -Message "The PDF component is missing, so the PDF could not be created. The transcript itself finished successfully and was saved to $saved." `
      -Detail "renderer not found: $RENDERER")
  }

  $inProcess = $true
  if ($null -ne $cfg.render.PSObject.Properties['inProcess']) { $inProcess = [bool]$cfg.render.inProcess }

  if ($inProcess) {
    # Same rationale and same escape hatch as Invoke-Merge: the child pwsh cost
    # ~2.8 s before Render-Pdf's first statement plus a comparable teardown,
    # and Edge itself - the render's real work - is a grandchild either way.
    # Render-Pdf signals failure with `exit`, which ends only its own script
    # scope when invoked with the call operator; its message goes to
    # [Console]::Error, which redirection operators cannot see, so stderr is
    # captured by swapping the process writer around the call. Verified: exit
    # code lands in $LASTEXITCODE, the caller survives, strictness intact.
    # render.inProcess=false in config.json restores the child-process path.
    #
    # NOTE for whoever edits this next: while the writer is swapped, anything
    # this process sends to [Console]::Error is diverted into the capture buffer
    # instead of the real stderr - and Write-Log echoes WARN and ERROR there.
    # Harmless as written, because the engine is blocked inside the renderer for
    # the whole window and Write-Log's file output is unaffected either way. Do
    # not start a background task that logs during this call without moving its
    # logging off Console.Error first.
    function Invoke-RendererInProcess {
      param([hashtable]$NamedArgs, [string[]]$PositionalArgs)
      $ew = [System.IO.StringWriter]::new()
      $orig = [Console]::Error
      $lines = @()
      $threw = $false
      try {
        [Console]::SetError($ew)
        if ($NamedArgs) { $lines = @(& $RENDERER @NamedArgs 6>&1 | ForEach-Object { "$_" }) }
        else            { $lines = @(& $RENDERER @PositionalArgs 6>&1 | ForEach-Object { "$_" }) }
      } catch {
        $threw = $true
        $lines += "renderer exception: $($_.Exception.Message)"
      } finally {
        [Console]::SetError($orig)
      }
      # A THROWN renderer never reaches its own `exit`, so $LASTEXITCODE still
      # holds whatever the previous command left there - frequently 0, which
      # would read as success. The caller also tests for the PDF so nothing
      # actually slips through, but a failure must not depend on that: report a
      # sentinel non-zero instead of a stale zero.
      $code = if ($threw) { -1 } else { 0 }
      if (-not $threw) {
        try { if (Test-Path variable:LASTEXITCODE) { $code = [int]$LASTEXITCODE } } catch { }
      }
      return [pscustomobject]@{ ExitCode = $code; StdOut = ($lines -join "`n"); StdErr = $ew.ToString() }
    }

    # Config stores the parameter names dash-prefixed for the command line;
    # splatting wants them bare.
    $namedArgs = @{}
    $namedArgs[("$($cfg.render.turnsParam)".TrimStart('-'))]  = $TurnsPath
    $namedArgs[("$($cfg.render.outputParam)".TrimStart('-'))] = $PdfPath

    $r = Invoke-RendererInProcess -NamedArgs $namedArgs
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $PdfPath)) {
      # Track B's signature is not pinned by the contracts; retry positionally
      Write-Log 'Renderer named-parameter call failed; retrying positionally' 'WARN'
      $r = Invoke-RendererInProcess -PositionalArgs @($TurnsPath, $PdfPath)
    }
  }
  else {
    $named = [string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RENDERER,
                         $cfg.render.turnsParam, $TurnsPath, $cfg.render.outputParam, $PdfPath)
    $r = Invoke-Tool -FilePath $script:PwshPath -Arguments $named -Tag 'render' -ComponentName 'PowerShell'

    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $PdfPath)) {
      # Track B's signature is not pinned by the contracts; retry positionally
      Write-Log 'Renderer named-parameter call failed; retrying positionally' 'WARN'
      $pos = [string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RENDERER, $TurnsPath, $PdfPath)
      $r = Invoke-Tool -FilePath $script:PwshPath -Arguments $pos -Tag 'render2' -ComponentName 'PowerShell'
    }
  }

  if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $PdfPath)) {
    Write-Log "render stdout: $($r.StdOut)" 'ERROR'
    Write-Log "render stderr: $($r.StdErr)" 'ERROR'
    $saved = Save-RecoveredTranscript -TurnsPath $TurnsPath -MediaPath $MediaPath
    $combined = "$($r.StdOut)`n$($r.StdErr)"
    # Blame policy ONLY when the renderer actually reported a policy restriction.
    # This used to fire on the mere presence of the string 'Edge' anywhere in the
    # output - and since the renderer's own failure text always contains 'Edge',
    # EVERY render failure was reported to the user as a suspected enterprise
    # block. On 2026-08-27 that sent a launcher-exit race to the user as
    # "Company policy may be blocking it", which is the one wrong answer that
    # costs somebody a day with IT. The renderer's real policy signal is its
    # own Fail 5 wording.
    $why = if ($combined -match 'refused to print|disabled by policy|Printing is disabled|not allowed') {
      'Microsoft Edge refused to print because of an enterprise policy on this computer, which the PDF step needs. Please send the log file to IT.'
    } elseif ($combined -match 'did not produce a usable PDF|no PDF produced') {
      'Microsoft Edge ran but did not finish writing the PDF.'
    } elseif ($combined -match 'no usable Microsoft Edge|Edge executable not found|Edge was not found') {
      'Microsoft Edge could not be found on this computer, and the PDF step needs it.'
    } elseif ($combined -match 'Access is denied|UnauthorizedAccess') {
      'The PDF could not be written to that folder because access was denied.'
    } else {
      'The PDF could not be created.'
    }
    throw (New-Failure -Stage 'render' -Kind 'renderFailed' `
      -Message "$why The transcript itself finished successfully and was saved to $saved." `
      -Detail (($combined -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6) -join ' | '))
  }
  Send-Progress -Stage 'render' -StagePercent 100 -Message 'Writing PDF' -Force
}

# ============================================================== main loop ====

$script:PwshPath = (Get-Process -Id $PID).Path
if (-not $script:PwshPath) { $script:PwshPath = 'pwsh.exe' }

$allPaths = [System.Collections.Generic.List[string]]::new()
foreach ($p in $Path) { if ($p) { $allPaths.Add($p) } }
if ($AdditionalPaths) {
  foreach ($p in $AdditionalPaths) {
    # ignore anything that looks like a stray switch rather than a file
    if ($p -and -not $p.StartsWith('-')) { $allPaths.Add($p) }
    elseif ($p) { Write-Log "Ignoring unrecognised argument '$p'" 'WARN' }
  }
}
$files = [System.Collections.Generic.List[string]]::new()
foreach ($p in $allPaths) {
  try { $files.Add((Resolve-Path -LiteralPath $p -ErrorAction Stop).Path) } catch { $files.Add($p) }
}
$total = $files.Count
$batchWatch = [System.Diagnostics.Stopwatch]::StartNew()
$succeeded = 0; $failed = 0
$pdfPaths = [System.Collections.Generic.List[string]]::new()
$stopBatch = $false
$wasCancelled = $false

for ($i = 0; $i -lt $total; $i++) {
  if ($stopBatch) { break }
  $media = $files[$i]
  $leaf  = [System.IO.Path]::GetFileName($media)
  Start-Item -Name $leaf -Index ($i + 1) -Total $total

  $msg = if ($total -gt 1 -and $i -eq 0) { "Queued $total files" } else { 'Starting' }
  Send-Progress -Stage 'queued' -StagePercent 0 -Message $msg -Force

  # ASCII-only working directory: whisper.cpp and sherpa-onnx take narrow
  # paths, so they never see the user's non-ASCII filename
  $work = Join-Path $env:TEMP ("TranscribeIt\job-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $wav       = Join-Path $work 'audio.wav'
  $prefix    = Join-Path $work 'asr'
  $segsPath  = Join-Path $work 'speakers.json'
  $ctxPath   = Join-Path $work 'context.json'
  $turnsPath = Join-Path $work 'turns.json'

  # Per-item stage table. startup and init are process-level and measured once,
  # so they survive; carrying anything else over would report item 1's numbers
  # for a stage that item 2 skipped.
  foreach ($k in @($script:StageTimes.Keys)) {
    if ($k -notin @('startup', 'init')) { $script:StageTimes.Remove($k) }
  }

  try {
    if (Test-Cancelled) { throw [CancelledException]::new() }
    Write-Log "=== item $($i+1)/$total : $media"
    Assert-SourceReadable -MediaPath $media

    Start-Stage 'probe'
    $probe = Invoke-Probe -MediaPath $media
    Stop-Stage 'probe'
    $script:Item.Duration = $probe.DurationSeconds
    $script:Item.BaseRtf  = Get-BaseRtf
    $durMsg = if ($probe.DurationSeconds -gt 0) {
      $s = [int][math]::Round($probe.DurationSeconds)
      if ($s -ge 60) { "Read $([int][math]::Floor($s/60)) min $($s % 60) s of audio" } else { "Read $s s of audio" }
    } else { 'Read audio' }
    Send-Progress -Stage 'probe' -StagePercent 100 -Message $durMsg -Force

    Assert-DiskSpace -WorkDir $work -DurationSeconds $probe.DurationSeconds
    Start-Stage 'decode'
    $exact = Invoke-Decode -MediaPath $media -WavPath $wav -DurationSeconds $probe.DurationSeconds
    Stop-Stage 'decode'
    if ($exact -gt 0) { $script:Item.Duration = $exact }

    # Overlap: the diarizer only needs the WAV, which now exists. Launch it here
    # and collect it after transcription, so its wall clock is hidden behind the
    # transcribe stage instead of being added to it.
    $diarHandle = $null
    $asrThreads = 0
    if ($cfg.diarization.enabled -and $diarConcurrent) {
      $diarHandle = Start-DiarizeBackground -WavPath $wav -ThreadCount $diarConcThreads
      if ($null -ne $diarHandle) {
        Start-Stage 'diarizeWall'
        if ($asrConcThreads -gt 0) { $asrThreads = $asrConcThreads }
      }
    }

    Start-Stage 'transcribe'
    $asr = Invoke-Transcribe -WavPath $wav -OutPrefix $prefix -DurationSeconds $script:Item.Duration -ThreadCount $asrThreads
    Stop-Stage 'transcribe'

    Start-Stage 'diarize'
    $diarOk = $false
    if ($null -ne $diarHandle) {
      $diarOk = Complete-DiarizeBackground -Handle $diarHandle -SegmentsPath $segsPath
      Stop-Stage 'diarizeWall'
    }
    elseif ($cfg.diarization.enabled) {
      $diarOk = Invoke-Diarize -WavPath $wav -SegmentsPath $segsPath -ThreadCount $diarThreads
    }
    Stop-Stage 'diarize'
    if (-not $diarOk) { Send-Progress -Stage 'diarize' -StagePercent 100 -Message 'Identifying speakers' -Force }

    # elapsedSeconds is measured to the end of merge, because the renderer
    # must be handed a complete document and cannot be timed from inside it
    $elapsedNow = $script:Item.Watch.Elapsed.TotalSeconds
    $ctx = [ordered]@{
      source = [ordered]@{
        path            = $media
        fileName        = $leaf
        durationSeconds = [math]::Round($script:Item.Duration, 3)
        container       = $probe.Container
        audioCodec      = $probe.AudioCodec
        sizeBytes       = $probe.SizeBytes
      }
      processing = [ordered]@{
        processedAtUtc               = Get-Utc
        transcriptionModel           = [System.IO.Path]::GetFileNameWithoutExtension($modelName)
        language                     = $asr.Language
        languageAutoDetected         = ($language -eq 'auto')
        diarizationSegmentationModel = if ($diarOk) { [System.IO.Path]::GetFileNameWithoutExtension($segModel) } else { $null }
        diarizationEmbeddingModel    = if ($diarOk) { [System.IO.Path]::GetFileNameWithoutExtension($embModel) } else { $null }
        speakerCountMode             = if ($Speakers -gt 0) { 'fixed' } else { 'auto' }
        elapsedSeconds               = [math]::Round($elapsedNow, 2)
        realTimeFactor               = if ($elapsedNow -gt 0 -and $script:Item.Duration -gt 0) { [math]::Round($script:Item.Duration / $elapsedNow, 2) } else { $null }
        toolVersion                  = [string]$cfg.toolVersion
      }
    }
    [System.IO.File]::WriteAllText($ctxPath, ($ctx | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

    Start-Stage 'merge'
    Invoke-Merge -WhisperJson $asr.JsonPath -SegmentsPath $segsPath -ContextPath $ctxPath -TurnsPath $turnsPath
    Stop-Stage 'merge'

    $turns = Get-Content -LiteralPath $turnsPath -Raw | ConvertFrom-Json
    $warn = @()
    if ($null -ne $turns.PSObject.Properties['warnings'] -and $null -ne $turns.warnings) { $warn = @($turns.warnings) }
    $spkCount = @($turns.speakers).Count

    $destDir = if ($OutputDirectory) { $OutputDirectory } else { [System.IO.Path]::GetDirectoryName($media) }
    $pdfPath = Join-Path $destDir ([System.IO.Path]::GetFileNameWithoutExtension($media) + $cfg.output.pdfSuffix)

    if ($NoRender) {
      $kept = Save-RecoveredTranscript -TurnsPath $turnsPath -MediaPath $media
      Write-Log "NoRender: turns JSON at $kept"
      Send-Progress -Stage 'merge' -StagePercent 100 -Message 'Transcript complete' -Force
      $succeeded++
    } else {
      Start-Stage 'render'
      Invoke-Render -TurnsPath $turnsPath -PdfPath $pdfPath -MediaPath $media
      Stop-Stage 'render'
      if ($cfg.output.keepTurnsJsonBesidePdf) {
        Copy-Item -LiteralPath $turnsPath -Force -Destination `
          (Join-Path $destDir ([System.IO.Path]::GetFileNameWithoutExtension($media) + '.transcript.json'))
      }
      $pdfPaths.Add($pdfPath)
      $succeeded++
      Send-Event @{
        type = 'result'; pdfPath = $pdfPath
        turnsPath = if ($KeepIntermediate) { $turnsPath } else { $null }
        speakerCount = $spkCount
        elapsedSeconds = [math]::Round($script:Item.Watch.Elapsed.TotalSeconds, 1)
        warnings = $warn
        itemIndex = ($i + 1); itemTotal = $total; timestamp = Get-Utc
      }
    }
    Write-Log ("item done in {0:N1}s, {1} speakers, {2} warnings" -f $script:Item.Watch.Elapsed.TotalSeconds, $spkCount, $warn.Count)
  }
  catch [CancelledException] {
    $wasCancelled = $true
    $stopBatch = $true
    Write-Log 'Cancelled by user' 'WARN'
    Send-Progress -Stage 'cancelled' -StagePercent $null -Message 'Cancelled' -Force
  }
  catch {
    $failed++
    $ex = $_.Exception
    if ($ex -is [PipelineError]) {
      $stage = $ex.Stage; $userMsg = $ex.Message; $kind = $ex.Kind
      $installLevel = $ex.InstallLevel
      Write-Log "FAILED item $($i+1) [$kind] at $stage : $userMsg" 'ERROR'
      if ($ex.Detail) { Write-Log "  detail: $($ex.Detail)" 'ERROR' }
    } else {
      $stage = if ($script:Item.LastStage) { $script:Item.LastStage } else { 'probe' }
      $userMsg = 'Something went wrong while processing this file. The log file has the details.'
      $installLevel = $false
      Write-Log "FAILED item $($i+1) unexpected $($ex.GetType().FullName): $($ex.Message)" 'ERROR'
      Write-Log "  stack: $($_.ScriptStackTrace)" 'ERROR'
    }
    # a per-file problem in a batch is non-fatal so the batch continues; an
    # install-level problem would repeat on every remaining file
    $isFatal = $installLevel -or ($total -eq 1)
    Send-Event @{
      type = 'error'; stage = $stage; message = $userMsg
      logPath = $script:LogPath; fatal = $isFatal
      itemIndex = ($i + 1); itemTotal = $total; timestamp = Get-Utc
    }
    if ($isFatal) { $stopBatch = $true }
  }
  finally {
    # A failure anywhere between Start-DiarizeBackground and its collection would
    # otherwise leave sherpa-onnx running against a WAV we are about to delete.
    foreach ($bp in @($script:BgProcs)) {
      try { if (-not $bp.HasExited) { $bp.Kill($true); [void]$bp.WaitForExit(3000) } } catch { }
    }
    $script:BgProcs.Clear()
    Write-StageSummary
    if ($KeepIntermediate) { Write-Log "Intermediates retained: $work" }
    else { try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
  }
}

# batchComplete is the one and only FlashWindowEx trigger, so it must not be
# emitted after a fatal error (the UI is already in its terminal state).
if (-not $stopBatch -or $wasCancelled) {
  Send-Event @{
    type = 'batchComplete'
    succeeded = $succeeded; failed = $failed
    pdfPaths = $pdfPaths.ToArray()
    elapsedSeconds = [math]::Round($batchWatch.Elapsed.TotalSeconds, 1)
    timestamp = Get-Utc
  }
}

$script:Out.Flush()
Write-Log "batch done: $succeeded ok, $failed failed, cancelled=$wasCancelled, $([math]::Round($batchWatch.Elapsed.TotalSeconds,1))s"
if ($wasCancelled) { exit 3 }
exit ([int]($failed -gt 0))
