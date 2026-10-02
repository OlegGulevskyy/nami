import Foundation

/// Streaming diagnostics; stores no audio and makes no speech-detection claim.
public struct AudioStatistics: Sendable {
    public private(set) var sampleCount = 0
    public private(set) var peak: Double = 0
    private var sumSquares: Double = 0
    public init() {}

    public mutating func append(_ samples: [Float]) {
        sampleCount += samples.count
        for sample in samples {
            let value = Double(sample)
            peak = max(peak, abs(value))
            sumSquares += value * value
        }
    }

    public var duration: Double { Double(sampleCount) / AudioChunk.sampleRate }
    public var rmsDBFS: Double {
        guard sampleCount > 0, sumSquares > 0 else { return -.infinity }
        return 10 * log10(sumSquares / Double(sampleCount))
    }
    public var peakDBFS: Double { peak > 0 ? 20 * log10(peak) : -.infinity }
}
