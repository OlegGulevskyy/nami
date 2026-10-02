import Foundation

public enum CleanupPrompt {
    public static func input(_ request: CleanupRequest, highlightEdits: Bool = false) -> String {
        let examples = examples(request)
        let text = request.memory.replacingVocabulary(in: request.rawText, language: request.language)
        // A small model follows a short, explicit edit more reliably than two
        // nearly identical example paragraphs. Keep full examples for rewrites.
        var sections = examples.filter { !highlightEdits || savedEdit($0) == nil }.map {
            PromptConfiguration.render(request.prompts[.example], values: ["raw": quoted($0.rawText), "corrected": quoted($0.correctedText)])
        }
        if highlightEdits {
            let edits = examples.compactMap(savedEdit).compactMap { $0.instruction(for: text, template: request.prompts[.savedEdit]) }
            if !edits.isEmpty {
                sections.append(request.prompts[.editsHeading] + "\n" + edits.joined(separator: "\n"))
            }
        }
        let context = sections.isEmpty ? "" : sections.joined(separator: "\n\n") + "\n\n"
        return PromptConfiguration.render(request.prompts[.cleanupUser], values: [
            "context": context, "transcript": quoted(text), "language": request.language,
        ])
    }

    /// Describe small edits the user actually made to a generated result. This
    /// stays scoped to retrieved examples; it never creates a replacement rule.
    private static func savedEdit(_ example: CleanupExample) -> SavedEdit? {
        let before = example.generatedText.split(whereSeparator: \.isWhitespace)
        let after = example.correctedText.split(whereSeparator: \.isWhitespace)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let removed = before[prefix..<(before.count - suffix)]
        let inserted = after[prefix..<(after.count - suffix)]
        guard !removed.isEmpty, !inserted.isEmpty, removed.count <= 4, inserted.count <= 4 else { return nil }
        let source = removed.joined(separator: " "), replacement = inserted.joined(separator: " ")
        guard source.utf8.count <= 160, replacement.utf8.count <= 160 else { return nil }
        return SavedEdit(source: source, replacement: replacement)
    }

    private struct SavedEdit {
        let source: String
        let replacement: String
        func instruction(for text: String, template: String) -> String? {
            // Match whole terms, not identifiers or a filename already corrected
            // to e.g. pom.xml. A trailing sentence period is still a boundary.
            let escaped = NSRegularExpression.escapedPattern(for: source)
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}_.-])\(escaped)(?![\\p{L}\\p{M}\\p{N}_-]|\\.[\\p{L}\\p{M}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { return nil }
            return PromptConfiguration.render(template, values: ["source": quoted(String(text[range])), "replacement": quoted(replacement)])
        }
    }

    private static func examples(_ request: CleanupRequest) -> [CleanupExample] {
        request.memory.relevantExamples(for: request.rawText, language: request.language)
            .filter { !CleanupOutput.isFormatLeak($0.correctedText, original: $0.rawText) }
    }

    private static func quoted(_ text: String) -> String {
        // Escaped string literals delimit user data without showing an output object to imitate.
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
    }
}

public enum CleanupOutput {
    public static func rejectionReason(_ output: String, original: String) -> String? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The model returned no text. Original text kept."
        }
        if isFormatLeak(output, original: original) {
            return "The model returned a response wrapper instead of plain text. Original text kept."
        }
        if isSeverelyTruncated(output, original: original) {
            let before = original.split(whereSeparator: \.isWhitespace).count
            let after = output.split(whereSeparator: \.isWhitespace).count
            return "The model shortened \(before) words to \(after), dropping too much text. Original text kept."
        }
        if output.utf8.count > max(256, original.utf8.count * 3) {
            return "The model expanded the transcript too much. Original text kept."
        }
        return nil
    }

    /// Catch catastrophic shortening, not semantic correctness. Legitimate
    /// aggressive edits may fall back too; preserving the dictation is safer.
    public static func isSeverelyTruncated(_ output: String, original: String) -> Bool {
        let originalWords = original.split(whereSeparator: \.isWhitespace).count
        let outputWords = output.split(whereSeparator: \.isWhitespace).count
        guard originalWords >= 6 && outputWords * 5 < originalWords * 2 else { return false }
        return !isRestatedCorrection(output, original: original)
    }

    /// Repeated false starts can be longer than their complete correction. Allow
    /// a literal corrected suffix only when it retains every non-disfluency word;
    /// a short summary or an unrelated final sentence still fails the length gate.
    private static func isRestatedCorrection(_ output: String, original: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        }
        let before = words(original), after = words(output)
        guard after.count >= 4, before.suffix(after.count).elementsEqual(after) else { return false }
        let cue = " " + before.filter { !["um", "uh", "erm"].contains($0) }.joined(separator: " ") + " "
        guard cue.contains(" actually no ") || cue.contains(" no sorry ") else { return false }
        let disfluencies: Set<String> = ["um", "uh", "erm", "actually", "no", "sorry"]
        return Set(before).subtracting(disfluencies).isSubset(of: Set(after))
    }

    /// A chat model may quote its entire answer as a JSON string. Decode only
    /// that envelope, preserving genuine quoted source text and inner quotes.
    /// Objects such as {before, after} remain invalid; never guess a field.
    public static func removingStringEnvelope(_ output: String, original: String) -> String {
        let decoder = JSONDecoder()
        guard (try? decoder.decode(String.self, from: Data(original.utf8))) == nil,
              let text = try? decoder.decode(String.self, from: Data(output.utf8)) else { return output }
        return text
    }

    public static func isFormatLeak(_ output: String, original: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == original.trimmingCharacters(in: .whitespacesAndNewlines) { return false }
        if text.contains("<think>") || text.contains("</think>") { return true }
        if text.hasPrefix("```") && !original.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") { return true }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        // Preserve genuine dictated JSON. A newly generated object/array is not prose cleanup.
        let originalJSON = original.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return originalJSON == nil && (object is [String: Any] || object is [Any])
    }
}
