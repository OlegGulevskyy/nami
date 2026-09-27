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
        let groups = dates.map { date in
            (date: date, runs: (0..<8).map { index in
                RecordingRun(id: UUID(), date: date, transcript: "Entry \(index)", audioSeconds: 1,
                             latency: 0, averageDB: -20, peakDB: -6, input: "Test", savedURL: nil,
                             engine: "fake", model: "Test", prompt: "")
            })
        }
        let content = RecordingHistoryTimeline(groups: groups) { run in
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

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

}
