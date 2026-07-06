import EasySplatCore
import SwiftUI

/// Compact chip used in the project list to surface reconstruction quality.
/// Click target should remain the parent row; this view is purely decorative.
struct ReconstructionQualityChip: View {
    let summary: ReconstructionSummary

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(qualityColor)
                .frame(width: 7, height: 7)
            Text(summary.compactSummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            Capsule(style: .continuous)
                .fill(qualityColor.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(qualityColor.opacity(0.32), lineWidth: 0.5)
        )
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var qualityColor: Color {
        switch summary.quality {
        case .strong: return Theme.success
        case .fair: return Theme.accent
        case .low: return .orange
        }
    }

    private var tooltip: String {
        var lines: [String] = []
        lines.append("Mapper: \(summary.displayMapper)")
        lines.append("Coverage: \(summary.registeredImages) of \(summary.totalImages) frames (\(summary.registeredPercentText))")
        if let pts = summary.pointCountText {
            lines.append("Points: \(pts)")
        }
        if let obs = summary.observationCountText {
            lines.append("Observations: \(obs)")
        }
        if let track = summary.meanTrackLengthText {
            lines.append("Mean track length: \(track)")
        }
        if let reproj = summary.meanReprojectionErrorText {
            lines.append("Mean reprojection error: \(reproj)")
        }
        if summary.hasOnlyCoverage {
            lines.append("Detailed quality metrics were not measured for this run.")
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        "Reconstruction quality \(summary.quality.rawValue), \(summary.compactSummary)"
    }
}
