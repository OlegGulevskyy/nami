import CoreText
import SwiftUI

public enum TranscriptFont: String, Codable, CaseIterable, Sendable {
    case sourceSans, avenirNext, rounded, system

    var title: String {
        switch self {
        case .sourceSans: "Source Sans 3"
        case .avenirNext: "Avenir Next"
        case .rounded: "SF Rounded"
        case .system: "System"
        }
    }

    var font: Font {
        switch self {
        case .sourceSans:
            Self.registerSourceSans()
            return .custom("SourceSans3-Regular", size: 18, relativeTo: .body)
        case .avenirNext:
            return .custom("AvenirNext-Regular", size: 18, relativeTo: .body)
        case .rounded:
            return .system(size: 18, design: .rounded)
        case .system:
            return .system(size: 17)
        }
    }

    // Process-scoped registration keeps the font self-contained in the app.
    static func registerSourceSans() { _ = sourceSansRegistration }

    private static let sourceSansRegistration: Void = {
        guard let url = Bundle.module.url(forResource: "SourceSans3-Regular", withExtension: "otf", subdirectory: "Fonts") else {
            assertionFailure("Missing bundled Source Sans 3 font")
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}
