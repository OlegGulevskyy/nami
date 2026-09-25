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

struct StudioToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? StudioStyle.green : Color(red: 0.80, green: 0.83, blue: 0.77))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).frame(width: 20, height: 20)
                }
                .frame(width: 35, height: 20)
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
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
