import CryptoKit
import Foundation
import Testing
@testable import NamiStudio

struct AgentSkillsTests {
    /// Installed skills are compared by version, so every change to a template must raise it.
    /// After raising `metadata.version`, paste the new fingerprint printed by the failure here.
    @Test func changedTemplatesRaiseTheirVersion() {
        let fingerprints = Dictionary(uniqueKeysWithValues: AgentSkill.bundled.map { skill in
            (skill.name, "\(skill.version):" + SHA256.hash(data: Data(skill.template.utf8)).map { String(format: "%02x", $0) }.joined())
        })
        #expect(fingerprints == [
            "nami-snippets": "1:ed1fb8bbc9030aeee94b4882deeacaa237943155c00521ddb078ac974d019548",
            "nami-actions": "1:06f66082516f558f439c45a23929d2090262b1cc706424ab29430a8e784d78d0",
        ], "Edited a skill? Raise its metadata.version, then update this fingerprint.")
    }

    @Test func bundledSkillsPointAtTheirTool() throws {
        #expect(AgentSkill.bundled.map(\.name) == ["nami-snippets", "nami-actions"])
        let tools = URL(fileURLWithPath: "/Applications/Nami.app/Contents/Helpers")
        for skill in AgentSkill.bundled {
            #expect(skill.version >= 1)
            #expect(skill.template.contains("\nname: \(skill.name)\n"))
            let rendered = skill.rendered(tools: tools)
            #expect(rendered.contains("`/Applications/Nami.app/Contents/Helpers/\(skill.name)`"))
            #expect(!rendered.contains("@NAMI_"))
        }
    }

    @Test func quotesToolPathsWithSpaces() throws {
        let skill = try #require(AgentSkill.bundled.first)
        let rendered = skill.rendered(tools: URL(fileURLWithPath: "/Users/sam/My Apps/Nami.app/Contents/Helpers"))
        #expect(rendered.contains("`'/Users/sam/My Apps/Nami.app/Contents/Helpers/\(skill.name)'`"))
    }

    @Test func readsTheVersionFromFrontMatterOnly() {
        #expect(AgentSkill.version(of: "---\nname: a\nmetadata:\n  version: \"12\"\n---\nversion: 3\n") == 12)
        #expect(AgentSkill.version(of: "---\nname: a\n---\n  version: 3\n") == nil)
        #expect(AgentSkill.version(of: "no front matter") == nil)
    }

    @Test func reportsInstallLifecycle() throws {
        try withFolder { folder in
            let tools = URL(fileURLWithPath: "/Applications/Nami.app/Contents/Helpers")
            let installer = AgentSkillInstaller(folder: folder, tools: tools)
            let skill = AgentSkill(name: "nami-snippets", title: "Snippets", template: "---\nname: nami-snippets\nmetadata:\n  version: \"2\"\n---\nRun @NAMI_SNIPPETS@\n")
            let file = folder.appendingPathComponent("nami-snippets/SKILL.md")
            #expect(installer.status(skill) == .notInstalled)

            try installer.install(skill)
            #expect(installer.status(skill) == .current)
            #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("Run /Applications/Nami.app/Contents/Helpers/nami-snippets\n"))

            try Data("---\nname: nami-snippets\nmetadata:\n  version: \"1\"\n---\nold\n".utf8).write(to: file)
            #expect(installer.status(skill) == .outdated(installed: 1))
            try Data("hand-written\n".utf8).write(to: file)
            #expect(installer.status(skill) == .outdated(installed: nil))
            try Data("---\nname: nami-snippets\nmetadata:\n  version: \"3\"\n---\nnew\n".utf8).write(to: file)
            #expect(installer.status(skill) == .newer(installed: 3))

            try installer.install(skill)
            let moved = AgentSkillInstaller(folder: folder, tools: URL(fileURLWithPath: "/Users/sam/Applications/Nami.app/Contents/Helpers"))
            #expect(moved.status(skill) == .changed)
        }
    }

    @Test func replacesSymlinkedSkillsWithoutTouchingTheirTarget() throws {
        try withFolder { folder in
            let skill = try #require(AgentSkill.bundled.first)
            let checkout = folder.appendingPathComponent("checkout", isDirectory: true)
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            try Data("checkout copy".utf8).write(to: checkout.appendingPathComponent("SKILL.md"))
            let skills = folder.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            let link = skills.appendingPathComponent(skill.name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: checkout)
            let installer = AgentSkillInstaller(folder: skills, tools: URL(fileURLWithPath: "/tmp/tools")) { _ in
                Issue.record("Symlinks are removed, not trashed")
            }
            #expect(installer.status(skill) == .outdated(installed: nil))

            try installer.install(skill)
            #expect(installer.status(skill) == .current)
            #expect(try String(contentsOf: checkout.appendingPathComponent("SKILL.md"), encoding: .utf8) == "checkout copy")

            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("missing"))
            #expect(installer.status(skill) == .notInstalled)
            try installer.remove(skill)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
            #expect(FileManager.default.fileExists(atPath: checkout.path))
        }
    }

    @Test func removingMovesTheSkillFolderToTheTrash() throws {
        try withFolder { folder in
            let skill = try #require(AgentSkill.bundled.first)
            let trashed = Trashed()
            let installer = AgentSkillInstaller(folder: folder, tools: URL(fileURLWithPath: "/tmp/tools")) { trashed.urls.append($0) }
            try installer.remove(skill)
            #expect(trashed.urls.isEmpty)
            try installer.install(skill)
            try installer.remove(skill)
            #expect(trashed.urls == [folder.appendingPathComponent(skill.name, isDirectory: true)])
        }
    }

    @Test func skillsFolderDefaultsToClaudeCode() throws {
        #expect(try JSONDecoder().decode(StudioSettings.self, from: Data("{}".utf8)).skillsFolder == "")
        #expect(AgentSkillInstaller.claudeCodeFolder.path.hasSuffix("/.claude/skills"))
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nami-skills-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }
}

private final class Trashed: @unchecked Sendable {
    var urls: [URL] = []
}
