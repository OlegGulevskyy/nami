import CoreGraphics

/// Recognizes complete, modifier-only taps. No key characters are inspected.
struct ModifierTapGesture {
    enum Action: Equatable { case start, stop }
    static let chord: CGEventFlags = [.maskAlternate, .maskCommand]
    static let relevant: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn]
    private var firstTap: Double?
    private var pressedAt: Double?
    private var sawChord = false
    private var interrupted = false
    private var phase: StudioPhase?

    mutating func reset() { self = Self() }

    mutating func handle(type: CGEventType, flags: CGEventFlags, time: Double, phase: StudioPhase) -> Action? {
        if self.phase != phase {
            reset()
            self.phase = phase
        }
        guard phase == .idle || phase == .failed || phase == .recording else { return nil }
        guard type == .flagsChanged else {
            // A key or mouse click makes this an ordinary shortcut, not a tap.
            firstTap = nil
            interrupted = pressedAt != nil || !flags.intersection(Self.relevant).isEmpty
            return nil
        }
        let modifiers = flags.intersection(Self.relevant)
        if !modifiers.isEmpty {
            if pressedAt == nil { pressedAt = time }
            if !modifiers.subtracting(Self.chord).isEmpty {
                interrupted = true
                firstTap = nil
            }
            if modifiers == Self.chord { sawChord = true }
            return nil
        }

        let valid = sawChord && !interrupted && pressedAt.map { time - $0 <= 0.6 } == true
        pressedAt = nil
        sawChord = false
        interrupted = false
        guard valid else { firstTap = nil; return nil }
        if phase == .recording { firstTap = nil; return .stop }
        if let firstTap, time - firstTap <= 0.5 {
            self.firstTap = nil
            return .start
        }
        firstTap = time
        return nil
    }
}
