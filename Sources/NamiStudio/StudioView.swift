import AppKit
import NamiCore
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

public struct StudioView: View {
    @Bindable var session: StudioSession
    public enum Page: String, CaseIterable {
        case history = "History", snippets = "Snippets", actions = "Actions", debugging = "Playground", settings = "Settings"
        case shortcuts = "Shortcuts", model = "Models", about = "About"

        var symbol: String {
            switch self {
            case .history: "clock.arrow.circlepath"
            case .settings: "slider.horizontal.3"
            case .shortcuts: "keyboard"
            case .model: "cpu"
            case .snippets: "curlybraces"
            case .actions: "bolt"
            case .about: "info.circle"
            case .debugging: "flask"
            }
        }

        /// Pressed with Command to switch pages from anywhere in the window.
        var shortcutKey: Character {
            switch self {
            case .history: "1"
            case .snippets: "2"
            case .actions: "3"
            case .debugging: "4"
            case .settings: "5"
            case .shortcuts: "6"
            case .model: "7"
            case .about: "8"
            }
        }

        var settingsPage: StudioSettingsView.Page? {
            switch self {
            case .history, .debugging, .snippets, .actions: nil
            case .settings: .general
            case .shortcuts: .shortcuts
            case .model: .model
            case .about: .about
            }
        }
    }

    @Binding private var page: Page
    @State private var searchVisible = false
    @State private var query = ""
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
    @AppStorage("studio.sidebar.width") private var savedSidebarWidth = StudioSidebarLayout.defaultWidth
    @AppStorage("studio.sidebar.collapsed") private var savedSidebarCollapsed = false
    @State private var draggedSidebarWidth: Double?
    @State private var resizingSidebar = false
    @FocusState private var searchFocused: Bool
    @State private var floatingBarHeight = 0.0
    @State private var builtPages: Set<Page> = []

    public init(session: StudioSession, page: Binding<Page>) {
        self.session = session
        _page = page
    }

    public var body: some View {
        GeometryReader { geometry in
            studio(availableWidth: geometry.size.width)
        }
        .frame(minWidth: 760, minHeight: 600)
        .onChange(of: session.settings.appearance, initial: true) { NSApp.appearance = session.settings.appearance.nsAppearance }
        .background(StudioWindowChrome()).ignoresSafeArea(.container, edges: .top)
    }

