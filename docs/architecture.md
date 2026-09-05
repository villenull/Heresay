# Architecture notes

Heresay is the public product name. `TranscribeIt` remains in internal paths,
registry verb identifiers, and manifest fields for upgrade compatibility with
earlier releases. Renaming those identifiers requires a migration that removes the
old shell registrations and preserves existing per-user settings.

The application is split into three boundaries:

- `app/Transcribe-Entry.ps1` owns Explorer launches, queueing, and batch progress.
- `app/Transcribe.ps1` owns decoding, transcription, diarization, and orchestration.
- `app/Render-Pdf.ps1` turns the transcript contract into the final PDF.

The stable data boundaries live in `contracts/`. Times are floating-point seconds
from the beginning of the source media. The launcher exposes one monotonic batch
progress stream even though the engine processes one file at a time.

