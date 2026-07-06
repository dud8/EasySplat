import EasySplatCore
import Foundation

/// Predicts the expected wall-clock duration of the next run by looking at
/// successful past runs that match the currently-selected mode and quality.
/// Uses the median (robust against outliers like cold-start cache misses) and
/// requires a minimum sample to avoid extrapolating from a single fluke run.
enum RunDurationPredictor {
    /// Minimum number of comparable past runs before the prediction surfaces.
    /// Lower than typical statistical wisdom because user-facing UI benefits
    /// from any signal at all once a couple of runs exist.
    static let minimumSamples = 2

    struct Prediction: Equatable {
        var seconds: TimeInterval
        var sampleCount: Int
    }

    static func predict(
        mode: CaptureMode,
        quality: QualityPreset,
        from projects: [ProjectSummary],
        excluding excludingURL: URL? = nil
    ) -> Prediction? {
        // Only consider successful past runs that match BOTH the current mode
        // and the current quality preset. Mixing draft/standard/ultra would
        // smear the median across very different time budgets. The caller
        // can opt to exclude one project (typically the one being viewed)
        // so the comparison badge never benchmarks a run against itself.
        let durations = projects
            .filter { $0.status == .ready && $0.url != excludingURL }
            .filter { matchesPreset(summary: $0, mode: mode, quality: quality) }
            .compactMap { $0.stageTimings.totalDurationSeconds }
            .filter { $0 > 0 }
        guard durations.count >= minimumSamples else { return nil }
        return Prediction(seconds: median(of: durations), sampleCount: durations.count)
    }

    private static func matchesPreset(summary: ProjectSummary, mode: CaptureMode, quality: QualityPreset) -> Bool {
        guard let preset = summary.preset else { return false }
        return preset.mode == mode && preset.quality == quality
    }

    /// Median duration of a single stage across successful past runs that
    /// match the current preset. Returns nil if we have fewer than
    /// `minimumSamples` observations.
    static func predictStage(
        _ stage: PipelineStage,
        mode: CaptureMode?,
        quality: QualityPreset?,
        from projects: [ProjectSummary]
    ) -> Prediction? {
        let durations = projects
            .filter { $0.status == .ready }
            .filter { project in
                guard let mode, let quality else { return true }
                return matchesPreset(summary: project, mode: mode, quality: quality)
            }
            .flatMap { $0.stageTimings }
            .filter { $0.stage == stage && $0.durationSeconds > 0 }
            .map { $0.durationSeconds }
        guard durations.count >= minimumSamples else { return nil }
        return Prediction(seconds: median(of: durations), sampleCount: durations.count)
    }

    static func medianForTesting(_ values: [TimeInterval]) -> TimeInterval {
        median(of: values)
    }

    private static func median(of values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
}

extension RunDurationPredictor.Prediction {
    var displayText: String {
        let durationText = StageTimingDisplay.formatDuration(seconds: seconds)
        let sampleText = sampleCount == 1 ? "1 past run" : "\(sampleCount) past runs"
        return "Estimated ~\(durationText) based on \(sampleText)"
    }
}
