import EasySplatCore
import SwiftUI

/// Full reconstruction quality breakdown shown on the viewer screen.
/// Gives the user the same metrics a postdoc would expect from a COLMAP
/// `model_analyzer` run, without forcing them to dig through logs.
struct ReconstructionDetailPanel: View {
    let summary: ReconstructionSummary
    /// Fleet median registered-fraction for comparison; nil hides the badge.
    var fleetMedianFraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Reconstruction quality")
                    .font(.subheadline.weight(.semibold))
                qualityPill
                Spacer()
                Text(summary.displayMapper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            metricsGrid

            if let comparisonText {
                Label(comparisonText, systemImage: comparisonIcon)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(comparisonColor)
                    .help("\"Your usual\" is the median registered-frame coverage across your past successful runs. Deltas are reported in percentage points (e.g. 90% → 95% is +5 pp). The badge appears when this run differs from that median by 2 pp or more.")
            }

            if summary.hasOnlyCoverage {
                Text("Detailed quality metrics were not measured for this run.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if let captured = capturedAtText {
                Text("Captured \(captured)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private var metricsGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            metricRow(label: "Frames registered", value: "\(summary.registeredImages) of \(summary.totalImages) (\(summary.registeredPercentText))")
            if let points = summary.pointCountText {
                metricRow(label: "Points", value: points)
            }
            if let obs = summary.observationCountText {
                metricRow(label: "Observations", value: obs)
            }
            if let track = summary.meanTrackLengthText {
                metricRow(label: "Mean track length", value: track)
            }
            if let reproj = summary.meanReprojectionErrorText {
                metricRow(label: "Mean reprojection error", value: reproj)
            }
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .gridColumnAlignment(.trailing)
        }
    }

    private var qualityColor: Color {
        switch summary.quality {
        case .strong: return Theme.success
        case .fair: return Theme.accent
        case .low: return .orange
        }
    }

    private var qualityLabel: String {
        switch summary.quality {
        case .strong: return "Strong"
        case .fair: return "Fair"
        case .low: return "Low"
        }
    }

    private var qualityPill: some View {
        Text(qualityLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(qualityColor)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(qualityColor.opacity(0.13))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(qualityColor.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityLabel("Reconstruction quality \(qualityLabel)")
    }

    /// Threshold below which we treat the run as effectively at the user's
    /// usual coverage and skip the up/down badge to avoid noisy chatter.
    private static let comparisonThreshold: Double = 0.02

    private var comparisonText: String? {
        guard let baseline = fleetMedianFraction else { return nil }
        let delta = summary.registeredFraction - baseline
        guard abs(delta) >= Self.comparisonThreshold else { return nil }
        // Delta is in percentage points (absolute), not a relative percent,
        // so use "pp" so a "+5 pp" badge on 90% reads as 95% rather than
        // being mistaken for a 4.5% relative change.
        let points = Int((delta * 100).rounded())
        if delta > 0 {
            return "+\(points) pp above your usual coverage"
        }
        return "\(points) pp below your usual coverage"
    }

    private var comparisonIcon: String {
        guard let baseline = fleetMedianFraction else { return "equal" }
        return summary.registeredFraction >= baseline ? "arrow.up.right" : "arrow.down.right"
    }

    private var comparisonColor: Color {
        guard let baseline = fleetMedianFraction else { return .secondary }
        return summary.registeredFraction >= baseline ? Theme.success : .orange
    }

    private var capturedAtText: String? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: summary.capturedAt)
    }
}
