import Foundation

public struct SmartFrameSelectionConfig: Sendable {
    public var targetFPS: Int
    public var minDistanceRatio: Double
    public var sharpnessFloor: Double
    public var sharpnessRatio: Double

    public init(targetFPS: Int, minDistanceRatio: Double, sharpnessFloor: Double, sharpnessRatio: Double) {
        self.targetFPS = max(1, targetFPS)
        self.minDistanceRatio = minDistanceRatio
        self.sharpnessFloor = sharpnessFloor
        self.sharpnessRatio = sharpnessRatio
    }
}

public struct SmartFrameSelectionResult: Sendable {
    public var selectedIndices: [Int]

    public init(selectedIndices: [Int]) {
        self.selectedIndices = selectedIndices
    }
}

public enum SmartFrameSelection {
    public static func selectBatch(
        scores: [(index: Int, sharpness: Double)],
        config: SmartFrameSelectionConfig,
        fps: Double,
        lastSelectedIndex: inout Int
    ) -> SmartFrameSelectionResult {
        guard !scores.isEmpty else { return SmartFrameSelectionResult(selectedIndices: []) }
        let ordered = scores.sorted { $0.index < $1.index }

        let maxScore = ordered.map { $0.sharpness }.max() ?? 0
        let limit = max(config.sharpnessFloor, maxScore * config.sharpnessRatio)
        let candidates = ordered.filter { $0.sharpness >= limit }

        let targetFPS = max(1, config.targetFPS)
        let startIndex = ordered[0].index
        let count = ordered.count
        let targetOffsets = (0..<targetFPS).map { idx in
            Int(Double(count) * (Double(idx) + 0.5) / Double(targetFPS))
        }
        let targetIndices = targetOffsets.map { startIndex + $0 }

        var selected: [(index: Int, sharpness: Double)] = []
        for targetIndex in targetIndices {
            guard !candidates.isEmpty else { break }
            let bestMatch = candidates.min { lhs, rhs in
                abs(lhs.index - targetIndex) < abs(rhs.index - targetIndex)
            }
            if let bestMatch {
                selected.append(bestMatch)
            }
        }

        selected.sort { $0.index < $1.index }

        let minDistance = Int(fps * config.minDistanceRatio)
        var finalSelection: [Int] = []
        for candidate in selected {
            let index = candidate.index
            if finalSelection.last == index {
                continue
            }
            let distance = index - lastSelectedIndex
            if distance < minDistance {
                continue
            }
            finalSelection.append(index)
            lastSelectedIndex = index
        }

        return SmartFrameSelectionResult(selectedIndices: finalSelection)
    }
}
