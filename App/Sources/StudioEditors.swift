import SwiftUI
import UniformTypeIdentifiers

struct ScriptEditor: View {
    let title: String
    var multiline = true
    var help: String?
    let save: (String) -> Void
    let close: () -> Void
    @State var value: String

    init(title: String, value: String, multiline: Bool = true, help: String? = nil,
         save: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.multiline = multiline
        self.help = help
        self.save = save
        self.close = close
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let help { Text(help).font(.callout).foregroundStyle(.secondary) }
                if multiline {
                    TextEditor(text: $value)
                        .padding(6)
                        .frame(minHeight: 180)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Script text")
                } else {
                    TextField("Project name", text: $value).textFieldStyle(.roundedBorder)
                    Spacer()
                }
            }
            .padding(18)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(value) }.disabled(value.isBlank)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: multiline ? 340 : 150)
        #endif
    }
}

struct VoiceEditor: View {
    let audio: StudioAudioControls
    let save: (String, String, URL) throws -> Void
    let close: () -> Void
    @State private var name = ""
    @State private var transcript = ""
    @State private var reference: URL?
    @State private var temporaryReference: URL?
    @State private var recordingTimer: Task<Void, Never>?
    @State private var preparing = false
    @State private var recording = false
    @State private var importing = false
    @State private var consent = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Recording") {
                    HStack {
                        Button(recording ? "Stop recording" : "Record", systemImage: recording ? "stop.circle" : "mic") {
                            if recording { stopRecording() }
                            else { startRecording() }
                        }
                        .disabled(preparing)
                        Button("Import audio", systemImage: "folder") { importing = true }
                            .disabled(recording || preparing)
                    }
                    if recording {
                        Text("Recording…").foregroundStyle(.red)
                    } else if let reference {
                        HStack {
                            Text(reference == temporaryReference ? "Microphone recording" : reference.lastPathComponent)
                            Spacer()
                            Button("Play", systemImage: "play.circle") {
                                do { try audio.play(reference) }
                                catch { message = error.localizedDescription }
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    Text("Use a clear recording between 1 and 10 seconds. Read a short sentence, then enter the words below.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Voice profile") {
                    TextField("Voice name", text: $name)
                    TextField("Reference transcript", text: $transcript, axis: .vertical)
                    Toggle("I have permission to use this voice", isOn: $consent)
                }
                if let message { Text(message).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add voice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let reference else { return }
                        do { try save(name, transcript, reference); close() }
                        catch { message = error.localizedDescription }
                    }
                    .disabled(recording || preparing || name.isBlank || transcript.isBlank || reference == nil || !consent)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            do {
                let url = try result.get()
                removeTemporaryReference()
                reference = url
                message = nil
            } catch { message = error.localizedDescription }
        }
        .onDisappear {
            stopRecording()
            removeTemporaryReference()
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 440)
        #endif
    }

    private func startRecording() {
        message = nil
        preparing = true
        recordingTimer = Task {
            defer { preparing = false }
            do {
                let url = try await audio.startRecording()
                removeTemporaryReference()
                temporaryReference = url
                reference = url
                preparing = false
                recording = true
                try await Task.sleep(for: .seconds(10))
                audio.stopRecording()
                recording = false
            } catch is CancellationError {} catch {
                message = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        recordingTimer?.cancel()
        recordingTimer = nil
        audio.stopRecording()
        recording = false
    }

    private func removeTemporaryReference() {
        if let temporaryReference { try? FileManager.default.removeItem(at: temporaryReference) }
        temporaryReference = nil
    }
}
