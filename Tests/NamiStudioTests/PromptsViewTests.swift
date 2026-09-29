import AppKit
import SwiftUI
import Testing
import NamiCore
import NamiAudio
@testable import NamiStudio

@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_PROMPTS_SNAPSHOT_DIR"] != nil))
@MainActor func promptsRenderPreview() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NAMI_PROMPTS_SNAPSHOT_DIR"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let studio = StudioSession(project: directory, historyDirectory: directory.appendingPathComponent("History"),
        permissions: StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
            requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false }),
        pastePreparer: { { _, _ in .targetUnavailable } },
        captureBuilder: { _ in PromptPreviewCapture() }, clipboardWriter: { _ in true })
    studio.debugging.page = .prompts
    studio.debugging.promptStore.record(.init(requestID: UUID(), source: "Live dictation", provider: "Qwen 0.6B", messages: [
        .init(role: "system", content: PromptField.qwenSystem.defaultText),
        .init(role: "user", content: "Edit this transcript only:\n\"please check the deployment\"\nReturn the corrected sentence as plain text."),
    ], details: "Thinking disabled · temperature 0 · maximum 2,048 output tokens"))
    for (destination, history, size) in [
        (PromptDestination.qwen, false, NSSize(width: 760, height: 900)),
        (.qwen, false, NSSize(width: 1300, height: 1000)),
        (.apple, false, NSSize(width: 1100, height: 950)),
        (.whisper, false, NSSize(width: 1100, height: 900)),
        (.elevenLabs, false, NSSize(width: 1100, height: 900)),
        (.qwen, true, NSSize(width: 1100, height: 900)),
        (.qwen, false, NSSize(width: 1100, height: 920)),
    ] {
        let view = NSHostingView(rootView: PromptsView(studio: studio, store: studio.debugging.promptStore, destination: destination, showingHistory: history)
            .frame(width: size.width, height: size.height).background(StudioStyle.paper)
            .environment(\.colorScheme, .light))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if size.height == 920 {
            func editors(in view: NSView) -> [NSTextView] {
                (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors(in: $0) }
            }
            let editor = try #require(editors(in: view).first { $0.string == PromptField.qwenSystem.defaultText })
            let newPrompt = "Fix punctuation only. Keep the speaker’s exact wording."
            editor.string = newPrompt
            editor.didChangeText()
            await Task.yield()
            #expect(studio.debugging.promptStore.draftConfiguration[.qwenSystem] == newPrompt)
            #expect(studio.debugging.promptStore.configuration[.qwenSystem] == PromptField.qwenSystem.defaultText)
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("prompts-\(destination.rawValue)-\(history ? "history" : "editor")-\(Int(size.width))-\(Int(size.height)).png"))
    }
}

@MainActor private final class PromptPreviewCapture: AudioCapturing {
    let inputDescription = "Preview"
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> { throw EngineError.noAudio }
    func stop() {}
}
