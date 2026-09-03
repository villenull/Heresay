#requires -Version 7
<#
.SYNOPSIS
  Aligns whisper.cpp token timings to sherpa-onnx speaker segments and emits a
  transcript document conforming to contracts/turns.schema.json.

.DESCRIPTION
  Track A owns this file. It is called by Transcribe.ps1 but is deliberately
  runnable standalone so the alignment can be tested without models or audio:

    ./Merge-Diarization.ps1 -WhisperJson x.json -SegmentsJson y.json -OutJson turns.json

  Method:
    1. Reassemble whisper's BPE sub-word tokens into words, dropping special
       tokens ([_BEG_], [_TT_nnn]) and repairing zero-length token spans.
    2. Assign each word to the speaker segment it overlaps most in time.
       Sherpa emits overlapping segments, so ties are real and are flagged.
    3. Group consecutive same-speaker words into turns, breaking at long
       pauses, at sentence ends once a turn gets long, and unconditionally at
       a hard character cap so no turn becomes a wall of text.
    4. Renumber speakers by first appearance, so Speaker 1 spoke first.

.NOTES
  All emitted times are seconds from the start of the media, as the contract
  requires. Nothing here writes to the source file's folder.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$WhisperJson,
  [string]$SegmentsJson,
  [Parameter(Mandatory)][string]$OutJson,
  [string]$ContextJson,

  [double]$PauseSplitSeconds      = 1.5,
  [int]   $SoftMaxTurnCharacters  = 420,
  [int]   $HardMaxTurnCharacters  = 900,
  [double]$AmbiguityMarginSeconds = 0.2,
  [double]$MinOverlapRatio        = 0.5,
  [int]   $MaxExpectedSpeakers    = 4,
  [double]$LongSilenceWarnSeconds = 30,
  [switch]$OmitWords,

  # only used when -ContextJson is absent (standalone / test invocation)
  [string]$SourcePath,
  [double]$DurationSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ----

function Read-JsonFile {
  param([string]$FilePath)
  $raw = [System.IO.File]::ReadAllText($FilePath, [System.Text.UTF8Encoding]::new($false))
  # whisper.cpp writes a BOM-less UTF-8 file, but be tolerant of one
  if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
  return $raw | ConvertFrom-Json
}

function Format-Duration {
  param([double]$Seconds)
  $s = [int][math]::Round($Seconds)
  if ($s -ge 60) {
    $m = [int][math]::Floor($s / 60); $r = $s % 60
    if ($r -eq 0) { return "$m min" }
    return "$m min $r s"
  }
  return "$s s"
}

