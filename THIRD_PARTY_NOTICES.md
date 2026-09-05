# Third-party notices

Heresay downloads the components below during installation. They are not authored
by the Heresay maintainers. Exact artifact URLs, versions, sizes, and SHA256 hashes
are pinned in [`contracts/download-manifest.json`](contracts/download-manifest.json).

| Component | Version | License | Source |
|---|---|---|---|
| whisper.cpp and converted Whisper models | v1.9.2 / ggml | [MIT](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE) | [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) |
| FFmpeg Windows build | n9.0.1-8-g16dfae5c88 | [LGPL-3.0-or-later](https://ffmpeg.org/legal.html) | [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) |
| sherpa-onnx | v1.13.6 | [Apache-2.0](https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE) | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) |
| NAudio.Core and NAudio.Wasapi | 2.2.1 | [MIT](https://github.com/naudio/NAudio/blob/main/LICENSE) | [naudio/NAudio](https://github.com/naudio/NAudio) |
| pyannote segmentation model | segmentation-3.0 | [MIT](https://huggingface.co/pyannote/segmentation-3.0) | [model page](https://huggingface.co/pyannote/segmentation-3.0) |
| 3D-Speaker embedding models | 3D-Speaker | [Apache-2.0](https://github.com/modelscope/3D-Speaker/blob/main/LICENSE) | [modelscope/3D-Speaker](https://github.com/modelscope/3D-Speaker) |
| Silero VAD model | v5.1.2 | [MIT](https://github.com/snakers4/silero-vad/blob/master/LICENSE) | [snakers4/silero-vad](https://github.com/snakers4/silero-vad) |

FFmpeg's license text and the pyannote model's license file are also installed
beside those components, as specified by the manifest's extraction mappings.

