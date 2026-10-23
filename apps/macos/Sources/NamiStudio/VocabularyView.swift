import SwiftUI

struct VocabularyView: View {
    @Bindable var session: StudioSession
    @State private var showingHelp = false

    private var termCount: Int {
        session.settings.vocabulary
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(termCount == 1 ? "1 term" : "\(termCount) terms")
                        .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                    Spacer()
                    Button { showingHelp.toggle() } label: {
                        Label("How it works", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain).preferenceControl()
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Vocabulary").font(.system(size: 13, weight: .semibold))
                            Text("Add names and technical terms, separated by commas or new lines. Changes save automatically and apply to your next transcription.")
                            Text("Keep the list short. Vocabulary provides recognition hints and consistent capitalization; it does not guarantee a spelling.")
                        }
                        .font(.system(size: 12)).frame(width: 320, alignment: .leading).padding(16)
                    }
                }

                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $session.settings.vocabulary)
                            .font(.system(size: 16)).lineSpacing(8)
                            .scrollContentBackground(.hidden)
                            .padding(16).frame(minHeight: 320)
                            .disabled(session.phase.busy)
                            .accessibilityLabel("Vocabulary")

                    }
                }
                .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StudioStyle.line))

                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .foregroundStyle(StudioStyle.ink)
    }
}
