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
        let stagedURL = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do {
            let file = try AVAudioFile(forWriting: stagedURL, settings: wavSettings(sampleRate: audio.sampleRate))
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: stagedURL, to: url)
    }

    public static func concatenateWAV(_ inputs: [URL], to url: URL) throws {
        guard let first = inputs.first else { throw SynthesisError.invalidOutput }
        let format = try AVAudioFile(forReading: first).processingFormat
        let stagedURL = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do {
            let output = try AVAudioFile(forWriting: stagedURL, settings: wavSettings(sampleRate: format.sampleRate))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
                throw SynthesisError.invalidOutput
            }
            for input in inputs {
                let file = try AVAudioFile(forReading: input)
                guard file.processingFormat == format else { throw SynthesisError.invalidOutput }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw SynthesisError.invalidOutput }
                    try output.write(from: buffer)
                }
            }
        }
        try FileManager.default.moveItem(at: stagedURL, to: url)
    }

    private static func wavSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16
        ]
    }
}
