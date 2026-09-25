import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation

/// Reads macOS authorization on every launch; never persists an onboarding flag.
@MainActor @Observable
public final class StudioPermissions {
    public enum Pane: String {
        case microphone = "Privacy_Microphone", inputMonitoring = "Privacy_ListenEvent", accessibility = "Privacy_Accessibility"

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            }
        }
    }

    public private(set) var microphone: AVAuthorizationStatus = .notDetermined
    public private(set) var inputMonitoring = false
    public private(set) var accessibility = false
    public private(set) var requestingMicrophone = false
    public private(set) var settingsError: String?
    public var needsSetup: Bool { microphone != .authorized || !inputMonitoring }

    @ObservationIgnored private let microphoneStatus: @MainActor () -> AVAuthorizationStatus
    @ObservationIgnored private let inputMonitoringStatus: @MainActor () -> Bool
    @ObservationIgnored private let accessibilityStatus: @MainActor () -> Bool
    @ObservationIgnored private let requestAccessibility: @MainActor () -> Bool
    @ObservationIgnored private let requestMicrophone: @MainActor () async -> Bool
    @ObservationIgnored private let requestInputMonitoring: @MainActor () -> Bool
    @ObservationIgnored private let openSettings: @MainActor (Pane) -> Bool

    public init(
        microphoneStatus: @escaping @MainActor () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        inputMonitoringStatus: @escaping @MainActor () -> Bool = { CGPreflightListenEventAccess() },
        accessibilityStatus: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        requestAccessibility: @escaping @MainActor () -> Bool = {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        },
        requestMicrophone: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
        requestInputMonitoring: @escaping @MainActor () -> Bool = { CGRequestListenEventAccess() },
        openSettings: @escaping @MainActor (Pane) -> Bool = { pane in
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return false }
            return NSWorkspace.shared.open(url)
        }
    ) {
        self.microphoneStatus = microphoneStatus
        self.inputMonitoringStatus = inputMonitoringStatus
        self.accessibilityStatus = accessibilityStatus
        self.requestAccessibility = requestAccessibility
        self.requestMicrophone = requestMicrophone
        self.requestInputMonitoring = requestInputMonitoring
        self.openSettings = openSettings
        refresh()
    }

    public func refresh() {
        microphone = microphoneStatus()
        inputMonitoring = inputMonitoringStatus()
        accessibility = accessibilityStatus()
    }

    public func resolveMicrophone() async {
        guard !requestingMicrophone else { return }
        refresh()
        settingsError = nil
        switch microphone {
        case .notDetermined:
            requestingMicrophone = true
            defer { requestingMicrophone = false }
            _ = await requestMicrophone()
            refresh()
        case .authorized: break
        default: showSettings(.microphone)
        }
    }

    public func resolveInputMonitoring() {
        guard !requestingMicrophone else { return }
        refresh()
        settingsError = nil
        guard !inputMonitoring else { return }
        _ = requestInputMonitoring()
        refresh()
        if !inputMonitoring { showSettings(.inputMonitoring) }
    }

    public func resolveAccessibility() {
        guard !requestingMicrophone else { return }
        refresh()
        settingsError = nil
        guard !accessibility else { return }
        _ = requestAccessibility()
        refresh()
        if !accessibility { showSettings(.accessibility) }
    }

    public func showSettings(_ pane: Pane) {
        guard !requestingMicrophone else { return }
        settingsError = nil
        if !openSettings(pane) {
            settingsError = "Open System Settings → Privacy & Security, then choose \(pane.title) to change Nami’s access."
        }
    }
}
