# Heresay

**Audio and video to speaker-labeled transcripts on your PC.**

Heresay turns meeting recordings into timestamped, speaker-labeled PDF transcripts. Everything runs on your own computer — no audio is ever uploaded anywhere.

---

## What it does

- **Right-click any recording** → transcript PDF appears next to the file.
- **Record a live meeting** → right click on your desktop, system audio and microphone captured together and transcribed.
- **Three quality levels** — from a fast English-only model to a slower multilingual one with speaker separation.

---

## Features

### Transcribe a file

Right-click any audio or video file in File Explorer and choose **Transcribe in PDF**. A progress window opens and shows a live ETA. When it finishes, the transcript PDF is saved next to the source file.

![The Transcribe in PDF entry in the Windows right-click menu](docs/images/right-click-menu.png)

Supported formats include MP3, M4A, MP4, WAV, OGG, FLAC, MKV, WEBM, and [many more](app/Register-ShellVerbs.ps1).

The output is a paginated PDF with timestamps and, at the two higher quality levels, speaker labels:

![A page of a generated transcript, showing timestamps and speaker labels](docs/images/transcript-example.png)

### Record a conversation

Right-click an empty part of your desktop — or the background of any open folder — and choose **Transcribe new conversation**.

![The Transcribe new conversation entry in the desktop right-click menu](docs/images/right-click-desktop.png)

Heresay captures both your microphone and the audio playing through your speakers simultaneously, then transcribes the combined recording when you stop. Works with Zoom, Teams, and any other call. The same entry is also on the **Transcribe new conversation** button in the home window.

> If your default microphone is a Bluetooth headset, Heresay automatically uses a wired or built-in microphone instead — opening a Bluetooth hands-free mic forces the earbuds into mono phone quality, which degrades the whole recording. If no alternative exists, it falls back to the Bluetooth mic with a note in the log.

### Choose a quality level

Open the Heresay home window (Start → search "Heresay") to pick how carefully Heresay listens. The setting applies to every path — both right-click entries and the file button.

![The Heresay home window, showing the three transcription quality levels](docs/images/home-window.png)

| Level | Speed | Speakers | Language |
|---|---|---|---|
| **Fastest** *(default)* | ~9× faster than real-time | No | English |
| **Moderate** | ~4× faster | Yes — labeled by speaker | English |
| **Slower, more capable** | ~1.5× faster | Yes — labeled by speaker | Auto-detects (English, Spanish, and more) |

The window also has a **Transcribe a file…** button that opens a file picker, and an **Uninstall Heresay** link at the bottom.

---

## Install

### New install

1. Go to the [Releases page](https://github.com/villenull/Heresay/releases/latest) and download **`Install-Heresay.vbs`**.
2. Double-click the file. A setup window opens after a few seconds while the package downloads.
3. Click **Install**. The first install downloads approximately 2.7 GB of speech models — leave the window open until it finishes.

> **SmartScreen warning**: if Windows shows a "Windows protected your PC" message, click **More info**, then **Run anyway**. Heresay is open source and installs only for your user account — no administrator rights are needed.

### Upgrade from v0.1

Run the new installer the same way. It detects the previous install and upgrades in place. Your right-click menus and Start Menu entry are updated automatically. Your recordings and transcripts in Downloads are not touched.

### Manual install (advanced)

The same Releases page also offers **`Heresay-Setup.zip`** for those who prefer to inspect the package before running. Extract the zip, open the `Heresay-Setup` folder, and double-click **Install Heresay**.

---

## Uninstall

Open the Heresay home window (Start → Heresay), scroll to the bottom, and click **Uninstall Heresay**. Confirm the prompt. A message appears when it's done.

Alternatively: paste `%LOCALAPPDATA%\Programs\TranscribeIt` into the File Explorer address bar, right-click `Uninstall-TranscribeIt.ps1`, and choose **Run with PowerShell**.

Your recordings and transcripts are never deleted by the uninstaller.

---

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11 (64-bit) |
| Disk | ~6 GB free (models + app; the download cache is removed after install) |
| Internet | Required for the initial model download only |
| Admin rights | Not needed — installs per user |

---

## Privacy

Heresay runs entirely on your computer.

- Audio is processed locally by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx).
- No recordings, transcripts, or usage data are sent to any server.
- No accounts, no telemetry, no cloud.

---

## How it works (briefly)

1. Audio or video is decoded to a 16 kHz WAV by ffmpeg.
2. Whisper transcribes it to word-level timestamps.
3. (Moderate and Slower levels) sherpa-onnx diarizes the audio to assign each word to a speaker.
4. A merger combines the transcript and diarization into a turn-by-turn structure.
5. A PDF is rendered from that structure.

For conversation recordings, system audio and microphone are recorded in parallel as two WAV files, mixed, and then fed into the same pipeline.

---

## License

MIT
