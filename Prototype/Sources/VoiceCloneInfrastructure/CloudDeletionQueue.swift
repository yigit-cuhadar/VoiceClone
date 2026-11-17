import CloudKit
import Foundation

/// Retains account cleanup requests until local files and the original iCloud account are accessible.
public struct CloudDeletionQueue {
    private let file: URL
    private let workspaces: AccountWorkspaces

    public init(root: URL) {
        file = root.appendingPathComponent("PendingCloudDeletions.json")
        workspaces = AccountWorkspaces(root: root)
    }

    public func enqueue(firebaseID: String, cloudAccounts: Set<String>) throws {
        var jobs = try load()
        jobs.insert(Job(firebaseID: firebaseID, cloudID: nil, environment: CloudKitWorkspaceTransport.environment))
        jobs.formUnion(cloudAccounts.map { Job(firebaseID: firebaseID, cloudID: $0, environment: CloudKitWorkspaceTransport.environment) })
        try save(jobs)
    }

    @MainActor
    public func process(excludingFirebaseID: String?) async throws {
        let jobs = try load().filter { $0.firebaseID != excludingFirebaseID && $0.environment == CloudKitWorkspaceTransport.environment }
        guard !jobs.isEmpty else { return }
        for job in jobs where job.cloudID == nil {
            try workspaces.remove(accountID: job.firebaseID)
            var remaining = try load()
            remaining.remove(job)
            try save(remaining)
        }
        guard jobs.contains(where: { $0.cloudID != nil }) else { return }
        let container = CKContainer(identifier: CloudKitWorkspaceTransport.containerIdentifier)
        guard try await container.accountStatus() == .available else { return }
        let currentID = try await container.userRecordID().recordName
        for job in jobs where job.cloudID == currentID {
            try Task.checkCancellation()
            let cloud = CloudKitWorkspaceTransport(firebaseUserID: job.firebaseID, cloudAccountID: currentID)
            try await cloud.deleteWorkspace()
            var remaining = try load()
            remaining.remove(job)
            try save(remaining)
        }
    }

    private func load() throws -> Set<Job> {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode(Set<Job>.self, from: Data(contentsOf: file))
    }

    private func save(_ jobs: Set<Job>) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: file, options: .atomic)
    }

    private struct Job: Codable, Hashable {
        let firebaseID: String
        let cloudID: String?
        let environment: String?
    }
}
