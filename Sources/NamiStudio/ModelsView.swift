import AppKit
import NamiCore
import NamiMLXCleanup
import NamiWhisperKit
import SwiftUI

struct ModelsView: View {
    @Bindable var session: StudioSession
    @State private var deletion: Deletion?
    @State private var error: String?
    @State private var browse = false
    @State private var search = ""
    private var service: CleanupService { session.cleanupService }
    private var locked: Bool { session.busyForUpdate }
    private enum Deletion: Identifiable {
        case whisper(TranscriptionModel), qwen(QwenModel)
        var id: String {
            switch self { case .whisper(let model): model.id; case .qwen(let model): model.id }
        }
        var title: String {
            switch self { case .whisper(let model): model.name; case .qwen(let model): model.engine.title }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("Download models or delete them to free space.")
                        .font(.system(size: 14)).foregroundStyle(StudioStyle.quiet)
                    Spacer()
                    Button("Open model folder") {
                        do {
                            try FileManager.default.createDirectory(at: service.modelsRoot, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(service.modelsRoot)
                        } catch { self.error = error.localizedDescription }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let error = service.downloadError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if session.debugging.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(session.debugging.status).lineLimit(2)
                        Spacer()
                        Button("Cancel") { session.debugging.cancel() }
                    }.font(.system(size: 13))
                }
                if let error = session.debugging.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red)
                }
                if session.modelMaintenance {
                    HStack { ProgressView().controlSize(.small); Text("Removing model…") }
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        StudioSectionHeader(title: "Transcription")
                        Button("Add folder…", action: chooseFolder).disabled(locked)
                    }
                    DisclosureGroup("Browse more transcription models", isExpanded: $browse) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Filter model names", text: $search)
                            Button(session.debugging.availableModels.isEmpty ? "Load model catalog" : "Refresh catalog") {
                                session.debugging.fetchModels()
                            }.disabled(locked)
                        }.padding(.top, 12)
                    }.font(.system(size: 13))
                    LazyVStack(spacing: 12) {
                        ForEach(session.modelLibrary.transcription.filter { model in
                            (model.hasFiles || model.name == WhisperKitEngine.defaultModel || session.debugging.workspace.models.contains(where: { entry in entry.folder == model.id }) || browse) &&
                            (!browse || search.isEmpty || model.name.localizedCaseInsensitiveContains(search))
                        }) { model in whisperRow(model) }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    StudioSectionHeader(title: "Text cleanup")
                    ForEach(QwenModel.allCases) { model in qwenRow(model) }
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Apple Intelligence").font(.system(size: 15, weight: .semibold))
                            Text(service.appleUnavailableReason == nil ? "Available · managed by macOS" : "Unavailable · managed by macOS")
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                        }
                        Spacer()
                        Button("System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }.padding(18).background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 10))
                    Text("RAM estimates cover short cleanup requests and exclude transcription. Actual peaks vary.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { session.refreshModels() }
        .onChange(of: session.debugging.isBusy) { if !session.debugging.isBusy { session.refreshModels() } }
        .onChange(of: session.settings.modelFolder) { session.refreshModels() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in session.refreshModels() }
        .alert(item: $deletion) { item in
            Alert(title: Text("Delete \(item.title)?"),
                  message: Text("Deletes this model's downloaded files. Recordings and saved corrections stay. A selected dictation model will be disabled. You can download the model again."),
                  primaryButton: .destructive(Text("Delete model")) { remove(item) },
                  secondaryButton: .cancel())
        }
    }

    private func whisperRow(_ model: TranscriptionModel) -> some View {
        let selected = !session.settings.modelFolder.isEmpty &&
            URL(fileURLWithPath: session.settings.modelFolder).standardizedFileURL == model.folder.standardizedFileURL
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name == WhisperKitEngine.defaultModel ? "Whisper large-v3 turbo" : model.name.replacingOccurrences(of: "openai_whisper-", with: "Whisper "))
                    .font(.system(size: 15, weight: .semibold)).lineLimit(2).help(model.folder.path)
                Spacer(minLength: 12)
                stateLabel(model.installed ? (selected ? "Installed · selected" : "Installed") : (model.hasFiles ? "Incomplete" : "Not installed"), ready: model.installed)
            }
            ViewThatFits(in: .horizontal) {
                HStack { whisperSize(model); Spacer(); whisperActions(model, selected: selected) }
                VStack(alignment: .leading, spacing: 12) { whisperSize(model); whisperActions(model, selected: selected) }
            }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioStyle.line))
    }
    private func whisperSize(_ model: TranscriptionModel) -> some View {
        Text(model.hasFiles ? "\(ModelFiles.sizeLabel(model.bytes)) on disk" :
                (model.name == WhisperKitEngine.defaultModel ? "~630 MB download" : "Size depends on model"))
            .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
    }
    @ViewBuilder private func whisperActions(_ model: TranscriptionModel, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if model.installed {
                Button(selected ? "Selected" : "Use for dictation") {
                    session.settings.modelFolder = model.folder.path
                    session.settings.engine = "whisperkit"
                }.disabled(locked || selected)
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder]) }
                    Button("Add to transcription comparison") {
                        session.debugging.addModel(folder: model.folder)
                        session.debugging.setModelEnabled(model.id, enabled: true)
                    }.disabled(locked)
                } label: { Image(systemName: "ellipsis") }.fixedSize().help("Model options")
            } else if !model.hasFiles {
                Button("Download") { session.debugging.downloadModel(model.name, to: session.modelLibrary.installRoot(for: model)) }
                    .studioProminentButton().disabled(locked)
            }
            if model.hasFiles {
                if model.managed {
                    Button("Delete…", role: .destructive) { deletion = .whisper(model) }.disabled(locked)
                } else {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder]) }
                        .help("Files outside Nami's model folders are managed in Finder.")
                }
            }
        }.font(.system(size: 12))
    }

    private func qwenRow(_ model: QwenModel) -> some View {
        let installed = service.isInstalled(model.engine)
        let hasFiles = FileManager.default.fileExists(atPath: service.folder(for: model).path)
        let downloading = service.downloadingEngine == model.engine
        let included = model == .qwen06 ? session.debugging.cleanupLab.compareQwen : session.debugging.cleanupLab.compareQwen17
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(model.engine.title) · 4-bit").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                stateLabel(downloading ? "Downloading…" : installed ? "Installed" : hasFiles ? "Incomplete" : "Not installed", ready: installed)
            }
            Text("\(ModelFiles.sizeLabel(hasFiles ? ModelFiles.size(at: service.folder(for: model)) : model.downloadBytes)) \(hasFiles ? "on disk" : "download") · RAM ~\(model.memoryEstimate)")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            HStack(spacing: 12) {
                if downloading {
                    ProgressView().controlSize(.small)
                    Button("Cancel download") { service.cancelDownload() }
                } else if installed {
                    Button(included ? "Included in comparison" : "Add to comparison") {
                        if model == .qwen06 { session.debugging.cleanupLab.compareQwen = true }
                        else { session.debugging.cleanupLab.compareQwen17 = true }
                        session.debugging.cleanupLab.savePreferences()
                    }.disabled(locked || included)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([service.folder(for: model)]) }
                } else if !hasFiles {
                    Button("Download") { service.downloadQwen(model.engine) }
                        .studioProminentButton().disabled(locked)
                }
                Spacer()
                if hasFiles && !downloading {
                    Button("Delete…", role: .destructive) { deletion = .qwen(model) }.disabled(locked)
                }
            }.font(.system(size: 12))
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioStyle.line))
    }

    private func stateLabel(_ text: String, ready: Bool) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(ready ? StudioStyle.green : StudioStyle.quiet)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a WhisperKit transcription model folder."
        if panel.runModal() == .OK, let folder = panel.url {
            session.debugging.addModel(folder: folder)
            session.refreshModels()
        }
    }
    private func remove(_ item: Deletion) {
        error = nil
        Task {
            do {
                switch item {
                case .whisper(let model): try await session.deleteTranscriptionModel(model)
                case .qwen(let model): try await session.deleteCleanupModel(model)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
