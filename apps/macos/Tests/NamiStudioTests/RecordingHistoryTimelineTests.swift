import AppKit
import SwiftUI
import Testing
import Vision
@testable import NamiStudio

/// Opt-in native rendering check. OCR verifies the date actually drawn in the
/// stationary header, including after SwiftUI recycles the lazy history rows.
/// Run with NAMI_TEST_HISTORY_UI=1 swift test --filter RecordingHistoryTimelineTests.
@MainActor struct RecordingHistoryTimelineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_HISTORY_UI"] == "1"))
    func pinnedDateFollowsScrollingAcrossDaysMonthsAndYears() async throws {
        _ = NSApplication.shared
        let calendar = Calendar(identifier: .gregorian)
        let dates = [(2026, 1, 2), (2026, 1, 1), (2025, 12, 31)].map { year, month, day in
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let runs = dates.flatMap { date in
            (0..<8).map { index in run(date, "Entry \(index)") }
        }
        let content = RecordingHistoryTimeline(runs: runs) { run in
            Text(run.transcript).frame(maxWidth: .infinity, alignment: .leading).frame(height: 100)
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.calendar, calendar)
        .frame(width: 500, height: 350)

        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 350),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let scrollView = try #require(findScrollView(in: host))

        for (offset, expectedDate) in [(0.0, "2 JANUARY 2026"), (450.0, "2 JANUARY 2026"),
                                       (830.0, "1 JANUARY 2026"), (1660.0, "31 DECEMBER 2025"),
                                       (830.0, "1 JANUARY 2026"), (0.0, "2 JANUARY 2026")] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.regionOfInterest = CGRect(x: 0, y: 0.9, width: 1, height: 0.1)
            try VNImageRequestHandler(cgImage: image).perform([request])
            let header = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            #expect(header == expectedDate, "At offset \(offset)")
        }
    }

    /// The pinned date and the hovered row come from frames in the content's own
    /// coordinates plus the content's offset, never from rows observing the scroll.
    @Test func layoutFindsTopDayAndHoveredRowFromContentFrames() {
        let calendar = Calendar(identifier: .gregorian)
        let newer = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!
        let older = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let ids = (0..<4).map { _ in UUID() }
        let layout = HistoryLayout()
        // 100-point rows; the older day starts after its 18-point gap.
        for (index, (day, y)) in [(newer, 0.0), (newer, 100), (older, 218), (older, 318)].enumerated() {
            layout.rows[ids[index]] = .init(day: day, frame: CGRect(x: 0, y: y, width: 500, height: 100))
        }
        layout.shown = Set(ids)

        #expect(layout.topDay == newer)
        layout.contentTop = -150
        #expect(layout.topDay == newer)
        // The gap above a day belongs to that day.
        layout.contentTop = -205
        #expect(layout.topDay == older)

        #expect(layout.hoveredRow == nil)
        layout.pointer = CGPoint(x: 10, y: 20)
        #expect(layout.hoveredRow == ids[2])
        // Rows scrolling under a pointer that stays put.
        layout.contentTop = -310
        #expect(layout.hoveredRow == ids[3])
        // A row the lazy stack let go of no longer counts, even though its frame is kept.
        layout.shown.remove(ids[3])
        #expect(layout.hoveredRow == nil)
        layout.shown.insert(ids[3])
        layout.pointer = nil
        #expect(layout.hoveredRow == nil)
    }

    @Test func groupsPreserveNewestFirstOrderByDay() {
        let calendar = Calendar(identifier: .gregorian)
        let day = { (d: Int, h: Int) in calendar.date(from: DateComponents(year: 2026, month: 1, day: d, hour: h))! }
        let runs = [run(day(2, 18), "c"), run(day(2, 9), "b"), run(day(1, 23), "a")]
        let groups = RecordingHistoryTimeline<EmptyView>.grouped(runs[...], calendar: calendar)
        #expect(groups.map(\.date) == [calendar.startOfDay(for: day(2, 0)), calendar.startOfDay(for: day(1, 0))])
        #expect(groups.map { $0.runs.map(\.transcript) } == [["c", "b"], ["a"]])
    }

    private func run(_ date: Date, _ transcript: String) -> RecordingRun {
        RecordingRun(id: UUID(), date: date, transcript: transcript, audioSeconds: 1,
                     latency: 0, averageDB: -20, peakDB: -6, input: "Test", savedURL: nil,
                     engine: "fake", model: "Test", prompt: "")
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

}
