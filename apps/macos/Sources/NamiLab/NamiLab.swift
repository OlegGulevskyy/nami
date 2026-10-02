import Foundation
import NamiStudio

@main struct NamiLab {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] {
            print(DebugBenchmarkCLI.usage)
            return
        }
        do {
            let report = try await DebugBenchmarkCLI.run(arguments)
            FileHandle.standardOutput.write(report)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
