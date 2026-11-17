# VoiceClone

VoiceClone is an on-device voice cloning project for iPhone and Apple Silicon Mac. The planned app uses OmniVoice to turn long-form Turkish and English scripts into editable audio sections. Firebase Authentication will handle sign-in, and private CloudKit will sync projects and audio between devices.

The prototype generates a WAV file from a short reference recording using OmniVoice INT8 or FP16. It includes a macOS command-line tool and an iPhone test app that share the synthesis use case and model adapter.

- [Development plan](PLAN.md)
- [Build and run the prototypes](Prototype/README.md)
