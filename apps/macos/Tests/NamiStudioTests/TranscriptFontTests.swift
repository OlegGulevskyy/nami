import AppKit
import Foundation
import Testing
@testable import NamiStudio

struct TranscriptFontTests {
    @Test func olderAndUnknownSettingsUseDefaultFont() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(StudioSettings.self, from: Data("{}".utf8)).transcriptFont == .sourceSans)
        #expect(try decoder.decode(StudioSettings.self, from: Data(#"{"transcriptFont":"future-font","language":"fr"}"#.utf8)).language == "fr")
        #expect(try decoder.decode(StudioSettings.self, from: Data(#"{"transcriptFont":"future-font"}"#.utf8)).transcriptFont == .sourceSans)
    }

    @Test func selectionSurvivesSavingAndReopening() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        for typeface in TranscriptFont.allCases {
            var settings = StudioSettings()
            settings.transcriptFont = typeface
            try settings.save(project: project)
            #expect(try StudioSettings.load(project: project).transcriptFont == typeface)
        }
    }

    @Test @MainActor func bundledFontResolvesWithoutSystemInstallation() throws {
        TranscriptFont.registerSourceSans()
        let font = try #require(NSFont(name: "SourceSans3-Regular", size: 18))
        #expect(font.familyName == "Source Sans 3")
        #expect(NSFont(name: "AvenirNext-Regular", size: 18) != nil)
    }
}
