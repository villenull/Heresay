# Frozen contracts — read this before touching anything

`TranscribeIt` is being built by several parallel tracks. These two contracts are the
seams between them. **They are frozen.** If you believe one is wrong, stop and say so —
do not unilaterally change a field name or meaning, because another track is already
coding against it.

## Seam 1 — the transcript

- Schema: `turns.schema.json`
- Worked example / stub: `turns.example.json`

**Producer:** Track A (engine). **Consumer:** Track B (PDF renderer).

Track B must be able to render `turns.example.json` into a finished PDF without the engine
existing at all. That file is deliberately awkward on purpose — it contains a very short
interjection, a turn flagged `speakerUncertain`, turns with an empty `words` array, a
600-character monologue, and two `warnings`. If the renderer handles that file it will
handle real output.

Rules that matter:

- All times are **seconds from the start of the media**, floating point. Not milliseconds,
  not `hh:mm:ss` strings. Formatting timestamps for display is the renderer's job.
- `speakerLabel` is **display-ready** and printed verbatim. The renderer must not invent
  its own labels or renumber speakers.
- `words` **may be empty**. Never depend on it. Word timings are a bonus for future
  features, not a requirement for rendering.
- `speakers[]` is ordered by first appearance, so `Speaker 1` is whoever spoke first.
- `warnings[]` are **not rendered in the PDF** (decision 2026-08-26: the PDF was specified
  to contain the transcript only — no header block, no metadata, no warnings box, no speakers
  table, no legend). They stay in the JSON and reach the user through the completion UI
  instead, which already receives them on the `result` event. Do not reintroduce them into
  the PDF.

## Seam 2 — progress events

- Schema: `progress.schema.json`
- Fixtures: `progress.single.jsonl` (66 events, one long file), `progress.batch.jsonl`
  (17 events, three files, one of which fails)

**Producer:** Track A (engine), on stdout. **Consumer:** Track E (WPF taskbar UI).

Format is **JSON Lines**: exactly one compact JSON object per line, UTF-8, newline
terminated, flushed immediately so the UI updates live rather than in bursts at the end.

Rules that matter:

- `overallPercent` is **authoritative and monotonically non-decreasing**. The UI binds it
  straight to `TaskbarItemInfo.ProgressValue` (divided by 100). The UI must never compute
  its own overall percentage from stage weights — that logic lives in the engine only, so
  there is exactly one place to fix if the bar feels wrong.
- `stagePercent: null` means *this stage cannot report granular progress* → the UI shows an
  indeterminate/marquee taskbar state, not 0%.
- `etaSeconds: null` means *not yet estimable* → the UI shows "estimating…", never
  "0 min left". Getting this wrong is the single most annoying possible bug in this app.
- `error` with `"fatal": false` means the batch continues to the next file. The UI must
  keep running and only enter the terminal red state on a fatal error.
- `batchComplete` is the normal terminal event. **Flash at most once per process**, on
  reaching a terminal state. Amended 2026-08-26: a *fatal* `error` also counts as terminal
  and also flashes. The original wording said `batchComplete` only, which was wrong — a run
  that fails after ten minutes needs to call the user back just as much as one that
  succeeds, and a silent failure is the worse outcome. The invariant is "at most one flash",
  not "only on success". Guard it with a once-only flag; do not add further callers.
- **The UI must not outlive the run.** Amended 2026-08-27, after four progress windows from
  the previous night's batches were found still running, ~300 MB each, their engine pids
  long gone. The launcher passes its own pid as `-EnginePid` and the UI treats that process
  as the run's lifetime: once it is gone and the stream has stopped growing, the UI settles
  on a terminal state - `stopped`, never an invented success - and then closes itself after
  `-LingerSeconds` (default 600). Activating the window does not buy it immortality, only a
  longer leash: the linger is replaced by an idle clock (`-AcknowledgedIdleSeconds`, default
  1800) that every activation restarts, and that is also held open for as long as it is the
  foreground window - so a result being read is never closed out from under the user, but one
  glanced at and abandoned still goes. Amended the same day after a clicked window was
  measured holding 386 MB with its engine dead. This is a launcher/UI seam, not a stream
  rule: a producer that writes the stream but passes no pid keeps the old behaviour of
  waiting for a click for ever.

## Two stream scopes — do not confuse them

Discovered during the build and worth writing down, because it changes what
"monotonically non-decreasing" means:

- **The engine emits a per-file stream.** `Transcribe.ps1` handles one file per invocation,
  so its `overallPercent` runs 0 → 100 for *that file* and legitimately restarts at 0 on the
  next invocation.
- **The launcher emits the batch-scaled stream.** `Transcribe-Entry.ps1` owns batching. It
  rescales each file's `overallPercent` onto the whole-batch scale with a monotonic clamp,
  rewrites `itemIndex`/`itemTotal`, and suppresses the engine's `batchComplete` so exactly
  one reaches the UI.

The taskbar UI only ever sees the launcher's stream, so from its point of view
`overallPercent` never decreases. Note `contracts/progress.batch.jsonl` predates this
decision and still shows raw per-file resets — it is a valid *engine* stream but is no
longer representative of what the UI receives. Treat it as an engine-side fixture.
- Unknown `type` values and unknown fields must be **ignored, not treated as errors**, so
  the engine can add events later without breaking the UI.

Track E must be fully testable by replaying these fixtures — no engine, no audio, no
models. Replay `progress.single.jsonl` with realistic delays and the taskbar should behave
exactly as it will in production.

## Stage weights

Fixed in `progress.schema.json` under `stageWeights`, summing to 100:

| stage | weight |
|---|---|
| probe | 1 |
| decode | 2 |
| transcribe | 85 |
| diarize | 9 |
| merge | 1 |
| render | 2 |

Transcription dominates, which is why the bar must not simply track it — otherwise it
appears to freeze at 85% for the ~30 seconds diarization takes. The engine blends stages
so the bar keeps moving to 100%.

## File ownership (avoid stepping on each other)

| Path | Owner |
|---|---|
| `app/Transcribe.ps1`, `app/Merge-Diarization.ps1`, `app/config.default.json` | Track A |
| `vendor/**`, `contracts/download-manifest.json` | Track A |
| `app/Render-Pdf.ps1`, `app/template.html` | Track B |
| `installer/**`, `app/Register-ShellVerbs.ps1` | Track C |
| `app/Progress.ps1` | Track E |
| `contracts/*.schema.json`, `contracts/*.example.json`, `contracts/*.jsonl` | **nobody — frozen** |
