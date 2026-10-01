import Foundation
import NamiCore

@main struct NamiActions {
    static func main() {
        do {
            print(try ActionCommandLine.run(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
