import AppKit
import SwiftUI

enum StudioStyle {
    static let paperColor = NSColor(light: (0.969, 0.976, 0.961), dark: (0.090, 0.114, 0.098))
    static let paper = Color(nsColor: paperColor)
    static let sidebar = Color(light: (0.937, 0.949, 0.918), dark: (0.071, 0.090, 0.078))
    /// Cards and fields that sit on top of `paper`.
    static let surface = Color(light: (1, 1, 1), dark: (0.118, 0.145, 0.129))
    static let soft = Color(light: (0.921, 0.941, 0.898), dark: (0.137, 0.169, 0.149))
    static let selection = Color(light: (0.875, 0.906, 0.843), dark: (0.133, 0.235, 0.173))
    static let ink = Color(light: (0.165, 0.220, 0.184), dark: (0.910, 0.941, 0.918))
    static let quiet = Color(light: (0.447, 0.498, 0.439), dark: (0.608, 0.667, 0.627))
    /// Text, icons, and switches.
    static let green = Color(light: (0.204, 0.341, 0.251), dark: (0.439, 0.812, 0.576))
    /// Fills behind white labels, deeper than `green` in dark mode so the label stays legible.
    static let greenFill = Color(light: (0.204, 0.341, 0.251), dark: (0.216, 0.576, 0.353))
    static let line = Color(light: (0.867, 0.890, 0.847), dark: (0.188, 0.227, 0.204))
    static var divider: some View { Rectangle().fill(line).frame(height: 1) }

    /// The floating indicator is always dark, whatever the app's appearance.
    enum Indicator {
        static let background = Color(red: 0.165, green: 0.220, blue: 0.184)
        static let foreground = Color(red: 0.969, green: 0.976, blue: 0.961)
        static let accent = Color(red: 0.875, green: 0.906, blue: 0.843)
    }
}

extension StudioAppearance {
    var title: String {
        switch self {
        case .system: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil lets the app follow the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

typealias StudioRGB = (red: Double, green: Double, blue: Double)

extension NSColor {
    /// Resolves per appearance, so windows and views follow light and dark mode.
    convenience init(light: StudioRGB, dark: StudioRGB) {
        self.init(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }
}

extension Color {
    init(light: StudioRGB, dark: StudioRGB) { self.init(nsColor: NSColor(light: light, dark: dark)) }
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

    func studioProminentButton() -> some View {
        Group {
            if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
        }.tint(StudioStyle.greenFill)
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
            window.backgroundColor = StudioStyle.paperColor
            window.isMovableByWindowBackground = true
        }
    }
}
