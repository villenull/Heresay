# Heresay

**Right-click a recording. Get a transcript PDF. Nothing leaves your machine.**

Heresay turns any audio or video file — meeting recordings, voice memos, screen
recordings, interviews — into a clean, timestamped transcript PDF, directly from the
Windows right-click menu. Everything runs locally: no accounts, no cloud, no upload,
no admin rights.

<p align="center">
  <img src="docs/images/transcript-example.png" width="720"
       alt="Example transcript PDF: timestamped turns, colour-coded speakers, uncertainty markers">
</p>

## How it looks in use

Right-click any audio or video file and pick **Transcribe in PDF** — it's in the menu
itself and under *Send to* (illustration below). A small progress window appears
bottom-right with a live time estimate; when it closes, the PDF is sitting next to
your recording.

<p align="center">
  <img src="docs/images/right-click-menu.png" width="640"
       alt="Windows context menu with the Transcribe in PDF entry, and the same entry under Send to">
</p>

## Highlights

- **Fast.** The default profile transcribes roughly **14× faster than real time** on a
  mid-range laptop CPU — an hour-long recording takes a few minutes. No GPU required.
- **Private by construction.** Speech recognition, speaker separation, and PDF
  rendering all run on your own machine. The generated HTML even ships a
  `default-src 'none'` Content-Security-Policy, so a render *cannot* touch the network.
- **Speaker separation, when you want it.** The default profile favours speed and
  skips it; the full pipeline diarises up to several speakers and colour-codes them
  in the PDF (see the example above). Single-voice transcripts render label-free.
- **A real installer.** Double-click **Install Heresay** in the release zip and a
  setup wizard walks you through it — download progress bars included. Per-user
  install, no administrator rights, clean uninstall. If PowerShell 7 is missing, the
  installer sets up a private copy automatically.
- **Careful engineering under the hood.** Every downloaded component is pinned by
  SHA-256 and verified before use; interrupted downloads resume; an install manifest
  records every file, registry key, and menu entry so uninstall provably removes them.

## Installing

1. Download `Heresay-Setup.zip` from the [Releases](../../releases) page.
2. Right-click it → **Extract All…** → open the extracted folder.
3. Double-click **Install Heresay** and click *Install* in the window that opens.

The first install downloads about **2.7 GB** of speech models and tools (once). An
offline variant of the zip with everything bundled can be built from source — see
*Building* below.

**Requirements:** Windows 10/11 (64-bit) and Microsoft Edge (present on stock
Windows; used purely as a local, offline PDF printer). PowerShell 7 is installed
automatically if absent. No admin rights are needed at any point.

**Uninstalling:** run
`pwsh -File "%LOCALAPPDATA%\Programs\TranscribeIt\Uninstall-TranscribeIt.ps1"`.
The uninstaller removes everything the manifest recorded and verifies the removal.

## How it works

| Stage | Component | Notes |
|---|---|---|
| Decode | [FFmpeg](https://ffmpeg.org) | any audio/video container → 16 kHz WAV |
| Speech recognition | [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | OpenAI Whisper models, quantised, CPU |
| Voice activity detection | [Silero VAD](https://github.com/snakers4/silero-vad) | suppresses hallucination over silence |
| Speaker separation | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | pyannote segmentation + CAM++ embeddings; runs concurrently with recognition |
| Turn assembly | `app/Merge-Diarization.ps1` | aligns words to speakers, shapes readable turns |
| PDF rendering | headless Microsoft Edge | HTML template → `--print-to-pdf`, fully offline |

The pipeline is orchestrated by PowerShell scripts — deliberately: on locked-down
corporate machines, unsigned binaries get quarantined, while scripts can be read,
reviewed, and allowed. The same constraint shaped the installer: the setup wizard is
WPF hosted in PowerShell rather than a `setup.exe`.

Design notes worth knowing before you dig in:

- **Contracts first.** `contracts/` pins the JSON schemas the stages exchange
  (`turns.schema.json`, `progress.schema.json`) and the download manifest with pinned
  URLs and SHA-256 hashes for every component and model.
- **Measured, not guessed.** Configuration defaults (`app/config.default.json`) carry
  their own benchmark evidence in `_comment` fields — thread counts, model choices,
  and speed/accuracy trade-offs are documented where they're set.
- **The engine survives failure.** If PDF rendering fails, the finished transcript is
  preserved as JSON and the error message says where it is. Downloads resume.
  Cancellation is honoured mid-stage.

## Speed and accuracy profiles

Both menu entries — the right-click verb and the *Send to* shortcut — pin the fastest
profile on the command line: English-only `tiny` model, no speaker separation, ~14×
real time, roughly one imperfect word in thirty. That is the right trade for meeting
notes.

| Profile | Model | Speakers | Speed (CPU) | Word error |
|---|---|---|---|---|
| Fastest — what both menu entries run | `tiny.en` q8 | no | ~14× real time | ~3.4 % |
| Balanced | `base.en` q8 | optional | ~9× | ~2.5 % |
| Quality — the `config.json` default | `large-v3-turbo` q4 | yes | ~1.5–2× | ~1.6 % |

(Measured end-to-end on a 12-core ultraportable; your numbers will vary.)

`config.json` in the install folder ships the Quality profile, and it governs any run
that does not override it:

```powershell
pwsh -File "$env:LOCALAPPDATA\Programs\TranscribeIt\app\Transcribe-Entry.ps1" recording.m4a
```

Editing `config.json` alone will **not** change the menu entries: both pass `-Model` and
`-NoDiarization`, which take precedence over the file. To change what the right-click
entry runs, edit the command in `app/Register-ShellVerbs.ps1` and re-run it.

## Building the distribution

```powershell
# Standard package (small zip; installer downloads components on first run)
pwsh -File build\Make-Distribution.ps1

# Offline package (~2.7 GB zip, everything bundled, install needs no network)
pwsh -File build\Make-Distribution.ps1 -IncludeDownloadCache
```

The build stamps the output with the git commit it came from, and the installer
verifies every bundled file against the pinned hashes before using it.

## Repository layout

```
app/         the pipeline: engine, merger, renderer, progress UI, launch shim
installer/   setup wizard (GUI), console installer, uninstaller, pwsh 7 bootstrap
contracts/   frozen JSON schemas + the pinned download manifest
build/       distribution packer
Install Heresay.vbs / .cmd   the double-click entry points shipped in the zip
```

## Acknowledgements

Heresay stands on excellent open-source work, fetched at install time and verified
against pinned hashes:

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and the Whisper models — MIT
- [FFmpeg](https://ffmpeg.org) (LGPL build) — LGPL-3.0-or-later
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — Apache-2.0
- [pyannote segmentation 3.0](https://huggingface.co/pyannote/segmentation-3.0) — MIT
- [3D-Speaker CAM++ embeddings](https://github.com/modelscope/3D-Speaker) — Apache-2.0
- [Silero VAD](https://github.com/snakers4/silero-vad) — MIT

## License

[MIT](LICENSE). The components Heresay downloads at install time keep their own
licences — see *Acknowledgements* above.
