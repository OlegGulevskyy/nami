import Foundation

public struct EvaluationSample: Codable, Sendable {
    public let id: String
    public let audio: String
    public let reference: String
    public let language: String
    public let category: String
    public let condition: String
    public let referenceVerified: Bool

    public func validate() throws {
        guard !id.isEmpty, !audio.isEmpty, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !language.isEmpty, !category.isEmpty, !condition.isEmpty, referenceVerified else {
            throw EvaluationError.invalidSample(id)
        }
    }
}

public enum EvaluationError: Error, LocalizedError {
    case invalidSample(String), duplicateIDs, invalidCount
    public var errorDescription: String? {
        switch self {
        case .invalidSample(let id): "Sample \(id) needs all fields and a manually verified reference (referenceVerified: true)."
        case .duplicateIDs: "Sample IDs must be unique."
        case .invalidCount: "Use 20–30 samples for the evaluation corpus."
        }
    }
}

public enum EvaluationMetrics {
    /// Case/punctuation-insensitive proxy, not the human 'needs no corrections' gate.
    /// Whitespace tokenization is suitable for the initial English evaluation only.
    public static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let expected = words(reference), actual = words(hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
        var row = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var next = [i + 1]
            for (j, candidate) in actual.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (word == candidate ? 0 : 1)))
            }
            row = next
        }
        return Double(row[actual.count]) / Double(expected.count)
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let values = values.sorted(), middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    /// Nearest-rank percentile, including all warm runs (never cold or warm-up).
    public static func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
    }
}
