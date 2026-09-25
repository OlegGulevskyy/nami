import ApplicationServices
import CoreGraphics
import Testing
@testable import NamiStudio

@MainActor private final class PasteEnvironment {
    var allowed = true
    var target: TranscriptPaster.Target? = .init(pid: 42, element: AXUIElementCreateApplication(42))
    var flags: CGEventFlags = []
    var sentTo: [pid_t] = []
    var canPost = true

    func paster() -> TranscriptPaster {
        TranscriptPaster(accessibilityGranted: { self.allowed }, focusedTarget: { self.target },
                         modifiers: { self.flags }, postPaste: {
            self.sentTo.append($0)
            return self.canPost
        })
    }
}

@Test @MainActor func pastesOnlyToTheCapturedAppAndField() {
    let environment = PasteEnvironment()
    let paste = environment.paster().prepare()
    #expect(environment.sentTo.isEmpty)
    #expect(paste() == .sent)
    #expect(environment.sentTo == [42])
}

@Test @MainActor func appOrFieldChangesPreventPaste() {
    let environment = PasteEnvironment()
    let paste = environment.paster().prepare()
    environment.target = .init(pid: 43, element: AXUIElementCreateApplication(43))
    #expect(paste() == .targetChanged)
    environment.target = .init(pid: 42, element: AXUIElementCreateSystemWide())
    #expect(paste() == .targetChanged)
    environment.target = .init(pid: 42, element: nil)
    #expect(paste() == .targetChanged)
    environment.target = nil
    #expect(paste() == .targetChanged)
    #expect(environment.sentTo.isEmpty)
}

@Test @MainActor func editorsWithoutAccessibilityElementsStillGetBestEffortPaste() {
    let environment = PasteEnvironment()
    environment.target = .init(pid: 42, element: nil)
    let paste = environment.paster().prepare()
    #expect(paste() == .sent)
    environment.target = .init(pid: 43, element: nil)
    #expect(paste() == .targetChanged)
    #expect(environment.sentTo == [42])
}

@Test @MainActor func missingOrRevokedAccessibilityNeverPostsKeys() {
    let environment = PasteEnvironment()
    let previouslyAllowed = environment.paster().prepare()
    environment.allowed = false
    #expect(previouslyAllowed() == .accessibilityRequired)
    let denied = environment.paster().prepare()
    #expect(denied() == .accessibilityRequired)
    environment.allowed = true
    #expect(denied() == .accessibilityRequired)
    #expect(environment.sentTo.isEmpty)
}

@Test @MainActor func missingInitialTargetDoesNotPasteIntoALaterApp() {
    let environment = PasteEnvironment()
    environment.target = nil
    let paste = environment.paster().prepare()
    environment.target = .init(pid: 42, element: nil)
    #expect(paste() == .targetUnavailable)
    #expect(environment.sentTo.isEmpty)
}

@Test @MainActor func heldModifiersPreventAlteredPasteShortcuts() {
    let environment = PasteEnvironment()
    let paste = environment.paster().prepare()
    for flag: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn] {
        environment.flags = flag
        #expect(paste() == .modifiersPressed)
    }
    #expect(environment.sentTo.isEmpty)
    environment.flags = .maskAlphaShift // Caps Lock does not alter ⌘V.
    #expect(paste() == .sent)
}

@Test @MainActor func eventFailureIsReportedForManualRecovery() {
    let environment = PasteEnvironment()
    environment.canPost = false
    #expect(environment.paster().prepare()() == .failed)
}