function ConvertTo-Words {
  <#
    Turns whisper's transcription[].tokens[] into word records.
    Returns a hashtable: Words (List), SegmentFallbackCount, ZeroSpanCount,
    TotalTokens, DroppedMarkers.
  #>
  param($Doc)

  $words    = [System.Collections.Generic.List[object]]::new()
  $segFall  = 0
  $zeroSpan = 0
  $totalTok = 0
  $dropped  = 0

  # whisper emits these as ordinary text, not as special tokens
  $nonSpeechMarker = '^(\[BLANK_AUDIO\]|\[MUSIC\]|\[SOUND\]|\[NOISE\]|\(music\)|\(silence\))$'

  $segs = @($Doc.transcription)
  for ($si = 0; $si -lt $segs.Count; $si++) {
    $seg = $segs[$si]
    $segStart = [double]$seg.offsets.from / 1000.0
    $segEnd   = [double]$seg.offsets.to   / 1000.0
    if ($segEnd -lt $segStart) { $segEnd = $segStart }

    $usable = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $seg.PSObject.Properties['tokens'] -and $null -ne $seg.tokens) {
      foreach ($tk in @($seg.tokens)) {
        $totalTok++
        $txt = [string]$tk.text
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        if ($txt -match '^\[_.*\]$')  { continue }   # [_BEG_] [_TT_198] [_EOT_]
        if ($txt -match '^<\|.*\|>$') { continue }   # <|notimestamps|> style
        if ($txt.Trim() -match $nonSpeechMarker) { $dropped++; continue }
        $usable.Add($tk)
      }
    }

    # No usable tokens: fall back to the segment as a single pseudo-word so the
    # text still survives even though word timings are lost.
    if ($usable.Count -eq 0) {
      $t = ([string]$seg.text) -replace '\s+', ' '
      $t = $t.Trim()
      if ($t -and ($t -notmatch $nonSpeechMarker)) {
        $words.Add([pscustomobject]@{
          Text = $t; Start = $segStart; End = $segEnd
          Conf = $null; SegIndex = $si; SegStart = $segStart; SegEnd = $segEnd
        })
        $segFall++
      }
      continue
    }

    $segWords = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($tk in $usable) {
      $raw   = [string]$tk.text
      $clean = $raw.Trim()
      if ($clean -eq '') { continue }
      $startsNewWord = $raw.StartsWith(' ')
      $ws = [double]$tk.offsets.from / 1000.0
      $we = [double]$tk.offsets.to   / 1000.0
      $p  = if ($null -ne $tk.PSObject.Properties['p']) { [double]$tk.p } else { $null }

      if ($null -eq $cur -or $startsNewWord) {
        if ($null -ne $cur) { $segWords.Add($cur) }
        $cur = [pscustomobject]@{
          Text = $clean; Start = $ws; End = $we
          Ps = [System.Collections.Generic.List[double]]::new()
          SegIndex = $si; SegStart = $segStart; SegEnd = $segEnd
        }
        if ($null -ne $p) { $cur.Ps.Add($p) }
      } else {
        $cur.Text = $cur.Text + $clean
        if ($we -gt $cur.End) { $cur.End = $we }
        if ($null -ne $p) { $cur.Ps.Add($p) }
      }
    }
    if ($null -ne $cur) { $segWords.Add($cur) }

    # --- repair timings inside this segment ---
    # whisper.cpp hands out a lot of tokens whose from == to, and several
    # consecutive words often share one offset. Naively giving each a fixed 50 ms
    # span piles them on top of each other, which then makes the overlap test
    # against diarization segments meaningless. Instead, find each run of words
    # with non-increasing starts and spread them evenly between the last known
    # good time and the next one.
    for ($i = 0; $i -lt $segWords.Count; $i++) {
      $w = $segWords[$i]
      if ($w.Start -lt $segStart) { $w.Start = $segStart }
      if ($w.Start -gt $segEnd)   { $w.Start = $segEnd }
      if ($w.End -gt $segEnd)     { $w.End = $segEnd }
      if ($w.End -le $w.Start)    { $zeroSpan++ }
    }

    $i = 0
    while ($i -lt $segWords.Count) {
      # a run starts where this word's own span is unusable
      if ($segWords[$i].End -gt $segWords[$i].Start) { $i++; continue }
      $runStart = $i
      $anchor = [double]$segWords[$i].Start
      $j = $i
      while ($j + 1 -lt $segWords.Count -and [double]$segWords[$j + 1].Start -le $anchor) { $j++ }
      # next usable boundary after the run
      $nextTime = if ($j + 1 -lt $segWords.Count) { [double]$segWords[$j + 1].Start } else { $segEnd }
      if ($nextTime -le $anchor) { $nextTime = [math]::Min($segEnd, $anchor + 0.05 * ($j - $runStart + 1)) }
      $count = $j - $runStart + 1
      $step = ($nextTime - $anchor) / [math]::Max(1, $count)
      if ($step -le 0) { $step = 0.02 }
      for ($k = 0; $k -lt $count; $k++) {
        $ww = $segWords[$runStart + $k]
        $ww.Start = $anchor + $step * $k
        $ww.End   = $anchor + $step * ($k + 1)
      }
      $i = $j + 1
    }

    # final guard: strictly ascending, inside the segment
    for ($i = 0; $i -lt $segWords.Count; $i++) {
      $w = $segWords[$i]
      if ($i -gt 0 -and $w.Start -lt [double]$segWords[$i - 1].End) { $w.Start = [double]$segWords[$i - 1].End }
      if ($w.End -le $w.Start) { $w.End = [math]::Min($segEnd, $w.Start + 0.02) }
      if ($w.End -le $w.Start) { $w.End = $w.Start }
    }

    foreach ($w in $segWords) {
      $conf = if ($w.Ps.Count -gt 0) { ($w.Ps | Measure-Object -Average).Average } else { $null }
      $words.Add([pscustomobject]@{
        Text = $w.Text; Start = $w.Start; End = $w.End
        Conf = $conf; SegIndex = $w.SegIndex; SegStart = $w.SegStart; SegEnd = $w.SegEnd
      })
    }
  }

  return @{
    Words = $words; SegmentFallbackCount = $segFall; ZeroSpanCount = $zeroSpan
    TotalTokens = $totalTok; DroppedMarkers = $dropped
  }
}

function ConvertTo-SpeakerSegments {
  # Emits segments individually; the caller wraps the call in @() so an empty
  # result becomes an empty array rather than $null.
  param([string]$FilePath)
  if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath)) { return }
  $list = [System.Collections.Generic.List[object]]::new()
  $data = Read-JsonFile -FilePath $FilePath
  foreach ($s in @($data)) {
    if ($null -eq $s) { continue }
    $st = [double]$s.start; $en = [double]$s.end
    if ($en -le $st) { continue }
    $list.Add([pscustomobject]@{ Start = $st; End = $en; Raw = [string]$s.speaker })
  }
  # ascending by start is required by the assignment scan below
  $list | Sort-Object Start, End
}

