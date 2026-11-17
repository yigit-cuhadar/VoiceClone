# VoiceClone

VoiceClone is an on-device voice cloning project for iPhone and Apple Silicon Mac. The planned app uses OmniVoice to turn long-form Turkish and English scripts into editable audio sections. Firebase Authentication provides optional account sign-in. Private CloudKit synchronizes projects and audio after the user enables it.

The local app opens in the Project Editor. Record or import a short reference, add script sections, generate each section, and export the complete audio as a WAV. Projects and voice profiles are stored on the device.

If a generation is interrupted, choose **Generate remaining** or retry the section. VoiceClone reuses completed audio chunks when the script, voice, language, and model still match.

The Account screen supports email/password registration, sign-in, email verification, password reset, provider linking, sign-out, and account deletion with reauthentication. Apple sign-in requires the Sign in with Apple capability and a matching development provisioning profile. Guest projects remain available offline. Signing in opens an account-specific local workspace and asks before moving guest projects, voices, and audio into it. Signing out returns to the guest workspace.

## iCloud synchronization

After sign-in, VoiceClone explains the upload of reference recordings, scripts, voice profiles, projects, settings, and generated audio before asking to enable sync. Each device uses the same VoiceClone account and iCloud account to share a library. Sync consent and audio network preferences are stored separately for each account pair on each device.

Audio transfers default to Wi-Fi or Ethernet. Enable **Allow cellular audio transfers** in **Account** to use cellular data. Project metadata can arrive while its audio is waiting to transfer. Playback and WAV export become available after the required audio files are downloaded.

Sync runs while the app is active, when the library changes, when connectivity returns, and every minute. Incoming changes wait for active rendering or export to finish. The Account screen shows pending audio, retries, the last successful sync, and iCloud quota errors. Cached libraries remain usable offline. Transfers pause while the current iCloud identity needs to be verified.

Independent edits to different sections merge into one project. Conflicting edits to the same section preserve both project versions, with a **Conflicted copy** title. Interrupted uploads resume from a persistent journal. File checksums protect downloaded audio. Removed projects and voices propagate to other devices, and unused cloud audio is deleted together with the workspace update. Account deletion retains a cleanup request for cloud data in an iCloud account that is temporarily unavailable.

The shared container is `iCloud.com.yigitcuhadar.voiceclone`. Development builds use `VOICECLONE_CLOUDKIT_ENVIRONMENT=Development`. CloudKit creates the `Workspace` and `Audio` record types in the development environment during validation. Before App Store distribution, deploy this schema to production and build with `VOICECLONE_CLOUDKIT_ENVIRONMENT=Production` on both platforms. Model downloads and temporary render checkpoints are managed locally.

## Firebase configuration

The development Firebase project is `voiceclone-dev`. Its Apple app uses `com.yigitcuhadar.voiceclone` on iOS and macOS. Download its client configuration before building. The local configuration is excluded from Git.

```sh
firebase apps:sdkconfig IOS 1:88103338077:ios:0a4831f0e25ec2b0fccdb4 \
  --project voiceclone-dev --out App/Sources/GoogleService-Info.plist
```

Enable Email/Password and Apple in Firebase Authentication. Use the same bundle identifier when configuring Sign in with Apple. To build against a different Firebase project, download that project's matching Apple app configuration into the same file.

## Build

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

## Account validation

The opt-in account smoke test uses a named Firebase app connected to the local Authentication emulator at `127.0.0.1:9099` with project ID `demo-voiceclone`. It keeps test workspaces separate from the normal library. Build with `VOICECLONE_SMOKE_CONDITION=VOICECLONE_SMOKE_TEST` and run with `--account-smoke`. Set `VOICECLONE_ACCOUNT_SMOKE_DIRECTORY` to a writable directory inside the app's sandbox. The test writes `report.json` there and leaves one emulator account signed in. Relaunch the same build with `--account-persistence-smoke` and the same directory to verify restored authentication and reauthenticated account deletion.

The tests cover guest transfer, reference audio preservation, interrupted transfer recovery, two-account isolation, invalid passwords, verification/reset requests, and local file cleanup. Apple authorization and token revocation require separate device testing against the configured Apple provider.

Cloud synchronization validation is also opt-in. Build with `VOICECLONE_SMOKE_CONDITION=VOICECLONE_SMOKE_TEST` and run `--sync-smoke-local` to verify metadata before audio, concurrent edits, quota failure recovery, interrupted uploads, server revision retries, and deletion propagation using an in-memory transport. Set `VOICECLONE_CLOUD_SMOKE_DIRECTORY` to a fresh directory inside the app sandbox.

For device-to-device validation, set the same unique `VOICECLONE_CLOUD_SMOKE_NAMESPACE` starting with `validation-` on both devices. Run `--sync-smoke-publish` on one device and `--sync-smoke-consume` on the other. Both devices must use the same system iCloud account. The test uses synthetic audio and a separate private record zone, writes `report.json`, and verifies an exported WAV on the receiving device. Run `--sync-smoke-cleanup` afterward to delete that validation zone.
