# VoiceClone

VoiceClone is an on-device voice cloning project for iPhone and Apple Silicon Mac. The planned app uses OmniVoice to turn long-form Turkish and English scripts into editable audio sections. Firebase Authentication will handle sign-in, and private CloudKit will sync projects and audio between devices.

The local app opens in the Project Editor. Record or import a short reference, add script sections, generate each section, and export the complete audio as a WAV. Projects and voice profiles are stored on the device.

Open [VoiceClone.xcodeproj](App/VoiceClone.xcodeproj) in Xcode and select the `VoiceClone` scheme. Select a development team to run on a physical iPhone. If Xcode asks you to approve the MLX build plugin, review and enable it in Xcode.

Build the macOS app for Apple Silicon with the following command. The architecture override also applies to Swift package targets.

```sh
xcodebuild -project App/VoiceClone.xcodeproj -scheme VoiceClone \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

The model catalog offers OmniVoice INT8 on iPhone and OmniVoice INT8, OmniVoice FP16, and Chatterbox Multilingual on Apple Silicon Mac. Mac recommendations account for RAM and available disk space. With a voice and script selected, use **Preview** to hear the first script excerpt through any downloaded model. Synthesis and previews work offline once the model files are present. [Chatterbox model bundle](https://huggingface.co/aufklarer/Chatterbox-Multilingual-MLX-fp16) · [S3 tokenizer source model](https://huggingface.co/FunAudioLLM/CosyVoice2-0.5B)

- [Development plan](PLAN.md)
- [Build and run the prototypes](Prototype/README.md)
