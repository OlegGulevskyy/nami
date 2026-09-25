import AppKit
import CoreGraphics
import Observation

/// Owns a passive event tap. It never consumes events or reads typed characters.
@MainActor @Observable
public final class ModifierRecordingShortcut {
    public var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "modifierRecordingShortcutEnabled")
            refresh()
        }
    }
    public private(set) var isListening = false
    public private(set) var message = "Allow Input Monitoring to use ⌥⌘ taps in any app."
    @ObservationIgnored private weak var session: StudioSession?
    @ObservationIgnored private var resources: TapResources?
    @ObservationIgnored private var gesture = ModifierTapGesture()

    public init() {
        enabled = UserDefaults.standard.object(forKey: "modifierRecordingShortcutEnabled") as? Bool ?? true
    }

    func install(for session: StudioSession) {
        self.session = session
        refresh()
    }

    public func refresh() {
        gesture.reset()
        guard session != nil else { return }
        RecordingShortcuts.setStandardShortcutsEnabled(!enabled)
        guard enabled else {
            resources = nil
            isListening = false
            return
        }
        guard CGPreflightListenEventAccess() else {
            resources = nil
            isListening = false
            message = "Allow Input Monitoring to use ⌥⌘ taps in any app."
            return
        }
        if let resources {
            CGEvent.tapEnable(tap: resources.tap, enable: true)
            isListening = CGEvent.tapIsEnabled(tap: resources.tap)
            message = isListening ? "Ready in any app while Nami is running." : "Quit and reopen Nami to enable ⌥⌘ taps."
            return
        }
        let events: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap's source is installed exclusively on the main run loop.
            MainActor.assumeIsolated {
                let monitor = Unmanaged<ModifierRecordingShortcut>.fromOpaque(context).takeUnretainedValue()
                monitor.receive(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            isListening = false
            message = "Could not listen for ⌥⌘ taps. Check Input Monitoring, then quit and reopen Nami."
            return
        }
        resources = TapResources(tap: tap, source: source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = CGEvent.tapIsEnabled(tap: tap)
        message = isListening ? "Ready in any app while Nami is running." : "Quit and reopen Nami to enable ⌥⌘ taps."
    }

    public func requestPermission() {
        _ = CGRequestListenEventAccess()
        refresh()
        if !isListening, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gesture.reset()
            if let resources { CGEvent.tapEnable(tap: resources.tap, enable: true) }
            return
        }
        guard enabled, let session else { gesture.reset(); return }
        handle(type: type, flags: event.flags, time: Double(event.timestamp) / 1_000_000_000, session: session)
    }

    // Event interpretation is separate from OS permissions so the actual routing
    // into recording, transcription and copying can be tested without a microphone.
    func handle(type: CGEventType, flags: CGEventFlags, time: Double, session: StudioSession) {
        switch gesture.handle(type: type, flags: flags, time: time,
                              phase: session.phase) {
        case .start: session.startRecording()
        case .stop: session.stopRecording()
        case nil: break
        }
    }
}

private final class TapResources {
    let tap: CFMachPort
    let source: CFRunLoopSource

    init(tap: CFMachPort, source: CFRunLoopSource) { self.tap = tap; self.source = source }

    deinit {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
}
