import Foundation
import CoreMedia

struct SmartFrameCandidate: Sendable {
    var index: Int
    var sharpness: Double
    var brightness: Double
    var clippedFraction: Double
    var motionScore: Double
    var dHash: UInt64?

    init(
        index: Int,
        sharpness: Double,
        brightness: Double = 0.5,
        clippedFraction: Double = 0,
        motionScore: Double = 0,
        dHash: UInt64? = nil
    ) {
        self.index = index
        self.sharpness = sharpness
        self.brightness = brightness
        self.clippedFraction = clippedFraction
        self.motionScore = motionScore
        self.dHash = dHash
    }
}

struct TimedFrameCandidate: Sendable {
    var frameIndex: Int
    var timestampSeconds: Double
    var candidate: SmartFrameCandidate
    var presentationTime: CMTime? = nil
}

enum SmartFrameSelection {
    static func selectTimeline(
        _ candidates: [TimedFrameCandidate],
        targetCount: Int,
        minimumTimeDistance: Double
    ) -> [TimedFrameCandidate] {
        guard targetCount > 0 else { return [] }

        var seenFrameIndices = Set<Int>()
        let ordered = candidates
            .filter { $0.timestampSeconds.isFinite && $0.timestampSeconds >= 0 }
            .sorted(by: timelineOrder)
            .filter { seenFrameIndices.insert($0.frameIndex).inserted }
        guard !ordered.isEmpty else { return [] }
        guard ordered.count > 1 else { return ordered }

        let slotCount = min(targetCount, ordered.count)
        if slotCount == 1 {
            let index = bestCandidateIndex(
                in: ordered,
                range: ordered.indices,
                targetTime: ordered[0].timestampSeconds,
                targetSpacing: 0,
                previousTime: nil,
                minimumTimeDistance: 0,
                recentHashes: []
            )
            return [ordered[index]]
        }

        let firstTime = ordered[0].timestampSeconds
        let lastTime = ordered[ordered.count - 1].timestampSeconds
        let duration = max(0, lastTime - firstTime)
        let targetSpacing = duration / Double(slotCount - 1)
        let safeDistance = max(0, minimumTimeDistance)
        var selected: [TimedFrameCandidate] = []
        selected.reserveCapacity(slotCount)
        var recentHashes: [UInt64] = []
        var previousOrderedIndex = 0

        for slot in 0..<slotCount {
            if slot == 0 {
                let first = ordered[0]
                selected.append(first)
                appendImmediateHash(first.candidate.dHash, to: &recentHashes)
                continue
            }
            if slot == slotCount - 1 {
                let last = ordered[ordered.count - 1]
                selected.append(last)
                appendImmediateHash(last.candidate.dHash, to: &recentHashes)
                continue
            }
            let targetTime = firstTime + Double(slot) * targetSpacing
            let minimumIndex = previousOrderedIndex + 1
            let remainingAfterSlot = slotCount - slot - 1
            let maximumIndex = ordered.count - remainingAfterSlot - 1
            let lowerTime = targetTime - targetSpacing / 2
            let upperTime = targetTime + targetSpacing / 2
            let windowStart = max(
                minimumIndex,
                lowerBound(in: ordered, timestamp: lowerTime)
            )
            let windowEnd = min(
                maximumIndex + 1,
                lowerBound(in: ordered, timestamp: upperTime)
            )
            let candidateRange = windowStart < windowEnd
                ? windowStart..<windowEnd
                : minimumIndex..<(maximumIndex + 1)
            let bestIndex = bestCandidateIndex(
                in: ordered,
                range: candidateRange,
                targetTime: targetTime,
                targetSpacing: targetSpacing,
                previousTime: selected.last?.timestampSeconds,
                minimumTimeDistance: safeDistance,
                recentHashes: recentHashes
            )
            let best = ordered[bestIndex]
            selected.append(best)
            previousOrderedIndex = bestIndex
            appendImmediateHash(best.candidate.dHash, to: &recentHashes)
        }

        return selected
    }

    private static func bestCandidateIndex(
        in candidates: [TimedFrameCandidate],
        range: Range<Int>,
        targetTime: Double,
        targetSpacing: Double,
        previousTime: Double?,
        minimumTimeDistance: Double,
        recentHashes: [UInt64]
    ) -> Int {
        precondition(!range.isEmpty)
        var bestIndex = range.lowerBound
        var best = candidates[bestIndex]
        var bestFitness = timelineFitness(
            best,
            targetTime: targetTime,
            targetSpacing: targetSpacing,
            previousTime: previousTime,
            minimumTimeDistance: minimumTimeDistance,
            recentHashes: recentHashes
        )

        for index in range.dropFirst() {
            let candidate = candidates[index]
            let fitness = timelineFitness(
                candidate,
                targetTime: targetTime,
                targetSpacing: targetSpacing,
                previousTime: previousTime,
                minimumTimeDistance: minimumTimeDistance,
                recentHashes: recentHashes
            )
            if fitness > bestFitness
                || (fitness == bestFitness
                    && tieBreaksBefore(candidate, best, targetTime: targetTime)) {
                best = candidate
                bestIndex = index
                bestFitness = fitness
            }
        }
        return bestIndex
    }

