import Foundation
import Security
import Testing
@testable import NamiStudio

@MainActor private final class FixtureKeyStore {
    var key: String?
    var writes = 0
    var fail = false
    var store: ComparisonAPIKeyStore {
        ComparisonAPIKeyStore(load: { self.key }, save: {
            if self.fail { throw StudioError.message("Fixture storage failure") }
            self.key = $0
            self.writes += 1
        })
    }
}

@Test @MainActor func comparisonAPIKeySurvivesSessionRecreation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = FixtureKeyStore()
    let session = DebuggingSession(directory: directory, apiKeyStore: credentials.store, environmentAPIKey: "")
    session.cloudAPIKey = "comparison-settings-fixture"
    let restored = DebuggingSession(directory: directory, apiKeyStore: credentials.store, environmentAPIKey: "environment")
    #expect(restored.cloudAPIKey == "comparison-settings-fixture")
    #expect(credentials.writes == 1)
    restored.cloudAPIKey = "replacement-fixture"
    let replaced = DebuggingSession(directory: directory, apiKeyStore: credentials.store, environmentAPIKey: "")
    #expect(replaced.cloudAPIKey == "replacement-fixture")
    replaced.cloudAPIKey = ""
    let cleared = DebuggingSession(directory: directory, apiKeyStore: credentials.store, environmentAPIKey: "environment")
    #expect(cleared.cloudAPIKey.isEmpty)
    #expect(credentials.writes == 3)
    session.save()
    let metadata = try String(contentsOf: DebuggingStore(directory: directory).metadataURL, encoding: .utf8)
    #expect(!metadata.contains("comparison-settings-fixture"))
}

@Test @MainActor func comparisonModelSurvivesSessionRecreationAndHandlesRemoval() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = DebuggingSession(directory: directory, environmentAPIKey: "")
    session.addModel(folder: URL(fileURLWithPath: "/models/first"))
    session.addModel(folder: URL(fileURLWithPath: "/models/second"))
    let chosen = try #require(session.workspace.models.last)
    session.setModelEnabled(chosen.id, enabled: false)
    session.selectComparisonModel(chosen.id)
    let restored = DebuggingSession(directory: directory, environmentAPIKey: "")
    #expect(restored.comparisonModel?.id == chosen.id)
    restored.removeModel(chosen.id)
    let afterRemoval = DebuggingSession(directory: directory, environmentAPIKey: "")
    #expect(afterRemoval.comparisonModel?.id == session.workspace.models.first?.id)
}

@Test @MainActor func comparisonSettingsLoadLegacyWorkspaceAndEnvironmentWithoutSavingKey() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"samples":[],"models":[],"results":[]}"#.utf8)
        .write(to: DebuggingStore(directory: directory).metadataURL)
    let credentials = FixtureKeyStore()
    let session = DebuggingSession(directory: directory, apiKeyStore: credentials.store, environmentAPIKey: "environment")
    #expect(!session.loadFailed)
    #expect(session.comparisonModel == nil)
    #expect(session.cloudAPIKey == "environment")
    #expect(credentials.writes == 0)
}

@Test @MainActor func comparisonKeySaveFailureIsVisibleAndRetryable() {
    let credentials = FixtureKeyStore()
    credentials.fail = true
    let session = DebuggingSession(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        apiKeyStore: credentials.store, environmentAPIKey: "")
    session.cloudAPIKey = "unsaved-fixture"
    #expect(session.cloudAPIKeyError?.contains("could not be saved") == true)
    #expect(session.cloudAPIKey == "unsaved-fixture")
    #expect(credentials.key == nil)
    credentials.fail = false
    session.saveCloudAPIKey()
    #expect(session.cloudAPIKeyError == nil)
    #expect(credentials.key == "unsaved-fixture")
}

@Test @MainActor func comparisonKeyLoadFailureIsVisible() {
    let store = ComparisonAPIKeyStore(load: { throw StudioError.message("Fixture read failure") }, save: { _ in })
    let session = DebuggingSession(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        apiKeyStore: store, environmentAPIKey: "environment")
    #expect(session.cloudAPIKeyError?.contains("Could not load") == true)
    #expect(session.cloudAPIKey == "environment")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_KEYCHAIN_TESTS"] == "1"))
@MainActor func comparisonKeychainStoresReplacesAndClearsCredentials() throws {
    let account = "nami-comparison-test-\(UUID().uuidString)"
    defer {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.nami.studio.elevenlabs",
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        #expect(status == errSecSuccess || status == errSecItemNotFound)
    }
    let store = ComparisonAPIKeyStore.keychain(account: account)
    #expect(try store.load() == nil)
    try store.save("original-fixture")
    #expect(try ComparisonAPIKeyStore.keychain(account: account).load() == "original-fixture")
    try store.save("replacement-fixture")
    #expect(try ComparisonAPIKeyStore.keychain(account: account).load() == "replacement-fixture")
    try store.save("")
    #expect(try ComparisonAPIKeyStore.keychain(account: account).load() == "")
}
