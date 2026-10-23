import SwiftUI

struct CloudDictationSettingsView: View {
    @Bindable var session: StudioSession
    @State private var draftKey = ""
    @State private var hasKey = false
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Groq API key").font(.system(size: 15, weight: .semibold))
                Spacer()
                if hasKey && !editing {
                    Label("Saved", systemImage: "checkmark.circle")
                        .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                }
                Menu {
                    if hasKey {
                        if editing {
                            Button("Cancel editing") { editing = false; draftKey = ""; error = nil }
                        } else {
                            Button("Change API key…") { editing = true }
                        }
                        Button("Remove API key", role: .destructive) { store("") }
                    }
                    Link("Get API key…", destination: DictationProvider.groq.keyURL)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Manage Groq API key").accessibilityLabel("Manage Groq API key")
            }
            if !hasKey || editing {
                HStack {
                    SecureField("API key", text: $draftKey)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Groq API key")
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.line))
        .disabled(session.busyForUpdate)
        .onStudioPageVisibility(appear: refresh, disappear: { draftKey = ""; editing = false })
    }

    private func refresh() {
        do { hasKey = try session.hasDictationKey(.groq); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func save() {
        let value = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard !value.contains(where: { $0.isWhitespace }) else {
            error = "The key contains whitespace. Paste the key again."; return
        }
        store(value)
    }

    private func store(_ value: String) {
        do {
            try session.saveDictationKey(value, provider: .groq)
            draftKey = ""; hasKey = !value.isEmpty; editing = false; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
