import Foundation
import NamiCore

/// Derived report; workspace.json remains the immutable run history/source of truth.
struct DebugBenchmarkReport: Encodable {
    var schemaVersion = 1
    var generatedAt = Date()
    var notes = [
        "Cloud disagreement is not accuracy. Only verified references enter quality aggregates.",
        "WER/CER use nami-words-v1 normalization; whitespace WER is intended for English, not unsegmented languages. Numbers and internal punctuation are not canonicalized.",
        "Empty verified references represent silence: inspect insertions; WER/CER are undefined.",
        "Summaries use the latest attempt per sample/model, exclude stale references/languages, and report failures separately.",
        "Compare models on paired sample IDs; different coverage and categories are not a fair ranking.",
        "Latency includes one-pass transcription (network round trip for cloud), excludes local model preparation. It is not a warmed p95 benchmark.",
        "Review numbers, names, negation, code-switching and filler removal by listening; edit distance does not measure semantic correctness."
    ]
    struct Sample: Encodable {
        var sample: DebugSample
        var audioPath: String
        var results: [Result]
        var comparisons: [Pair]
    }
    struct Result: Encodable {
        var run: DebugResult
        var stale: Bool
        var referenceStatus: String
        var analysis: TranscriptAnalysis?
        var realTimeFactor: Double?
    }
    struct Pair: Encodable {
        var localResultID: UUID
        var cloudResultID: UUID
        var localModel: String
        var sameBatch: Bool
        var disagreement: TranscriptAnalysis
        var localWERMinusCloudWER: Double?
    }
    struct Summary: Encodable {
        var model: String
        var category: String
        var attemptedSamples: Int
        var failures: Int
        var staleResults: Int
        var verifiedSamples: Int
        var sampleIDs: [UUID]
        var referenceWords: Int
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        var corpusWER: Double?
        var normalizedExactMatchRate: Double?
        var medianTranscriptionSeconds: Double?
        var observedP95TranscriptionSeconds: Double?
    }
    var samples: [Sample]
    var summaries: [Summary]

    init(workspace: DebugWorkspace, directory: URL) {
        samples = workspace.samples.map { sample in
            let runs = workspace.results.filter { $0.sampleID == sample.id }
            let results = runs.map { run in
                Result(run: run, stale: run.expectedText != sample.expectedText || run.language != sample.language || run.referenceVerified != sample.referenceVerified,
                    referenceStatus: run.referenceVerified == true ? "verified" : "unverified",
                    analysis: run.error == nil ? TranscriptAnalysis.compare(reference: run.expectedText, hypothesis: run.transcript) : nil,
                    realTimeFactor: sample.audioSeconds > 0 ? run.transcriptionSeconds / sample.audioSeconds : nil)
            }
            // Latest attempt, including failures: don't silently replace failed runs with old successes.
            let latest = Dictionary(grouping: results, by: { $0.run.model.id }).compactMap { $0.value.last }.filter { !$0.stale }
            let cloud = latest.first { $0.run.model.id == CloudTranscriber.model.id && $0.run.error == nil }
            let pairs: [Pair] = latest.compactMap { local in
                guard let cloud, local.run.model.id != cloud.run.model.id, local.run.error == nil,
                      let hash = local.run.audioSHA256, hash == cloud.run.audioSHA256 else { return nil }
                let verified = local.run.referenceVerified == true && cloud.run.referenceVerified == true
                let delta: Double?
                if verified, let l = local.analysis?.wordErrorRate, let c = cloud.analysis?.wordErrorRate { delta = l - c }
                else { delta = nil }
                return Pair(localResultID: local.run.id, cloudResultID: cloud.run.id, localModel: local.run.model.name,
                    sameBatch: local.run.batchID == cloud.run.batchID,
                    disagreement: .compare(reference: cloud.run.transcript, hypothesis: local.run.transcript),
                    localWERMinusCloudWER: delta)
            }
            return Sample(sample: sample, audioPath: directory.appendingPathComponent("Audio/\(sample.id.uuidString).wav").path,
                          results: results, comparisons: pairs.sorted { $0.localModel < $1.localModel })
        }
        var output: [Summary] = []
        let models = Set(workspace.results.map { $0.model.id }).sorted()
        for model in models {
            let categories = Set(workspace.samples.map { $0.category ?? "uncategorized" }).sorted()
            for category in ["all"] + categories.filter({ $0 != "all" }) {
                let matching = samples.filter { category == "all" || ($0.sample.category ?? "uncategorized") == category }
                let latest = matching.compactMap { $0.results.last { $0.run.model.id == model } }
                guard !latest.isEmpty else { continue }
                let valid = latest.filter { !$0.stale && $0.run.error == nil }
                let scored = valid.filter { $0.run.referenceVerified == true }
                let words = scored.reduce(0) { $0 + ($1.analysis?.referenceWords ?? 0) }
                let substitutions = scored.reduce(0) { $0 + ($1.analysis?.substitutions ?? 0) }
                let deletions = scored.reduce(0) { $0 + ($1.analysis?.deletions ?? 0) }
                let insertions = scored.reduce(0) { $0 + ($1.analysis?.insertions ?? 0) }
                let times = valid.map { $0.run.transcriptionSeconds }
                output.append(Summary(model: model, category: category, attemptedSamples: latest.count,
                    failures: latest.filter { $0.run.error != nil }.count, staleResults: latest.filter(\.stale).count,
                    verifiedSamples: scored.count, sampleIDs: scored.map { $0.run.sampleID }, referenceWords: words,
                    substitutions: substitutions, deletions: deletions, insertions: insertions,
                    corpusWER: words > 0 ? Double(substitutions + deletions + insertions) / Double(words) : nil,
                    normalizedExactMatchRate: scored.isEmpty ? nil : Double(scored.filter { $0.analysis?.normalizedMatch == true }.count) / Double(scored.count),
                    medianTranscriptionSeconds: EvaluationMetrics.median(times), observedP95TranscriptionSeconds: EvaluationMetrics.p95(times)))
            }
        }
        summaries = output
    }
}
