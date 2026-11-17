import SwiftUI
import UniformTypeIdentifiers
import VoiceCloneCore
#if os(macOS)
import AppKit
#endif

struct StudioView: View {
    @Bindable var model: StudioViewModel
    @State private var audio = StudioAudioControls()
    @State private var sheet: StudioSheet?
    @State private var deletion: Deletion?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    navigation
                    if let project = model.project {
                        editor(project)
                    } else {
                        ContentUnavailableView {
                            Label("No project selected", systemImage: "document")
                        } description: {
                            Text("Create a project to start generating speech.")
                        } actions: {
                            Button("New project", action: model.addProject).buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("VoiceClone")
            .safeAreaInset(edge: .bottom) {
                if let status = model.status { activity(status) }
            }
        }
        .sheet(item: $sheet, content: present)
        .alert("VoiceClone", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .confirmationDialog(deletion?.title ?? "", isPresented: Binding(
            get: { deletion != nil },
            set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible, presenting: deletion) { item in
            Button("Delete", role: .destructive, action: item.action)
        }
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button { sheet = .projects } label: { Label("Projects", systemImage: "folder") }
            Button { sheet = .voices } label: { Label("Voices", systemImage: "waveform") }
            Button { sheet = .models } label: { Label("Models", systemImage: "cpu") }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(model.isBusy)
    }

    private func editor(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    sheet = .projectName(project.name)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(project.name).font(.largeTitle.weight(.semibold))
                        Image(systemName: "pencil").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename project")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { projectOptions(project) }
                    VStack(alignment: .leading, spacing: 8) { projectOptions(project) }
                }
            }
            .disabled(model.isBusy)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Script").font(.title2.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("Paste script") { sheet = .paste }
                        Button("Add section") { sheet = .section(nil, "") }
                    } label: { Label("Add text", systemImage: "plus") }
                    .disabled(model.isBusy)
                }
                if project.sections.isEmpty {
                    Button("Add section") { sheet = .section(nil, "") }
                        .disabled(model.isBusy)
                }
                ForEach(Array(project.sections.enumerated()), id: \.element.id) { index, section in
                    sectionRow(section, index: index, project: project)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { projectActions(project) }
                VStack(alignment: .leading, spacing: 12) { projectActions(project) }
            }
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder
    private func projectOptions(_ project: StudioProject) -> some View {
        if model.workspace.voices.isEmpty {
            Button { sheet = .addVoice } label: { Label("Add voice", systemImage: "waveform.badge.plus") }
        } else {
            Picker("Voice", selection: Binding(get: { project.voiceID }, set: model.setVoice)) {
                Text("Choose a voice").tag(UUID?.none)
                ForEach(model.workspace.voices) { voice in Text(voice.name).tag(Optional(voice.id)) }
            }
            .fixedSize()
        }
        Picker("Language", selection: Binding(get: { project.language }, set: model.setLanguage)) {
            Text("English").tag(SpeechLanguage.english)
            Text("Turkish").tag(SpeechLanguage.turkish)
        }
        .fixedSize()
    }

    private func sectionRow(_ section: StudioSection, index: Int, project: StudioProject) -> some View {
        let current = project.currentGeneration(for: section)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Section \(index + 1)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Button(section.preview) { sheet = .section(section.id, section.text) }
                    .buttonStyle(.plain)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHint("Edit this section")
                if let current {
                    Text(current.model.name).font(.caption).foregroundStyle(.secondary)
                } else if section.generation != nil {
                    Text("Needs regeneration").font(.caption).foregroundStyle(.orange)
                }
            }
            if let current {
                Button { play(model.audioURL(for: current.id)) } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play section \(index + 1)")
            }
            Menu {
                Button("Edit") { sheet = .section(section.id, section.text) }
                Button(section.generation == nil ? "Generate" : "Regenerate") { model.generate(section.id) }
                    .disabled(section.text.isBlank)
                Button("Move up") { model.moveSection(section.id, offset: -1) }.disabled(index == 0)
                Button("Move down") { model.moveSection(section.id, offset: 1) }
                    .disabled(index == project.sections.count - 1)
                Button("Delete section", role: .destructive) {
                    deletion = Deletion(title: "Delete section \(index + 1)?") { model.deleteSection(section.id) }
                }
            } label: { Image(systemName: "ellipsis").accessibilityLabel("Section \(index + 1) actions") }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func projectActions(_ project: StudioProject) -> some View {
        let ready = model.readyModels.contains(model.selectedModel)
        if !ready {
            Button { sheet = .models } label: { Label("Download model", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderedProminent)
        } else {
            Button { model.generate() } label: { Label("Generate remaining", systemImage: "waveform") }
                .buttonStyle(.borderedProminent)
                .disabled(project.voiceID == nil || model.hasCompleteAudio || project.sections.allSatisfy { $0.text.isBlank })
        }
        Button { model.exportProject() } label: { Label("Prepare WAV", systemImage: "square.and.arrow.up") }
            .buttonStyle(.bordered)
            .disabled(!model.hasCompleteAudio)
        if let output = model.exportURL {
            #if os(macOS)
            Button { saveExport(output) } label: { Label("Save WAV", systemImage: "square.and.arrow.down") }
            #else
            ShareLink(item: output) { Label("Share WAV", systemImage: "square.and.arrow.up") }
            #endif
        }
    }

    private func activity(_ status: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(status).font(.callout)
                if let progress = model.progress { ProgressView(value: progress) }
                else { ProgressView().controlSize(.small) }
            }
            Spacer()
            Button("Cancel", action: model.cancel)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func present(_ item: StudioSheet) -> some View {
        switch item {
        case .projects:
            panel("Projects") {
                List {
                    Button { model.addProject(); sheet = nil } label: { Label("New project", systemImage: "plus") }
                    ForEach(model.workspace.projects) { project in
                        HStack {
                            Button(project.name) {
                                model.selectProject(project.id)
                                sheet = nil
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if project.id == model.project?.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                    }
                    if let project = model.project {
                        Button("Delete current project", role: .destructive) {
                            sheet = nil
                            deletion = Deletion(title: "Delete \(project.name)?", action: model.deleteProject)
                        }
                    }
                }
            }
        case .voices:
            panel("Voices") {
                List {
                    Button { sheet = .addVoice } label: { Label("Add voice", systemImage: "plus") }
                    ForEach(model.workspace.voices) { voice in
                        HStack {
                            Button(voice.name) { model.setVoice(voice.id); sheet = nil }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Play", systemImage: "play.circle") { play(model.audioURL(for: voice.id)) }
                                .labelStyle(.iconOnly)
                            Menu {
                                Button("Delete voice", role: .destructive) {
                                    sheet = nil
                                    deletion = Deletion(title: "Delete \(voice.name)?") { model.deleteVoice(voice.id) }
                                }
                            } label: { Image(systemName: "ellipsis") }
                            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
                            .fixedSize()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        case .models:
            panel("Models") {
                List {
                    ForEach(model.supportedModels) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(entry.name).font(.headline)
                                if entry == model.selectedModel { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                Spacer()
                                if entry == model.recommendedModel { Text("Recommended").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(ByteCountFormatter.string(fromByteCount: entry.downloadBytes, countStyle: .file))
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                if model.readyModels.contains(entry) {
                                    Button(entry == model.selectedModel ? "Selected" : "Use model") { model.setModel(entry) }
                                        .disabled(model.isBusy || entry == model.selectedModel)
                                    Button("Remove", role: .destructive) { model.removeModel(entry) }
                                        .disabled(model.isBusy)
                                } else {
                                    Button("Download") { model.downloadModel(entry) }
                                        .disabled(model.isBusy)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 5)
                    }
                    if let status = model.status {
                        if let progress = model.progress { ProgressView(status, value: progress) }
                        else { ProgressView(status) }
                        Button("Cancel", action: model.cancel)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
            }
        case .addVoice:
            VoiceEditor(audio: audio, save: model.addVoice) { sheet = nil }
        case .projectName(let name):
            ScriptEditor(title: "Rename project", value: name, multiline: false) {
                model.renameProject($0)
                sheet = nil
            } close: { sheet = nil }
        case .section(let id, let text):
            ScriptEditor(title: id == nil ? "Add section" : "Edit section", value: text) {
                if let id { model.editSection(id, text: $0) }
                else { model.addSection($0) }
                sheet = nil
            } close: { sheet = nil }
        case .paste:
            ScriptEditor(title: "Paste script", value: "", help: "Blank lines start new sections.") {
                model.appendScript($0)
                sheet = nil
            } close: { sheet = nil }
        }
    }

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
    }

    private func play(_ url: URL) {
        do { try audio.play(url) }
        catch { model.error = error.localizedDescription }
    }

    #if os(macOS)
    private func saveExport(_ source: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: destination, create: true)
                defer { try? files.removeItem(at: staging) }
                let file = staging.appendingPathComponent(destination.lastPathComponent)
                try files.copyItem(at: source, to: file)
                _ = try files.replaceItemAt(destination, withItemAt: file)
            } else {
                try files.copyItem(at: source, to: destination)
            }
        } catch { model.error = error.localizedDescription }
    }
    #endif
}

private struct Deletion {
    let title: String
    let action: () -> Void
}

private enum StudioSheet: Identifiable {
    case projects, voices, models, addVoice, paste
    case projectName(String)
    case section(UUID?, String)

    var id: String {
        switch self {
        case .projects: "projects"
        case .voices: "voices"
        case .models: "models"
        case .addVoice: "add-voice"
        case .paste: "paste"
        case .projectName: "project-name"
        case .section(let id, _): id?.uuidString ?? "new-section"
        }
    }
}
