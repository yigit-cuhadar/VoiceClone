#if os(macOS)
import AudioCommon
import ChatterboxTTS
import Foundation
import VoiceCloneCore

final class ChatterboxSynthesizer: SpeechSynthesizing {
    private let model: ChatterboxTTSModel
    private let sampleRate = 24_000

    init(directory: URL) throws {
        model = try ChatterboxTTSModel.fromPretrained(
            localDir: directory,
            s3TokenizerWeights: directory.appendingPathComponent("s3_tokenizer.safetensors")
        )
    }

    func synthesize(_ request: SynthesisRequest) throws -> SpeechAudio {
        let reference = try AudioFileLoader.load(url: request.referenceAudio, targetSampleRate: sampleRate)
        let samples = try model.clone(
            referenceSamples: reference,
            sampleRate: sampleRate,
            text: request.text,
            languageId: request.language.rawValue,
            maxNewTokens: 384
        )
        return try SpeechAudio(samples: samples, sampleRate: Double(sampleRate))
    }
}
#endif
