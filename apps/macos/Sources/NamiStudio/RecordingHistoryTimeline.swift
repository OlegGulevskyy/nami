import SwiftUI

/// One stationary date above the scrolling transcripts. Measure rows rather than
/// section headers: a lazy stack may discard a header during a long day's history.
/// `runs` is the whole (already searched) history, newest first; only a growing
/// prefix is laid out so long histories scroll smoothly.
///
/// Nothing in a row follows the scroll position. Rows are measured in the content's
/// own coordinates, which scrolling doesn't change, and a single observer follows
/// the content offset; the pinned date and the hovered row are both read from those
/// frames. Frames observed in the scroll view's coordinates, or a hover tracker per
/// row, made SwiftUI update every row on every scrolled frame.
struct RecordingHistoryTimeline<Row: View>: View {
    static var pageSize: Int { 20 }

    let runs: [RecordingRun]
    @ViewBuilder var row: (RecordingRun) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendar) private var calendar
    @State private var activeDate: Date?
    @State private var movingToOlderDate = true
    @State private var visibleCount = pageSize
    @State private var hoveredRunID: RecordingRun.ID?
    @State private var layout = HistoryLayout()
    @Namespace private var scrollSpace
    @Namespace private var contentSpace

    private var groups: [(date: Date, runs: [RecordingRun])] {
        Self.grouped(runs.prefix(visibleCount), calendar: calendar)
    }

    /// Groups consecutive runs by day, preserving the newest-first order.
    static func grouped(_ runs: ArraySlice<RecordingRun>, calendar: Calendar) -> [(date: Date, runs: [RecordingRun])] {
        var groups: [(date: Date, runs: [RecordingRun])] = []
        for run in runs {
            let day = calendar.startOfDay(for: run.date)
            if groups.last?.date == day { groups[groups.count - 1].runs.append(run) }
            else { groups.append((date: day, runs: [run])) }
        }
        return groups
    }

    private func displayedDate(in groups: [(date: Date, runs: [RecordingRun])]) -> Date? {
        if let activeDate, groups.contains(where: { $0.date == activeDate }) {
            return activeDate
        }
        return groups.first?.date
    }

    var body: some View {
        let groups = self.groups
        VStack(alignment: .leading, spacing: 0) {
            if let date = displayedDate(in: groups) {
                HistoryDateHeader(date: date, movingDown: movingToOlderDate)
                    .padding(.top, 5).padding(.bottom, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioStyle.paper)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.date) { group in
                        ForEach(group.runs) { run in
                            row(run)
                                .environment(\.historyRowHovered, hoveredRunID == run.id)
                                // Runs when the row is laid out, not when it scrolls. A row
                                // the lazy stack brings back reports only a changed frame,
                                // so frames are kept while the row is away.
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(contentSpace)) } action: { frame in
                                    layout.rows[run.id] = .init(day: group.date, frame: frame)
                                    follow()
                                }
                                .onAppear { layout.shown.insert(run.id); follow() }
                                .onDisappear { layout.shown.remove(run.id) }
                                .padding(.top, run.id == group.runs.first?.id && group.date != groups.first?.date ? 18 : 0)
                        }
                    }
                    if visibleCount < runs.count {
                        // A new identity per page so the sentinel fires again when
                        // the loaded rows still don't fill the viewport.
                        Color.clear.frame(height: 1)
                            .id(visibleCount)
                            .onAppear { visibleCount = min(visibleCount + Self.pageSize, runs.count) }
                    }
                }
                .coordinateSpace(name: contentSpace)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(scrollSpace)).minY } action: { top in
                    layout.contentTop = top
                    follow()
                }
            }
            .coordinateSpace(name: scrollSpace)
            .scrollIndicators(.automatic)
            // On the scroll view, which stays put, rather than on rows that move under the pointer.
            .onContinuousHover { phase in
                if case .active(let location) = phase { layout.pointer = location } else { layout.pointer = nil }
                follow()
            }
        }
    }

    /// Reads only the laid-out rows, so it is cheap enough for every scrolled frame.
    private func follow() {
        if let day = layout.topDay, day != activeDate {
            movingToOlderDate = day < (displayedDate(in: groups) ?? day)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                activeDate = day
            }
        }
        let hovered = layout.hoveredRow
        if hovered != hoveredRunID { hoveredRunID = hovered }
    }
}

/// Where the laid-out rows sit in the scrolled content, and where the content and
/// pointer are in the scroll view. Not observable: updating it redraws nothing.
@MainActor final class HistoryLayout {
    struct Row {
        let day: Date
        let frame: CGRect
    }

    var rows: [RecordingRun.ID: Row] = [:]
    /// Rows the lazy stack currently lays out; only their frames are current.
    var shown: Set<RecordingRun.ID> = []
    /// The content's top edge in the scroll view; negative once scrolled down.
    var contentTop: CGFloat = 0
    /// In the scroll view's coordinates; nil while the pointer is elsewhere.
    var pointer: CGPoint?

    /// The day of the topmost row still showing below the scroll view's top edge.
    var topDay: Date? {
        let edge = -contentTop
        var top: Row?
        for id in shown {
            guard let row = rows[id], row.frame.maxY > edge, row.frame.minY < (top?.frame.minY ?? .infinity) else { continue }
            top = row
        }
        return top?.day
    }

    var hoveredRow: RecordingRun.ID? {
        guard let pointer else { return nil }
        let y = pointer.y - contentTop
        return shown.first { rows[$0].map { $0.frame.minY <= y && y < $0.frame.maxY } ?? false }
    }
}

extension EnvironmentValues {
    /// Whether the pointer is over this history row; the timeline tracks it for every row at once.
    @Entry var historyRowHovered = false
}

private struct HistoryDateHeader: View {
    let date: Date
    let movingDown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private var format: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
    }

    var body: some View {
        HStack(spacing: 4) {
            component(date.formatted(format.day()))
                .monospacedDigit()
            component(date.formatted(format.month(.wide)).uppercased(with: locale))
            component(date.formatted(format.year()))
                .monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(StudioStyle.quiet)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(format.day().month(.wide).year()))
        .accessibilityAddTraits(.isHeader)
    }

    private func component(_ text: String) -> some View {
        ZStack(alignment: .leading) {
            Text(text)
                .fixedSize()
                .id(text)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .move(edge: movingDown ? .top : .bottom).combined(with: .opacity),
                    removal: .move(edge: movingDown ? .bottom : .top).combined(with: .opacity)
                ))
        }
        .frame(height: 16)
        .clipped()
    }
}
