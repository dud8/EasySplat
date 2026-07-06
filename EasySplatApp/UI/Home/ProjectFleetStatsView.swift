import SwiftUI

/// Compact summary row shown above the project list. Designed to disappear
/// when there is nothing meaningful to show (no successful runs and no
/// recorded run time), so the home screen stays clean on first launch.
struct ProjectFleetStatsView: View {
    let stats: ProjectFleetStats
    var freeDiskBytes: Int64? = nil

    var body: some View {
        if shouldHide {
            EmptyView()
        } else {
            // Many small cards can run wider than the home column. Wrap in a
            // horizontal ScrollView so the row never clips, but keep the
            // outer ScrollView's vertical scroll feel natural.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    statCard(label: "Projects", value: "\(stats.totalProjects)")
                    if stats.readyProjects > 0 {
                        statCard(label: "Ready", value: "\(stats.readyProjects)", tint: Theme.success)
                    }
                    if stats.failedProjects > 0 {
                        statCard(label: "Failed", value: "\(stats.failedProjects)", tint: .red)
                    }
                    if let duration = stats.totalRunDurationText {
                        statCard(label: "Total run time", value: duration)
                    }
                    if let sfm = stats.totalSfmDurationText {
                        statCard(label: "SfM time", value: sfm)
                    }
                    if let training = stats.totalTrainingDurationText {
                        statCard(label: "Training time", value: training)
                    }
                    if let coverage = stats.averageCoverageText {
                        statCard(label: "Avg coverage", value: coverage)
                    }
                    if let lastSuccess = stats.lastSuccessfulText {
                        statCard(label: "Last success", value: lastSuccess)
                    }
                    if let lastFailure = stats.lastFailureText {
                        statCard(label: "Last failure", value: lastFailure, tint: .red)
                    }
                    if let diskText {
                        statCard(label: "Free disk", value: diskText, tint: diskTint)
                    }
                }
            }
        }
    }

    private var shouldHide: Bool {
        return stats.totalProjects == 0
    }

    private var diskText: String? {
        guard let bytes = freeDiskBytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var diskTint: Color {
        guard let bytes = freeDiskBytes else { return Theme.accent }
        return bytes < AppModel.recommendedFreeSpaceBytes ? .orange : Theme.accent
    }

    private func statCard(label: String, value: String, tint: Color = Theme.accent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .stroke(Theme.border)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
