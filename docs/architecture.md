# Architecture notes

Heresay is both the public product name and the internal product identifier. Installed
files live under `%LOCALAPPDATA%\Programs\Heresay`, mutable state lives under
`%LOCALAPPDATA%\Heresay`, and Explorer shell verbs use `Heresay` as their registry
identifier.

The application is split into three boundaries:

- `app/Transcribe-Entry.ps1` owns Explorer launches, queueing, and batch progress.
- `app/Transcribe.ps1` owns decoding, transcription, diarization, and orchestration.
- `app/Render-Pdf.ps1` turns the transcript contract into the final PDF.

The stable data boundaries live in `contracts/`. Times are floating-point seconds
from the beginning of the source media. The launcher exposes one monotonic batch
progress stream even though the engine processes one file at a time.
