# OmniVoice macOS prototype

This command-line prototype generates Turkish or English speech from a reference recording on Apple Silicon. It writes a mono, 16-bit PCM WAV and reports model load time, generation time, audio duration, and peak process RSS.

The Swift package separates core request and audio types, the synthesis use case, and its interface from the OmniVoice and AVFoundation adapters. The command-line target supplies the dependencies.

Build from this directory using Xcode and the Metal toolchain. If Xcode asks you to approve the MLX Swift package build plugin, review and enable it in Xcode.

```sh
xcodebuild -scheme VoiceCloneProbe -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
```

Choose a short recording of your voice or a voice you have permission to use. Pass the words spoken in the reference recording, followed by the text to synthesize and a new output path.

```sh
.build/xcode/Build/Products/Release/VoiceCloneProbe int8 en \
  /path/to/reference.wav 'This is my reference recording.' \
  'Today I am starting a new audio project.' /tmp/voiceclone-en.wav
```

Use `tr` for Turkish or `fp16` for the FP16 bundle. The first online run can include a model download in the reported load time. After the weights are cached, add `--offline` before the model name to measure loading and generation with the local files.
