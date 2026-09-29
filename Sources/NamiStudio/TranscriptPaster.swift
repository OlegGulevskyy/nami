import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

public enum TranscriptPasteResult: Equatable, Sendable {
    /// macOS accepts events asynchronously; the receiving app may still reject Paste.
    case sent, accessibilityRequired, targetUnavailable, targetChanged, modifiersPressed, failed, clipboardRestoreFailed

    func status(copied: Bool) -> String {
        let recovery = copied ? "Transcript copied; paste it with ⌘V." : "Copy it from your history."
        switch self {
        case .sent: return "Paste sent to your text field. " + (copied ? "Transcript also copied." : "Clipboard preserved.")
        case .accessibilityRequired: return "Allow Accessibility in Permissions to paste automatically. " + recovery
        case .targetUnavailable: return "Focus a text field in another app before recording to paste automatically. " + recovery
        case .targetChanged: return "The focused field changed. " + recovery
        case .modifiersPressed: return "Keys were held down; automatic paste was skipped. " + recovery
        case .failed: return "Automatic paste could not start. " + recovery
        case .clipboardRestoreFailed: return "Your previous clipboard could not be restored. The transcript is in your history."
        }
    }
}

/// The final text and whether the clipboard must be preserved during delivery.
public typealias PreparedTranscriptPaste = @MainActor (_ text: String, _ preservingClipboard: Bool) async -> TranscriptPasteResult

public enum TranscriptInsertResult: Equatable, Sendable {
    case inserted, accessibilityRequired, targetUnavailable, rejected

    func status(app: String, copied: Bool) -> String {
        let fallback = copied ? "Transcript copied; paste it with ⌘V." : "Copy it from your history."
        switch self {
        case .inserted: return copied ? "Sent to \(app). Transcript also copied." : "Sent to \(app)."
        case .accessibilityRequired: return "Allow Accessibility in Permissions to send text to \(app). " + fallback
        case .targetUnavailable: return "The pinned field in \(app) is gone. " + fallback
        case .rejected: return "\(app) did not accept text in the background. " + fallback
        }
    }
}

/// A field chosen before the transcript exists. Delivery writes through
/// Accessibility, so the app stays in the background and keeps its window order.
public struct PinnedTranscriptDestination {
    public let appName: String
    let insert: @MainActor (String) async -> TranscriptInsertResult

    public init(appName: String, insert: @escaping @MainActor (String) async -> TranscriptInsertResult) {
        self.appName = appName
        self.insert = insert
    }
}

public enum TranscriptPinAttempt {
    case pinned(PinnedTranscriptDestination), failed(String)
}

