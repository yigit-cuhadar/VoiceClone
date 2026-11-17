import CryptoKit
import Foundation
import VoiceCloneCore

public actor LocalStudioRenderer: StudioSectionRendering {
    private let models: StudioModelCache
    private var activeCheckpoints: Set<URL> = []

    public init(models: StudioModelCache) {
        self.models = models
    }

    public func render(_ section: StudioSectionRender, progress: @Sendable (Int, Int) -> Void) async throws -> String {
        if let checkpoint = section.checkpoint, !activeCheckpoints.insert(checkpoint).inserted {
            throw SynthesisError.renderInProgress
        }
        defer {
            if let checkpoint = section.checkpoint { activeCheckpoints.remove(checkpoint) }
        }
        let fingerprint = try await models.verify(section.model)
        try Task.checkCancellation()
        let staging = try stagingDirectory(for: section, fingerprint: fingerprint)
        defer {
            if section.checkpoint == nil { try? FileManager.default.removeItem(at: staging) }
        }

        var clips: [URL] = []
        var synthesize: SynthesizeSpeech?
        for (index, request) in section.requests.enumerated() {
            try Task.checkCancellation()
            progress(index, section.requests.count)
            try Task.checkCancellation()
            let clip = staging.appendingPathComponent("\(index).wav")
            if (try? AudioFiles.duration(of: clip)).map({ $0 > 0 }) != true {
                if FileManager.default.fileExists(atPath: clip.path) { try FileManager.default.removeItem(at: clip) }
                if synthesize == nil { synthesize = try await SynthesizeSpeech(synthesizer: load(section.model)) }
                try Task.checkCancellation()
                if let synthesize { try AudioFiles.writeWAV(try synthesize(request), to: clip) }
            }
            clips.append(clip)
        }
        try Task.checkCancellation()
        try AudioFiles.concatenateWAV(clips, to: section.destination)
        progress(section.requests.count, section.requests.count)
        return fingerprint
    }

    private func stagingDirectory(for section: StudioSectionRender, fingerprint: String) throws -> URL {
        let files = FileManager.default
        guard let checkpoint = section.checkpoint else {
            let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: temporary, withIntermediateDirectories: true)
            return temporary
        }

        let inputs = [[section.model.rawValue, fingerprint]] + section.requests.map {
            [$0.text, $0.language.rawValue, $0.referenceText, $0.referenceAudio.absoluteString]
        }
        let signature = SHA256.hash(data: try JSONEncoder().encode(inputs))
        let identity = Data(signature)
        let marker = checkpoint.appendingPathComponent("Inputs.sha256")
        if (try? Data(contentsOf: marker)) != identity {
            if files.fileExists(atPath: checkpoint.path) { try files.removeItem(at: checkpoint) }
            try files.createDirectory(at: checkpoint, withIntermediateDirectories: true)
            try identity.write(to: marker, options: .atomic)
        }
        return checkpoint
    }

    private func load(_ model: StudioModel) async throws -> any SpeechSynthesizing {
        switch model {
        case .int8: try await OmniVoiceSynthesizer.load(.int8, offline: true)
        case .fp16: try await OmniVoiceSynthesizer.load(.fp16, offline: true)
        case .chatterbox:
            #if os(macOS)
            try ChatterboxSynthesizer(directory: models.directory(for: model))
            #else
            throw StudioError.unavailableModel
            #endif
        }
    }

    public func concatenate(_ inputs: [URL], to output: URL) async throws {
        try AudioFiles.concatenateWAV(inputs, to: output)
    }
}
