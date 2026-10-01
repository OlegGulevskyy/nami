import Foundation

/// A Claude Code style skill (`<folder>/<name>/SKILL.md`) bundled with Nami that
/// teaches coding agents to use one of the command-line tools in `Contents/Helpers`.
public struct AgentSkill: Identifiable, Equatable, Sendable {
    public let name: String
    /// What it manages, as shown in Settings.
    public let title: String
    /// `metadata.version` in the template's front matter. Raise it whenever the template changes.
    public let version: Int
    let template: String
    public var id: String { name }

    init(name: String, title: String, template: String) {
        self.name = name
        self.title = title
        self.template = template
        version = Self.version(of: template) ?? 0
    }

    /// The bundled skills, one per command-line tool.
    public static let bundled: [AgentSkill] = [("nami-snippets", "Snippets"), ("nami-actions", "Actions")].compactMap { name, title in
        guard let url = Bundle.module.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/\(name)"),
              let template = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return AgentSkill(name: name, title: title, template: template)
    }

    /// The template with `@NAMI_SNIPPETS@`-style placeholders replaced by the tool's path.
    func rendered(tools: URL) -> String {
        let placeholder = "@" + name.uppercased().replacingOccurrences(of: "-", with: "_") + "@"
        return template.replacingOccurrences(of: placeholder, with: Self.shellQuoted(tools.appendingPathComponent(name).path))
    }

    /// `version: "3"` inside the front matter's `metadata` map.
    static func version(of contents: String) -> Int? {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        for line in lines[1..<end] where line.hasPrefix(" ") || line.hasPrefix("\t") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "version" else { continue }
            return Int(parts[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))))
        }
        return nil
    }

    private static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        guard path.unicodeScalars.contains(where: { !safe.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AgentSkillStatus: Equatable, Sendable {
    case notInstalled
    case current
    /// Installed from an older Nami (`nil`: no version, e.g. copied by hand).
    case outdated(installed: Int?)
    /// Same version, different text: edited by hand, or Nami moved since it was installed.
    case changed
    /// Installed by a newer Nami.
    case newer(installed: Int)
}

/// Installs bundled skills into a skills folder, such as `~/.claude/skills`.
public struct AgentSkillInstaller: Sendable {
    public static let claudeCodeFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills", isDirectory: true)
    /// Shared by Codex and other agents that follow the Agent Skills convention.
    public static let agentsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agents/skills", isDirectory: true)
    /// The command-line tools bundled in the running app, or nil when this build has none.
    public static var bundledTools: URL? {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let complete = AgentSkill.bundled.allSatisfy {
            FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent($0.name).path)
        }
        return complete ? helpers : nil
    }

    public let folder: URL
    public let tools: URL
    private let trash: @Sendable (URL) throws -> Void

    public init(folder: URL, tools: URL,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.folder = folder
        self.tools = tools
        self.trash = trash
    }

    public func status(_ skill: AgentSkill) -> AgentSkillStatus {
        guard let installed = try? String(contentsOf: file(skill), encoding: .utf8) else { return .notInstalled }
        if installed == skill.rendered(tools: tools) { return .current }
        guard let version = AgentSkill.version(of: installed) else { return .outdated(installed: nil) }
        if version < skill.version { return .outdated(installed: version) }
        if version > skill.version { return .newer(installed: version) }
        return .changed
    }

    /// Writes this app's version. A symlinked skill folder is replaced, never written through.
    public func install(_ skill: AgentSkill) throws {
        let directory = folder.appendingPathComponent(skill.name, isDirectory: true)
        if isSymlink(directory) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(skill.rendered(tools: tools).utf8).write(to: file(skill), options: .atomic)
    }

    /// Moves the skill's folder to the Trash; a symlink is removed without touching its target.
    public func remove(_ skill: AgentSkill) throws {
        let directory = folder.appendingPathComponent(skill.name, isDirectory: true)
        if isSymlink(directory) {
            try FileManager.default.removeItem(at: directory)
        } else if FileManager.default.fileExists(atPath: directory.path) {
            try trash(directory)
        }
    }

    private func file(_ skill: AgentSkill) -> URL {
        folder.appendingPathComponent(skill.name, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    /// Also true for a dangling link, which `fileExists` reports as missing.
    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
