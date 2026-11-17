import SwiftUI
import VoiceCloneInfrastructure

@main
struct VoiceCloneApp: App {
    @State private var model: StudioViewModel
    #if DEBUG || VOICECLONE_SMOKE_TEST
    private let smokeTest: StudioSmokeTest?
    #endif

    init() {
        var root = URL.applicationSupportDirectory.appending(path: "VoiceClone", directoryHint: .isDirectory)
        #if DEBUG || VOICECLONE_SMOKE_TEST
        smokeTest = StudioSmokeTest.configuration()
        if let smokeTest { root = smokeTest.workspace }
        #endif
        let models = StudioModelCache()
        _model = State(initialValue: StudioViewModel(
            store: LocalStudioWorkspace(root: root),
            renderer: OmniVoiceStudioRenderer(models: models),
            models: models
        ))
    }

    private var studioView: some View {
        StudioView(model: model)
            #if DEBUG || VOICECLONE_SMOKE_TEST
            .task { await smokeTest?.run(model) }
            #endif
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
