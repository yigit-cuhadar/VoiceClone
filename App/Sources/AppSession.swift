import CloudKit
import Foundation
import Observation
import VoiceCloneCore
import VoiceCloneInfrastructure

@MainActor
@Observable
final class AppSession {
    let account: AccountViewModel
    private let service: (any AccountAuthenticating)?
    private let workspaces: AccountWorkspaces
    private let models = StudioModelCache()
    private let connection = NetworkConnection()
    private let usesCloudKit: Bool
    private let deletions: CloudDeletionQueue
    private var cleanup: Task<Void, Never>?
    private var opening = UUID()
    private var activeDirectory: URL?
    private var cloudScope: CloudAccountScope?
    private var isActive = true
    private(set) var studio: StudioViewModel?
    private(set) var synchronization: CloudSyncViewModel?
    private(set) var workspaceID: String?
    private(set) var cloudAccountID: String?
    private(set) var libraryRevision = UUID()
    private(set) var cloudNotice: String?
    var offersGuestTransfer = false
    var offersCloudConsent = false
    var error: String?
    var accountDeletionMessage: String?

    init(root: URL, service: (any AccountAuthenticating)?, usesCloudKit: Bool = true) {
        self.service = service
        self.usesCloudKit = usesCloudKit
        workspaces = AccountWorkspaces(root: root)
        deletions = CloudDeletionQueue(root: root)
        let storage = workspaces
        account = AccountViewModel(service: service, removeLocalData: { try storage.remove(accountID: $0) })
        account.prepareForDeletion = { [weak self] id in
            guard let self, self.usesCloudKit else { return }
            await self.synchronization?.setEnabled(false)
            let accounts = try CloudAccountLibrary(accountRoot: self.workspaces.directory(for: id)).knownAccountIDs()
            try self.deletions.enqueue(firebaseID: id, cloudAccounts: accounts)
        }
        account.didDeleteAccount = { [weak self] localError in
            guard let self else { return }
            self.accountDeletionMessage = localError ?? "Your account and local library have been deleted. Any remaining cloud cleanup will finish when this app can access the original iCloud account."
            self.processCloudDeletions()
        }
        connection.didChange = { [weak self] in
            guard let self else { return }
            if self.connection.isConnected && self.synchronization == nil && self.account.account != nil && self.usesCloudKit {
                Task { await self.refreshCloudAccount() }
            } else { self.synchronization?.requestSync() }
        }
    }

    func observe() async {
        do { try workspaces.finishPendingTransfer() }
        catch {
            self.error = "Could not finish moving your guest workspace. \(error.localizedDescription)"
            return
        }
        guard let service else { await open(nil); return }
        for await user in service.accountChanges() {
            guard !Task.isCancelled else { return }
            account.update(user)
            processCloudDeletions()
            if studio == nil || workspaceID != user?.id { await open(user?.id) }
        }
    }