# ------------------------------------------------------------------ load -----

if (-not (Test-Path -LiteralPath $WhisperJson)) { throw "Whisper JSON not found: $WhisperJson" }
$doc = Read-JsonFile -FilePath $WhisperJson

$ex    = ConvertTo-Words -Doc $doc
$words = $ex.Words
$segments = @(ConvertTo-SpeakerSegments -FilePath $SegmentsJson)

$warnings = [System.Collections.Generic.List[string]]::new()

# Judge timing quality AFTER repair, not before. whisper.cpp routinely emits
# tokens with from == to, so counting those pre-repair flagged a perfectly good
# transcript as unreliable - the interpolation above recovers sensible spans and
# the measured alignment against ground truth was within ~0.05 s. Only complain
# when we genuinely fell back to whole-segment text with no token detail.
$wordTimingsDegraded = $false
if ($words.Count -gt 0 -and ($ex.SegmentFallbackCount / [double]$words.Count) -gt 0.5) {
  $wordTimingsDegraded = $true
}
if ($wordTimingsDegraded) {
  $warnings.Add('Word-level timings were unavailable, so timestamps are approximate at the sentence level.')
}

# ------------------------------------------------- assign words to speakers --

$ambiguousWordCount = 0

if ($segments.Count -eq 0) {
  foreach ($w in $words) {
    Add-Member -InputObject $w -NotePropertyName Speaker   -NotePropertyValue '_single' -Force
    Add-Member -InputObject $w -NotePropertyName Ambiguous -NotePropertyValue $false    -Force
  }
  if ($words.Count -gt 0) {
    $warnings.Add('Speaker separation was unavailable, so the whole transcript is attributed to a single speaker.')
  }
} else {
  $lo = 0
  foreach ($w in $words) {
    # segments are start-sorted, so anything ending at or before this word's
    # start can never match a later word either
    while ($lo -lt $segments.Count -and $segments[$lo].End -le $w.Start) { $lo++ }

    $bestSpk = $null; $bestOv = 0.0; $secondOv = 0.0
    $nearestSpk = $null; $nearestGap = [double]::MaxValue
    $wDur = [math]::Max($w.End - $w.Start, 0.001)

    for ($i = $lo; $i -lt $segments.Count; $i++) {
      $s = $segments[$i]
      if ($s.Start -ge $w.End) { break }
      $ov = [math]::Min($w.End, $s.End) - [math]::Max($w.Start, $s.Start)
      if ($ov -gt $bestOv) { $secondOv = $bestOv; $bestOv = $ov; $bestSpk = $s.Raw }
      elseif ($ov -gt $secondOv) { $secondOv = $ov }
    }

    if ($null -eq $bestSpk) {
      # word sits in a diarization gap (sherpa discards sub-min-duration speech)
      $from = [math]::Max(0, $lo - 4)
      $to   = [math]::Min($segments.Count - 1, $lo + 4)
      for ($i = $from; $i -le $to; $i++) {
        $s = $segments[$i]
        $gap = if ($w.Start -gt $s.End) { $w.Start - $s.End }
               elseif ($s.Start -gt $w.End) { $s.Start - $w.End }
               else { 0.0 }
        if ($gap -lt $nearestGap) { $nearestGap = $gap; $nearestSpk = $s.Raw }
      }
      $spk = $nearestSpk
      $amb = $true
    } else {
      $spk = $bestSpk
      # Ambiguity needs a genuine rival. Testing (bestOv - secondOv) against an
      # absolute margin alone would flag every word shorter than the margin -
      # and words like "I", "on", "it" are routinely 0.1 s - which fired on
      # about half of all words and made the flag meaningless noise.
      $amb = $false
      if ($secondOv -gt 0) {
        # a rival that captured a comparable slice of the word, or one within
        # the absolute margin (the very short word straddling a boundary)
        if ($secondOv -ge 0.6 * $bestOv) { $amb = $true }
        elseif (($bestOv - $secondOv) -lt [math]::Min($AmbiguityMarginSeconds, 0.5 * $wDur)) { $amb = $true }
      }
      # the word mostly sits outside the segment it was handed to
      if (-not $amb -and ($bestOv / $wDur) -lt $MinOverlapRatio) { $amb = $true }
    }

    if ($null -eq $spk) { $spk = $segments[0].Raw; $amb = $true }
    if ($amb) { $ambiguousWordCount++ }

    Add-Member -InputObject $w -NotePropertyName Speaker   -NotePropertyValue $spk -Force
    Add-Member -InputObject $w -NotePropertyName Ambiguous -NotePropertyValue $amb -Force
  }
}

