import CloudKit
import Foundation
import VoiceCloneCore

public struct CloudSyncPreferences: Codable, Sendable {
    public var hasAskedConsent = false
    public var isEnabled = false
    public var allowsCellularAudio = false
    public init() {}
}

public struct CloudAccountScope: Sendable {
    public let accountID: String
    public let directory: URL
    public let preferencesFile: URL
    public let isVerified: Bool
}

/// Identity tokens allow offline reopening without selecting a different iCloud user's cache.
public struct CloudAccountLibrary {
    private let accountRoot: URL
    private let indexFile: URL

    public init(accountRoot: URL) {
        self.accountRoot = accountRoot
        indexFile = accountRoot.appendingPathComponent("CloudAccounts.json")
    }

    public func resolve(allowOfflineCache: Bool = true) async throws -> CloudAccountScope? {
        var index = try loadIndex()
        let token = FileManager.default.ubiquityIdentityToken
        if let token, let known = index.accounts.first(where: { known in
            guard known.environment == CloudKitWorkspaceTransport.environment, let saved = known.identityToken,
                  let decoded = try? Self.decodeIdentity(saved) else { return false }
            return token.isEqual(decoded)
        }) { return try prepare(known.id, index: &index) }

        do {
            let container = CKContainer(identifier: CloudKitWorkspaceTransport.containerIdentifier)
            let status = try await container.accountStatus()
            guard status == .available else {
                if status == .noAccount || status == .restricted { return nil }
                throw WorkspaceSyncError.unavailable
            }
            let id = try await container.userRecordID().recordName
            let data = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
            index.accounts.removeAll { $0.id == id && $0.environment == CloudKitWorkspaceTransport.environment }
            index.accounts.append(KnownAccount(id: id, identityToken: data, environment: CloudKitWorkspaceTransport.environment))
            return try prepare(id, index: &index)
        } catch {
            let temporary: Set<CKError.Code> = [.networkFailure, .networkUnavailable, .serviceUnavailable,
                                               .accountTemporarilyUnavailable, .requestRateLimited]
            let isTemporary: Bool
            if case WorkspaceSyncError.unavailable = error { isTemporary = true }
            else { isTemporary = (error as? CKError).map { temporary.contains($0.code) } ?? false }
            guard allowOfflineCache, token == nil, isTemporary,
                  index.lastEnvironment == CloudKitWorkspaceTransport.environment,
                  let previous = index.lastAccountID else { throw error }
            return scope(previous, verified: false)
        }
    }

    public func knownAccountIDs() throws -> Set<String> { Set(try loadIndex().accounts.filter { $0.environment == CloudKitWorkspaceTransport.environment }.map(\.id)) }

    public static func preferences(at file: URL) throws -> CloudSyncPreferences {
        guard FileManager.default.fileExists(atPath: file.path) else { return CloudSyncPreferences() }
        return try JSONDecoder().decode(CloudSyncPreferences.self, from: Data(contentsOf: file))
    }

    public static func savePreferences(_ preferences: CloudSyncPreferences, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
    }

    private func prepare(_ id: String, index: inout Index) throws -> CloudAccountScope {
        let storage = AccountWorkspaces(root: accountRoot)
        try storage.finishPendingTransfer()
        if !index.adoptedInitialWorkspace {
            try storage.transferGuest(to: id)
            index.adoptedInitialWorkspace = true
        }
        index.lastAccountID = id
        index.lastEnvironment = CloudKitWorkspaceTransport.environment
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: indexFile, options: .atomic)
        return scope(id, verified: true)
    }

    private func scope(_ id: String, verified: Bool) -> CloudAccountScope {
        let directory = AccountWorkspaces(root: accountRoot).directory(for: id)
        // Preferences live beside the workspace so an empty destination can still receive guest data.
        let preferences = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".preferences.json")
        return CloudAccountScope(accountID: id, directory: directory, preferencesFile: preferences, isVerified: verified)
    }

    private static func decodeIdentity(_ data: Data) throws -> Any? {
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = false
        decoder.decodingFailurePolicy = .setErrorAndReturn
        defer { decoder.finishDecoding() }
        return decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }

    private func loadIndex() throws -> Index {
        guard FileManager.default.fileExists(atPath: indexFile.path) else { return Index() }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexFile))
    }

    private struct Index: Codable {
        var adoptedInitialWorkspace = false
        var lastAccountID: String?
        var lastEnvironment: String?
        var accounts: [KnownAccount] = []
    }

    private struct KnownAccount: Codable {
        let id: String
        let identityToken: Data?
        let environment: String?
    }
}