    func observeCloudAccount() async {
        guard usesCloudKit else { return }
        for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
            guard !Task.isCancelled else { return }
            await open(account.account?.id, allowOfflineCache: false)
        }
    }

    func refreshCloudAccount() async {
        guard let id = account.account?.id, usesCloudKit, studio != nil else {
            await open(account.account?.id)
            return
        }
        let request = UUID()
        opening = request
        let previous = synchronization
        synchronization = nil
        await previous?.stop()
        guard opening == request else { return }
        do {
            let scope = try await CloudAccountLibrary(accountRoot: workspaces.directory(for: id)).resolve()
            guard opening == request, account.account?.id == id else { return }
            if scope?.accountID == cloudAccountID, let directory = activeDirectory, let model = studio {
                cloudScope = scope
                cloudNotice = scope?.isVerified == false ? "Your offline iCloud library is open. Connect to confirm the current iCloud account and resume syncing." : nil
                try configureSynchronization(store: LocalStudioWorkspace(root: directory, synchronizationNamespace: CloudKitWorkspaceTransport.environment), model: model, scope: scope)
                promptForCloudConsent()
            } else { await open(id) }
        } catch { cloudNotice = error.localizedDescription }
    }

    func setActive(_ active: Bool) {
        isActive = active
        synchronization?.setActive(active)
        if active { processCloudDeletions() }
        else { cleanup?.cancel() }
    }

    func runSyncSchedule() async {
        while !Task.isCancelled {
            synchronization?.requestSync()
            processCloudDeletions()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
        }
    }

    private func processCloudDeletions() {
        guard usesCloudKit, isActive, cleanup == nil else { return }
        cleanup = Task {
            defer { cleanup = nil }
            do { try await deletions.process(excludingFirebaseID: account.account?.id) }
            catch is CancellationError {}
            catch { /* The durable queue retries when the app is active again. */ }
        }
    }

    func keepGuestWorkspace() {
        offersGuestTransfer = false
        promptForCloudConsent()
    }

    func transferGuest() async {
        guard let directory = activeDirectory, workspaceID != nil else { return }
        let request = opening
        offersGuestTransfer = false
        let previous = synchronization
        synchronization = nil
        await previous?.stop()
        await studio?.cancelAndWait()
        guard opening == request else { return }
        do {
            try workspaces.transferGuest(toDirectory: directory)
            try assemble(directory: directory, scope: cloudScope)
            promptForCloudConsent()
        } catch { self.error = error.localizedDescription }
    }

    func requestCloudConsent() { offersCloudConsent = synchronization != nil }

    func decideCloudConsent(_ enabled: Bool) async {
        offersCloudConsent = false
        await synchronization?.setEnabled(enabled)
    }

    private func promptForCloudConsent() {
        guard !offersGuestTransfer, let synchronization, !synchronization.preferences.hasAskedConsent else { return }
        // Present after SwiftUI has dismissed the guest-transfer alert.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.offersCloudConsent = true
        }
    }

    private func open(_ id: String?, allowOfflineCache: Bool = true) async {
        let request = UUID()
        opening = request
        offersGuestTransfer = false
        offersCloudConsent = false
        error = nil
        cloudNotice = nil
        let previous = studio
        studio = nil
        let previousSync = synchronization
        synchronization = nil
        await previousSync?.stop()
        await previous?.cancelAndWait()
        guard opening == request else { return }
        workspaceID = id
        cloudScope = nil
        cloudAccountID = nil
        let accountRoot = workspaces.directory(for: id)
        do {
            var scope: CloudAccountScope?
            if id != nil && usesCloudKit {
                scope = try await CloudAccountLibrary(accountRoot: accountRoot).resolve(allowOfflineCache: allowOfflineCache)
                guard opening == request else { return }
                if scope == nil { cloudNotice = "Sign in to iCloud in system settings to sync your library." }
                else if scope?.isVerified == false { cloudNotice = "Your offline iCloud library is open. Connect to confirm the current iCloud account and resume syncing." }
            }
            cloudScope = scope
            cloudAccountID = scope?.accountID
            let directory = scope?.directory ?? accountRoot
            try assemble(directory: directory, scope: scope)
            if id != nil { offersGuestTransfer = workspaces.canTransferGuest(toDirectory: directory) }
            promptForCloudConsent()
        } catch {
            guard opening == request else { return }
            self.error = error.localizedDescription
        }
    }

    private func assemble(directory: URL, scope: CloudAccountScope?) throws {
        activeDirectory = directory
        let store = LocalStudioWorkspace(root: directory, synchronizationNamespace: CloudKitWorkspaceTransport.environment)
        let model = StudioViewModel(store: store, renderer: LocalStudioRenderer(models: models), models: models)
        studio = model
        libraryRevision = UUID()
        try configureSynchronization(store: store, model: model, scope: scope)
    }

    private func configureSynchronization(store: LocalStudioWorkspace, model: StudioViewModel, scope: CloudAccountScope?) throws {
        guard let scope, scope.isVerified, let workspaceID else { return }
        synchronization = try CloudSyncViewModel(
                store: store, cloud: CloudKitWorkspaceTransport(firebaseUserID: workspaceID, cloudAccountID: scope.accountID),
                preferencesFile: scope.preferencesFile, connection: connection,
                canApply: { [weak model] in model?.isBusy == false },
                didApply: { [weak model] in model?.reloadWorkspace() },
                accountChanged: { [weak self] in Task { await self?.refreshCloudAccount() } })
        synchronization?.setActive(isActive)
    }
}
