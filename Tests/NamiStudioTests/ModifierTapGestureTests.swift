import CoreGraphics
import Testing
@testable import NamiStudio

private func tap(_ gesture: inout ModifierTapGesture, at time: Double, phase: StudioPhase = .idle,
                 first: CGEventFlags = .maskAlternate) -> ModifierTapGesture.Action? {
    #expect(gesture.handle(type: .flagsChanged, flags: first, time: time, phase: phase) == nil)
    #expect(gesture.handle(type: .flagsChanged, flags: ModifierTapGesture.chord, time: time + 0.02, phase: phase) == nil)
    #expect(gesture.handle(type: .flagsChanged, flags: first, time: time + 0.04, phase: phase) == nil)
    return gesture.handle(type: .flagsChanged, flags: [], time: time + 0.06, phase: phase)
}

@Test func doubleModifierTapStartsAndSingleTapStops() {
    var gesture = ModifierTapGesture()
    #expect(tap(&gesture, at: 0) == nil)
    #expect(tap(&gesture, at: 0.2, first: .maskCommand) == .start)
    #expect(tap(&gesture, at: 1, phase: .recording) == .stop)
}

@Test func modifierTapRejectsSlowPairsAndHeldKeys() {
    var gesture = ModifierTapGesture()
    #expect(tap(&gesture, at: 0) == nil)
    #expect(tap(&gesture, at: 1) == nil)
    #expect(tap(&gesture, at: 1.2) == .start)
    gesture.reset()
    #expect(gesture.handle(type: .flagsChanged, flags: ModifierTapGesture.chord, time: 2, phase: .recording) == nil)
    #expect(gesture.handle(type: .flagsChanged, flags: [], time: 3, phase: .recording) == nil)
}

@Test func ordinaryKeyboardAndMouseShortcutsDoNotTriggerRecording() {
    for type in [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
        var gesture = ModifierTapGesture()
        #expect(tap(&gesture, at: 0) == nil)
        #expect(gesture.handle(type: .flagsChanged, flags: ModifierTapGesture.chord, time: 0.2, phase: .idle) == nil)
        #expect(gesture.handle(type: type, flags: ModifierTapGesture.chord, time: 0.25, phase: .idle) == nil)
        #expect(gesture.handle(type: .flagsChanged, flags: [], time: 0.3, phase: .idle) == nil)
        #expect(tap(&gesture, at: 0.4) == nil)
    }
}

@Test func extraModifiersAndPartialReleasesDoNotCountAsTaps() {
    var gesture = ModifierTapGesture()
    #expect(gesture.handle(type: .flagsChanged, flags: [.maskCommand, .maskAlternate, .maskShift], time: 0, phase: .recording) == nil)
    #expect(gesture.handle(type: .flagsChanged, flags: ModifierTapGesture.chord, time: 0.02, phase: .recording) == nil)
    #expect(gesture.handle(type: .flagsChanged, flags: [], time: 0.04, phase: .recording) == nil)
    for index in 0..<4 {
        #expect(gesture.handle(type: .flagsChanged, flags: ModifierTapGesture.chord, time: Double(index) * 0.1, phase: .idle) == nil)
        #expect(gesture.handle(type: .flagsChanged, flags: .maskCommand, time: Double(index) * 0.1 + 0.05, phase: .idle) == nil)
    }
    #expect(gesture.handle(type: .flagsChanged, flags: [], time: 0.4, phase: .idle) == nil)
}

@Test func busyPhasesAndStateChangesDiscardPendingTaps() {
    var gesture = ModifierTapGesture()
    for phase in [StudioPhase.preparing, .processing, .cancelling] {
        #expect(tap(&gesture, at: 0, phase: phase) == nil)
        #expect(tap(&gesture, at: 0.2, phase: phase) == nil)
    }
    #expect(tap(&gesture, at: 1) == nil)
    #expect(tap(&gesture, at: 1.1, phase: .processing) == nil)
    #expect(tap(&gesture, at: 1.2) == nil)
    #expect(tap(&gesture, at: 1.4) == .start)
    gesture.reset()
    #expect(tap(&gesture, at: 2) == nil)
}

@Test func normalTypingDoesNotBlockNextDoubleTap() {
    var gesture = ModifierTapGesture()
    #expect(gesture.handle(type: .keyDown, flags: [], time: 0, phase: .idle) == nil)
    #expect(tap(&gesture, at: 0.1) == nil)
    #expect(tap(&gesture, at: 0.3) == .start)
}