    private func studio(availableWidth: Double) -> some View {
        let sidebarWidth = sidebarCollapsed ? StudioSidebarLayout.collapsedWidth
            : StudioSidebarLayout.expandedWidth(draggedSidebarWidth ?? savedSidebarWidth, availableWidth: availableWidth)
        return HStack(spacing: 0) {
            sidebar.frame(width: sidebarWidth)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(StudioStyle.line).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    StudioSidebarResizeHandle(width: sidebarWidth, onResize: { width in
                        resizingSidebar = true
                        draggedSidebarWidth = width
                    }, onEnd: {
                        finishSidebarResize(availableWidth: availableWidth)
                    })
                    .frame(width: 8)
                    .background(resizingSidebar ? StudioStyle.green.opacity(0.12) : .clear)
                    .help("Drag to resize the sidebar. Drag left to collapse to icons.")
                    .accessibilityElement()
                    .accessibilityLabel("Sidebar width")
                    .accessibilityValue(sidebarCollapsed ? "Collapsed" : "\(Int(sidebarWidth)) points")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            if sidebarCollapsed { savedSidebarCollapsed = false }
                            else { savedSidebarWidth = StudioSidebarLayout.expandedWidth(sidebarWidth + 20, availableWidth: availableWidth) }
                        case .decrement:
                            if sidebarWidth <= StudioSidebarLayout.minimumWidth { savedSidebarCollapsed = true }
                            else { savedSidebarWidth = sidebarWidth - 20 }
                        @unknown default: break
                        }
                    }
                }
            VStack(spacing: 0) {
                header
                StudioStyle.divider
                // Pages stay built and are only hidden, so switching pages does
                // not rebuild and re-measure a whole page each time.
                ZStack {
                    ForEach(Page.allCases.filter { $0 == page || builtPages.contains($0) }, id: \.self) { item in
                        let visible = item == page
                        pageContent(item)
                            .opacity(visible ? 1 : 0)
                            .allowsHitTesting(visible)
                            .accessibilityHidden(!visible)
                            // Also turns off a hidden page's keyboard shortcuts and focus.
                            .disabled(!visible)
                            .environment(\.studioPageVisible, visible)
                            .zIndex(visible ? 1 : 0)
                    }
                }
                .onChange(of: page, initial: true) { builtPages.insert(page) }
                // A hidden page must not keep typing focus.
                .onChange(of: page) { NSApp.keyWindow?.makeFirstResponder(nil) }
                .task {
                    // Build the other pages one at a time while idle, so even a first visit is instant.
                    for item in Page.allCases {
                        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                        builtPages.insert(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 16)).foregroundStyle(StudioStyle.ink)
        .background(StudioStyle.paper).tint(StudioStyle.green)
        .task {
            recheckPermissions()
            // Keep the gate current even when System Settings stays in front.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let neededSetup = session.permissions.needsSetup
                session.refreshPermissions()
                session.refreshSnippetsIfChanged()
                session.refreshActionsIfChanged()
                if neededSetup && !session.permissions.needsSetup { session.modifierShortcut.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshInput()
            recheckPermissions()
            shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        }
        .onExitCommand {
            if page == .debugging && session.debugging.cleanupLab.isBusy { session.debugging.cleanupLab.cancel() }
            else if page == .debugging && session.debugging.isBusy { session.debugging.cancel() }
            else if page != .history { page = .history }
            else if searchVisible { query = ""; searchVisible = false }
            else { session.cancel() }
        }
    }

    @ViewBuilder private func pageContent(_ item: Page) -> some View {
        if item == .debugging {
            InternalDebuggingView(session: session, lab: session.debugging)
        } else if item == .snippets {
            SnippetsView(session: session)
        } else if item == .actions {
            ActionsView(session: session)
        } else if let settingsPage = item.settingsPage {
            StudioSettingsView(session: session, page: settingsPage)
        } else {
            recordingHistory
                .disabled(session.permissions.needsSetup)
                .allowsHitTesting(!session.permissions.needsSetup)
                .accessibilityHidden(session.permissions.needsSetup)
                .blur(radius: session.permissions.needsSetup ? 7 : 0)
                .overlay {
                    if session.permissions.needsSetup {
                        ZStack {
                            StudioStyle.paper.opacity(0.4).contentShape(Rectangle()).onTapGesture {}
                            PermissionSetupView(permissions: session.permissions, recheck: recheckPermissions)
                        }
                    }
                }
        }
    }

    private func recheckPermissions() {
        session.refreshPermissions()
        session.modifierShortcut.refresh()
    }

    private var recordingHistory: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = session.errorMessage { errorBanner(error).padding(.bottom, 18) }
            if let prompt = session.selectedPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("READING PROMPT · \(prompt.id.uppercased())")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.quiet)
                    Text(prompt.reference).font(.system(size: 16)).textSelection(.enabled)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 20)
            }
            // History scrolls beneath the floating glass bar.
            history.frame(maxHeight: .infinity)
                .contentMargins(.bottom, floatingBarHeight, for: .scrollContent)
        }
        .padding(.top, 24)
        .padding(.horizontal, 28)
        // An overlay, not a safe-area inset: an inset makes the timeline's scroll view demand its full height.
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if session.modifierShortcut.enabled && !session.modifierShortcut.isListening {
                    shortcutPermissionNotice
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .studioGlass(in: RoundedRectangle(cornerRadius: 12))
                }
                if session.settings.pasteWhenFinished && !session.permissions.accessibility {
                    HStack(spacing: 10) {
                        Text("Allow Accessibility to paste your recordings automatically.")
                        Spacer(minLength: 8)
                        Button("Allow Accessibility…", action: session.permissions.resolveAccessibility)
                            .buttonStyle(.plain).underline().disabled(session.phase.busy)
                    }
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.green)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .studioGlass(in: RoundedRectangle(cornerRadius: 12))
                }
                recordingBar
            }
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 18)
            .background(alignment: .bottom) {
                LinearGradient(colors: [StudioStyle.paper.opacity(0), StudioStyle.paper], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44).allowsHitTesting(false)
            }
            .onGeometryChange(for: Double.self) { $0.size.height } action: { floatingBarHeight = $0 }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    StudioLogo()
                        .foregroundStyle(StudioStyle.green)
                        .frame(width: 42, height: 32)
                        .padding(.leading, 12)
                    Spacer(minLength: 0)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { savedSidebarCollapsed.toggle() }
                } label: {
                    Image(systemName: sidebarCollapsed ? "chevron.right" : "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StudioStyle.quiet)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
                .accessibilityLabel(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            }
            .padding(.bottom, 14)
            ForEach(Page.allCases.filter { $0 != .about }, id: \.self) { navigationItem($0) }
            Spacer(minLength: 12)
            navigationItem(.about)
        }
        .padding(.horizontal, 12).padding(.top, 64).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioStyle.sidebar)
    }

    private var sidebarCollapsed: Bool {
        if let draggedSidebarWidth { return draggedSidebarWidth < StudioSidebarLayout.collapseThreshold }
        return savedSidebarCollapsed
    }

    private func finishSidebarResize(availableWidth: Double) {
        if let draggedSidebarWidth {
            savedSidebarCollapsed = sidebarCollapsed
            if !savedSidebarCollapsed {
                savedSidebarWidth = StudioSidebarLayout.expandedWidth(draggedSidebarWidth, availableWidth: availableWidth)
            }
        }
        draggedSidebarWidth = nil
        resizingSidebar = false
    }

    private func navigationItem(_ item: Page) -> some View {
        let iconOnly = sidebarCollapsed || item == .about
        return Button { page = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 16)).frame(width: 20)
                if !iconOnly {
                    Text(item.rawValue).font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: "⌘\(item.shortcutKey)").font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(StudioStyle.quiet.opacity(0.8))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(page == item ? StudioStyle.green : StudioStyle.quiet)
            .padding(.horizontal, iconOnly ? 0 : 12)
            .frame(maxWidth: item == .about ? nil : .infinity)
            .frame(width: item == .about ? (sidebarCollapsed ? 40 : 44) : nil, height: 40)
            .background(page == item ? StudioStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
        .accessibilityLabel(item.rawValue)
        .help("\(item.rawValue) (⌘\(String(item.shortcutKey)))")
        .keyboardShortcut(KeyEquivalent(item.shortcutKey), modifiers: .command)
    }

    private var header: some View {
        HStack(spacing: 20) {
            Text(page.rawValue).font(.system(size: 17, weight: .semibold))
            Spacer()
            if page == .history {
                HStack(spacing: 8) {
                    Circle().fill(StudioStyle.green.opacity(0.75)).frame(width: 6, height: 6)
                    Text(session.settings.engine == "fake" ? "Demo mode" : "On-device")
                        .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { searchVisible.toggle() }
                    searchFocused = searchVisible
                    if !searchVisible { query = "" }
                } label: { Image(systemName: searchVisible ? "xmark" : "magnifyingglass") }
                .buttonStyle(StudioIconButton()).studioGlass(in: Circle(), interactive: true, fallback: .clear)
                .keyboardShortcut("f", modifiers: .command)
                .help(searchVisible ? "Close search" : "Search transcripts (⌘F)")
                .accessibilityLabel(searchVisible ? "Close search" : "Search transcripts")
            }
        }
        .padding(.horizontal, 28).frame(height: 64)
    }

    /// Searches the entire history; the timeline pages only what it lays out.
    private var filteredRuns: [RecordingRun] {
        query.isEmpty ? session.runs : session.runs.filter { $0.transcript.localizedStandardContains(query) }
    }

    private var history: some View {
        let filteredRuns = filteredRuns
        return VStack(alignment: .leading, spacing: 18) {
            if searchVisible {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudioStyle.quiet)
                    TextField("Search your words…", text: $query)
                        .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search transcripts")
                    if !query.isEmpty {
                        Text("\(filteredRuns.count) results").font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    }
                }
                .padding(13).studioGlass(in: RoundedRectangle(cornerRadius: 9))
            }
            if filteredRuns.isEmpty {
                emptyHistory.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, floatingBarHeight)
            } else {
                RecordingHistoryTimeline(runs: filteredRuns) { run in
                    RecordingHistoryRow(session: session, run: run)
                }
                .id(query)
            }
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 13) {
            Image(systemName: query.isEmpty ? "text.alignleft" : "magnifyingglass")
                .font(.system(size: 30, weight: .light)).foregroundStyle(StudioStyle.quiet.opacity(0.7))
                .padding(.bottom, 4)
            Text(query.isEmpty ? "Your first thought goes here." : "No matching words.")
                .font(.system(size: 22, weight: .medium, design: .rounded))
            Text(query.isEmpty ? "Record something on your mind, or import an audio file."
                 : "Try another word or clear your search.")
                .font(.system(size: 14)).foregroundStyle(StudioStyle.quiet)
            if !query.isEmpty {
                Button("Clear search") { query = "" }.buttonStyle(.plain).foregroundStyle(StudioStyle.green)
            }
        }.multilineTextAlignment(.center).padding(24)
    }

    private var shortcutPermissionNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard recording needs Input Monitoring.").fontWeight(.medium)
                Text("If Nami is already enabled there, switch it off and back on, then quit and reopen Nami.")
                    .foregroundStyle(StudioStyle.quiet)
            }
            Spacer(minLength: 8)
            Button("Open Settings…", action: session.modifierShortcut.requestPermission)
                .buttonStyle(.plain).underline()
                .accessibilityLabel("Open Input Monitoring settings")
        }
        .font(.system(size: 12))
        .foregroundStyle(StudioStyle.green)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button(action: session.toggleRecording) {
                ZStack {
                    if session.phase.busy && session.phase != .recording {
                        ProgressView().controlSize(.small).tint(.white).colorScheme(.dark)
                    } else {
                        Image(systemName: session.phase == .recording ? "stop.fill" : "mic")
                            .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 36)
                .studioGlass(in: Circle(), tint: StudioStyle.greenFill, interactive: true)
                .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(session.phase.busy && session.phase != .recording)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(session.phase == .recording ? "Stop and transcribe" : "Start recording")
            .help(session.phase == .recording ? "Stop and transcribe" : "Start recording (⌘R)")
            Text(recordingTitle).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 12)
            if session.phase == .recording {
                waveform.frame(width: 80, height: 28)
                Text(String(format: "%02d:%02d", Int(session.elapsed) / 60, Int(session.elapsed) % 60))
                    .font(.system(size: 15, design: .monospaced)).monospacedDigit()
                    .accessibilityLabel("\(Int(session.elapsed)) seconds recorded")
            }
            if session.phase.busy {
                Button("Cancel", action: session.cancel)
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                    .disabled(session.phase == .cancelling)
            } else {
                Button { page = .shortcuts } label: {
                    HStack(spacing: 5) {
                        if session.modifierShortcut.enabled {
                            StudioKeycap(text: "⌥ ⌘")
                            StudioKeycap(text: "× 2")
                        } else { StudioKeycap(text: shortcut?.description ?? "Set shortcut") }
                    }
                }.buttonStyle(.plain).help("Change recording shortcut").accessibilityLabel("Change recording shortcut")
            }
            Button(action: importAudio) { Image(systemName: "doc.badge.plus") }
                .buttonStyle(StudioIconButton()).disabled(session.phase.busy)
                .keyboardShortcut("o", modifiers: .command)
                .help("Import audio (⌘O)").accessibilityLabel("Import audio")
        }
        .foregroundStyle(StudioStyle.green).padding(.horizontal, 14).padding(.vertical, 10)
        .studioGlass(in: RoundedRectangle(cornerRadius: 12))
    }

    private var recordingTitle: String {
        switch session.phase {
        case .idle: "Ready when you are"
        case .recording: session.awaitingMicrophone ? "Waiting for the microphone" : "Listening"
        case .preparing: "Getting ready"
        case .processing: "Finding your words"
        case .cancelling: "Cancelling recording"
        case .choosingMicrophone: "Choose a microphone"
        case .failed: "Let’s try that again"
        }
    }
    private var waveform: some View {
        StudioWaveform(levels: session.meterHistory)
            .accessibilityLabel("Microphone level \(Int(session.level * 100)) percent")
    }
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(message).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: session.dismissError) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }.foregroundStyle(StudioStyle.ink).padding(14)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Choose a recording to transcribe."
        if panel.runModal() == .OK, let url = panel.url { session.transcribeFile(url) }
    }
}

