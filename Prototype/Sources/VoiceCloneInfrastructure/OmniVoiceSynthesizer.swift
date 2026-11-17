import OmniVoiceTTS
import VoiceCloneCore

public final class OmniVoiceSynthesizer: SpeechSynthesizing {
    public enum Variant: String {
        case int8
        case fp16
    }

    private let model: OmniVoiceTTSModel

    private init(model: OmniVoiceTTSModel) {
        self.model = model
    }

    public static func load(_ variant: Variant, offline: Bool) async throws -> OmniVoiceSynthesizer {
        let model = try await OmniVoiceTTSModel.fromPretrained(
            modelId: "aufklarer/OmniVoice-MLX-\(variant.rawValue)",
            offlineMode: offline
        )
        return OmniVoiceSynthesizer(model: model)
    }

    public func synthesize(_ request: SynthesisRequest) throws -> SpeechAudio {
        let samples = try model.generate(
            text: request.text,
            referenceAudio: request.referenceAudio,
            referenceText: request.referenceText,
            language: request.language.rawValue
        )
        return try SpeechAudio(samples: samples, sampleRate: Double(model.sampleRate))
    }
}
