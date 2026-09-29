import AppKit
import NamiCore
import SwiftUI

/// One destination owns both its editors and its preview, so they can never show different models.
enum PromptDestination: String, CaseIterable {
    case qwen, apple, whisper, elevenLabs
    var isCleanup: Bool { self == .qwen || self == .apple }
    var title: String {
        switch self {
        case .qwen: "Qwen 3"
        case .apple: "Apple Intelligence"
        case .whisper: "Whisper"
        case .elevenLabs: "ElevenLabs"
        }
    }
    var systemField: PromptField { self == .apple ? .appleSystem : .qwenSystem }
    var editableFields: [PromptField] {
        guard isCleanup else { return [] }
        return [systemField, .cleanupUser, .example] + (self == .apple ? [.appleOutput] : [.editsHeading, .savedEdit])
    }
    func includes(_ record: ModelPromptRecord) -> Bool {
        let provider = record.provider.lowercased()
        switch self {
        case .qwen: return provider.contains("qwen")
        case .apple: return provider.contains("apple")
        case .whisper: return provider.contains("whisper")
        case .elevenLabs: return provider.contains("elevenlabs")
        }
    }
}

struct PromptsView: View {
    @Bindable var studio: StudioSession
    @Bindable var store: PromptStore
    @State var destination: PromptDestination = .qwen
    @State var showingHistory = false
    @State private var previewText = "um please check the deployment I think I think we need two instances"
    @State private var showSaved = false
    @State private var useMemory = true
    @State private var language = "en"
    @State private var liveVocabulary = true
    @State private var advanced = false
    @State private var selectedRecordID: UUID?
    @State private var saved = false

    private var draft: PromptConfiguration {
        get { store.draftConfiguration }
        nonmutating set { store.draftConfiguration = newValue }
    }
    private var vocabulary: Binding<String> {
        liveVocabulary
            ? Binding(get: { store.draftLiveVocabulary ?? studio.settings.vocabulary }, set: { store.draftLiveVocabulary = $0 })
            : $store.draftPlaygroundVocabulary
    }
    private var dirty: Bool {
        if destination.isCleanup { return destination.editableFields.contains { draft[$0] != store.configuration[$0] } }
        return destination == .whisper && vocabulary.wrappedValue != savedVocabulary
    }
    private var savedVocabulary: String { liveVocabulary ? studio.settings.vocabulary : store.playgroundVocabulary }
    private var previewConfiguration: PromptConfiguration { showSaved ? store.configuration : draft }
    private var messages: [ModelPromptMessage] {
        var request = CleanupRequest(rawText: previewText, language: language,
            memory: useMemory ? studio.debugging.cleanupLab.memory : .init())
        request.prompts = previewConfiguration
        var messages = [ModelPromptMessage(role: "system", content: previewConfiguration[destination.systemField]),
                        .init(role: "user", content: CleanupPrompt.input(request, highlightEdits: destination == .qwen))]
        if destination == .apple { messages.append(.init(role: "output field · text", content: previewConfiguration[.appleOutput])) }
        return messages
    }
    private var records: [ModelPromptRecord] { store.records.filter(destination.includes) }
    private var record: ModelPromptRecord? { records.first { $0.id == selectedRecordID } ?? records.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading
            stageSelection
            modelBar
            if let error = store.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            if showingHistory {
                history
            } else {
                workspace
                if destination != .elevenLabs { saveBar }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if store.draftLiveVocabulary == nil { store.draftLiveVocabulary = studio.settings.vocabulary }
            language = studio.debugging.cleanupLab.language
            useMemory = studio.debugging.cleanupLab.useMemory
        }
        .onChange(of: destination) { _, _ in showSaved = false; saved = false; selectedRecordID = nil }
        .onChange(of: dirty) { _, dirty in if dirty { saved = false; showSaved = false } }
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Prompts").font(.system(size: 24, weight: .semibold))
                Text("Choose where the prompt goes. Edit it and see the complete request.")
                    .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
            }
            Spacer()
            HStack(spacing: 2) {
                tab("Edit & preview", selected: !showingHistory) { showingHistory = false }
                tab("Sent requests", selected: showingHistory) { showingHistory = true }
            }.padding(3).background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var stageSelection: some View {
        HStack(spacing: 12) {
            stage("Cleanup", subtitle: "Transcript → edited text", icon: "text.badge.checkmark", selected: destination.isCleanup) {
                destination = .qwen
            }
            stage("Transcription", subtitle: "Audio → transcript", icon: "waveform", selected: !destination.isCleanup) {
                destination = .whisper
            }
        }
    }

