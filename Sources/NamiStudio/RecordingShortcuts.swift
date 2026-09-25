import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", initial: .init(.space, modifiers: [.control, .option]))
    static let startRecording = Self("startRecording")
    static let stopRecording = Self("stopRecording")
}

@MainActor public enum RecordingShortcuts {
    static let names: [KeyboardShortcuts.Name] = [.toggleRecording, .startRecording, .stopRecording]

    public static func install(for session: StudioSession) {
        // One release per press avoids toggling repeatedly when a key is held.
        for name in names { KeyboardShortcuts.removeHandler(for: name) }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak session] in session?.toggleRecording() }
        KeyboardShortcuts.onKeyUp(for: .startRecording) { [weak session] in session?.startRecording() }
        KeyboardShortcuts.onKeyUp(for: .stopRecording) { [weak session] in session?.stopRecording() }
        session.modifierShortcut.install(for: session)
    }

    static func setStandardShortcutsEnabled(_ enabled: Bool) {
        if enabled { KeyboardShortcuts.enable(names) }
        else { KeyboardShortcuts.disable(names) }
    }
}

public struct RecordingShortcutSettings: View {
    @Bindable private var session: StudioSession
    @Bindable private var modifierShortcut: ModifierRecordingShortcut

    public init(session: StudioSession) {
        self.session = session
        self.modifierShortcut = session.modifierShortcut
    }

    public var body: some View {
        Form {
            Section("Option + Command taps") {
                Toggle("Use ⌥⌘ taps", isOn: $modifierShortcut.enabled)
                LabeledContent("Start recording", value: "⌥⌘ twice")
                LabeledContent("Stop & transcribe", value: "⌥⌘ once")
                Text("Press and release both keys together twice quickly to start (within half a second). While recording, press and release them once to stop. No letter or Space key needed.")
                    .font(.callout).foregroundStyle(.secondary)
                if session.modifierShortcut.enabled {
                    Label(session.modifierShortcut.message,
                          systemImage: session.modifierShortcut.isListening ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.callout)
                    if !session.modifierShortcut.isListening {
                        Button("Allow Input Monitoring…", action: session.modifierShortcut.requestPermission)
                        Text("Enable Nami in System Settings → Privacy & Security → Input Monitoring. If it is already enabled, switch it off and back on, then quit and reopen Nami.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !modifierShortcut.enabled {
                Section {
                    recorder("Start / stop recording", name: .toggleRecording)
                    recorder("Start recording", name: .startRecording)
                    recorder("Stop & transcribe", name: .stopRecording)
                } header: {
                    Text("Regular key shortcuts")
                } footer: {
                    Text("Click a field and press modifiers plus a regular key. These fields cannot record modifier-only taps.")
                }
            }
            Section {
                Toggle("Stop automatically", isOn: $session.settings.timed)
                Text(session.settings.timed
                     ? "Recording stops after \(Int(session.settings.duration)) seconds. You can also stop earlier with a shortcut."
                     : "Stop when you're done using your shortcut. Recordings have a 60-second safety limit.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Recording starts as soon as the microphone opens, even while the model warms up. Start and stop normally while it loads. Shortcuts are ignored while the microphone opens or a transcript is processing.")
                    .font(.callout).foregroundStyle(.secondary)
                Label(session.settings.copyWhenFinished
                      ? (session.settings.pasteWhenFinished
                         ? "Recordings are copied and pasted into the focused app. Allow Accessibility in General settings."
                         : "Finished transcripts are copied automatically.")
                      : "Automatic copying and pasting are off. Copy transcripts from your history.", systemImage: "doc.on.clipboard")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 570, height: 640)
        .disabled(session.phase.busy)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.modifierShortcut.refresh()
        }
    }

    private func recorder(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        KeyboardShortcuts.Recorder(LocalizedStringKey(title), name: name)
            .shortcutValidation { shortcut in
                if RecordingShortcuts.names.contains(where: { $0 != name && KeyboardShortcuts.getShortcut(for: $0) == shortcut }) {
                    return .disallow(reason: "This shortcut is already assigned to another recording action. Choose different keys, or clear the other shortcut first.")
                }
                return .allow
            }
    }
}
