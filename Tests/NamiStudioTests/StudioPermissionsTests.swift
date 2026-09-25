import AVFoundation
import Testing
@testable import NamiStudio

@MainActor private final class PermissionSystem {
    var microphone: AVAuthorizationStatus = .notDetermined
    var inputMonitoring = false
    var accessibility = false
    var microphoneRequests = 0
    var inputRequests = 0
    var accessibilityRequests = 0
    var grantMicrophone = false
    var grantInput = false
    var canOpenSettings = true
    var opened: [StudioPermissions.Pane] = []

    func permissions() -> StudioPermissions {
        StudioPermissions(microphoneStatus: { self.microphone }, inputMonitoringStatus: { self.inputMonitoring },
            accessibilityStatus: { self.accessibility }, requestAccessibility: {
                self.accessibilityRequests += 1
                return self.accessibility
            },
            requestMicrophone: {
                self.microphoneRequests += 1
                self.microphone = self.grantMicrophone ? .authorized : .denied
                return self.grantMicrophone
            }, requestInputMonitoring: {
                self.inputRequests += 1
                self.inputMonitoring = self.grantInput
                return self.grantInput
            }, openSettings: {
                self.opened.append($0)
                return self.canOpenSettings
            })
    }
}

@Test @MainActor func accessibilityIsOptionalAndRequestedOnlyFromUserAction() {
    let system = PermissionSystem()
    system.microphone = .authorized
    system.inputMonitoring = true
    let permissions = system.permissions()
    #expect(!permissions.needsSetup)
    #expect(!permissions.accessibility)
    #expect(system.accessibilityRequests == 0)
    permissions.resolveAccessibility()
    #expect(system.accessibilityRequests == 1)
    #expect(system.opened == [.accessibility])
    system.accessibility = true
    permissions.refresh()
    #expect(permissions.accessibility)
    permissions.resolveAccessibility()
    #expect(system.accessibilityRequests == 1)
    system.accessibility = false
    system.canOpenSettings = false
    permissions.resolveAccessibility()
    #expect(permissions.settingsError?.contains("Accessibility") == true)
    #expect(!permissions.needsSetup)
}

@Test @MainActor func firstLaunchChecksWithoutPromptingAndRequiresBothPermissions() async {
    let system = PermissionSystem()
    let permissions = system.permissions()
    #expect(permissions.needsSetup)
    #expect(system.microphoneRequests == 0 && system.inputRequests == 0)
    system.grantMicrophone = true
    await permissions.resolveMicrophone()
    #expect(system.microphoneRequests == 1)
    #expect(permissions.microphone == .authorized)
    #expect(permissions.needsSetup)
    system.grantInput = true
    permissions.resolveInputMonitoring()
    #expect(system.inputRequests == 1)
    #expect(!permissions.needsSetup)
    #expect(system.opened.isEmpty)
    await permissions.resolveMicrophone()
    permissions.resolveInputMonitoring()
    #expect(system.microphoneRequests == 1 && system.inputRequests == 1)
}

@Test @MainActor func deniedMicrophoneOffersSettingsAndDetectsRecoveryAndRevocation() async {
    let system = PermissionSystem()
    system.inputMonitoring = true
    let permissions = system.permissions()
    await permissions.resolveMicrophone()
    #expect(permissions.microphone == .denied && permissions.needsSetup)
    #expect(!permissions.requestingMicrophone)
    await permissions.resolveMicrophone()
    #expect(system.microphoneRequests == 1)
    #expect(system.opened == [.microphone])
    system.microphone = .authorized
    permissions.refresh()
    #expect(!permissions.needsSetup)
    system.inputMonitoring = false
    permissions.refresh()
    #expect(permissions.needsSetup)
    system.inputMonitoring = true
    system.microphone = .denied
    permissions.refresh()
    #expect(permissions.needsSetup)
}

@Test @MainActor func restrictedMicrophoneAndDeniedInputMonitoringStayBlocked() async {
    let system = PermissionSystem()
    system.microphone = .restricted
    system.canOpenSettings = false
    let permissions = system.permissions()
    await permissions.resolveMicrophone()
    #expect(system.microphoneRequests == 0)
    #expect(permissions.settingsError?.contains("Microphone") == true)
    permissions.resolveInputMonitoring()
    #expect(system.inputRequests == 1)
    #expect(system.opened == [.microphone, .inputMonitoring])
    #expect(permissions.settingsError?.contains("Input Monitoring") == true)
    #expect(permissions.needsSetup)
    system.inputMonitoring = true
    permissions.refresh()
    #expect(permissions.needsSetup)
}

@Test @MainActor func repeatedClicksDoNotStartCompetingPermissionRequests() async throws {
    var completion: CheckedContinuation<Bool, Never>?
    var requests = 0
    let permissions = StudioPermissions(microphoneStatus: { .notDetermined }, inputMonitoringStatus: { false },
        requestMicrophone: {
            requests += 1
            return await withCheckedContinuation { completion = $0 }
        }, requestInputMonitoring: { Issue.record("Input request must wait for the microphone dialog"); return false },
        openSettings: { _ in Issue.record("Settings must not open during a microphone request"); return false })
    let request = Task { await permissions.resolveMicrophone() }
    while completion == nil { await Task.yield() }
    #expect(permissions.requestingMicrophone)
    await permissions.resolveMicrophone()
    permissions.resolveInputMonitoring()
    permissions.showSettings(.microphone)
    #expect(requests == 1)
    completion?.resume(returning: false)
    await request.value
    #expect(!permissions.requestingMicrophone)
}

@Test @MainActor func grantedPermissionsCanBeManagedWithoutRequestingAccessAgain() {
    let system = PermissionSystem()
    system.microphone = .authorized
    system.inputMonitoring = true
    system.accessibility = true
    let permissions = system.permissions()

    permissions.showSettings(.microphone)
    permissions.showSettings(.inputMonitoring)
    permissions.showSettings(.accessibility)

    #expect(system.opened == [.microphone, .inputMonitoring, .accessibility])
    #expect(system.microphoneRequests == 0 && system.inputRequests == 0 && system.accessibilityRequests == 0)
    #expect(permissions.microphone == .authorized && permissions.inputMonitoring && permissions.accessibility)

    system.microphone = .denied
    system.inputMonitoring = false
    system.accessibility = false
    permissions.refresh()
    #expect(permissions.needsSetup && !permissions.accessibility)

    system.microphone = .authorized
    system.inputMonitoring = true
    system.accessibility = true
    permissions.refresh()
    #expect(!permissions.needsSetup && permissions.accessibility)
}

@Test @MainActor func successfulManageActionClearsAnEarlierSettingsError() {
    let system = PermissionSystem()
    let permissions = system.permissions()
    system.canOpenSettings = false
    permissions.showSettings(.microphone)
    #expect(permissions.settingsError?.contains("Microphone") == true)

    system.canOpenSettings = true
    permissions.showSettings(.accessibility)
    #expect(permissions.settingsError == nil)
    #expect(system.opened == [.microphone, .accessibility])
}
