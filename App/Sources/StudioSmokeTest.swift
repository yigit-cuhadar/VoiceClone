#if DEBUG || VOICECLONE_SMOKE_TEST
import Foundation
import VoiceCloneCore
import VoiceCloneInfrastructure

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
            language: language
        )
    }

    func run(_ model: StudioViewModel) async {
        var result: [String: String] = ["language": language.rawValue]
        do {
            let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf:
                fixtures.appendingPathComponent("script-\(language.rawValue).json")))
            let reference = fixtures.appendingPathComponent("reference-\(language.rawValue).aiff")

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
            model.generate()
            try await wait(for: model)

            let initial = try require(model.project)
            guard initial.sections.count == 2, model.hasCompleteAudio else { throw SmokeError.incomplete }
            let first = initial.sections[0]
            let second = try require(initial.sections[1].generation)
            let original = try require(first.generation)

            model.editSection(first.id, text: script.text)
            guard !model.hasCompleteAudio else { throw SmokeError.incomplete }
            model.generate(first.id)
            try await wait(for: model)
            let updated = try require(model.project)
            guard let replacement = updated.sections[0].generation, replacement.id != original.id,
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
