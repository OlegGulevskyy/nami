import AppKit
import NamiStudio
import SwiftUI

@main
struct NamiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session: StudioSession
    @State private var recordingIndicator: RecordingIndicatorController?
    @State private var page: StudioView.Page = .history

    init() {
        let args = CommandLine.arguments
        var project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let index = args.firstIndex(of: "--project"), args.indices.contains(index + 1) {
            project = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else if let url = Bundle.main.url(forResource: "workspace", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let values = try? JSONDecoder().decode([String: String].self, from: data),
                  let path = values["project"] {
            project = URL(fileURLWithPath: path, isDirectory: true)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            // Distributed apps must never depend on the developer's checkout or
            // Finder's working directory. Keep writable settings outside the app.
            project = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Nami", isDirectory: true)
        }
        let snapshot = args.contains("--snapshot")
        let previewPermissions = args.contains("--snapshot")
            ? StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
                                accessibilityStatus: { false }, requestAccessibility: { false },
                                requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false })
            : nil
        // Screenshot fixtures must never enter the user's permanent history.
        let previewHistory = args.contains("--snapshot")
            ? FileManager.default.temporaryDirectory.appendingPathComponent("nami-preview-" + UUID().uuidString)
            : nil
        let session = StudioSession(project: project, historyDirectory: previewHistory,
                                    permissions: previewPermissions, pastePreparer: StudioSession.systemPastePreparer,
                                    destinationPinner: StudioSession.systemDestinationPinner,
                                    captureBuilder: StudioSession.systemCapture,
                                    clipboardWriter: { snapshot || StudioSession.systemClipboardWriter($0) })
        _session = State(initialValue: session)
        session.updates = AppUpdates(disabled: args.contains("--snapshot"), isBusy: { [weak session] in
            session?.busyForUpdate ?? false
        })
        // Visual checks must not register shortcuts or change the user's clipboard.
        if !args.contains("--snapshot") {
            _recordingIndicator = State(initialValue: RecordingIndicatorController(session: session))
            RecordingShortcuts.install(for: session)
            session.prepareForRecording()
        }
    }

    var body: some Scene {
        Window("Nami · Recording history", id: "studio") {
            StudioView(session: session, page: $page)
                .onDisappear { session.cancel(); session.stopPlayback(); session.debugging.cancel(); session.debugging.cleanupLabCancel(); session.debugging.stopPlayback() }
                .task { await runVisualCheckIfRequested() }
        }
        .defaultSize(width: 1080, height: 850)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { session.updates?.checkForUpdates() }
                    .disabled(session.updates?.canCheckForUpdates != true || session.busyForUpdate)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { page = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    /// Explicit developer-only visual check. Uses a provided audio file, never the
    /// microphone, and renders only our own view (not the user's desktop).
    @MainActor private func runVisualCheckIfRequested() async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) else { return }
        let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(300))
            if args.contains("--cleanup-check") {
                let result = try await session.debugging.prepareCleanupSnapshot()
                try result.write(to: output.appendingPathComponent("cleanup-result.json"))
                for size in [NSSize(width: 1080, height: 1050), NSSize(width: 760, height: 850)] {
                    try renderView(AnyView(StudioView(session: session, page: .constant(.debugging))),
                        size: size, to: output.appendingPathComponent("cleanup-\(Int(size.width)).png"))
                }
                NSApplication.shared.terminate(nil)
                return
            }
            try render(to: output.appendingPathComponent("idle.png"))
            try renderView(AnyView(StudioView(session: session, page: .constant(.debugging))),
                           size: NSSize(width: 1080, height: 850), to: output.appendingPathComponent("debugging-empty.png"))
            let permissionSession = StudioSession(project: session.project, historyDirectory: session.historyDirectory,
                permissions: StudioPermissions(microphoneStatus: { .notDetermined }, inputMonitoringStatus: { false },
                    accessibilityStatus: { false }, requestAccessibility: { false },
                    requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false }),
                pastePreparer: { { _, _ in .targetUnavailable } }, captureBuilder: StudioSession.systemCapture,
                clipboardWriter: { _ in true })
            try renderView(AnyView(StudioView(session: permissionSession, page: .constant(.history))),
                           size: NSSize(width: 760, height: 600), to: output.appendingPathComponent("permissions.png"))
            try render(to: output.appendingPathComponent("shortcuts.png"), shortcuts: true)
            try render(to: output.appendingPathComponent("shortcuts-compact.png"), shortcuts: true,
                       size: NSSize(width: 760, height: 600))
            try render(to: output.appendingPathComponent("shortcuts-full.png"), shortcuts: true,
                       size: NSSize(width: 1080, height: 1600))
            for phase in [StudioPhase.preparing, .recording, .processing] {
                let levels = (0..<20).map { 0.15 + abs(sin(Double($0) * 0.65)) * 0.75 }
                try renderView(AnyView(RecordingIndicatorView(phase: phase, levels: levels, elapsed: 12)),
                               size: RecordingIndicatorView.windowSize,
                               to: output.appendingPathComponent("indicator-\(phase.rawValue).png"))
            }
            try render(to: output.appendingPathComponent("local-model.png"), settingsPage: .model)
            try render(to: output.appendingPathComponent("about.png"), settingsPage: .about)
            try render(to: output.appendingPathComponent("settings.png"), settingsPage: .general)
            try render(to: output.appendingPathComponent("settings-compact.png"), settingsPage: .general,
                       size: NSSize(width: 760, height: 600))
            try renderView(AnyView(StudioView(session: permissionSession, page: .constant(.settings))),
                           size: NSSize(width: 1080, height: 2200), to: output.appendingPathComponent("settings-permissions-missing.png"))
            if let frame = NSApplication.shared.windows.first(where: { $0.title.contains("Recording history") })?.contentView?.superview {
                try cacheView(frame, to: output.appendingPathComponent("window.png"))
            }
            #if DEBUG
            if args.contains("--design-preview") {
                session.loadDesignPreviewHistory()
                session.debugging.loadDesignPreview()
                try renderView(AnyView(StudioView(session: session, page: .constant(.debugging))),
                               size: NSSize(width: 1080, height: 1000), to: output.appendingPathComponent("debugging.png"))
                try renderView(AnyView(StudioView(session: session, page: .constant(.debugging))),
                               size: NSSize(width: 760, height: 850), to: output.appendingPathComponent("debugging-compact.png"))
                try render(to: output.appendingPathComponent("history.png"))
                try render(to: output.appendingPathComponent("history-compact.png"), size: NSSize(width: 760, height: 600))
                try render(to: output.appendingPathComponent("settings-compact.png"), settingsPage: .general, size: NSSize(width: 800, height: 720))
                try render(to: output.appendingPathComponent("settings-wide.png"), settingsPage: .general,
                           size: NSSize(width: 1440, height: 1000))
                try render(to: output.appendingPathComponent("settings-full.png"), settingsPage: .general,
                           size: NSSize(width: 1080, height: 2400))
                session.loadDesignPreviewHistory(includeIssues: true)
                try render(to: output.appendingPathComponent("history-issues.png"), size: NSSize(width: 1080, height: 1200))
                try render(to: output.appendingPathComponent("history-issues-compact.png"), size: NSSize(width: 760, height: 850))
            }
            #endif
            if let fileIndex = args.firstIndex(of: "--audio"), args.indices.contains(fileIndex + 1) {
                let previousRunIDs = Set(session.runs.map(\.id))
                session.transcribeFile(URL(fileURLWithPath: args[fileIndex + 1]))
                let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                while session.phase.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
                guard session.phase == .idle, let run = session.runs.first, !previousRunIDs.contains(run.id) else {
                    throw NSError(domain: "NamiVisualCheck", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: session.errorMessage ?? "Transcription timed out"])
                }
                try render(to: output.appendingPathComponent("transcript.png"))
                let result: [String: Any] = ["transcript": run.transcript, "audioSeconds": run.audioSeconds,
                    "latencySeconds": run.latency, "modelLoaded": session.modelLoaded]
                try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
                    .write(to: output.appendingPathComponent("result.json"))
            }
            NSApplication.shared.terminate(nil)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("error.txt"))
            NSApplication.shared.terminate(nil)
        }
    }

    @MainActor private func render(to url: URL, shortcuts: Bool = false, settingsPage: StudioSettingsView.Page? = nil, size requestedSize: NSSize? = nil) throws {
        let isSettings = shortcuts || settingsPage != nil
        let size = requestedSize ?? (isSettings ? NSSize(width: 880, height: 830) : NSSize(width: 1080, height: 850))
        let selectedPage: StudioView.Page = switch settingsPage {
        case .general: .settings
        case .shortcuts: .shortcuts
        case .model: .model
        case .about: .about
        case nil: shortcuts ? .shortcuts : .history
        }
        let content = AnyView(StudioView(session: session, page: .constant(selectedPage)))
        try renderView(content, size: size, to: url)
    }

    @MainActor private func renderView(_ content: AnyView, size: NSSize, to url: URL) throws {
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        try cacheView(view, to: url)
    }

    @MainActor private func cacheView(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
