# Data contracts

The files in this directory define the stable boundaries between the transcription
engine, PDF renderer, launcher, and progress window. Change a field's meaning only
with a `schemaVersion` bump and corresponding consumer updates.

## Transcript contract

- Schema: `turns.schema.json`
- Example: `turns.example.json`

The example deliberately includes a short interjection, an uncertain speaker, an
empty `words` array, a long monologue, and warnings.

- Times are floating-point seconds from the beginning of the media.
- `speakerLabel` is display-ready and must not be renumbered by renderers.
- `words` may be empty.
- `speakers[]` is ordered by first appearance.
- `warnings[]` remain in JSON and may be shown by the completion UI; they are not
  printed in the PDF.

## Progress contract

- Schema: `progress.schema.json`
- Fixtures: `progress.single.jsonl` and `progress.batch.jsonl`

The format is JSON Lines: one compact UTF-8 JSON object per line, newline
terminated and flushed promptly.

- `overallPercent` is authoritative and monotonically non-decreasing in the stream
  seen by the UI.
- `stagePercent: null` means granular stage progress is unavailable.
- `etaSeconds: null` means an estimate is not available yet.
- A nonfatal `error` allows the batch to continue; a fatal error is terminal.
- `batchComplete` is the normal terminal event. The window flashes at most once on
  any terminal state.
- Unknown event types and fields must be ignored for forward compatibility.
- The UI must not outlive a completed or abandoned run. The launcher passes its PID
  so the UI can settle and close when the process and stream are both inactive.

The engine emits progress for one file at a time. The launcher owns batching: it
rewrites item coordinates, rescales each file's percentage onto the batch range,
and emits one final `batchComplete`. `progress.batch.jsonl` is an engine-side fixture
and therefore contains legitimate per-file percentage resets.

## Stage weights

| Stage | Weight |
|---|---:|
| probe | 1 |
| decode | 2 |
| transcribe | 85 |
| diarize | 9 |
| merge | 1 |
| render | 2 |
