import NamiCore
import NamiMLXCleanup
import SwiftUI

struct CleanupLabView: View {
    @Bindable var lab: CleanupLabSession
    @Bindable var studio: StudioSession
    let sourceText: String?
    @State private var heard = ""
    @State private var replacement = ""
    @State private var showVocabulary = false
    @State private var showExamples = false
    private var locked: Bool { lab.isBusy || studio.phase.busy || studio.modelMaintenance }
    private var service: CleanupService { lab.service }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                liveSettings
                StudioStyle.divider
                comparisonInput
                if let error = lab.errorMessage { message(error, color: .red) }
                if lab.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(lab.status).font(.system(size: 14))
                        Spacer()
                        Button("Cancel comparison") { lab.cancel() }
                    }
                }
                if let run = lab.latestRun { results(run) }
                if lab.showingCorrectionEditor { correctionEditor }
                StudioStyle.divider
                personalVocabulary
                savedExamples
            }
            .padding(28).frame(maxWidth: 1300, alignment: .topLeading).frame(maxWidth: .infinity)
        }
        .onAppear { service.refreshAvailability() }
        .onChange(of: lab.compareApple) { lab.savePreferences() }
        .onChange(of: lab.compareQwen) { lab.savePreferences() }
        .onChange(of: lab.compareQwen17) { lab.savePreferences() }
        .onChange(of: lab.useMemory) { lab.savePreferences() }
        .onChange(of: lab.deadlineSeconds) { lab.savePreferences() }
    }

    private var liveSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Live dictation").font(.system(size: 20, weight: .semibold))
                Spacer()
                Toggle("Clean up before pasting", isOn: $studio.settings.cleanupEnabled)
                    .toggleStyle(.switch).fixedSize().disabled(studio.phase.busy || studio.modelMaintenance)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { liveEngine; liveTimeout; liveMemory }
                VStack(alignment: .leading, spacing: 14) {
                    liveEngine
                    HStack(spacing: 24) { liveTimeout; liveMemory }
                }
            }.disabled(studio.phase.busy || studio.modelMaintenance)
            if studio.settings.cleanupEnabled {
                if studio.settings.cleanupEngine == .apple, let reason = service.appleUnavailableReason {
                    message(reason, color: .orange)
                } else if QwenModel.model(for: studio.settings.cleanupEngine) != nil, !service.isInstalled(studio.settings.cleanupEngine) {
                    message("Download the selected model in Models to use it for dictation.", color: .orange)
                }
            }
            if let run = studio.runs.first, let result = run.cleanupResult {
                HStack(spacing: 8) {
                    Image(systemName: result.succeeded ? "checkmark.circle" : "arrow.uturn.backward.circle")
                    Text("Last dictation: \(CleanupEngine.title(for: result.provider)) · \(milliseconds(result)) · \(outcome(result))")
                    Spacer()
                    Button("Compare this dictation") { lab.input = run.rawTranscript ?? run.transcript }.disabled(locked)
                }.font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            }
        }
    }

    private var liveEngine: some View {
        Picker("Engine", selection: $studio.settings.cleanupEngine) {
            ForEach(CleanupEngine.allCases) { engine in
                Text(engine == .automatic ? "Automatic · \(service.automaticEngine.title)" : engine.title).tag(engine)
            }
        }.frame(minWidth: 260, maxWidth: 380)
            .help("Automatic uses Apple when available, then downloaded Qwen, then vocabulary rules. Failed or timed-out cleanup keeps the original transcript.")
    }
    private var liveTimeout: some View {
        Picker("Max wait", selection: $studio.settings.cleanupTimeoutSeconds) {
            ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) sec").tag($0) }
        }.fixedSize().help("Maximum added time before Nami uses the original transcript instead.")
    }
    private var liveMemory: some View {
        Toggle("Use saved corrections", isOn: $studio.settings.cleanupUseMemory).toggleStyle(.checkbox).fixedSize()
    }

    private var comparisonInput: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Compare cleanup").font(.system(size: 20, weight: .semibold))
                Spacer()
                Menu("Load text") {
                    Button("Example dictation") {
                        lab.input = "um can you check the name me deployment I think I think we need two instances"
                        lab.language = "en"
                    }
                    if let sourceText, !sourceText.isEmpty {
                        Button("Transcription comparison") { lab.input = sourceText; lab.language = "en" }
                    }
                    if let run = studio.runs.first {
                        Button("Last dictation") { lab.input = run.rawTranscript ?? run.transcript; lab.language = "en" }
                    }
                }.fixedSize().disabled(locked)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], alignment: .leading, spacing: 16) {
                modelOption(.apple, selected: $lab.compareApple)
                modelOption(.qwen, selected: $lab.compareQwen)
                modelOption(.qwen17, selected: $lab.compareQwen17)
            }
            if let error = service.downloadError { message(error, color: .red) }
            ZStack(alignment: .topLeading) {
                if lab.input.isEmpty {
                    Text("Type or load a transcript to compare…").foregroundStyle(StudioStyle.quiet)
                        .padding(12).allowsHitTesting(false)
                }
                TextEditor(text: $lab.input).font(.system(size: 16)).scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 145).disabled(locked).accessibilityLabel("Transcript to clean up")
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioStyle.line))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { comparisonOptions; Spacer(); compareButton }
                VStack(alignment: .leading, spacing: 16) { comparisonOptions; compareButton }
            }
        }
    }
    private var comparisonOptions: some View {
        HStack(spacing: 20) {
            Toggle("Use saved corrections", isOn: $lab.useMemory).toggleStyle(.checkbox).fixedSize()
            Picker("Max wait", selection: $lab.deadlineSeconds) {
                ForEach([1.0, 10.0, 30.0], id: \.self) { Text("\(Int($0)) sec").tag($0) }
            }.fixedSize()
        }.font(.system(size: 13)).disabled(locked)
    }
    private var compareButton: some View {
        Button("Run comparison") { lab.compare() }.studioProminentButton().controlSize(.large)
            .disabled(locked || lab.loadFailed || lab.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lab.input.utf8.count > 20_000)
    }
    private func modelOption(_ engine: CleanupEngine, selected: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(engine.title, isOn: selected).toggleStyle(.checkbox)
                .font(.system(size: 14, weight: .medium)).disabled(locked)
            if engine == .apple {
                Text(service.appleUnavailableReason == nil ? "Ready on this Mac" : "Unavailable on this Mac")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    .help(service.appleUnavailableReason ?? "Uses Apple's on-device text model.")
            } else if service.downloadingEngine == engine {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.system(size: 12))
                    Button("Cancel") { service.cancelDownload() }.font(.system(size: 12))
                }
            } else if service.isInstalled(engine) {
                Text("Downloaded · runs locally").font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            } else {
                Button("Download · \(ModelFiles.sizeLabel(QwenModel.model(for: engine)!.downloadBytes))") { service.downloadQwen(engine) }
                    .font(.system(size: 12)).disabled(studio.busyForUpdate)
            }
        }.frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(16).background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 10))
    }

    private func results(_ run: CleanupLabRun) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Results").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(run.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
            }
            if run.results.first?.rawText != lab.input {
                DisclosureGroup("Original text from this comparison") {
                    Text(run.results.first?.rawText ?? "").textSelection(.enabled).padding(.top, 8)
                }.font(.system(size: 13))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(Array(run.results.enumerated()), id: \.offset) { _, result in resultCard(result) }
            }
        }
    }
    private func resultCard(_ result: CleanupResult) -> some View {
        let leaked = CleanupOutput.isFormatLeak(result.text, original: result.rawText)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(CleanupEngine.title(for: result.provider)).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Text(milliseconds(result)).font(.system(size: 12)).monospacedDigit().foregroundStyle(StudioStyle.quiet)
            }
            Text(leaked ? result.rawText : result.text).font(.system(size: 16)).lineSpacing(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            if leaked || !result.succeeded {
                Text(leaked ? "Invalid model format. Original text kept." : result.reason ?? "Original text kept.")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                if let rejected = result.rejectedText, !rejected.isEmpty {
                    DisclosureGroup("Show rejected response") {
                        Text(rejected).font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.system(size: 12))
                }
            } else {
                HStack {
                    Text(outcome(result)).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    Spacer()
                    Button("Correct this result") { lab.editCorrection(for: result) }.font(.system(size: 12)).disabled(locked)
                }
            }
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioStyle.line))
    }
    private var correctionEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your correction").font(.system(size: 17, weight: .semibold))
            TextEditor(text: $lab.correctedText).font(.system(size: 16)).frame(height: 120)
                .padding(8).background(.white).disabled(locked).accessibilityLabel("Corrected transcript to remember")
            HStack {
                Button("Remember correction") { lab.teachCorrection() }.studioProminentButton().disabled(!lab.canTeach || locked)
                    .help("Save a personal example for future cleanup. This does not create a global word replacement.")
                Button("Cancel") { lab.showingCorrectionEditor = false }
            }
        }.padding(20).background(StudioStyle.soft, in: RoundedRectangle(cornerRadius: 10))
    }
    private var personalVocabulary: some View {
        DisclosureGroup("Word replacements (\(lab.memory.vocabulary.count))", isExpanded: $showVocabulary) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    TextField("Replace this phrase", text: $heard)
                    Image(systemName: "arrow.right").foregroundStyle(StudioStyle.quiet)
                    TextField("With this phrase", text: $replacement)
                    Button("Add replacement") {
                        lab.addVocabulary(heard: heard, replacement: replacement)
                        if lab.errorMessage == nil { heard = ""; replacement = "" }
                    }
                }.disabled(locked || lab.loadFailed)
                ForEach(lab.memory.vocabulary) { rule in
                    HStack {
                        Text("\(rule.heard) → \(rule.replacement)").textSelection(.enabled)
                        Spacer()
                        Button("Remove") { lab.removeVocabulary(rule.id) }.disabled(locked)
                    }
                }
            }.padding(.top, 16)
        }.font(.system(size: 14))
    }
    private var savedExamples: some View {
        DisclosureGroup("Saved corrections (\(lab.memory.examples.count))", isExpanded: $showExamples) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(lab.memory.examples.reversed()) { example in
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(example.rawText).foregroundStyle(StudioStyle.quiet)
                            Text(example.correctedText)
                        }.textSelection(.enabled)
                        Spacer()
                        Button("Remove") { lab.removeExample(example.id) }.disabled(locked)
                    }
                }
            }.padding(.top, 16)
        }.font(.system(size: 14))
    }
    private func milliseconds(_ result: CleanupResult) -> String {
        "\((result.elapsedSeconds * 1_000).formatted(.number.precision(.fractionLength(0)))) ms"
    }
    private func outcome(_ result: CleanupResult) -> String {
        switch result.outcome { case .cleaned: "Cleaned up"; case .unchanged: "No changes"; default: "Original kept" }
    }
    private func message(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(color).textSelection(.enabled)
    }
}
