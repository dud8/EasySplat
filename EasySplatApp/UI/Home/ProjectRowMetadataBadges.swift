import SwiftUI

/// Compact row of metadata badges (created date, output size, duration,
/// reconstruction quality chip) displayed under the project title in the
/// project list. Pulled out of ProjectListView so the SwiftUI type checker
/// has a shorter expression to reason about and so each badge can evolve
/// independently.
struct ProjectRowMetadataBadges: View {
    let project: ProjectSummary
    let createdAtText: String

    var body: some View {
        HStack(spacing: 8) {
            Text(createdAtText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let outputSize = project.outputSizeText {
                separator
                Text(outputSize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let duration = project.totalRunDurationText {
                separator
                Label(duration, systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let reconstruction = project.reconstruction {
                ReconstructionQualityChip(summary: reconstruction)
            }
            if let errorCount = project.recentErrorCount, errorCount > 0 {
                separator
                Label("\(errorCount) error\(errorCount == 1 ? "" : "s")", systemImage: "exclamationmark.octagon")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(errorCount >= 5 ? .red : .orange)
                    .help("Recent pipeline.log tail contains \(errorCount) error-level line\(errorCount == 1 ? "" : "s").")
            }
            Spacer(minLength: 0)
        }
    }

    private var separator: some View {
        Text("·")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
