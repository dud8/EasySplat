import EasySplatCore
import Foundation
import SwiftUI

enum StageTimingComparison: Equatable {
    case unavailable
    case withinBand
    case slowerBy(percent: Int)
    case fasterBy(percent: Int)

    /// Compare a run's total wall-clock time to the user's median across past
    /// runs at the same preset. The 10% deadband matches the reconstruction
    /// coverage badge so the two surfaces feel consistent. Pure data — no
    /// SwiftUI dependencies so it can be unit-tested directly.
    static func compute(timings: [StageTimingRecord], medianSeconds: TimeInterval?) -> StageTimingComparison {
        guard let median = medianSeconds, median > 0 else { return .unavailable }
        guard let total = timings.totalDurationSeconds, total > 0 else { return .unavailable }
        let delta = total - median
        let fraction = delta / median
        guard abs(fraction) >= 0.10 else { return .withinBand }
        let percent = Int((abs(fraction) * 100).rounded())
        return delta > 0 ? .slowerBy(percent: percent) : .fasterBy(percent: percent)
    }
}

enum StageTimingDisplay {
    /// Human-friendly summary of total wall-clock time, e.g., "12m 30s".
    static func formatDuration(seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let rem = totalSeconds % 60
            return rem == 0 ? "\(minutes)m" : "\(minutes)m \(rem)s"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// Stages we want to surface in the per-stage breakdown. Pipeline stages
    /// that are mostly bookkeeping (importInput) are omitted to keep the
    /// summary focused on time the user actually waited on.
    static func surfaceableStages(from timings: [StageTimingRecord]) -> [StageTimingRecord] {
        let hiddenStages: Set<PipelineStage> = [.importInput]
        return timings
            .filter { !hiddenStages.contains($0.stage) }
            .sorted { $0.startedAt < $1.startedAt }
    }
}

extension StageTimingRecord {
    var displayDuration: String {
        StageTimingDisplay.formatDuration(seconds: durationSeconds)
    }
}

extension PipelineStage {
    /// Color used in the stage-timing bar so each stage stays visually
    /// distinct without burning through the system accent palette. Picked
    /// to read well on both light and dark macOS appearance.
    var timingBarColor: Color {
        switch self {
        case .importInput: return .gray
        case .extractFrames: return .teal
        case .selectFrames: return .mint
        case .sfmFeatures: return .blue
        case .sfmMatching: return .indigo
        case .sfmMapping: return .purple
        case .trainSplat: return .orange
        case .exportSplat: return Theme.success
        case .done: return Theme.success
        }
    }
}
