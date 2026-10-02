import Foundation

/// Word differences mapped back to the original text, preserving punctuation and spacing.
public struct TranscriptDifference {
    public var local: [Range<String.Index>]
    public var cloud: [Range<String.Index>]

    public static func compare(local: String, cloud: String) -> Self {
        func tokens(_ text: String) -> [(word: String, range: Range<String.Index>)] {
            text.split(whereSeparator: \.isWhitespace).compactMap { token in
                guard let word = EvaluationMetrics.words(String(token)).first else { return nil }
                return (word, token.startIndex..<token.endIndex)
            }
        }
        let a = tokens(local), b = tokens(cloud)
        let changes = b.map(\.word).difference(from: a.map(\.word))
        var localRanges: [Range<String.Index>] = [], cloudRanges: [Range<String.Index>] = []
        for change in changes {
            switch change {
            case .remove(let offset, _, _): localRanges.append(a[offset].range)
            case .insert(let offset, _, _): cloudRanges.append(b[offset].range)
            }
        }
        return Self(local: localRanges, cloud: cloudRanges)
    }
}
