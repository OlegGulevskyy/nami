import AppKit
import SwiftUI
import Testing
import NamiAudio
@testable import NamiStudio

@MainActor private final class Counter { var value = 0 }

@Test @MainActor func switchingPagesKeepsPagesBuiltAndRefreshesOnlyVisiblePage() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nami-pages-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputRefreshes = Counter()
    let session = StudioSession(project: directory, historyDirectory: directory.appendingPathComponent("History"),
        permissions: StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
            requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false }),
        pastePreparer: { { _, _ in .targetUnavailable } }, modelDirectory: directory.appendingPathComponent("Models"),
        captureBuilder: { _ in fatalError("Page switching must not open the microphone") },
        inputDevicesProvider: { inputRefreshes.value += 1; return [] },
        clipboardWriter: { _ in true })
    let size = NSSize(width: 1080, height: 850)
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = host
    func show(_ page: StudioView.Page) {
        host.rootView = AnyView(StudioView(session: session, page: .constant(page)))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }
    func vocabularyEditors(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { vocabularyEditors(in: $0) }
    }

    let startupRefreshes = inputRefreshes.value
    show(.settings)
    let editor = try #require(vocabularyEditors(in: host).first)
    #expect(inputRefreshes.value == startupRefreshes + 1)

    show(.history)
    // Hidden, not torn down, and not refreshed while hidden.
    #expect(vocabularyEditors(in: host).contains { $0 === editor })
    #expect(inputRefreshes.value == startupRefreshes + 1)

    show(.settings)
    // The same page comes back instead of a rebuilt one, and still refreshes what it shows.
    #expect(vocabularyEditors(in: host).first === editor)
    #expect(inputRefreshes.value == startupRefreshes + 2)
}
