<#
.SYNOPSIS
    "Send to -> Heresay" entry point.

.DESCRIPTION
    A fallback route to the same pipeline, for machines where the Explorer context-menu
    verb does not appear.

    On this laptop, Explorer has corporate endpoint-security products
    hooked into it, and NO newly
    registered static verb renders - not under SystemFileAssociations, not under the
    file's ProgID, not under *\shell. Verified with five labelled probe verbs, none of
    which appeared, while an unhooked process building the same IContextMenu with the
    same flags shows all of them.

    Send To works differently: it is a folder of .lnk shortcuts under
    %APPDATA%\Microsoft\Windows\SendTo, not a registry verb, so it is not subject to
    whatever suppresses those.

    Explorer passes every selected file as a separate argument to a single invocation,
    which is the opposite of the context-menu verb (one invocation per file). So this
    script hands each path to the launcher individually and lets the launcher's existing
    queue and mutex serialise them - the behaviour Track C already proved under 12
    concurrent starts.

.PARAMETER Model
    Optional whisper model FILENAME (not a path) to transcribe with, e.g.
    ggml-small.en-q8_0.bin. Omitted means "whatever config.json says", which is the
    default-accuracy path and must stay byte-identical to what it was before this
    parameter existed.

    This is the single seam that makes one parameterised wrapper serve both Send To
    entries. The fast entry's .lnk is the same command line plus -Model <filename>;
    the default entry's .lnk is untouched.

.NOTES
    PositionalBinding = $false is LOad-BEARING, not tidiness. MEASURED: with a plain
    [CmdletBinding()], adding -Model makes it positional slot 0 whatever order the
    param block declares it in, so an ordinary Send To invocation with no -Model binds
    the FIRST SELECTED FILE to $Model and drops it from $Paths. Probed four ways:

      declared first,  no -Model, 2 files -> Model=C:\a.m4a  Paths=C:\b.m4a   WRONG
      declared last,   no -Model, 2 files -> Model=C:\a.m4a  Paths=C:\b.m4a   WRONG
      Position = 99,   no -Model, 1 file  -> Model=C:\only   Paths=(empty)    WRONG
      PositionalBinding=$false, no -Model -> Model=(empty)   Paths=both       right

    ValueFromRemainingArguments still collects every path with positional binding off,
    so the default route keeps working exactly as it did. Do not "simplify" this
    attribute away.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string] $Model,

    # Solo-recording mode: skip speaker separation entirely. Diarization is now the
    # stage that bounds the pipeline, and a one-voice recording has nothing for it to
    # separate. Measured 1.88x faster on a 40 s clip (57.3 s -> 30.4 s).
    [switch] $NoDiarization,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Paths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $PSScriptRoot
$launcher    = Join-Path $PSScriptRoot 'Transcribe-Entry.ps1'
$logDir      = Join-Path $installRoot 'logs'
$log         = Join-Path $logDir 'sendto.log'

# Initialise before use: Set-StrictMode -Version Latest throws on an unassigned
# variable, and this codebase has been bitten by exactly that four times.
$modelName = ''
if ($Model) { $modelName = $Model.Trim() }

function Write-SendToLog([string] $Message) {
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -LiteralPath $log -Value ('{0} [SendTo] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    } catch { }
}

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-SendToLog "launcher missing: $launcher"
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [System.Windows.Forms.MessageBox]::Show(
        "Heresay is not installed correctly - the launcher is missing:`n`n$launcher",
        'Heresay', 'OK', 'Error') | Out-Null
    exit 1
}

$files = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
if (-not $files.Count) {
    Write-SendToLog "invoked with no usable file arguments: $($Paths -join ' | ')"
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [System.Windows.Forms.MessageBox]::Show(
        'Select one or more audio or video files, then use Send to > Heresay.',
        'Heresay', 'OK', 'Information') | Out-Null
    exit 2
}

# --- fast-mode model, if one was asked for ------------------------------------
# Everything below is inert when -Model is absent, which is the default Send To
# entry. That entry's command line is unchanged, so its behaviour is unchanged.
if ($modelName) {
    # It goes onto a command line, so it must be a bare filename - not a path, not a
    # traversal. The engine resolves it against paths.modelDir itself.
    if ($modelName -match '[\\/]' -or $modelName -match '\.\.') {
        Write-SendToLog "rejected -Model '$modelName': must be a bare model filename, not a path."
        exit 3
    }

    # Pre-flight the model file. Without this each selected file would start, run to
    # the engine's model check and fail individually; one message up front is kinder.
    $modelDir = ''
    try {
        $cfgFile = Join-Path $PSScriptRoot 'config.json'
        if (-not (Test-Path -LiteralPath $cfgFile)) { $cfgFile = Join-Path $PSScriptRoot 'config.default.json' }
        if (Test-Path -LiteralPath $cfgFile) {
            $cfgObj = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfgObj.PSObject.Properties.Name -contains 'paths' -and
                $cfgObj.paths.PSObject.Properties.Name -contains 'modelDir') {
                $md = [string]$cfgObj.paths.modelDir -replace '/', '\'
                $modelDir = if ([System.IO.Path]::IsPathRooted($md)) { $md } else { Join-Path $installRoot $md }
            }
        }
    }
    catch { $modelDir = '' }   # unreadable config is the engine's problem to report, not ours

    if ($modelDir -and (Test-Path -LiteralPath $modelDir -PathType Container) -and
        -not (Test-Path -LiteralPath (Join-Path $modelDir $modelName) -PathType Leaf)) {
        Write-SendToLog "model '$modelName' not found in '$modelDir'; refusing to start."
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
        [System.Windows.Forms.MessageBox]::Show(
            "Fast mode needs the speech model '$modelName', which is not installed:`n`n$modelDir`n`n" +
            'Use "Heresay - Generate transcript (PDF)" instead, or re-run the installer.',
            'Heresay', 'OK', 'Error') | Out-Null
        exit 3
    }
}

Write-SendToLog ("invoked with {0} file(s){1}: {2}" -f
    $files.Count,
    $(if ($modelName) { " model=$modelName" } else { ' model=(config default)' }),
    (($files | Split-Path -Leaf) -join ', '))

# Hand each file to the launcher separately. The launcher owns batching: the first
# invocation wins a named mutex and becomes the worker, the rest enqueue and exit, so
# this produces exactly one progress window and one completion flash for the batch.
#
# The model rides with each file rather than with the batch on purpose: the launcher
# stores it on the QUEUE ITEM, so if a default-mode send and a fast-mode send land in
# the same batch, each file is still transcribed with the model it was sent with.
foreach ($f in $files) {
    $full = (Resolve-Path -LiteralPath $f).ProviderPath
    $launcherArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Path "{1}"' -f $launcher, $full
    if ($modelName) { $launcherArgs += ' -Model "{0}"' -f $modelName }
    # Solo mode. Inert when the switch is absent, so the existing entries are unchanged.
    if ($NoDiarization) { $launcherArgs += ' -NoDiarization' }
    try {
        Start-Process -FilePath 'C:\Program Files\PowerShell\7\pwsh.exe' `
            -ArgumentList $launcherArgs `
            -WindowStyle Hidden | Out-Null
        Write-SendToLog "queued: $full"
    }
    catch {
        Write-SendToLog "FAILED to queue '$full': $($_.Exception.Message)"
    }
}

exit 0
