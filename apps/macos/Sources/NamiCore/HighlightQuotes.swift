import Foundation

/// Text the user highlighted in another app while dictating, and when.
public struct CapturedHighlight: Equatable, Sendable {
    public var text: String
    /// Words in the live preview when the highlight began; nil before any preview arrived.
    public var spokenWords: Int?
    /// Seconds of audio recorded when the highlight began.
    public var seconds: Double

    public init(text: String, spokenWords: Int?, seconds: Double) {
        self.text = text
        self.spokenWords = spokenWords
        self.seconds = seconds
    }
}

/// Turns a stream of on-screen selections into distinct highlights. A selection
/// counts once it holds still for two polls, so a drag that grows the selection
/// is one highlight, anchored where the drag began.
public struct HighlightTracker: Sendable {
    public private(set) var highlights: [CapturedHighlight] = []
    private var pending: (highlight: CapturedHighlight, polls: Int)?
    private var committed: String?
    private var committedAt = -Double.infinity

    public init() {}

    public mutating func observe(_ selection: String?, spokenWords: Int?, seconds: Double) {
        let text = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { pending = nil; committed = nil; return }
        guard text != committed else { pending = nil; return }
        if var next = pending {
            if next.highlight.text == text { next.polls += 1 } else { next.highlight.text = text; next.polls = 1 }
            pending = next
        } else {
            pending = (CapturedHighlight(text: text, spokenWords: spokenWords, seconds: seconds), 1)
        }
        if let pending, pending.polls >= 2 { commit(pending.highlight, at: seconds) }
    }

    /// Keeps a selection seen right before the recording stopped.
    public mutating func finish(seconds: Double) {
        if let pending { commit(pending.highlight, at: seconds) }
    }

    private mutating func commit(_ highlight: CapturedHighlight, at seconds: Double) {
        pending = nil
        committed = highlight.text
        // Adjusting the previous selection a moment later replaces it.
        if let last = highlights.last, seconds - committedAt < 2,
           last.text.contains(highlight.text) || highlight.text.contains(last.text) {
            highlights[highlights.count - 1].text = highlight.text
        } else {
            highlights.append(highlight)
        }
        committedAt = seconds
    }
}

/// Replaces the spoken reference to each highlight ("this", "that sentence")
/// with the highlighted text in quotes.
public enum HighlightQuotes {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let quoted: Int
        public let unmatched: Int
        /// Cleanup reworded the references, so quotes went into the original wording.
        public let usedOriginal: Bool
    }

    private static let pointers: Set<String> = ["this", "that", "these", "those", "here"]
    private static let weakPointers: Set<String> = ["that", "those", "here"]
    private static let nouns: Set<String> = [
        "sentence", "sentences", "paragraph", "paragraphs", "part", "parts", "text", "line", "lines",
        "bit", "word", "words", "phrase", "one", "section", "message", "piece", "passage", "title", "heading",
    ]

    /// `spoken` is the recognized text the highlights were timed against; `edited`
    /// is what will be delivered, which may be the cleaned-up version of it.
    public static func apply(_ highlights: [CapturedHighlight], spoken: String, edited: String, audioSeconds: Double) -> Result {
        let spokenWords = words(spoken)
        let references = spokenWords.indices.filter { pointers.contains(spokenWords[$0].lower) }
        var chosen: [(reference: Int, text: String)] = []
        var after = -1
        for highlight in highlights {
            let anchor = highlight.spokenWords ?? (audioSeconds > 0
                ? Int((highlight.seconds / audioSeconds * Double(spokenWords.count)).rounded()) : 0)
            // Previews lag the voice, and people highlight just before or while
            // saying "this", so look mostly forward of the anchor.
            let best = references.enumerated()
                .filter { $0.element > after && $0.element >= anchor - 4 && $0.element <= anchor + 12 }
                .min { score($0.element, anchor, spokenWords) < score($1.element, anchor, spokenWords) }
            guard let best else { continue }
            chosen.append((best.offset, highlight.text))
            after = best.element
        }
        let unmatched = highlights.count - chosen.count
        guard !chosen.isEmpty else { return Result(text: edited, quoted: 0, unmatched: unmatched, usedOriginal: false) }
        // Cleanup rarely touches "this" or "that". When it kept every one, the
        // nth reference is the same in both texts; otherwise quote the original.
        let editedWords = words(edited)
        let editedReferences = editedWords.filter { pointers.contains($0.lower) }.map(\.lower)
        let usable = editedReferences == references.map { spokenWords[$0].lower }
        let target = usable ? edited : spoken
        return Result(text: replace(chosen, in: target), quoted: chosen.count, unmatched: unmatched, usedOriginal: !usable)
    }

    private static func score(_ index: Int, _ anchor: Int, _ words: [Word]) -> Int {
        (index >= anchor ? index - anchor : (anchor - index) * 2) + (weakPointers.contains(words[index].lower) ? 3 : 0)
    }

    private static func replace(_ chosen: [(reference: Int, text: String)], in text: String) -> String {
        let all = words(text)
        let references = all.indices.filter { pointers.contains(all[$0].lower) }
        var result = text
        // Replace from the end so earlier ranges stay valid.
        for (reference, quote) in chosen.reversed() {
            let index = references[reference]
            var range = all[index].range
            if index + 1 < all.count, nouns.contains(all[index + 1].lower),
               text[range.upperBound..<all[index + 1].range.lowerBound].allSatisfy(\.isWhitespace) {
                range = range.lowerBound..<all[index + 1].range.upperBound
            }
            result.replaceSubrange(range, with: "\"\(quote)\"")
        }
        return result
    }

    private struct Word {
        let range: Range<String.Index>
        let lower: String
    }

    private static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var start: String.Index?
        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                if start == nil { start = index }
            } else if let begin = start {
                result.append(Word(range: begin..<index, lower: text[begin..<index].lowercased()))
                start = nil
            }
        }
        if let begin = start { result.append(Word(range: begin..<text.endIndex, lower: text[begin...].lowercased())) }
        return result
    }
}
