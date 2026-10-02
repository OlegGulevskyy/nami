import Testing
import NamiCore

@Test func highlightQuotesReplaceTheNearestReferenceInOrder() {
    let spoken = "can you rephrase this and also fix that sentence please"
    let highlights = [
        CapturedHighlight(text: "The quick brown fox.", spokenWords: 3, seconds: 1),
        CapturedHighlight(text: "It jumped.", spokenWords: 6, seconds: 3),
    ]
    let result = HighlightQuotes.apply(highlights, spoken: spoken, edited: spoken, audioSeconds: 5)
    #expect(result.text == "can you rephrase \"The quick brown fox.\" and also fix \"It jumped.\" please")
    #expect(result.quoted == 2)
    #expect(result.unmatched == 0)
}

@Test func highlightQuotesUseCleanedTextWhenReferencesSurvive() {
    let spoken = "um can you fix this"
    let edited = "Can you fix this?"
    let highlight = CapturedHighlight(text: "Teh cat", spokenWords: 3, seconds: 1)
    let result = HighlightQuotes.apply([highlight], spoken: spoken, edited: edited, audioSeconds: 2)
    #expect(result.text == "Can you fix \"Teh cat\"?")
    #expect(!result.usedOriginal)
}

@Test func highlightQuotesFallBackToSpokenTextWhenCleanupRewordsReferences() {
    let spoken = "fix this and this"
    let edited = "Fix these."
    let highlight = CapturedHighlight(text: "A", spokenWords: 1, seconds: 0)
    let result = HighlightQuotes.apply([highlight], spoken: spoken, edited: edited, audioSeconds: 2)
    #expect(result.text == "fix \"A\" and this")
    #expect(result.usedOriginal)
}

@Test func highlightQuotesLeaveOutHighlightsWithoutANearbyReference() {
    let spoken = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen this"
    let highlight = CapturedHighlight(text: "A", spokenWords: 0, seconds: 0)
    let result = HighlightQuotes.apply([highlight], spoken: spoken, edited: spoken, audioSeconds: 5)
    #expect(result.text == spoken)
    #expect(result.unmatched == 1)
}

@Test func highlightQuotesPreferThisOverAConjunctionThat() {
    let spoken = "I think that this is wrong"
    let highlight = CapturedHighlight(text: "X", spokenWords: 2, seconds: 0)
    let result = HighlightQuotes.apply([highlight], spoken: spoken, edited: spoken, audioSeconds: 2)
    #expect(result.text == "I think that \"X\" is wrong")
}

@Test func highlightQuotesEstimatePositionFromTimeWithoutPreviews() {
    let spoken = "first fix this then later rephrase this"
    let highlights = [CapturedHighlight(text: "B", spokenWords: nil, seconds: 6)]
    let result = HighlightQuotes.apply(highlights, spoken: spoken, edited: spoken, audioSeconds: 7)
    #expect(result.text == "first fix this then later rephrase \"B\"")
}

@Test func highlightTrackerCommitsStableSelectionsAnchoredAtTheirStart() {
    var tracker = HighlightTracker()
    tracker.observe(nil, spokenWords: 0, seconds: 0)
    tracker.observe("The", spokenWords: 2, seconds: 0.25)
    tracker.observe("The quick", spokenWords: 2, seconds: 0.5)
    tracker.observe("The quick fox", spokenWords: 3, seconds: 0.75)
    tracker.observe("The quick fox", spokenWords: 3, seconds: 1)
    tracker.observe("The quick fox", spokenWords: 4, seconds: 1.25)
    tracker.observe(nil, spokenWords: 5, seconds: 1.5)
    tracker.observe("Jumped", spokenWords: 8, seconds: 4)
    tracker.finish(seconds: 4.1)
    #expect(tracker.highlights == [
        CapturedHighlight(text: "The quick fox", spokenWords: 2, seconds: 0.25),
        CapturedHighlight(text: "Jumped", spokenWords: 8, seconds: 4),
    ])
}

@Test func highlightTrackerReplacesAQuickAdjustment() {
    var tracker = HighlightTracker()
    for _ in 0..<2 { tracker.observe("quick fox", spokenWords: 1, seconds: 0.5) }
    for _ in 0..<2 { tracker.observe("The quick fox", spokenWords: 1, seconds: 1) }
    #expect(tracker.highlights.map(\.text) == ["The quick fox"])
}
