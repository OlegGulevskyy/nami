import SwiftUI

struct PermissionSetupView: View {
    @Bindable var permissions: StudioPermissions
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 23, weight: .regular)).foregroundStyle(StudioStyle.quiet)
                    Text("Permissions")
                        .font(.system(size: 25, weight: .medium)).tracking(-0.5)
                        .accessibilityAddTraits(.isHeader)
                }
                Text("Allow Nami to record and paste into your apps.")
                    .font(.system(size: 14)).foregroundStyle(StudioStyle.quiet)
            }

            VStack(spacing: 18) {
                permissionRow("Microphone", icon: "mic", detail: microphoneDetail,
                              granted: permissions.microphone == .authorized) {
                    if permissions.microphone != .restricted {
                        Button(permissions.requestingMicrophone ? "Waiting…" :
                                permissions.microphone == .notDetermined ? "Allow…" : "Open Settings…") {
                            Task { await permissions.resolveMicrophone(); recheck() }
                        }
                        .accessibilityLabel("Allow Microphone")
                    }
                }
                StudioStyle.divider
                permissionRow("Input Monitoring", icon: "keyboard",
                              detail: "Use recording shortcuts in other apps.",
                              granted: permissions.inputMonitoring) {
                    Button("Allow…") {
                        permissions.resolveInputMonitoring()
                        recheck()
                    }
                    .accessibilityLabel("Allow Input Monitoring")
                }
                StudioStyle.divider
                permissionRow("Accessibility", icon: "hand.point.up.left",
                              detail: "Paste transcripts automatically into your text field.",
                              granted: permissions.accessibility) {
                    Button("Allow…") {
                        permissions.resolveAccessibility()
                        recheck()
                    }
                    .accessibilityLabel("Allow Accessibility")
                }
            }
            .buttonStyle(.borderedProminent).tint(StudioStyle.accentFill).controlSize(.regular)
            .disabled(permissions.requestingMicrophone)

            Text("Enable Nami in System Settings → Privacy & Security. Follow any restart prompt from macOS.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true)

            if let error = permissions.settingsError {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                DisclosureGroup("Access still missing?") {
                    Text("Switch Nami off and on in System Settings, then quit and reopen Nami.")
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                Spacer(minLength: 0)
                Button("Check again", action: recheck)
                    .disabled(permissions.requestingMicrophone)
            }
        }
        .padding(30).frame(width: 520)
        .foregroundStyle(StudioStyle.ink)
        .setupCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permissions required")
    }

    private var microphoneDetail: String {
        switch permissions.microphone {
        case .authorized: ""
        case .denied: "Microphone access is off. Enable Nami in System Settings."
        case .restricted: "Microphone access is restricted on this Mac. Ask your administrator to allow it."
        default: "Record your voice."
        }
    }

    private func permissionRow<Action: View>(_ title: String, icon: String, detail: String,
                                            granted: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 24, height: 24)
                .foregroundStyle(StudioStyle.quiet)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .medium))
                if !granted {
                    Text(detail).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    .fixedSize()
            } else {
                action().fixedSize()
            }
        }
    }
}

private extension View {
    func setupCard() -> some View {
        background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioStyle.line))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }
}
