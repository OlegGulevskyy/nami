import Foundation

/// The `nami-snippets` commands. Every change goes through `SnippetStore.update`, so the running
/// app and concurrent runs never overwrite each other; the app picks up changes within a second.
public enum SnippetCommandLine {
    public static let usage = """
    Usage: nami-snippets <command> [options]

    Manage Nami's dictation snippets. Say the trigger word, one of a snippet's
    phrases, then details; Nami pastes the snippet's text with the details in
    place of {{…}} placeholders.

    Commands:
      list [--json]                          Show the trigger words and all snippets.
      add --phrases <a, b> --text <text>     Add a snippet. Prints its ID.
      update <snippet> [--phrases <a, b>] [--text <text>]
                                             Change a snippet's phrases or text.
      remove <snippet>                       Delete a snippet.
      trigger [<words>]                      Show the trigger words, or set them, comma-separated
                                             (e.g. one per language: "snippet, сниппет"). "" turns snippets off.
      try <what you'd say>                   Show what Nami would paste, without changing anything.
      path                                   Print the snippets file location.

    <snippet> is an ID (or a unique ID prefix of 4+ characters) or one of its phrases.
    Pass --text - to read the text from standard input (keeps new lines).

    Options:
      --file <path>   Use another snippets file. Default: ~/Library/Application Support/Nami/snippets.json
      --json          Print JSON (list, add, update, try).
    """

