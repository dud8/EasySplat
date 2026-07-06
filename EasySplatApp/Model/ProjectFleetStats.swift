import EasySplatCore
import Foundation

/// Aggregate statistics across every project visible on the home screen.
/// Computed by folding over `[ProjectSummary]` so the home screen does not need
/// to re-read project.json files. Designed to be cheap (linear in projects).
struct ProjectFleetStats: Equatable {
    var totalProjects: Int
    var readyProjects: Int
    var failedProjects: Int
    var inProgressProjects: Int
    var totalRunSeconds: TimeInterval
    var totalSfmSeconds: TimeInterval
    var totalTrainingSeconds: TimeInterval
    var averageRegisteredFraction: Double?
    var lastSuccessfulCompletionAt: Date?
    var lastFailureAt: Date?

    static let empty = ProjectFleetStats(
        totalProjects: 0,
        readyProjects: 0,
        failedProjects: 0,
        inProgressProjects: 0,
        totalRunSeconds: 0,
        totalSfmSeconds: 0,
        totalTrainingSeconds: 0,
        averageRegisteredFraction: nil,
        lastSuccessfulCompletionAt: nil,
        lastFailureAt: nil
    )

    /// Compute the median registered-frame fraction across the user's
    /// successful past runs, excluding the project at `excludingURL` so the
    /// comparison badge does not benchmark a project against itself.
    /// Requires at least 2 comparison samples to avoid noisy single-run baselines.
    static func medianCoverage(
        excluding excludingURL: URL?,
        from projects: [ProjectSummary]
    ) -> Double? {
        let fractions = projects
            .filter { $0.status == .ready && $0.url != excludingURL }
            .compactMap { $0.reconstruction?.registeredFraction }
        guard fractions.count >= 2 else { return nil }
        let sorted = fractions.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Aggregate the supplied summaries into a single stats struct. Skips
    /// `needsAppUpdate` projects because they cannot be acted on and would
    /// otherwise inflate the totals with stale data.
    static func aggregate(_ projects: [ProjectSummary]) -> ProjectFleetStats {
        var stats = ProjectFleetStats.empty
        var fractionSum: Double = 0
        var fractionCount: Int = 0

        for project in projects where project.status != .needsAppUpdate {
            stats.totalProjects += 1
            switch project.status {
            case .ready: stats.readyProjects += 1
            case .failed: stats.failedProjects += 1
            case .inProgress: stats.inProgressProjects += 1
            case .needsAppUpdate: break
            }
            if let total = project.stageTimings.totalDurationSeconds {
                stats.totalRunSeconds += total
            }
            for record in project.stageTimings {
                switch record.stage {
                case .sfmFeatures, .sfmMatching, .sfmMapping:
                    stats.totalSfmSeconds += record.durationSeconds
                case .trainBrush:
                    stats.totalTrainingSeconds += record.durationSeconds
                default:
                    break
                }
            }
            if project.status == .ready, let fraction = project.reconstruction?.registeredFraction {
                fractionSum += fraction
                fractionCount += 1
            }
            if project.status == .ready {
                let candidate = project.lastRunCompletedAt
                if stats.lastSuccessfulCompletionAt.map({ $0 < candidate }) ?? true {
                    stats.lastSuccessfulCompletionAt = candidate
                }
            }
            if project.status == .failed {
                // Prefer the persisted failure timestamp written by
                // PipelineRunner.emitFailure. Fall back to lastActivityAt for
                // legacy projects without the persisted field so the card
                // still has something to show.
                let candidate = project.lastFailureAt ?? project.lastActivityAt
                if stats.lastFailureAt.map({ $0 < candidate }) ?? true {
                    stats.lastFailureAt = candidate
                }
            }
        }
        if fractionCount > 0 {
            stats.averageRegisteredFraction = fractionSum / Double(fractionCount)
        }
        return stats
    }

    var totalRunDurationText: String? {
        guard totalRunSeconds > 0 else { return nil }
        return StageTimingDisplay.formatDuration(seconds: totalRunSeconds)
    }

    var totalSfmDurationText: String? {
        guard totalSfmSeconds > 0 else { return nil }
        return StageTimingDisplay.formatDuration(seconds: totalSfmSeconds)
    }

    var totalTrainingDurationText: String? {
        guard totalTrainingSeconds > 0 else { return nil }
        return StageTimingDisplay.formatDuration(seconds: totalTrainingSeconds)
    }

    var averageCoverageText: String? {
        guard let fraction = averageRegisteredFraction else { return nil }
        return String(format: "%.0f%%", fraction * 100)
    }

    var lastSuccessfulText: String? {
        guard let date = lastSuccessfulCompletionAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var lastFailureText: String? {
        guard let date = lastFailureAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
