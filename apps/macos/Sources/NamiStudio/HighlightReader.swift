import AppKit
import ApplicationServices
import os

/// Selection access for a recording that watches for highlights.
public struct SelectionReading {
    /// Called when a recording starts watching; forgets the previous recording's selection.
    public var begin: @MainActor () -> Void
    public var read: @MainActor () async -> String?
    /// Called when the recording stops. The last selection stays readable.
    public var end: @MainActor () -> Void

    public init(begin: @escaping @MainActor () -> Void = {}, read: @escaping @MainActor () async -> String?,
                end: @escaping @MainActor () -> Void = {}) {
        self.begin = begin
        self.read = read
        self.end = end
    }

    public static var unavailable: Self { SelectionReading(read: { nil }) }
    /// Live access for the app only; tests must never pass this. In Google editors it copies.
    @MainActor public static func system() -> Self {
        let reader = HighlightReader()
        return SelectionReading(begin: { reader.begin() }, read: { await reader.read() }, end: { reader.end() })
    }
}

/// Reads the text selected in the frontmost app through Accessibility, which
/// never changes the app or the clipboard. Google Docs, Sheets and Slides draw
/// text on a canvas that Accessibility cannot see, so there a finished selection
/// is copied with ⌘C and the clipboard is restored straight after.
@MainActor final class HighlightReader {
    struct Window: Equatable, Sendable {
        let pid: pid_t
        let title: String
    }

    nonisolated private static let exposed = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    private static let log = Logger(subsystem: "local.nami.studio", category: "Highlights")
    private let pasteboard = NSPasteboard.general
    private var monitor: Any?
    private var debounce: Task<Void, Never>?
    private var copying = false
    private var copyAgain = false
    /// What the last ⌘C found in a Google editor window; nil text means nothing was selected.
    private var copied: (window: Window, text: String?)?

    func begin() {
        end()
        copied = nil
        guard AXIsProcessTrusted() else { return }
        // Global monitors only see events sent to other apps, and run on the main thread.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [weak self] event in
            let selecting = event.type == .leftMouseUp || Self.selectsText(event)
            MainActor.assumeIsolated { if selecting { self?.scheduleCopy() } }
        }
        // Text may already be highlighted when the recording starts.
        scheduleCopy(after: .zero)
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        debounce?.cancel(); debounce = nil
    }

    func read() async -> String? {
        guard AXIsProcessTrusted(), let pid = Self.frontmostPID() else { return nil }
        let found = await Task.detached { Self.inspect(pid) }.value
        if let text = found.selection, !text.isEmpty { return text }
        guard let window = found.window, let copied, copied.window == window else { return nil }
        return copied.text
    }

    private func scheduleCopy(after delay: Duration = .milliseconds(150)) {
        debounce?.cancel()
        // A double or triple click sends several mouse-ups; copy once they settle.
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard !self.copying else { self.copyAgain = true; return }
            self.copying = true
            defer { self.copying = false }
            repeat {
                self.copyAgain = false
                await self.copyFromGoogleEditor()
            } while self.copyAgain && self.monitor != nil
        }
    }

    private func copyFromGoogleEditor() async {
        guard let pid = Self.frontmostPID() else { return }
        guard let window = await Task.detached(operation: { Self.inspect(pid).window }).value,
              Self.isGoogleEditor(window.title) else { return }
        let text = await copySelection(from: pid)
        copied = (window, text)
        Self.log.notice("Copied a Google editor selection: \(text?.count ?? 0, privacy: .public) characters")
    }

    /// Returns nil when nothing was selected, because then the app copies nothing.
    private func copySelection(from pid: pid_t) async -> String? {
        let before = pasteboard.changeCount
        // Materialize every representation; lazily supplied data is lost once the app copies.
        var original: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let saved = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), saved.setData(data, forType: type) else { return nil }
            }
            original.append(saved)
        }
        guard pasteboard.changeCount == before, Self.sendCopy(to: pid) else { return nil }
        // Cancellation must not cut the wait short: the clipboard is always restored.
        func pause(_ milliseconds: Int) async { await Task { try? await Task.sleep(for: .milliseconds(milliseconds)) }.value }
        for _ in 0..<30 where pasteboard.changeCount == before { await pause(20) }
        guard pasteboard.changeCount != before else { return nil }
        await pause(30)
        let copiedCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        // Someone may have copied in the meantime; their newer clipboard wins.
        if pasteboard.changeCount == copiedCount {
            pasteboard.clearContents()
            if !original.isEmpty, !pasteboard.writeObjects(original) {
                Self.log.error("Could not restore the clipboard after copying a highlight")
            }
        }
        return text
    }

    private static func selectsText(_ event: NSEvent) -> Bool {
        // Shift with arrows, Home, End, Page Up or Page Down, and ⌘A.
        let navigation: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        let flags = event.modifierFlags
        return (flags.contains(.shift) && navigation.contains(event.keyCode)) || (flags.contains(.command) && event.keyCode == 0)
    }

    static func isGoogleEditor(_ title: String) -> Bool {
        ["Google Docs", "Google Sheets", "Google Slides"].contains { title.contains(" - " + $0) }
    }

    private static func frontmostPID() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return nil }
        return app.processIdentifier
    }

    /// ⌘C addressed to one process, like the paste, so an app switch cannot redirect it.
    private static func sendCopy(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// Accessibility calls block until the app answers, so they run off the main thread.
    nonisolated private static func inspect(_ pid: pid_t) -> (selection: String?, window: Window?) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        // Electron and Chromium build their tree only once asked.
        if exposed.withLock({ $0.insert(pid).inserted }) {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let window = element(application, kAXFocusedWindowAttribute)
            .map { Window(pid: pid, title: value($0, kAXTitleAttribute) as? String ?? "") }
        guard let focused = element(application, kAXFocusedUIElementAttribute) else { return (nil, window) }
        AXUIElementSetMessagingTimeout(focused, 0.15)
        guard value(focused, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return (nil, window) }
        if let text = value(focused, kAXSelectedTextAttribute) as? String, !text.isEmpty { return (text, window) }
        // Web pages in Safari and Chrome report selections as text marker ranges.
        guard let range = value(focused, "AXSelectedTextMarkerRange") else { return (nil, window) }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focused, "AXStringForTextMarkerRange" as CFString, range, &text) == .success
        else { return (nil, window) }
        return (text as? String, window)
    }

    nonisolated private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let found = value(parent, name), CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        return (found as! AXUIElement)
    }

    nonisolated private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
