import Testing
import NamiCore

@Test func transcriptDifferenceHighlightsAddedMissingAndReplacedWords() {
    let local = "We need two instances today."
    let cloud = "We need, um, three instances."
    let result = TranscriptDifference.compare(local: local, cloud: cloud)
    #expect(Set(result.local.map { String(local[$0]) }) == ["two", "today."])
    #expect(Set(result.cloud.map { String(cloud[$0]) }) == ["um,", "three"])
}

@Test func transcriptDifferencePreservesOriginalUnicodeAndIgnoresPunctuation() {
    let local = "Hello,  —\nCAFÉ! I’m ready."
    let cloud = "hello café I'm really ready"
    let result = TranscriptDifference.compare(local: local, cloud: cloud)
    #expect(result.local.isEmpty)
    #expect(result.cloud.map { String(cloud[$0]) } == ["really"])
}

@Test func transcriptDifferenceHandlesSilenceAndRepeatedWords() {
    let silence = TranscriptDifference.compare(local: "", cloud: "Hello there.")
    #expect(silence.local.isEmpty)
    #expect(silence.cloud.count == 2)
    let local = "I I think so"
    let repeated = TranscriptDifference.compare(local: local, cloud: "I think so")
    #expect(repeated.local.map { String(local[$0]) } == ["I"])
    #expect(repeated.cloud.isEmpty)
    #expect(TranscriptDifference.compare(local: "", cloud: "").local.isEmpty)
}
