import Foundation

/// Conservative routing decisions, not guessed spelling replacements. Ambiguous
/// spellings go through the original acoustic recognizer with the full recording.
enum RecognitionReview {
    static let supportedLanguages: Set<String> = ["en", "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"]

    static func reason(for result: FastDecodedAudio, vocabulary: String) -> String? {
        if result.text.isEmpty || result.confidence < 0.75 { return "Low recognition confidence" }
        for word in result.words {
            let letters = word.text.filter(\.isLetter)
            if letters.count >= 3, letters == letters.uppercased(), word.confidence < 0.9 {
                return "Uncertain acronym: " + word.text
            }
        }
        let words = result.text.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        for term in terms(vocabulary) {
            let target = normalized(term)
            guard target.count >= 6 else { continue }
            let width = term.split(whereSeparator: \.isWhitespace).count
            for start in words.indices {
                for count in max(1, width - 1)...(width + 1) where start + count <= words.count {
                    let candidate = words[start..<(start + count)].joined()
                    if candidate != target, oneEditApart(candidate, target) { return "Uncertain vocabulary: " + term }
                }
            }
        }
        return nil
    }

    static func canonicalCase(_ text: String, vocabulary: String) -> String {
        terms(vocabulary).sorted { $0.count > $1.count }.reduce(text) { text, term in
            let phrase = term.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])" + phrase + "(?![\\p{L}\\p{N}_])", options: .caseInsensitive) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
    }

    private static func terms(_ vocabulary: String) -> [String] {
        vocabulary.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private static func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            guard edits <= 1 else { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) == 1
    }
}
