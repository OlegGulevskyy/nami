import Foundation

/// The `nami-actions` commands. Every change goes through `ActionStore.update`, so the running
/// app and concurrent runs never overwrite each other; the app picks up changes within a second.
public enum ActionCommandLine {
    public static let usage = """
    Usage: nami-actions <command> [options]

    Manage Nami's voice actions. When a recording starts with one of an action's
    phrases, Nami runs its steps instead of pasting. Without a {{…}} placeholder
    the phrase must be all that is said; with one, the words after the phrase
    fill it.

    Commands:
      list [--json]                          Show all actions and their steps.
      add --phrases <a, b> <steps>           Add an action. Prints its ID.
      update <action> [--phrases <a, b>] [<steps>]
                                             Change an action's phrases, or replace all its steps.
      remove <action>                        Delete an action.
      try <what you'd say>                   Show what Nami would run, without running anything.
      path                                   Print the actions file location.

    Steps, run in the order given:
      --open-url <url>        Open a link. No scheme means https://.
      --open-app <name>       Open an app, e.g. "Google Chrome".
      --open-file <path>      Open a file or folder. ~ is expanded.
      --shortcut <name>       Run a Shortcut from the Shortcuts app.
      --command <command>     Run a shell command in a login zsh. - reads it from standard input.
      --with <app>            Open the previous link, file, or folder in this app.

    <action> is an ID (or a unique ID prefix of 4+ characters) or one of its phrases.

    Options:
      --file <path>   Use another actions file. Default: ~/Library/Application Support/Nami/actions.json
      --json          Print JSON (list, add, update, try).
    """

