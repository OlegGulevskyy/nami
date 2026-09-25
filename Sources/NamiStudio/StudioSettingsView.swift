import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

public struct StudioSettingsView: View {
    public enum Page: String, CaseIterable {
        case general = "General", permissions = "Permissions", model = "Local model", about = "About Nami"
    }

    @Bindable private var session: StudioSession
    private let page: Page
    @State private var editingShortcut = false
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    public init(session: StudioSession, page: Page = .general) {
        self.session = session
        self.page = page
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                switch page {
                case .general: general
                case .permissions: permissions
                case .model: model
                case .about: about
                }
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 15)).foregroundStyle(StudioStyle.ink)
        .onAppear {
            session.refreshInput(); session.modifierShortcut.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshInput(); session.modifierShortcut.refresh()
            loginStatus = SMAppService.mainApp.status
            shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        }
        .sheet(isPresented: $editingShortcut, onDismiss: {
            shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        }) {
            VStack(spacing: 0) {
                HStack {
                    Text("Recording shortcut").font(.headline)
                    Spacer()
                    Button("Done") { editingShortcut = false }.keyboardShortcut(.defaultAction)
                }.padding(20)
                RecordingShortcutSettings(session: session)
            }.background(StudioStyle.paper)
        }
    }

    @ViewBuilder private var general: some View {
        Text("Changes save automatically.").font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
        section("SHORTCUT") {
            row("Start / stop recording", subtitle: session.modifierShortcut.enabled
                ? "Tap twice to start. Tap once to finish."
                : "Press once to start. Press again to finish.") {
                Button { editingShortcut = true } label: {
                    HStack(spacing: 10) {
                        Text(session.modifierShortcut.enabled ? "⌥ ⌘" : shortcut?.description ?? "Set shortcut")
                        Image(systemName: "pencil").font(.system(size: 12))
                    }.preferenceControl()
                }.buttonStyle(.plain).accessibilityLabel("Edit recording shortcut")
            }
        }
        section("INPUT") {
            row("Microphone") {
                Menu {
                    Button("System default") { session.settings.microphoneUID = nil }
                    ForEach(session.inputDevices) { device in
                        Button {
                            session.settings.microphoneUID = device.id
                        } label: {
                            if session.settings.microphoneUID == device.id { Label(device.name, systemImage: "checkmark") }
                            else { Text(device.name) }
                        }
                    }
                    Divider()
                    Button("Refresh microphones") { session.refreshInput() }
                    Button("Change in Sound Settings…") { openSoundSettings() }
                } label: { Text(session.inputName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200) }
                    .preferenceMenu().accessibilityLabel("Microphone: \(session.inputName)")
            }
            row("Language") {
                Menu {
                    ForEach(languages, id: \.code) { language in
                        Button {
                            session.settings.language = language.code
                        } label: {
                            if session.settings.language == language.code { Label(language.name, systemImage: "checkmark") }
                            else { Text(language.name) }
                        }
                    }
                } label: { Text(languages.first { $0.code == session.settings.language }?.name ?? session.settings.language) }
                    .preferenceMenu().accessibilityLabel("Transcription language")
            }
        }.disabled(session.phase.busy)
        section("RECORDING") {
            row("Copy when finished", subtitle: "Your words on the clipboard, ready to paste.") {
                Toggle("Copy when finished", isOn: $session.settings.copyWhenFinished).labelsHidden().toggleStyle(StudioToggleStyle())
            }
            row("Paste automatically", subtitle: "Insert recordings at your cursor in another app. Requires Copy when finished.") {
                Toggle("Paste automatically", isOn: $session.settings.pasteWhenFinished)
                    .labelsHidden().toggleStyle(StudioToggleStyle())
                    .disabled(!session.settings.copyWhenFinished)
            }
            if session.settings.copyWhenFinished && session.settings.pasteWhenFinished {
                row("Accessibility", subtitle: session.permissions.accessibility
                    ? "Ready to paste into the focused app."
                    : "Allow Nami to paste for you. Until then, transcripts are copied.") {
                    if session.permissions.accessibility {
                        Label("Allowed", systemImage: "checkmark.circle").font(.system(size: 13))
                    } else {
                        Button("Allow Accessibility…", action: session.permissions.resolveAccessibility)
                            .buttonStyle(.plain).preferenceControl()
                    }
                }
                if let error = session.permissions.settingsError {
                    Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                }
            }
            row("Stop automatically") {
                Menu {
                    Button("Manually · 60-second limit") { session.settings.timed = false }
                    ForEach(Array(stride(from: 5, through: 60, by: 5)), id: \.self) { seconds in
                        Button("After \(seconds) seconds") {
                            session.settings.duration = Double(seconds); session.settings.timed = true
                        }
                    }
                } label: {
                    Text(session.settings.timed ? "After \(Int(session.settings.duration)) seconds" : "Manually (up to 60 sec)")
                }.preferenceMenu().accessibilityLabel("Stop automatically")
            }
            row("Recording history", subtitle: "All recordings and transcripts stay on this Mac. Nothing is automatically deleted.") {
                Button("Show folder") { NSWorkspace.shared.open(session.historyDirectory) }
                    .buttonStyle(.plain).preferenceControl()
            }
            row("Save extra audio copies", subtitle: "Also save microphone audio in a folder you choose.") {
                Toggle("Save extra audio copies", isOn: $session.settings.saveAudio).labelsHidden().toggleStyle(StudioToggleStyle())
            }
            if session.settings.saveAudio {
                row("Save extra copies to", subtitle: session.settings.audioDirectory) {
                    Button("Choose folder…", action: chooseAudioFolder).buttonStyle(.plain).preferenceControl()
                }
            }
        }.disabled(session.phase.busy)
        section("STARTUP") {
            row("Launch at login") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { setLaunchAtLogin($0) }
                )).labelsHidden().toggleStyle(StudioToggleStyle())
            }
            if loginStatus == .requiresApproval {
                Button("Allow Nami in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.plain).font(.system(size: 12)).padding(.top, 10)
            }
            if let loginError {
                Text(loginError).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 10)
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        Text("See what Nami can access. You can turn permissions off or on in System Settings.")
            .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
            permissionRow(.microphone, icon: "mic", detail: microphonePermissionDetail,
                          granted: session.permissions.microphone == .authorized,
                          status: microphonePermissionStatus) {
                Task { await session.permissions.resolveMicrophone() }
            }
            permissionRow(.inputMonitoring, icon: "keyboard",
                          detail: "Use the recording shortcut while you’re in another app. Required for Nami.",
                          granted: session.permissions.inputMonitoring) {
                session.permissions.resolveInputMonitoring()
            }
            permissionRow(.accessibility, icon: "hand.point.up.left",
                          detail: "Paste finished transcripts at your cursor. Optional; copying works without it.",
                          granted: session.permissions.accessibility) {
                session.permissions.resolveAccessibility()
            }
        }
        .disabled(session.permissions.requestingMicrophone)
        if let error = session.permissions.settingsError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("To revoke access, choose Manage… and turn Nami off. You can turn it back on in the same place. Follow any restart prompt from macOS.")
            Text("Permissions refresh automatically when you return to Nami.")
        }
        .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var microphonePermissionStatus: String {
        switch session.permissions.microphone {
        case .authorized: "Allowed"
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        default: "Not allowed"
        }
    }

    private var microphonePermissionDetail: String {
        session.permissions.microphone == .restricted
            ? "Access is restricted on this Mac. Contact your administrator to change it."
            : "Record your voice for on-device transcription. Required for Nami."
    }

    private func permissionRow(_ pane: StudioPermissions.Pane, icon: String, detail: String,
                               granted: Bool, status: String? = nil, allow: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(pane.title, systemImage: icon).font(.system(size: 15, weight: .medium))
                Spacer()
                Label(status ?? (granted ? "Allowed" : "Not allowed"),
                      systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12)).foregroundStyle(granted ? StudioStyle.green : StudioStyle.quiet)
            }
            Text(detail).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if !granted && !(pane == .microphone && session.permissions.microphone == .restricted) {
                    Button(pane == .microphone && session.permissions.requestingMicrophone ? "Waiting for macOS…" : "Allow…", action: allow)
                        .buttonStyle(.plain).preferenceControl()
                        .accessibilityLabel("Allow \(pane.title)")
                }
                Button("Manage…") { session.permissions.showSettings(pane) }
                    .buttonStyle(.plain).preferenceControl()
                    .help("Change \(pane.title) access in System Settings")
                    .accessibilityLabel("Manage \(pane.title) in System Settings")
            }
            StudioStyle.divider.padding(.top, 6)
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder private var model: some View {
        heading("A little intelligence. All local.", subtitle: "Your voice stays on your Mac, from audio to words.")
        section("RECOGNITION") {
            row("Transcription engine") {
                Menu {
                    Button("WhisperKit · on-device") { session.settings.engine = "whisperkit" }
                    Button("Demo · sample text") { session.settings.engine = "fake" }
                } label: { Text(session.settings.engine == "fake" ? "Demo" : "WhisperKit") }.preferenceMenu()
            }
            if session.settings.engine == "fake" {
                Text("Demo produces placeholder text. Choose WhisperKit to recognize your speech.")
                    .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet).padding(.vertical, 16)
            } else {
                row("Local model", subtitle: session.modelName) {
                    Button("Choose folder…", action: chooseModel).buttonStyle(.plain).preferenceControl()
                }
                HStack(spacing: 8) {
                    Circle().fill(StudioStyle.green.opacity(0.6)).frame(width: 6, height: 6)
                    Text(session.modelLoaded ? "Loaded and ready to listen" : "Loads when you make your first recording")
                }.font(.system(size: 12)).foregroundStyle(StudioStyle.quiet).padding(.top, 15)
                Text("The first recording can take a little longer while the model gets ready. After that, it stays loaded for this session.")
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(StudioStyle.quiet).padding(.top, 12)
            }
        }.disabled(session.phase.busy)
        section("READING PRACTICE") {
            row("Reading prompt", subtitle: "An optional passage for comparing recordings.") {
                Menu {
                    Button("Free speech") { session.selectedPromptID = "" }
                    ForEach(session.prompts) { prompt in
                        Button("\(prompt.id) · \(prompt.category)") { session.selectedPromptID = prompt.id }
                    }
                } label: { Text(session.selectedPrompt?.id ?? "Free speech") }.preferenceMenu()
            }
        }.disabled(session.phase.busy)
    }

    @ViewBuilder private var about: some View {
        heading("A little less typing.", subtitle: "A little more room for your thoughts.")
        VStack(alignment: .leading, spacing: 20) {
            Text("nami").font(.system(size: 54, weight: .semibold, design: .rounded)).tracking(-2)
            Text("Speak naturally. Keep your words close.")
                .font(.system(size: 21, weight: .medium, design: .rounded))
            Text("Nami turns short recordings into text with a local speech model. No account, no cloud transcription. Just your voice and your Mac.")
                .font(.system(size: 15)).lineSpacing(6).foregroundStyle(StudioStyle.quiet)
            StudioStyle.divider.padding(.vertical, 8)
            Label("Version 0.1 · Proof of concept", systemImage: "leaf")
            Text("All recordings and transcripts are saved on this Mac and restored when you reopen Nami. Imported audio is copied into history. There is no automatic deletion or history limit.")
                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(StudioStyle.quiet)
            Text("Finished text can be copied automatically. Pasting into another app is manual for now.")
                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(StudioStyle.quiet)
        }.padding(.top, 20)
    }

    private var languages: [(code: String, name: String)] {
        [("auto", "Auto-detect"), ("en", "English"), ("fr", "French"), ("uk", "Ukrainian"), ("es", "Spanish"), ("de", "German")]
    }
    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 28, weight: .medium)).tracking(-0.4)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
        }.padding(.bottom, 3)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(StudioStyle.quiet)
                .padding(.bottom, 13)
            content()
        }
    }
    private func row<Control: View>(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 15))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    }
                }
                Spacer(minLength: 8)
                control().fixedSize()
            }.padding(.vertical, 14).frame(minHeight: 55)
            StudioStyle.divider
        }
    }
    private func chooseModel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the downloaded WhisperKit model folder."
        if panel.runModal() == .OK, let url = panel.url { session.settings.modelFolder = url.path }
    }
    private func chooseAudioFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { session.settings.audioDirectory = url.path }
    }
    private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = "Could not update login settings. \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }
}

private extension View {
    func preferenceControl() -> some View {
        font(.system(size: 13)).foregroundStyle(StudioStyle.green)
            .padding(.horizontal, 11).frame(minHeight: 32)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StudioStyle.line))
    }
    func preferenceMenu() -> some View {
        menuStyle(.borderlessButton).fixedSize().preferenceControl()
    }
}
