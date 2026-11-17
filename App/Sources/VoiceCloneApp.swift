import SwiftUI
import VoiceCloneInfrastructure

@main
struct VoiceCloneApp: App {
    @State private var session: AppSession
    #if DEBUG || VOICECLONE_SMOKE_TEST
    private let smokeTest: StudioSmokeTest?
    private let accountSmokeTest: AccountSmokeTest?
    #endif

    init() {
        var useLocalEmulator = false
        var usesAccount = true
        var root = URL.applicationSupportDirectory.appending(path: "VoiceClone", directoryHint: .isDirectory)
        #if DEBUG || VOICECLONE_SMOKE_TEST
        smokeTest = StudioSmokeTest.configuration()
        accountSmokeTest = AccountSmokeTest.configuration()
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
        _session = State(initialValue: AppSession(root: root, service: service))
    }

    private var studioView: some View {
        ZStack {
            if let model = session.studio {
                StudioView(model: model, account: session.account)
                    .id(session.workspaceID ?? "guest")
                    #if DEBUG || VOICECLONE_SMOKE_TEST
                    .task { await smokeTest?.run(model) }
                    #endif
            } else if let error = session.error {
                ContentUnavailableView("Could not open workspace", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView("Opening workspace…")
            }
        }
        .task { await session.observe() }
        #if DEBUG || VOICECLONE_SMOKE_TEST
        .task {
            guard let accountSmokeTest else { return }
            while session.studio == nil {
                if Task.isCancelled || session.error != nil { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
            await accountSmokeTest.run(session)
        }
        #endif
        .alert("Move guest projects to your account?", isPresented: $session.offersGuestTransfer) {
            Button("Move projects") { Task { await session.transferGuest() } }
            Button("Keep in guest workspace", role: .cancel) {}
        } message: {
            Text("Move this device's guest projects, voices, and audio into your signed-in account. Signing out returns to a separate guest workspace.")
        }
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
