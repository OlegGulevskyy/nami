import Foundation
import NamiCore

@main struct NamiSnippets {
    static func main() {
        do {
            print(try SnippetCommandLine.run(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
