import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

public struct StudioSettingsView: View {
    public enum Page: String, CaseIterable {
        case general = "General", shortcuts = "Shortcuts", model = "Models"
    }

    @Bindable private var session: StudioSession
    @Bindable private var modifierShortcut: ModifierRecordingShortcut
    private let page: Page
    /// Read off the main thread: the status is a synchronous XPC call.
    @State private var loginStatus: SMAppService.Status?
    @Environment(\.studioPageVisible) private var visible
    @State private var loginError: String?
    /// The helpers folder holding the bundled command-line tools; nil when this build has none.
    @State private var skillTools: URL?
    @State private var skillStatuses: [String: AgentSkillStatus] = [:]
    @State private var skillConfirmation: SkillConfirmation?
    @State private var skillsError: String?
    @State private var showingShortcutHelp = false

    public init(session: StudioSession, page: Page = .general) {
        self.session = session
        self.modifierShortcut = session.modifierShortcut
        self.page = page
    }

    public var body: some View {
        Group {
            if page == .model {
                ModelsView(session: session)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        switch page {
                        case .general: general
                        case .shortcuts: shortcuts
                        case .model: EmptyView()
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
        .onStudioPageVisibility(appear: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if visible { refresh() }
        }
    }

    @ViewBuilder private var general: some View {
        section("Recording") {
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
            if let volume = session.inputVolume {
                row("Input volume", subtitle: "Also changes this microphone's level in other apps.") {
                    HStack(spacing: 10) {
                        Image(systemName: "mic").font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                        Slider(value: Binding(get: { volume }, set: { session.setInputVolume($0) }), in: 0...1)
                            .frame(width: 180).tint(StudioStyle.accent)
                            .accessibilityLabel("Input volume")
                        Text("\(Int((volume * 100).rounded()))%").font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(StudioStyle.quiet).frame(width: 40, alignment: .trailing)
                    }
                }
            }
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
            row("Quote highlighted text", subtitle: "Replace “this” or “that” with the text you highlight while recording.") {
                Toggle("Quote highlighted text", isOn: $session.settings.quoteHighlights)
                    .labelsHidden().toggleStyle(StudioToggleStyle())
                    .help("In Google Docs, Nami briefly copies the selection, then restores your clipboard.")
            }
        }.disabled(session.phase.busy)
        section("Permissions") {
            permissions
        }
        section("History") {
            row("Recording history") {
                Button("Show folder") { NSWorkspace.shared.open(session.historyDirectory) }
                    .buttonStyle(.plain).preferenceControl()
            }
            row("Save extra audio copies") {
                Toggle("Save extra audio copies", isOn: $session.settings.saveAudio).labelsHidden().toggleStyle(StudioToggleStyle())
            }
            if session.settings.saveAudio {
                row("Save extra copies to", subtitle: session.settings.audioDirectory) {
                    Button("Choose folder…", action: chooseAudioFolder).buttonStyle(.plain).preferenceControl()
                }
            }
        }.disabled(session.phase.busy)
        section("Appearance") {
            row("Theme") {
                Menu {
                    ForEach(StudioAppearance.allCases, id: \.self) { appearance in
                        Button {
                            session.settings.appearance = appearance
                        } label: {
                            if session.settings.appearance == appearance {
                                Label(appearance.title, systemImage: "checkmark")
                            } else {
                                Text(appearance.title)
                            }
                        }
                    }
                } label: { Text(session.settings.appearance.title) }
                    .preferenceMenu()
                    .accessibilityLabel("Theme: \(session.settings.appearance.title)")
            }
            row("Transcript font") {
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
        section("Agent skills") {
            row("Install to", subtitle: (skillsFolder.path as NSString).abbreviatingWithTildeInPath) {
                Menu {
                    Button("Claude Code") { session.settings.skillsFolder = "" }
                    Button("Other agents") { session.settings.skillsFolder = AgentSkillInstaller.agentsFolder.path }
                    Button("Choose folder…", action: chooseSkillsFolder)
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skillsFolder]) }
                        .disabled(!FileManager.default.fileExists(atPath: skillsFolder.path))
                } label: { Text(skillsFolderTitle) }
                    .preferenceMenu().accessibilityLabel("Install skills to \(skillsFolder.path)")
            }
            ForEach(AgentSkill.bundled) { skill in skillRow(skill) }
            if skillTools == nil {
                Text("This build doesn’t include Nami’s command-line tools, so skills can’t be installed.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet).padding(.top, 6)
            }
            if let skillsError {
                Label(skillsError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).padding(.top, 6)
            }
        }
        .onChange(of: session.settings.skillsFolder) { refreshSkills() }
        .confirmationDialog(skillConfirmation?.title ?? "", isPresented: Binding(
            get: { skillConfirmation != nil }, set: { if !$0 { skillConfirmation = nil } }
        ), titleVisibility: .visible, presenting: skillConfirmation) { confirmation in
            switch confirmation {
            case .remove(let skill): Button("Remove", role: .destructive) { changeSkill(skill) { try $0.remove(skill) } }
            case .replace(let skill): Button("Replace", role: .destructive) { changeSkill(skill) { try $0.install(skill) } }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        let status = skillStatuses[skill.name] ?? .notInstalled
        return row(skill.title, subtitle: skillDetail(status, bundled: skill.version)) {
            HStack(spacing: 14) {
                switch status {
                case .notInstalled:
                    Button("Install") { changeSkill(skill) { try $0.install(skill) } }
                        .buttonStyle(.plain).preferenceControl().accessibilityLabel("Install \(skill.name)")
                case .outdated:
                    Button("Update") { changeSkill(skill) { try $0.install(skill) } }
                        .buttonStyle(.plain).preferenceControl().accessibilityLabel("Update \(skill.name)")
                case .changed, .newer:
                    Button("Reinstall") { skillConfirmation = .replace(skill) }
                        .buttonStyle(.plain).preferenceControl().accessibilityLabel("Reinstall \(skill.name)")
                case .current:
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.accent)
                }
                if status != .notInstalled {
                    Button { skillConfirmation = .remove(skill) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(StudioStyle.quiet)
                        .help("Remove skill").accessibilityLabel("Remove \(skill.name)")
                }
            }
            .disabled(skillTools == nil)
        }
    }

    private func skillDetail(_ status: AgentSkillStatus, bundled: Int) -> String? {
        switch status {
        case .notInstalled, .current: nil
        case .outdated: "Version \(bundled) available"
        case .changed: "Modified locally or installed from another location"
        case .newer(let installed): "Version \(installed) installed; this app includes version \(bundled)"
        }
    }

    private var skillsFolder: URL {
        session.settings.skillsFolder.isEmpty ? AgentSkillInstaller.claudeCodeFolder
            : URL(fileURLWithPath: (session.settings.skillsFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    private var skillsFolderTitle: String {
        switch skillsFolder.standardizedFileURL {
        case AgentSkillInstaller.claudeCodeFolder.standardizedFileURL: "Claude Code"
        case AgentSkillInstaller.agentsFolder.standardizedFileURL: "Other agents"
        default: "Custom folder"
        }
    }

    private func refreshSkills() {
        skillTools = AgentSkillInstaller.bundledTools
        guard let skillTools else { skillStatuses = [:]; return }
        let installer = AgentSkillInstaller(folder: skillsFolder, tools: skillTools)
        skillStatuses = Dictionary(uniqueKeysWithValues: AgentSkill.bundled.map { ($0.name, installer.status($0)) })
    }

    private func changeSkill(_ skill: AgentSkill, _ change: (AgentSkillInstaller) throws -> Void) {
        guard let skillTools else { return }
        do {
            try change(AgentSkillInstaller(folder: skillsFolder, tools: skillTools))
            skillsError = nil
        } catch {
            skillsError = "Could not change \(skill.name). \(error.localizedDescription)"
        }
        refreshSkills()
    }

    @ViewBuilder private var shortcuts: some View {
        HStack {
            Spacer()
            Button { showingShortcutHelp.toggle() } label: {
                Label("How it works", systemImage: "questionmark.circle")
            }
            .buttonStyle(.plain).preferenceControl()
            .popover(isPresented: $showingShortcutHelp, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shortcuts").font(.system(size: 13, weight: .semibold))
                    Text("Press and release Option–Command twice within half a second to record, then once to finish. Turn taps off to assign your own recording shortcuts.")
                    Text("To pin a destination, focus a text field and use Pin / unpin input. Your next transcript goes there. Press again to unpin.")
                    Text("Click a shortcut to change its keys. Search, recording, and import shortcuts apply in History.")
                }
                .font(.system(size: 12)).frame(width: 320, alignment: .leading).padding(16)
            }
        }
        section("Pin input") {
            shortcutRow("Pin / unpin input", name: .pinDestination)
        }.disabled(session.phase.busy)
        section("Recording") {
            row("Option–Command taps") {
                Toggle("Use Option–Command taps", isOn: $modifierShortcut.enabled)
                    .labelsHidden().toggleStyle(StudioToggleStyle())
            }
            if session.modifierShortcut.enabled {
                row("Start recording") { StudioKeycap(text: "⌥⌘ twice") }
                row("Stop & transcribe") { StudioKeycap(text: "⌥⌘ once") }
                if !session.modifierShortcut.isListening {
                    Label(session.modifierShortcut.message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).padding(.vertical, 8)
                    Button("Allow Input Monitoring…", action: session.modifierShortcut.requestPermission)
                        .buttonStyle(.plain).preferenceControl()
                }
            }
            StudioStyle.divider.padding(.vertical, 12)
            Group {
                shortcutRow("Start / stop recording", name: .toggleRecording)
                shortcutRow("Start recording", name: .startRecording)
                shortcutRow("Stop & transcribe", name: .stopRecording)
            }.disabled(session.modifierShortcut.enabled)

        }.disabled(session.phase.busy)
        section("In Nami") {
            ForEach(StudioView.Page.allCases.filter { $0.shortcutKey != nil }, id: \.self) { destination in
                row("Show \(destination.rawValue)") { StudioKeycap(text: destination.shortcutLabel ?? "") }
            }
            row("Open Settings") { StudioKeycap(text: "⌘,") }
            row("Search transcripts") { StudioKeycap(text: "⌘F") }
            row("Start / stop recording") { StudioKeycap(text: "⌘R") }
            row("Import audio") { StudioKeycap(text: "⌘O") }
            row("Go back / cancel") {
                StudioKeycap(text: "Esc")
            }
        }
    }

    private func shortcutRow(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        row(title) {
            KeyboardShortcuts.Recorder(for: name)
                .shortcutValidation { shortcut in
                    if RecordingShortcuts.assignable.contains(where: { $0 != name && KeyboardShortcuts.getShortcut(for: $0) == shortcut }) {
                        return .disallow(reason: "This shortcut is already assigned to another Nami action. Choose different keys, or clear the other shortcut first.")
                    }
                    return .allow
                }
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder private var permissions: some View {
        VStack(spacing: 0) {
            permissionRow(.microphone, icon: "mic", detail: microphonePermissionDetail,
                          granted: session.permissions.microphone == .authorized,
                          status: microphonePermissionStatus) {
                Task { await session.permissions.resolveMicrophone() }
            }
            StudioStyle.divider
            permissionRow(.inputMonitoring, icon: "keyboard",
                          detail: "Use recording shortcuts in other apps.",
                          granted: session.permissions.inputMonitoring) {
                session.permissions.resolveInputMonitoring()
            }
            StudioStyle.divider
            permissionRow(.accessibility, icon: "hand.point.up.left",
                          detail: "Paste transcripts automatically into your text field.",
                          granted: session.permissions.accessibility) {
                session.permissions.resolveAccessibility()
            }
        }
        .disabled(session.permissions.requestingMicrophone)
        if let error = session.permissions.settingsError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
    }

    private var microphonePermissionStatus: String {
        switch session.permissions.microphone {
        case .authorized: "Allowed"
        case .notDetermined: "Required"
        case .restricted: "Restricted"
        default: "Not allowed"
        }
    }

    private var microphonePermissionDetail: String {
        session.permissions.microphone == .restricted
            ? "Access is restricted on this Mac. Contact your administrator to change it."
            : "Record your voice."
    }

    private func permissionRow(_ pane: StudioPermissions.Pane, icon: String, detail: String,
                               granted: Bool, status: String? = nil, allow: @escaping () -> Void) -> some View {
        let restricted = pane == .microphone && session.permissions.microphone == .restricted
        return HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(StudioStyle.quiet)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(pane.title).font(.system(size: 15))
                if !granted {
                    Text(detail).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Label(status ?? (granted ? "Allowed" : "Required"),
                  systemImage: granted ? "checkmark.circle" : "circle")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize()
            if granted || restricted {
                Button("Manage…") { session.permissions.showSettings(pane) }
                    .buttonStyle(.plain).preferenceControl()
                    .accessibilityLabel("Manage \(pane.title) in System Settings")
            } else {
                Button(pane == .microphone && session.permissions.requestingMicrophone ? "Waiting…" : "Allow…", action: allow)
                    .buttonStyle(.plain).preferenceControl()
                    .accessibilityLabel("Allow \(pane.title)")
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private var updateSettings: some View {
        if let updates = session.updates {
            row("Check for updates automatically") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }
                )).labelsHidden().toggleStyle(StudioToggleStyle()).disabled(!updates.available)
            }
            row("Software updates", subtitle: updates.status ?? (session.busyForUpdate
                ? "Available after the current task finishes." : nil)) {
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
        [("auto", "Auto-detect"), ("en", "English"), ("fr", "French"), ("uk", "Ukrainian"), ("ru", "Russian"), ("es", "Spanish"), ("de", "German")]
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionHeader(title: title).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.line))
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
    private func chooseAudioFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { session.settings.audioDirectory = url.path }
    }
    private func chooseSkillsFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.showsHiddenFiles = true
        panel.directoryURL = skillsFolder
        panel.message = "Choose the skills folder your coding agent reads, such as ~/.claude/skills."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.settings.skillsFolder = url.standardizedFileURL == AgentSkillInstaller.claudeCodeFolder.standardizedFileURL ? "" : url.path
    }
    private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    /// Only what this page shows, so switching to it stays quick.
    private func refresh() {
        switch page {
        case .general:
            session.permissions.refresh()
            session.refreshInput()
            Task { loginStatus = await Task.detached { SMAppService.mainApp.status }.value }
            refreshSkills()
        case .shortcuts: session.modifierShortcut.refresh()
        case .model: break
        }
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

extension View {
    @ViewBuilder func preferenceControl() -> some View {
        let control = font(.system(size: 13)).foregroundStyle(StudioStyle.accent)
            .padding(.horizontal, 11).frame(minHeight: 32)
        if #available(macOS 26, *) {
            control.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 7))
        } else {
            control
                .background(StudioStyle.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StudioStyle.line))
        }
    }
    func preferenceMenu() -> some View {
        menuStyle(.borderlessButton).fixedSize().preferenceControl()
    }
}

private enum SkillConfirmation {
    case remove(AgentSkill), replace(AgentSkill)

    var title: String {
        switch self {
        case .remove(let skill): "Remove the \(skill.name) skill?"
        case .replace(let skill): "Replace the \(skill.name) skill?"
        }
    }

    var message: String {
        switch self {
        case .remove: "Coding agents will no longer know how to use it. Its folder is moved to the Trash."
        case .replace: "The installed skill differs from this app’s version. Any edits to it will be lost."
        }
    }
}
