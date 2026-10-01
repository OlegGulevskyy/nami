import Foundation
import NamiCore

/// Runs one step of a voice action, with placeholders already filled. Throws a
/// message the status line can show.
public typealias ActionStepRunner = @MainActor (ActionStep) async throws -> Void

enum SystemActionRunner {
    /// Long enough for `open` and quick commands to report a failure. Anything still
    /// running after this is left to finish on its own.
    static let failureWindow: Duration = .seconds(5)

    @MainActor static func run(_ step: ActionStep) async throws {
        let target = step.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = step.kind.opensWithApplication && !step.application.isEmpty ? ["-a", step.application] : []
        switch step.kind {
        case .openURL: try await launch("/usr/bin/open", app + [target])
        case .openApp: try await launch("/usr/bin/open", ["-a", target])
        case .openFile: try await launch("/usr/bin/open", app + [(target as NSString).expandingTildeInPath])
        case .runShortcut: try await launch("/usr/bin/shortcuts", ["run", target])
        // A login shell, so commands find the same tools as in Terminal.
        case .runCommand: try await launch("/bin/zsh", ["-lc", target])
        }
    }

    @MainActor private static func launch(_ path: String, _ arguments: [String]) async throws {
        // Errors go to a file, not a pipe: a background child that keeps a pipe open would block the read.
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("nami-action-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let deadline = ContinuousClock.now + failureWindow
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning, process.terminationStatus != 0 else { return }
        let message = (try? String(contentsOf: errorURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw StudioError.message(message.isEmpty ? "\(URL(fileURLWithPath: path).lastPathComponent) exited with status \(process.terminationStatus)." : message)
    }
}
