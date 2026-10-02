import Foundation

public struct TranscriptEdit: Codable, Sendable {
    public var operation: String
    public var reference: String?
    public var hypothesis: String?
    public var referenceIndex: Int
    public var hypothesisIndex: Int
}

public struct TranscriptAnalysis: Codable, Sendable {
    public var normalization = "nami-words-v1; lowercase, curly apostrophes, edge punctuation, whitespace tokens"
    public var referenceWords: Int
    public var hypothesisWords: Int
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var wordErrorRate: Double?
    public var characterErrorRate: Double?
    public var exactMatch: Bool
    public var normalizedMatch: Bool
    public var edits: [TranscriptEdit]

    public static func compare(reference: String, hypothesis: String) -> Self {
        let a = EvaluationMetrics.words(reference), b = EvaluationMetrics.words(hypothesis)
        var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { matrix[i][0] = i }
        for j in 0...b.count { matrix[0][j] = j }
        for i in a.indices {
            for j in b.indices {
                matrix[i+1][j+1] = min(matrix[i][j] + (a[i] == b[j] ? 0 : 1),
                                       matrix[i][j+1] + 1, matrix[i+1][j] + 1)
            }
        }
        var i = a.count, j = b.count, edits: [TranscriptEdit] = []
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && matrix[i][j] == matrix[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1) {
                i -= 1; j -= 1
                if a[i] != b[j] { edits.append(.init(operation: "substitution", reference: a[i], hypothesis: b[j], referenceIndex: i, hypothesisIndex: j)) }
            } else if i > 0 && matrix[i][j] == matrix[i-1][j] + 1 {
                i -= 1
                edits.append(.init(operation: "deletion", reference: a[i], referenceIndex: i, hypothesisIndex: j))
            } else {
                j -= 1
                edits.append(.init(operation: "insertion", hypothesis: b[j], referenceIndex: i, hypothesisIndex: j))
            }
        }
        let charsA = Array(a.joined(separator: " ")), charsB = Array(b.joined(separator: " "))
        var row = Array(0...charsB.count)
        for (i, char) in charsA.enumerated() {
            var next = [i + 1]
            for (j, other) in charsB.enumerated() {
                next.append(min(next[j] + 1, row[j+1] + 1, row[j] + (char == other ? 0 : 1)))
            }
            row = next
        }
        return Self(referenceWords: a.count, hypothesisWords: b.count,
                    substitutions: edits.filter { $0.operation == "substitution" }.count,
                    deletions: edits.filter { $0.operation == "deletion" }.count,
                    insertions: edits.filter { $0.operation == "insertion" }.count,
                    wordErrorRate: a.isEmpty ? nil : Double(matrix[a.count][b.count]) / Double(a.count),
                    characterErrorRate: charsA.isEmpty ? nil : Double(row[charsB.count]) / Double(charsA.count),
                    exactMatch: reference == hypothesis, normalizedMatch: a == b, edits: edits.reversed())
    }
}
