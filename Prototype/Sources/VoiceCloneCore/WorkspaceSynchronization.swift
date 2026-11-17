import Foundation

public struct CloudWorkspace: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var workspace: StudioWorkspace
    public var availableAudio: Set<UUID>

    public init(workspace: StudioWorkspace, availableAudio: Set<UUID> = []) {
        self.workspace = workspace
        self.availableAudio = availableAudio
    }
}

public struct RemoteWorkspace: Sendable {
    public let document: CloudWorkspace
    public let revision: String?

    public init(document: CloudWorkspace, revision: String?) {
        self.document = document
        self.revision = revision
    }
}

public struct WorkspaceSyncState: Codable, Sendable {
    public var baseline = StudioWorkspace.empty
    public var pendingUploads: Set<UUID> = []
    public var audioAliases: [UUID: UUID] = [:]

    public init() {}
}

public protocol WorkspaceCloudTransport: Sendable {
    func fetchWorkspace() async throws -> RemoteWorkspace
    func saveWorkspace(_ document: CloudWorkspace, revision: String?, deletingAudio: Set<UUID>) async throws
    func containsAudio(_ id: UUID) async throws -> Bool
    func uploadAudio(_ id: UUID, from source: URL, allowsCellular: Bool) async throws
    func downloadAudio(_ id: UUID, to destination: URL, allowsCellular: Bool) async throws
    func deleteWorkspace() async throws
}

public protocol SynchronizingWorkspaceStore: StudioWorkspaceStore {
    func loadForSynchronization() throws -> StudioWorkspace
    @discardableResult func applySynchronizedWorkspace(_ workspace: StudioWorkspace) throws -> Bool
    func loadSyncState() throws -> WorkspaceSyncState
    func saveSyncState(_ state: WorkspaceSyncState) throws
    func hasAudio(_ id: UUID) -> Bool
    func copyAudio(from sourceID: UUID, to destinationID: UUID) throws
}

public enum WorkspaceSyncError: LocalizedError {
    case conflict, accountChanged, unavailable, unsupportedFormat, invalidAudio, workspaceBusy

    public var errorDescription: String? {
        switch self {
        case .conflict: "Another device saved changes. Sync will retry."
        case .accountChanged: "Your iCloud account changed. Reopen your workspace to continue."
        case .unavailable: "Sign in to iCloud in system settings to sync your library."
        case .unsupportedFormat: "Update VoiceClone to open this cloud library."
        case .invalidAudio: "An audio file failed its integrity check. Sync will retry."
        case .workspaceBusy: "Sync will continue when the current operation finishes."
        }
    }
}

extension StudioWorkspace {
    public static var empty: Self {
        var value = Self()
        value.projects = []
        value.activeProjectID = nil
        return value
    }
}

/// Three-way merging preserves concurrent project edits as separate projects.
public struct WorkspaceMergeResult: Sendable {
    public let workspace: StudioWorkspace
    public let audioAliases: [UUID: UUID]
}

