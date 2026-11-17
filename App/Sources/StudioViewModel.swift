import Foundation
import Observation
import VoiceCloneCore
import VoiceCloneInfrastructure

@MainActor
@Observable
final class StudioViewModel {
    private let store: any StudioWorkspaceStore
    private let renderer: any StudioSectionRendering
    private let renderSection: RenderStudioSection
    private let models: StudioModelCache
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var loadError: (any Error)?

    private(set) var workspace = StudioWorkspace()
    private(set) var readyModels: Set<StudioModel> = []
    private(set) var status: String?
    private(set) var progress: Double?
    private(set) var exportURL: URL?
    var error: String?

    init(store: any StudioWorkspaceStore, renderer: any StudioSectionRendering, models: StudioModelCache) {
        self.store = store
        self.renderer = renderer
        self.models = models
        renderSection = RenderStudioSection(workspace: store, renderer: renderer)
        do { workspace = try store.load() }
        catch {
            loadError = error
            self.error = error.localizedDescription
        }
        refreshModels()
    }

    var project: StudioProject? {
        workspace.projects.first { $0.id == workspace.activeProjectID }
    }

    var recommendedModel: StudioModel {
        #if os(macOS)
        let memory = ProcessInfo.processInfo.physicalMemory
        let disk = (try? URL.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if memory >= 24 * 1_073_741_824, readyModels.contains(.fp16) || disk >= StudioModel.fp16.downloadBytes {
            return .fp16
        }
        #endif
        return .int8
    }

    var supportedModels: [StudioModel] {
        #if os(iOS)
        [.int8]
        #else
        StudioModel.allCases
        #endif
    }

    var selectedModel: StudioModel {
        if let model = workspace.model, supportedModels.contains(model) { return model }
        return recommendedModel
    }

    var isBusy: Bool { operationID != nil }

    var hasCompleteAudio: Bool {
        guard let project else { return false }
        let sections = project.sections.filter { !$0.text.isBlank }
        return !sections.isEmpty && sections.allSatisfy { project.currentGeneration(for: $0) != nil }
    }

    func audioURL(for id: UUID) -> URL {
        store.audioURL(for: id)
    }

    func selectProject(_ id: UUID) {
        edit { $0.activeProjectID = id }
    }

    func addProject() {
        let project = StudioProject()
        edit {
            $0.projects.insert(project, at: 0)
            $0.activeProjectID = project.id
        }
    }

    func renameProject(_ name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        editProject { $0.name = normalized }
    }

    func deleteProject() {
        guard let id = project?.id else { return }
        edit { workspace in
            workspace.projects.removeAll { $0.id == id }
            workspace.activeProjectID = workspace.projects.first?.id
        }
    }

    func setVoice(_ id: UUID?) {
        editProject { $0.voiceID = id }
    }

    func setLanguage(_ language: SpeechLanguage) {
        editProject { $0.language = language }
    }

    func setModel(_ model: StudioModel) {
        guard supportedModels.contains(model) else { return }
        edit { $0.model = model }
    }

    func addSection(_ text: String) {
        editProject { $0.sections.append(StudioSection(text: text)) }
    }

    func appendScript(_ script: String) {
        let sections = StudioScript.sections(from: script)
        guard !sections.isEmpty else { return }
        editProject {
            $0.sections.removeAll { $0.text.isBlank && $0.generation == nil }
            $0.sections.append(contentsOf: sections)
        }
    }

    func editSection(_ id: UUID, text: String) {
        editProject { project in
            guard let index = project.sections.firstIndex(where: { $0.id == id }) else { return }
            project.sections[index].text = text
        }
    }

    func deleteSection(_ id: UUID) {
        editProject { $0.sections.removeAll { $0.id == id } }
    }

    func moveSection(_ id: UUID, offset: Int) {
        editProject { project in
            guard let from = project.sections.firstIndex(where: { $0.id == id }),
                  project.sections.indices.contains(from + offset) else { return }
            project.sections.swapAt(from, from + offset)
        }
    }

    func addVoice(name: String, transcript: String, source: URL) throws {
        let voice = try StudioVoice(name: name, transcript: transcript)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store.saveReference(source, id: voice.id)
        var next = workspace
        next.voices.append(voice)
        if let index = next.projects.firstIndex(where: { $0.id == next.activeProjectID }) {
            next.projects[index].voiceID = voice.id
        }
        do { try save(next) }
        catch {
            store.removeAudio([voice.id])
            throw error
        }
    }

    func deleteVoice(_ id: UUID) {
        edit { workspace in
            workspace.voices.removeAll { $0.id == id }
            for index in workspace.projects.indices where workspace.projects[index].voiceID == id {
                workspace.projects[index].voiceID = nil
            }
        }
    }

    func downloadModel(_ model: StudioModel) {
        perform("Downloading \(model.name)…") { id in
            defer { self.refreshModels() }
            try await self.models.download(model) { [weak self] value in
                Task { @MainActor in self?.updateProgress(id, value: value) }
            }
        }
    }

    func removeModel(_ model: StudioModel) {
        perform("Removing \(model.name)…") { _ in
            defer { self.refreshModels() }
            try await self.models.remove(model)
        }
    }

    func generate(_ sectionID: UUID? = nil) {
        #if targetEnvironment(simulator)
        error = "Speech generation requires a physical iPhone."
        #else
        guard let project, let voice = workspace.voices.first(where: { $0.id == project.voiceID }) else {
            error = StudioError.missingVoice.localizedDescription
            return
        }
        let model = selectedModel
        guard readyModels.contains(model) else {
            error = StudioError.unavailableModel.localizedDescription
            return
        }
        let sections = project.sections.filter { section in
            guard !section.text.isBlank else { return false }
            if let sectionID { return section.id == sectionID }
            return project.currentGeneration(for: section) == nil
        }
        guard !sections.isEmpty else { return }
        perform("Preparing \(model.name)…") { id in
            defer { self.refreshModels() }
            for (offset, section) in sections.enumerated() {
                try Task.checkCancellation()
                self.status = "Generating section \(offset + 1) of \(sections.count)…"
                let result = try await self.renderSection(section, project: project, voice: voice, model: model) {
                    [weak self] completed, total in
                    let value = (Double(offset) + Double(completed) / Double(total)) / Double(sections.count)
                    Task { @MainActor in self?.updateProgress(id, value: value) }
                }
                var next = self.workspace
                guard let index = next.projects.firstIndex(where: { $0.id == project.id }),
                      let sectionIndex = next.projects[index].sections.firstIndex(where: { $0.id == section.id }) else {
                    self.store.removeAudio([result.id])
                    return
                }
                next.projects[index].sections[sectionIndex].generation = result
                do { try self.save(next) }
                catch {
                    self.store.removeAudio([result.id])
                    throw error
                }
            }
        }
        #endif
    }

    func exportProject() {
        guard let project, hasCompleteAudio else {
            error = StudioError.incompleteProject.localizedDescription
            return
        }
        let inputs = project.sections.compactMap { project.currentGeneration(for: $0) }.map { audioURL(for: $0.id) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let basename = project.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent(String(basename.prefix(100))).appendingPathExtension("wav")
        perform("Preparing WAV…") { _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try await self.renderer.concatenate(inputs, to: destination)
                if let previous = self.exportURL { try? FileManager.default.removeItem(at: previous.deletingLastPathComponent()) }
                self.exportURL = destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }

    func cancel() { operation?.cancel() }

    func refreshModels() {
        readyModels = Set(supportedModels.filter(models.isReady))
    }

    private func updateProgress(_ id: UUID, value: Double) {
        guard operationID == id else { return }
        progress = value
    }

    private func perform(_ label: String, work: @escaping @MainActor (UUID) async throws -> Void) {
        guard !isBusy else { return }
        let id = UUID()
        operationID = id
        status = label
        progress = nil
        error = nil
        operation = Task {
            defer {
                status = nil
                progress = nil
                operationID = nil
                operation = nil
            }
            do { try await work(id) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }

    private func edit(_ mutate: (inout StudioWorkspace) -> Void) {
        guard !isBusy else { return }
        var next = workspace
        mutate(&next)
        do { try save(next) }
        catch { self.error = error.localizedDescription }
    }

    private func editProject(_ mutate: (inout StudioProject) -> Void) {
        edit { workspace in
            guard let index = workspace.projects.firstIndex(where: { $0.id == workspace.activeProjectID }) else { return }
            mutate(&workspace.projects[index])
        }
    }

    private func save(_ next: StudioWorkspace) throws {
        if let loadError { throw loadError }
        try store.save(next)
        if let exportURL {
            try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
            self.exportURL = nil
        }
        let unused = workspace.assetIDs.subtracting(next.assetIDs)
        workspace = next
        store.removeAudio(unused)
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
