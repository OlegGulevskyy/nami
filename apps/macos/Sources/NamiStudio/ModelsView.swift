import AppKit
import NamiWhisperKit
import SwiftUI

struct ModelsView: View {
    @Bindable var session: StudioSession
    @State private var confirmDeletion = false
    @State private var showingHelp = false
    @State private var error: String?
    @State private var installed = FastTranscriptionEngine.installed
    @State private var download: Task<Void, Never>?
    @Environment(\.studioPageVisible) private var visible
    private var locked: Bool { session.busyForUpdate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Picker("Dictation", selection: $session.settings.engine) {
                        Text("On-device").tag("fast")
                        Text("Cloud").tag(DictationProvider.groq.engineID)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(locked)
                    Button { showingHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(StudioStyle.quiet)
                    .help("About dictation models").accessibilityLabel("About dictation models")
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Dictation models").font(.system(size: 13, weight: .semibold))
                            Text("On-device uses Parakeet on this Mac. Download it once to get started.")
                            Text("Cloud uses Groq and requires your API key. Audio and vocabulary are sent to Groq, which bills usage to your account.")
                            Text("Switching applies immediately. Your API key is stored securely in Keychain.")
                        }
                        .font(.system(size: 12)).frame(width: 320, alignment: .leading).padding(16)
                    }
                }
                if session.settings.engine == DictationProvider.groq.engineID {
                    CloudDictationSettingsView(session: session)
                } else {
                    parakeet
                }
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onStudioPageVisibility(appear: { installed = FastTranscriptionEngine.installed })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if visible { installed = FastTranscriptionEngine.installed }
        }
        .alert("Delete Parakeet?", isPresented: $confirmDeletion) {
            Button("Delete model", role: .destructive) {
                Task {
                    do { try await session.deleteFastModel() }
                    catch { self.error = error.localizedDescription }
                    installed = FastTranscriptionEngine.installed
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the downloaded model. Your recordings stay. Download Parakeet again or switch to Cloud to continue dictating.")
        }
    }

    private var parakeet: some View {
        HStack(spacing: 12) {
            Text("Parakeet").font(.system(size: 15, weight: .semibold))
            Spacer()
            if download != nil {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(StudioStyle.quiet)
                Button { download?.cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Cancel download").accessibilityLabel("Cancel download")
            } else if session.modelMaintenance {
                ProgressView().controlSize(.small)
                Text("Removing…").foregroundStyle(StudioStyle.quiet)
            } else if installed {
                Label("Ready", systemImage: "checkmark.circle")
                    .foregroundStyle(StudioStyle.quiet)
                Menu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([FastTranscriptionEngine.modelDirectory])
                    }
                    Button("Delete model…", role: .destructive) { confirmDeletion = true }
                        .disabled(locked)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Manage Parakeet").accessibilityLabel("Manage Parakeet")
            } else {
                Button("Download", action: downloadModel).studioProminentButton().disabled(locked)
                    .help("Download Parakeet, approximately 630 MB")
            }
        }
        .font(.system(size: 13))
        .padding(20).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.line))
    }

    private func downloadModel() {
        error = nil
        download = Task {
            defer { download = nil; installed = FastTranscriptionEngine.installed }
            do {
                try await FastTranscriptionEngine.download()
                try Task.checkCancellation()
                if session.settings.engine == "fast" { session.prepareInstalledParakeet() }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