    public static func run(_ arguments: [String], store defaultStore: SnippetStore = SnippetStore(),
                           readInput: () -> String = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }) throws -> String {
        var options = try Options(arguments)
        let store = options.file.map { SnippetStore(url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? defaultStore
        // Heredocs end with a new line, which would otherwise be pasted too.
        if options.text == "-" { options.text = String(readInput().reversed().drop { $0.isNewline }.reversed()) }
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
            if options.json { return try json(ListOutput(library)) }
            var lines = [triggerLine(library)]
            if library.snippets.isEmpty { lines.append("No snippets.") }
            for snippet in library.snippets {
                lines.append("")
                lines.append("\(shortID(snippet))  \(snippet.spokenPhrases.joined(separator: ", "))")
                lines += snippet.template.split(separator: "\n", omittingEmptySubsequences: false).map { "          " + $0 }
            }
            return lines.joined(separator: "\n")
        case "add":
            try expect(rest, count: 0, command)
            let phrases = try validPhrases(options.phrases)
            guard let text = options.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SnippetError.message("add needs --text with the snippet's text.")
            }
            let snippet = Snippet(phrases: phrases.joined(separator: ", "), template: text)
            try store.update { library in
                try checkConflicts(phrases, in: library, ignoring: nil)
                library.snippets.append(snippet)
            }
            return options.json ? try json(SnippetOutput(snippet)) : "Added \(shortID(snippet)): \(snippet.title)"
        case "update":
            try expect(rest, count: 1, command)
            guard options.phrases != nil || options.text != nil else {
                throw SnippetError.message("update needs --phrases, --text, or both.")
            }
            var updated: Snippet?
            try store.update { library in
                let index = try find(rest[0], in: library)
                var snippet = library.snippets[index]
                if let phrases = options.phrases {
                    let list = try validPhrases(phrases)
                    try checkConflicts(list, in: library, ignoring: snippet.id)
                    snippet.phrases = list.joined(separator: ", ")
                }
                if let text = options.text {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw SnippetError.message("--text cannot be empty. Use remove to delete a snippet.")
                    }
                    snippet.template = text
                }
                library.snippets[index] = snippet
                updated = snippet
            }
            return options.json ? try json(SnippetOutput(updated!)) : "Updated \(shortID(updated!)): \(updated!.title)"
        case "remove":
            try expect(rest, count: 1, command)
            var removed: Snippet?
            try store.update { library in
                removed = library.snippets.remove(at: try find(rest[0], in: library))
            }
            return "Removed \(shortID(removed!)): \(removed!.title)"
        case "trigger":
            guard rest.count <= 1 else {
                throw SnippetError.message("trigger takes one argument. Quote it, and separate several trigger words with commas.")
            }
            if let words = rest.first {
                let library = try store.update { $0.triggerWord = SnippetLibrary(triggerWord: words).triggerWords.joined(separator: ", ") }
                return library.triggerWords.isEmpty ? "Snippets are off." : triggerLine(library)
            }
            let library = try store.load()
            return library.triggerWords.isEmpty ? "(off)" : library.triggerWords.joined(separator: ", ")
        case "try":
            guard !rest.isEmpty else { throw SnippetError.message("try needs what you would say, in quotes.") }
            let spoken = rest.joined(separator: " ")
            let library = try store.load()
            let expansion = library.expand(spoken)
            if options.json { return try json(TryOutput(expansion: expansion, mentionsTrigger: library.mentionsTrigger(spoken))) }
            if let expansion { return expansion.text }
            if library.triggerWords.isEmpty { throw SnippetError.message("Snippets are off: there is no trigger word.") }
            if !library.mentionsTrigger(spoken) {
                throw SnippetError.message("No trigger word (\(library.triggerWords.map { "“\($0)”" }.joined(separator: ", "))), so this would be pasted as said.")
            }
            throw SnippetError.message("No snippet phrase matched, so this would be pasted as said.")
        default:
            throw SnippetError.message("Unknown command “\(command)”. Run nami-snippets help.")
        }
    }

    private struct Options {
        var positional: [String] = []
        var phrases: String?
        var text: String?
        var file: String?
        var json = false

        init(_ arguments: [String]) throws {
            var index = 0
            func value(_ flag: String) throws -> String {
                index += 1
                guard index < arguments.count else { throw SnippetError.message("\(flag) needs a value.") }
                return arguments[index]
            }
            while index < arguments.count {
                switch arguments[index] {
                case "--phrases": phrases = try value("--phrases")
                case "--text": text = try value("--text")
                case "--file": file = try value("--file")
                case "--json": json = true
                case let flag where flag.hasPrefix("--") && flag.count > 2: throw SnippetError.message("Unknown option \(flag).")
                case let argument: positional.append(argument)
                }
                index += 1
            }
        }
    }

    private struct SnippetOutput: Encodable {
        let id: String, phrases: [String], text: String
        init(_ snippet: Snippet) { id = snippet.id.uuidString; phrases = snippet.spokenPhrases; text = snippet.template }
    }

    private struct ListOutput: Encodable {
        let triggerWord: String, triggerWords: [String], snippets: [SnippetOutput]
        init(_ library: SnippetLibrary) {
            triggerWord = library.triggerWord; triggerWords = library.triggerWords; snippets = library.snippets.map(SnippetOutput.init)
        }
    }

    private struct TryOutput: Encodable {
        let matched: Bool, mentionsTrigger: Bool, snippetID: String?, values: [String], text: String?
        init(expansion: SnippetExpansion?, mentionsTrigger: Bool) {
            matched = expansion != nil; self.mentionsTrigger = mentionsTrigger
            snippetID = expansion?.snippet.id.uuidString; values = expansion?.values ?? []; text = expansion?.text
        }
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func triggerLine(_ library: SnippetLibrary) -> String {
        let words = library.triggerWords
        return (words.count > 1 ? "Trigger words: " : "Trigger word: ") + (words.isEmpty ? "(off)" : words.joined(separator: ", "))
    }

    private static func shortID(_ snippet: Snippet) -> String { String(snippet.id.uuidString.prefix(8)) }

    private static func expect(_ arguments: [String], count: Int, _ command: String) throws {
        guard arguments.count == count else {
            throw SnippetError.message(count == 0 ? "\(command) takes no arguments besides options. Quote values with spaces."
                                                  : "\(command) needs exactly one snippet ID or phrase. Quote it if it has spaces.")
        }
    }

    private static func validPhrases(_ phrases: String?) throws -> [String] {
        let list = Snippet(phrases: phrases ?? "").spokenPhrases
        guard !list.isEmpty else { throw SnippetError.message("Give at least one phrase with --phrases, separated by commas.") }
        return list
    }

    private static func key(_ phrase: String) -> String {
        phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The same phrase on two snippets would make one of them unreachable.
    private static func checkConflicts(_ phrases: [String], in library: SnippetLibrary, ignoring id: UUID?) throws {
        for other in library.snippets where other.id != id {
            if let phrase = phrases.first(where: { phrase in other.spokenPhrases.contains { key($0) == key(phrase) } }) {
                throw SnippetError.message("“\(phrase)” is already a phrase of snippet \(shortID(other)) (\(other.title)).")
            }
        }
    }

    private static func find(_ reference: String, in library: SnippetLibrary) throws -> Int {
        let upper = reference.uppercased()
        if upper.count >= 4 {
            let byID = library.snippets.indices.filter { library.snippets[$0].id.uuidString.hasPrefix(upper) }
            if byID.count == 1 { return byID[0] }
            if byID.count > 1 { throw SnippetError.message("“\(reference)” matches several snippet IDs; use more characters.") }
        }
        if let index = library.snippets.firstIndex(where: { $0.spokenPhrases.contains { key($0) == key(reference) } }) {
            return index
        }
        throw SnippetError.message("No snippet has the ID or phrase “\(reference)”. Run nami-snippets list.")
    }
}