    private func stage(_ title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioStyle.green) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(selected ? StudioStyle.soft : Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? StudioStyle.green.opacity(0.5) : StudioStyle.line))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var modelBar: some View {
        HStack(spacing: 6) {
            ForEach(PromptDestination.allCases.filter { $0.isCleanup == destination.isCleanup }, id: \.self) { model in
                tab(model.title, selected: destination == model) { destination = model }
            }
            Spacer()
            Text(destination == .qwen ? "Shared by 0.6B & 1.7B" : destination == .elevenLabs ? "Cloud · Scribe v2" : "On this Mac")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 660 {
                HStack(alignment: .top, spacing: 16) {
                    editorPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    previewPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        editorPanel.frame(height: 520)
                        previewPanel.frame(height: 520)
                    }
                }
            }
        }
    }

    private var editorPanel: some View {
        panel(title: destination.isCleanup ? "Edit cleanup prompts" : "Transcription input", icon: "pencil", trailing: destination == .elevenLabs ? "Audio only" : "Editable") {
            if destination.isCleanup { cleanupEditor }
            else if destination == .whisper { whisperEditor }
            else { cloudExplanation }
        }
    }

    private var cleanupEditor: some View {
        VStack(alignment: .leading, spacing: 22) {
            fieldEditor(destination.systemField, title: "System prompt", subtitle: "How \(destination.title) should edit your transcript.", height: 205)
            fieldEditor(.cleanupUser, title: "User message template", subtitle: "Shared by Qwen and Apple. The transcript is inserted here.", height: 115)
            HStack(spacing: 6) {
                variable("transcript", help: "The sample transcript below, quoted and with vocabulary replacements applied.")
                variable("context", help: "Relevant saved corrections. Empty when none apply.")
                variable("language", help: "The selected language code.")
            }
            StudioStyle.divider
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Sample transcript").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Use Cleanup text") { previewText = studio.debugging.cleanupLab.input }
                        .font(.system(size: 11)).disabled(studio.debugging.cleanupLab.input.isEmpty)
                }
                Text("Change this to see how your template is filled in.").font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                textEditor("Sample transcript", text: $previewText, height: 95)
                HStack {
                    Toggle("Include saved corrections", isOn: $useMemory).toggleStyle(.checkbox).font(.system(size: 12))
                    Spacer()
                    Text(language.uppercased()).font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.quiet)
                }
            }
            DisclosureGroup("Advanced · saved corrections & output", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("These templates build {{context}}. Saved corrections are shared by both cleanup models; Qwen can also receive short wording instructions.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    fieldEditor(.example, title: "Correction example", subtitle: "{{raw}} → original · {{corrected}} → your correction", height: 90)
                    if destination == .qwen {
                    fieldEditor(.editsHeading, title: "Qwen wording instructions", subtitle: "Heading before any matching wording changes.", height: 75)
                    fieldEditor(.savedEdit, title: "Qwen wording change", subtitle: "{{source}} → original wording · {{replacement}} → correction", height: 75)
                    }
                    if destination == .apple {
                        fieldEditor(.appleOutput, title: "Apple output field", subtitle: "Instructions for the text field in Apple’s structured response.", height: 95)
                    }
                }.padding(.top, 14)
            }.font(.system(size: 12, weight: .medium))
        }
    }

    private var whisperEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanation("Audio is the main input", "Whisper turns your recording into text. It has no system prompt. You can supply names and technical terms as vocabulary hints.", icon: "waveform")
            VStack(alignment: .leading, spacing: 10) {
                Text("Use these hints for").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    tab("Live dictation", selected: liveVocabulary) { liveVocabulary = true; showSaved = false }
                    tab("Playground", selected: !liveVocabulary) { liveVocabulary = false; showSaved = false }
                }
                Text(liveVocabulary ? "Also used for audio imports and history retries." : "Only used for transcription comparisons in Playground.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Vocabulary hints").font(.system(size: 13, weight: .semibold))
                Text("Separate names or phrases with commas or new lines. Leave empty for no hints.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                textEditor("Whisper vocabulary hints", text: vocabulary, height: 205)
            }
        }
    }

    private var cloudExplanation: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanation("No text prompt is sent", "Nami sends your audio to ElevenLabs Scribe v2, along with transcription options such as language. There is no system prompt or message template to edit.", icon: "waveform")
            Text("Audio is uploaded only when you confirm a cloud comparison in the Transcription tab.")
                .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
        }
    }

    private var previewPanel: some View {
        panel(title: "Request to \(destination.title)", icon: "arrow.up.right", trailing: "Read only", tinted: true) {
            VStack(alignment: .leading, spacing: 18) {
                if destination != .elevenLabs {
                    HStack(spacing: 4) {
                        tab("Your draft", selected: !showSaved) { showSaved = false }
                        tab("Currently saved", selected: showSaved) { showSaved = true }
                    }
                    Text(showSaved ? "What a new request uses today." : "Updates as you type. Save to use this in future requests.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                }
                if destination.isCleanup {
                    ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                        messageBlock(message.role, content: message.content, number: index + 1)
                    }
                    Text("Preview only · no model is called. Uses the sample transcript and correction toggle on the left.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.quiet)
                } else {
                    messageBlock("audio", content: "Your recording", number: 1)
                    if destination == .whisper {
                        messageBlock("vocabulary", content: showSaved ? savedVocabulary : vocabulary.wrappedValue, number: 2)
                        Text("Whisper trims whitespace and keeps the final 223 vocabulary tokens. Sent requests shows the exact hint after tokenization.")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    }
                    Label("No system prompt", systemImage: "minus.circle").font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                }
            }
        }
    }

    private var saveBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dirty ? "You have unsaved changes" : saved ? "Saved for future requests" : "You’re viewing saved settings")
                    .font(.system(size: 12, weight: .medium))
                Text(destination.isCleanup ? "Cleanup edits apply to live dictation, retries and Playground." : liveVocabulary ? "Applies to live dictation, audio imports and retries." : "Applies to Playground transcription only.")
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.quiet)
            }
            Spacer(minLength: 8)
            Button("Discard") { discard() }.disabled(!dirty)
            Button(destination.isCleanup ? "Save cleanup prompts" : "Save vocabulary") { save() }
                .buttonStyle(.borderedProminent).tint(StudioStyle.green).disabled(!dirty || store.loadFailed)
        }.padding(.top, 2)
    }

    private func save() {
        if destination.isCleanup {
            var config = store.configuration
            for field in destination.editableFields { config[field] = draft[field] }
            saved = store.save(configuration: config, playgroundVocabulary: store.playgroundVocabulary)
        } else if liveVocabulary {
            studio.settings.vocabulary = vocabulary.wrappedValue
            saved = true
        } else {
            saved = store.save(configuration: store.configuration, playgroundVocabulary: vocabulary.wrappedValue)
        }
    }

    private func discard() {
        if destination.isCleanup {
            for field in destination.editableFields { draft[field] = store.configuration[field] }
        } else { vocabulary.wrappedValue = savedVocabulary }
        saved = false
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sent to \(destination.title)").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(records.count) recorded").font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            }
            if records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(StudioStyle.quiet)
                    Text("No requests to \(destination.title) yet").font(.system(size: 15, weight: .medium))
                    Text("Run \(destination.isCleanup ? "cleanup" : "transcription") with this model to inspect exactly what was sent.")
                        .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(records) { entry in historyRow(entry) }
                        }
                    }.frame(width: 200)
                    panel(title: record?.source ?? "Request", icon: "arrow.up.right", trailing: "Sent · read only") {
                        if let record {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text(record.date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 12))
                                    Spacer()
                                    Button("Copy request") { copy(record) }.font(.system(size: 12))
                                }
                                Text(record.provider).font(.system(size: 12, weight: .medium))
                                ForEach(Array(record.messages.enumerated()), id: \.offset) { index, message in
                                    messageBlock(message.role, content: message.content, number: index + 1)
                                }
                                DisclosureGroup("Request details") {
                                    Text(record.details + "\n\nID: " + record.requestID.uuidString)
                                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
                                }.font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            Text("Captured before inference, including requests that later fail. Stored on this Mac · up to 200 recent requests across all models.")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.quiet)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func historyRow(_ entry: ModelPromptRecord) -> some View {
        Button { selectedRecordID = entry.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.source).font(.system(size: 12, weight: .semibold))
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11))
                Text(entry.provider).font(.system(size: 10)).foregroundStyle(StudioStyle.quiet).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(record?.id == entry.id ? StudioStyle.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func panel<Content: View>(title: String, icon: String, trailing: String, tinted: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(trailing).font(.system(size: 10)).foregroundStyle(StudioStyle.quiet)
            }.padding(16)
            StudioStyle.divider
            ScrollView {
                content().padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tinted ? StudioStyle.soft.opacity(0.35) : Color.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioStyle.line))
    }

    private func fieldEditor(_ field: PromptField, title: String, subtitle: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Reset") { draft[field] = field.defaultText }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(StudioStyle.green)
                    .disabled(draft[field] == field.defaultText).help("Restore the default \(title.lowercased()). Save to apply.")
            }
            Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet).fixedSize(horizontal: false, vertical: true)
            textEditor(title, text: Binding(get: { draft[field] }, set: { draft[field] = $0; showSaved = false }), height: height)
        }
    }

    private func textEditor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(size: 12, design: .monospaced)).lineSpacing(3)
            .scrollContentBackground(.hidden).padding(10).frame(height: height)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioStyle.line))
            .accessibilityLabel(label)
    }

    private func messageBlock(_ role: String, content: String, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", number)).foregroundStyle(StudioStyle.quiet)
                Text(role.uppercased()).foregroundStyle(StudioStyle.green)
            }.font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text(content.isEmpty ? "(empty)" : content).font(.system(size: 12, design: .monospaced))
                .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioStyle.line.opacity(0.7)))
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? StudioStyle.ink : StudioStyle.quiet)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func variable(_ name: String, help: String) -> some View {
        Text("{{\(name)}}").font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioStyle.green)
            .padding(.horizontal, 6).padding(.vertical, 4).background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 4))
            .help(help).textSelection(.enabled)
    }

    private func explanation(_ title: String, _ detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(StudioStyle.quiet).lineSpacing(3)
        }
    }

    private func copy(_ record: ModelPromptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(([record.source, record.provider, record.details] + record.messages.map {
            "\($0.role.uppercased())\n\($0.content)"
        }).joined(separator: "\n\n"), forType: .string)
    }
}
