import Foundation

public enum CleanupEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, qwen, qwen17, vocabulary
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .qwen: "Qwen 3 · 0.6B"
        case .qwen17: "Qwen 3 · 1.7B"
        case .vocabulary: "Vocabulary only"
        }
    }
    public static func title(for provider: String) -> String {
        // Recordings cleaned up before Apple Intelligence support was removed.
        if provider.hasPrefix("apple-") { return "Apple Intelligence" }
        if provider.hasPrefix("qwen3-1.7b") { return Self.qwen17.title }
        if provider.hasPrefix("qwen") { return Self.qwen.title }
        if provider == "vocabulary-v1" { return Self.vocabulary.title }
        return provider
    }
}
