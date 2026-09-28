import Foundation
import Testing
import NamiCore
import NamiMLXCleanup

private func assetTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nami-assets-test-\(UUID())")
}
private func fakeDownload(_ url: URL, model: QwenModel) throws -> (URL, URLResponse) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("nami-download-\(UUID())")
    try Data("{}".utf8).write(to: file)
    if url.lastPathComponent == "model.safetensors" {
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(model.weightBytes)) // Sparse fixture; no real weights/download.
        try handle.close()
    }
    return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

@Test func qwenModelsInstallIndependentlyAndDeletionPreservesOtherData() async throws {
    let root = assetTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(QwenModel.qwen06.processorID != QwenModel.qwen17.processorID)
    #expect(CleanupEngine.title(for: QwenModel.qwen17.processorID) == CleanupEngine.qwen17.title)
    for model in QwenModel.allCases {
        let folder = QwenModelAssets.directory(for: model, root: root)
        #expect(!QwenModelAssets.isInstalled(model, at: folder))
        try await QwenModelAssets.download(model, to: folder, fetch: { try fakeDownload($0, model: model) })
        #expect(QwenModelAssets.isInstalled(model, at: folder))
        #expect(!QwenModelAssets.isInstalled(model == .qwen06 ? .qwen17 : .qwen06, at: folder))
        // An installed model is reused without network requests.
        try await QwenModelAssets.download(model, to: folder, fetch: { _ in throw CancellationError() })
    }
    let history = root.appendingPathComponent("recording.txt")
    try Data("keep me".utf8).write(to: history)
    try QwenModelAssets.remove(.qwen06, root: root)
    #expect(!FileManager.default.fileExists(atPath: QwenModelAssets.directory(for: .qwen06, root: root).path))
    #expect(QwenModelAssets.isInstalled(.qwen17, at: QwenModelAssets.directory(for: .qwen17, root: root)))
    #expect(try String(contentsOf: history, encoding: .utf8) == "keep me")
    let larger = QwenModelAssets.directory(for: .qwen17, root: root)
    try Data().write(to: larger.appendingPathComponent("tokenizer.json"))
    #expect(!QwenModelAssets.isInstalled(.qwen17, at: larger))
    try QwenModelAssets.remove(.qwen17, root: root) // Incomplete installs can also be removed.
    #expect(FileManager.default.fileExists(atPath: history.path))
}

@Test func qwenCancelledDownloadCleansStagingAndCanRetry() async throws {
    let root = assetTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = QwenModel.qwen17
    let folder = QwenModelAssets.directory(for: model, root: root)
    await #expect(throws: CancellationError.self) {
        try await QwenModelAssets.download(model, to: folder, fetch: {
            if $0.lastPathComponent == "tokenizer.json" { throw CancellationError() }
            return try fakeDownload($0, model: model)
        })
    }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    try await QwenModelAssets.download(model, to: folder, fetch: { try fakeDownload($0, model: model) })
    #expect(QwenModelAssets.isInstalled(model, at: folder))
}

@Test func qwenDeletionRefusesSymlinkOutsideModelStorage() throws {
    let root = assetTestRoot(), external = assetTestRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: external.appendingPathComponent("weights"))
    try FileManager.default.createSymbolicLink(at: QwenModelAssets.directory(for: .qwen17, root: root), withDestinationURL: external)
    #expect(throws: (any Error).self) { try QwenModelAssets.remove(.qwen17, root: root) }
    #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("weights").path))
}
