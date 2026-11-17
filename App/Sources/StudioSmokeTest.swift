#if DEBUG || VOICECLONE_SMOKE_TEST
import Foundation
import VoiceCloneCore
import VoiceCloneInfrastructure
#if os(iOS)
import UIKit
#endif

@MainActor
struct StudioSmokeTest {
    struct Script: Decodable {
        let transcript: String
        let text: String
    }

    let fixtures: URL
    let report: URL
    let workspace: URL
    let language: SpeechLanguage
    let requestedModel: StudioModel?
    let previewOnly: Bool
    let checkpointOnly: Bool

    static func configuration() -> Self? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--studio-smoke"),
              index + 1 < arguments.count,
              let language = SpeechLanguage(rawValue: arguments[index + 1]) else { return nil }
        let fixtureDirectory = ProcessInfo.processInfo.environment["VOICECLONE_SMOKE_FIXTURES"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.documentsDirectory.appending(path: "Benchmark", directoryHint: .isDirectory)
        let reports = ProcessInfo.processInfo.environment["VOICECLONE_SMOKE_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.documentsDirectory.appending(path: "StudioSmoke", directoryHint: .isDirectory)
        return Self(
            fixtures: fixtureDirectory,
            report: reports.appendingPathComponent("report.json"),
            workspace: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            language: language,
            requestedModel: arguments.indices.contains(index + 2) ? StudioModel(rawValue: arguments[index + 2]) : nil,
            previewOnly: arguments.contains("--preview-only"),
            checkpointOnly: arguments.contains("--checkpoint-only")
        )
    }

    func run(_ model: StudioViewModel) async {
        #if os(iOS)
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        #endif
        var result: [String: String] = ["language": language.rawValue]
        do {
            let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf:
                fixtures.appendingPathComponent("script-\(language.rawValue).json")))
            let reference = fixtures.appendingPathComponent("reference-\(language.rawValue).aiff")

            if let requestedModel {
                model.setModel(requestedModel)
                guard model.selectedModel == requestedModel else { throw SmokeError.incomplete }
            }
            result["model"] = model.selectedModel.rawValue
            let needsDownload = !model.readyModels.contains(model.selectedModel)
            if needsDownload {
                model.downloadModel(model.selectedModel)
                try await wait(for: model, timeout: .seconds(300))
                guard model.readyModels.contains(model.selectedModel) else { throw SmokeError.incomplete }
            }
            result["download"] = needsDownload ? "verified" : "cached"

            model.renameProject("Smoke project")
            model.setLanguage(language)
            try model.addVoice(name: "Synthetic reference", transcript: script.transcript, source: reference)
            model.appendScript("\(script.text) \(script.text)\n\n\(script.text)")
            if checkpointOnly {
                try await verifyRenderCheckpoint(model)
                result["checkpoint"] = "resumed"
                result["status"] = "passed"
            } else if previewOnly {
                try await verifyPreview(model)
                result["preview"] = "verified"
                result["status"] = "passed"
            } else {
                model.generate()
                try await wait(for: model)

                let initial = try require(model.project)
                guard initial.sections.count == 2, model.hasCompleteAudio else { throw SmokeError.incomplete }
                let first = initial.sections[0]
                let second = try require(initial.sections[1].generation)
                let original = try require(first.generation)

                if requestedModel != nil {
                    try await verifyPreview(model)
                    result["preview"] = "verified"
                }

                model.editSection(first.id, text: script.text)
                guard !model.hasCompleteAudio else { throw SmokeError.incomplete }
                model.generate(first.id)
                try await wait(for: model)
                let updated = try require(model.project)
                guard let replacement = updated.sections[0].generation, replacement.id != original.id, replacement.model == model.selectedModel,
                      updated.sections[1].generation == second, model.hasCompleteAudio else { throw SmokeError.incomplete }

                let reopened = try LocalStudioWorkspace(root: workspace).load()
                guard reopened.projects.first == updated, reopened.voices.count == 1 else { throw SmokeError.incomplete }

                model.exportProject()
                try await wait(for: model)
                let export = try require(model.exportURL)
                let expected = try AudioFiles.duration(of: model.audioURL(for: replacement.id))
                    + AudioFiles.duration(of: model.audioURL(for: second.id))
                let duration = try AudioFiles.duration(of: export)
                guard duration > 0, abs(expected - duration) < 0.001 else { throw SmokeError.incomplete }
                result["status"] = "passed"
                result["exportSeconds"] = String(duration)
            }
        } catch {
            result["status"] = "failed"
            result["error"] = error.localizedDescription
        }
        do {
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: report, options: .atomic)
        } catch {
            NSLog("Could not write studio smoke test result: %@", error.localizedDescription)
        }
    }

    private func verifyPreview(_ model: StudioViewModel) async throws {
        let project = try require(model.project)
        let selectedModel = model.selectedModel
        model.previewModel(selectedModel)
        try await wait(for: model)
        let preview = try require(model.preview)
        guard preview.model == selectedModel, try AudioFiles.duration(of: preview.url) > 0,
              model.project == project, model.selectedModel == selectedModel else { throw SmokeError.incomplete }
    }

    private func verifyRenderCheckpoint(_ model: StudioViewModel) async throws {
        let store = LocalStudioWorkspace(root: workspace)
        let project = try require(model.project)
        let section = try require(project.sections.first)
        let voice = try require(model.workspace.voices.first { $0.id == project.voiceID })
        let selectedModel = model.selectedModel
        #if os(iOS)
        let chunkLength = 55
        #else
        let chunkLength = 100
        #endif
        let initialRenderer = LocalStudioRenderer(models: StudioModelCache())
        let initial = RenderStudioSection(workspace: store, renderer: initialRenderer, maximumChunkLength: chunkLength)
        let interrupted = Task {
            try await initial(section, project: project, voice: voice, model: selectedModel) { completed, _ in
                if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await interrupted.value
            throw SmokeError.incomplete
        } catch is CancellationError {}

        let checkpoint = store.renderCheckpointURL(for: section.id)
        let firstClip = checkpoint.appendingPathComponent("0.wav")
        guard try AudioFiles.duration(of: firstClip) > 0 else { throw SmokeError.incomplete }
        let before = try firstClip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let resumed = RenderStudioSection(workspace: store, renderer: LocalStudioRenderer(models: StudioModelCache()),
                                          maximumChunkLength: chunkLength)
        let result = try await resumed(section, project: project, voice: voice, model: selectedModel) { _, _ in }
        let after = try firstClip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard before != nil, before == after, try AudioFiles.duration(of: store.audioURL(for: result.id)) > 0 else {
            throw SmokeError.incomplete
        }

        var committed = try store.load()
        guard let index = committed.projects.firstIndex(where: { $0.id == project.id }) else { throw SmokeError.incomplete }
        committed.projects[index].sections[0].generation = result
        try store.save(committed)
        guard !FileManager.default.fileExists(atPath: checkpoint.path) else { throw SmokeError.incomplete }
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw SmokeError.incomplete }
        return value
    }

    private func wait(for model: StudioViewModel, timeout: Duration = .seconds(120)) async throws {
        let deadline = ContinuousClock.now + timeout
        while model.isBusy {
            guard ContinuousClock.now < deadline else { throw SmokeError.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let message = model.error { throw SmokeError.workflow(message) }
    }

    private enum SmokeError: LocalizedError {
        case incomplete, timedOut, workflow(String)

        var errorDescription: String? {
            switch self {
            case .incomplete: "A section, saved workspace, or export did not match the expected result."
            case .timedOut: "The workflow timed out."
            case .workflow(let message): message
            }
        }
    }
}
#endif
