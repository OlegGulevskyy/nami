import AppKit
import SwiftUI

enum StudioSidebarLayout {
    static let defaultWidth = 224.0
    static let collapsedWidth = 64.0
    static let minimumWidth = 200.0
    static let maximumWidth = 320.0
    static let collapseThreshold = 140.0

    static func expandedWidth(_ proposed: Double, availableWidth: Double) -> Double {
        let maximum = min(maximumWidth, max(minimumWidth, availableWidth - 560))
        return min(maximum, max(minimumWidth, proposed.isFinite ? proposed : defaultWidth))
    }
}

/// Native mouse tracking keeps the drag anchored even when the sidebar snaps
/// to its icon rail, and prevents the window background from stealing the drag.
struct StudioSidebarResizeHandle: NSViewRepresentable {
    var width: Double
    var onResize: (Double) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.width = width
        view.onResize = onResize
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var width = StudioSidebarLayout.defaultWidth
        var onResize: (Double) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private var startingX = 0.0
        private var startingWidth = 0.0

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            startingX = screenX(for: event)
            startingWidth = width
        }

        override func mouseDragged(with event: NSEvent) {
            onResize(startingWidth + screenX(for: event) - startingX)
        }

        override func mouseUp(with event: NSEvent) {
            onEnd()
        }

        private func screenX(for event: NSEvent) -> Double {
            Double(window?.convertPoint(toScreen: event.locationInWindow).x ?? event.locationInWindow.x)
        }
    }
}
