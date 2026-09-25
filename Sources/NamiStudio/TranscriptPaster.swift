import AppKit
import ApplicationServices
import CoreGraphics

public enum TranscriptPasteResult: Equatable, Sendable {
    /// macOS accepts events asynchronously; the receiving app may still reject Paste.
    case sent, accessibilityRequired, targetUnavailable, targetChanged, modifiersPressed, failed

    var status: String {
        switch self {
        case .sent: "Paste sent to your text field. Transcript also copied."
        case .accessibilityRequired: "Transcript copied. Allow Accessibility in Permissions to paste automatically."
        case .targetUnavailable: "Transcript copied. Focus a text field in another app before recording to paste automatically."
        case .targetChanged: "Transcript copied. The focused field changed; paste it where you need it."
        case .modifiersPressed: "Transcript copied. Keys were held down; paste it with ⌘V."
        case .failed: "Transcript copied. Automatic paste could not start; paste it with ⌘V."
        }
    }
}

public typealias PreparedTranscriptPaste = @MainActor () -> TranscriptPasteResult

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

    init(accessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
         focusedTarget: @escaping () -> Target? = { currentTarget() },
         modifiers: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
         postPaste: @escaping (pid_t) -> Bool = { sendPaste(to: $0) }) {
        self.accessibilityGranted = accessibilityGranted
        self.focusedTarget = focusedTarget
        self.modifiers = modifiers
        self.postPaste = postPaste
    }

    func prepare() -> PreparedTranscriptPaste {
        guard accessibilityGranted() else { return { .accessibilityRequired } }
        guard let target = focusedTarget() else { return { .targetUnavailable } }
        return { [self] in
            guard accessibilityGranted() else { return .accessibilityRequired }
            guard focusedTarget() == target else { return .targetChanged }
            let heldKeys: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
            guard modifiers().intersection(heldKeys).isEmpty else { return .modifiersPressed }
            return postPaste(target.pid) ? .sent : .failed
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
