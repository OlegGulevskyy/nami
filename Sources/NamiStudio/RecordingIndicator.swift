import AppKit
import NamiAudio
import Observation
import SwiftUI

/// Owned by the app, independently of the studio window and its focus.
@MainActor public final class RecordingIndicatorController {
    private let session: StudioSession
    private(set) var panel: NSPanel?
    private var size = RecordingIndicatorView.windowSize
    private var pointerTracking: Task<Void, Never>?

    public init(session: StudioSession) {
        self.session = session
        observeState()
    }

    private func observeState() {
        let (visible, interactive, size) = withObservationTracking {
            (session.phase.busy || session.pinnedDestination != nil || session.pinNotice != nil,
             session.phase.cancellableFromIndicator,
             RecordingIndicatorView.size(phase: session.phase, microphoneChoices: session.microphoneChoiceCount))
        } onChange: { [weak self] in
            // Observation fires before the write. Read the committed state on
            // the next main-actor turn, then subscribe for the next transition.
            Task { @MainActor [weak self] in self?.observeState() }
        }
        self.size = size
        if visible { show(interactive: interactive) }
        else {
            pointerTracking?.cancel(); pointerTracking = nil
            panel?.orderOut(nil)
        }
    }

    private func show(interactive: Bool) {
        if panel == nil {
            let panel = RecordingIndicatorPanel(
                contentRect: NSRect(origin: .zero, size: RecordingIndicatorView.windowSize),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Nami recording status"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.canHide = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            let content = IndicatorHostingView(rootView: SessionRecordingIndicator(session: session))
            // The controller sizes the panel for each state; SwiftUI must not resize it.
            content.sizingOptions = []
            panel.contentView = content
            self.panel = panel
        }
        guard let panel else { return }
        // Only the close button and microphone choices take clicks; otherwise
        // the indicator never gets in the way of the app underneath.
        panel.ignoresMouseEvents = !interactive
        followPointer()
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
        // Polling needs no extra permission, unlike a global mouse monitor.
        pointerTracking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.followPointer()
            }
        }
    }

    /// Keeps the indicator on the display with the pointer; visibleFrame clears the Dock.
    private func followPointer() {
        let pointer = NSEvent.mouseLocation
        guard let panel, let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let frame = NSRect(origin: Self.origin(in: screen.visibleFrame, size: size), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    static func origin(in visibleFrame: NSRect, size: NSSize = RecordingIndicatorView.windowSize) -> NSPoint {
        NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 16)
    }
}

private final class RecordingIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel never becomes key, so clicks must act without a focusing click first.
private final class IndicatorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension StudioSession {
    var microphoneChoiceCount: Int { inputDevices.count + (offersSystemDefaultMicrophone ? 1 : 0) }
}

private struct SessionRecordingIndicator: View {
    var session: StudioSession
    var body: some View {
        RecordingIndicatorView(phase: session.phase, levels: session.meterHistory, elapsed: session.elapsed,
                               cleaning: session.isCleaningUp, pasting: session.isPasting, destination: session.pinnedDestination?.appName,
                               notice: session.pinNotice, waitingForMicrophone: session.awaitingMicrophone,
                               microphones: session.inputDevices,
                               selectedMicrophone: session.settings.microphoneUID,
                               offersSystemDefault: session.offersSystemDefaultMicrophone,
                               microphoneIssue: session.microphoneIssue,
                               onChooseMicrophone: { session.chooseMicrophone($0) }, onCancel: { session.cancel() })
    }
}

/// Also used by the developer snapshot command without opening the microphone.
public struct RecordingIndicatorView: View {
    public static let windowSize = NSSize(width: 316, height: 72)
    static let microphoneRowHeight: CGFloat = 26
    let phase: StudioPhase
    let levels: [Double]
    let elapsed: Double
    let cleaning: Bool
    let pasting: Bool
    let destination: String?
    let notice: String?
    let waitingForMicrophone: Bool
    let microphones: [AudioInputDevice]
    let selectedMicrophone: String?
    let offersSystemDefault: Bool
    let microphoneIssue: String?
    let onChooseMicrophone: (String?) -> Void
    let onCancel: () -> Void

    public init(phase: StudioPhase, levels: [Double] = [], elapsed: Double = 0, cleaning: Bool = false,
                pasting: Bool = false, destination: String? = nil, notice: String? = nil, waitingForMicrophone: Bool = false,
                microphones: [AudioInputDevice] = [], selectedMicrophone: String? = nil, offersSystemDefault: Bool = false,
                microphoneIssue: String? = nil, onChooseMicrophone: @escaping (String?) -> Void = { _ in },
                onCancel: @escaping () -> Void = {}) {
        self.phase = phase
        self.levels = levels
        self.elapsed = elapsed
        self.cleaning = cleaning
        self.pasting = pasting
        self.destination = destination
        self.notice = notice
        self.waitingForMicrophone = waitingForMicrophone
        self.microphones = microphones
        self.selectedMicrophone = selectedMicrophone
        self.offersSystemDefault = offersSystemDefault
        self.microphoneIssue = microphoneIssue
        self.onChooseMicrophone = onChooseMicrophone
        self.onCancel = onCancel
    }

