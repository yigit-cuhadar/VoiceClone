import SwiftUI
import VoiceCloneInfrastructure

@main
struct VoiceCloneApp: App {
    @State private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG || VOICECLONE_SMOKE_TEST
    private let smokeTest: StudioSmokeTest?
    private let accountSmokeTest: AccountSmokeTest?
    private let cloudSmokeTest: CloudSyncSmokeTest?
    #endif

    init() {
        var useLocalEmulator = false
        var usesAccount = true
        var root = URL.applicationSupportDirectory.appending(path: "VoiceClone", directoryHint: .isDirectory)
        #if DEBUG || VOICECLONE_SMOKE_TEST
        smokeTest = StudioSmokeTest.configuration()
        accountSmokeTest = AccountSmokeTest.configuration()
        cloudSmokeTest = CloudSyncSmokeTest.configuration()
        if let cloudSmokeTest {
            root = cloudSmokeTest.root.appendingPathComponent("Presentation", isDirectory: true)
            usesAccount = false
        }
        if let accountSmokeTest {
            root = accountSmokeTest.root
            useLocalEmulator = true
        }
        if let smokeTest {
            root = smokeTest.workspace
            usesAccount = false
        }
        #endif
        let service = usesAccount ? FirebaseAccountService(configuration: Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
                                             useLocalEmulator: useLocalEmulator) : nil
        _session = State(initialValue: AppSession(root: root, service: service, usesCloudKit: usesAccount && !useLocalEmulator))
    }

    private var studioContent: some View {
        ZStack {
            if let model = session.studio {
                StudioView(model: model, account: session.account, synchronization: session.synchronization,
                           cloudNotice: session.cloudNotice, requestCloudConsent: session.requestCloudConsent)
                    .id(session.libraryRevision)
                    #if DEBUG || VOICECLONE_SMOKE_TEST
                    .task { await smokeTest?.run(model) }
                    #endif
            } else if let error = session.error {
                ContentUnavailableView {
                    Label("Could not open workspace", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Retry") { Task { await session.refreshCloudAccount() } }
                    Button("Sign out") { Task { await session.account.signOut() } }
                }
            } else {
                ProgressView("Opening workspace…")
            }
        }
        .task { await session.observe() }
        .task { await session.observeCloudAccount() }
        .task { await session.runSyncSchedule() }
        .onChange(of: scenePhase) { _, phase in session.setActive(phase == .active) }
        .onChange(of: session.studio?.workspaceRevision) { session.synchronization?.requestSync() }
        .onChange(of: session.studio?.isBusy) { _, busy in
            if busy == false { session.synchronization?.requestSync() }
        }
        #if DEBUG || VOICECLONE_SMOKE_TEST
        .task { await cloudSmokeTest?.run() }
        .task {
            guard let accountSmokeTest else { return }
            while session.studio == nil {
                if Task.isCancelled || session.error != nil { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
            await accountSmokeTest.run(session)
        }
        #endif
    }

    private var libraryView: some View {
        studioContent
        .alert("Move guest projects to your account?", isPresented: $session.offersGuestTransfer) {
            Button("Move projects") { Task { await session.transferGuest() } }
            Button("Keep in guest workspace", role: .cancel, action: session.keepGuestWorkspace)
        } message: {
            Text("Move this device's guest projects, voices, and audio into your signed-in account. Signing out returns to a separate guest workspace.")
        }
        .alert("Sync your library with iCloud?", isPresented: $session.offersCloudConsent) {
            Button("Enable sync") { Task { await session.decideCloudConsent(true) } }
            Button("Not now", role: .cancel) { Task { await session.decideCloudConsent(false) } }
        } message: {
            Text("Your reference recordings, scripts, voice profiles, settings, and generated audio will be stored in your private iCloud storage. Use the same VoiceClone and iCloud accounts on your devices. Audio transfers use Wi-Fi or Ethernet by default.")
        }
    }

    private var studioView: some View {
        libraryView
        .alert("Account deleted", isPresented: Binding(
            get: { session.accountDeletionMessage != nil },
            set: { if !$0 { session.accountDeletionMessage = nil } })) {
            Button("OK", role: .cancel) { session.accountDeletionMessage = nil }
        } message: { Text(session.accountDeletionMessage ?? "") }
        .alert("Workspace", isPresented: Binding(get: { session.error != nil && session.studio != nil },
                                                 set: { if !$0 { session.error = nil } })) {
            Button("OK", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    var body: some Scene {
        #if os(macOS)
        Window("VoiceClone", id: "studio") {
            studioView
                .frame(minWidth: 560, minHeight: 620)
        }
        .defaultSize(width: 840, height: 760)
        #else
        WindowGroup {
            studioView
        }
        #endif
    }
}
