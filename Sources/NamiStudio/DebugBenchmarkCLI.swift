import Foundation

/// Headless entry point sharing the app's runners, scoring and persistence.
public enum DebugBenchmarkCLI {
    public static let usage = """
    nami-lab report [--workspace PATH]
    nami-lab run (--sample UUID | --all) [--cloud --allow-cloud] [--model PATH] [--workspace PATH]
    nami-lab reference --sample UUID --text-file PATH [--verified] [--category NAME] [--workspace PATH]

    report prints JSON with sample/audio paths, all runs, diffs, paired comparisons and aggregates.
    run uses enabled local models; --model selects one folder for this run.
    --cloud adds Scribe v2; requires ELEVENLABS_API_KEY and --allow-cloud.
    --allow-cloud explicitly authorizes uploading the selected audio and provider charges for this invocation.
    Obtain the user's approval for that concrete batch before passing --allow-cloud.
    reference stores a listened-to reference; --verified certifies it was checked against audio.
    Close Nami before CLI writes; reopen it afterward to reload results. Keys are never written to the workspace.
    """

    @MainActor public static func run(_ arguments: [String]) async throws -> Data {
        guard let command = arguments.first, ["report", "run", "reference"].contains(command) else {
            throw StudioError.message(usage)
        }
        let valueFlags: Set<String> = ["--workspace", "--sample", "--model", "--text-file", "--category"]
        let booleanFlags: Set<String> = ["--all", "--cloud", "--allow-cloud", "--verified"]
        var values: [String: String] = [:], flags: Set<String> = [], index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard values[flag] == nil, !flags.contains(flag) else { throw StudioError.message("Duplicate option: \(flag)") }
            if valueFlags.contains(flag) {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw StudioError.message("Missing value for \(flag)") }
                values[flag] = arguments[index]
            } else if booleanFlags.contains(flag) { flags.insert(flag) }
            else { throw StudioError.message("Unknown option: \(flag)") }
            index += 1
        }
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nami/InternalDebugging")
        let directory = values["--workspace"].map { URL(fileURLWithPath: $0) } ?? defaultDirectory
        let lab = DebuggingSession(directory: directory)
        guard !lab.loadFailed else { throw StudioError.message(lab.errorMessage ?? "Workspace load failed") }
        if command != "report" {
            guard (values["--sample"] != nil) != flags.contains("--all") else {
                throw StudioError.message("Choose exactly one of --sample UUID or --all.")
            }
            if let id = values["--sample"] {
                guard let uuid = UUID(uuidString: id), lab.workspace.samples.contains(where: { $0.id == uuid }) else {
                    throw StudioError.message("Unknown sample: \(id)")
                }
                lab.selectedSampleID = uuid
            }
        }
        if command == "reference" {
            guard let sample = lab.selectedSample, !flags.contains("--all"), let path = values["--text-file"] else {
                throw StudioError.message("reference requires --sample UUID and --text-file PATH")
            }
            let reference = try String(contentsOfFile: path, encoding: .utf8)
            guard reference.count <= 20_000 else { throw StudioError.message("Reference exceeds 20,000 characters.") }
            lab.updateSample(sample.id, expectedText: reference, referenceVerified: flags.contains("--verified"), category: values["--category"])
        } else if command == "run" {
            guard !lab.workspace.samples.isEmpty else { throw StudioError.message("No samples in workspace.") }
            if flags.contains("--cloud") {
                guard flags.contains("--allow-cloud") else { throw StudioError.message("Cloud run needs explicit --allow-cloud approval for this batch.") }
                guard !lab.cloudAPIKey.isEmpty else { throw StudioError.message("Set ELEVENLABS_API_KEY in the environment.") }
            }
            // Selection is in memory only; preserve the user's model toggles.
            if let path = values["--model"] { lab.selectCLIModel(path) }
            guard flags.contains("--cloud") || values["--model"] != nil || lab.workspace.models.contains(where: \.enabled) else {
                throw StudioError.message("Choose a local --model PATH or --cloud.")
            }
            if flags.contains("--cloud") { lab.runCloudComparison(allSamples: flags.contains("--all")) }
            else { lab.runComparison(allSamples: flags.contains("--all")) }
            while lab.isBusy { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard !lab.unsaved else { throw StudioError.message(lab.errorMessage ?? "Workspace could not be saved") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(DebugBenchmarkReport(workspace: lab.workspace, directory: directory))
    }
}
