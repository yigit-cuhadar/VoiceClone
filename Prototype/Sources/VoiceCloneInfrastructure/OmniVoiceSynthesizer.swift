import OmniVoiceTTS
import VoiceCloneCore
#if os(iOS)
import MLX
#endif

public final class OmniVoiceSynthesizer: SpeechSynthesizing {
    public enum Variant: String, Sendable {
        case int8
        case fp16
    }

    private let model: OmniVoiceTTSModel
    #if os(iOS)
    private static let configureMemoryCache: Void = {
        // iOS enforces a per-process memory limit below the device's physical RAM.
        MLX.Memory.cacheLimit = min(MLX.Memory.cacheLimit, 64 * 1_048_576)
    }()
    #endif

    private init(model: OmniVoiceTTSModel) {
        self.model = model
    }

    public static func load(_ variant: Variant, offline: Bool) async throws -> OmniVoiceSynthesizer {
        #if os(iOS)
        _ = configureMemoryCache
        #endif
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