public enum WorkspaceMerge {
    public static func merge(base: StudioWorkspace, local: StudioWorkspace, remote: StudioWorkspace) throws -> WorkspaceMergeResult {
        for workspace in [base, local, remote] {
            guard Set(workspace.projects.map(\.id)).count == workspace.projects.count,
                  Set(workspace.voices.map(\.id)).count == workspace.voices.count else {
                throw WorkspaceSyncError.unsupportedFormat
            }
        }
        var result = StudioWorkspace.empty
        let baseVoices = Dictionary(uniqueKeysWithValues: base.voices.map { ($0.id, $0) })
        let localVoices = Dictionary(uniqueKeysWithValues: local.voices.map { ($0.id, $0) })
        let remoteVoices = Dictionary(uniqueKeysWithValues: remote.voices.map { ($0.id, $0) })
        var localVoiceAliases: [UUID: UUID] = [:]
        for id in Set(baseVoices.keys).union(localVoices.keys).union(remoteVoices.keys).sorted(by: uuidOrder) {
            let baselineValue = baseVoices[id], localValue = localVoices[id], remoteValue = remoteVoices[id]
            if localValue == baselineValue { if let remoteValue { result.voices.append(remoteValue) } }
            else if remoteValue == baselineValue || localValue == remoteValue { if let localValue { result.voices.append(localValue) } }
            else {
                if let remoteValue { result.voices.append(remoteValue) }
                if let localValue {
                    let copy = try StudioVoice(name: localValue.name + " (Conflicted copy)", transcript: localValue.transcript)
                    result.voices.append(copy)
                    localVoiceAliases[id] = copy.id
                }
            }
        }

        let baseProjects = Dictionary(uniqueKeysWithValues: base.projects.map { ($0.id, $0) })
        let localProjects = Dictionary(uniqueKeysWithValues: local.projects.map { ($0.id, $0) })
        let remoteProjects = Dictionary(uniqueKeysWithValues: remote.projects.map { ($0.id, $0) })
        for id in Set(baseProjects.keys).union(localProjects.keys).union(remoteProjects.keys).sorted(by: uuidOrder) {
            let baselineValue = baseProjects[id], localValue = localProjects[id].map { remapVoice($0, aliases: localVoiceAliases) }, remoteValue = remoteProjects[id]
            if localValue == baselineValue { if let remoteValue { result.projects.append(remoteValue) } }
            else if remoteValue == baselineValue || localValue == remoteValue { if let localValue { result.projects.append(localValue) } }
            else if let baselineValue, let localValue, let remoteValue,
                    let combined = mergeProject(base: baselineValue, local: localValue, remote: remoteValue) {
                result.projects.append(combined)
            } else {
                if let remoteValue { result.projects.append(remoteValue) }
                if let localValue {
                    var copy = StudioProject(name: localValue.name + " (Conflicted copy)")
                    copy.voiceID = localValue.voiceID
                    copy.language = localValue.language
                    copy.sections = localValue.sections.map { section in
                        var copy = StudioSection(text: section.text)
                        copy.generation = section.generation
                        return copy
                    }
                    result.projects.append(copy)
                }
            }
        }
        // Preserve a profile that is still referenced by a retained project.
        let referencedVoices = Set(result.projects.compactMap(\.voiceID))
        let existingVoices = Set(result.voices.map(\.id))
        for id in referencedVoices.subtracting(existingVoices).sorted(by: uuidOrder) {
            if let voice = localVoices[id] ?? remoteVoices[id] ?? baseVoices[id] { result.voices.append(voice) }
        }
        result.projects.sort { uuidOrder($0.id, $1.id) }
        result.voices.sort { uuidOrder($0.id, $1.id) }
        result.model = local.model == base.model ? remote.model : local.model
        let active = local.activeProjectID == base.activeProjectID ? remote.activeProjectID : local.activeProjectID
        result.activeProjectID = result.projects.first { $0.id == active }?.id ?? result.projects.first?.id
        let aliases = Dictionary(uniqueKeysWithValues: localVoiceAliases.map { ($0.value, $0.key) })
        return WorkspaceMergeResult(workspace: result, audioAliases: aliases)
    }

