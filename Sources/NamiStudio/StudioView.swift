import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

public struct StudioView: View {
    @Bindable var session: StudioSession
    @Binding private var showingSettings: Bool
    @State private var searchVisible = false
    @State private var query = ""
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
    @FocusState private var searchFocused: Bool

    public init(session: StudioSession, showingSettings: Binding<Bool>) {
        self.session = session
        _showingSettings = showingSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showingSettings {
                StudioSettingsView(session: session, onBack: { showingSettings = false })
            } else {
                recordingHistory
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshInput()
            session.modifierShortcut.refresh()
            shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        }
        .onExitCommand {
            if showingSettings { showingSettings = false }
            else if searchVisible { query = ""; searchVisible = false }
            else { session.cancel() }
        }
    }

    private var recordingHistory: some View {
        VStack(spacing: 0) {
            header
            StudioStyle.divider
            VStack(alignment: .leading, spacing: 0) {
                introduction.padding(.top, 38).padding(.bottom, 32)
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
                history.frame(maxHeight: .infinity)
                if session.modifierShortcut.enabled && !session.modifierShortcut.isListening {
                    shortcutPermissionNotice.padding(.top, 16)
                }
                recordingBar.padding(.top, 22)
                footer.padding(.top, 14).padding(.bottom, 24)
            }
            .padding(.horizontal, 54)
        }
        .font(.system(size: 16)).foregroundStyle(StudioStyle.ink)
        .background(StudioStyle.paper).tint(StudioStyle.green)
        .frame(minWidth: 760, minHeight: 600).preferredColorScheme(.light)
        .background(StudioWindowChrome()).ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        HStack(spacing: 20) {
            Text("nami").font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.6)
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(StudioStyle.green.opacity(0.75)).frame(width: 6, height: 6)
                Text(session.settings.engine == "fake" ? "Demo mode" : "On-device")
                    .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
            }
            Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(StudioIconButton()).help("Settings (⌘,)").accessibilityLabel("Open settings")
        }
        .padding(.leading, 118).padding(.trailing, 28).frame(height: 72)
    }

    private var introduction: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Your words, kept here.")
                    .font(.system(size: 34, weight: .medium)).tracking(-0.6)
                Text("A thought, a message, a little less typing.")
                    .font(.system(size: 16)).foregroundStyle(StudioStyle.quiet)
            }
            Spacer(minLength: 20)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { searchVisible.toggle() }
                searchFocused = searchVisible
                if !searchVisible { query = "" }
            } label: { Image(systemName: searchVisible ? "xmark" : "magnifyingglass") }
            .buttonStyle(StudioIconButton()).keyboardShortcut("f", modifiers: .command)
            .help(searchVisible ? "Close search" : "Search transcripts (⌘F)")
            .accessibilityLabel(searchVisible ? "Close search" : "Search transcripts")
        }
    }

    private var filteredRuns: [RecordingRun] {
        session.runs.filter { query.isEmpty || $0.transcript.localizedStandardContains(query) }
    }
    private var groupedRuns: [(date: Date, runs: [RecordingRun])] {
        Dictionary(grouping: filteredRuns) { Calendar.current.startOfDay(for: $0.date) }
            .map { (date: $0.key, runs: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            if searchVisible {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudioStyle.quiet)
                    TextField("Search your words…", text: $query)
                        .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search transcripts")
                    if !query.isEmpty {
                        Text("\(filteredRuns.count) results").font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    }
                }
                .padding(13).background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 9))
            }
            if filteredRuns.isEmpty {
                emptyHistory.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedRuns, id: \.date) { group in
                            Text(dayLabel(group.date)).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(StudioStyle.quiet)
                                .padding(.top, 5).padding(.bottom, 13)
                            ForEach(group.runs) { run in RecordingHistoryRow(session: session, run: run) }
                        }
                    }
                }.scrollIndicators(.automatic)
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
        HStack(spacing: 16) {
            Button(action: session.toggleRecording) {
                ZStack {
                    Circle().fill(StudioStyle.green)
                    if session.phase.busy && session.phase != .recording {
                        ProgressView().controlSize(.small).tint(.white).colorScheme(.dark)
                    } else {
                        Image(systemName: session.phase == .recording ? "stop.fill" : "mic")
                            .font(.system(size: 21, weight: .medium)).foregroundStyle(.white)
                    }
                }.frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).disabled(session.phase.busy && session.phase != .recording)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(session.phase == .recording ? "Stop and transcribe" : "Start recording")
            .help(session.phase == .recording ? "Stop and transcribe" : "Start recording (⌘R)")
            VStack(alignment: .leading, spacing: 5) {
                Text(recordingTitle).font(.system(size: 16, weight: .medium))
                Text(recordingSubtitle).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if session.phase == .recording {
                waveform.frame(width: 80, height: 28)
                Text(String(format: "%02d:%02d", Int(session.elapsed) / 60, Int(session.elapsed) % 60))
                    .font(.system(size: 17, design: .monospaced)).monospacedDigit()
                    .accessibilityLabel("\(Int(session.elapsed)) seconds recorded")
            }
            if session.phase.busy {
                Button("Cancel", action: session.cancel)
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                    .disabled(session.phase == .cancelling)
            } else {
                Button { showingSettings = true } label: {
                    HStack(spacing: 5) {
                        if session.modifierShortcut.enabled {
                            StudioKeycap(text: "⌥ ⌘")
                            StudioKeycap(text: "× 2")
                        } else { StudioKeycap(text: shortcut?.description ?? "Set shortcut") }
                    }
                }.buttonStyle(.plain).help("Change recording shortcut").accessibilityLabel("Change recording shortcut")
            }
        }
        .foregroundStyle(StudioStyle.green).padding(.horizontal, 21).padding(.vertical, 18)
        .background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 15))
    }

    private var recordingTitle: String {
        switch session.phase {
        case .idle: "Ready when you are"
        case .recording: "Listening to you"
        case .preparing: "Getting ready"
        case .processing: "Finding your words"
        case .cancelling: "Cancelling recording"
        case .failed: "Let’s try that again"
        }
    }
    private var recordingSubtitle: String {
        switch session.phase {
        case .idle, .failed:
            session.runs.isEmpty ? "Press your shortcut or click to record" : session.status
        case .recording: "Press your shortcut or click stop to finish"
        default: session.status
        }
    }
    private var waveform: some View {
        StudioWaveform(levels: session.meterHistory)
            .accessibilityLabel("Microphone level \(Int(session.level * 100)) percent")
    }
    private var footer: some View {
        HStack {
            Label("Private by design. Transcribed on your Mac.", systemImage: "lock")
            Spacer()
            Button(action: importAudio) { Label("Import audio", systemImage: "doc") }
                .buttonStyle(.plain).disabled(session.phase.busy).keyboardShortcut("o", modifiers: .command)
        }.font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
    }
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.month(.wide).day().year()).uppercased()
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
        panel.message = "Transcribe a recording up to 60 seconds long."
        if panel.runModal() == .OK, let url = panel.url { session.transcribeFile(url) }
    }
}

