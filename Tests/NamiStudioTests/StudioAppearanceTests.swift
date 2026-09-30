import AppKit
import Foundation
import SwiftUI
import Testing
@testable import NamiStudio

struct StudioAppearanceTests {
    @Test func olderAndUnknownSettingsFollowTheSystem() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(StudioSettings.self, from: Data("{}".utf8)).appearance == .system)
        #expect(try decoder.decode(StudioSettings.self, from: Data(#"{"appearance":"sepia"}"#.utf8)).appearance == .system)
    }

    @Test func selectionSurvivesSavingAndReopening() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        for appearance in StudioAppearance.allCases {
            var settings = StudioSettings()
            settings.appearance = appearance
            try settings.save(project: project)
            #expect(try StudioSettings.load(project: project).appearance == appearance)
        }
    }

    @Test func mapsToAppKitAppearances() {
        #expect(StudioAppearance.system.nsAppearance == nil)
        #expect(StudioAppearance.light.nsAppearance?.name == .aqua)
        #expect(StudioAppearance.dark.nsAppearance?.name == .darkAqua)
    }

    @Test @MainActor func paletteResolvesPerAppearance() throws {
        func rgb(_ appearance: NSAppearance.Name) throws -> NSColor {
            var color = NSColor.clear
            try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                color = StudioStyle.paperColor.usingColorSpace(.sRGB) ?? .clear
            }
            return color
        }
        #expect(try rgb(.aqua).brightnessComponent > 0.9)
        #expect(try rgb(.darkAqua).brightnessComponent < 0.2)
    }
}