    // Independent section edits can share one project. Conflicting values keep both projects.
    private static func mergeProject(base: StudioProject, local: StudioProject, remote: StudioProject) -> StudioProject? {
        let scalarConflict = (local.name != base.name && remote.name != base.name && local.name != remote.name)
            || (local.voiceID != base.voiceID && remote.voiceID != base.voiceID && local.voiceID != remote.voiceID)
            || (local.language != base.language && remote.language != base.language && local.language != remote.language)
        guard !scalarConflict else { return nil }
        let baseOrder = base.sections.map(\.id)
        let localOrder = local.sections.map(\.id)
        let remoteOrder = remote.sections.map(\.id)
        guard localOrder == baseOrder || remoteOrder == baseOrder || localOrder == remoteOrder else { return nil }
        let original = Dictionary(base.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localSections = Dictionary(local.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteSections = Dictionary(remote.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sections: [UUID: StudioSection] = [:]
        for id in Set(baseOrder).union(localOrder).union(remoteOrder) {
            let before = original[id], ours = localSections[id], theirs = remoteSections[id]
            if ours == before { sections[id] = theirs }
            else if theirs == before || ours == theirs { sections[id] = ours }
            else { return nil }
        }
        var project = remote
        project.name = local.name == base.name ? remote.name : local.name
        project.voiceID = local.voiceID == base.voiceID ? remote.voiceID : local.voiceID
        project.language = local.language == base.language ? remote.language : local.language
        let order = localOrder == baseOrder ? remoteOrder : localOrder
        project.sections = order.compactMap { sections[$0] }
        return project
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool { lhs.uuidString < rhs.uuidString }

    private static func remapVoice(_ project: StudioProject, aliases: [UUID: UUID]) -> StudioProject {
        guard let voice = project.voiceID, let replacement = aliases[voice] else { return project }
        var copy = project
        copy.voiceID = replacement
        for index in copy.sections.indices {
            if let generation = copy.sections[index].generation, generation.voiceID == voice {
                copy.sections[index].generation = StudioGeneration(
                    id: generation.id, sourceText: generation.sourceText, voiceID: replacement,
                    language: generation.language, model: generation.model, modelFingerprint: generation.modelFingerprint)
            }
        }
        return copy
    }
}

@MainActor
public final class SynchronizeWorkspace {
    private let store: any SynchronizingWorkspaceStore
    private let cloud: any WorkspaceCloudTransport

    public init(store: any SynchronizingWorkspaceStore, cloud: any WorkspaceCloudTransport) {
        self.store = store
        self.cloud = cloud
    }

    public func callAsFunction(transferAudio: () -> Bool, allowsCellular: () -> Bool,
                               canApply: () -> Bool, didApply: () -> Void) async throws -> Int {
        for attempt in 0..<3 {
            do {
                return try await synchronize(transferAudio: transferAudio, allowsCellular: allowsCellular,
                                             canApply: canApply, didApply: didApply)
            } catch WorkspaceSyncError.conflict {
                if attempt == 2 { throw WorkspaceSyncError.conflict }
            }
        }
        return 0
    }

    private func synchronize(transferAudio: () -> Bool, allowsCellular: () -> Bool,
                              canApply: () -> Bool, didApply: () -> Void) async throws -> Int {
        let remote = try await cloud.fetchWorkspace()
        try Task.checkCancellation()
        guard remote.document.schemaVersion == 1 else { throw WorkspaceSyncError.unsupportedFormat }
        guard canApply() else { throw WorkspaceSyncError.workspaceBusy }
        var state = try store.loadSyncState()
        let merge = try WorkspaceMerge.merge(base: state.baseline, local: store.loadForSynchronization(),
                                              remote: remote.document.workspace)
        let merged = merge.workspace
        state.audioAliases.merge(merge.audioAliases) { _, new in new }
        // Record aliases before committing a conflict copy, so interrupted copies can resume.
        try store.saveSyncState(state)
        for (destination, source) in state.audioAliases where store.hasAudio(source) && !store.hasAudio(destination) {
            try store.copyAudio(from: source, to: destination)
        }
        if try store.applySynchronizedWorkspace(merged) { didApply() }
        // Save the merged local workspace before advancing the baseline.
        state.baseline = remote.document.workspace
        try store.saveSyncState(state)

        var available = remote.document.availableAudio
        for id in merged.assetIDs.subtracting(available).sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            guard transferAudio() else { break }
            if !store.hasAudio(id), let source = state.audioAliases[id] {
                if !store.hasAudio(source), available.contains(source) {
                    try await cloud.downloadAudio(source, to: store.audioURL(for: source), allowsCellular: allowsCellular())
                }
                if store.hasAudio(source) { try store.copyAudio(from: source, to: id) }
            }
            guard store.hasAudio(id) else { continue }
            state.pendingUploads.insert(id)
            try store.saveSyncState(state)
            try await cloud.uploadAudio(id, from: store.audioURL(for: id), allowsCellular: allowsCellular())
            available.insert(id)
        }

        try Task.checkCancellation()
        guard canApply() else { throw WorkspaceSyncError.workspaceBusy }
        // Local editing may continue while uploads run. Read it again before committing.
        let current = try store.loadForSynchronization()
        let garbage = available.union(state.pendingUploads).subtracting(current.assetIDs)
        var deleting: Set<UUID> = []
        for id in garbage.sorted(by: { $0.uuidString < $1.uuidString }).prefix(100) {
            let exists: Bool
            if available.contains(id) { exists = true }
            else { exists = try await cloud.containsAudio(id) }
            if exists { deleting.insert(id) }
            else { state.pendingUploads.remove(id) }
        }
        available.subtract(deleting)
        let document = CloudWorkspace(workspace: current, availableAudio: available)
        if document != remote.document || !deleting.isEmpty {
            try await cloud.saveWorkspace(document, revision: remote.revision, deletingAudio: deleting)
        }
        state.baseline = current
        state.pendingUploads.subtract(available.union(deleting))
        state.audioAliases = state.audioAliases.filter { current.assetIDs.contains($0.key) && !store.hasAudio($0.key) }
        try store.saveSyncState(state)

        for id in current.assetIDs.intersection(available).sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            guard transferAudio() else { break }
            if !store.hasAudio(id) {
                try await cloud.downloadAudio(id, to: store.audioURL(for: id), allowsCellular: allowsCellular())
                if try store.loadForSynchronization().assetIDs.contains(id) { didApply() }
                else { store.removeAudio([id]) }
            }
        }
        let latest = try store.loadForSynchronization()
        return latest.assetIDs.filter { !store.hasAudio($0) || !available.contains($0) }.count
    }
}