private struct RecordingHistoryRow: View {
    @Bindable var session: StudioSession
    let run: RecordingRun
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(run.date.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text("\(Int(run.audioSeconds.rounded())) sec")
                if run.engine == "fake" { Text("·  Demo").foregroundStyle(.orange) }
                Spacer()
                if session.playing && session.selectedRunID == run.id || hovered {
                    Button {
                        if session.selectedRunID != run.id { session.stopPlayback(); session.selectedRunID = run.id }
                        session.togglePlayback()
                    } label: {
                        Image(systemName: session.playing && session.selectedRunID == run.id ? "stop.circle" : "play.circle")
                    }
                    .buttonStyle(.plain).disabled(session.phase.busy)
                    .accessibilityLabel(session.playing && session.selectedRunID == run.id ? "Stop playback" : "Listen to recording")
                    .help("Listen to recording")
                }
                Button {
                    if session.selectedRunID != run.id { session.stopPlayback() }
                    session.selectedRunID = run.id
                    copied = session.copyTranscript()
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .disabled(run.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(copied ? "Copied" : "Copy transcript")
                    .accessibilityLabel(copied ? "Transcript copied" : "Copy transcript")
            }.font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
            Text(run.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No speech recognized." : run.transcript)
                .font(.system(size: 17)).lineSpacing(6).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
            StudioStyle.divider
        }
        .padding(.top, 12).padding(.bottom, 3)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .contextMenu {
            Button("Copy transcript") {
                if session.selectedRunID != run.id { session.stopPlayback() }
                session.selectedRunID = run.id; copied = session.copyTranscript()
            }
            Button("Listen to recording") {
                session.stopPlayback(); session.selectedRunID = run.id; session.togglePlayback()
            }.disabled(session.phase.busy)
            if let url = run.savedURL {
                Button("Show audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}
