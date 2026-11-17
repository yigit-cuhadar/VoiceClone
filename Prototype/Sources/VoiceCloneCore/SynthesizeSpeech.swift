import Foundation

public enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case turkish = "tr"
}

public struct SynthesisRequest: Sendable {
    public let text: String
    public let referenceAudio: URL
    public let referenceText: String
    public let language: SpeechLanguage

    public init(text: String, referenceAudio: URL, referenceText: String, language: SpeechLanguage) throws {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.referenceText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.referenceAudio = referenceAudio
        self.language = language
        guard !self.text.isEmpty, !self.referenceText.isEmpty else {
            throw SynthesisError.missingText
        }
    }
}

public struct SpeechAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.0001 }) else {
            throw SynthesisError.invalidOutput
        }
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: Double {
        Double(samples.count) / sampleRate
    }
}

public protocol SpeechSynthesizing {
    func synthesize(_ request: SynthesisRequest) throws -> SpeechAudio
}

public struct SynthesizeSpeech {
    private let synthesizer: any SpeechSynthesizing

    public init(synthesizer: any SpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    public func callAsFunction(_ request: SynthesisRequest) throws -> SpeechAudio {
        try synthesizer.synthesize(request)
    }
}

public enum SynthesisError: LocalizedError {
    case missingText
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .missingText: "Both the reference transcript and the text to synthesize are required."
        case .invalidOutput: "The synthesizer did not produce valid speech audio."
        }
    }
}