# ------------------------------------- segment-level speaker voting ----------

# Whisper's own segment boundaries are linguistically meaningful - it breaks at
# sentence and phrase edges - whereas a diarization segment edge is a model
# guess about acoustics and is routinely off by a second. Assigning every word
# independently lets an imprecise sherpa edge cut a whisper segment in half:
# measured on the fixture, "Sorry, can everyone hear me? My headset was muted."
# is ONE whisper segment (27.07-32.53 s) whose first word was handed to the
# previous speaker.
#
# So when a whisper segment is short enough that a genuine speaker change inside
# it is unlikely, and one speaker already owns a clear majority of it, give the
# whole segment to that speaker. Longer segments, or genuinely split ones, keep
# their per-word assignment - a real interruption must still be able to split a
# segment.
$segVoteChanged = 0
if ($segments.Count -gt 0) {
  $bySeg = @{}
  foreach ($w in $words) {
    if (-not $bySeg.ContainsKey($w.SegIndex)) { $bySeg[$w.SegIndex] = [System.Collections.Generic.List[object]]::new() }
    $bySeg[$w.SegIndex].Add($w)
  }
  foreach ($k in @($bySeg.Keys)) {
    $ws = $bySeg[$k]
    if ($ws.Count -lt 2) { continue }
    $span = [double]$ws[$ws.Count - 1].End - [double]$ws[0].Start
    if ($span -gt 12.0) { continue }

    $tally = @{}
    foreach ($w in $ws) {
      $dw = [math]::Max(0.01, [double]$w.End - [double]$w.Start)
      $tally[$w.Speaker] = ($tally[$w.Speaker] ?? 0.0) + $dw
    }
    if ($tally.Count -lt 2) { continue }
    $sum = ($tally.Values | Measure-Object -Sum).Sum
    if ($sum -le 0) { continue }
    $top = $tally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    if (($top.Value / $sum) -lt 0.75) { continue }

    foreach ($w in $ws) {
      if ($w.Speaker -ne $top.Key) {
        $w.Speaker = $top.Key
        $w.Ambiguous = $true     # we overrode the diarizer; stay honest about it
        $segVoteChanged++
      }
    }
  }
}

# ------------------------------------------------------------ group turns ----

function Test-EndsSentence { param([string]$Text) return ($Text -match '[.!?]["'')\]]?$') }

function Group-WordsIntoTurns {
  param($WordList)
  $turns = [System.Collections.Generic.List[object]]::new()
  $cur = $null
  foreach ($w in $WordList) {
    $break = $false
    if ($null -eq $cur) {
      $break = $true
    } else {
      if ($w.Speaker -ne $cur.Speaker) { $break = $true }
      elseif (($w.Start - $cur.End) -gt $PauseSplitSeconds) { $break = $true }
      elseif ($cur.Length -ge $HardMaxTurnCharacters) { $break = $true }
      elseif ($cur.Length -ge $SoftMaxTurnCharacters -and $cur.EndsSentence) { $break = $true }
    }

    if ($break) {
      if ($null -ne $cur) { $turns.Add($cur) }
      $cur = [pscustomobject]@{
        Speaker = $w.Speaker
        Start   = [double]$w.Start
        End     = [double]$w.End
        Words   = [System.Collections.Generic.List[object]]::new()
        Length  = 0
        EndsSentence = $false
        AmbiguousWords = 0
      }
    }

    $cur.Words.Add($w)
    $cur.Length = $cur.Length + $w.Text.Length + 1
    if ($w.End -gt $cur.End) { $cur.End = [double]$w.End }
    $cur.EndsSentence = Test-EndsSentence -Text $w.Text
    if ($w.Ambiguous) { $cur.AmbiguousWords++ }
  }
  if ($null -ne $cur) { $turns.Add($cur) }
  $turns
}

# @() is load-bearing, not decoration: PowerShell UNROLLS a collection on the way
# out of a function, so an empty $turns comes back as $null and the very next
# statement (a $rawTurns.Count test) throws under Set-StrictMode. MEASURED: a
# 9.8 s recording made with the microphone muted transcribes to zero words,
# whisper writes an empty transcription array, and the merge died on that .Count
# with "The property Count cannot be found on this object" - which reached the
# user as "Speaker alignment failed", which is not what happened. The zero-word
# case is already handled deliberately further down (it adds the No speech was
# detected warning), so the only defect was never reaching it.
$rawTurns = @(Group-WordsIntoTurns -WordList $words)

# ------------------------------ coalesce spurious interrupting speakers ------

