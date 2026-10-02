import Foundation

/// Explicit, language-scoped vocabulary rules. Examples never become rules implicitly.
public struct VocabularyCorrection: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var heard: String
    public var replacement: String
    public var language: String

    public init(id: UUID = UUID(), heard: String, replacement: String, language: String = "en") {
        self.id = id
        self.heard = heard
        self.replacement = replacement
        self.language = language
    }
}

public struct CleanupExample: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var rawText: String
    public var generatedText: String
    public var correctedText: String
    public var language: String
    public var createdAt: Date
    public var sourceRunID: UUID?
    public var processorID: String?
    public var memoryRevision: Int?
    public var feedbackSource: String?

    public init(id: UUID = UUID(), rawText: String, generatedText: String, correctedText: String,
                language: String = "en", createdAt: Date = .now, sourceRunID: UUID? = nil,
                processorID: String? = nil, memoryRevision: Int? = nil, feedbackSource: String? = nil) {
        self.id = id
        self.rawText = rawText
        self.generatedText = generatedText
        self.correctedText = correctedText
        self.language = language
        self.createdAt = createdAt
        self.sourceRunID = sourceRunID
        self.processorID = processorID
        self.memoryRevision = memoryRevision
        self.feedbackSource = feedbackSource
    }
}

public struct CleanupMemory: Codable, Sendable, Equatable {
    public var version = 1
    public var revision = 0
    public var vocabulary: [VocabularyCorrection] = []
    public var examples: [CleanupExample] = []

    public init() {}

    /// A single pass over the original: longest phrase wins, replacements never cascade.
    /// Matching is literal and case-insensitive, with Unicode word boundaries.
    public func replacingVocabulary(in text: String, language: String) -> String {
        let rules = vocabulary.filter { $0.language == language && !$0.heard.isEmpty && !$0.replacement.isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
        guard !rules.isEmpty else { return text }
        let alternatives = rules.map { NSRegularExpression.escapedPattern(for: $0.heard) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{M}\\p{N}_])",
            options: [.caseInsensitive]) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text),
                  let rule = rules.first(where: { $0.heard.caseInsensitiveCompare(String(text[range])) == .orderedSame }),
                  let outputRange = Range(match.range, in: output) else { continue }
            output.replaceSubrange(outputRange, with: rule.replacement)
        }
        return output
    }

    /// Cheap lexical retrieval, with an explicit budget. No embedding model on the hot path.
    public func relevantExamples(for text: String, language: String, excluding: Set<UUID> = [],
                                 maximumBytes: Int = 1_600) -> [CleanupExample] {
        let words = Self.contentWords(text)
        guard !words.isEmpty else { return [] }
        let ranked = examples.filter { $0.language == language && !excluding.contains($0.id) }
            .compactMap { example -> (CleanupExample, Double)? in
                let exampleWords = Self.contentWords(example.rawText)
                let overlap = words.intersection(exampleWords).count
                // A single generic word must not retrieve an unrelated sentence.
                // Require at least half the example's content and two shared
                // terms when both passages contain that many meaningful terms.
                guard overlap > 0, overlap >= min(2, words.count, exampleWords.count),
                      overlap * 2 >= exampleWords.count else { return nil }
                let union = words.union(exampleWords).count
                return (example, Double(overlap) / Double(union))
            }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                if left.0.createdAt != right.0.createdAt { return left.0.createdAt > right.0.createdAt }
                return left.0.id.uuidString < right.0.id.uuidString
            }
        var selected: [CleanupExample] = []
        var bytes = 0
        for (example, _) in ranked {
            let size = example.rawText.utf8.count + example.correctedText.utf8.count
            guard bytes + size <= maximumBytes else { continue }
            selected.append(example)
            bytes += size
            if selected.count == 3 { break }
        }
        return selected
    }

    private static func contentWords(_ text: String) -> Set<String> {
        let common: Set<String> = ["the", "and", "that", "this", "with", "have", "you", "your", "for", "was", "are", "can", "could", "would", "should", "please",
            "need", "think", "want", "will", "just", "some", "what", "let", "say", "really", "maybe", "know", "like", "then", "also", "been"]
        return Set(EvaluationMetrics.words(text).filter { $0.count > 2 && !common.contains($0) })
    }
}
