import Foundation
import Testing
@testable import NamiStudio

@Test func updateConfigurationRequiresHTTPSAndAnEd25519PublicKey() {
    let key = Data(repeating: 42, count: 32).base64EncodedString()
    #expect(AppUpdates.validConfiguration(feed: "https://github.com/example/app/releases/latest/download/appcast.xml", publicKey: key))
    for feed in [nil, "", "$(NAMI_UPDATE_FEED_URL)", "http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/appcast.xml"] {
        #expect(!AppUpdates.validConfiguration(feed: feed, publicKey: key))
    }
    for invalidKey in [nil, "", "not a key", Data(repeating: 42, count: 31).base64EncodedString()] {
        #expect(!AppUpdates.validConfiguration(feed: "https://example.com/appcast.xml", publicKey: invalidKey))
    }
}

@Test @MainActor func updateInstallationWaitsForWorkToFinishAndResumesOnlyOnce() {
    var busy = true
    var installations = 0
    let updates = AppUpdates(disabled: true, isBusy: { busy })
    #expect(updates.postponeInstallation { installations += 1 })
    #expect(updates.waitingToInstall)
    #expect(!updates.resumeInstallationIfIdle())
    #expect(installations == 0)
    busy = false
    #expect(updates.resumeInstallationIfIdle())
    #expect(installations == 1)
    #expect(!updates.waitingToInstall)
    #expect(!updates.resumeInstallationIfIdle())
    #expect(installations == 1)
}

@Test @MainActor func idleUpdateInstallationDoesNotDelaySparkleOrInvokeItsHandler() {
    let updates = AppUpdates(disabled: true, isBusy: { false })
    var called = false
    #expect(!updates.postponeInstallation { called = true })
    #expect(!called)
    #expect(!updates.waitingToInstall)
}

@Test @MainActor func previewsNeverStartAnUpdater() {
    let updates = AppUpdates(disabled: true, isBusy: { false })
    updates.setAutomaticallyChecks(true)
    updates.checkForUpdates()
    #expect(!updates.available)
    #expect(!updates.canCheckForUpdates)
    #expect(!updates.automaticallyChecks)
}

@Test @MainActor func sparkleCanCallTheRecordingSafetyDelegates() {
    let updates = AppUpdates(disabled: true, isBusy: { false })
    #expect(updates.responds(to: NSSelectorFromString("updater:mayPerformUpdateCheck:error:")))
    #expect(updates.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")))
    #expect(updates.responds(to: NSSelectorFromString("updater:didAbortWithError:")))
}