    public static func run(_ arguments: [String], store defaultStore: ActionStore = ActionStore(),
                           readInput: () -> String = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }) throws -> String {
        var options = try Options(arguments)
        let store = options.file.map { ActionStore(url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? defaultStore
        if let index = options.steps.firstIndex(where: { $0.kind == .runCommand && $0.target == "-" }) {
            // Heredocs end with a new line, which is not part of the command.
            options.steps[index].target = readInput().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let command = options.positional.first else { return usage }
        let rest = Array(options.positional.dropFirst())
        switch command {
        case "help", "--help", "-h":
            return usage
        case "path":
            return store.url.path
        case "list":
            try expect(rest, count: 0, command)
            let library = try store.load()
            if options.json { return try json(library.actions.map(ActionOutput.init)) }
            if library.actions.isEmpty { return "No actions." }
            return library.actions.map { action in
                (["\(shortID(action))  \(action.spokenPhrases.joined(separator: ", "))"]
                    + action.steps.map { "          " + $0.summary }).joined(separator: "\n")
            }.joined(separator: "\n\n")
        case "add":
            try expect(rest, count: 0, command)
            let phrases = try validPhrases(options.phrases)
            let action = VoiceAction(phrases: phrases.joined(separator: ", "), steps: try validSteps(options.steps, command))
            try store.update { library in
                try checkConflicts(phrases, in: library, ignoring: nil)
                library.actions.append(action)
            }
            return options.json ? try json(ActionOutput(action)) : "Added \(shortID(action)): \(action.title)"
        case "update":
            try expect(rest, count: 1, command)
            guard options.phrases != nil || !options.steps.isEmpty else {
                throw ActionError.message("update needs --phrases, steps, or both.")
            }
            var updated: VoiceAction?
            try store.update { library in
                let index = try find(rest[0], in: library)
                var action = library.actions[index]
                if let phrases = options.phrases {
                    let list = try validPhrases(phrases)
                    try checkConflicts(list, in: library, ignoring: action.id)
                    action.phrases = list.joined(separator: ", ")
                }
                if !options.steps.isEmpty { action.steps = try validSteps(options.steps, command) }
                library.actions[index] = action
                updated = action
            }
            return options.json ? try json(ActionOutput(updated!)) : "Updated \(shortID(updated!)): \(updated!.title)"
        case "remove":
            try expect(rest, count: 1, command)
            var removed: VoiceAction?
            try store.update { library in
                removed = library.actions.remove(at: try find(rest[0], in: library))
            }
            return "Removed \(shortID(removed!)): \(removed!.title)"
        case "try":
            guard !rest.isEmpty else { throw ActionError.message("try needs what you would say, in quotes.") }
            let match = try store.load().match(rest.joined(separator: " "))
            if options.json { return try json(TryOutput(match)) }
            guard let match else {
                throw ActionError.message("No action matched, so this would be pasted as said. Without a {{…}} placeholder, the phrase must be all that is said.")
            }
            return (["Runs \(shortID(match.action)): \(match.action.title)"] + match.steps.map { "  " + $0.summary }).joined(separator: "\n")
        default:
            throw ActionError.message("Unknown command “\(command)”. Run nami-actions help.")
        }
    }

    private struct Options {
        var positional: [String] = []
        var phrases: String?
        var steps: [ActionStep] = []
        var file: String?
        var json = false

        init(_ arguments: [String]) throws {
            var index = 0
            func value(_ flag: String) throws -> String {
                index += 1
                guard index < arguments.count else { throw ActionError.message("\(flag) needs a value.") }
                return arguments[index]
            }
            let kinds: [String: ActionStep.Kind] = ["--open-url": .openURL, "--open-app": .openApp, "--open-file": .openFile,
                                                    "--shortcut": .runShortcut, "--command": .runCommand]
            while index < arguments.count {
                switch arguments[index] {
                case "--phrases": phrases = try value("--phrases")
                case "--file": file = try value("--file")
                case "--json": json = true
                case "--with":
                    let app = try value("--with")
                    guard let last = steps.indices.last, steps[last].kind.opensWithApplication else {
                        throw ActionError.message("--with must follow --open-url or --open-file.")
                    }
                    steps[last].application = app.trimmingCharacters(in: .whitespacesAndNewlines)
                case let flag where kinds[flag] != nil:
                    steps.append(ActionStep(kind: kinds[flag]!, target: try value(flag)))
                case let flag where flag.hasPrefix("--") && flag.count > 2: throw ActionError.message("Unknown option \(flag).")
                case let argument: positional.append(argument)
                }
                index += 1
            }
        }
    }

    private struct StepOutput: Encodable {
        let kind: String, target: String, application: String?, summary: String
        init(_ step: ActionStep) {
            kind = step.kind.rawValue; target = step.target
            application = step.application.isEmpty ? nil : step.application; summary = step.summary
        }
    }

    private struct ActionOutput: Encodable {
        let id: String, phrases: [String], takesDetails: Bool, steps: [StepOutput]
        init(_ action: VoiceAction) {
            id = action.id.uuidString; phrases = action.spokenPhrases
            takesDetails = action.takesDetails; steps = action.steps.map(StepOutput.init)
        }
    }

    private struct TryOutput: Encodable {
        let matched: Bool, actionID: String?, details: String?, steps: [StepOutput]
        init(_ match: ActionMatch?) {
            matched = match != nil; actionID = match?.action.id.uuidString
            details = match?.details; steps = match?.steps.map(StepOutput.init) ?? []
        }
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func shortID(_ action: VoiceAction) -> String { String(action.id.uuidString.prefix(8)) }

    private static func expect(_ arguments: [String], count: Int, _ command: String) throws {
        guard arguments.count == count else {
            throw ActionError.message(count == 0 ? "\(command) takes no arguments besides options. Quote values with spaces."
                                                 : "\(command) needs exactly one action ID or phrase. Quote it if it has spaces.")
        }
    }

    private static func validPhrases(_ phrases: String?) throws -> [String] {
        let list = VoiceAction(phrases: phrases ?? "").spokenPhrases
        guard !list.isEmpty else { throw ActionError.message("Give at least one phrase with --phrases, separated by commas.") }
        return list
    }

    private static func validSteps(_ steps: [ActionStep], _ command: String) throws -> [ActionStep] {
        guard !steps.isEmpty else { throw ActionError.message("\(command) needs at least one step, e.g. --open-url <url>.") }
        if let empty = steps.first(where: { $0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ActionError.message("“\(empty.kind.title)” needs a \(empty.kind.targetLabel.lowercased()).")
        }
        return steps
    }

    private static func key(_ phrase: String) -> String {
        phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The same phrase on two actions would make one of them unreachable.
    private static func checkConflicts(_ phrases: [String], in library: ActionLibrary, ignoring id: UUID?) throws {
        for other in library.actions where other.id != id {
            if let phrase = phrases.first(where: { phrase in other.spokenPhrases.contains { key($0) == key(phrase) } }) {
                throw ActionError.message("“\(phrase)” is already a phrase of action \(shortID(other)) (\(other.title)).")
            }
        }
    }

    private static func find(_ reference: String, in library: ActionLibrary) throws -> Int {
        let upper = reference.uppercased()
        if upper.count >= 4 {
            let byID = library.actions.indices.filter { library.actions[$0].id.uuidString.hasPrefix(upper) }
            if byID.count == 1 { return byID[0] }
            if byID.count > 1 { throw ActionError.message("“\(reference)” matches several action IDs; use more characters.") }
        }
        if let index = library.actions.firstIndex(where: { $0.spokenPhrases.contains { key($0) == key(reference) } }) {
            return index
        }
        throw ActionError.message("No action has the ID or phrase “\(reference)”. Run nami-actions list.")
    }
}
