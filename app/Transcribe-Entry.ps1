<#
.SYNOPSIS
    Thin launcher invoked by the Explorer right-click verb. Serialises multi-select.

.DESCRIPTION
    Track C. This is the process Explorer starts, once per selected file.

    THE PROBLEM
    A classic (non-COM) shell verb is invoked ONCE PER SELECTED ITEM. Select five
    recordings and Explorer starts five copies of this script simultaneously. Five
    concurrent Whisper processes would thrash the machine into uselessness.

    THE SOLUTION
    Every invocation drops its file into a queue directory (one atomically-created
    file per item - no read/modify/write race is possible) and then races for a
    single named mutex:

      * Winner  -> becomes THE WORKER. Waits a short coalesce window so its siblings
                   can land in the queue, then drains the queue one file at a time.
      * Losers  -> already enqueued, so they simply exit. Cost: one pwsh start.

    A named System.Threading.Mutex is the primary lock because the OS releases it
    automatically when the owning process dies, so a crashed worker can never
    deadlock the queue. logs\queue.lock is a companion heartbeat file used for
    diagnostics and to recognise and report a hung (as opposed to dead) worker.

    BATCH OWNERSHIP
    Because this script owns the batch boundary, it also owns the batch-level view
    of the progress stream that Track E consumes:

      * itemIndex / itemTotal / itemName are rewritten on pass-through, so the UI can
        say "File 2 of 5" even though the engine only ever sees one file at a time.
      * overallPercent is rescaled from per-file 0-100 to batch 0-100 and clamped
        monotonically non-decreasing, as the frozen contract requires.
      * batchComplete from the engine is suppressed; this script emits exactly one
        at the end of the batch, so FlashWindowEx fires exactly once.

    Both behaviours can be turned off in config.json (queue.rewriteItemFields,
    queue.rescaleOverallPercent) if Track A takes over batch maths later.

.PARAMETER Path
    The media file, supplied by Explorer as %1.

.PARAMETER NoWorker
    Enqueue and exit without ever becoming the worker. Test hook.

.PARAMETER EngineScript
    Override the engine invoked per item. Test hook; defaults to app\Transcribe.ps1.

.PARAMETER Wait
    Do not return until the batch is drained. Test hook - Explorer never uses it.

.PARAMETER Model
    Optional whisper model filename for THIS file, e.g. ggml-small.en-q8_0.bin.
    An override and test hook: when -Model or -NoDiarization is given, the quality
    setting is bypassed and the command line alone decides, exactly as before the
    quality setting existed (a -Model with no -NoDiarization leaves speaker
    separation to config.json; a -NoDiarization with no -Model leaves the model to
    config.json). The Send To wrapper still uses these.

    Whatever is resolved is stored on the QUEUE ITEM rather than held in the worker,
    because the worker is whichever invocation happened to win the mutex - not
    necessarily the invocation that chose the model. Send five files in fast mode
    and two in default mode into the same coalesce window and the worker drains all
    seven; only a per-item model gives each file the model it was actually sent with.

    Declared after the switches on purpose. $Path is explicitly Position 0 and the
    remaining non-switch parameters take the positional slots after it in
    declaration order, so appending here cannot move an existing slot. Every caller
    (the Send To wrapper, the recorder and Register-ShellVerbs) passes -Path by name
    anyway.

.PARAMETER Quality
    Which of the three quality levels to transcribe at: fastest, moderate or
    thorough. The default 'auto' reads the level the home window saved to
    %LOCALAPPDATA%\TranscribeIt\settings.json, and when that file is missing or
    holds something unrecognised the level is 'fastest'. The level is mapped to a
    model and a speaker-separation switch by the table in the "quality resolution"
    section below (overridable from config.json -> quality), and the result is what
    goes on the queue item. This script is the ONLY place that mapping lives: the
    right-click verb and the conversation recorder both hand their file here with
    nothing but -Path, so a change to the saved setting reaches both paths at once.

.PARAMETER SettingsPath
    Where the home window's settings.json lives. Test hook; the default is the real
    per-user file and nothing that ships passes it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Path,

    [string] $InstallRoot,
    [string] $EngineScript,
    [string] $ProgressScript,
    [string] $CancelFile,
    [int]    $CoalesceMs = -1,
    [switch] $NoWorker,
    [switch] $NoProgressUi,
    [switch] $Wait,
    [string] $Model,
    [switch] $NoDiarization,
    [ValidateSet('fastest', 'moderate', 'thorough', 'auto')]
    [string] $Quality = 'auto',
    [string] $SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================== configuration ==

if (-not $InstallRoot -or -not $InstallRoot.Trim()) {
    $InstallRoot = Split-Path -Parent $PSScriptRoot   # app\ -> install root
}
# Normalise: the mutex name is derived from this path, so it must be canonical or two
# invocations of the same install could end up with two different locks.
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$AppDir   = Join-Path $InstallRoot 'app'
$LogDir   = Join-Path $InstallRoot 'logs'
$QueueDir = Join-Path $LogDir 'queue'
$ClaimDir = Join-Path $QueueDir 'processing'
$LockFile = Join-Path $LogDir 'queue.lock'
$StateFile = Join-Path $LogDir 'batch-state.json'
$EntryLog = Join-Path $LogDir 'entry.log'

# Cancellation seam. Track E's Progress.ps1 CREATES this sentinel when the user clicks
# Cancel; Track A's Transcribe.ps1 POLLS it (as -CancelSignalFile) and stops cleanly.
# Neither of them knows about the other, so wiring the same path into both is this
# script's job - it is the only process that launches them both. The default matches
# Progress.ps1's documented default so the two agree even if one is started by hand.
if (-not $CancelFile) {
    $CancelFile = if ($env:TRANSCRIBEIT_CANCEL_FILE) { $env:TRANSCRIBEIT_CANCEL_FILE }
                  else { Join-Path $env:LOCALAPPDATA 'TranscribeIt\run\cancel.flag' }
}