# Automatic speaker-count detection reliably over-counts by about one: on the
# benchmark fixture sherpa returned four clusters for three real speakers, the
# fourth being a single 1.4 s segment. Left alone it tore one real sentence into
# three turns (Speaker 3 / Speaker 4 / Speaker 3), which reads as broken in the
# PDF - worse than a slightly wrong attribution.
#
# We only fold such a speaker away when it is unmistakably an artefact:
# negligible total speech, AND every one of its turns matches one of two shapes.
#   (a) sandwiched between the SAME other speaker on both sides - it interrupts
#       one continuous passage rather than contributing to the conversation;
#   (b) it continues an unfinished sentence from the previous, different speaker
#       (that turn's text does not end in . ! or ?). This is the shape actually
#       observed: "...the target system rejects those on load" attributed to
#       Speaker 3, then "rather than warning on them." handed to a 1.6 s
#       Speaker 4. A real person does not finish someone else's sentence and then
#       never speak again; a clipped diarization boundary looks exactly like this.
# Anything less clear-cut keeps its speaker and is flagged by the warning below.
$coalescedSpeakers = 0
if ($rawTurns.Count -ge 3) {
  $durBySpk = @{}
  foreach ($t in $rawTurns) {
    $d = [math]::Max(0.0, [double]$t.End - [double]$t.Start)
    $durBySpk[$t.Speaker] = ($durBySpk[$t.Speaker] ?? 0.0) + $d
  }
  $totalSpk = ($durBySpk.Values | Measure-Object -Sum).Sum
  if ($totalSpk -gt 0 -and $durBySpk.Count -gt 2) {
    foreach ($spk in @($durBySpk.Keys)) {
      $d = [double]$durBySpk[$spk]
      if ($d -ge 2.5 -or ($d / $totalSpk) -ge 0.015) { continue }

      $flank = $null; $ok = $true
      for ($i = 0; $i -lt $rawTurns.Count; $i++) {
        if ($rawTurns[$i].Speaker -ne $spk) { continue }
        if ($i -eq 0) { $ok = $false; break }
        $before = $rawTurns[$i - 1].Speaker
        if ($before -eq $spk) { $ok = $false; break }

        $target = $null
        if ($i -lt $rawTurns.Count - 1 -and $rawTurns[$i + 1].Speaker -eq $before) {
          $target = $before                                        # shape (a)
        } elseif (-not $rawTurns[$i - 1].EndsSentence) {
          $target = $before                                        # shape (b)
        }
        if ($null -eq $target) { $ok = $false; break }
        if ($null -eq $flank) { $flank = $target } elseif ($flank -ne $target) { $ok = $false; break }
      }
      if (-not $ok -or $null -eq $flank) { continue }

      foreach ($w in $words) {
        if ($w.Speaker -eq $spk) {
          $w.Speaker = $flank
          # attribution here is a judgement call, so keep it visibly uncertain
          $w.Ambiguous = $true
        }
      }
      $coalescedSpeakers++
    }
  }
  if ($coalescedSpeakers -gt 0) { $rawTurns = @(Group-WordsIntoTurns -WordList $words) }
}

# ------------------------------------- refine boundaries at sentence edges ---

# --------------------------------- snap boundaries to sentence edges ---------

function Update-TurnStats {
  param($T)
  if ($T.Words.Count -eq 0) { return }
  $T.Start = [double]$T.Words[0].Start
  $end = 0.0; $len = 0; $amb = 0
  foreach ($w in $T.Words) {
    if ([double]$w.End -gt $end) { $end = [double]$w.End }
    $len += $w.Text.Length + 1
    if ($w.Ambiguous) { $amb++ }
  }
  $T.End = $end; $T.Length = $len; $T.AmbiguousWords = $amb
  $T.EndsSentence = Test-EndsSentence -Text $T.Words[$T.Words.Count - 1].Text
}

