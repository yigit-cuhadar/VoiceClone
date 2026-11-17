# VoiceClone

VoiceClone is an on-device voice cloning project for iPhone and Apple Silicon Mac. The planned app uses OmniVoice to turn long-form Turkish and English scripts into editable audio sections. Firebase Authentication will handle sign-in, and private CloudKit will sync projects and audio between devices.

The current prototype is a macOS command-line tool that generates a WAV file from a short reference recording. It supports OmniVoice INT8 and FP16.

- [Development plan](PLAN.md)
- [Build and run the macOS prototype](Prototype/README.md)
