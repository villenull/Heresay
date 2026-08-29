<#
.SYNOPSIS
    Exports a Word document to PDF beside itself. Run it directly - the "Save as PDF"
    Send To entry was retired, so this script has no menu entry of its own.

.DESCRIPTION
    Closes the last gap in the Word for the web transcription flow. Transcription runs in
    Word (upload -> transcribe -> add to document), and the remaining step is exporting a
    PDF, which is several clicks inside Word.

    This drives Word DESKTOP through its documented COM automation interface. That is a
    supported Microsoft API - no browser, no credentials, no page scraping - which is
    specifically why it is acceptable where automating Word for the web is not.

    Word for the web has no transcription API, so the transcribe and insert steps cannot
    be automated by any legitimate route. This automates only the export.

.PARAMETER Paths
    Documents to convert. Each path is passed as a separate argument. Anything that
    is not a Word document is skipped with a message rather than silently ignored.

.NOTES
    THE HAZARD THIS SCRIPT IS BUILT AROUND: if we quit or hide a Word instance the user is
    using, we hide or close THEIR open documents. That is data loss caused by a
    convenience script, so the whole design turns on one question:

        is this Word instance MINE, or the user's?

    The first version answered a DIFFERENT question - "was Word already running?" - on the
    common assumption that Word's COM server is single-instance and that
    `New-Object -ComObject Word.Application` therefore attaches to an existing Word.

    THAT ASSUMPTION IS FALSE HERE, AND IT WAS MEASURED, NOT REASONED. With a document
    already open, requesting an instance started a SECOND WINWORD process (pid 33628
    alongside the user's 32572). So "Word was already running" is not "this instance is
    the user's": the old logic protected the user's Word correctly and then leaked our own
    process on every single run, visible only as a stray WINWORD in Task Manager.

    So ownership is now established by FACT rather than inference: record the WINWORD pids
    before asking for an instance, look for a pid that appeared afterwards, and quit only
    that one. If no new pid appeared we genuinely did attach, and we leave it strictly
    alone - not hidden, not quit.

    Both properties are asserted by test\Test-SaveAsPdf.ps1, which covers the case where a
    document is already open. A fix that satisfies only one of them is the bug in one
    direction or the other, so do not "simplify" the pid diff into a boolean.

    Also note: `(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue).Id` THROWS
    under Set-StrictMode when nothing matches, which broke the common case of Word not
    being open. Enumerate with ForEach-Object instead.

    Documents are opened read-only with AddToRecentFiles disabled, so a converted file is
    never modified and the user's recent-documents list is not polluted.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Paths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Initialise before use - Set-StrictMode throws on unassigned $script: variables, and this
# codebase has been bitten by that five times.
$script:Made    = New-Object System.Collections.Generic.List[string]
$script:Skipped = New-Object System.Collections.Generic.List[string]
$script:Failed  = New-Object System.Collections.Generic.List[string]

$installRoot = Split-Path -Parent $PSScriptRoot
$logDir      = Join-Path $installRoot 'logs'
$log         = Join-Path $logDir 'save-as-pdf.log'

$wordExts = @('.docx', '.doc', '.docm', '.rtf', '.odt', '.txt')

function Write-PdfLog([string] $Message) {
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -LiteralPath $log -Value ('{0} [SaveAsPdf] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    } catch { }
}

function Show-Message([string] $Text, [string] $Icon = 'Information') {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [System.Windows.Forms.MessageBox]::Show($Text, 'Heresay - Save as PDF', 'OK', $Icon) | Out-Null
}

$files = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
if (-not $files.Count) {
    Show-Message ("No Word documents were passed. Run this script with the documents as arguments, for example:`n`n" +
                  'pwsh -File Save-AsPdf.ps1 "C:\path\report.docx"')
    exit 2
}

Write-PdfLog ("invoked with {0} file(s)" -f $files.Count)

# Which WINWORD processes existed BEFORE we asked for one? Recorded so we can tell our
# own instance apart from the user's afterwards.
#
# MEASURED, and it contradicts the usual assumption: with a document already open,
# New-Object -ComObject Word.Application started a SECOND WINWORD process (33628 beside
# the user's 32572) rather than attaching to the existing one. So "Word was already
# running" is NOT the same question as "is this instance mine". Deciding on the former
# protected the user's Word but leaked ours.
$preWordPids = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
Write-PdfLog ("WINWORD before: {0}" -f $(if ($preWordPids.Count) { $preWordPids -join ',' } else { '(none)' }))


$word = $null
try {
    try { $word = New-Object -ComObject Word.Application }
    catch {
        Write-PdfLog "could not start Word: $($_.Exception.Message)"
        Show-Message ("Could not start Microsoft Word, which this needs in order to export a PDF.`n`n" +
                      $_.Exception.Message) 'Error'
        exit 1
    }

    # Did we get our own process, or attach to the user's? Answered by looking for a PID
    # that was not there a moment ago.
    $ourWordPids = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id } | Where-Object { $preWordPids -notcontains $_ })
    $instanceIsOurs = $ourWordPids.Count -gt 0
    Write-PdfLog ("instance is ours: {0}{1}" -f $instanceIsOurs, $(if ($instanceIsOurs) { " (pid $($ourWordPids -join ','))" } else { ' (attached to an existing Word)' }))

    # Hide only our own instance. Hiding the user's Word would look exactly like a crash.
    if ($instanceIsOurs) {
        try { $word.Visible = $false } catch { }
    }
    try { $word.DisplayAlerts = 0 } catch { }   # wdAlertsNone

    foreach ($f in $files) {
        $src = (Resolve-Path -LiteralPath $f).ProviderPath
        $ext = [System.IO.Path]::GetExtension($src).ToLowerInvariant()

        if ($wordExts -notcontains $ext) {
            Write-PdfLog "skipped (not a Word document): $src"
            $script:Skipped.Add((Split-Path -Leaf $src))
            continue
        }

        $pdf = [System.IO.Path]::ChangeExtension($src, '.pdf')
        $doc = $null
        try {
            # ReadOnly + no recent-files entry: never modify the source, never pollute the
            # user's recent list. The remaining args are Word's positional defaults.
            $doc = $word.Documents.Open($src, $false, $true, $false)
            $doc.ExportAsFixedFormat($pdf, 17)   # 17 = wdExportFormatPDF
            if (-not (Test-Path -LiteralPath $pdf)) { throw 'Word reported success but produced no file' }
            $sizeKB = [math]::Round((Get-Item -LiteralPath $pdf).Length / 1KB)
            Write-PdfLog ("exported {0} -> {1} ({2} KB)" -f (Split-Path -Leaf $src), (Split-Path -Leaf $pdf), $sizeKB)
            $script:Made.Add($pdf)
        }
        catch {
            Write-PdfLog "FAILED '$src': $($_.Exception.Message)"
            $script:Failed.Add("$(Split-Path -Leaf $src): $($_.Exception.Message)")
        }
        finally {
            if ($doc) {
                try { $doc.Close(0) } catch { }   # 0 = wdDoNotSaveChanges
                try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($doc) } catch { }
            }
        }
    }
}
finally {
    if ($word) {
        # Quit ONLY an instance we created. Quitting an attached one closes the user's work.
        if ($instanceIsOurs) {
            # Ours, so quitting it cannot touch the user's documents. Logged rather than
            # swallowed: a silent Quit failure orphans a WINWORD process, and the only
            # symptom would be a stray entry in Task Manager.
            try { $word.Quit(0); Write-PdfLog 'closed our own Word instance.' }
            catch { Write-PdfLog "Quit failed, a Word process may be left running: $($_.Exception.Message)" }
        }
        else {
            Write-PdfLog "attached to the user's Word - not hidden, not quit."
        }
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) } catch { }
    }
}

if ($script:Made.Count) {
    try { Set-Clipboard -Value ($script:Made -join [Environment]::NewLine) } catch { }
}

# Silent on clean success, for the same reason as Compress-ForWord: this exists to remove
# clicks, so ending with a dialog to dismiss would defeat it. The PDF appearing beside the
# document is the signal. Anything unexpected still interrupts.
if ($script:Failed.Count -or $script:Skipped.Count) {
    $msg = ''
    if ($script:Made.Count)    { $msg += "Exported:`n" + (($script:Made | ForEach-Object { Split-Path -Leaf $_ }) -join "`n") + "`n`n" }
    if ($script:Skipped.Count) { $msg += "Not Word documents, skipped:`n" + ($script:Skipped -join "`n") + "`n`n" }
    if ($script:Failed.Count)  { $msg += "Failed:`n" + ($script:Failed -join "`n") + "`n`n" }
    $msg += "Log: $log"
    Show-Message $msg ($(if ($script:Failed.Count) { 'Warning' } else { 'Information' }))
}

exit $(if ($script:Failed.Count) { 1 } else { 0 })
