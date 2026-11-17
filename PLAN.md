# VoiceClone development plan

VoiceClone will ship as native SwiftUI apps for iPhone and Apple Silicon Mac, with shared Swift code and a public App Store release. Users will create voice profiles from reference recordings, synthesize long-form speech in Turkish and English, edit individual sections, and export WAV files. The app interface, documentation, source code, diagnostic messages, and store listing will be in English.

## User workflow

1. Open the Project Editor and work locally without an account. Sign in with Apple or with email and password to prepare for synchronization. Verify the email address or reset the password when necessary. Ask before moving existing guest projects, voices, and audio into the signed-in account.
2. Review the model recommended for the current device. Download it or select a compatible alternative from the catalog.
3. Record a short sample or import an audio file. Preview and trim the sample, then confirm the transcript and permission to use the voice.
4. Create a project, paste a script, and select a voice profile. Edit and reorder the automatically created sections, then generate a preview of one section.
5. Generate the remaining sections. Regenerate any edited section, preview the complete audio, and export it as a WAV file.
6. Open the app on another device with the same VoiceClone and iCloud accounts to access settings, voice profiles, reference recordings, projects, drafts, sections, and generated audio.

## Models and device recommendations

- **OmniVoice** is the primary model family. Evaluate the reference-encoding INT8 and FP16 bundles through the Swift runtime. Use measured memory use, latency, and audio quality to determine where each model is recommended. [INT8 bundle](https://huggingface.co/aufklarer/OmniVoice-MLX-int8), [FP16 bundle](https://huggingface.co/aufklarer/OmniVoice-MLX-fp16), [Swift runtime](https://github.com/soniqo/speech-swift)
- **Chatterbox Multilingual** is the first alternative in the Apple Silicon Mac catalog. The app verifies the model, conformer, tokenizer, and configuration files before use. Validate speaker similarity and mobile performance separately before expanding its availability. [Chatterbox](https://github.com/resemble-ai/chatterbox#supported-languages), [Swift runtime](https://github.com/soniqo/speech-swift)
- Recommend a model at startup using the device class, OS version, available disk space, and measured compatibility. Show download size, supported languages, and device restrictions. Let users download compatible alternatives and audition them using the same short text and voice profile. Resume interrupted downloads, verify package integrity, and allow removal of unused models.
- Each device downloads its own model files. Record the model identifier and version with each generation. Existing audio remains playable when the model is unavailable locally. The user chooses a compatible model before regenerating a section. Identify sections generated with different models.

## Clean Architecture

| Layer | Responsibilities |
| --- | --- |
| Domain | Voice profiles, projects, sections, speech languages, generation results, and their invariants. |
| Application | Use cases for adding a voice profile, recommending a compatible model, generating or regenerating sections, running queued work, exporting audio, and synchronizing the library. Use cases define the interfaces they need for storage, identity, synthesis, and file I/O. |
| Infrastructure | Implement those interfaces using OmniVoice and other vetted models, AVFoundation, local persistence, Firebase Authentication, and CloudKit. |
| Presentation | Platform-specific SwiftUI screens and state. An assembly point for each app constructs the infrastructure adapters and injects them into the use cases. |

Dependencies point inward. The domain and use cases are shared across macOS and iOS and can run against test doubles for external services. Keep framework types in the layers that use them.

## Generation, identity, and storage

- **On-device synthesis.** Generation works offline once the selected model and reference audio are available locally. OmniVoice uses a short reference recording and its transcript. The proposed initial recording flow uses a prompted sentence for new recordings and a manually confirmed transcript for imported clips. [OmniVoice voice cloning](https://github.com/k2-fsa/OmniVoice#voice-cloning)
- **Long-form editing.** Keep editable sections separate from the smaller sentence-based chunks processed by the model. Persist completed section audio as generation progresses. Resume after interruption, retry individual sections, and mark edited sections for regeneration. Stream section audio from disk in order when exporting the full WAV.
- **Firebase Authentication.** Begin with the separate `voiceclone-dev` development project. Account sign-in is optional for local editing and generation. Both platforms use the same Firebase project for Sign in with Apple and email/password. Users can explicitly link the two sign-in methods to one VoiceClone account. Include in-app account deletion. [Sign in with Apple](https://firebase.google.com/docs/auth/ios/apple), [Password authentication](https://firebase.google.com/docs/auth/ios/password-auth), [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **Private CloudKit sync.** Explain the upload and ask for consent at the first sign-in. Default audio transfers to Wi-Fi or Ethernet and let users enable cellular audio in Account. Sync project metadata on any available connection. Both platforms use the same CloudKit container. Sync settings, voice profiles, projects, drafts, sections, and generation history through the private database. Store reference recordings and generated section audio as CloudKit assets. Assets count toward the user's iCloud storage quota. Assemble the full WAV locally for export. [Private CloudKit database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), [CloudKit assets](https://developer.apple.com/documentation/cloudkit/ckasset)
- **Account scopes.** Firebase owns the VoiceClone session. CloudKit authorizes access through the device's iCloud account. Scope local data and synchronization state to the active Firebase and iCloud account pair. Stop pending transfers when either account changes. Delete associated CloudKit data during account deletion when the original iCloud account is available. Explain how to remove remaining iCloud data if that account is unavailable.
- **Offline changes and retries.** Save drafts and outputs locally first. Upload them when iCloud is available, show pending transfers and quota failures, and make retries idempotent. Preserve both versions when two devices edit the same section concurrently. Propagate deletions across devices. Explain the iCloud upload of reference audio, text, and generated audio before the first sync. [CloudKit quota errors](https://developer.apple.com/documentation/cloudkit/ckerror/code/quotaexceeded)

## Milestones and acceptance criteria

| Milestone | Acceptance criteria |
| --- | --- |
| 1. Model prototype | Generate Turkish and English audio from reference recordings on an Apple Silicon Mac and a physical iPhone. Measure cold load, peak memory, generation time, and thermals under repeated use. Review intelligibility, speaker similarity, and transitions between generated chunks. Use these measurements to determine the supported devices and OS versions. |
| 2. Local app | Download a model, audition a compatible alternative, add a reference recording, and complete a multi-section project. Regenerating one section preserves other sections. Completed work survives interruption and the exported WAV plays on both platforms. |
| 3. Firebase Authentication and CloudKit | Both sign-in methods work on both platforms. Audio generated offline appears on the second device after connectivity returns. Verify concurrent edits, full iCloud storage, account switching, cross-account isolation, and account deletion. |
| 4. Public App Store release | Test the supported device matrix. Prepare English store content, privacy disclosures, the microphone purpose string, and review instructions. Submit the iOS and macOS builds for App Store review. |
