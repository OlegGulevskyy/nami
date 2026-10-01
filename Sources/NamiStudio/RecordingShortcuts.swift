import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", initial: .init(.space, modifiers: [.control, .option]))
    static let startRecording = Self("startRecording")
    static let stopRecording = Self("stopRecording")
    static let pinDestination = Self("pinDestination", initial: .init(.p, modifiers: [.control, .option]))
    /// Registered only while the indicator offers cancel, so Escape keeps working everywhere else.
    static let cancelRecording = Self("cancelRecording", initial: .init(.escape))
}

@MainActor public enum RecordingShortcuts {
    static let names: [KeyboardShortcuts.Name] = [.toggleRecording, .startRecording, .stopRecording]
    // Stays active with ⌥⌘ taps, which only replace the recording shortcuts above.
    static let assignable = names + [.pinDestination]

    public static func install(for session: StudioSession) {
        // One release per press avoids toggling repeatedly when a key is held.
        for name in assignable { KeyboardShortcuts.removeHandler(for: name) }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak session] in session?.toggleRecording() }
        KeyboardShortcuts.onKeyUp(for: .startRecording) { [weak session] in session?.startRecording() }
        KeyboardShortcuts.onKeyUp(for: .stopRecording) { [weak session] in session?.stopRecording() }
        KeyboardShortcuts.onKeyUp(for: .pinDestination) { [weak session] in session?.togglePinnedDestination() }
        KeyboardShortcuts.removeHandler(for: .cancelRecording)
        KeyboardShortcuts.disable(.cancelRecording)
        KeyboardShortcuts.onKeyUp(for: .cancelRecording) { [weak session] in
            if session?.phase.cancellableFromIndicator == true { session?.cancel() }
        }
        session.modifierShortcut.install(for: session)
        observeCancelShortcut(for: session)
    }

    private static func observeCancelShortcut(for session: StudioSession) {
        let cancellable = withObservationTracking { session.phase.cancellableFromIndicator } onChange: { [weak session] in
            // Observation fires before the write; read the committed phase next turn.
            Task { @MainActor [weak session] in if let session { observeCancelShortcut(for: session) } }
        }
        if cancellable { KeyboardShortcuts.enable(.cancelRecording) }
        else { KeyboardShortcuts.disable(.cancelRecording) }
    }

    static func setStandardShortcutsEnabled(_ enabled: Bool) {
        if enabled { KeyboardShortcuts.enable(names) }
        else { KeyboardShortcuts.disable(names) }
    }
}