# Defaults; overridable from config.json -> queue.*
$cfg = [ordered]@{
    coalesceMs             = 700    # first wait for Explorer's sibling invocations
    coalesceSliceMs        = 350    # then keep extending while the queue is still growing
    maxCoalesceMs          = 8000   # cap on the total coalesce wait
    graceMs                = 1200   # re-check window before the worker gives up the lock
    hungWorkerSeconds      = 1800   # heartbeat older than this = report, do not double-run
    rewriteItemFields      = $true
    rescaleOverallPercent  = $true
    emitQueuedEvent        = $true
    keepEventLogs          = 20
    uiLingerSeconds        = 600    # a finished progress window nobody acknowledges
                                    # closes itself after this (0 = stay up for ever)
    uiIdleSeconds          = 1800   # ...and one that WAS acknowledged closes after this
                                    # long untouched, so a single click cannot buy a
                                    # window the right to outlive the session
}

# ======================================================= quality resolution ==
# THE ONE mapping from the home window's quality level to what the engine is told.
# Built-in so that it works on an upgraded install whose config.json predates the
# 'quality' section (user edits to config.json survive upgrades, so a new section
# never arrives there by itself); config.json -> quality.<level> may override either
# field of a level. 'fastest' is exactly what both entry paths hard-coded before the
# setting existed, which is why it is also the fallback when nothing was saved and
# the model that stands in when a chosen level's model file is not installed.
$QualityTable = [ordered]@{
    fastest  = @{ model = 'ggml-tiny.en-q8_0.bin';        diarization = $false; language = ''     }
    moderate = @{ model = 'ggml-base.en-q8_0.bin';        diarization = $true;  language = ''     }
    thorough = @{ model = 'ggml-large-v3-turbo-q4_0.bin'; diarization = $true;  language = 'auto' }
}
$QualityFallbackLevel = 'fastest'
if (-not $SettingsPath) { $SettingsPath = Join-Path $env:LOCALAPPDATA 'TranscribeIt\settings.json' }
# Where model files live, used only to pre-flight the resolved model so a level whose
# model is missing degrades to the fastest one instead of failing the item. Filled in
# from config.json -> paths.modelDir below, with the installed and development layouts
# as fallbacks; '' disables the check and leaves the missing file for the engine to report.
$ModelDir = ''

foreach ($d in @($LogDir, $QueueDir, $ClaimDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-EntryLog {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} [{1,-5}] pid={2} {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $PID, $Message
    # Several invocations write here at once; retry through the sharing violations.
    for ($i = 0; $i -lt 25; $i++) {
        try {
            $fs = [System.IO.File]::Open($EntryLog, 'Append', 'Write', 'Read')
            try {
                $sw = New-Object System.IO.StreamWriter($fs, [System.Text.UTF8Encoding]::new($false))
                $sw.WriteLine($line); $sw.Flush(); $sw.Dispose()
            }
            finally { $fs.Dispose() }
            return
        }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds (10 + $i * 4) }
        catch { return }   # never let logging break the run
    }
}

try {
    $cfgPath = Join-Path $AppDir 'config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $json = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'queue') {
            foreach ($k in @($cfg.Keys)) {
                if ($json.queue.PSObject.Properties.Name -contains $k) { $cfg[$k] = $json.queue.$k }
            }
        }
        # Per-level overrides of the quality table. Only the three known levels are
        # read (the home window can only save those), and a model must be a bare
        # filename because the engine resolves it against paths.modelDir itself.
        if ($json.PSObject.Properties.Name -contains 'quality') {
            foreach ($level in @($QualityTable.Keys)) {
                if ($json.quality.PSObject.Properties.Name -notcontains $level) { continue }
                $o = $json.quality.$level
                if ($o.PSObject.Properties.Name -contains 'model' -and $o.model) {
                    $m = ([string]$o.model).Trim()
                    if ($m -match '[\\/]' -or $m -match '\.\.') {
                        Write-EntryLog "config.json quality.$level.model '$m' is not a bare filename; keeping the built-in '$($QualityTable[$level]['model'])'." 'WARN'
                    }
                    else { $QualityTable[$level]['model'] = $m }
                }
                if ($o.PSObject.Properties.Name -contains 'diarization') { $QualityTable[$level]['diarization'] = [bool]$o.diarization }
            }
        }
        if ($json.PSObject.Properties.Name -contains 'paths' -and $json.paths.PSObject.Properties.Name -contains 'modelDir' -and $json.paths.modelDir) {
            $md = ([string]$json.paths.modelDir) -replace '/', '\'
            $ModelDir = if ([System.IO.Path]::IsPathRooted($md)) { $md } else { Join-Path $InstallRoot $md }
        }
    }
}
catch { Write-EntryLog "config.json unreadable ($($_.Exception.Message)); using built-in queue defaults." 'WARN' }

# The engine's Resolve-Vendor tries both tree layouts, so the pre-flight does the same.
$ModelDir = @($ModelDir, (Join-Path $InstallRoot 'models'), (Join-Path $InstallRoot 'vendor\models')) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Select-Object -First 1
if (-not $ModelDir) { $ModelDir = '' }

if ($CoalesceMs -ge 0) { $cfg['coalesceMs'] = $CoalesceMs }
if (-not $EngineScript)   { $EngineScript   = Join-Path $AppDir 'Transcribe.ps1' }
if (-not $ProgressScript) { $ProgressScript = Join-Path $AppDir 'Progress.ps1' }

# ==================================================================== helpers ==