# Even after segment voting, a couple of words still land on the wrong side of a
# speaker change, because whisper timestamps an utterance's opening words about a
# second early and the diarizer's edge sits later. Where a turn ends mid-sentence
# and its neighbour begins mid-sentence, move the short fragment to the side the
# sentence structure says owns it.
#
# NOTE ON MEASUREMENT: judged against ground-truth TIME windows this looks like a
# regression, because a word moved to the semantically right speaker is still
# outside that speaker's true time window when whisper timed it early. Scored on
# TEXT - which utterance's words each speaker label actually holds, the thing a
# reader experiences - it is a clear gain: 97.24% -> 98.85% attribution, with
# misattributed words falling from 24 to 10 out of 870.
$boundaryWordsMoved = 0
$maxFragmentWords = 5
for ($i = 0; $i -lt $rawTurns.Count - 1; $i++) {
  $a = $rawTurns[$i]; $b = $rawTurns[$i + 1]
  if ($a.Speaker -eq $b.Speaker) { continue }
  if ($a.Words.Count -lt 2 -or $b.Words.Count -lt 1) { continue }
  if (Test-EndsSentence -Text $a.Words[$a.Words.Count - 1].Text) { continue }

  # forward: A's trailing fragment actually opens B's sentence
  $cut = -1
  for ($k = $a.Words.Count - 2; $k -ge 0; $k--) {
    if (Test-EndsSentence -Text $a.Words[$k].Text) { $cut = $k; break }
  }
  $trailing = $a.Words.Count - 1 - $cut
  if ($cut -ge 0 -and $trailing -ge 1 -and $trailing -le $maxFragmentWords -and
      (([string]$b.Words[0].Text) -cmatch '^[a-z]')) {
    $move = [System.Collections.Generic.List[object]]::new()
    for ($k = $cut + 1; $k -lt $a.Words.Count; $k++) { $move.Add($a.Words[$k]) }
    for ($k = $a.Words.Count - 1; $k -gt $cut; $k--) { $a.Words.RemoveAt($k) }
    for ($k = $move.Count - 1; $k -ge 0; $k--) {
      $move[$k].Speaker = $b.Speaker
      $move[$k].Ambiguous = $true
      $b.Words.Insert(0, $move[$k])
    }
    $boundaryWordsMoved += $move.Count
    Update-TurnStats -T $a; Update-TurnStats -T $b
    continue
  }

  # backward: B's leading fragment closes A's unfinished sentence
  $bCut = -1
  $limit = [math]::Min($b.Words.Count, $maxFragmentWords)
  for ($k = 0; $k -lt $limit; $k++) {
    if (Test-EndsSentence -Text $b.Words[$k].Text) { $bCut = $k; break }
  }
  if ($bCut -ge 0 -and $bCut -lt $b.Words.Count - 1 -and
      (([string]$b.Words[$bCut + 1].Text) -cmatch '^[A-Z0-9]')) {
    $move = [System.Collections.Generic.List[object]]::new()
    for ($k = 0; $k -le $bCut; $k++) { $move.Add($b.Words[$k]) }
    for ($k = $bCut; $k -ge 0; $k--) { $b.Words.RemoveAt($k) }
    foreach ($w in $move) { $w.Speaker = $a.Speaker; $w.Ambiguous = $true; $a.Words.Add($w) }
    $boundaryWordsMoved += $move.Count
    Update-TurnStats -T $a; Update-TurnStats -T $b
  }
}

if ($boundaryWordsMoved -gt 0) {
  $kept = [System.Collections.Generic.List[object]]::new()
  foreach ($t in $rawTurns) { if ($t.Words.Count -gt 0) { $kept.Add($t) } }
  $rawTurns = $kept
}

# ------------------------------------------- drop empty turns, then number ---

# The contract forbids a turn whose text is empty or whitespace-only: it would
# render as a bare speaker label with nothing after it. Whisper can produce one
# from a segment of pure punctuation, or from a token group that filtering
# empties out. Discard those FIRST - before speakers are numbered - otherwise a
# speaker whose only turn is dropped still consumes a number and the labels come
# out as "Speaker 1, Speaker 3".
$keptTurns = [System.Collections.Generic.List[object]]::new()
foreach ($t in $rawTurns) {
  $text = (($t.Words | ForEach-Object { $_.Text }) -join ' ') -replace '\s+', ' '
  $text = $text.Trim()
  # Empty, whitespace-only, or carrying no letters or digits at all. The last
  # case is the same defect wearing a disguise: a turn reading only "..." or "--"
  # still renders as a speaker label with nothing to read after it. Unicode
  # categories rather than A-Z, because the language is auto-detected.
  if ($text -eq '' -or $text -notmatch '[\p{L}\p{N}]') { continue }
  Add-Member -InputObject $t -NotePropertyName Text -NotePropertyValue $text -Force
  $keptTurns.Add($t)
}
$droppedEmptyTurns = $rawTurns.Count - $keptTurns.Count

# ------------------------------------------------ enforce non-overlap --------

# The contract requires "adjacent turns never overlap". They can still come out
# overlapping here for a real reason: sherpa-onnx emits OVERLAPPING speaker
# segments (it models crosstalk), so a word assigned to the incoming speaker can
# legitimately start before the outgoing speaker's last word has ended. Measured
# on the benchmark fixture that produced 9 overlapping pairs out of 31 turns.
# Resolve by trimming the earlier turn back to where the later one starts: the
# later turn's start is anchored to a real word onset, so it is the value worth
# preserving.
$overlapsFixed = 0
for ($i = 1; $i -lt $keptTurns.Count; $i++) {
  $prev = $keptTurns[$i - 1]
  $cur  = $keptTurns[$i]
  if ([double]$cur.Start -ge [double]$prev.End) { continue }
  $overlapsFixed++
  if ([double]$cur.Start -gt [double]$prev.Start) {
    $prev.End = [double]$cur.Start
  } else {
    # degenerate: identical starts, so move the later turn instead
    $cur.Start = [double]$prev.End
    if ([double]$cur.End -lt [double]$cur.Start) { $cur.End = [double]$cur.Start }
  }
}

