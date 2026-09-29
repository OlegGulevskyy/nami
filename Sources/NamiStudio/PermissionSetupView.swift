import SwiftUI

struct PermissionSetupView: View {
    @Bindable var permissions: StudioPermissions
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "lock.open")
                    .font(.system(size: 25, weight: .light)).foregroundStyle(StudioStyle.green)
                Text("A little setup, then your words.")
                    .font(.system(size: 25, weight: .medium)).tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
                Text("Allow these two permissions to start using Nami.")
                    .font(.system(size: 14)).foregroundStyle(StudioStyle.quiet)
            }

            VStack(spacing: 18) {
                permissionRow("Microphone", icon: "mic", detail: microphoneDetail,
                              granted: permissions.microphone == .authorized) {
                    Button(permissions.requestingMicrophone ? "Waiting for macOS…" :
                            permissions.microphone == .notDetermined ? "Allow microphone" : "Open Settings…") {
                        Task { await permissions.resolveMicrophone(); recheck() }
                    }
                }
                StudioStyle.divider
                permissionRow("Input Monitoring", icon: "keyboard",
                              detail: "Use your recording shortcut while you’re in another app.",
                              granted: permissions.inputMonitoring) {
                    Button("Allow Input Monitoring…") {
                        permissions.resolveInputMonitoring()
                        recheck()
                    }
                }
            }
            .studioProminentButton().tint(StudioStyle.green).controlSize(.regular)
            .disabled(permissions.requestingMicrophone)

            Text("In System Settings → Privacy & Security, enable Nami. If it’s already enabled but access is still missing, switch it off and on, then quit and reopen Nami. Follow any restart prompt from macOS.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true)

            if let error = permissions.settingsError {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Text("Nami checks again when you return.")
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
        .environment(\.colorScheme, .light)
    }

    private var microphoneDetail: String {
        switch permissions.microphone {
        case .authorized: "Ready to record your voice."
        case .denied: "Microphone access is off. Enable Nami in System Settings."
        case .restricted: "Microphone access is restricted on this Mac. Ask your administrator to allow it."
        default: "Record your voice for transcription on your Mac."
        }
    }

    private func permissionRow<Action: View>(_ title: String, icon: String, detail: String,
                                            granted: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 24, height: 24)
                .foregroundStyle(StudioStyle.green)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(.system(size: 16, weight: .medium))
                    Spacer()
                    if granted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.green)
                    }
                }
                Text(detail).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted { action().padding(.top, 3) }
            }
        }
    }
}

private extension View {
    @ViewBuilder func setupCard() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        } else {
            background(StudioStyle.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(StudioStyle.line))
                .shadow(color: StudioStyle.ink.opacity(0.14), radius: 30, y: 12)
        }
    }
}
