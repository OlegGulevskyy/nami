import SwiftUI

struct CloudDictationSettingsView: View {
    @Bindable var session: StudioSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudioSectionHeader(title: "Cloud dictation")
            Text("Add a provider's API key, choose a model, then select Use for dictation. Your audio and vocabulary are sent to that provider when you record or retry. Provider usage charges apply.")
                .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Language").font(.system(size: 13))
                Picker("Cloud dictation language", selection: $session.settings.language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("French").tag("fr")
                    if !["auto", "en", "fr"].contains(session.settings.language) {
                        Text(session.settings.language).tag(session.settings.language)
                    }
                }.labelsHidden().fixedSize()
                Spacer()
            }.disabled(session.busyForUpdate)
            Text("This is the same language used in General settings. Choose Auto-detect for switching between English and French.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            ForEach(DictationProvider.allCases) { provider in
                CloudDictationProviderRow(session: session, provider: provider)
            }
        }
    }
}

private struct CloudDictationProviderRow: View {
    @Bindable var session: StudioSession
    let provider: DictationProvider
    @State private var draftKey = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var failed = false
    private var selected: Bool { session.settings.engine == provider.engineID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(selected ? "Selected for dictation" : hasKey ? "Key saved" : "Needs API key")
                    .font(.system(size: 12)).foregroundStyle(selected ? StudioStyle.green : StudioStyle.quiet)
            }
            Text(provider.detail).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Picker("\(provider.title) model", selection: Binding(
                get: { session.settings.cloudModel(for: provider) },
                set: { session.settings.cloudModels[provider.rawValue] = $0 })) {
                ForEach(provider.models, id: \.id) { model in Text(model.title).tag(model.id) }
            }
            if provider == .soniox || provider == .assemblyai {
                Picker("\(provider.title) region", selection: Binding(
                    get: { session.settings.cloudRegion(for: provider) },
                    set: { session.settings.cloudRegions[provider.rawValue] = $0 })) {
                    ForEach(DictationCloudRegion.allCases, id: \.self) { region in Text(region.title).tag(region) }
                }
            }
            HStack {
                SecureField(hasKey ? "Replace saved API key" : "Paste API key", text: $draftKey)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("\(provider.title) API key")
                    .onSubmit(save)
                Button("Save key", action: save).disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 12) {
                Link("Get API key", destination: provider.keyURL)
                if hasKey { Button("Remove key") { store("") } }
                Spacer()
                Button(selected ? "Selected" : "Use for dictation") { session.settings.engine = provider.engineID }
                    .disabled(!hasKey || selected || !draftKey.isEmpty)
            }.font(.system(size: 12))
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(failed ? .red : StudioStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Saved in this Mac's Keychain. Saving a key does not test or charge it; the first recording checks access.")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.quiet)
        }
        .padding(18).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? StudioStyle.green : StudioStyle.line))
        .disabled(session.busyForUpdate)
        .onAppear { refresh() }
        .onDisappear { draftKey = "" }
    }

    private func refresh() {
        do { hasKey = try session.hasDictationKey(provider) }
        catch { failed = true; message = error.localizedDescription }
    }
    private func save() {
        let value = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard !value.contains(where: { $0.isWhitespace }) else {
            failed = true; message = "The key contains whitespace. Paste the key again."; return
        }
        store(value)
    }
    private func store(_ value: String) {
        do {
            try session.saveDictationKey(value, provider: provider)
            draftKey = ""; hasKey = !value.isEmpty; failed = false
            message = value.isEmpty ? "API key removed." : "API key saved. Ready to select for dictation."
        } catch { failed = true; message = error.localizedDescription }
    }
}
