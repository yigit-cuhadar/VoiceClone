import Foundation
import OmniVoiceTTS
import VoiceCloneCore
#if os(iOS)
import MLX
import os
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
        MLX.Memory.cacheLimit = min(MLX.Memory.cacheLimit, 16 * 1_048_576)
    }()
    #endif

    private init(model: OmniVoiceTTSModel) {
        self.model = model
    }

    public static func load(_ variant: Variant, offline: Bool) async throws -> OmniVoiceSynthesizer {
        #if os(iOS)
        configureMemory()
        traceMemory("before load")
        #endif
        let model = try await OmniVoiceTTSModel.fromPretrained(
            modelId: "aufklarer/OmniVoice-MLX-\(variant.rawValue)",
            offlineMode: offline
        )
        #if os(iOS)
        traceMemory("after load")
        #endif
        return OmniVoiceSynthesizer(model: model)
    }

    public func synthesize(_ request: SynthesisRequest) throws -> SpeechAudio {
        #if os(iOS)
        Self.traceMemory("before chunk")
        defer { Self.traceMemory("after chunk") }
        #endif
        let samples = try model.generate(
            text: request.text,
            referenceAudio: request.referenceAudio,
            referenceText: request.referenceText,
            language: request.language.rawValue
        )
        return try SpeechAudio(samples: samples, sampleRate: Double(model.sampleRate))
    }

    #if os(iOS)
    static func configureMemory() { _ = configureMemoryCache }

    static func traceMemory(_ stage: String) {
        guard ProcessInfo.processInfo.environment["VOICECLONE_TRACE_MEMORY"] == "1" else { return }
        let mebibyte = 1_048_576
        let message = "\(stage)  headroom \(os_proc_available_memory() / mebibyte) MiB  MLX active \(MLX.Memory.activeMemory / mebibyte) MiB  MLX peak \(MLX.Memory.peakMemory / mebibyte) MiB\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
    #endif
}
