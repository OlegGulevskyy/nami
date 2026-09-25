import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InternalDebuggingView: View {
    @Bindable var session: StudioSession
    @Bindable var lab: DebuggingSession
    @State private var showModels = false
    @State private var downloadChoice = ""
    @State private var showHistory = false
    @State private var detailedResultID: UUID?

    private var locked: Bool { lab.isBusy || session.phase.busy || lab.loadFailed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let message = lab.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(message).textSelection(.enabled)
                        Spacer()
                        if lab.unsaved { Button("Retry saving") { lab.save() } }
                        Button { lab.errorMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss debugging error")
                    }
                    .font(.system(size: 13)).padding(14)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                captureControls
                if lab.isBusy {
                    HStack(spacing: 10) {
                        if lab.isBusy { ProgressView().controlSize(.small) }
                        Text(lab.status).font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                        Spacer()
                        if lab.isBusy {
                            Button("Cancel") { lab.cancel() }.disabled(lab.cancelling)
                        }
                    }
                }
                modelPanel
                if lab.workspace.samples.isEmpty { emptyState }
                else { sampleWorkspace }
            }.padding(28)
        }
        .onAppear {
            session.stopPlayback()
            if !CommandLine.arguments.contains("--snapshot"),
               lab.workspace.models.isEmpty, lab.workspace.samples.isEmpty,
               !session.settings.modelFolder.isEmpty, session.settings.engine == "whisperkit", !lab.isBusy {
                lab.addModel(folder: URL(fileURLWithPath: session.settings.modelFolder))
            }
            if lab.workspace.models.isEmpty { showModels = true }
        }
        .onDisappear { lab.stopPlayback() }
        .sheet(isPresented: $showHistory) { historyPicker }
    }

    private var captureControls: some View {
        HStack(spacing: 10) {
            Button {
                if lab.recording { lab.stopRecording() } else { session.startDebugRecording() }
            } label: {
                Label(lab.recording ? "Stop" : "Record", systemImage: lab.recording ? "stop.fill" : "mic")
            }
            .buttonStyle(.borderedProminent)
            .disabled((locked && !lab.recording) || session.permissions.needsSetup)
            Button { importAudio() } label: { Label("Import", systemImage: "doc.badge.plus") }
                .disabled(locked)
            Button("From History…") { showHistory = true }
                .disabled(locked || session.runs.isEmpty)
            Spacer(minLength: 0)
            if lab.recording {
                Circle().fill(StudioStyle.green.opacity(0.3 + lab.level * 0.7)).frame(width: 9, height: 9)
                Text(String(format: "%02d:%02d", Int(lab.elapsed) / 60, Int(lab.elapsed) % 60))
                    .font(.system(size: 13, design: .monospaced)).monospacedDigit()
            }
        }
        .controlSize(.regular)
        .overlay(alignment: .bottomLeading) {
            if session.permissions.needsSetup {
                Text("Enable recording in Permissions.")
                    .font(.system(size: 10)).foregroundStyle(StudioStyle.quiet).offset(y: 18)
            }
        }
        .padding(.bottom, session.permissions.needsSetup ? 12 : 0)
    }

    private var modelPanel: some View {
        DisclosureGroup(isExpanded: $showModels) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lab.workspace.models) { model in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { model.enabled }, set: { lab.setModelEnabled(model.id, enabled: $0) })) {
                            Text(model.name).font(.system(size: 12, design: .monospaced))
                                .lineLimit(2).textSelection(.enabled)
                        }.toggleStyle(.checkbox).disabled(locked)
                        Spacer(minLength: 0)
                        Button { lab.removeModel(model.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).disabled(locked).help("Remove from comparison; keep model files")
                            .accessibilityLabel("Remove \(model.name) from comparison")
                    }.help(model.folder)
                }
                Menu("Add model") {
                    if !session.settings.modelFolder.isEmpty {
                        Button("Use dictation model") { lab.addModel(folder: URL(fileURLWithPath: session.settings.modelFolder)) }
                            .disabled(locked || session.settings.engine != "whisperkit")
                    }
                    Button("Choose local folder…", action: addModelFolder).disabled(locked)
                    Button("Download from Hugging Face…") { lab.fetchModels() }.disabled(locked)
                }.fixedSize().controlSize(.small).disabled(locked)
                if !lab.availableModels.isEmpty {
                    HStack {
                        Picker("Download", selection: $downloadChoice) {
                            Text("Choose a model").tag("")
                            ForEach(lab.availableModels, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                        Button("Download") { lab.downloadModel(downloadChoice) }
                            .disabled(locked || downloadChoice.isEmpty)
                    }.disabled(locked)
                }
            }.padding(.top, 12)
        } label: {
            Text("Models (\(lab.workspace.models.filter(\.enabled).count))")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(16).background(StudioStyle.soft.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 30, weight: .light))
            Text("No samples yet").font(.system(size: 18, weight: .medium, design: .rounded))
            Text("Record or import audio to begin.")
                .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    private var sampleWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            if lab.workspace.samples.count > 1 {
                Picker("Sample", selection: Binding(get: { lab.selectedSampleID }, set: { lab.stopPlayback(); lab.selectedSampleID = $0 })) {
                    ForEach(lab.workspace.samples) { Text($0.title).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("Sample")
            }
            if let sample = lab.selectedSample {
                HStack {
                    TextField("Sample title", text: Binding(get: { sample.title }, set: { lab.updateSample(sample.id, title: $0) }))
                        .textFieldStyle(.plain).font(.system(size: 18, weight: .medium)).disabled(locked)
                        .accessibilityLabel("Sample title").help(sample.createdAt.formatted())
                    Text("\(sample.audioSeconds.formatted(.number.precision(.fractionLength(1)))) s")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.quiet)
                    Button { session.stopPlayback(); lab.togglePlayback() } label: {
                        Image(systemName: lab.playing ? "stop.circle" : "play.circle")
                    }.buttonStyle(StudioIconButton()).disabled(locked)
                        .accessibilityLabel(lab.playing ? "Stop playback" : "Listen to sample")
                        .help(lab.playing ? "Stop playback" : "Listen")
                    Picker("Language", selection: Binding(get: { sample.language }, set: { lab.updateSample(sample.id, language: $0) })) {
                        Text("English").tag("en")
                        Text("Auto-detect").tag("auto")
                        if sample.language != "en" && sample.language != "auto" { Text(sample.language).tag(sample.language) }
                    }.labelsHidden().fixedSize().controlSize(.small).disabled(locked)
                        .accessibilityLabel("Language")
                }
                HStack(alignment: .top, spacing: 18) {
                    expectedEditor(sample).frame(maxWidth: .infinity, alignment: .topLeading)
                    results(sample).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func expectedEditor(_ sample: DebugSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Expected text").font(.system(size: 13, weight: .medium))
            TextEditor(text: Binding(get: { sample.expectedText }, set: { lab.updateSample(sample.id, expectedText: $0) }))
                .font(.system(size: 14)).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 170, maxHeight: 240)
                .background(StudioStyle.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.line))
                .disabled(locked).accessibilityLabel("Expected transcript")
                .help("Enter the words you said, including hesitations and corrections. Changes save automatically.")
            if lab.unsaved {
                Button("Retry saving changes") { lab.save() }.font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack {
                Button("Compare") { session.stopPlayback(); lab.runComparison() }
                    .buttonStyle(.borderedProminent).disabled(locked || !lab.canRun)
                if lab.workspace.samples.count > 1 {
                    Button("Compare all") {
                        session.stopPlayback(); lab.runComparison(allSamples: true)
                    }.disabled(locked || !lab.canRun)
                }
            }
        }
    }

    private func results(_ sample: DebugSample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Results").font(.system(size: 13, weight: .medium))
            if lab.selectedResults.isEmpty {
                Text("Run a comparison to see results.")
                    .font(.system(size: 13)).foregroundStyle(StudioStyle.quiet).padding(.top, 8)
            }
            ForEach(lab.selectedResults) { result in resultCard(result, sample: sample) }
        }
    }

    private func resultCard(_ result: DebugResult, sample: DebugSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(result.model.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { detailedResultID = result.id } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(StudioStyle.quiet)
                    .accessibilityLabel("Result details for \(result.model.name)").help("Result details")
                    .popover(isPresented: Binding(get: { detailedResultID == result.id }, set: { if !$0 { detailedResultID = nil } })) {
                        resultDetails(result)
                    }
            }
            HStack {
                if let rate = result.wordErrorRate {
                    Text("WER \((rate * 100).formatted(.number.precision(.fractionLength(1))))%")
                        .foregroundStyle(rate == 0 ? StudioStyle.green : .orange)
                        .help("Word error rate ignores case and punctuation. Lower is better; it can exceed 100%.")
                } else { Text(result.error == nil ? "Not scored" : "Failed") }
                Spacer(minLength: 4)
                Text("\(result.transcriptionSeconds.formatted(.number.precision(.fractionLength(2)))) s")
                    .help("Transcription time, excluding model loading")
            }.font(.system(size: 12, weight: .medium))
            if let error = result.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            else {
                Text(result.transcript.isEmpty ? "(No speech recognized)" : result.transcript)
                    .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.expectedText != sample.expectedText || result.language != sample.language {
                Label("Reference changed", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .help("The expected text or language changed since this run. Open result details to see the original reference.")
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.soft.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func resultDetails(_ result: DebugResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.date.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Model load", value: "\(result.preparationSeconds.formatted(.number.precision(.fractionLength(2)))) s")
            LabeledContent("Language", value: result.language)
            StudioStyle.divider
            Text("Reference used").fontWeight(.medium)
            Text(result.expectedText.isEmpty ? "No expected text supplied." : result.expectedText)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).padding(18).frame(width: 300)
    }

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a recording").font(.system(size: 20, weight: .medium, design: .rounded))
            List(session.runs) { run in
                Button {
                    lab.useHistory(run, language: session.settings.language)
                    showHistory = false
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.date.formatted()).font(.system(size: 11)).foregroundStyle(StudioStyle.quiet)
                        Text(run.displayText).lineLimit(3).font(.system(size: 13))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.buttonStyle(.plain)
            }.listStyle(.plain).disabled(locked)
            HStack { Spacer(); Button("Cancel") { showHistory = false } }
        }.padding(24).frame(width: 540, height: 450).background(StudioStyle.paper)
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Choose audio up to 60 seconds long. Nami keeps a separate copy for testing."
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
