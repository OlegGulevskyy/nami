import AppKit
import Observation
import SwiftUI

/// Owned by the app, independently of the studio window and its focus.
@MainActor public final class RecordingIndicatorController {
    private let session: StudioSession
    private(set) var panel: NSPanel?

    public init(session: StudioSession) {
        self.session = session
        observePhase()
    }

    private func observePhase() {
        let phase = withObservationTracking {
            session.phase
        } onChange: { [weak self] in
            // Observation fires before the write. Read the committed phase on
            // the next main-actor turn, then subscribe for the next transition.
            Task { @MainActor [weak self] in self?.observePhase() }
        }
        if phase.busy { show() }
        else { panel?.orderOut(nil) }
    }

    private func show() {
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
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: SessionRecordingIndicator(session: session))
            self.panel = panel
        }
        guard let panel, !panel.isVisible else { return }
        // Use the pointer's display for this run; visibleFrame clears the Dock.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen { panel.setFrameOrigin(Self.origin(in: screen.visibleFrame)) }
        panel.orderFrontRegardless()
    }

    static func origin(in visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: visibleFrame.midX - RecordingIndicatorView.windowSize.width / 2,
                y: visibleFrame.minY + 16)
    }
}

private final class RecordingIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SessionRecordingIndicator: View {
    var session: StudioSession
    var body: some View {
        RecordingIndicatorView(phase: session.phase, levels: session.meterHistory, elapsed: session.elapsed)
    }
}

/// Also used by the developer snapshot command without opening the microphone.
public struct RecordingIndicatorView: View {
    public static let windowSize = NSSize(width: 272, height: 72)
    let phase: StudioPhase
    let levels: [Double]
    let elapsed: Double

    public init(phase: StudioPhase, levels: [Double] = [], elapsed: Double = 0) {
        self.phase = phase
        self.levels = levels
        self.elapsed = elapsed
    }

    public var body: some View {
        HStack(spacing: 12) {
            if phase == .recording {
                Circle().fill(StudioStyle.selection).frame(width: 6, height: 6)
                Text("Listening").font(.system(size: 13, weight: .medium))
                StudioWaveform(levels: levels, color: StudioStyle.selection)
                    .frame(width: 66, height: 26).accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(StudioStyle.selection)
            } else {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text(status).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "waveform").foregroundStyle(StudioStyle.selection)
            }
        }
        .foregroundStyle(StudioStyle.paper)
        .padding(.horizontal, 18)
        .frame(width: 256, height: 52)
        .background(StudioStyle.ink, in: Capsule())
        .overlay(Capsule().strokeBorder(StudioStyle.selection.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase == .recording ? "Nami is recording" : "Nami: \(status)")
    }

    private var status: String {
        switch phase {
        case .preparing: "Getting ready…"
        case .cancelling: "Cancelling…"
        default: "Transcribing…"
        }
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