function Get-PwshPath {
    foreach ($c in @(
        (Join-Path $PSHOME 'pwsh.exe'),
        'C:\Program Files\PowerShell\7\pwsh.exe',
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        # Portable per-user copy installed by installer\Bootstrap-Pwsh.ps1 when Program Files pwsh is absent (no admin on this fleet).
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    throw 'pwsh.exe not found.'
}

function Get-InstanceId {
    <# Mutex names cannot contain '\', and two installs must not share a lock. #>
    param([string] $Root)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant().TrimEnd('\'))
    $hash  = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16)
}

function Add-QueueItem {
    <# Atomic enqueue: write to a temp name, then Move (rename is atomic on NTFS) so a
       worker can never observe a half-written item. Name sorts by arrival. #>
    param([string] $FilePath, [string] $ModelName = '', [bool] $SkipDiarization = $false, [string] $Language = '')

    $seq  = '{0:D19}-{1:D5}-{2}' -f (Get-Date).ToUniversalTime().Ticks, $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $tmp  = Join-Path $QueueDir "$seq.tmp"
    $item = Join-Path $QueueDir "$seq.item"
    $payload = [ordered]@{
        path          = $FilePath
        enqueuedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        enqueuedBy    = $PID
        model         = $ModelName        # '' = engine default. Always written, so the shape is stable.
        noDiarization = $SkipDiarization  # solo-recording mode. Always written, same reason.
        language      = $Language         # '' = use config.json; 'auto' = multilingual (thorough level).
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($tmp, $payload, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $item)
    return $item
}

function Resolve-TranscriptionProfile {
    <# Decide the model and the speaker-separation switch for ONE enqueue. Pure: it
       touches nothing but its inputs and returns everything the caller should log,
       so a test can drive it without a queue, a mutex or a real settings file.

       Precedence, highest first:
         1. -Model / -NoDiarization on the command line. Either one present means
            the command line alone decides both fields, byte-for-byte the pre-quality
            behaviour, so the Send To wrapper and any test that passes them see no
            change at all.
         2. -Quality when it is not 'auto'.
         3. The level saved in settings.json.
         4. The fallback level ('fastest'), which is also what an unknown or
            unreadable saved value degrades to - noisily, never fatally, because a
            bad settings file must never cost an enqueue.
       The level is then mapped through $Table. If that model is not installed the
       fallback level's model stands in (speakers stay as the level said), because a
       transcript at the wrong speed beats no transcript with a puzzling error. #>
    param(
        [string] $ExplicitModel,
        [bool]   $ExplicitNoDiarization,
        [string] $RequestedQuality,
        [string] $SettingsFile,
        [string] $ModelDirectory,
        [System.Collections.IDictionary] $Table,
        [string] $FallbackLevel = 'fastest'
    )

    $warnings = New-Object System.Collections.Generic.List[string]

    if ($ExplicitModel -or $ExplicitNoDiarization) {
        $given = @()
        if ($ExplicitModel)         { $given += "-Model '$ExplicitModel'" }
        if ($ExplicitNoDiarization) { $given += '-NoDiarization' }
        return [pscustomobject]@{
            Model = $ExplicitModel; NoDiarization = $ExplicitNoDiarization; Quality = ''; Language = ''; Source = 'command line'
            Warnings = $warnings.ToArray()
            Summary  = ("quality setting bypassed: {0} given on the command line -> model '{1}', speakers {2}" -f ($given -join ' and '),
                $(if ($ExplicitModel) { $ExplicitModel } else { '(config default)' }),
                $(if ($ExplicitNoDiarization) { 'off' } else { 'per config.json' }))
        }
    }

    $level = ''; $source = ''
    if ($RequestedQuality -and $RequestedQuality -ne 'auto') {
        $level = $RequestedQuality.Trim().ToLowerInvariant(); $source = 'from -Quality'
    }
    elseif ($SettingsFile -and (Test-Path -LiteralPath $SettingsFile -PathType Leaf)) {
        try {
            $settings = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved = ''
            if ($settings -and $settings.PSObject.Properties.Name -contains 'quality') { $saved = ([string]$settings.quality).Trim().ToLowerInvariant() }
            if (-not $saved) {
                $warnings.Add("settings.json has no quality value; using '$FallbackLevel'.")
                $level = $FallbackLevel; $source = 'default: settings.json has no quality'
            }
            elseif ($Table.Contains($saved)) { $level = $saved; $source = 'from settings.json' }
            else {
                $warnings.Add("settings.json holds unknown quality '$saved'; using '$FallbackLevel'.")
                $level = $FallbackLevel; $source = "default: settings.json holds unknown '$saved'"
            }
        }
        catch {
            $warnings.Add("settings.json unreadable ($($_.Exception.Message)); using '$FallbackLevel'.")
            $level = $FallbackLevel; $source = 'default: settings.json unreadable'
        }
    }
    else { $level = $FallbackLevel; $source = 'default: no settings.json' }

    # -Quality is ValidateSet'd, so only a table that lost a level could get here.
    if (-not $Table.Contains($level)) {
        $warnings.Add("quality '$level' is not in the quality table; using '$FallbackLevel'.")
        $level = $FallbackLevel; $source = "default: '$level' not in table"
    }

    $model    = [string]$Table[$level]['model']
    $noDiar   = -not [bool]$Table[$level]['diarization']
    $language = if ($Table[$level].Contains('language')) { [string]$Table[$level]['language'] } else { '' }

    if ($ModelDirectory -and (Test-Path -LiteralPath $ModelDirectory -PathType Container) -and
        -not (Test-Path -LiteralPath (Join-Path $ModelDirectory $model) -PathType Leaf)) {
        $standIn = [string]$Table[$FallbackLevel]['model']
        if ($standIn -ne $model -and (Test-Path -LiteralPath (Join-Path $ModelDirectory $standIn) -PathType Leaf)) {
            $warnings.Add("model '$model' for quality '$level' is not installed in '$ModelDirectory'; falling back to '$standIn' so the file is still transcribed.")
            $model    = $standIn
            # fallback drops the language override so the engine falls back to config.json
            $language = ''
        }
        else {
            $warnings.Add("model '$model' for quality '$level' is not installed in '$ModelDirectory' and neither is the fallback; the engine will report the missing file.")
        }
    }

    return [pscustomobject]@{
        Model = $model; NoDiarization = $noDiar; Quality = $level; Language = $language; Source = $source
        Warnings = $warnings.ToArray()
        Summary  = "quality '$level' ($source) -> model '$model', speakers $(if ($noDiar) { 'off' } else { 'on' })$(if ($language) { ", language=$language" })"
    }
}

function Get-QueueItemFiles {
    if (-not (Test-Path -LiteralPath $QueueDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $QueueDir -Filter '*.item' -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Request-QueueItem {
    <# Move the item into processing\. The move is the claim: if two workers ever
       raced, exactly one Move succeeds and the other gets an exception. #>
    foreach ($f in Get-QueueItemFiles) {
        $dest = Join-Path $ClaimDir $f.Name
        try {
            [System.IO.File]::Move($f.FullName, $dest)
            $item = Get-Content -LiteralPath $dest -Raw -Encoding UTF8 | ConvertFrom-Json
            # Guarded, not $item.model: Set-StrictMode -Version Latest throws on a
            # missing property, and an item enqueued by the PREVIOUS build of this
            # script has no 'model' key. An upgrade must not poison an in-flight queue.
            $itemModel = ''
            if ($item.PSObject.Properties.Name -contains 'model' -and $item.model) { $itemModel = [string]$item.model }
            # Same guard, same reason: an item enqueued by the previous build has no
            # 'noDiarization' key, and an upgrade must not poison an in-flight queue.
            $itemNoDiar = $false
            if ($item.PSObject.Properties.Name -contains 'noDiarization' -and $item.noDiarization) { $itemNoDiar = [bool]$item.noDiarization }
            return [pscustomobject]@{ Path = $item.path; ClaimFile = $dest; EnqueuedUtc = $item.enqueuedUtc; Model = $itemModel; NoDiarization = $itemNoDiar }
        }
        catch { continue }   # someone else got it, or it vanished - try the next
    }
    return $null
}

function Remove-ClaimFile {
    param([string] $ClaimFile)
    try { if ($ClaimFile -and (Test-Path -LiteralPath $ClaimFile)) { Remove-Item -LiteralPath $ClaimFile -Force } } catch { }
}

function Test-ProcessAlive {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return $false }
    try { return $null -ne (Get-Process -Id $ProcessId -ErrorAction Stop) } catch { return $false }
}

function Write-LockFile {
    param([string] $BatchId)
    $payload = [ordered]@{
        workerPid    = $PID
        batchId      = $BatchId
        startedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        heartbeatUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress
    try { [System.IO.File]::WriteAllText($LockFile, $payload, [System.Text.UTF8Encoding]::new($false)) } catch { }
}

function Update-LockHeartbeat {
    param([string] $BatchId, [int] $ItemIndex, [int] $ItemTotal, [string] $ItemName)
    $payload = [ordered]@{
        workerPid    = $PID
        batchId      = $BatchId
        heartbeatUtc = (Get-Date).ToUniversalTime().ToString('o')
        itemIndex    = $ItemIndex
        itemTotal    = $ItemTotal
        itemName     = $ItemName
    } | ConvertTo-Json -Compress
    try { [System.IO.File]::WriteAllText($LockFile, $payload, [System.Text.UTF8Encoding]::new($false)) } catch { }
}

function Get-LockInfo {
    if (-not (Test-Path -LiteralPath $LockFile)) { return $null }
    try { return Get-Content -LiteralPath $LockFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-BatchState {
    <# Batch position, readable by Track E without parsing the event stream. #>
    param([hashtable] $State)
    try {
        $tmp = "$StateFile.tmp"
        [System.IO.File]::WriteAllText($tmp, ([pscustomobject]$State | ConvertTo-Json -Compress -Depth 6), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $StateFile, $true)
    }
    catch { }
}

# ------------------------------------------------------- progress event stream --

$script:EventWriter      = $null
$script:LastOverall      = 0.0
$script:SawBatchComplete = $false

function Open-EventLog {
    param([string] $EventLogPath)
    $fs = [System.IO.File]::Open($EventLogPath, 'Append', 'Write', 'Read')
    $sw = New-Object System.IO.StreamWriter($fs, [System.Text.UTF8Encoding]::new($false))
    $sw.AutoFlush = $true    # the contract demands events are flushed immediately
    $script:EventWriter = $sw
}

function Close-EventLog {
    if ($script:EventWriter) { try { $script:EventWriter.Flush(); $script:EventWriter.Dispose() } catch { }; $script:EventWriter = $null }
}

function Write-EventLine {
    param([string] $Line)
    if ($script:EventWriter) { try { $script:EventWriter.WriteLine($Line) } catch { } }
}

function Write-EventObject {
    param([hashtable] $Event)
    if (-not $Event.ContainsKey('timestamp')) { $Event['timestamp'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    Write-EventLine (([pscustomobject]$Event) | ConvertTo-Json -Compress -Depth 6)
}

function Convert-EngineLine {
    <# Rewrite one JSONL line from the engine into batch coordinates.
       Anything that does not parse is passed through untouched - never lose data. #>
    param(
        [string] $Line,
        [int]    $ItemIndex,
        [int]    $ItemTotal,
        [string] $ItemName,
        [int]    $CompletedItems
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $obj = $null
    try { $obj = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $Line }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) { return $Line }

    $names = $obj.PSObject.Properties.Name
    $type  = if ($names -contains 'type') { [string]$obj.type } else { '' }

    # We own the batch boundary, so we own the single terminal event.
    if ($type -eq 'batchComplete') { $script:SawBatchComplete = $true; return $null }

    if ($cfg['rewriteItemFields'] -and $type -in @('progress', 'result', 'error')) {
        $obj | Add-Member -NotePropertyName 'itemIndex' -NotePropertyValue $ItemIndex -Force
        $obj | Add-Member -NotePropertyName 'itemTotal' -NotePropertyValue $ItemTotal -Force
        if ($type -eq 'progress' -and $ItemName) {
            $obj | Add-Member -NotePropertyName 'itemName' -NotePropertyValue $ItemName -Force
        }
    }

    if ($cfg['rescaleOverallPercent'] -and $type -eq 'progress' -and $names -contains 'overallPercent') {
        $fileOverall = 0.0
        if ($null -ne $obj.overallPercent) { $fileOverall = [double]$obj.overallPercent }
        $batchOverall = (($CompletedItems * 100.0) + $fileOverall) / [Math]::Max(1, $ItemTotal)
        # The contract guarantees the UI a value that never goes backwards. A batch
        # that grows mid-flight would otherwise push it down, so clamp.
        if ($batchOverall -lt $script:LastOverall) { $batchOverall = $script:LastOverall }
        $script:LastOverall = [Math]::Min(100.0, $batchOverall)
        # Add-Member -Force rather than property assignment: ConvertFrom-Json may have
        # typed overallPercent as Int64, and assigning a double to it truncates or throws.
        $obj | Add-Member -NotePropertyName 'overallPercent' -NotePropertyValue ([Math]::Round($script:LastOverall, 2)) -Force
    }

    return ($obj | ConvertTo-Json -Compress -Depth 12)
}

# ------------------------------------------------------------ child invocation --

function Get-ScriptParameterNames {
    <# Track A and Track E are still being written, so discover what their scripts
       actually accept instead of guessing and crashing. #>
    param([string] $ScriptPath)
    try {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        $pb = $ast.ParamBlock
        if (-not $pb) { return @() }
        return @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    catch { return @() }
}

function Invoke-Engine {
    <# Run the engine for one file, streaming its JSONL stdout into the batch event
       log as it arrives. Returns a result summary. #>
    param(
        [string] $MediaPath,
        [int]    $ItemIndex,
        [int]    $ItemTotal,
        [int]    $CompletedItems,
        [string] $StdErrPath,
        [string] $ModelName = '',
        [bool]   $SkipDiarization = $false,
        [string] $LanguageOverride = ''
    )

    $itemName = Split-Path -Leaf $MediaPath
    $summary  = [ordered]@{ Path = $MediaPath; Ok = $false; PdfPath = $null; Error = $null; ExitCode = $null }

    if (-not (Test-Path -LiteralPath $EngineScript)) {
        $summary.Error = "Transcription engine not installed: $EngineScript"
        Write-EntryLog $summary.Error 'ERROR'
        Write-EventObject @{
            type = 'error'; stage = 'error'; message = 'TranscribeIt is not fully installed - the transcription engine is missing. Re-run the installer.'
            logPath = $EntryLog; fatal = $false; itemIndex = $ItemIndex; itemTotal = $ItemTotal
        }
        return [pscustomobject]$summary
    }

    $declared = Get-ScriptParameterNames -ScriptPath $EngineScript
    $argList  = New-Object System.Collections.Generic.List[string]
    $argList.Add('-NoProfile'); $argList.Add('-NonInteractive')
    $argList.Add('-ExecutionPolicy'); $argList.Add('Bypass')
    $argList.Add('-File'); $argList.Add($EngineScript)

    # -Path (or its likely aliases) is the only mandatory hand-off.
    $pathParam = @('Path', 'InputPath', 'File', 'Media', 'MediaPath') | Where-Object { $declared -contains $_ } | Select-Object -First 1
    if (-not $pathParam) { $pathParam = 'Path' }
    $argList.Add("-$pathParam"); $argList.Add($MediaPath)

    # Pass batch coordinates only if the engine actually declares them. Track A's
    # Transcribe.ps1 does not, which is exactly why Convert-EngineLine rewrites
    # itemIndex/itemTotal and rescales overallPercent on the way out.
    if ($declared -contains 'ItemIndex') { $argList.Add('-ItemIndex'); $argList.Add("$ItemIndex") }
    if ($declared -contains 'ItemTotal') { $argList.Add('-ItemTotal'); $argList.Add("$ItemTotal") }

    # Fast mode. Only when this item actually carried a model, and only if the engine
    # declares -Model - the same discover-do-not-guess rule as every other hand-off
    # here. With no model the command line is byte-for-byte what it was before, which
    # is what keeps the default Send To entry's behaviour identical.
    if ($ModelName -and ($declared -contains 'Model')) { $argList.Add('-Model'); $argList.Add($ModelName) }
    elseif ($ModelName) {
        Write-EntryLog "engine '$EngineScript' does not declare -Model; ignoring requested model '$ModelName' and using the config default." 'WARN'
    }

    # Solo mode. Same discover-do-not-guess rule. With the switch absent the command
    # line is byte-for-byte what it was before, which is what keeps the two existing
    # Send To entries' behaviour identical.
    if ($SkipDiarization -and ($declared -contains 'NoDiarization')) { $argList.Add('-NoDiarization') }
    elseif ($SkipDiarization) {
        Write-EntryLog "engine '$EngineScript' does not declare -NoDiarization; ignoring the request and leaving speaker separation on." 'WARN'
    }

    # Language override. 'auto' = multilingual (thorough level); '' = use config.json.
    if ($LanguageOverride -and ($declared -contains 'Language')) { $argList.Add('-Language'); $argList.Add($LanguageOverride) }
    elseif ($LanguageOverride) {
        Write-EntryLog "engine '$EngineScript' does not declare -Language; ignoring the override '$LanguageOverride' and using config.json." 'WARN'
    }

    # Cancellation and config, again only if declared.
    if ($declared -contains 'CancelSignalFile') { $argList.Add('-CancelSignalFile'); $argList.Add($CancelFile) }
    $cfgFile = Join-Path $AppDir 'config.json'
    if (($declared -contains 'ConfigPath') -and (Test-Path -LiteralPath $cfgFile)) {
        $argList.Add('-ConfigPath'); $argList.Add($cfgFile)
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = Get-PwshPath
    # A WorkingDirectory that does not exist makes Process.Start throw outright, which
    # would take down the whole batch. Fall back rather than assume the layout.
    $psi.WorkingDirectory       = @($AppDir, $InstallRoot, (Split-Path -Parent $MediaPath)) |
                                    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
                                    Select-Object -First 1
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }

    Write-EntryLog ("engine start: item {0}/{1} '{2}' model={3} speakers={4}{5}" -f $ItemIndex, $ItemTotal, $itemName,
        $(if ($ModelName) { $ModelName } else { '(config default)' }),
        $(if ($SkipDiarization) { 'off' } else { 'per config.json' }),
        $(if ($LanguageOverride) { " language=$LanguageOverride" } else { '' }))
    $proc = [System.Diagnostics.Process]::Start($psi)

    # Drain stderr concurrently. Reading stdout to completion first would deadlock
    # once the child fills the 64 KB stderr pipe buffer.
    $errTask = $proc.StandardError.ReadToEndAsync()

    while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
        $out = Convert-EngineLine -Line $line -ItemIndex $ItemIndex -ItemTotal $ItemTotal -ItemName $itemName -CompletedItems $CompletedItems
        if ($null -ne $out) {
            Write-EventLine $out
            try {
                $o = $out | ConvertFrom-Json -ErrorAction Stop
                if ($o.PSObject.Properties.Name -contains 'type') {
                    if ($o.type -eq 'result' -and $o.PSObject.Properties.Name -contains 'pdfPath') { $summary.PdfPath = $o.pdfPath }
                    if ($o.type -eq 'error'  -and $o.PSObject.Properties.Name -contains 'message') { $summary.Error   = $o.message }
                }
            }
            catch { }
        }
    }

    $proc.WaitForExit()
    $summary.ExitCode = $proc.ExitCode
    $stderr = ''
    try { $stderr = $errTask.GetAwaiter().GetResult() } catch { }
    if ($stderr) {
        try { [System.IO.File]::AppendAllText($StdErrPath, "=== $itemName ===`r`n$stderr`r`n", [System.Text.UTF8Encoding]::new($false)) } catch { }
    }

    $summary.Ok = ($proc.ExitCode -eq 0 -and -not $summary.Error)
    if (-not $summary.Ok -and -not $summary.Error) {
        $summary.Error = "Engine exited with code $($proc.ExitCode). See $StdErrPath"
        Write-EventObject @{
            type = 'error'; stage = 'error'; message = "Could not transcribe '$itemName'."
            logPath = $StdErrPath; fatal = $false; itemIndex = $ItemIndex; itemTotal = $ItemTotal
        }
    }
    Write-EntryLog "engine done : item $ItemIndex/$ItemTotal '$itemName' ok=$($summary.Ok) exit=$($summary.ExitCode)"
    return [pscustomobject]$summary
}

function Start-ProgressUi {
    param([string] $EventLogPath, [string] $BatchId)
    if ($NoProgressUi) { return $null }
    if (-not (Test-Path -LiteralPath $ProgressScript)) {
        Write-EntryLog "progress UI not installed ($ProgressScript); running headless." 'WARN'
        return $null
    }
    try {
        $declared = Get-ScriptParameterNames -ScriptPath $ProgressScript
        $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $ProgressScript)

        # Track E's Progress.ps1 documents -Path as "a .jsonl file to read and then tail",
        # which is exactly our batch event log.
        $evtParam = @('EventLog', 'EventFile', 'EventStream', 'JsonlPath', 'InputFile', 'Path') | Where-Object { $declared -contains $_ } | Select-Object -First 1
        if ($evtParam) { $argList += @("-$evtParam", $EventLogPath) }
        if ($declared -contains 'BatchStateFile') { $argList += @('-BatchStateFile', $StateFile) }
        elseif ($declared -contains 'BatchState')  { $argList += @('-BatchState', $StateFile) }
        if ($declared -contains 'BatchId') { $argList += @('-BatchId', $BatchId) }

        # Same sentinel path the engine is told to poll.
        if ($declared -contains 'CancelFile') { $argList += @('-CancelFile', $CancelFile) }
        # Our own PID, not the current engine child's: killing the worker tree stops the
        # whole batch, whereas a per-item engine PID goes stale after every file.
        if ($declared -contains 'EnginePid') { $argList += @('-EnginePid', "$PID") }
        # Same pid, second job: the UI's lifetime watchdog polls it so a finished window
        # cannot stay resident for ever holding ~300 MB. See Progress.ps1 section 0b.
        # Withheld when TRANSCRIBEIT_UI_LINGER_SECONDS is set: an explicit argument beats
        # the UI's own env fallback, so passing it unconditionally would make that variable
        # a dead knob on the one path that matters. Config is the default, env the override.
        if (($declared -contains 'LingerSeconds') -and
            [string]::IsNullOrWhiteSpace($env:TRANSCRIBEIT_UI_LINGER_SECONDS)) {
            $argList += @('-LingerSeconds', "$([int]$cfg['uiLingerSeconds'])")
        }
        if (($declared -contains 'AcknowledgedIdleSeconds') -and
            [string]::IsNullOrWhiteSpace($env:TRANSCRIBEIT_UI_IDLE_SECONDS)) {
            $argList += @('-AcknowledgedIdleSeconds', "$([int]$cfg['uiIdleSeconds'])")
        }

        if (-not $evtParam) { Write-EntryLog "progress UI declares no event-log parameter (saw: $($declared -join ',')); starting it bare." 'WARN' }

        # Start-Process joins ArgumentList without quoting, so quote anything with a space.
        $quoted = @($argList | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } })
        $p = Start-Process -FilePath (Get-PwshPath) -ArgumentList $quoted -WindowStyle Hidden -PassThru
        Write-EntryLog "progress UI started pid=$($p.Id) param=$evtParam"
        return $p
    }
    catch {
        Write-EntryLog "could not start progress UI: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Remove-OldEventLogs {
    try {
        $keep = [int]$cfg['keepEventLogs']
        if ($keep -le 0) { return }
        Get-ChildItem -LiteralPath $LogDir -Filter 'batch-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip $keep |
            ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force } catch { } }
    }
    catch { }
}

# ======================================================================= main ==

# --- validate the file Explorer handed us -------------------------------------
try {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}
catch {
    Write-EntryLog "rejected '$Path': not found." 'ERROR'
    exit 2
}
if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    Write-EntryLog "rejected '$resolved': not a file." 'ERROR'
    exit 2
}

# Initialise before use - Set-StrictMode -Version Latest throws on an unassigned
# variable, and an unbound [string] parameter is $null rather than ''.
$requestedModel = ''
if ($Model) { $requestedModel = $Model.Trim() }
if ($requestedModel -match '[\\/]' -or $requestedModel -match '\.\.') {
    Write-EntryLog "rejected -Model '$requestedModel': must be a bare model filename, not a path." 'ERROR'
    exit 2
}

# Resolve the model and speaker switch NOW, at enqueue time, and store the result on
# the item: the worker that eventually drains it may be a different invocation with a
# different command line, and the user changing the setting mid-batch must not
# retroactively change files already queued.
$decision = Resolve-TranscriptionProfile -ExplicitModel $requestedModel -ExplicitNoDiarization ([bool]$NoDiarization) `
    -RequestedQuality $Quality -SettingsFile $SettingsPath -ModelDirectory $ModelDir -Table $QualityTable -FallbackLevel $QualityFallbackLevel
foreach ($w in $decision.Warnings) { Write-EntryLog $w 'WARN' }
Write-EntryLog $decision.Summary

$itemFile = Add-QueueItem -FilePath $resolved -ModelName ([string]$decision.Model) -SkipDiarization ([bool]$decision.NoDiarization) -Language ([string]$decision.Language)
Write-EntryLog ("enqueued '{0}' as {1} (model={2}, speakers={3}{4})" -f $resolved, (Split-Path -Leaf $itemFile),
    $(if ($decision.Model) { $decision.Model } else { '(config default)' }),
    $(if ($decision.NoDiarization) { 'off' } else { 'on' }),
    $(if ($decision.Language) { ", language=$($decision.Language)" } else { '' }))

if ($NoWorker) { Write-EntryLog 'NoWorker set; exiting after enqueue.'; exit 0 }

# --- race for the worker role -------------------------------------------------
$mutexName = "Local\TranscribeIt.Worker.$(Get-InstanceId -Root $InstallRoot)"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
$owned = $false
try {
    $owned = $mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    # Previous worker died holding the lock. The OS handed ownership to us, which is
    # exactly the crashed-worker recovery path.
    $owned = $true
    Write-EntryLog 'recovered abandoned worker mutex (previous worker died); taking over the queue.' 'WARN'
}

if (-not $owned) {
    # Someone else is the worker. Our item is already queued, so just report and go.
    $lock = Get-LockInfo
    if ($lock -and $lock.PSObject.Properties.Name -contains 'heartbeatUtc') {
        $age = ((Get-Date).ToUniversalTime() - ([datetime]$lock.heartbeatUtc).ToUniversalTime()).TotalSeconds
        if ($age -gt [double]$cfg['hungWorkerSeconds']) {
            $aliveTxt = if (Test-ProcessAlive -ProcessId ([int]$lock.workerPid)) { 'still running' } else { 'gone' }
            Write-EntryLog ("worker pid=$($lock.workerPid) is $aliveTxt but its heartbeat is $([int]$age)s old. " +
                'Not starting a second worker (that would run two transcriptions at once). ' +
                "To recover: stop pid=$($lock.workerPid), then delete '$LockFile'.") 'ERROR'
        }
    }
    Write-EntryLog 'another invocation holds the worker lock; enqueued and exiting.'
    $mutex.Dispose()
    exit 0
}

# --- we are the worker --------------------------------------------------------
$batchId      = '{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 6))
$eventLogPath = Join-Path $LogDir "batch-$batchId.jsonl"
$stdErrPath   = Join-Path $LogDir "batch-$batchId.stderr.log"
$started      = Get-Date
$succeeded    = 0
$failed       = 0
$pdfPaths     = New-Object System.Collections.Generic.List[string]
$uiProc       = $null

# A stale lock file with no live owner means the previous worker died mid-batch.
$stale = Get-LockInfo
if ($stale -and $stale.PSObject.Properties.Name -contains 'workerPid') {
    if (-not (Test-ProcessAlive -ProcessId ([int]$stale.workerPid))) {
        Write-EntryLog "cleared stale queue.lock from dead worker pid=$($stale.workerPid) (batch $($stale.batchId))." 'WARN'
    }
}
# Items abandoned in processing\ by a dead worker go back on the queue.
try {
    foreach ($orphan in @(Get-ChildItem -LiteralPath $ClaimDir -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
        [System.IO.File]::Move($orphan.FullName, (Join-Path $QueueDir $orphan.Name))
        Write-EntryLog "requeued orphaned item $($orphan.Name) from a previous worker." 'WARN'
    }
}
catch { }

Write-LockFile -BatchId $batchId
Open-EventLog -EventLogPath $eventLogPath
Write-EntryLog "worker start: batch $batchId, event log $(Split-Path -Leaf $eventLogPath)"

# A cancel sentinel left over from a previous run would cancel this batch instantly.
try {
    $cancelDir = Split-Path -Parent $CancelFile
    if ($cancelDir -and -not (Test-Path -LiteralPath $cancelDir)) { New-Item -ItemType Directory -Path $cancelDir -Force | Out-Null }
    if (Test-Path -LiteralPath $CancelFile) {
        Remove-Item -LiteralPath $CancelFile -Force
        Write-EntryLog "removed a stale cancel sentinel at '$CancelFile'." 'WARN'
    }
}
catch { Write-EntryLog "could not prepare the cancel sentinel path '$CancelFile': $($_.Exception.Message)" 'WARN' }
$cancelled = $false

function Get-FirstQueuedName {
    $first = @(Get-QueueItemFiles) | Select-Object -First 1
    if (-not $first) { return '' }
    try { return Split-Path -Leaf ((Get-Content -LiteralPath $first.FullName -Raw | ConvertFrom-Json).path) } catch { return '' }
}

try {
    # Start the UI before coalescing, so the user gets feedback immediately rather than
    # staring at nothing for the length of the coalesce window.
    $uiProc = Start-ProgressUi -EventLogPath $eventLogPath -BatchId $batchId
    if ($cfg['emitQueuedEvent']) {
        $n0 = @(Get-QueueItemFiles).Count
        Write-EventObject @{
            type = 'progress'; stage = 'queued'; stagePercent = 0; overallPercent = 0; etaSeconds = $null
            message = 'Preparing'; itemIndex = 1; itemTotal = [Math]::Max(1, $n0); itemName = (Get-FirstQueuedName)
        }
    }

    # Adaptive coalesce window. Explorer is still starting our siblings, one process
    # per selected file, and with a large selection the last one can be seconds behind
    # the first. A fixed wait either stalls single-file runs or reports "File 1 of 9"
    # for a 12-file batch (both measured), so instead keep waiting while the queue
    # grows, and require two consecutive quiet slices before declaring the selection
    # complete - one quiet slice can fall in the gap between two sibling starts.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds ([int]$cfg['coalesceMs'])
    $pending    = @(Get-QueueItemFiles).Count
    $quiet      = 0
    $quietNeeded = 2
    while ($sw.ElapsedMilliseconds -lt [int]$cfg['maxCoalesceMs']) {
        Start-Sleep -Milliseconds ([int]$cfg['coalesceSliceMs'])
        $n = @(Get-QueueItemFiles).Count
        if ($n -eq $pending) {
            $quiet++
            if ($quiet -ge $quietNeeded) { break }
        }
        else { $quiet = 0; $pending = $n }
    }
    $sw.Stop()
    Write-EntryLog "coalesced $pending item(s) in $([int]$sw.ElapsedMilliseconds) ms"

    if ($cfg['emitQueuedEvent']) {
        Write-EventObject @{
            type = 'progress'; stage = 'queued'; stagePercent = 0; overallPercent = 0; etaSeconds = $null
            message = if ($pending -gt 1) { "Queued $pending files" } else { 'Queued 1 file' }
            itemIndex = 1; itemTotal = [Math]::Max(1, $pending); itemName = (Get-FirstQueuedName)
        }
    }

    $completed  = 0
    $graceUsed  = $false

    while ($true) {
        # Cancelling "file 2 of 5" has to mean the batch, not just this file - otherwise
        # the queue would march on to file 3 and the Cancel button would look broken.
        if (Test-Path -LiteralPath $CancelFile) {
            $cancelled = $true
            $dropped = 0
            foreach ($q in Get-QueueItemFiles) { try { Remove-Item -LiteralPath $q.FullName -Force; $dropped++ } catch { } }
            Write-EntryLog "cancel sentinel seen; abandoning the batch and discarding $dropped queued item(s)." 'WARN'
            Write-EventObject @{
                type = 'progress'; stage = 'cancelled'; stagePercent = $null
                overallPercent = $script:LastOverall; etaSeconds = $null
                message = if ($dropped -gt 0) { "Cancelled - $dropped file(s) not started" } else { 'Cancelled' }
                itemIndex = [Math]::Max(1, $completed); itemTotal = [Math]::Max(1, $completed + $dropped)
            }
            break
        }

        $claim = Request-QueueItem
        if (-not $claim) {
            if (-not $graceUsed) {
                # A straggler sibling may still be starting up. Look once more.
                $graceUsed = $true
                Start-Sleep -Milliseconds ([int]$cfg['graceMs'])
                continue
            }
            break
        }
        $graceUsed = $false   # activity resets the grace window

        $remaining = @(Get-QueueItemFiles).Count
        $itemIndex = $completed + 1
        $itemTotal = $completed + 1 + $remaining
        $itemName  = Split-Path -Leaf $claim.Path

        Update-LockHeartbeat -BatchId $batchId -ItemIndex $itemIndex -ItemTotal $itemTotal -ItemName $itemName
        Write-BatchState @{
            batchId = $batchId; workerPid = $PID; itemIndex = $itemIndex; itemTotal = $itemTotal
            itemName = $itemName; itemPath = $claim.Path; eventLog = $eventLogPath
            startedUtc = $started.ToUniversalTime().ToString('o'); state = 'running'
            succeeded = $succeeded; failed = $failed
        }

        # One item blowing up must cost that item only, never the rest of the batch.
        try {
            $claimModel  = ''
            $claimNoDiar = $false
            $claimLang   = ''
            if ($claim.PSObject.Properties.Name -contains 'Model' -and $claim.Model) { $claimModel = [string]$claim.Model }
            if ($claim.PSObject.Properties.Name -contains 'NoDiarization' -and $claim.NoDiarization) { $claimNoDiar = [bool]$claim.NoDiarization }
            if ($claim.PSObject.Properties.Name -contains 'Language' -and $claim.Language) { $claimLang = [string]$claim.Language }
            $r = Invoke-Engine -MediaPath $claim.Path -ItemIndex $itemIndex -ItemTotal $itemTotal -CompletedItems $completed -StdErrPath $stdErrPath -ModelName $claimModel -SkipDiarization $claimNoDiar -LanguageOverride $claimLang
        }
        catch {
            Write-EntryLog "item $itemIndex/$itemTotal '$itemName' failed to launch: $($_.Exception.Message)" 'ERROR'
            Write-EventObject @{
                type = 'error'; stage = 'error'; message = "Could not start transcription for '$itemName'."
                logPath = $EntryLog; fatal = $false; itemIndex = $itemIndex; itemTotal = $itemTotal
            }
            $r = [pscustomobject]@{ Path = $claim.Path; Ok = $false; PdfPath = $null; Error = $_.Exception.Message; ExitCode = $null }
        }
        if ($r.Ok) { $succeeded++ } else { $failed++ }
        if ($r.PdfPath) { $pdfPaths.Add([string]$r.PdfPath) }

        Remove-ClaimFile -ClaimFile $claim.ClaimFile
        $completed++
    }

    # Exactly one terminal event per batch -> exactly one FlashWindowEx.
    Write-EventObject @{
        type = 'batchComplete'; succeeded = $succeeded; failed = $failed
        pdfPaths = $pdfPaths.ToArray()
        elapsedSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
    }
    Write-BatchState @{
        batchId = $batchId; workerPid = $PID; itemIndex = $completed; itemTotal = $completed
        itemName = ''; itemPath = ''; eventLog = $eventLogPath
        startedUtc = $started.ToUniversalTime().ToString('o')
        state = if ($cancelled) { 'cancelled' } else { 'complete' }
        succeeded = $succeeded; failed = $failed
    }
    Write-EntryLog "worker done : batch $batchId succeeded=$succeeded failed=$failed cancelled=$cancelled elapsed=$([int]((Get-Date)-$started).TotalSeconds)s"
}
catch {
    Write-EntryLog "worker crashed: $($_.Exception.Message)" 'ERROR'
    Write-EventObject @{
        type = 'error'; stage = 'error'; message = 'TranscribeIt stopped unexpectedly.'
        logPath = $EntryLog; fatal = $true
    }
    Write-EventObject @{ type = 'batchComplete'; succeeded = $succeeded; failed = $failed + 1; pdfPaths = $pdfPaths.ToArray() }
    throw
}
finally {
    Close-EventLog
    try { if (Test-Path -LiteralPath $LockFile) { Remove-Item -LiteralPath $LockFile -Force } } catch { }
    # Consume the sentinel so the NEXT batch does not start out cancelled.
    try { if (Test-Path -LiteralPath $CancelFile) { Remove-Item -LiteralPath $CancelFile -Force } } catch { }
    Remove-OldEventLogs
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

# -Wait is a debugging switch; nothing that ships passes it. Note the interaction with
# the UI's lifetime watchdog: that watchdog only starts its linger countdown once THIS
# process is gone, so under -Wait (where this process is waiting on the window) the
# window stays up until the user closes it - the pre-watchdog behaviour, deliberately.
if ($Wait -and $uiProc) { try { $uiProc.WaitForExit() } catch { } }
exit 0
