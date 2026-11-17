import SwiftUI
import UniformTypeIdentifiers
import VoiceCloneCore
import VoiceCloneInfrastructure

@main
struct VoiceCloneProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

private struct ProbeView: View {
    @State private var variant = OmniVoiceSynthesizer.Variant.int8
    @State private var language = SpeechLanguage.english
    @State private var reference: URL?
    @State private var referenceName = ""
    @State private var transcript = ""
    @State private var text = ""
    @State private var offline = false
    @State private var importing = false
    @State private var generating = false
    @State private var report: ProbeReport?
    @State private var output: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Variant", selection: $variant) {
                        Text("OmniVoice INT8").tag(OmniVoiceSynthesizer.Variant.int8)
                        Text("OmniVoice FP16").tag(OmniVoiceSynthesizer.Variant.fp16)
                    }
                    Picker("Output language", selection: $language) {
                        Text("English").tag(SpeechLanguage.english)
                        Text("Turkish").tag(SpeechLanguage.turkish)
                    }
                    Toggle("Use cached model only", isOn: $offline)
                }
                .disabled(generating)

                Section("Speech") {
                    Button(referenceName.isEmpty ? "Choose reference audio" : referenceName) {
                        importing = true
                    }
                    TextField("Reference transcript", text: $transcript, axis: .vertical)
                    TextField("Text to synthesize", text: $text, axis: .vertical)
                }
                .disabled(generating)

                Button("Generate WAV", action: beginGeneration)
                    .disabled(generating || reference == nil || transcript.isBlank || text.isBlank)

                if generating {
                    ProgressView("Loading model or generating speech")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if let report, let output {
                    Section("Result") {
                        LabeledContent("Model load", value: seconds(report.loadSeconds))
                        LabeledContent("Generation", value: seconds(report.generationSeconds))
                        LabeledContent("Audio duration", value: seconds(report.audioSeconds))
                        if let footprint = report.peakFootprintMiB {
                            LabeledContent("Peak memory footprint", value: String(format: "%.0f MiB", footprint))
                        }
                        LabeledContent("Thermal state", value: report.finalThermalState.capitalized)
                        ShareLink(item: output) { Label("Share WAV", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("VoiceClone Probe")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], onCompletion: importReference)
            #if DEBUG || VOICECLONE_BENCHMARK
            .task { await runBenchmarkIfRequested() }
            #endif
        }
    }

    private func importReference(_ result: Result<URL, Error>) {
        do {
            let selected = try result.get()
            let scoped = selected.startAccessingSecurityScopedResource()
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
            let duration = try AudioFiles.duration(of: selected)
            guard (1...15).contains(duration) else {
                throw ProbeFailure(message: "Choose a reference recording between 1 and 15 seconds.")
            }
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(selected.pathExtension)
            try FileManager.default.copyItem(at: selected, to: local)
            if let reference { try? FileManager.default.removeItem(at: reference) }
            reference = local
            referenceName = selected.lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginGeneration() {
        guard let reference else { return }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceClone-\(UUID().uuidString).wav")
        let variant = self.variant
        let language = self.language
        let transcript = self.transcript
        let text = self.text
        let offline = self.offline
        Task {
            do {
                let request = try SynthesisRequest(
                    text: text, referenceAudio: reference, referenceText: transcript, language: language
                )
                try await generate(request, variant: variant, offline: offline, outputURL: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func generate(
        _ request: SynthesisRequest,
        variant: OmniVoiceSynthesizer.Variant,
        offline: Bool,
        outputURL: URL
    ) async throws {
        guard !generating else { return }
        generating = true
        errorMessage = nil
        defer { generating = false }

        let report = try await Task.detached(priority: .userInitiated) {
            try await ProbeRunner.run(request, variant: variant, offline: offline, outputURL: outputURL)
        }.value
        if let output, output.deletingLastPathComponent() == FileManager.default.temporaryDirectory {
            try? FileManager.default.removeItem(at: output)
        }
        self.report = report
        output = outputURL
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }

    #if DEBUG || VOICECLONE_BENCHMARK
    private func runBenchmarkIfRequested() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--benchmark"),
              index + 2 < arguments.count,
              let variant = OmniVoiceSynthesizer.Variant(rawValue: arguments[index + 1]),
              let language = SpeechLanguage(rawValue: arguments[index + 2]) else { return }
        self.variant = variant
        self.language = language
        let folder = URL.documentsDirectory.appending(path: "Benchmark", directoryHint: .isDirectory)
        let run = "\(variant.rawValue)-\(language.rawValue)"
        let reference = folder.appending(path: "reference-\(language.rawValue).aiff")
        let destination = folder.appending(path: "output-\(run).wav")
        let reportURL = folder.appending(path: "report-\(run).json")
        let errorURL = folder.appending(path: "error-\(run).txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in [destination, reportURL, errorURL] where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            let script = try JSONDecoder().decode(
                BenchmarkScript.self,
                from: Data(contentsOf: folder.appending(path: "script-\(language.rawValue).json"))
            )
            let request = try SynthesisRequest(
                text: script.text, referenceAudio: reference, referenceText: script.transcript, language: language
            )
            try await generate(request, variant: variant, offline: !arguments.contains("--allow-model-download"), outputURL: destination)
            if let report {
                try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
            }
        } catch {
            errorMessage = error.localizedDescription
            try? Data(error.localizedDescription.utf8).write(to: errorURL, options: .atomic)
        }
    }

    private struct BenchmarkScript: Decodable {
        let transcript: String
        let text: String
    }
    #endif
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