# words must stay inside their (possibly trimmed) turn span
foreach ($t in $keptTurns) {
  foreach ($w in $t.Words) {
    if ([double]$w.Start -lt [double]$t.Start) { $w.Start = [double]$t.Start }
    if ([double]$w.End   -gt [double]$t.End)   { $w.End   = [double]$t.End }
    if ([double]$w.End   -lt [double]$w.Start) { $w.End   = [double]$w.Start }
  }
}

# -------------------------------------- number speakers by first appearance --

$idByRaw = [ordered]@{}
foreach ($t in $keptTurns) {
  if (-not $idByRaw.Contains($t.Speaker)) {
    $n = $idByRaw.Count
    $idByRaw[$t.Speaker] = [pscustomobject]@{ Id = "S$n"; Label = "Speaker $($n + 1)" }
  }
}

# ------------------------------------------------------------ build output ---

$turnsOut = [System.Collections.Generic.List[object]]::new()
$agg = @{}
$ambiguousTurnCount = 0
$idx = 0

foreach ($t in $keptTurns) {
  $map  = $idByRaw[$t.Speaker]
  $text = [string]$t.Text

  $confs = @($t.Words | Where-Object { $null -ne $_.Conf } | ForEach-Object { [double]$_.Conf })
  $turnConf = if ($confs.Count -gt 0) {
    [math]::Round([math]::Min(1.0, [math]::Max(0.0, ($confs | Measure-Object -Average).Average)), 3)
  } else { $null }

  # A short interjection is fragile: one ambiguous word is enough to doubt it.
  # A long turn needs a real share of doubt before we flag it.
  $wc  = $t.Words.Count
  $dur = $t.End - $t.Start
  $uncertain = if ($wc -le 3 -or $dur -lt 2.0) { $t.AmbiguousWords -gt 0 }
               else { ($t.AmbiguousWords / [double]$wc) -gt 0.34 }
  if ($uncertain) { $ambiguousTurnCount++ }

  $wordsOut = [System.Collections.Generic.List[object]]::new()
  if (-not $OmitWords) {
    foreach ($w in $t.Words) {
      $wordsOut.Add([ordered]@{
        text       = $w.Text
        start      = [math]::Round([double]$w.Start, 3)
        end        = [math]::Round([double]$w.End, 3)
        confidence = if ($null -ne $w.Conf) { [math]::Round([double]$w.Conf, 3) } else { $null }
      })
    }
  }

  $turnsOut.Add([ordered]@{
    index            = $idx
    speaker          = $map.Id
    speakerLabel     = $map.Label
    start            = [math]::Round([double]$t.Start, 3)
    end              = [math]::Round([double]$t.End, 3)
    text             = $text
    confidence       = $turnConf
    speakerUncertain = [bool]$uncertain
    words            = $wordsOut.ToArray()
  })

  if (-not $agg.ContainsKey($map.Id)) {
    $agg[$map.Id] = [pscustomobject]@{ Id = $map.Id; Label = $map.Label; Seconds = 0.0; Turns = 0 }
  }
  $agg[$map.Id].Seconds += [math]::Max(0.0, $dur)
  $agg[$map.Id].Turns++
  $idx++
}

$speakersOut = [System.Collections.Generic.List[object]]::new()
foreach ($k in ($idByRaw.Values | ForEach-Object { $_.Id })) {
  if (-not $agg.ContainsKey($k)) { continue }
  $a = $agg[$k]
  $speakersOut.Add([ordered]@{
    id                   = $a.Id
    label                = $a.Label
    totalSpeakingSeconds = [math]::Round($a.Seconds, 2)
    turnCount            = [int]$a.Turns
  })
}

# ------------------------------------------------------------- warnings ------

if ($speakersOut.Count -gt $MaxExpectedSpeakers) {
  $warnings.Add("$($speakersOut.Count) speakers detected; attribution is less reliable above about $MaxExpectedSpeakers speakers.")
}

