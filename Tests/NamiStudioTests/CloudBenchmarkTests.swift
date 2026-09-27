import Foundation
import Testing
import NamiCore
@testable import NamiStudio

private func fixtureCloud() -> CloudTranscriber {
    CloudTranscriber(transport: { request in
        #expect(request.url?.host == "api.elevenlabs.io")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "test-secret")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("scribe_v2"))
        #expect(body.contains("no_verbatim"))
        #expect(!body.contains("Expected secret"))
        return (Data(#"{"text":"please do not deploy","language_code":"en","words":[{"text":"please","start":0,"end":0.3,"type":"word"}]}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
}

@Test @MainActor func cloudComparisonPersistsPairsAndVerifiedScores() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DebuggingStore(directory: directory)
    let sample = DebugSample(title: "Negation", expectedText: "please do not deploy", audioSeconds: 1,
                             source: "test", referenceVerified: true, category: "negation")
    try store.saveAudio(Array(repeating: 0.1, count: 16000), id: sample.id)
    try store.save(DebugWorkspace(samples: [sample], models: [DebugModel(name: "local", folder: "/fake")]))
    let lab = DebuggingSession(directory: directory, engineBuilder: { _ in FakeTranscriptionEngine(transcript: "please do deploy") }, cloudTranscriber: fixtureCloud())
    lab.cloudAPIKey = "test-secret"
    lab.runCloudComparison()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!lab.isBusy)
    #expect(lab.workspace.results.count == 2)
    #expect(lab.workspace.results.first?.cloudResponse?.words?.count == 1)
    let report = DebugBenchmarkReport(workspace: lab.workspace, directory: directory)
    #expect(report.samples[0].comparisons.count == 1)
    #expect(report.samples[0].comparisons[0].localWERMinusCloudWER == 0.25)
    #expect(report.samples[0].comparisons[0].disagreement.edits.first?.reference == "not")
    #expect(report.summaries.first { $0.model == "/fake" && $0.category == "all" }?.corpusWER == 0.25)
    let export = try Data(contentsOf: lab.exportBenchmark())
    #expect(!String(decoding: export, as: UTF8.self).contains("test-secret"))
    let restored = DebuggingSession(directory: directory)
    #expect(restored.workspace.results.count == 2)
    lab.updateSample(sample.id, expectedText: "changed")
    let stale = DebugBenchmarkReport(workspace: lab.workspace, directory: directory)
    #expect(stale.samples[0].comparisons.isEmpty)
    #expect(stale.summaries.allSatisfy { $0.verifiedSamples == 0 })
}

@Test @MainActor func cloudHTTPFailureDoesNotLeakResponse() async throws {
    let cloud = CloudTranscriber(transport: { request in
        (Data("test-secret echoed".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    })
    do {
        _ = try await cloud.transcribe(audio: Data(), language: "auto", apiKey: "test-secret")
        Issue.record("Expected HTTP failure")
    } catch {
        #expect(error.localizedDescription.contains("401"))
        #expect(!error.localizedDescription.contains("test-secret"))
    }
}

@Test @MainActor func benchmarkStoreRejectsConcurrentOverwrite() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = DebuggingStore(directory: directory), second = DebuggingStore(directory: directory)
    _ = try first.load(); _ = try second.load()
    try first.save(DebugWorkspace())
    #expect(throws: (any Error).self) { try second.save(DebugWorkspace()) }
}

@Test @MainActor func cliRequiresExplicitPaidBatchAndRejectsUnknownSamples() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DebuggingStore(directory: directory)
    try store.save(DebugWorkspace(samples: [DebugSample(title: "sample", audioSeconds: 1, source: "test")]))
    do {
        _ = try await DebugBenchmarkCLI.run(["run", "--all", "--cloud", "--workspace", directory.path])
        Issue.record("Expected approval failure")
    } catch { #expect(error.localizedDescription.contains("--allow-cloud")) }
    do {
        _ = try await DebugBenchmarkCLI.run(["run", "--sample", UUID().uuidString, "--workspace", directory.path])
        Issue.record("Expected missing sample failure")
    } catch { #expect(error.localizedDescription.contains("Unknown sample")) }
}

@Test @MainActor func benchmarkUsesLatestAttemptAndWeightsByWordCount() {
    let directory = URL(fileURLWithPath: "/fixture")
    let a = DebugSample(title: "Short", expectedText: "one", audioSeconds: 1, source: "test", referenceVerified: true)
    let b = DebugSample(title: "Long", expectedText: "one two three four five six seven eight nine", audioSeconds: 3, source: "test", referenceVerified: true)
    let model = DebugModel(name: "local", folder: "/local")
    func result(_ sample: DebugSample, _ transcript: String, error: String? = nil) -> DebugResult {
        DebugResult(batchID: UUID(), sampleID: sample.id, model: model, expectedText: sample.expectedText,
            language: "en", transcript: transcript, preparationSeconds: 0, transcriptionSeconds: 1,
            error: error, referenceVerified: true)
    }
    var workspace = DebugWorkspace(samples: [a,b], results: [result(a, "wrong"), result(b, b.expectedText)])
    let weighted = DebugBenchmarkReport(workspace: workspace, directory: directory)
    #expect(weighted.summaries.first?.corpusWER == 0.1) // Not the misleading per-sample average, 0.5.
    workspace.results.append(result(a, "", error: "Failed"))
    let failed = DebugBenchmarkReport(workspace: workspace, directory: directory)
    #expect(failed.summaries.first?.failures == 1)
    #expect(failed.summaries.first?.verifiedSamples == 1)
    #expect(failed.summaries.first?.sampleIDs == [b.id])
}

@Test @MainActor func cloudCancellationDiscardsLateResponse() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DebuggingStore(directory: directory)
    let sample = DebugSample(title: "Cancel", audioSeconds: 1, source: "test")
    try store.saveAudio(Array(repeating: 0.1, count: 16000), id: sample.id)
    try store.save(DebugWorkspace(samples: [sample]))
    let cloud = CloudTranscriber(transport: { request in
        try? await Task.sleep(for: .milliseconds(150))
        return (Data(#"{"text":"late result"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let lab = DebuggingSession(directory: directory, cloudTranscriber: cloud)
    lab.cloudAPIKey = "fixture"
    lab.runCloudComparison()
    try await Task.sleep(for: .milliseconds(30))
    lab.cancel()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!lab.isBusy)
    #expect(lab.workspace.results.isEmpty)
}

@Test @MainActor func failedCloudAttemptStillRunsLocalModel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DebuggingStore(directory: directory)
    let sample = DebugSample(title: "Failure", audioSeconds: 1, source: "test")
    try store.saveAudio(Array(repeating: 0.1, count: 16000), id: sample.id)
    try store.save(DebugWorkspace(samples: [sample], models: [DebugModel(name: "local", folder: "/fake")]))
    let cloud = CloudTranscriber(transport: { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
    })
    let lab = DebuggingSession(directory: directory, engineBuilder: { _ in FakeTranscriptionEngine(transcript: "local result") }, cloudTranscriber: cloud)
    lab.cloudAPIKey = "fixture"
    lab.runCloudComparison()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!lab.isBusy)
    #expect(lab.workspace.results.count == 2)
    #expect(lab.workspace.results.first?.error?.contains("429") == true)
    #expect(lab.workspace.results.last?.transcript == "local result")
}

@Test @MainActor func comparisonRunsOnlyChosenModelAndPairsCurrentBatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DebuggingStore(directory: directory)
    let sample = DebugSample(title: "Selection", audioSeconds: 1, source: "test")
    let first = DebugModel(name: "first", folder: "/first")
    let chosen = DebugModel(name: "chosen", folder: "/chosen", enabled: false)
    try store.saveAudio(Array(repeating: 0.1, count: 16000), id: sample.id)
    try store.save(DebugWorkspace(samples: [sample], models: [first, chosen]))
    var built: [String] = []
    let lab = DebuggingSession(directory: directory, engineBuilder: { folder in
        built.append(folder)
        return FakeTranscriptionEngine(transcript: "please deploy")
    }, cloudTranscriber: fixtureCloud())
    lab.cloudAPIKey = "test-secret"
    lab.runCloudComparison(localModelID: chosen.id)
    #expect(lab.activeComparisonBatchID != nil)
    #expect(lab.comparisonResults(localModelID: chosen.id).local == nil)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!lab.isBusy)
    #expect(built == [chosen.id])
    let pair = lab.comparisonResults(localModelID: chosen.id)
    #expect(pair.local?.transcript == "please deploy")
    #expect(pair.cloud?.transcript == "please do not deploy")
    #expect(pair.local?.batchID == pair.cloud?.batchID)
    #expect(pair.local?.audioSHA256 == pair.cloud?.audioSHA256)
    #expect(lab.comparisonResults(localModelID: first.id).local == nil)
    lab.updateSample(sample.id, language: "auto")
    #expect(lab.comparisonResults(localModelID: chosen.id).cloud == nil)
    #expect(lab.comparisonResults(localModelID: chosen.id).local == nil)
}

@Test @MainActor func comparisonNeverFillsMissingOrFailedResultsFromOlderBatches() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DebuggingStore(directory: directory)
    let sample = DebugSample(title: "Rerun", audioSeconds: 1, source: "test")
    let model = DebugModel(name: "local", folder: "/local")
    let oldBatch = UUID(), newBatch = UUID()
    func result(_ model: DebugModel, _ batch: UUID, error: String? = nil) -> DebugResult {
        DebugResult(batchID: batch, sampleID: sample.id, model: model, expectedText: "", language: "en",
                    transcript: "old text", preparationSeconds: 0, transcriptionSeconds: 1, error: error)
    }
    var workspace = DebugWorkspace(samples: [sample], models: [model], results: [
        result(CloudTranscriber.model, oldBatch), result(model, oldBatch),
        result(CloudTranscriber.model, newBatch, error: "Request failed")
    ])
    try store.save(workspace)
    let lab = DebuggingSession(directory: directory)
    let pair = lab.comparisonResults(localModelID: model.id)
    #expect(pair.local == nil)
    #expect(pair.cloud?.error == "Request failed")
    workspace.results.append(result(model, newBatch, error: "Model failed"))
    try store.save(workspace)
    let restored = DebuggingSession(directory: directory)
    #expect(restored.comparisonResults(localModelID: model.id).local?.error == "Model failed")
    #expect(restored.comparisonResults(localModelID: model.id).cloud?.error == "Request failed")
}
