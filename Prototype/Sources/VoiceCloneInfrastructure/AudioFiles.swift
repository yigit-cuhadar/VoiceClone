import AVFoundation
import Foundation
import VoiceCloneCore

public enum AudioFiles {
    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    public static func writeWAV(_ audio: SpeechAudio, to url: URL) throws {
        guard audio.samples.count <= Int(UInt32.max),
              let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw SynthesisError.invalidOutput
        }

        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                channel.update(from: baseAddress, count: source.count)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16
        ]
        let stagedURL = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do {
            let file = try AVAudioFile(forWriting: stagedURL, settings: settings)
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: stagedURL, to: url)
    }
}
