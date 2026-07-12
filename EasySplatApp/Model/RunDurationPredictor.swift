import EasySplatCore
import Foundation

/// Predicts the expected wall-clock duration of the next run from genuinely
/// comparable successful runs.
/// Uses the median (robust against outliers like cold-start cache misses) and
/// requires a minimum sample to avoid extrapolating from a single fluke run.
enum RunDurationPredictor {
    /// Minimum number of comparable past runs before the prediction surfaces.
    static let minimumSamples = 3

    struct Prediction: Equatable {
        var seconds: TimeInterval
        var minimumSeconds: TimeInterval
        var maximumSeconds: TimeInterval
        var sampleCount: Int

        init(
            seconds: TimeInterval,
            minimumSeconds: TimeInterval,
            maximumSeconds: TimeInterval,
            sampleCount: Int
        ) {
            self.seconds = seconds
            self.minimumSeconds = minimumSeconds
            self.maximumSeconds = maximumSeconds
            self.sampleCount = sampleCount
        }
    }

    static func predict(
        options: RequestedRunOptions,
        input: InputSpec,
        from projects: [ProjectSummary],
        excluding excludingURL: URL? = nil
    ) -> Prediction? {
        let inputShape = InputShape(input)
        return prediction(from: projects
            .filter { $0.status == .ready && $0.url != excludingURL }
            .filter { $0.requestedRunOptions == options }
            .filter { summary in
                summary.input.map(InputShape.init) == inputShape
            }
            .compactMap { $0.stageTimings.totalDurationSeconds }
            .filter { $0 > 0 })
    }

    private enum InputShape: Equatable {
        case videos(ClipCount)
        case photos
        case mixed(ClipCount)

        init(_ input: InputSpec) {
            switch input {
            case .video(let files):
                self = .videos(ClipCount(files.count))
            case .photos:
                self = .photos
            case .mixed(let videos, _):
                self = .mixed(ClipCount(videos.count))
            }
        }
    }

    private enum ClipCount: Equatable {
        case one
        case few
        case many

        init(_ count: Int) {
            if count <= 1 {
                self = .one
            } else if count <= 3 {
                self = .few
            } else {
                self = .many
            }
        }
    }

    private static func prediction(from durations: [TimeInterval]) -> Prediction? {
        guard durations.count >= minimumSamples else { return nil }
        return Prediction(
            seconds: median(of: durations),
            minimumSeconds: durations.min() ?? 0,
            maximumSeconds: durations.max() ?? 0,
            sampleCount: durations.count
        )
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
        let minimum = StageTimingDisplay.formatDuration(seconds: minimumSeconds)
        let maximum = StageTimingDisplay.formatDuration(seconds: maximumSeconds)
        let range = minimum == maximum ? minimum : "\(minimum)–\(maximum)"
        return "Usually \(range) · \(sampleCount) similar runs"
    }
}
