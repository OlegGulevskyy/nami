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

@MainActor private final class PinEnvironment {
    var allowed = true
    let field = AXUIElementCreateApplication(42)
    lazy var target: TranscriptPaster.Target? = .init(pid: 42, element: field)
    var accepting = true
    var running = true
    var exposed = 0
    var exposes = true
    var inserted: [String] = []
    var pasted = 0
    var onRetry: () -> Void = {}
    var windowField: AXUIElement?
    var writeResult: TranscriptInsertResult = .inserted
    var typed: [String] = []
    var focusable = true

    func paster() -> TranscriptPaster {
        TranscriptPaster(accessibilityGranted: { self.allowed }, focusedTarget: { self.target },
                         modifiers: { [] }, postPaste: { _ in self.pasted += 1; return true },
                         exposeAccessibility: { _ in self.exposed += 1; return self.exposes },
                         acceptsText: { element in
                             defer { self.onRetry() }
                             return self.accepting && CFEqual(element, self.field)
                         },
                         insertText: { text, _ in
                             if self.writeResult == .inserted { self.inserted.append(text) }
                             return self.writeResult
                         },
                         appName: { _ in self.running ? "T3 Code" : nil },
                         searchFocusedField: { _ in self.windowField },
                         characterCount: { _ in nil },
                         typeText: { text, _ in self.typed.append(text); return true },
                         focusField: { _ in self.focusable })
    }

    func pinned() async -> PinnedTranscriptDestination? {
        guard case .pinned(let destination) = await paster().pin(retryDelay: .zero) else { return nil }
        return destination
    }
}

@Test @MainActor func pinnedNativeFieldReceivesTextWithoutKeystrokes() async throws {
    let environment = PinEnvironment()
    environment.exposes = false
    let destination = try #require(await environment.pinned())
    #expect(destination.appName == "T3 Code")
    // The user moves on to another app; delivery still targets the pinned field.
    environment.target = .init(pid: 7, element: AXUIElementCreateApplication(7))
    #expect(await destination.insert("Hello there") == .inserted)
    #expect(environment.inserted == ["Hello there"] && environment.typed.isEmpty && environment.pasted == 0)
}

@Test @MainActor func pinnedChromiumFieldIsTypedIntoOnlyWhileFocused() async throws {
    let environment = PinEnvironment()
    let destination = try #require(await environment.pinned())
    // Lexical accepts an Accessibility write and drops it, so it is never tried.
    #expect(await destination.insert("Hello\nthere") == .inserted)
    #expect(environment.typed == ["Hello there"] && environment.inserted.isEmpty && environment.pasted == 0)
    environment.focusable = false
    #expect(await destination.insert("Stray letters") == .targetUnavailable)
    #expect(environment.typed.count == 1)
}

@Test @MainActor func pinWaitsForElectronToExposeItsFields() async throws {
    let environment = PinEnvironment()
    environment.accepting = false
    var checks = 0
    environment.onRetry = { checks += 1; if checks == 2 { environment.accepting = true } }
    #expect(await environment.pinned() != nil)
    #expect(environment.exposed == 1 && checks == 3)
}

@Test @MainActor func pinFindsTheFocusedFieldInTheWindowWhenTheAppReportsNone() async throws {
    let environment = PinEnvironment()
    environment.target = .init(pid: 42, element: nil)
    #expect(await environment.pinned() == nil)
    environment.windowField = environment.field
    let destination = try #require(await environment.pinned())
    #expect(await destination.insert("Hello") == .inserted && environment.typed == ["Hello"])
}

@Test @MainActor func pinFailsForUnwritableFieldsAndFocusChanges() async {
    let environment = PinEnvironment()
    environment.accepting = false
    #expect(await environment.pinned() == nil)
    environment.exposes = false
    var checks = 0
    environment.onRetry = { checks += 1 }
    #expect(await environment.pinned() == nil)
    #expect(checks == 1) // Native apps are not polled.
    environment.exposes = true
    environment.onRetry = { environment.target = .init(pid: 43, element: environment.field) }
    guard case .failed(let message) = await environment.paster().pin(retryDelay: .zero) else {
        Issue.record("A focus change must not pin another app"); return
    }
    #expect(message.contains("Focus changed"))
}

@Test @MainActor func pinRequiresAccessibilityAndAFocusedField() async {
    let environment = PinEnvironment()
    environment.allowed = false
    #expect(await environment.pinned() == nil)
    environment.allowed = true
    environment.target = nil
    #expect(await environment.pinned() == nil)
    #expect(environment.exposed == 0)
}

@Test @MainActor func pinnedDeliveryStopsWhenTheAppQuitsOrAccessibilityIsRevoked() async throws {
    let environment = PinEnvironment()
    let destination = try #require(await environment.pinned())
    environment.running = false
    #expect(await destination.insert("text") == .targetUnavailable)
    environment.running = true
    environment.allowed = false
    #expect(await destination.insert("text") == .accessibilityRequired)
    #expect(environment.inserted.isEmpty && environment.pasted == 0)
}

@Test @MainActor func refusedAccessibilityWritesAreTypedWithoutReturnOrTab() async throws {
    let environment = PinEnvironment()
    environment.exposes = false
    let destination = try #require(await environment.pinned())
    environment.writeResult = .rejected
    #expect(await destination.insert("First line\nSecond\tpart") == .inserted)
    #expect(environment.typed == ["First line Second part"] && environment.pasted == 0)
    // An accepted write is never typed again, even if its length is not reported.
    environment.writeResult = .inserted
    #expect(await destination.insert("Once") == .inserted)
    #expect(environment.typed.count == 1 && environment.inserted == ["Once"])
    environment.writeResult = .targetUnavailable
    #expect(await destination.insert("Gone") == .targetUnavailable)
    #expect(environment.typed.count == 1)
}
