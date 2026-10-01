import Darwin
import Foundation

public enum SnippetError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

/// Snippets are personal, so they live with history rather than in the project's `nami.json`.
/// The app and the `nami-snippets` CLI share this file; writes take a lock so neither loses the other's change.
public struct SnippetStore: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nami/snippets.json")
    }

    public let url: URL

    public init(url: URL = SnippetStore.defaultURL) { self.url = url }

    /// A missing file is an empty library. A damaged one throws, and is then never overwritten.
    public func load() throws -> SnippetLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return SnippetLibrary() }
        let library = try JSONDecoder().decode(SnippetLibrary.self, from: Data(contentsOf: url))
        guard library.version == 1 else { throw SnippetError.message("Unsupported snippets version.") }
        return library
    }

    public func save(_ library: SnippetLibrary) throws {
        try locked { try write(library) }
    }

    /// Loads, changes, and saves under one lock, so a concurrent writer cannot be overwritten.
    @discardableResult
    public func update(_ change: (inout SnippetLibrary) throws -> Void) throws -> SnippetLibrary {
        try locked {
            var library = try load()
            try change(&library)
            try write(library)
            return library
        }
    }

    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func write(_ library: SnippetLibrary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(library) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.deletingLastPathComponent().appendingPathComponent(".snippets.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw SnippetError.message("Cannot lock the snippets file.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SnippetError.message("Cannot lock the snippets file.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
