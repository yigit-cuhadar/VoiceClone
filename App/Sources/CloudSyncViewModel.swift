import CloudKit
import Foundation
import Network
import Observation
import VoiceCloneCore
import VoiceCloneInfrastructure

@MainActor
@Observable
final class CloudSyncViewModel {
    private let synchronize: SynchronizeWorkspace
    private let preferencesFile: URL
    private let connection: NetworkConnection
    private let canApply: () -> Bool
    private let didApply: () -> Void
    private let accountChanged: () -> Void
    private var operation: Task<Void, Never>?
    private var requestedAgain = false
    private var isActive = true
    private var retryAfter: Date?
    private(set) var preferences: CloudSyncPreferences
    private(set) var isSyncing = false
    private(set) var pendingAudio = 0
    private(set) var lastSynced: Date?
    private(set) var status = "Sync is off."
    private(set) var error: String?

    init(store: any SynchronizingWorkspaceStore, cloud: any WorkspaceCloudTransport,
         preferencesFile: URL, connection: NetworkConnection,
         canApply: @escaping () -> Bool, didApply: @escaping () -> Void, accountChanged: @escaping () -> Void) throws {
        synchronize = SynchronizeWorkspace(store: store, cloud: cloud)
        self.preferencesFile = preferencesFile
        self.connection = connection
        self.canApply = canApply
        self.didApply = didApply
        self.accountChanged = accountChanged
        preferences = try CloudAccountLibrary.preferences(at: preferencesFile)
        if preferences.isEnabled { status = "Waiting to sync…" }
    }

    func setEnabled(_ enabled: Bool) async {
        var next = preferences
        next.hasAskedConsent = true
        next.isEnabled = enabled
        guard persist(next) else { return }
        retryAfter = nil
        if enabled { requestSync() }
        else {
            await cancelTransfers()
            status = "Sync is off."
        }
    }

    func setCellularAudio(_ allowed: Bool) async {
        var next = preferences
        next.allowsCellularAudio = allowed
        guard persist(next) else { return }
        await cancelTransfers()
        requestSync()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { requestSync() }
        else { operation?.cancel() }
    }

    func requestSync() {
        guard preferences.isEnabled, isActive else { return }
        if operation != nil {
            requestedAgain = true
            return
        }
        guard connection.isConnected else { status = "Waiting for a connection."; return }
        guard retryAfter.map({ $0 <= Date() }) ?? true else { return }
        operation = Task {
            isSyncing = true
            error = nil
            status = "Syncing…"
            do {
                pendingAudio = try await synchronize(
                    transferAudio: { self.connection.isConnected && (self.preferences.allowsCellularAudio || self.connection.isWiFiOrEthernet) },
                    allowsCellular: { self.preferences.allowsCellularAudio },
                    canApply: { self.isActive && self.preferences.isEnabled && self.canApply() },
                    didApply: didApply)
                lastSynced = Date()
                retryAfter = nil
                status = pendingAudio > 0 ? "\(pendingAudio) audio files waiting to sync." : "Up to date."
                if pendingAudio > 0 && !preferences.allowsCellularAudio && !connection.isWiFiOrEthernet {
                    status = "\(pendingAudio) audio files waiting for Wi-Fi."
                }
            } catch is CancellationError {
                status = preferences.isEnabled ? "Sync paused." : "Sync is off."
            } catch WorkspaceSyncError.workspaceBusy {
                status = "Sync will continue after the current operation."
            } catch WorkspaceSyncError.accountChanged {
                status = "Your iCloud account changed."
                accountChanged()
            } catch {
                if let cloud = error as? CKError, cloud.code == .quotaExceeded {
                    self.error = "Your iCloud storage is full. Free some space to continue syncing."
                } else { self.error = error.localizedDescription }
                retryAfter = Date().addingTimeInterval(max(5, (error as? CKError)?.retryAfterSeconds ?? 60))
                status = "Changes are saved on this device. Sync will retry."
            }
            isSyncing = false
            operation = nil
            if requestedAgain {
                requestedAgain = false
                requestSync()
            }
        }
    }

    func stop() async {
        isActive = false
        await cancelTransfers()
    }

    private func cancelTransfers() async {
        requestedAgain = false
        operation?.cancel()
        await operation?.value
    }

    private func persist(_ next: CloudSyncPreferences) -> Bool {
        do {
            try CloudAccountLibrary.savePreferences(next, at: preferencesFile)
            preferences = next
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

@MainActor
@Observable
final class NetworkConnection {
    private let monitor = NWPathMonitor()
    private(set) var isConnected = false
    private(set) var isWiFiOrEthernet = false
    var didChange: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                self?.isConnected = connected
                self?.isWiFiOrEthernet = wifi
                self?.didChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "VoiceClone.Network"))
    }

    deinit { monitor.cancel() }
}
