import AppKit
import Testing
@testable import NamiStudio

@MainActor struct StudioSidebarTests {
    @Test func sidebarListsMainPagesFirstAndKeepsSettingsSectionsInTabs() {
        typealias Page = StudioView.Page
        #expect(Page.primary == [.history, .snippets, .actions])
        #expect(Page.secondary == [.debugging, .settings])
        // Every page is reachable from the sidebar or the Settings tabs.
        #expect(Set(Page.primary + Page.secondary + Page.settingsTabs) == Set(Page.allCases))
        #expect(Page.settingsTabs.allSatisfy { $0.settingsPage != nil && $0.sidebarPage == .settings })
        #expect((Page.primary + [.debugging]).map(\.shortcutKey) == Array("1234"))
        #expect(Page.settingsTabs.allSatisfy { $0.shortcutKey == nil })
        #expect(Page.settings.shortcutLabel == "⌘,")
        for page in Page.allCases {
            #expect(NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test func dragRemainsAnchoredWhenSidebarSnapsClosedAndReopens() throws {
        let handle = StudioSidebarResizeHandle.HandleView()
        handle.width = 224
        var proposedWidth = 224.0
        var finished = false
        handle.onResize = { proposedWidth = $0 }
        handle.onEnd = { finished = true }

        handle.mouseDown(with: try event(.leftMouseDown, x: 224))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 100))
        #expect(proposedWidth < StudioSidebarLayout.collapseThreshold)

        // SwiftUI updates the handle's width and position while a drag is active.
        handle.width = StudioSidebarLayout.collapsedWidth
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 260))
        #expect(proposedWidth == 260)
        handle.mouseUp(with: try event(.leftMouseUp, x: 260))
        #expect(finished)

        handle.width = StudioSidebarLayout.collapsedWidth
        handle.mouseDown(with: try event(.leftMouseDown, x: StudioSidebarLayout.collapsedWidth))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 224))
        #expect(proposedWidth == 224)
        #expect(!handle.mouseDownCanMoveWindow)
    }

    @Test func resizingPreservesSpaceForContentAndReadableNavigation() {
        for windowWidth in [760.0, 880, 1080, 1440] {
            for proposed in [-200.0, 64, 140, 224, 320, 2000, .infinity, .nan] {
                let width = StudioSidebarLayout.expandedWidth(proposed, availableWidth: windowWidth)
                #expect(width >= StudioSidebarLayout.minimumWidth)
                #expect(width <= StudioSidebarLayout.maximumWidth)
                #expect(windowWidth - width >= 560)
            }
        }
    }

    private func event(_ type: NSEvent.EventType, x: Double) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100),
                                      modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
