import SwiftUI

/// One stationary date above the scrolling transcripts. Measure rows rather than
/// section headers: a lazy stack may discard a header during a long day's history.
struct RecordingHistoryTimeline<Row: View>: View {
    let groups: [(date: Date, runs: [RecordingRun])]
    @ViewBuilder var row: (RecordingRun) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeDate: Date?
    @State private var movingToOlderDate = true
    @Namespace private var scrollSpace

    private var displayedDate: Date? {
        if let activeDate, groups.contains(where: { $0.date == activeDate }) {
            return activeDate
        }
        return groups.first?.date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let date = displayedDate {
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
                                .padding(.top, run.id == group.runs.first?.id && group.date != groups.first?.date ? 18 : 0)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: HistoryDayFrames.self,
                                            value: [group.date: geometry.frame(in: .named(scrollSpace))]
                                        )
                                    }
                                }
                        }
                    }
                }
            }
            .coordinateSpace(name: scrollSpace)
            .scrollIndicators(.automatic)
            .onPreferenceChange(HistoryDayFrames.self) { frames in
                guard let date = HistoryDayFrames.topDate(in: frames), date != displayedDate else { return }
                movingToOlderDate = date < (displayedDate ?? date)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                    activeDate = date
                }
            }
        }
    }
}

private struct HistoryDayFrames: PreferenceKey {
    static let defaultValue: [Date: CGRect] = [:]

    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $0.union($1) })
    }

    static func topDate(in frames: [Date: CGRect]) -> Date? {
        frames.filter { $0.value.maxY > 0 }
            .min { $0.value.minY < $1.value.minY }?.key
    }
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
