import AppKit
import NamiCore
import SwiftUI
import UniformTypeIdentifiers

/// Actions run steps on this Mac, such as opening a link in a chosen browser, when a recording is one of their phrases.
struct ActionsView: View {
    @Bindable var session: StudioSession
    @State private var pendingDelete: VoiceAction?
    @State private var showingHelp = false
    /// The one action being edited. Changes apply only on Save; a new action is added then.
    @State private var draft: VoiceAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if session.actionsLoadFailed, let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 8)
                    Button { showingHelp.toggle() } label: {
                        Label("How it works", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain).preferenceControl()
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) { help }
                }
                VStack(alignment: .leading, spacing: 0) {
                    StudioSectionHeader(title: "Actions").padding(.bottom, 4)
                    ForEach(session.actions.actions) { action in
                        if draft?.id == action.id { editor } else { row(action) }
                        StudioStyle.divider
                    }
                    if let draft, !session.actions.actions.contains(where: { $0.id == draft.id }) {
                        editor
                        StudioStyle.divider
                    }
                    Button { draft = VoiceAction() } label: { Label("Add action", systemImage: "plus") }
                        .buttonStyle(.plain).preferenceControl().padding(.top, 16)
                        .disabled(draft != nil)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.system(size: 15)).foregroundStyle(StudioStyle.ink)
        .confirmationDialog("Delete this action?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { action in
            Button("Delete", role: .destructive) { session.actions.actions.removeAll { $0.id == action.id } }
        } message: { action in
            Text("“\(action.title)” will be removed. This can’t be undone.")
        }
    }

    private func row(_ action: VoiceAction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(action.spokenPhrases.isEmpty ? action.title : action.spokenPhrases.joined(separator: ", "))
                    .font(.system(size: 15, weight: .semibold))
                Text(action.steps.isEmpty ? "No steps" : action.steps.map(\.summary).joined(separator: "\n"))
                    .font(.system(size: 14)).foregroundStyle(StudioStyle.quiet).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                Button { draft = action } label: { Image(systemName: "pencil") }
                    .help("Edit action").accessibilityLabel("Edit \(action.title)")
                Button { pendingDelete = action } label: { Image(systemName: "trash") }
                    .help("Delete action").accessibilityLabel("Delete \(action.title)")
            }
            .buttonStyle(.plain).foregroundStyle(StudioStyle.quiet)
            .disabled(draft != nil)
        }
        .padding(.vertical, 12)
    }

    private var editor: some View {
        let phrases = Binding { draft?.phrases ?? "" } set: { draft?.phrases = $0 }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Phrases, separated by commas", text: phrases).actionField()
                .accessibilityLabel("Phrases")
            ForEach(Array((draft?.steps ?? []).enumerated()), id: \.element.id) { index, step in
                stepEditor(step, number: index + 1)
            }
            HStack(spacing: 12) {
                Button { draft?.steps.append(ActionStep()) } label: { Label("Add step", systemImage: "plus") }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(StudioStyle.green)
                Spacer()
                Button("Cancel") { draft = nil }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveDraft)
                    .buttonStyle(.plain).preferenceControl()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft?.isValid != true)
                    .help("Save (⌘Return)")
            }
        }
        .padding(.vertical, 12)
    }

    private func stepEditor(_ step: ActionStep, number: Int) -> some View {
        HStack(spacing: 8) {
            Picker("Step \(number)", selection: stepBinding(step.id, \.kind)) {
                ForEach(ActionStep.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 170)
            TextField(step.kind.targetLabel, text: stepBinding(step.id, \.target)).actionField()
                .accessibilityLabel("Step \(number) \(step.kind.targetLabel)")
            if step.kind.opensWithApplication {
                ApplicationPicker(step: step, selection: stepBinding(step.id, \.application))
                    .frame(width: 170).accessibilityLabel("Step \(number) app")
            }
            Button { draft?.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(StudioStyle.quiet)
                .help("Remove step").accessibilityLabel("Remove step \(number)")
                .disabled((draft?.steps.count ?? 0) < 2)
        }
    }

    private func stepBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<ActionStep, Value>) -> Binding<Value> {
        Binding {
            draft?.steps.first { $0.id == id }?[keyPath: keyPath] ?? ActionStep()[keyPath: keyPath]
        } set: { value in
            guard let index = draft?.steps.firstIndex(where: { $0.id == id }) else { return }
            draft?.steps[index][keyPath: keyPath] = value
        }
    }

    private func saveDraft() {
        guard let draft, draft.isValid else { return }
        session.refreshActionsIfChanged()
        if let index = session.actions.actions.firstIndex(where: { $0.id == draft.id }) {
            session.actions.actions[index] = draft
        } else {
            session.actions.actions.append(draft)
        }
        self.draft = nil
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How actions work").font(.system(size: 13, weight: .semibold))
            Text("Start a recording with one of an action’s phrases. Nami runs its steps in order instead of pasting your words.")
            Text("“Open Excel repo”")
                .foregroundStyle(StudioStyle.green)
            Text("A step can open a link, app, file, or folder, optionally in a chosen app, run a Shortcut, or run a shell command.")
            Text("Put {{ }} in a step to use the words said after the phrase, e.g. github.com/search?q={{query}}. Without it, the phrase must be all you say.")
            Text("Matching is word for word, not translated: add the phrases in each language you speak, e.g. “open Excel repo, открой репозиторий Excel”.")
            Text("Other recordings are pasted as usual. History shows which action ran.")
        }
        .font(.system(size: 12)).foregroundStyle(StudioStyle.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading).padding(16)
    }
}

/// Apps that can open a step's link, file, or folder, with the default app first.
private struct ApplicationPicker: View {
    let step: ActionStep
    @Binding var selection: String
    @State private var apps: [InstalledApp] = []

    var body: some View {
        Picker("Open with", selection: $selection) {
            Text("Default app").tag("")
            Divider()
            ForEach(apps) { app in
                Label { Text(app.name) } icon: { Image(nsImage: app.icon) }.tag(app.name)
            }
            // A name typed in the CLI or saved earlier stays selectable even when it isn't installed.
            if !selection.isEmpty, !apps.contains(where: { $0.name == selection }) {
                Text(selection).tag(selection)
            }
        }
        .labelsHidden()
        .task(id: "\(step.kind.rawValue)|\(step.target)") { apps = InstalledApp.apps(toOpen: step) }
    }
}

private struct InstalledApp: Identifiable {
    /// The name `open -a` takes.
    let name: String
    let icon: NSImage
    var id: String { name }

    @MainActor static func apps(toOpen step: ActionStep) -> [InstalledApp] {
        let workspace = NSWorkspace.shared
        let urls: [URL]
        switch step.kind {
        case .openURL:
            // Placeholders and missing schemes still list the apps for web links.
            let target = step.target.trimmingCharacters(in: .whitespacesAndNewlines)
            let link = URL(string: target).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "https://example.com")!
            urls = workspace.urlsForApplications(toOpen: link)
        case .openFile:
            let path = (step.target.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                urls = workspace.urlsForApplications(toOpen: URL(fileURLWithPath: path))
            } else {
                let ext = (path as NSString).pathExtension
                urls = workspace.urlsForApplications(toOpen: ext.isEmpty ? .folder : UTType(filenameExtension: ext) ?? .data)
            }
        default:
            urls = []
        }
        var seen = Set<String>()
        return urls
            .map { InstalledApp(name: $0.deletingPathExtension().lastPathComponent, icon: icon(for: $0)) }
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor private static func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

private extension View {
    func actionField() -> some View {
        textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(StudioStyle.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.line))
    }
}
