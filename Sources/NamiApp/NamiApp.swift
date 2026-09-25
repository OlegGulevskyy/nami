import AppKit
import NamiStudio
import SwiftUI

@main
struct NamiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session: StudioSession
    @State private var recordingIndicator: RecordingIndicatorController?
    @State private var showingSettings = false

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
        }
        var clipboardWriter: (@MainActor (String) -> Bool)?
        if args.contains("--snapshot") { clipboardWriter = { _ in true } }
        let session = StudioSession(project: project, clipboardWriter: clipboardWriter)
        _session = State(initialValue: session)
        // Visual checks must not register shortcuts or change the user's clipboard.
        if !args.contains("--snapshot") {
            _recordingIndicator = State(initialValue: RecordingIndicatorController(session: session))
            RecordingShortcuts.install(for: session)
        }
    }

    var body: some Scene {
        Window("Nami · Recording history", id: "studio") {
            StudioView(session: session, showingSettings: $showingSettings)
                .onDisappear { session.cancel(); session.stopPlayback() }
                .task { await runVisualCheckIfRequested() }
        }
        .defaultSize(width: 1080, height: 850)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { showingSettings = true }
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
            try render(to: output.appendingPathComponent("idle.png"))
            try render(to: output.appendingPathComponent("shortcuts.png"), shortcuts: true)
            for phase in [StudioPhase.preparing, .recording, .processing] {
                let levels = (0..<20).map { 0.15 + abs(sin(Double($0) * 0.65)) * 0.75 }
                try renderView(AnyView(RecordingIndicatorView(phase: phase, levels: levels, elapsed: 12)),
                               size: RecordingIndicatorView.windowSize,
                               to: output.appendingPathComponent("indicator-\(phase.rawValue).png"))
            }
            try render(to: output.appendingPathComponent("local-model.png"), settingsPage: .model)
            try render(to: output.appendingPathComponent("about.png"), settingsPage: .about)
            if let frame = NSApplication.shared.windows.first(where: { $0.title.contains("Recording history") })?.contentView?.superview {
                try cacheView(frame, to: output.appendingPathComponent("window.png"))
            }
            #if DEBUG
            if args.contains("--design-preview") {
                session.loadDesignPreviewHistory()
                try render(to: output.appendingPathComponent("history.png"))
                try render(to: output.appendingPathComponent("history-compact.png"), size: NSSize(width: 760, height: 600))
                try render(to: output.appendingPathComponent("settings-compact.png"), shortcuts: true, size: NSSize(width: 800, height: 720))
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
        let content = isSettings
            ? AnyView(StudioSettingsView(session: session, page: settingsPage ?? .general, onBack: {}))
            : AnyView(StudioView(session: session, showingSettings: .constant(false)))
        try renderView(content, size: size, to: url)
    }

    @MainActor private func renderView(_ content: AnyView, size: NSSize, to url: URL) throws {
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
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
