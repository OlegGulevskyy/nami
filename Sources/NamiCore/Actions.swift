import Darwin
import Foundation

/// Something Nami does on this Mac when a recording is one of the action's phrases.
public struct VoiceAction: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// Comma-separated spoken phrases that run this action.
    public var phrases: String
    /// Run in order; the first failure stops the rest.
    public var steps: [ActionStep]

    public init(id: UUID = UUID(), phrases: String = "", steps: [ActionStep] = [ActionStep()]) {
        self.id = id
        self.phrases = phrases
        self.steps = steps
    }

    /// Each phrase, as typed. Empty entries are ignored.
    public var spokenPhrases: [String] {
        phrases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The first phrase names the action in history and status messages.
    public var title: String { spokenPhrases.first ?? "Untitled action" }

    public var isValid: Bool {
        !spokenPhrases.isEmpty && !steps.isEmpty && steps.allSatisfy { !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// An action takes the words said after its phrase only if a step has a `{{…}}` placeholder.
    public var takesDetails: Bool { steps.contains { $0.target.contains(ActionLibrary.placeholder) } }
}

public struct ActionStep: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case openURL, openApp, openFile, runShortcut, runCommand

        public var title: String {
            switch self {
            case .openURL: "Open link"
            case .openApp: "Open app"
            case .openFile: "Open file or folder"
            case .runShortcut: "Run shortcut"
            case .runCommand: "Run shell command"
            }
        }

        /// What `target` holds for this kind.
        public var targetLabel: String {
            switch self {
            case .openURL: "URL"
            case .openApp: "App name"
            case .openFile: "Path"
            case .runShortcut: "Shortcut name"
            case .runCommand: "Command"
            }
        }

        /// Links, files, and folders can open in a chosen app instead of the default one.
        public var opensWithApplication: Bool { self == .openURL || self == .openFile }
    }

    public var id: UUID
    public var kind: Kind
    public var target: String
    /// App name for `opensWithApplication` kinds; empty uses the default app.
    public var application: String

    public init(id: UUID = UUID(), kind: Kind = .openURL, target: String = "", application: String = "") {
        self.id = id
        self.kind = kind
        self.target = target
        self.application = application
    }

    public var summary: String {
        let app = application.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .openURL, .openFile: return app.isEmpty || !kind.opensWithApplication ? "Open \(target)" : "Open \(target) in \(app)"
        case .openApp: return "Open \(target)"
        case .runShortcut: return "Run shortcut \(target)"
        case .runCommand: return "Run \(target)"
        }
    }
}

public struct ActionMatch: Sendable, Equatable {
    public let action: VoiceAction
    /// What was said after the phrase, or empty.
    public let details: String
    /// The action's steps with placeholders filled, ready to run.
    public let steps: [ActionStep]
}

public struct ActionLibrary: Codable, Sendable, Equatable {
    public var version = 1
    public var actions: [VoiceAction] = []

    public init(actions: [VoiceAction] = []) { self.actions = actions }

    static let placeholder = "{{"

    /// A recording runs an action only when it starts with one of the action's phrases.
    /// Anything said after the phrase is the details: an action without placeholders
    /// needs none, so ordinary dictation that merely starts the same way is pasted as usual.
    /// Matching ignores case, accents, and punctuation. The longest phrase wins, then
    /// the first action in the list.
    public func match(_ transcript: String) -> ActionMatch? {
        let words = Self.words(transcript)
        let spoken = words.map(\.text)
        var best: (action: VoiceAction, length: Int)?
        for action in actions where action.isValid {
            for phrase in action.spokenPhrases {
                let phraseWords = Self.words(phrase).map(\.text)
                guard !phraseWords.isEmpty, spoken.starts(with: phraseWords),
                      spoken.count == phraseWords.count || action.takesDetails,
                      phraseWords.count > best?.length ?? 0 else { continue }
                best = (action, phraseWords.count)
            }
        }
        guard let best else { return nil }
        let details = best.length < words.count ? Self.trimmedDetails(String(transcript[words[best.length - 1].range.upperBound...])) : ""
        let steps = best.action.steps.map { step in
            var step = step
            step.target = Self.fill(step.target, with: details, escaping: step.kind)
            step.application = step.application.trimmingCharacters(in: .whitespacesAndNewlines)
            if step.kind == .openURL { step.target = Self.normalizedURL(step.target) }
            return step
        }
        return ActionMatch(action: best.action, details: details, steps: steps)
    }

    /// Every `{{…}}` takes all the details, escaped so they stay one URL value or one shell word.
    static func fill(_ template: String, with details: String, escaping kind: ActionStep.Kind) -> String {
        let value: String
        switch kind {
        case .openURL:
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#?/")
            value = details.addingPercentEncoding(withAllowedCharacters: allowed) ?? details
        case .runCommand: value = "'" + details.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .openApp, .openFile, .runShortcut: value = details
        }
        let pattern = try! NSRegularExpression(pattern: "\\{\\{[^{}\\n]*\\}\\}")
        return pattern.stringByReplacingMatches(in: template, range: NSRange(template.startIndex..., in: template),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `github.com/org/repo` opens as a website rather than a missing file.
    static func normalizedURL(_ text: String) -> String {
        URL(string: text)?.scheme == nil ? "https://" + text : text
    }

    /// English and Russian, folded like the spoken words they are compared with.
    private static let leadingFillers = Set(["for", "to", "with", "about", "on", "of", "please",
                                             "для", "про", "о", "об", "на", "с", "со", "по", "насчёт", "пожалуйста"]
        .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })

    private static func trimmedDetails(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        while let first = words(text).first, leadingFillers.contains(first.text), first.range.lowerBound == text.startIndex {
            text = String(text[first.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return text
    }

    private static func words(_ text: String) -> [(text: String, range: Range<String.Index>)] {
        let pattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{M}\\p{N}]+")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return (text[range].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), range)
        }
    }
}

public enum ActionError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

/// Actions are personal, so they live with history rather than in the project's `nami.json`.
/// The app and the `nami-actions` CLI share this file; writes take a lock so neither loses the other's change.
public struct ActionStore: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nami/actions.json")
    }

    public let url: URL

    public init(url: URL = ActionStore.defaultURL) { self.url = url }

    /// A missing file is an empty library. A damaged one throws, and is then never overwritten.
    public func load() throws -> ActionLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return ActionLibrary() }
        let library = try JSONDecoder().decode(ActionLibrary.self, from: Data(contentsOf: url))
        guard library.version == 1 else { throw ActionError.message("Unsupported actions version.") }
        return library
    }

    public func save(_ library: ActionLibrary) throws {
        try locked { try write(library) }
    }

    /// Loads, changes, and saves under one lock, so a concurrent writer cannot be overwritten.
    @discardableResult
    public func update(_ change: (inout ActionLibrary) throws -> Void) throws -> ActionLibrary {
        try locked {
            var library = try load()
            try change(&library)
            try write(library)
            return library
        }
    }

    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func write(_ library: ActionLibrary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(library) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.deletingLastPathComponent().appendingPathComponent(".actions.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ActionError.message("Cannot lock the actions file.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ActionError.message("Cannot lock the actions file.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
