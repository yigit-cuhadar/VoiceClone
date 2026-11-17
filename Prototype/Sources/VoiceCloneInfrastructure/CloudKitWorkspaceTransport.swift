import CloudKit
import CryptoKit
import Foundation
import VoiceCloneCore

public actor CloudKitWorkspaceTransport: WorkspaceCloudTransport {
    public static var environment: String {
        Bundle.main.object(forInfoDictionaryKey: "VoiceCloneCloudKitEnvironment") as? String ?? "Development"
    }

    public static let containerIdentifier = "iCloud.com.yigitcuhadar.voiceclone"
    private let container = CKContainer(identifier: containerIdentifier)
    private let expectedAccount: String
    private let zoneID: CKRecordZone.ID
    private var workspaceRecord: CKRecord?

    public init(firebaseUserID: String, cloudAccountID: String) {
        expectedAccount = cloudAccountID
        let name = SHA256.hash(data: Data(firebaseUserID.utf8)).map { String(format: "%02x", $0) }.joined()
        zoneID = CKRecordZone.ID(zoneName: "account-" + name, ownerName: cloudAccountID)
    }

    public func fetchWorkspace() async throws -> RemoteWorkspace {
        try await verifyAccount()
        do { _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID)) }
        catch { throw Self.translate(error) }
        workspaceRecord = try await fetch(CKRecord.ID(recordName: "workspace", zoneID: zoneID), allowsCellular: true)
        guard let record = workspaceRecord else {
            return RemoteWorkspace(document: CloudWorkspace(workspace: .empty), revision: nil)
        }
        guard let asset = record["document"] as? CKAsset, let file = asset.fileURL else {
            throw WorkspaceSyncError.unsupportedFormat
        }
        let document = try JSONDecoder().decode(CloudWorkspace.self, from: Data(contentsOf: file))
        guard document.schemaVersion == 1 else { throw WorkspaceSyncError.unsupportedFormat }
        return RemoteWorkspace(document: document, revision: record.recordChangeTag)
    }

    public func saveWorkspace(_ document: CloudWorkspace, revision: String?, deletingAudio: Set<UUID>) async throws {
        try await verifyAccount()
        guard workspaceRecord?.recordChangeTag == revision else { throw WorkspaceSyncError.conflict }
        let record = workspaceRecord ?? CKRecord(recordType: "Workspace", recordID: CKRecord.ID(recordName: "workspace", zoneID: zoneID))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
        record["document"] = CKAsset(fileURL: file)
        workspaceRecord = try await save(record, deleting: deletingAudio.map(audioID), allowsCellular: true)
    }

    public func containsAudio(_ id: UUID) async throws -> Bool {
        try await verifyAccount()
        return try await fetch(audioID(id), keys: ["sha256"], allowsCellular: true) != nil
    }

    public func uploadAudio(_ id: UUID, from source: URL, allowsCellular: Bool) async throws {
        try await verifyAccount()
        let digest = try Self.checksum(source)
        if let existing = try await fetch(audioID(id), keys: ["sha256"], allowsCellular: true) {
            guard existing["sha256"] as? String == digest else { throw WorkspaceSyncError.invalidAudio }
            return
        }
        let record = CKRecord(recordType: "Audio", recordID: audioID(id))
        record["audio"] = CKAsset(fileURL: source)
        record["sha256"] = digest
        do { _ = try await save(record, allowsCellular: allowsCellular) }
        catch WorkspaceSyncError.conflict {
            let existing = try await fetch(audioID(id), keys: ["sha256"], allowsCellular: true)
            guard existing?["sha256"] as? String == digest else { throw WorkspaceSyncError.invalidAudio }
        }
    }

    public func downloadAudio(_ id: UUID, to destination: URL, allowsCellular: Bool) async throws {
        try await verifyAccount()
        guard let record = try await fetch(audioID(id), allowsCellular: allowsCellular),
              let asset = record["audio"] as? CKAsset, let source = asset.fileURL,
              let expected = record["sha256"] as? String,
              try Self.checksum(source) == expected, try AudioFiles.duration(of: source) > 0 else {
            throw WorkspaceSyncError.invalidAudio
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }

    public func deleteWorkspace() async throws {
        try await verifyAccount()
        do { _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zoneID) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {}
        workspaceRecord = nil
    }

    private func verifyAccount() async throws {
        try Task.checkCancellation()
        guard try await container.userRecordID().recordName == expectedAccount else {
            throw WorkspaceSyncError.accountChanged
        }
        try Task.checkCancellation()
    }

    private func audioID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "audio-" + id.uuidString, zoneID: zoneID)
    }

    private func fetch(_ id: CKRecord.ID, keys: [String]? = nil, allowsCellular: Bool) async throws -> CKRecord? {
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        operation.desiredKeys = keys
        operation.configuration.allowsCellularAccess = allowsCellular
        let result = CloudOperationValue<CKRecord?>()
        return try await perform(operation) { continuation in
            operation.perRecordResultBlock = { _, value in
                switch value {
                case .success(let record): result.set(.success(record))
                case .failure(let error as CKError) where error.code == .unknownItem: result.set(.success(nil))
                case .failure(let error): result.set(.failure(error))
                }
            }
            operation.fetchRecordsResultBlock = { outcome in
                // A missing single record is reported both per record and as a partial failure.
                if let value = result.value { continuation.resume(with: value) }
                else { continuation.resume(throwing: outcome.failure ?? WorkspaceSyncError.unavailable) }
            }
        }
    }

    private func save(_ record: CKRecord, deleting: [CKRecord.ID] = [], allowsCellular: Bool) async throws -> CKRecord {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: deleting)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        operation.configuration.allowsCellularAccess = allowsCellular
        let result = CloudOperationValue<CKRecord>()
        return try await perform(operation) { continuation in
            operation.perRecordSaveBlock = { _, value in result.set(value) }
            operation.modifyRecordsResultBlock = { outcome in
                switch outcome {
                case .success:
                    continuation.resume(with: result.value ?? .failure(WorkspaceSyncError.unavailable))
                case .failure(let error): continuation.resume(throwing: Self.translate(error))
                }
            }
        }
    }

    private func perform<T: Sendable>(_ operation: CKDatabaseOperation,
                                      configure: (CheckedContinuation<T, any Error>) -> Void) async throws -> T {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                configure(continuation)
                container.privateCloudDatabase.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    nonisolated private static func translate(_ error: any Error) -> any Error {
        guard let cloud = error as? CKError else { return error }
        if cloud.code == .serverRecordChanged { return WorkspaceSyncError.conflict }
        if cloud.partialErrorsByItemID?.values.contains(where: { ($0 as? CKError)?.code == .serverRecordChanged }) == true {
            return WorkspaceSyncError.conflict
        }
        return error
    }

    nonisolated private static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class CloudOperationValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, any Error>?
    var value: Result<T, any Error>? { lock.withLock { stored } }
    func set(_ value: Result<T, any Error>) { lock.withLock { stored = value } }
}

private extension Result where Success == Void, Failure == any Error {
    var failure: (any Error)? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