    private static func lowerBound(
        in candidates: [TimedFrameCandidate],
        timestamp: Double
    ) -> Int {
        var lower = 0
        var upper = candidates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if candidates[middle].timestampSeconds < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func timelineFitness(
        _ value: TimedFrameCandidate,
        targetTime: Double,
        targetSpacing: Double,
        previousTime: Double?,
        minimumTimeDistance: Double,
        recentHashes: [UInt64]
    ) -> Double {
        let quality = qualityScore(value.candidate)
        let normalizedDistance = targetSpacing > 0
            ? abs(value.timestampSeconds - targetTime) / targetSpacing
            : 0
        let timingPenalty = normalizedDistance * max(5, quality * 0.15)
        let spacingPenalty: Double
        if let previousTime, minimumTimeDistance > 0 {
            let distance = max(0, value.timestampSeconds - previousTime)
            let deficit = max(0, minimumTimeDistance - distance)
                / minimumTimeDistance
            spacingPenalty = deficit * quality * 0.2
        } else {
            spacingPenalty = 0
        }
        let duplicatePenalty = isNearDuplicate(
            value.candidate.dHash,
            recentHashes: recentHashes
        ) ? max(60, quality) : 0
        return quality - timingPenalty - spacingPenalty - duplicatePenalty
    }

    private static func timelineOrder(
        _ lhs: TimedFrameCandidate,
        _ rhs: TimedFrameCandidate
    ) -> Bool {
        if lhs.timestampSeconds != rhs.timestampSeconds {
            return lhs.timestampSeconds < rhs.timestampSeconds
        }
        if lhs.frameIndex != rhs.frameIndex {
            return lhs.frameIndex < rhs.frameIndex
        }
        let lhsQuality = qualityScore(lhs.candidate)
        let rhsQuality = qualityScore(rhs.candidate)
        if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
        return (lhs.candidate.dHash ?? 0) < (rhs.candidate.dHash ?? 0)
    }

    private static func tieBreaksBefore(
        _ lhs: TimedFrameCandidate,
        _ rhs: TimedFrameCandidate,
        targetTime: Double
    ) -> Bool {
        let lhsDistance = abs(lhs.timestampSeconds - targetTime)
        let rhsDistance = abs(rhs.timestampSeconds - targetTime)
        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
        if lhs.timestampSeconds != rhs.timestampSeconds {
            return lhs.timestampSeconds < rhs.timestampSeconds
        }
        return lhs.frameIndex < rhs.frameIndex
    }

    private static func qualityScore(_ candidate: SmartFrameCandidate) -> Double {
        let sharpness = candidate.sharpness.isFinite ? max(0, candidate.sharpness) : 0
        let brightness = candidate.brightness.isFinite
            ? min(max(candidate.brightness, 0), 1)
            : 0.5
        let clipped = candidate.clippedFraction.isFinite
            ? min(max(candidate.clippedFraction, 0), 1)
            : 1
        let clippingPenalty = min(0.85, clipped * 1.5)
        let brightnessPenalty: Double
        if brightness < 0.18 {
            brightnessPenalty = min(0.45, (0.18 - brightness) * 1.8)
        } else if brightness > 0.88 {
            brightnessPenalty = min(0.55, (brightness - 0.88) * 2.5)
        } else {
            brightnessPenalty = 0
        }
        let motion = candidate.motionScore.isFinite
            ? min(max(candidate.motionScore, 0), 1)
            : 0
        let multiplier = max(0.05, 1 - clippingPenalty - brightnessPenalty)
            * (1 + motion * 0.03)
        return sharpness * multiplier
    }

    private static func appendImmediateHash(
        _ hash: UInt64?,
        to recentHashes: inout [UInt64]
    ) {
        guard let hash else { return }
        recentHashes.append(hash)
        if recentHashes.count > 2 {
            recentHashes.removeFirst(recentHashes.count - 2)
        }
    }

    private static func isNearDuplicate(
        _ hash: UInt64?,
        recentHashes: [UInt64]
    ) -> Bool {
        guard let hash else { return false }
        return recentHashes.contains { (hash ^ $0).nonzeroBitCount <= 8 }
    }
}
