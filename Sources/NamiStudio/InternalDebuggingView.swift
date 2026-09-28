import NamiCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InternalDebuggingView: View {
    @Bindable var session: StudioSession
    @Bindable var lab: DebuggingSession
    @State private var confirmCloud = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var highlightDifferences = true
    @State private var downloadChoice = ""

    private var locked: Bool { lab.isBusy || session.phase.busy || lab.loadFailed }
    private var selectedModel: DebugModel? {
        lab.comparisonModel
    }
    private var needsSetup: Bool {
        selectedModel == nil || lab.cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sourceControls
                if lab.isBusy && lab.activeComparisonBatchID == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(lab.status).font(.system(size: 13))
                        Spacer()
                        Button("Cancel") { lab.cancel() }.disabled(lab.cancelling)
                    }
                }
                if let message = lab.errorMessage { errorBanner(message) }
                if let sample = lab.selectedSample {
                    recordingRow(sample)
                    comparisonControls
                    transcripts
                } else {
                    Text("Choose a recording")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(StudioStyle.quiet)
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(28)
            .frame(maxWidth: 1300, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            session.stopPlayback()
            if !CommandLine.arguments.contains("--snapshot"), lab.workspace.models.isEmpty,
               !session.settings.modelFolder.isEmpty, session.settings.engine == "whisperkit", !lab.isBusy {
                lab.addModel(folder: URL(fileURLWithPath: session.settings.modelFolder))
            }
        }
        .onDisappear { lab.stopPlayback() }
        .sheet(isPresented: $showHistory) { historyPicker }
        .confirmationDialog("Compare with ElevenLabs?", isPresented: $confirmCloud, titleVisibility: .visible) {
            Button("Upload and compare") {
                guard !locked, let model = selectedModel else { return }
                session.stopPlayback()
                lab.runCloudComparison(localModelID: model.id)
            }
        } message: {
            Text("Uploads “\(lab.selectedSample?.title ?? "")” (\(lab.selectedSample?.audioSeconds ?? 0, specifier: "%.1f") s) to ElevenLabs. Your API account will be charged. The same audio runs locally with \(selectedModel?.name ?? "").")
        }
    }

    private var sourceControls: some View {
        HStack(spacing: 10) {
            Button("Upload audio", action: importAudio).disabled(locked)
            Button("History") { showHistory = true }
                .disabled(locked || (session.runs.isEmpty && lab.workspace.samples.isEmpty))
            Spacer()
            Button("Settings") { showSettings.toggle() }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { comparisonSettings }
        }.controlSize(.large)
    }

    private func recordingRow(_ sample: DebugSample) -> some View {
        HStack(spacing: 12) {
            Button { session.stopPlayback(); lab.togglePlayback() } label: {
                Image(systemName: lab.playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 14)).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(StudioStyle.soft, in: Circle())
            .disabled(locked)
            .accessibilityLabel(lab.playing ? "Stop playback" : "Play recording")
            Text(sample.title)
                .font(.system(size: 14, weight: .medium)).lineLimit(2)
                .help(sample.title)
            Spacer(minLength: 8)
            Text(Duration.seconds(sample.audioSeconds).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(StudioStyle.quiet)
            Picker("Language", selection: Binding(get: { sample.language }, set: { lab.updateSample(sample.id, language: $0) })) {
                Text("English").tag("en")
                Text("Auto-detect").tag("auto")
                if sample.language != "en" && sample.language != "auto" { Text(sample.language).tag(sample.language) }
            }.labelsHidden().fixedSize().disabled(locked).accessibilityLabel("Language")
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { StudioStyle.divider }
        .overlay(alignment: .bottom) { StudioStyle.divider }
    }

    private var comparisonControls: some View {
        HStack(spacing: 12) {
            if lab.activeComparisonBatchID != nil {
                ProgressView().controlSize(.small)
                Text(lab.cancelling ? "Cancelling…" : "Comparing…")
                    .font(.system(size: 13)).help(lab.status)
                Button("Cancel") { lab.cancel() }.disabled(lab.cancelling)
            } else {
                Button(needsSetup ? "Set up comparison" : "Compare") {
                    if needsSetup { showSettings = true } else { confirmCloud = true }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(locked)
            }
            Spacer()
            Toggle("Highlight differences", isOn: $highlightDifferences)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help("Highlights words that differ between the two transcripts. Case and punctuation are ignored.")
        }
    }

    private var transcripts: some View {
        let pair = lab.comparisonResults(localModelID: selectedModel?.id)
        let difference: TranscriptDifference? = {
            guard highlightDifferences, let local = pair.local, let cloud = pair.cloud,
                  local.error == nil, cloud.error == nil,
                  let hash = local.audioSHA256, hash == cloud.audioSHA256 else { return nil }
            return .compare(local: local.transcript, cloud: cloud.transcript)
        }()
        return HStack(alignment: .top, spacing: 0) {
            transcriptColumn("Local", result: pair.local, highlights: difference?.local ?? [])
                .padding(.trailing, 24)
            Rectangle().fill(StudioStyle.line).frame(width: 1)
            transcriptColumn("ElevenLabs", result: pair.cloud, highlights: difference?.cloud ?? [])
                .padding(.leading, 24)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func transcriptColumn(_ title: String, result: DebugResult?, highlights: [Range<String.Index>]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 17, weight: .semibold))
                    .help(title == "Local" ? selectedModel?.name ?? "Local model" : "Scribe v2")
                Spacer(minLength: 4)
                if let result, result.error == nil {
                    Text("\(result.transcriptionSeconds.formatted(.number.precision(.fractionLength(2)))) s")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(StudioStyle.quiet)
                        .help("Transcription time")
                }
            }
            if let result {
                if let error = result.error {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                } else if result.transcript.isEmpty {
                    Text("No speech detected").foregroundStyle(StudioStyle.quiet)
                } else {
                    Text(highlightedTranscript(result.transcript, ranges: highlights))
                        .font(.system(size: 15)).lineSpacing(7)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(lab.isBusy ? "Waiting…" : "No transcript yet")
                    .font(.system(size: 14)).foregroundStyle(StudioStyle.quiet)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
    }

    private func highlightedTranscript(_ text: String, ranges: [Range<String.Index>]) -> AttributedString {
        var output = AttributedString(text)
        for range in ranges {
            guard let start = AttributedString.Index(range.lowerBound, within: output),
                  let end = AttributedString.Index(range.upperBound, within: output) else { continue }
            output[start..<end].backgroundColor = Color(red: 0.96, green: 0.87, blue: 0.60)
            output[start..<end].underlineStyle = .single
        }
        return output
    }

    private var comparisonSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Comparison settings").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { showSettings = false }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Local model").font(.system(size: 13, weight: .medium))
                Picker("Local model", selection: Binding(get: { selectedModel?.id ?? "" }, set: { lab.selectComparisonModel($0) })) {
                    if lab.workspace.models.isEmpty { Text("Choose a model").tag("") }
                    ForEach(lab.workspace.models) { Text($0.name).tag($0.id) }
                }.labelsHidden().disabled(locked)
                Menu("Add model") {
                    if !session.settings.modelFolder.isEmpty && session.settings.engine == "whisperkit" {
                        Button("Use dictation model") { lab.addModel(folder: URL(fileURLWithPath: session.settings.modelFolder)) }
                    }
                    Button("Choose folder…", action: addModelFolder)
                    Button("Download…") { lab.fetchModels() }
                }.fixedSize().disabled(locked)
                if !lab.availableModels.isEmpty {
                    HStack {
                        Picker("Download", selection: $downloadChoice) {
                            Text("Choose a model").tag("")
                            ForEach(lab.availableModels, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                        Button("Download") { lab.downloadModel(downloadChoice) }
                            .disabled(locked || downloadChoice.isEmpty)
                    }.disabled(locked)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ElevenLabs API key").font(.system(size: 13, weight: .medium))
                SecureField("API key", text: $lab.cloudAPIKey)
                    .textFieldStyle(.roundedBorder).disabled(locked)
                if let error = lab.cloudAPIKeyError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    Button("Retry saving key") { lab.saveCloudAPIKey() }.disabled(locked)
                }
            }
            if lab.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(lab.status).font(.system(size: 12))
                }
            }
        }.padding(22).frame(width: 420)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(message).textSelection(.enabled)
            Spacer()
            if lab.unsaved { Button("Retry saving") { lab.save() } }
            Button { lab.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }
        .font(.system(size: 13)).padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a recording").font(.system(size: 20, weight: .medium, design: .rounded))
            List {
                if !lab.workspace.samples.isEmpty {
                    Section("Saved recordings") {
                        ForEach(lab.workspace.samples) { sample in
                            Button {
                                lab.stopPlayback()
                                lab.selectedSampleID = sample.id
                                showHistory = false
                            } label: {
                                HStack {
                                    Text(sample.title).lineLimit(2)
                                    Spacer()
                                    if sample.id == lab.selectedSampleID { Image(systemName: "checkmark") }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if !session.runs.isEmpty {
                    Section("Recording history") {
                        ForEach(session.runs) { run in
                            Button {
                                lab.useHistory(run, language: session.settings.language)
                                showHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(run.date.formatted()).font(.system(size: 11)).foregroundStyle(StudioStyle.quiet)
                                    Text(run.displayText).lineLimit(3).font(.system(size: 13))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.listStyle(.plain).disabled(locked)
            HStack { Spacer(); Button("Cancel") { showHistory = false } }
        }.padding(24).frame(width: 540, height: 450).background(StudioStyle.paper)
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Choose audio to test. Nami keeps a separate copy for testing."
        if panel.runModal() == .OK, !locked, let url = panel.url {
            lab.importAudio(url, language: session.settings.language)
        }
    }

    private func addModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a WhisperKit model folder containing Core ML models and tokenizer files."
        if panel.runModal() == .OK, !locked, let url = panel.url { lab.addModel(folder: url) }
    }
}