    /// The microphone list grows with the choices, scrolling beyond five.
    public static func size(phase: StudioPhase, microphoneChoices: Int) -> NSSize {
        guard phase == .choosingMicrophone else { return windowSize }
        let rows = CGFloat(min(max(microphoneChoices, 1), 5))
        return NSSize(width: 316, height: 80 + rows * (microphoneRowHeight + 4))
    }

    public var body: some View {
        if phase == .choosingMicrophone { microphonePicker } else { capsule }
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) { capsuleContent }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(notice.map { "Nami: \($0)" }
                    ?? (phase == .recording && !waitingForMicrophone
                        ? "Nami is recording" + (destination.map { " for \($0)" } ?? "") : "Nami: \(status)"))
            if notice == nil && phase == .recording {
                closeButton(label: "Cancel recording")
            }
        }
        .foregroundStyle(StudioStyle.Indicator.foreground)
        .padding(.horizontal, 18)
        .frame(width: 300, height: 52)
        .background(StudioStyle.Indicator.background, in: Capsule())
        .overlay(Capsule().strokeBorder(StudioStyle.Indicator.accent.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var capsuleContent: some View {
        if let notice {
            Image(systemName: "pin").foregroundStyle(StudioStyle.Indicator.accent)
            Text(notice).font(.system(size: 12, weight: .medium)).lineLimit(2).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        } else if !phase.busy, let destination {
            Image(systemName: "pin.fill").foregroundStyle(StudioStyle.Indicator.accent)
            Text("Next transcript → \(destination)").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        } else if phase == .recording && !waitingForMicrophone {
            Circle().fill(StudioStyle.Indicator.accent).frame(width: 6, height: 6)
            if let destination {
                Label(destination, systemImage: "pin.fill").font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            } else {
                Text("Listening").font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            StudioWaveform(levels: levels, color: StudioStyle.Indicator.accent)
                .frame(width: 66, height: 26).accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                .foregroundStyle(StudioStyle.Indicator.accent).fixedSize()
        } else {
            ProgressView().controlSize(.small).colorScheme(.dark)
            Text(status).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            Image(systemName: "waveform").foregroundStyle(StudioStyle.Indicator.accent)
        }
    }

    private var microphonePicker: some View {
        let size = Self.size(phase: phase, microphoneChoices: microphones.count + (offersSystemDefault ? 1 : 0))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "mic.slash").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StudioStyle.Indicator.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a microphone").font(.system(size: 13, weight: .semibold))
                    Text(microphoneIssue ?? "Recording starts once you pick one.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.Indicator.accent.opacity(0.8))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                closeButton(label: "Cancel recording")
            }
            .frame(height: 36)
            if microphones.isEmpty {
                Text("No microphones found. Plug one in to continue.")
                    .font(.system(size: 12)).lineLimit(2).foregroundStyle(StudioStyle.Indicator.accent.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        if offersSystemDefault { microphoneRow("System default", uid: nil) }
                        ForEach(microphones) { microphoneRow($0.name, uid: $0.id) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .foregroundStyle(StudioStyle.Indicator.foreground)
        .padding(12)
        .frame(width: size.width - 16, height: size.height - 16)
        .background(StudioStyle.Indicator.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StudioStyle.Indicator.accent.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nami needs a microphone")
    }

    private func microphoneRow(_ name: String, uid: String?) -> some View {
        Button { onChooseMicrophone(uid) } label: {
            HStack(spacing: 8) {
                Image(systemName: uid == nil ? "mic" : "mic.fill").font(.system(size: 11))
                    .foregroundStyle(StudioStyle.Indicator.accent).frame(width: 14)
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if uid != nil && uid == selectedMicrophone {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioStyle.Indicator.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.microphoneRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(IndicatorRowButtonStyle())
        .accessibilityLabel("Record with \(name)")
    }

    private func closeButton(label: String) -> some View {
        Button(action: onCancel) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(StudioStyle.Indicator.foreground)
                .frame(width: 20, height: 20)
                .background(StudioStyle.Indicator.accent.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(label) (Esc)")
        .accessibilityLabel(label)
    }

    private var status: String {
        if !phase.busy, let destination { return "Next transcript goes to \(destination)" }
        if phase == .recording && waitingForMicrophone { return "Waiting for microphone…" }
        return switch phase {
        case .preparing: "Getting ready…"
        case .cancelling: "Cancelling…"
        default: pasting ? "Pasting…" : cleaning ? "Cleaning up…" : "Transcribing…"
        }
    }
}

private struct IndicatorRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(StudioStyle.Indicator.accent.opacity(configuration.isPressed ? 0.24 : 0.1),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The same live audio bars in the dashboard and floating indicator.
struct StudioWaveform: View {
    let levels: [Double]
    var color = StudioStyle.green.opacity(0.7)

    var body: some View {
        Canvas { context, size in
            let values = Array(levels.suffix(20))
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let height = max(3, min(1, max(0, value)) * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
    }
}
