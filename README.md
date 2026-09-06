<p align="center">
  <img src="docs/images/logo.png" width="128" height="128" alt="Heresay logo">
</p>

<h1 align="center">Heresay</h1>

<p align="center">
  <strong>Right-click a recording. Get a speaker-labeled transcript PDF.</strong><br>
  Runs entirely on your Windows PC with whisper.cpp and sherpa-onnx.
</p>

<p align="center">
  <a href="https://github.com/villenull/Heresay/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/villenull/Heresay?label=release&color=0B7285"></a>
  <img alt="Windows 10 and 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white">
  <img alt="Local only" src="https://img.shields.io/badge/processing-local%20only-17A673">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-2EA44F"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#what-the-installer-does">Installer audit</a> ·
  <a href="#privacy">Privacy</a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" width="938" alt="Right-click a recording, watch transcription progress, and get a PDF">
</p>

The name is *here + say*: your recordings stay here.

## What it does

- **Transcribe a file:** right-click audio or video and choose **Transcribe in PDF**.
- **Record a meeting:** capture your microphone and system audio together, then transcribe it locally.
- **Choose the tradeoff:** three quality levels balance speed, speaker labels, and language detection.

## Features

### Files to PDF

The progress window shows a live ETA and saves the finished PDF beside the recording. Supported formats include MP3, M4A, MP4, WAV, OGG, FLAC, MKV, WEBM, and [more](app/Register-ShellVerbs.ps1).

![The Transcribe in PDF entry in the Windows right-click menu](docs/images/right-click-menu.png)

### Record a conversation

Right-click the desktop or an open folder and choose **Transcribe new conversation**. Heresay records your microphone and speaker audio together and works with Zoom, Teams, and other calls.

![The Transcribe new conversation entry in the desktop right-click menu](docs/images/right-click-desktop.png)

### Quality levels

Open Heresay from the Start Menu to choose a level. The setting applies to files and live recordings.

| Level | Speed | Speakers | Language |
|---|---|---|---|
| **Fastest** *(default)* | ~9× real-time | No | English |
| **Moderate** | ~4× | Labeled | English |
| **Slower, more capable** | ~1.5× | Labeled | Auto-detects |

![The Heresay home window, showing the three transcription quality levels](docs/images/home-window.png)

## Install

1. Download **[`Install-Heresay.vbs`](https://github.com/villenull/Heresay/releases/latest/download/Install-Heresay.vbs)**.
2. Open the [release notes](https://github.com/villenull/Heresay/releases/latest), read the tag-pinned installer source linked there, and compare its SHA256 with the published checksum.
3. Double-click it, then click **Install**. The first install downloads approximately 2.7 GB.

> **SmartScreen:** the installer is unsigned, so Windows may warn you. Source review and the published checksum are the available mitigations. If you choose to continue, click **More info**, then **Run anyway**.

Upgrading from v0.1 uses the same installer and preserves your recordings and transcripts.

## What the installer does

[`Install-Heresay.vbs`](Install-Heresay.vbs) is the complete 859-line development version of the installer. For an exact match to a downloaded release, use the tag-pinned source link in that release's notes.

1. Extracts its embedded package to `%TEMP%\Heresay-Setup-*` and starts `installer\Install-Gui.ps1`.
2. If needed, downloads a pinned PowerShell 7 release, verifies its SHA256, and installs it under `%LOCALAPPDATA%\Programs\PowerShell7`.
3. Downloads SHA256-pinned binaries and models from GitHub, Hugging Face, and NuGet. Exact URLs and hashes are in [`contracts/download-manifest.json`](contracts/download-manifest.json).
4. Caches downloads under `%LOCALAPPDATA%\TranscribeIt\downloads` and installs Heresay under `%LOCALAPPDATA%\Programs\TranscribeIt`.
5. Adds per-user shell verbs under `HKCU\Software\Classes`; it does not request admin rights or write to HKLM.

Verify the downloaded installer in PowerShell:

```powershell
Get-FileHash .\Install-Heresay.vbs -Algorithm SHA256
```

Release checksums are published in the release notes.

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11, 64-bit |
| Disk | 7 GB free during installation; approximately 4.4 GB retained |
| Internet | Initial download only |
| Admin rights | Not required |

## Privacy

- Audio and transcripts stay on your computer.
- No accounts, telemetry, or cloud processing.
- Speech recognition uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp); speaker separation uses [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx).

## Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io/), certificate by [SignPath Foundation](https://signpath.org/).

Committer, reviewer, and signing approver: [Diego Huyke (@villenull)](https://github.com/villenull).

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

## Uninstall

Open Heresay from the Start Menu and click **Uninstall Heresay**. Recordings and transcripts are not removed.

## License

[MIT](LICENSE)
