import NamiCore
import SwiftUI

/// Snippets replace a spoken command with saved text, filling `{{…}}` with the details said after it.
struct SnippetsView: View {
    @Bindable var session: StudioSession
    @State private var pendingDelete: Snippet?
    @State private var showingHelp = false
    /// The one snippet being edited. Changes apply only on Save; a new snippet is added then.
    @State private var draft: Snippet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if session.snippetsLoadFailed, let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Text("Trigger words").font(.system(size: 15))
                    TextField("Off", text: $session.snippets.triggerWord)
                        .snippetField().frame(width: 260)
                        .accessibilityLabel("Trigger words")
                    Spacer(minLength: 8)
                    Button { showingHelp.toggle() } label: {
                        Label("How it works", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain).preferenceControl()
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) { help }
                }
                VStack(alignment: .leading, spacing: 0) {
                    StudioSectionHeader(title: "Snippets").padding(.bottom, 4)
                    ForEach(session.snippets.snippets) { snippet in
                        if draft?.id == snippet.id { editor } else { row(snippet) }
                        StudioStyle.divider
                    }
                    if let draft, !session.snippets.snippets.contains(where: { $0.id == draft.id }) {
                        editor
                        StudioStyle.divider
                    }
                    Button { draft = Snippet() } label: { Label("Add snippet", systemImage: "plus") }
                        .buttonStyle(.plain).preferenceControl().padding(.top, 16)
                        .disabled(draft != nil)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.system(size: 15)).foregroundStyle(StudioStyle.ink)
        .confirmationDialog("Delete this snippet?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { snippet in
            Button("Delete", role: .destructive) { session.snippets.snippets.removeAll { $0.id == snippet.id } }
        } message: { snippet in
            Text("“\(snippet.title)” will be removed. This can’t be undone.")
        }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(snippet.spokenPhrases.isEmpty ? snippet.title : snippet.spokenPhrases.joined(separator: ", "))
                    .font(.system(size: 15, weight: .semibold))
                Text(snippet.template.isEmpty ? "No text" : snippet.template)
                    .font(.system(size: 14)).foregroundStyle(StudioStyle.quiet).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                Button { draft = snippet } label: { Image(systemName: "pencil") }
                    .help("Edit snippet").accessibilityLabel("Edit \(snippet.title)")
                Button { pendingDelete = snippet } label: { Image(systemName: "trash") }
                    .help("Delete snippet").accessibilityLabel("Delete \(snippet.title)")
            }
            .buttonStyle(.plain).foregroundStyle(StudioStyle.quiet)
            .disabled(draft != nil)
        }
        .padding(.vertical, 12)
    }

    private var editor: some View {
        let phrases = Binding { draft?.phrases ?? "" } set: { draft?.phrases = $0 }
        let template = Binding { draft?.template ?? "" } set: { draft?.template = $0 }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Phrases, separated by commas", text: phrases).snippetField()
                .accessibilityLabel("Phrases")
            TextEditor(text: template)
                .font(.system(size: 14)).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(6).frame(height: 76)
                .background(StudioStyle.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.line))
                .accessibilityLabel("Snippet text")
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { draft = nil }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveDraft)
                    .buttonStyle(.plain).preferenceControl()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft?.spokenPhrases.isEmpty != false)
                    .help("Save (⌘Return)")
            }
        }
        .padding(.vertical, 12)
    }

    private func saveDraft() {
        guard let draft, !draft.spokenPhrases.isEmpty else { return }
        session.refreshSnippetsIfChanged()
        if let index = session.snippets.snippets.firstIndex(where: { $0.id == draft.id }) {
            session.snippets.snippets[index] = draft
        } else {
            session.snippets.snippets.append(draft)
        }
        self.draft = nil
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How snippets work").font(.system(size: 13, weight: .semibold))
            Text("Say a trigger word, one of a snippet’s phrases, then the details. Nami pastes the snippet’s text instead of your words.")
            Text("“free env snippet for Excel add-in, Users API”")
                .foregroundStyle(StudioStyle.green)
            Text("Phrases are separated by commas. In the text, {{ }} marks where details go, e.g. {{apps}}. One placeholder gets every detail, joined with commas; several are filled in order.")
            Text("Matching is word for word, not translated: for each language, add a trigger word and phrases as you say them, e.g. “snippet, сниппет”.")
            Text("Recordings without a trigger word are pasted as usual. Leave it empty to turn snippets off.")
        }
        .font(.system(size: 12)).foregroundStyle(StudioStyle.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading).padding(16)
    }
}

private extension View {
    func snippetField() -> some View {
        textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(StudioStyle.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.line))
    }
}
