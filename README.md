# VoiceClone

VoiceClone is an on-device voice cloning project for iPhone and Apple Silicon Mac. The planned app uses OmniVoice to turn long-form Turkish and English scripts into editable audio sections. Firebase Authentication will handle sign-in, and private CloudKit will sync projects and audio between devices.

The local app opens in the Project Editor. Record or import a short reference, add script sections, generate each section, and export the complete audio as a WAV. Projects and voice profiles are stored on the device.

Open [VoiceClone.xcodeproj](App/VoiceClone.xcodeproj) in Xcode and run the `VoiceClone` scheme on Apple Silicon Mac or a physical iPhone. Select a development team for physical-device signing. If Xcode asks you to approve the MLX build plugin, review and enable it in Xcode.

The model catalog offers OmniVoice INT8 on iPhone and both tested OmniVoice variants on Mac. Mac recommendations account for RAM and available disk space. Synthesis uses downloaded model files and works offline. A changed section can be regenerated without touching other outputs.

- [Development plan](PLAN.md)
- [Build and run the prototypes](Prototype/README.md)
