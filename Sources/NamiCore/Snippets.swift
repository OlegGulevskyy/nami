import Foundation

/// Reusable text inserted in place of a spoken command, with `{{…}}` placeholders
/// for the details said after its phrase.
public struct Snippet: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// Comma-separated spoken phrases that select this snippet.
    public var phrases: String
    public var template: String

    public init(id: UUID = UUID(), phrases: String = "", template: String = "") {
        self.id = id
        self.phrases = phrases
        self.template = template
    }

    /// Each phrase, as typed. Empty entries are ignored.
    public var spokenPhrases: [String] {
        phrases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The first phrase names the snippet in history and status messages.
    public var title: String { spokenPhrases.first ?? "Untitled snippet" }
}

public struct SnippetExpansion: Sendable, Equatable {
    public let snippet: Snippet
    public let values: [String]
    public let text: String
}

public struct SnippetLibrary: Codable, Sendable, Equatable {
    public var version = 1
    /// Snippets expand only when a transcript contains one of these comma-separated words or
    /// phrases, e.g. one per language: "snippet, сниппет". Empty turns them off.
    public var triggerWord = "snippet"
    public var snippets: [Snippet] = []

    public init(triggerWord: String = "snippet", snippets: [Snippet] = []) {
        self.triggerWord = triggerWord
        self.snippets = snippets
    }

    /// Each trigger word or phrase, as typed. Empty entries are ignored.
    public var triggerWords: [String] {
        triggerWord.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// True when the transcript contains a trigger word, whether or not a snippet matches.
    public func mentionsTrigger(_ transcript: String) -> Bool {
        triggerRange(in: Self.words(transcript).map(\.text)) != nil
    }

    /// The earliest trigger said, and the longest one where several start together.
    private func triggerRange(in spoken: [String]) -> Range<Int>? {
        triggerWords.compactMap { Self.firstRange(of: Self.words($0).map(\.text), in: spoken) }
            .min { ($0.lowerBound, -$0.count) < ($1.lowerBound, -$1.count) }
    }

    /// Matching is literal and ignores case, accents, and punctuation. The longest
    /// matching phrase wins, then the earliest, then the first snippet in the list.
    /// Details are what follows the phrase, without the trigger word and leading
    /// words such as "for".
    public func expand(_ transcript: String) -> SnippetExpansion? {
        let words = Self.words(transcript)
        let spoken = words.map(\.text)
        guard let triggerRange = triggerRange(in: spoken) else { return nil }
        var best: (snippet: Snippet, range: Range<Int>)?
        for snippet in snippets {
            for phrase in snippet.spokenPhrases {
                let phraseWords = Self.words(phrase).map(\.text)
                guard let range = Self.firstRange(of: phraseWords, in: spoken, avoiding: triggerRange) else { continue }
                if let current = best, current.range.count > range.count
                    || (current.range.count == range.count && current.range.lowerBound <= range.lowerBound) { continue }
                best = (snippet, range)
            }
        }
        guard let best else { return nil }
        // The details follow the phrase; drop the trigger word if it is among them.
        let phraseEnd = words[best.range.upperBound - 1].range.upperBound
        let parts = triggerRange.lowerBound >= best.range.upperBound
            ? [phraseEnd..<words[triggerRange.lowerBound].range.lowerBound,
               words[triggerRange.upperBound - 1].range.upperBound..<transcript.endIndex]
            : [phraseEnd..<transcript.endIndex]
        let details = parts.map { Self.trimmedDetails(String(transcript[$0])) }.filter { !$0.isEmpty }.joined(separator: " ")
        let values = Self.values(in: details)
        return SnippetExpansion(snippet: best.snippet, values: values, text: Self.fill(best.snippet.template, with: values))
    }

    /// One placeholder takes every value, joined with commas. Several placeholders take
    /// values in order, and the last takes the rest. Repeated labels share a value;
    /// placeholders without a value are left in place so the gap is visible.
    public static func fill(_ template: String, with values: [String]) -> String {
        let pattern = try! NSRegularExpression(pattern: "\\{\\{([^{}\\n]*)\\}\\}")
        let matches = pattern.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var labels: [String] = []
        for match in matches {
            let label = Range(match.range(at: 1), in: template).map { template[$0].trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if !labels.contains(label) { labels.append(label) }
        }
        var output = template
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output), let labelRange = Range(match.range(at: 1), in: template) else { continue }
            let index = labels.firstIndex(of: template[labelRange].trimmingCharacters(in: .whitespaces).lowercased())!
            guard index < values.count else { continue }
            let value = index == labels.count - 1 ? values[index...].joined(separator: ", ") : values[index]
            output.replaceSubrange(range, with: value)
        }
        return output
    }

    /// Lists split on commas, semicolons, new lines, "&", "and", and "plus", or Russian "и" and "плюс".
    static func values(in details: String) -> [String] {
        let separator = try! NSRegularExpression(pattern: "\\s*(?:[,;\\n]|\\s&\\s|\\b(?:and|plus|и|плюс)\\b)\\s*", options: [.caseInsensitive])
        let marked = separator.stringByReplacingMatches(in: details, range: NSRange(details.startIndex..., in: details), withTemplate: "\u{1F}")
        return marked.split(separator: "\u{1F}").map { trimmedDetails(String($0)) }.filter { !$0.isEmpty }
    }

    /// English and Russian, folded like the spoken words they are compared with.
    private static let leadingFillers = Set(["for", "to", "with", "about", "on", "of", "regarding", "please", "and",
                                             "для", "про", "о", "об", "на", "с", "со", "по", "к", "насчёт", "пожалуйста", "и"]
        .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })

    private static func trimmedDetails(_ text: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "@#&()[]\"'"))
        var text = text.trimmingCharacters(in: edges)
        while let first = words(text).first, leadingFillers.contains(first.text), first.range.lowerBound == text.startIndex {
            text = String(text[first.range.upperBound...]).trimmingCharacters(in: edges)
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

    private static func firstRange(of needle: [String], in haystack: [String], avoiding excluded: Range<Int>? = nil) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            let range = start..<(start + needle.count)
            if let excluded, range.overlaps(excluded) { continue }
            if Array(haystack[range]) == needle { return range }
        }
        return nil
    }
}
