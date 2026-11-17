import AudioCommon
import Foundation
import VoiceCloneCore

public struct LocalStudioWorkspace: StudioWorkspaceStore {
    private let root: URL
    private let media: URL
    private let manifest: URL

    public init(root: URL) {
        self.root = root
        media = root.appendingPathComponent("Audio", isDirectory: true)
        manifest = root.appendingPathComponent("Workspace.json")
    }

    public func load() throws -> StudioWorkspace {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return StudioWorkspace() }
        return try JSONDecoder().decode(StudioWorkspace.self, from: Data(contentsOf: manifest))
    }

    public func save(_ workspace: StudioWorkspace) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: manifest, options: .atomic)
    }

    public func audioURL(for id: UUID) -> URL {
        media.appendingPathComponent(id.uuidString).appendingPathExtension("wav")
    }

    public func saveReference(_ url: URL, id: UUID) throws {
        let duration = try AudioFiles.duration(of: url)
        guard (1...10).contains(duration) else { throw StudioError.invalidReference }
        let samples = try AudioFileLoader.load(url: url, targetSampleRate: 24_000)
        let audio = try SpeechAudio(samples: samples, sampleRate: 24_000)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try AudioFiles.writeWAV(audio, to: audioURL(for: id))
    }

    public func removeAudio(_ ids: Set<UUID>) {
        for id in ids { try? FileManager.default.removeItem(at: audioURL(for: id)) }
    }
}
