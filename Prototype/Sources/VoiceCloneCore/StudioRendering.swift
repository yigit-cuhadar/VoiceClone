import Foundation
import NaturalLanguage

public struct StudioSectionRender: Sendable {
    public let requests: [SynthesisRequest]
    public let destination: URL
    public let model: StudioModel
}

public protocol StudioSectionRendering: Sendable {
    func render(_ section: StudioSectionRender, progress: @Sendable (Int, Int) -> Void) async throws -> String
    func concatenate(_ inputs: [URL], to output: URL) async throws
}

public struct RenderStudioSection: Sendable {
    private let workspace: any StudioWorkspaceStore
    private let renderer: any StudioSectionRendering

    public init(workspace: any StudioWorkspaceStore, renderer: any StudioSectionRendering) {
        self.workspace = workspace
        self.renderer = renderer
    }

    public func callAsFunction(
        _ section: StudioSection,
        project: StudioProject,
        voice: StudioVoice,
        model: StudioModel,
        progress: @Sendable (Int, Int) -> Void
    ) async throws -> StudioGeneration {
        guard project.voiceID == voice.id else { throw StudioError.missingVoice }
        let chunks = StudioScript.chunks(section.text, language: project.language)
        guard !chunks.isEmpty else { throw StudioError.missingScript }
        let requests = try chunks.map {
            try SynthesisRequest(text: $0, referenceAudio: workspace.audioURL(for: voice.id),
                                 referenceText: voice.transcript, language: project.language)
        }
        let id = UUID()
        let fingerprint = try await renderer.render(
            StudioSectionRender(requests: requests, destination: workspace.audioURL(for: id), model: model),
            progress: progress
        )
        return StudioGeneration(id: id, sourceText: section.text, voiceID: voice.id,
                                language: project.language, model: model, modelFingerprint: fingerprint)
    }
}

public enum StudioScript {
    public static func sections(from script: String) -> [StudioSection] {
        script.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(StudioSection.init(text:))
    }

    public static func chunks(_ text: String, language: SpeechLanguage) -> [String] {
        // The phone benchmark validated short utterances. Keep inference inputs
        // bounded while preserving the user's larger editable sections.
        let maxLength = 100
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(language == .turkish ? .turkish : .english)
        var chunks: [String] = []
        var cursor = text.startIndex
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            appendChunks(text[cursor..<range.upperBound], maxLength: maxLength, to: &chunks)
            cursor = range.upperBound
        }
        appendChunks(text[cursor...], maxLength: maxLength, to: &chunks)
        return chunks
    }

    private static func appendChunks(_ sentence: Substring, maxLength: Int, to chunks: inout [String]) {
        var current = ""
        for word in sentence.split(whereSeparator: \.isWhitespace) {
            if !current.isEmpty, current.count + word.count + 1 > maxLength {
                chunks.append(current)
                current = ""
            }
            var rest = word
            while rest.count > maxLength {
                chunks.append(String(rest.prefix(maxLength)))
                rest = rest.dropFirst(maxLength)
            }
            if !current.isEmpty { current += " " }
            current += rest
        }
        if !current.isEmpty { chunks.append(current) }
    }
}
