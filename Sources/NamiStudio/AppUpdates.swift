import Combine
import Foundation
import Observation
import Sparkle

/// Owns the single updater for the lifetime of the application.
@MainActor @Observable
public final class AppUpdates: NSObject, SPUUpdaterDelegate {
    public private(set) var available = false
    public private(set) var canCheckForUpdates = false
    public private(set) var automaticallyChecks = false
    public private(set) var status: String?
    public private(set) var waitingToInstall = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private var installation: (() -> Void)?
    @ObservationIgnored private var installationTask: Task<Void, Never>?

    public init(bundle: Bundle = .main, disabled: Bool = false,
                isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
        super.init()
        guard !disabled else {
            status = "Updates are unavailable in preview mode."
            return
        }
        guard bundle.bundleURL.pathExtension == "app",
              Self.validConfiguration(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                      publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) else {
            status = "Updates are not configured for this build."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            available = true
            controller.updater.publisher(for: \.canCheckForUpdates)
                .sink { [weak self] value in
                    Task { @MainActor [weak self] in self?.canCheckForUpdates = value }
                }.store(in: &subscriptions)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .sink { [weak self] value in
                    Task { @MainActor [weak self] in self?.automaticallyChecks = value }
                }.store(in: &subscriptions)
        } catch {
            status = "Could not start updates: \(error.localizedDescription)"
        }
    }

    nonisolated static func validConfiguration(feed: String?, publicKey: String?) -> Bool {
        guard let feed, let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty, !feed.contains("$("),
              url.user == nil, url.password == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }

    public func checkForUpdates() {
        guard available, canCheckForUpdates else { return }
        status = nil
        controller?.checkForUpdates(nil)
    }

    public func setAutomaticallyChecks(_ enabled: Bool) {
        guard available else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = enabled
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isBusy() {
            throw NSError(domain: "NamiUpdates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Finish recording or transcription before checking for updates."])
        }
    }

    public func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                        untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation(installHandler)
    }

    // Recheck at installation time: a recording can start after the update check.
    // Keep the handler on the main actor and invoke it exactly once, once idle.
    func postponeInstallation(_ handler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        installationTask?.cancel()
        installation = handler
        waitingToInstall = true
        status = "Update ready. Nami will restart when the current task finishes."
        installationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                if self.resumeInstallationIfIdle() { return }
            }
        }
        return true
    }

    @discardableResult func resumeInstallationIfIdle() -> Bool {
        guard !isBusy(), let handler = installation else { return false }
        installation = nil
        waitingToInstall = false
        status = nil
        handler()
        return true
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationTask?.cancel()
        installationTask = nil
        installation = nil
        if waitingToInstall { status = nil }
        waitingToInstall = false
        // Sparkle presents errors and "up to date" results for manual checks.
    }
}
