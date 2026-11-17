import CryptoKit
import Foundation
import VoiceCloneCore

/// Keeps the existing guest workspace and each Firebase user's files separate.
public struct AccountWorkspaces {
    public let guest: URL
    private let accounts: URL
    private var transferJournal: URL { guest.appendingPathComponent("GuestTransfer.json") }
    private let artifacts = ["Workspace.json", "Audio", "RenderCheckpoints"]

    public init(root: URL) {
        guest = root
        accounts = root.appendingPathComponent("Accounts", isDirectory: true)
    }

    public func directory(for accountID: String?) -> URL {
        guard let accountID else { return guest }
        let name = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return accounts.appendingPathComponent(name, isDirectory: true)
    }

    public func canTransferGuest(to accountID: String) -> Bool {
        let destination = directory(for: accountID)
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.fileExists(atPath: guest.appendingPathComponent("Workspace.json").path),
              let workspace = try? LocalStudioWorkspace(root: guest).load() else { return false }
        return !workspace.voices.isEmpty || workspace.projects.contains { !$0.sections.isEmpty }
    }

    /// Copies first, atomically commits the destination, then removes guest data.
    /// The journal finishes guest cleanup if the process stops after the commit.
    public func transferGuest(to accountID: String) throws {
        guard canTransferGuest(to: accountID) else { return }
        let manager = FileManager.default
        let destination = directory(for: accountID)
        try manager.createDirectory(at: accounts, withIntermediateDirectories: true)
        let staging = accounts.appendingPathComponent(".transfer-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for name in artifacts {
            let source = guest.appendingPathComponent(name)
            if manager.fileExists(atPath: source.path) {
                try manager.copyItem(at: source, to: staging.appendingPathComponent(name))
            }
        }
        // Validate the copied manifest before making it the account workspace.
        _ = try LocalStudioWorkspace(root: staging).load()
        try JSONEncoder().encode(accountID).write(to: transferJournal, options: .atomic)
        try manager.moveItem(at: staging, to: destination)
        try finishPendingTransfer()
    }

    public func finishPendingTransfer() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: transferJournal.path) else { return }
        let id = try JSONDecoder().decode(String.self, from: Data(contentsOf: transferJournal))
        let destination = directory(for: id)
        if manager.fileExists(atPath: destination.appendingPathComponent("Workspace.json").path) {
            _ = try LocalStudioWorkspace(root: destination).load()
            for name in artifacts {
                let source = guest.appendingPathComponent(name)
                if manager.fileExists(atPath: source.path) { try manager.removeItem(at: source) }
            }
        }
        try manager.removeItem(at: transferJournal)
    }

    public func remove(accountID: String) throws {
        try finishPendingTransfer()
        let directory = directory(for: accountID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