/// Captures focus without activating an app or reading its text. Some editors do
/// not expose a focused AX element; in that case the foreground app is the guard.
@MainActor final class TranscriptPaster {
    struct Target: Equatable {
        let pid: pid_t
        let element: AXUIElement?

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.pid == rhs.pid else { return false }
            switch (lhs.element, rhs.element) {
            case (nil, nil): return true
            case let (left?, right?): return CFEqual(left, right)
            default: return false
            }
        }
    }

    private let accessibilityGranted: () -> Bool
    private let focusedTarget: () -> Target?
    private let modifiers: () -> CGEventFlags
    private let postPaste: (pid_t) -> Bool
    private let pasteboard: NSPasteboard
    private let waitForPaste: @MainActor () async -> Void
    private let exposeAccessibility: (pid_t) -> Bool
    private let acceptsText: (AXUIElement) -> Bool
    private let insertText: (String, AXUIElement) -> TranscriptInsertResult
    private let appName: (pid_t) -> String?
    private let searchFocusedField: (pid_t) -> AXUIElement?
    private let characterCount: (AXUIElement) -> Int?
    private let typeText: @MainActor (String, pid_t) async -> Bool
    private let focusField: @MainActor (AXUIElement) async -> Bool
    private static let log = Logger(subsystem: "local.nami.studio", category: "Paste")

    init(accessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
         focusedTarget: @escaping () -> Target? = { currentTarget() },
         modifiers: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
         postPaste: @escaping (pid_t) -> Bool = { sendPaste(to: $0) },
         pasteboard: NSPasteboard = .general,
         waitForPaste: @escaping @MainActor () async -> Void = {
             // Posted events are asynchronous. Cancellation must not shorten the
             // receiving app's opportunity to read the temporary clipboard.
             await Task { try? await Task.sleep(for: .milliseconds(500)) }.value
         },
         exposeAccessibility: @escaping (pid_t) -> Bool = { requestAccessibilityTree(of: $0) },
         acceptsText: @escaping (AXUIElement) -> Bool = { isTextInput($0) },
         insertText: @escaping (String, AXUIElement) -> TranscriptInsertResult = { replaceSelection(in: $1, with: $0) },
         appName: @escaping (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName },
         searchFocusedField: @escaping (pid_t) -> AXUIElement? = { focusedFieldInWindow(of: $0) },
         characterCount: @escaping (AXUIElement) -> Int? = { numberOfCharacters(in: $0) },
         typeText: @escaping @MainActor (String, pid_t) async -> Bool = { await type($0, to: $1) },
         focusField: @escaping @MainActor (AXUIElement) async -> Bool = { await focus($0) }) {
        self.accessibilityGranted = accessibilityGranted
        self.focusedTarget = focusedTarget
        self.modifiers = modifiers
        self.postPaste = postPaste
        self.pasteboard = pasteboard
        self.waitForPaste = waitForPaste
        self.exposeAccessibility = exposeAccessibility
        self.acceptsText = acceptsText
        self.insertText = insertText
        self.appName = appName
        self.searchFocusedField = searchFocusedField
        self.characterCount = characterCount
        self.typeText = typeText
        self.focusField = focusField
    }

    func prepare() -> PreparedTranscriptPaste {
        guard accessibilityGranted() else { return { _, _ in .accessibilityRequired } }
        guard let target = focusedTarget() else { return { _, _ in .targetUnavailable } }
        return { [self] text, preservingClipboard in
            guard !Task.isCancelled else { return .failed }
            guard accessibilityGranted() else { return .accessibilityRequired }
            guard focusedTarget() == target else { return .targetChanged }
            let heldKeys: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
            guard modifiers().intersection(heldKeys).isEmpty else { return .modifiersPressed }
            if preservingClipboard {
                return await pastePreservingClipboard(text, to: target)
            }
            return postPaste(target.pid) ? .sent : .failed
        }
    }

    private func pastePreservingClipboard(_ text: String, to target: Target) async -> TranscriptPasteResult {
        let initialChangeCount = pasteboard.changeCount
        var original: [NSPasteboardItem] = []
        let items = pasteboard.pasteboardItems ?? []
        guard !items.isEmpty || (pasteboard.types ?? []).isEmpty else { return .failed }
        // Materialize every representation before clearing the board; retaining
        // NSPasteboardItems alone loses lazily supplied data when ownership changes.
        for item in items {
            let saved = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), saved.setData(data, forType: type) else { return .failed }
            }
            original.append(saved)
        }
        guard pasteboard.changeCount == initialChangeCount, !Task.isCancelled else { return .failed }
        // Reading a lazy pasteboard provider can take time. Recheck the destination
        // before modifying the clipboard or sending any keys.
        guard accessibilityGranted() else { return .accessibilityRequired }
        guard focusedTarget() == target else { return .targetChanged }
        let heldKeys: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard modifiers().intersection(heldKeys).isEmpty else { return .modifiersPressed }

        let temporary = NSPasteboardItem()
        guard temporary.setString(text, forType: .string),
              temporary.setData(Data(), forType: .init("org.nspasteboard.TransientType")),
              temporary.setData(Data(), forType: .init("org.nspasteboard.AutoGeneratedType")) else { return .failed }
        pasteboard.clearContents()
        let written = pasteboard.writeObjects([temporary])
        let temporaryChangeCount = pasteboard.changeCount
        let sent = written && postPaste(target.pid)
        if sent { await waitForPaste() }
        // A user or another app may have copied while the paste was in flight.
        // Their newer clipboard always wins, including when this task is cancelled.
        if pasteboard.changeCount == temporaryChangeCount {
            pasteboard.clearContents()
            if !original.isEmpty, !pasteboard.writeObjects(original) { return .clipboardRestoreFailed }
        }
        return sent ? .sent : .failed
    }

    /// Pins the focused field of the frontmost app. Nothing is typed or activated,
    /// and the field's contents are never read.
    func pin(retryDelay: Duration = .milliseconds(200)) async -> TranscriptPinAttempt {
        guard accessibilityGranted() else { return .failed("Allow Accessibility in Permissions to pin a field.") }
        guard let first = focusedTarget() else { return .failed("Click into a text field in another app, then pin it.") }
        let name = appName(first.pid) ?? "This app"
        // Electron and Chromium build their tree only once asked, which takes a moment.
        let exposed = exposeAccessibility(first.pid)
        var target = first
        for attempt in 0..<(exposed ? 12 : 1) {
            if attempt > 0 {
                try? await Task.sleep(for: retryDelay)
                guard let next = focusedTarget(), next.pid == first.pid else {
                    return .failed("Focus changed before \(name) was pinned. Try again.")
                }
                target = next
            }
            // Electron may answer the app-wide focus query with no value even
            // though the field in its window reports itself as focused.
            let element = target.element.flatMap { acceptsText($0) ? $0 : nil }
                ?? searchFocusedField(first.pid).flatMap { acceptsText($0) ? $0 : nil }
            if let element {
                Self.log.notice("Pinned a \(Self.role(of: element), privacy: .public) in \(name, privacy: .public) after \(attempt + 1) checks; from app focus: \(target.element.map { CFEqual($0, element) } ?? false, privacy: .public)")
                let pid = target.pid
                return .pinned(PinnedTranscriptDestination(appName: name) { [self] text in
                    guard accessibilityGranted() else { return .accessibilityRequired }
                    guard appName(pid) != nil else { return .targetUnavailable }
                    let result = await deliver(text, to: element, pid: pid, chromium: exposed)
                    Self.log.notice("Pinned insert into \(name, privacy: .public): \(String(describing: result), privacy: .public)")
                    return result
                })
            }
        }
        Self.log.error("No writable focused field in \(name, privacy: .public); exposed tree: \(exposed, privacy: .public), app focus element: \(first.element != nil, privacy: .public)")
        return .failed("\(name) does not let Nami write into this field in the background.")
    }

    /// Only the field's length is read, to confirm the text arrived.
    /// Only the field's length is read, for the log.
    private func deliver(_ text: String, to element: AXUIElement, pid: pid_t, chromium: Bool) async -> TranscriptInsertResult {
        if chromium {
            // Chromium editors such as Lexical report an Accessibility write as done,
            // then drop it. Keystrokes addressed to the app's process reach the field
            // while the app stays in the background.
            return await type(text, into: element, pid: pid)
        }
        _ = await focusField(element)
        let written = insertText(text, element)
        Self.log.notice("Accessibility write: \(String(describing: written), privacy: .public), role \(Self.role(of: element), privacy: .public)")
        guard written == .rejected else { return written }
        return await type(text, into: element, pid: pid)
    }

    private func type(_ text: String, into element: AXUIElement, pid: pid_t) async -> TranscriptInsertResult {
        // Letters typed outside the field could trigger an app's single-key shortcuts.
        guard await focusField(element) else {
            Self.log.error("Pinned field could not be focused; nothing typed")
            return .targetUnavailable
        }
        let before = characterCount(element)
        guard await typeText(Self.typeable(text), pid) else { return .rejected }
        Self.log.notice("Typed into the pinned \(Self.role(of: element), privacy: .public); length \(before ?? -1, privacy: .public) -> \(self.characterCount(element) ?? -1, privacy: .public)")
        return .inserted
    }

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String ?? "unknown"
    }

    /// Line breaks and tabs would press Return or Tab, which sends chat messages
    /// or moves focus, so they are typed as spaces.
    static func typeable(_ text: String) -> String {
        String(text.map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }

    /// Focuses the field inside its own window. This does not activate the app.
    private static func focus(_ element: AXUIElement) async -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.5)
        func focused() -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) == .success
                && value as? Bool == true
        }
        if focused() { return true }
        let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        log.notice("Pinned field had lost focus; refocus result \(result.rawValue, privacy: .public)")
        // Chromium applies focus in its renderer, a moment after the call returns.
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(50))
            if focused() { return true }
        }
        return false
    }

    private static func numberOfCharacters(in element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success
        else { return nil }
        return value as? Int
    }

    /// Unicode key events sent to one process only; no Return, Tab or modifiers.
    private static func type(_ text: String, to pid: pid_t) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        for character in text {
            var units = Array(String(character).utf16)
            guard units.count <= 20 else { continue }
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return false }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event.postToPid(pid)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private static func requestAccessibilityTree(of pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    /// Bounded search of the app's front window for the focused text input.
    private static func focusedFieldInWindow(of pid: pid_t) -> AXUIElement? {
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let window = value(application, kAXFocusedWindowAttribute) ?? value(application, kAXMainWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var pending = [window as! AXUIElement], visited = 0
        while let element = pending.popLast(), visited < 3000 {
            visited += 1
            // Chromium also marks the web area around the field as focused.
            if value(element, kAXFocusedAttribute) as? Bool == true, isTextInput(element) {
                return value(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole ? nil : element
            }
            pending += (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed()
        }
        return nil
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        // Chromium can accept replacement text without advertising it as settable.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role as? String ?? "")
    }

    private static func replaceSelection(in element: AXUIElement, with text: String) -> TranscriptInsertResult {
        AXUIElementSetMessagingTimeout(element, 0.5)
        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if error != .success { log.error("Accessibility write failed with \(error.rawValue, privacy: .public)") }
        switch error {
        case .success: return .inserted
        case .invalidUIElement: return .targetUnavailable
        case .apiDisabled: return .accessibilityRequired
        default: return .rejected
        }
    }

    private static func currentTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return Target(pid: app.processIdentifier, element: nil)
        }
        let element = value as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { return nil }
        return Target(pid: app.processIdentifier, element: element)
    }

    private static func sendPaste(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Address the captured process, so an app switch cannot redirect the
        // keystrokes to a different app. Only ⌘V is sent, never Return/Enter.
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
