import EasySplatCore
import SwiftUI

/// Per-stage timing breakdown shown on the viewer screen. Helps users see
/// where wall-clock time went without scrubbing pipeline logs.
struct StageTimingPanel: View {
    let timings: [StageTimingRecord]
    /// Optional reference total for this preset across the user's past runs.
    /// When present, the panel shows a small "+15% slower than your median"
    /// hint so users can spot regressions.
    var comparisonMedianSeconds: TimeInterval? = nil

    var body: some View {
        let surfaced = StageTimingDisplay.surfaceableStages(from: timings)
        if surfaced.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Pipeline timing")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let total = timings.totalDurationSeconds {
                        Text(StageTimingDisplay.formatDuration(seconds: total))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                stackedBar(records: surfaced)
                if let hint = comparisonHint {
                    Label(hint, systemImage: hintIcon)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(hintColor)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(surfaced, id: \.stage) { record in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(record.stage.timingBarColor)
                                    .frame(width: 6, height: 6)
                                Text(record.stage.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .gridColumnAlignment(.leading)
                            Text(record.displayDuration)
                                .font(.caption.monospacedDigit())
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.border)
            )
        }
    }

    private var comparison: StageTimingComparison {
        StageTimingComparison.compute(timings: timings, medianSeconds: comparisonMedianSeconds)
    }

    private var comparisonHint: String? {
        guard let median = comparisonMedianSeconds else { return nil }
        let medianText = StageTimingDisplay.formatDuration(seconds: median)
        switch comparison {
        case .unavailable, .withinBand: return nil
        case .slowerBy(let percent): return "+\(percent)% slower than your median (\(medianText))"
        case .fasterBy(let percent): return "-\(percent)% faster than your median (\(medianText))"
        }
    }

    private var hintIcon: String {
        switch comparison {
        case .slowerBy: return "tortoise"
        case .fasterBy: return "hare"
        case .withinBand, .unavailable: return "equal"
        }
    }

    private var hintColor: Color {
        switch comparison {
        case .slowerBy: return .orange
        case .fasterBy: return Theme.success
        case .withinBand, .unavailable: return .secondary
        }
    }

    private func stackedBar(records: [StageTimingRecord]) -> some View {
        // Guard against a degenerate run where every stage reported zero
        // duration; render a thin neutral bar so the panel still reads as
        // intentional rather than broken.
        let total = max(0.0001, records.reduce(0.0) { $0 + $1.durationSeconds })
        return GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(records, id: \.stage) { record in
                    let width = proxy.size.width * (record.durationSeconds / total)
                    record.stage.timingBarColor
                        .frame(width: max(2, width))
                        .help("\(record.stage.displayName): \(record.displayDuration)")
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: 8)
        .accessibilityLabel("Per-stage timing breakdown")
    }
}
