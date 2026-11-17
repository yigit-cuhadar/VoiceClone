# OmniVoice prototypes

## macOS command-line tool

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

## iPhone test app

Open [VoiceCloneProbe.xcodeproj](iOS/VoiceCloneProbe.xcodeproj) in Xcode, select a development team in Signing & Capabilities, and run the `VoiceCloneProbe` scheme on a physical iPhone. Use a Release build for performance measurements. The benchmark's current deployment target is iOS 18. The supported device list depends on measured model compatibility. [MLX on iOS](https://swiftpackageindex.com/ml-explore/mlx-swift/main/documentation/mlx/running-on-ios)

Choose INT8 or FP16, select the output language, and import a reference clip between 1 and 15 seconds long. Enter the clip's transcript and the text to generate, then select **Generate WAV**. The test app reports load time, generation time, audio duration, process lifetime peak memory, and thermal state. Relaunch the app between runs to measure peak memory separately for each variant. Enable **Use cached model only** after the first download for measurements without network transfer.

Debug builds also accept `--benchmark <int8|fp16> <en|tr>` as launch arguments. Pass `VOICECLONE_BENCHMARK_CONDITION=VOICECLONE_BENCHMARK` to `xcodebuild` when building in Release to enable the same entry point. Place `reference-<language>.aiff` and `script-<language>.json` in `Documents/Benchmark` inside the app container. The JSON contains `transcript` and `text` strings. The app writes the WAV and a JSON report to that directory. This entry point uses cached weights unless the launch arguments include `--allow-model-download`.
