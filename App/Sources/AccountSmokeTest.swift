#if DEBUG || VOICECLONE_SMOKE_TEST
import Foundation
import VoiceCloneCore
import VoiceCloneInfrastructure

/// Exercises the real Firebase SDK against the local Authentication emulator.
@MainActor
struct AccountSmokeTest {
    let root: URL
    let report: URL
    let persistenceOnly: Bool

    static func configuration() -> Self? {
        let arguments = CommandLine.arguments
        guard arguments.contains("--account-smoke") || arguments.contains("--account-persistence-smoke"),
              let directory = ProcessInfo.processInfo.environment["VOICECLONE_ACCOUNT_SMOKE_DIRECTORY"] else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        return Self(root: root.appendingPathComponent("Workspace", isDirectory: true),
                    report: root.appendingPathComponent("report.json"),
                    persistenceOnly: arguments.contains("--account-persistence-smoke"))
    }

    func run(_ session: AppSession) async {
        var result: [String: String] = [:]
        do {
            if persistenceOnly {
                guard session.workspaceID != nil, session.account.account != nil,
                      session.studio?.project?.name == "Account project" else { throw Failure.incomplete("restored session") }
                // Deletion includes reauthentication through the same view model used by the UI.
                session.account.password = "Local-emulator-password-42!"
                await session.account.deleteWithPassword()
                try await requireSuccess(session)
                try await wait { session.workspaceID == nil }
                result["persistence"] = "verified"
                result["deletion"] = "verified"
            } else {
                let account = session.account
                guard account.isConfigured, session.workspaceID == nil else { throw Failure.incomplete("initial guest session") }
                let guest = try studio(session)
                guest.renameProject("Guest project")
                guest.appendScript("A guest project must survive sign-in until its owner chooses to move it.")
                let reference = report.deletingLastPathComponent().appendingPathComponent("reference.wav")
                try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AudioFiles.writeWAV(try SpeechAudio(samples: [Float](repeating: 0.05, count: 48_000), sampleRate: 24_000), to: reference)
                try guest.addVoice(name: "Emulator reference", transcript: "An isolated test reference.", source: reference)
                let voiceID = try require(guest.workspace.voices.first?.id)
                let referenceData = try Data(contentsOf: guest.audioURL(for: voiceID))
                let guestID = guest.project?.id
                let nonce = UUID().uuidString.lowercased()
                let email = "voiceclone-\(nonce)@example.invalid"
                account.email = email
                account.password = "Local-emulator-password-42!"
                await account.signIn(create: true)
                try await requireSuccess(session)
                try await wait { session.workspaceID != nil && session.offersGuestTransfer }
                let firstID = try require(session.workspaceID)
                guard session.studio?.project?.id != guestID else { throw Failure.incomplete("guest isolation") }
                await session.transferGuest()
                guard session.error == nil, session.studio?.project?.id == guestID else { throw Failure.incomplete("guest transfer") }
                let storage = AccountWorkspaces(root: root)
                guard !storage.canTransferGuest(to: firstID),
                      try LocalStudioWorkspace(root: storage.guest).load().projects.first?.id != guestID else {
                    throw Failure.incomplete("transfer cleanup")
                }
                let moved = try studio(session)
                guard try Data(contentsOf: moved.audioURL(for: voiceID)) == referenceData else {
                    throw Failure.incomplete("reference audio transfer")
                }
                moved.renameProject("Account project")
                await account.signOut()
                try await requireSuccess(session)
                try await wait { session.workspaceID == nil }
                guard session.studio?.project?.id != guestID else { throw Failure.incomplete("signed-out isolation") }

                account.email = "voiceclone-second-\(nonce)@example.invalid"
                account.password = "Local-emulator-password-42!"
                await account.signIn(create: true)
                try await requireSuccess(session)
                try await wait { session.workspaceID != nil }
                guard session.workspaceID != firstID, session.studio?.project?.id != guestID else {
                    throw Failure.incomplete("second account isolation")
                }
                account.password = "Local-emulator-password-42!"
                await account.deleteWithPassword()
                try await requireSuccess(session)
                try await wait { session.workspaceID == nil }

                account.email = email
                account.password = "Incorrect-password-42!"
                await account.signIn(create: false)
                guard account.error != nil, session.workspaceID == nil else { throw Failure.incomplete("invalid password rejection") }
                account.password = "Local-emulator-password-42!"
                await account.signIn(create: false)
                try await requireSuccess(session)
                try await wait { session.workspaceID == firstID }
                guard session.studio?.project?.name == "Account project" else { throw Failure.incomplete("account project restoration") }
                await account.verifyEmail()
                try await requireSuccess(session)
                account.email = email
                await account.resetPassword()
                try await requireSuccess(session)
                try verifyInterruptedTransfer()
                result["accounts"] = "verified"
                result["guestTransfer"] = "verified"
                result["isolation"] = "verified"
                result["verificationAndReset"] = "emulator accepted"
                // Leave the first account signed in for a second-process persistence check.
            }
            result["status"] = "passed"
        } catch {
            result["status"] = "failed"
            result["error"] = error.localizedDescription
        }
        do {
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: report, options: .atomic)
        } catch { NSLog("Could not write account smoke test result: %@", error.localizedDescription) }
    }

    private func verifyInterruptedTransfer() throws {
        let root = report.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        let storage = AccountWorkspaces(root: root)
        let guest = LocalStudioWorkspace(root: root)
        let workspace = StudioWorkspace()
        try guest.save(workspace)
        let manifest = root.appendingPathComponent("Workspace.json")
        let journal = root.appendingPathComponent("GuestTransfer.json")
        // A stop before destination commit must preserve the guest manifest.
        try JSONEncoder().encode("interrupted-account").write(to: journal, options: .atomic)
        try storage.finishPendingTransfer()
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw Failure.incomplete("transfer rollback") }
        // A stop after destination commit must finish removing the guest copy.
        let destination = storage.directory(for: "interrupted-account")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifest, to: destination.appendingPathComponent("Workspace.json"))
        try JSONEncoder().encode("interrupted-account").write(to: journal, options: .atomic)
        try storage.finishPendingTransfer()
        guard !FileManager.default.fileExists(atPath: manifest.path),
              try LocalStudioWorkspace(root: destination).load().projects == workspace.projects else { throw Failure.incomplete("transfer recovery") }
    }

    private func requireSuccess(_ session: AppSession) async throws {
        if let error = session.account.error ?? session.error { throw Failure.incomplete(error) }
    }

    private func studio(_ session: AppSession) throws -> StudioViewModel { try require(session.studio) }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure.incomplete("missing value") }
        return value
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.incomplete("session transition timeout") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private enum Failure: LocalizedError {
        case incomplete(String)
        var errorDescription: String? {
            switch self { case .incomplete(let step): "Account smoke test failed at \(step)." }
        }
    }
}
#endif