private struct RecordingHistoryRow: View {
    @Bindable var session: StudioSession
    let run: RecordingRun
    @State private var copied = false
    @State private var hovered = false
    @State private var confirmDelete = false
    @State private var showOriginal = false

    private var needsAttention: Bool { run.historyNotice?.needsAttention == true }

    @ViewBuilder private var transcriptionTime: some View {
        if let seconds = run.transcriptionSeconds {
            Text("Transcribed in \(Int(seconds * 1000)) ms")
                .help("Time from the end of the recording until the text was ready, before cleanup.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                HStack(spacing: 10) {
                    Text(run.date.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text("\(Int(run.audioSeconds.rounded())) sec")
                    if run.engine == "fake" { Text("·  Demo").foregroundStyle(.orange) }
                }
                historyActions
                Spacer(minLength: 0)
            }
            .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
            .frame(minHeight: 24)
            RecordingHistoryText(run: run, transcriptFont: session.settings.transcriptFont.font)
                .padding(.bottom, needsAttention ? 2 : 16)
            if let name = run.actionName {
                HStack(spacing: 12) {
                    Label("Action · \(name)", systemImage: StudioView.Page.actions.symbol)
                        .help("This recording ran the action instead of being pasted.")
                    transcriptionTime
                }.font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            } else if run.cleanupResult != nil || run.snippetName != nil {
                HStack(spacing: 12) {
                    transcriptionTime
                    if let name = run.snippetName {
                        Label("Snippet · \(name)", systemImage: StudioView.Page.snippets.symbol)
                            .help("Your words were replaced by this snippet. What you said is available below.")
                    } else if let result = run.cleanupResult {
                        Text("\(CleanupEngine.title(for: result.provider)) · \(Int(result.elapsedSeconds * 1000)) ms · \(result.succeeded ? "Cleanup applied" : "Original kept")")
                            .help(result.reason ?? "Original transcript is available below.")
                    }
                    Spacer()
                    Button(showOriginal ? "Hide original" : "Show original") { showOriginal.toggle() }
                    Button("Copy original") { _ = session.copyOriginalTranscript(run) }
                }.font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                if showOriginal {
                    Text(run.rawTranscript ?? run.transcript).font(.system(size: 15)).lineSpacing(5)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 8))
                }
            } else if run.transcriptionSeconds != nil {
                transcriptionTime.font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            }
            if !needsAttention { StudioStyle.divider }
        }
        .padding(.top, 12).padding(.bottom, needsAttention ? 14 : 3)
        .padding(.horizontal, needsAttention ? 14 : 0)
        .background(needsAttention ? RecordingHistoryNotice.background : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if needsAttention {
                RoundedRectangle(cornerRadius: 10).strokeBorder(RecordingHistoryNotice.border, lineWidth: 1)
            }
        }
        .padding(.bottom, needsAttention ? 10 : 0)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .contextMenu {
            Button("Copy transcript") {
                if session.selectedRunID != run.id { session.stopPlayback() }
                session.selectedRunID = run.id; copied = session.copyTranscript()
            }.disabled(!run.hasTranscript)
            Button("Listen to recording") {
                session.stopPlayback(); session.selectedRunID = run.id; session.togglePlayback()
            }.disabled(session.phase.busy)
            Button("Re-transcribe recording") { session.retranscribeRun(run.id) }
                .disabled(session.busyForUpdate)
            if let url = run.savedURL {
                Button("Show audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Delete recording…", role: .destructive) { confirmDelete = true }
                .disabled(session.retranscribingRunID == run.id)
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { session.deleteRun(run.id) }
        } message: {
            Text("The transcript and its audio will be removed from history. This can’t be undone.")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    private var historyActions: some View {
        HStack(spacing: 10) {
            if session.playing && session.selectedRunID == run.id || hovered || needsAttention {
                Button {
                    if session.selectedRunID != run.id { session.stopPlayback(); session.selectedRunID = run.id }
                    session.togglePlayback()
                } label: {
                    Image(systemName: session.playing && session.selectedRunID == run.id ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.plain).frame(width: 24, height: 24)
                .disabled(session.phase.busy)
                .accessibilityLabel(session.playing && session.selectedRunID == run.id ? "Stop playback" : "Listen to recording")
                .help(session.playing && session.selectedRunID == run.id ? "Stop" : "Play")
            }
            if session.retranscribingRunID == run.id {
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
                    .accessibilityLabel("Re-transcribing recording")
                    .help("Re-transcribing…")
            } else if hovered || confirmDelete {
                Button { session.retranscribeRun(run.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .disabled(session.busyForUpdate)
                    .accessibilityLabel("Re-transcribe recording")
                    .help("Re-transcribe")
            }
            if hovered || confirmDelete {
                Button {
                    if session.selectedRunID != run.id { session.stopPlayback() }
                    session.selectedRunID = run.id
                    copied = session.copyTranscript()
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .disabled(!run.hasTranscript)
                    .help(copied ? "Copied" : "Copy")
                    .accessibilityLabel(copied ? "Transcript copied" : "Copy transcript")

                Rectangle().fill(StudioStyle.line)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .disabled(session.retranscribingRunID == run.id)
                    .accessibilityLabel("Delete recording")
                    .help("Delete")
            }
        }
    }
}

extension EnvironmentValues {
    /// False while StudioView keeps a visited page built but hidden.
    @Entry var studioPageVisible = true
}

extension View {
    /// `onAppear`/`onDisappear` for page content StudioView keeps alive while hidden:
    /// also runs when the page is shown or hidden again.
    func onStudioPageVisibility(appear: @escaping () -> Void, disappear: @escaping () -> Void = {}) -> some View {
        modifier(StudioPageVisibility(appear: appear, disappear: disappear))
    }
}

private struct StudioPageVisibility: ViewModifier {
    let appear: () -> Void
    let disappear: () -> Void
    @Environment(\.studioPageVisible) private var visible

    func body(content: Content) -> some View {
        content
            .onAppear { if visible { appear() } }
            .onDisappear { if visible { disappear() } }
            .onChange(of: visible) { _, visible in visible ? appear() : disappear() }
    }
}
