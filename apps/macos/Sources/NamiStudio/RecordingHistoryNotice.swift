import SwiftUI

/// App status stays separate from recognized speech, including when a failed
/// operation recovered some text. Color is reinforced by an icon and a label.
struct RecordingHistoryNotice {
    let title: String
    let detail: String
    let symbol: String
    let needsAttention: Bool

    static let ink = Color(light: (0.49, 0.25, 0.12), dark: (0.945, 0.753, 0.608))
    static let background = Color(light: (0.985, 0.948, 0.905), dark: (0.196, 0.145, 0.106))
    static let border = Color(light: (0.86, 0.72, 0.58), dark: (0.478, 0.337, 0.231))
}

extension RecordingRun {
    var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var historyNotice: RecordingHistoryNotice? {
        let retained = hasTranscript
            ? "Your recording is kept. Recovered text is shown below."
            : "No transcript was produced. Your recording is kept."
        switch outcome {
        case .failed:
            return .init(title: "Transcription failed", detail: retained,
                         symbol: "exclamationmark.triangle.fill", needsAttention: true)
        case .interrupted:
            return .init(title: "Transcription interrupted", detail: retained,
                         symbol: "exclamationmark.circle.fill", needsAttention: true)
        case .cancelled:
            return .init(title: "Transcription cancelled", detail: retained,
                         symbol: "stop.circle", needsAttention: true)
        case .completed:
            if let cleanupResult, !cleanupResult.succeeded {
                return .init(title: "Cleanup not applied", detail: "Your original transcript is kept below.",
                             symbol: "exclamationmark.triangle.fill", needsAttention: true)
            }
            if !hasTranscript {
                return .init(title: "No speech recognized", detail: "Listen to the recording to check the audio.",
                             symbol: "waveform", needsAttention: false)
            }
            return nil
        }
    }
}

struct RecordingHistoryText: View {
    let run: RecordingRun
    let transcriptFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = run.historyNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 15)).padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(notice.title).font(.system(size: 13, weight: .semibold))
                        Text(notice.detail).font(.system(size: 12)).lineSpacing(3)
                    }
                }
                .foregroundStyle(notice.needsAttention ? RecordingHistoryNotice.ink : StudioStyle.quiet)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Nami status: \(notice.title). \(notice.detail)")
            }
            if run.hasTranscript {
                if run.historyNotice != nil { StudioStyle.divider }
                Text(run.transcript)
                    .font(transcriptFont).foregroundStyle(StudioStyle.ink)
                    .lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
