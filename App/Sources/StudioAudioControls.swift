import AVFoundation
import Foundation

@MainActor
final class StudioAudioControls {
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?

    func play(_ url: URL) throws {
        player?.stop()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        player = try scoped ? AVAudioPlayer(data: Data(contentsOf: url)) : AVAudioPlayer(contentsOf: url)
        guard player?.play() == true else { throw StudioAudioError.playbackFailed }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func startRecording() async throws -> URL {
        stop()
        #if os(iOS)
        let permitted = await AVAudioApplication.requestRecordPermission()
        #else
        let permitted = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard permitted else { throw StudioAudioError.microphoneDenied }
        try Task.checkCancellation()
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            guard recorder.record(forDuration: 9.8) else { throw StudioAudioError.recordingFailed }
            self.recorder = recorder
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

private enum StudioAudioError: LocalizedError {
    case microphoneDenied
    case recordingFailed
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Allow microphone access in Settings to record a reference."
        case .recordingFailed: "The microphone did not start recording."
        case .playbackFailed: "The audio could not be played."
        }
    }
}
