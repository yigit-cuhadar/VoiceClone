#if os(iOS)
import AudioCommon
import Foundation
import MLX
import OmniVoiceTTS
import VoiceCloneCore

/// Runs the same OmniVoice model without keeping its reference encoder loaded
/// during diffusion and waveform decoding.
final class MobileOmniVoiceSynthesizer: SpeechSynthesizing {
    private let referenceTokens: MLXArray
    private let backbone: OmniVoiceModel
    private let decoder: OmniVoiceCodec
    private let inputBuilder: OmniVoiceInputBuilder
    private let configuration: OmniVoiceConfig

    private init(referenceTokens: MLXArray, backbone: OmniVoiceModel, decoder: OmniVoiceCodec,
                 inputBuilder: OmniVoiceInputBuilder, configuration: OmniVoiceConfig) {
        self.referenceTokens = referenceTokens
        self.backbone = backbone
        self.decoder = decoder
        self.inputBuilder = inputBuilder
        self.configuration = configuration
    }

    static func load(bundle: URL, referenceAudio: URL) async throws -> MobileOmniVoiceSynthesizer {
        OmniVoiceSynthesizer.configureMemory()
        let configuration = OmniVoiceConfig()
        let codec = bundle.appendingPathComponent("audio_tokenizer/model.safetensors")
        OmniVoiceSynthesizer.traceMemory("before reference encode")
        let prompt = try encodeReference(referenceAudio, weights: codec, sampleRate: configuration.sampleRate)
        MLX.Stream.gpu.synchronize()
        MLX.Memory.clearCache()
        OmniVoiceSynthesizer.traceMemory("after releasing reference encoder")
        try Task.checkCancellation()

        let metadata = try JSONDecoder().decode(BundleConfiguration.self, from: Data(contentsOf: bundle.appendingPathComponent("config.json")))
        let backbone = OmniVoiceModel(configuration)
        try backbone.loadWeights(from: bundle.appendingPathComponent("model.safetensors"),
                                 quantization: (metadata.quantization.groupSize, metadata.quantization.bits))
        let decoder = OmniVoiceCodec()
        try decoder.loadWeights(from: codec)
        let tokenizer = try await OmniVoiceTokenizer.load(from: bundle)
        OmniVoiceSynthesizer.traceMemory("after loading generation model")

        return MobileOmniVoiceSynthesizer(
            referenceTokens: MLXArray(prompt.values).reshaped(prompt.shape), backbone: backbone,
            decoder: decoder, inputBuilder: OmniVoiceInputBuilder(tokenizer: tokenizer, config: configuration),
            configuration: configuration
        )
    }

    func synthesize(_ request: SynthesisRequest) throws -> SpeechAudio {
        let targetLength = RuleDurationEstimator.shared.estimateTargetTokens(
            targetText: request.text, refText: request.referenceText,
            numRefAudioTokens: referenceTokens.dim(referenceTokens.ndim - 1)
        )
        let inputs = inputBuilder.buildInputs(text: request.text, refText: request.referenceText,
                                              lang: request.language.rawValue, refAudioTokens: referenceTokens,
                                              targetLen: targetLength, denoise: true, instruct: nil)
        OmniVoiceSynthesizer.traceMemory("before diffusion")
        let tokens = backbone.generateTokens(condInputIds: inputs.inputIds, audioMask: inputs.audioMask,
                                            targetLen: targetLength, numSteps: configuration.numInferenceSteps)
        OmniVoiceSynthesizer.traceMemory("after diffusion")
        let waveform = decoder.decode(tokens).asType(.float32).asArray(Float.self)
        OmniVoiceSynthesizer.traceMemory("after waveform decode")
        return try SpeechAudio(samples: Self.finishWaveform(waveform, sampleRate: configuration.sampleRate),
                               sampleRate: Double(configuration.sampleRate))
    }

    private static func encodeReference(_ reference: URL, weights: URL,
                                        sampleRate: Int) throws -> (values: [Int32], shape: [Int]) {
        try autoreleasepool {
            let encoder = OmniVoiceCodecEncoder()
            try encoder.loadWeights(from: weights)
            let samples = try AudioFileLoader.load(url: reference, targetSampleRate: sampleRate)
            let codes = encoder.encode(MLXArray(samples))
            return (codes.asArray(Int32.self), codes.shape)
        }
    }

    // Match the upstream OmniVoice output treatment: keep a 100 ms lead before
    // sustained speech and fade both edges over at most 100 ms.
    private static func finishWaveform(_ waveform: [Float], sampleRate: Int) -> [Float] {
        let window = max(1, sampleRate / 100)
        let lead = sampleRate / 10
        let onset = stride(from: 0, to: max(0, waveform.count - 6 * window + 1), by: window).first { start in
            (0..<6).allSatisfy { index in
                let from = start + index * window
                let energy = waveform[from..<(from + window)].reduce(Float.zero) { $0 + $1 * $1 }
                return (energy / Float(window)).squareRoot() >= 0.02
            }
        }
        var result = Array(waveform[max(0, (onset ?? 0) - lead)...])
        let fade = min(lead, result.count / 2)
        for index in 0..<fade {
            let weight = Float(0.5 - 0.5 * cos(.pi * Double(index) / Double(fade)))
            result[index] *= weight
            result[result.count - 1 - index] *= weight
        }
        return result
    }

    private struct BundleConfiguration: Decodable {
        let quantization: Quantization

        struct Quantization: Decodable {
            let groupSize: Int
            let bits: Int

            enum CodingKeys: String, CodingKey {
                case groupSize = "group_size"
                case bits
            }
        }
    }
}
#endif
