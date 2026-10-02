import Testing
import NamiCore

@Test func transcriptAnalysisAlignsInsertionsDeletionsAndSubstitutions() {
    let result = TranscriptAnalysis.compare(reference: "one two three four", hypothesis: "one too four extra")
    #expect(result.substitutions + result.deletions + result.insertions == 3)
    #expect(result.wordErrorRate == 0.75)
    #expect(result.edits.count == 3)
    #expect(result.characterErrorRate != nil)
    let deletion = TranscriptAnalysis.compare(reference: "please do not deploy", hypothesis: "please do deploy")
    #expect(deletion.deletions == 1)
    #expect(deletion.edits.first?.reference == "not")
    #expect(deletion.edits.first?.referenceIndex == 2)
    let insertion = TranscriptAnalysis.compare(reference: "hello", hypothesis: "hello lovely new world")
    #expect(insertion.insertions == 3)
    #expect(insertion.wordErrorRate == 3)
}

@Test func transcriptAnalysisHandlesNormalizationSilenceAndUnicode() {
    let normalized = TranscriptAnalysis.compare(reference: "Hello, WORLD!", hypothesis: "hello world")
    #expect(normalized.normalizedMatch)
    #expect(!normalized.exactMatch)
    #expect(normalized.characterErrorRate == 0)
    let silence = TranscriptAnalysis.compare(reference: "", hypothesis: "Thanks for watching")
    #expect(silence.wordErrorRate == nil)
    #expect(silence.insertions == 3)
    #expect(TranscriptAnalysis.compare(reference: "", hypothesis: "").normalizedMatch)
    #expect(TranscriptAnalysis.compare(reference: "café", hypothesis: "cafe").characterErrorRate == 0.25)
}
