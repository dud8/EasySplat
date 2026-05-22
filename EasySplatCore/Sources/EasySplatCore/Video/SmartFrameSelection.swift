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

struct SmartFrameCandidate: Sendable {
    var index: Int
    var sharpness: Double
    var brightness: Double
    var clippedFraction: Double
    var dHash: UInt64?

    init(
        index: Int,
        sharpness: Double,
        brightness: Double = 0.5,
        clippedFraction: Double = 0,
        dHash: UInt64? = nil
    ) {
        self.index = index
        self.sharpness = sharpness
        self.brightness = brightness
        self.clippedFraction = clippedFraction
        self.dHash = dHash
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
        let limit = sharpnessLimit(maxScore: maxScore, config: config)
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

    static func selectBatch(
        candidates: [SmartFrameCandidate],
        config: SmartFrameSelectionConfig,
        fps: Double,
        lastSelectedIndex: inout Int,
        recentHashes: inout [UInt64]
    ) -> SmartFrameSelectionResult {
        guard !candidates.isEmpty else { return SmartFrameSelectionResult(selectedIndices: []) }
        let ordered = candidates.sorted { $0.index < $1.index }

        let rawCandidates = qualityFilteredCandidates(ordered, config: config)

        let targetFPS = max(1, config.targetFPS)
        let startIndex = ordered[0].index
        let count = ordered.count
        let targetOffsets = (0..<targetFPS).map { idx in
            Int(Double(count) * (Double(idx) + 0.5) / Double(targetFPS))
        }
        let targetIndices = targetOffsets.map { startIndex + $0 }

        let minDistance = Int(fps * config.minDistanceRatio)
        var selectedCandidates: [SmartFrameCandidate] = []
        var workingHashes = recentHashes
        var usedIndices = Set<Int>()

        for targetIndex in targetIndices {
            guard !rawCandidates.isEmpty else { break }
            let pool = rawCandidates.filter {
                !usedIndices.contains($0.index) && ($0.index - lastSelectedIndex) >= minDistance
            }
            guard !pool.isEmpty else { continue }
            let nearestDistance = pool.map { abs($0.index - targetIndex) }.min() ?? 0
            let localWindow = max(1, minDistance / 2)
            let localCandidates = pool.filter { abs($0.index - targetIndex) <= nearestDistance + localWindow }
            let searchCandidates = localCandidates.isEmpty ? pool : localCandidates
            let bestMatch = searchCandidates.max { lhs, rhs in
                candidateFitness(lhs, targetIndex: targetIndex, orderedCount: count, recentHashes: workingHashes)
                    < candidateFitness(rhs, targetIndex: targetIndex, orderedCount: count, recentHashes: workingHashes)
            }
            guard let bestMatch else { continue }

            selectedCandidates.append(bestMatch)
            usedIndices.insert(bestMatch.index)
            lastSelectedIndex = bestMatch.index
            appendHash(bestMatch.dHash, to: &workingHashes)
        }

        recentHashes = workingHashes
        return SmartFrameSelectionResult(selectedIndices: selectedCandidates.map(\.index))
    }

    static func candidateFitness(
        _ candidate: SmartFrameCandidate,
        targetIndex: Int,
        orderedCount: Int,
        recentHashes: [UInt64]
    ) -> Double {
        let distance = abs(candidate.index - targetIndex)
        let distancePenalty = Double(distance) * max(1.0, candidate.sharpness / Double(max(orderedCount, 1)))
        let duplicatePenalty = isNearDuplicate(candidate.dHash, recentHashes: recentHashes) ? max(60.0, candidate.sharpness) : 0
        return qualityScore(candidate) - distancePenalty - duplicatePenalty
    }

    static func sharpnessLimit(maxScore: Double, config: SmartFrameSelectionConfig) -> Double {
        max(config.sharpnessFloor, maxScore * config.sharpnessRatio)
    }

    static func qualityFilteredCandidates(
        _ candidates: [SmartFrameCandidate],
        config: SmartFrameSelectionConfig
    ) -> [SmartFrameCandidate] {
        let maxQuality = candidates.map { qualityScore($0) }.max() ?? 0
        let qualityLimit = max(0, maxQuality * config.sharpnessRatio)
        return candidates.filter {
            $0.sharpness >= config.sharpnessFloor
                && qualityScore($0) >= qualityLimit
        }
    }

    static func qualityScore(_ candidate: SmartFrameCandidate) -> Double {
        let brightness = min(max(candidate.brightness, 0), 1)
        let clipped = min(max(candidate.clippedFraction, 0), 1)
        let clippingPenalty = min(0.85, clipped * 1.5)
        let brightnessPenalty: Double
        if brightness < 0.18 {
            brightnessPenalty = min(0.45, (0.18 - brightness) * 1.8)
        } else if brightness > 0.88 {
            brightnessPenalty = min(0.55, (brightness - 0.88) * 2.5)
        } else {
            brightnessPenalty = 0
        }
        let multiplier = max(0.05, 1.0 - clippingPenalty - brightnessPenalty)
        return candidate.sharpness * multiplier
    }

    static func appendHash(_ hash: UInt64?, to recentHashes: inout [UInt64]) {
        guard let hash else { return }
        recentHashes.append(hash)
        let maxRecentHashes = 24
        if recentHashes.count > maxRecentHashes {
            recentHashes.removeFirst(recentHashes.count - maxRecentHashes)
        }
    }

    static func isNearDuplicate(_ hash: UInt64?, recentHashes: [UInt64]) -> Bool {
        guard let hash else { return false }
        return recentHashes.contains { hammingDistance(hash, $0) <= 8 }
    }

    private static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}
