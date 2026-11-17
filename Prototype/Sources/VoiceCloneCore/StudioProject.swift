import Foundation

public enum StudioModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case int8
    case fp16
    case chatterbox

    public var id: Self { self }
    public var name: String {
        switch self {
        case .int8, .fp16: "OmniVoice \(rawValue.uppercased())"
        case .chatterbox: "Chatterbox Multilingual"
        }
    }

    public var repository: String {
        switch self {
        case .int8, .fp16: "aufklarer/OmniVoice-MLX-\(rawValue)"
        case .chatterbox: "aufklarer/Chatterbox-Multilingual-MLX-fp16"
        }
    }
    public var downloadBytes: Int64 {
        switch self {
        case .int8: 1_103_709_212
        case .fp16: 1_639_483_112
        case .chatterbox: 1_852_159_783
        }
    }
}

public struct StudioVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let transcript: String

    public init(id: UUID = UUID(), name: String, transcript: String) throws {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.name.isEmpty, !self.transcript.isEmpty else {
            throw StudioError.missingVoiceDetails
        }
    }
}

public struct StudioGeneration: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceText: String
    public let voiceID: UUID
    public let language: SpeechLanguage
    public let model: StudioModel
    public let modelFingerprint: String

    public init(id: UUID, sourceText: String, voiceID: UUID, language: SpeechLanguage,
                model: StudioModel, modelFingerprint: String) {
        self.id = id
        self.sourceText = sourceText
        self.voiceID = voiceID
        self.language = language
        self.model = model
        self.modelFingerprint = modelFingerprint
    }
}

public struct StudioSection: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var generation: StudioGeneration?

    public init(text: String = "") {
        id = UUID()
        self.text = text
    }

    public var preview: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Empty section"
    }
}

public struct StudioProject: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var voiceID: UUID?
    public var language: SpeechLanguage
    public var sections: [StudioSection]

    public init(name: String = "Untitled project") {
        id = UUID()
        self.name = name
        language = .english
        sections = [StudioSection()]
    }

    public func currentGeneration(for section: StudioSection) -> StudioGeneration? {
        guard let generation = section.generation,
              generation.sourceText == section.text,
              generation.voiceID == voiceID,
              generation.language == language else { return nil }
        return generation
    }
}

public struct StudioWorkspace: Codable, Sendable {
    public var projects: [StudioProject]
    public var voices: [StudioVoice]
    public var activeProjectID: UUID?
    public var model: StudioModel?

    public init() {
        let project = StudioProject()
        projects = [project]
        voices = []
        activeProjectID = project.id
    }

    public var assetIDs: Set<UUID> {
        Set(voices.map(\.id) + projects.flatMap { $0.sections.compactMap { $0.generation?.id } })
    }
}

public protocol StudioWorkspaceStore: Sendable {
    func load() throws -> StudioWorkspace
    func save(_ workspace: StudioWorkspace) throws
    func audioURL(for id: UUID) -> URL
    func renderCheckpointURL(for sectionID: UUID) -> URL
    func saveReference(_ url: URL, id: UUID) throws
    func removeAudio(_ ids: Set<UUID>)
}

public enum StudioError: LocalizedError {
    case missingVoiceDetails
    case missingVoice
    case missingScript
    case incompleteProject
    case invalidReference
    case unavailableModel

    public var errorDescription: String? {
        switch self {
        case .missingVoiceDetails: "Enter a voice name and the words spoken in the reference."
        case .missingVoice: "Choose a voice profile before generating."
        case .missingScript: "Enter some text to generate."
        case .incompleteProject: "Generate every non-empty section before exporting the project."
        case .invalidReference: "Choose a clear reference recording between 1 and 10 seconds."
        case .unavailableModel: "Download a compatible model before generating."
        }
    }
}
