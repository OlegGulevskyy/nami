import AppKit
import Testing
@testable import NamiStudio

@MainActor struct StudioSidebarTests {
    @Test func everyDestinationHasASequentialShortcutInSidebarOrder() {
        let pages = StudioView.Page.allCases
        #expect(pages.map(\.shortcutKey) == Array("123456"))
        #expect(pages[1] == .debugging)
        #expect(pages.last == .about)
        for page in pages {
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
        handle.mouseDown(with: try event(.leftMouseDown, x: 64))
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
