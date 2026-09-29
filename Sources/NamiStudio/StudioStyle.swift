import AppKit
import SwiftUI

enum StudioStyle {
    static let paper = Color(red: 0.969, green: 0.976, blue: 0.961)
    static let sidebar = Color(red: 0.937, green: 0.949, blue: 0.918)
    static let soft = Color(red: 0.921, green: 0.941, blue: 0.898)
    static let selection = Color(red: 0.875, green: 0.906, blue: 0.843)
    static let ink = Color(red: 0.165, green: 0.220, blue: 0.184)
    static let quiet = Color(red: 0.447, green: 0.498, blue: 0.439)
    static let green = Color(red: 0.204, green: 0.341, blue: 0.251)
    static let line = Color(red: 0.867, green: 0.890, blue: 0.847)
    static var divider: some View { Rectangle().fill(line).frame(height: 1) }
}

extension View {
    /// Liquid Glass on macOS 26 and later; the flat `fallback` fill before that.
    @ViewBuilder func studioGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false,
                                  fallback: Color = StudioStyle.soft) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(tint ?? fallback, in: shape)
        }
    }

    @ViewBuilder func studioProminentButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}

struct StudioSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .fixedSize().accessibilityAddTraits(.isHeader)
            StudioStyle.divider
        }
    }
}

struct StudioIconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(StudioStyle.quiet)
            .frame(width: 34, height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(configuration.isPressed ? StudioStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct StudioKeycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14, design: .rounded))
            .foregroundStyle(StudioStyle.green)
            .padding(.horizontal, 12).frame(minWidth: 34, minHeight: 31)
            .background(StudioStyle.paper, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StudioStyle.line))
    }
}

/// The system switch, so it keeps the native slide animation and picks up
/// Liquid Glass on macOS 26 and later.
struct StudioToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch).tint(StudioStyle.green)
    }
}

/// Leaves window controls and dragging native while extending the paper header.
struct StudioWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) { nsView.configure() }

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(StudioStyle.paper)
            window.isMovableByWindowBackground = true
        }
    }
}