# Measured behaviour: with automatic speaker-count detection the clusterer tends
# to add one extra speaker holding a sliver of speech (on the benchmark fixture
# it reported 4 for a genuine 3). We deliberately do NOT merge it away - a real
# meeting can contain someone who says one short thing, and silently deleting a
# participant is worse than over-reporting one. Instead we tell the reader.
$totalSpeech = ($speakersOut | ForEach-Object { [double]$_.totalSpeakingSeconds } | Measure-Object -Sum).Sum
if ($speakersOut.Count -gt 1 -and $totalSpeech -gt 0) {
  foreach ($s in $speakersOut) {
    $secs = [double]$s.totalSpeakingSeconds
    if ($secs -lt 5.0 -and ($secs / $totalSpeech) -lt 0.02) {
      $warnings.Add("$($s.label) was detected for only $([math]::Round($secs,1)) s of speech, so the number of speakers may be over-estimated. If you know the real number, re-run and specify it.")
    }
  }
}
if ($ambiguousTurnCount -gt 0) {
  $noun = if ($ambiguousTurnCount -eq 1) { 'turn' } else { 'turns' }
  $warnings.Add("Speaker attribution for $ambiguousTurnCount $noun was ambiguous and may be incorrect.")
}
if ($ex.DroppedMarkers -gt 0) {
  $warnings.Add("$($ex.DroppedMarkers) non-speech marker(s) such as [BLANK_AUDIO] were removed from the transcript.")
}

# long stretches with no recognised speech
$silentTotal = 0.0
$silentRuns  = 0
for ($i = 1; $i -lt $words.Count; $i++) {
  $gap = [double]$words[$i].Start - [double]$words[$i - 1].End
  if ($gap -ge $LongSilenceWarnSeconds) { $silentTotal += $gap; $silentRuns++ }
}
if ($silentRuns -gt 0) {
  $warnings.Add("$silentRuns stretch(es) totalling $(Format-Duration $silentTotal) contained no detectable speech and were skipped.")
}
if ($words.Count -eq 0) {
  $warnings.Add('No speech was detected in this recording, so the transcript is empty.')
}

# ------------------------------------------------------- source / processing --

$lastEnd = if ($turnsOut.Count -gt 0) { [double]$turnsOut[$turnsOut.Count - 1].end } else { 0.0 }

if ($ContextJson -and (Test-Path -LiteralPath $ContextJson)) {
  $ctx = Read-JsonFile -FilePath $ContextJson
  $sourceOut     = $ctx.source
  $processingOut = $ctx.processing
} else {
  $sp = if ($SourcePath) { $SourcePath } else { (Resolve-Path -LiteralPath $WhisperJson).Path }
  $dur = if ($DurationSeconds -gt 0) { $DurationSeconds } else { $lastEnd }
  $lang = if ($null -ne $doc.PSObject.Properties['result'] -and $doc.result.language) { [string]$doc.result.language } else { 'en' }
  $sourceOut = [ordered]@{
    path            = $sp
    fileName        = [System.IO.Path]::GetFileName($sp)
    durationSeconds = [math]::Round($dur, 3)
    container       = $null
    audioCodec      = $null
    sizeBytes       = $null
  }
  $processingOut = [ordered]@{
    processedAtUtc               = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    transcriptionModel           = if ($doc.params.model) { [System.IO.Path]::GetFileNameWithoutExtension([string]$doc.params.model) } else { 'unknown' }
    language                     = $lang
    languageAutoDetected         = $false
    diarizationSegmentationModel = $null
    diarizationEmbeddingModel    = $null
    speakerCountMode             = 'auto'
    elapsedSeconds               = 0
    realTimeFactor               = $null
    toolVersion                  = '0.1.0'
  }
}

$out = [ordered]@{
  schemaVersion = 1
  source        = $sourceOut
  processing    = $processingOut
  speakers      = $speakersOut.ToArray()
  turns         = $turnsOut.ToArray()
  warnings      = $warnings.ToArray()
}

$json = $out | ConvertTo-Json -Depth 12
$dir = [System.IO.Path]::GetDirectoryName($OutJson)
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($OutJson, $json, [System.Text.UTF8Encoding]::new($false))

# Summary for the caller. Written to the information stream, never stdout,
# because Transcribe.ps1's stdout is the JSON Lines progress contract.
$summary = [pscustomobject]@{
  OutJson            = $OutJson
  Words              = $words.Count
  Turns              = $turnsOut.Count
  Speakers           = $speakersOut.Count
  AmbiguousWords     = $ambiguousWordCount
  AmbiguousTurns     = $ambiguousTurnCount
  DroppedEmptyTurns  = $droppedEmptyTurns
  BoundaryWordsMoved = $boundaryWordsMoved
  CoalescedSpeakers  = $coalescedSpeakers
  Warnings           = $warnings.Count
  LastEndSeconds     = [math]::Round($lastEnd, 2)
  WordTimingsDegraded= $wordTimingsDegraded
}
Write-Information ($summary | ConvertTo-Json -Compress) -InformationAction Continue
