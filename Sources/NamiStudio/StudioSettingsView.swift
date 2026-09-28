import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

public struct StudioSettingsView: View {
    public enum Page: String, CaseIterable {
        case general = "General", permissions = "Permissions", model = "Models", about = "About Nami"
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
        Group {
            if page == .model {
                ModelsView(session: session)
            } else if page == .about {
                about
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        switch page {
                        case .general: general
                        case .permissions: permissions
                        case .model: EmptyView()
                        case .about: EmptyView()
                        }
                        if let error = session.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
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
        Text("Changes save automatically.").font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
        section("Recording") {
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
            Group {
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
            }.disabled(session.phase.busy)
        }
        section("Transcription") {
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
            Text("Vocabulary").font(.system(size: 15)).padding(.top, 8)
            Text("Help Nami recognize names and technical terms. Separate them with commas or new lines.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3).padding(.bottom, 8)
            TextEditor(text: $session.settings.vocabulary)
                .font(.system(size: 14)).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(8).frame(height: 76)
                .background(StudioStyle.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.line))
                .accessibilityLabel("Vocabulary")
                .help("For example: Nami, Oleg, WhisperKit, PostHog, TypeScript.")
            Text("Applies to your next transcription. Keep it short; long lists use only the last terms. Clear to disable hints.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }.disabled(session.phase.busy)
        section("Clipboard") {
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
        }.disabled(session.phase.busy)
        section("History") {
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
        section("Appearance") {
            row("Transcript font", subtitle: "Used for your transcription history.") {
                Menu {
                    ForEach(TranscriptFont.allCases, id: \.self) { typeface in
                        Button {
                            session.settings.transcriptFont = typeface
                        } label: {
                            if session.settings.transcriptFont == typeface {
                                Label(typeface.title, systemImage: "checkmark")
                            } else {
                                Text(typeface.title)
                            }
                        }
                    }
                } label: { Text(session.settings.transcriptFont.title) }
                    .preferenceMenu()
                    .accessibilityLabel("Transcript font: \(session.settings.transcriptFont.title)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.quiet)
                Text("A thought worth keeping. Let’s meet at 10:30, share a few ideas, and make something great together.")
                    .font(session.settings.transcriptFont.font).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 9))
            .padding(.top, 4)
        }
        section("App") {
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
            updateSettings
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

    @ViewBuilder private var about: some View {
        VStack(spacing: 8) {
            Text("nami").font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2")")
                .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
            if let updates = session.updates {
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .buttonStyle(.plain).preferenceControl().padding(.top, 12)
                    .disabled(!updates.canCheckForUpdates || session.busyForUpdate)
                if let status = updates.status {
                    Text(status).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var updateSettings: some View {
        if let updates = session.updates {
            row("Check for updates automatically", subtitle: "Check daily. You choose when to download and install.") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }
                )).labelsHidden().toggleStyle(StudioToggleStyle()).disabled(!updates.available)
            }
            row("Software updates", subtitle: updates.status ?? (session.busyForUpdate
                ? "Available after the current task finishes." : "Keep Nami up to date.")) {
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .buttonStyle(.plain).preferenceControl()
                    .disabled(!updates.canCheckForUpdates || session.busyForUpdate)
            }
        } else {
            Text("Updates are unavailable in this preview.")
                .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
        }
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
            HStack(spacing: 12) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                StudioStyle.divider
            }
            .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.leading, 24)
        }
    }
    private func row<Control: View>(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                }
            }
            Spacer(minLength: 8)
            control().fixedSize()
        }.padding(.vertical, 8).frame(minHeight: 44)
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
