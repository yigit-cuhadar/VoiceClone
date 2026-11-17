import Foundation
import VoiceCloneCore

public actor OmniVoiceStudioRenderer: StudioSectionRendering {
    private let models: StudioModelCache

    public init(models: StudioModelCache) {
        self.models = models
    }

    public func render(_ section: StudioSectionRender, progress: @Sendable (Int, Int) -> Void) async throws -> String {
        let fingerprint = try await models.verify(section.model)
        try Task.checkCancellation()
        let variant: OmniVoiceSynthesizer.Variant = section.model == .int8 ? .int8 : .fp16
        let synthesizer = try await OmniVoiceSynthesizer.load(variant, offline: true)
        let synthesize = SynthesizeSpeech(synthesizer: synthesizer)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var clips: [URL] = []
        for (index, request) in section.requests.enumerated() {
            try Task.checkCancellation()
            progress(index, section.requests.count)
            let clip = staging.appendingPathComponent("\(index).wav")
            try AudioFiles.writeWAV(try synthesize(request), to: clip)
            clips.append(clip)
        }
        try Task.checkCancellation()
        try AudioFiles.concatenateWAV(clips, to: section.destination)
        progress(section.requests.count, section.requests.count)
        return fingerprint
    }

    public func concatenate(_ inputs: [URL], to output: URL) async throws {
        try AudioFiles.concatenateWAV(inputs, to: output)
    }
}
