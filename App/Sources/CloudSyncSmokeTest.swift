#if DEBUG || VOICECLONE_SMOKE_TEST
import CloudKit
import CryptoKit
import Foundation
import VoiceCloneCore
import VoiceCloneInfrastructure
#if os(iOS)
import UIKit
#endif

@MainActor
struct CloudSyncSmokeTest {
    let mode: String
    let root: URL
    let namespace: String?

    static func configuration() -> Self? {
        guard let mode = CommandLine.arguments.first(where: { $0.hasPrefix("--sync-smoke-") }) else { return nil }
        let root = ProcessInfo.processInfo.environment["VOICECLONE_CLOUD_SMOKE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.documentsDirectory.appendingPathComponent("CloudSyncSmoke", isDirectory: true)
        return Self(mode: mode, root: root, namespace: ProcessInfo.processInfo.environment["VOICECLONE_CLOUD_SMOKE_NAMESPACE"])
    }

    func run() async {
        #if os(iOS)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        #endif
        var report: [String: String] = ["mode": mode]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if mode == "--sync-smoke-local" {
                try await verifyLocalSynchronization()
                report["conflicts"] = "both versions preserved"
                report["audioPolicy"] = "metadata before audio"
                report["retry"] = "verified"
                report["deletion"] = "verified"
            } else {
                guard let namespace, namespace.hasPrefix("validation-") else { throw Failure.step("validation namespace") }
                let container = CKContainer(identifier: CloudKitWorkspaceTransport.containerIdentifier)
                guard try await container.accountStatus() == .available else { throw WorkspaceSyncError.unavailable }
                let identity = try await container.userRecordID().recordName
                report["accountFingerprint"] = String(SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
                report["environment"] = CloudKitWorkspaceTransport.environment
                report["namespace"] = namespace
                let cloud = CloudKitWorkspaceTransport(firebaseUserID: namespace, cloudAccountID: identity)
                let store = LocalStudioWorkspace(root: root.appendingPathComponent("Library", isDirectory: true))
                if mode == "--sync-smoke-publish" {
                    _ = try makeFixture(store)
                    try await sync(store, cloud: cloud)
                    let remote = try await cloud.fetchWorkspace()
                    guard remote.document.workspace.projects.count == 1, remote.document.availableAudio.count == 2 else {
                        throw Failure.step("cloud publication")
                    }
                    report["publication"] = "verified"
                } else if mode == "--sync-smoke-consume" {
                    try await sync(store, cloud: cloud)
                    let workspace = try store.load()
                    report["projects"] = String(workspace.projects.count)
                    report["voices"] = String(workspace.voices.count)
                    guard workspace.projects.count == 1, workspace.voices.count == 1,
                          let generation = workspace.projects[0].sections.first?.generation,
                          workspace.assetIDs.allSatisfy(store.hasAudio) else { throw Failure.step("cross-device download") }
                    let export = root.appendingPathComponent("Export.wav")
                    try AudioFiles.concatenateWAV([store.audioURL(for: generation.id)], to: export)
                    guard try AudioFiles.duration(of: export) > 0 else { throw Failure.step("downloaded export") }
                    report["downloadAndExport"] = "verified"
                } else if mode == "--sync-smoke-cleanup" {
                    try await cloud.deleteWorkspace()
                    report["cloudCleanup"] = "verified"
                } else { throw Failure.step("unknown mode") }
            }
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"
            report["error"] = error.localizedDescription
            if let cloudError = error as? CKError { report["cloudError"] = String(describing: cloudError) }
        }
        do {
            try JSONEncoder().encode(report).write(to: root.appendingPathComponent("report.json"), options: .atomic)
        } catch { NSLog("Could not write cloud sync result: %@", error.localizedDescription) }
    }

    private func verifyLocalSynchronization() async throws {
        let a = LocalStudioWorkspace(root: root.appendingPathComponent("A"))
        let b = LocalStudioWorkspace(root: root.appendingPathComponent("B"))
        let cloud = MemoryCloud()
        let fixture = try makeFixture(a)
        try await sync(a, cloud: cloud, audio: false)
        try await sync(b, cloud: cloud, audio: false)
        guard try b.load().projects == fixture.projects,
              fixture.assetIDs.allSatisfy({ !b.hasAudio($0) }) else { throw Failure.step("metadata-only sync") }
        try await sync(a, cloud: cloud)
        try await sync(b, cloud: cloud)
        for id in fixture.assetIDs {
            guard try Data(contentsOf: a.audioURL(for: id)) == Data(contentsOf: b.audioURL(for: id)) else {
                throw Failure.step("audio transfer")
            }
        }
        var first = try a.load()
        var second = try b.load()
        first.projects[0].sections[0].text = "An edit on device A."
        second.projects[0].sections[0].text = "An edit on device B."
        try a.save(first)
        try b.save(second)
        try await sync(a, cloud: cloud)
        try await sync(b, cloud: cloud)
        try await sync(a, cloud: cloud)
        let merged = try a.load()
        guard merged.projects.count == 2, Set(merged.projects.map { $0.sections[0].text }) ==
                ["An edit on device A.", "An edit on device B."],
              try b.load() == merged else { throw Failure.step("concurrent project edits") }

        var localVoiceEdit = try a.load()
        var remoteVoiceEdit = try b.load()
        let sharedID = fixture.voices[0].id
        localVoiceEdit.voices = [try StudioVoice(id: sharedID, name: "Local profile", transcript: "Local transcript.")]
        remoteVoiceEdit.voices = [try StudioVoice(id: sharedID, name: "Remote profile", transcript: "Remote transcript.")]
        try a.save(localVoiceEdit)
        try b.save(remoteVoiceEdit)
        try await sync(b, cloud: cloud)
        try await sync(a, cloud: cloud)
        let voiceConflict = try a.load()
        guard let copied = voiceConflict.voices.first(where: { $0.id != sharedID }), a.hasAudio(copied.id),
              copied.transcript == "Local transcript." else { throw Failure.step("conflicting reference audio") }
        try await sync(b, cloud: cloud)

        // A failed upload must leave a durable pending item and all local data intact.
        let voice = try StudioVoice(name: "Retry reference", transcript: "A retry fixture.")
        try a.saveReference(a.audioURL(for: fixture.voices[0].id), id: voice.id)
        var retry = try a.load()
        retry.voices.append(voice)
        try a.save(retry)
        await cloud.failNextUpload()
        do { try await sync(a, cloud: cloud); throw Failure.step("injected upload failure") }
        catch let error as CKError where error.code == .quotaExceeded {}
        guard try a.loadSyncState().pendingUploads.contains(voice.id), a.hasAudio(voice.id) else {
            throw Failure.step("pending upload journal")
        }
        try await sync(LocalStudioWorkspace(root: root.appendingPathComponent("A")), cloud: cloud)
        guard try a.loadSyncState().pendingUploads.isEmpty else { throw Failure.step("upload resume") }

        let interruptedVoice = try StudioVoice(name: "Interrupted reference", transcript: "Interrupted upload.")
        try a.saveReference(a.audioURL(for: sharedID), id: interruptedVoice.id)
        var interrupted = try a.load()
        interrupted.voices.append(interruptedVoice)
        try a.save(interrupted)
        await cloud.interruptNextUpload()
        do { try await sync(a, cloud: cloud); throw Failure.step("injected interruption") }
        catch is CancellationError {}
        try await sync(a, cloud: cloud)
        guard try a.loadSyncState().pendingUploads.isEmpty else { throw Failure.step("interrupted upload recovery") }

        // Rebase after a server compare-and-swap conflict, preserving the latest local edit.
        var raced = try a.load()
        raced.projects[0].name = "Latest local title"
        try a.save(raced)
        await cloud.raceNextSave()
        try await sync(a, cloud: cloud)
        guard try a.load().projects.contains(where: { $0.name == "Concurrent cloud project" }),
              try a.load().projects.contains(where: { $0.name == "Latest local title" }) else {
            throw Failure.step("server revision retry")
        }
        try await sync(b, cloud: cloud)

        var independentBase = fixture
        independentBase.projects[0].sections.append(StudioSection(text: "A second section."))
        var independentLocal = independentBase
        var independentRemote = independentBase
        independentLocal.projects[0].sections[0].text = "Independent local edit."
        independentRemote.projects[0].sections[1].text = "Independent remote edit."
        let independent = try WorkspaceMerge.merge(base: independentBase, local: independentLocal,
                                                   remote: independentRemote).workspace
        guard independent.projects.count == 1,
              independent.projects[0].sections.map(\.text) == ["Independent local edit.", "Independent remote edit."] else {
            throw Failure.step("independent section merge")
        }

        // A remote deletion propagates to an unchanged device and removes its WAV files.
        try a.save(.empty)
        try await sync(a, cloud: cloud)
        try await sync(b, cloud: cloud)
        guard try b.load().projects.isEmpty, try b.load().voices.isEmpty,
              fixture.assetIDs.allSatisfy({ !b.hasAudio($0) }), await cloud.audioCount == 0 else {
            throw Failure.step("deletion propagation")
        }
        let cleanupRoot = root.appendingPathComponent("AccountCleanup", isDirectory: true)
        let accountStorage = AccountWorkspaces(root: cleanupRoot)
        let accountDirectory = accountStorage.directory(for: "deleted-validation-account")
        try LocalStudioWorkspace(root: accountDirectory).save(fixture)
        let cleanup = CloudDeletionQueue(root: cleanupRoot)
        try cleanup.enqueue(firebaseID: "deleted-validation-account", cloudAccounts: [])
        try await cleanup.process(excludingFirebaseID: "deleted-validation-account")
        guard FileManager.default.fileExists(atPath: accountDirectory.path) else { throw Failure.step("active account cleanup isolation") }
        try await cleanup.process(excludingFirebaseID: nil)
        guard !FileManager.default.fileExists(atPath: accountDirectory.path) else { throw Failure.step("deferred local cleanup") }

        var edited = fixture
        edited.projects[0].sections[0].text = "An offline edit concurrent with deletion."
        let recovered = try WorkspaceMerge.merge(base: fixture, local: edited, remote: .empty).workspace
        guard recovered.projects.count == 1, recovered.projects[0].id != fixture.projects[0].id else {
            throw Failure.step("concurrent deletion recovery")
        }
    }

    private func makeFixture(_ store: LocalStudioWorkspace) throws -> StudioWorkspace {
        let voice = try StudioVoice(name: "Synthetic sync reference", transcript: "A synthetic synchronization sample.")
        var workspace = StudioWorkspace()
        workspace.voices = [voice]
        workspace.projects[0].name = "Cloud synchronization validation"
        workspace.projects[0].voiceID = voice.id
        workspace.projects[0].sections[0].text = "A synthetic synchronization sample."
        let generation = StudioGeneration(id: UUID(), sourceText: workspace.projects[0].sections[0].text,
                                          voiceID: voice.id, language: .english, model: .int8, modelFingerprint: "validation")
        workspace.projects[0].sections[0].generation = generation
        let seed = root.appendingPathComponent(UUID().uuidString + ".wav")
        let samples = (0..<24_000).map { [Float(0), 0.125, 0, -0.125][$0 % 4] }
        try AudioFiles.writeWAV(try SpeechAudio(samples: samples, sampleRate: 24_000), to: seed)
        try store.saveReference(seed, id: voice.id)
        try FileManager.default.copyItem(at: store.audioURL(for: voice.id), to: store.audioURL(for: generation.id))
        try store.save(workspace)
        return workspace
    }

    private func sync(_ store: LocalStudioWorkspace, cloud: any WorkspaceCloudTransport, audio: Bool = true) async throws {
        _ = try await SynchronizeWorkspace(store: store, cloud: cloud)(
            transferAudio: { audio }, allowsCellular: { false }, canApply: { true }, didApply: {})
    }

    private enum Failure: LocalizedError {
        case step(String)
        var errorDescription: String? {
            switch self {
            case .step(let value): "Cloud sync validation failed at \(value)."
            }
        }
    }

    private actor MemoryCloud: WorkspaceCloudTransport {
        private var document = CloudWorkspace(workspace: .empty)
        private var revision = 0
        private var audio: [UUID: Data] = [:]
        private var uploadFailure = false
        private var saveRace = false
        private var uploadInterruption = false
        var audioCount: Int { audio.count }
        func failNextUpload() { uploadFailure = true }
        func raceNextSave() { saveRace = true }
        func interruptNextUpload() { uploadInterruption = true }
        func fetchWorkspace() -> RemoteWorkspace { RemoteWorkspace(document: document, revision: String(revision)) }
        func saveWorkspace(_ value: CloudWorkspace, revision expected: String?, deletingAudio: Set<UUID>) throws {
            if saveRace {
                saveRace = false
                document.workspace.projects.append(StudioProject(name: "Concurrent cloud project"))
                revision += 1
            }
            guard expected == String(revision) else { throw WorkspaceSyncError.conflict }
            document = value
            for id in deletingAudio { audio.removeValue(forKey: id) }
            revision += 1
        }
        func containsAudio(_ id: UUID) -> Bool { audio[id] != nil }
        func uploadAudio(_ id: UUID, from source: URL, allowsCellular: Bool) throws {
            if uploadFailure { uploadFailure = false; throw CKError(.quotaExceeded) }
            audio[id] = try Data(contentsOf: source)
            if uploadInterruption { uploadInterruption = false; throw CancellationError() }
        }
        func downloadAudio(_ id: UUID, to destination: URL, allowsCellular: Bool) throws {
            guard let data = audio[id] else { throw WorkspaceSyncError.invalidAudio }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        func deleteWorkspace() { document = CloudWorkspace(workspace: .empty); audio = [:]; revision += 1 }
    }
}
#endif
