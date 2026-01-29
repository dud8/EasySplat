import Foundation

public final class FrameSelector {
    public init() {}

    public enum FrameSelectionMode: Sendable {
        case legacy
        case smartExtracted
    }

    public func selectFrames(
        from frames: [URL],
        targetCount: Int,
        mode: FrameSelectionMode = .legacy,
        progress: @escaping @Sendable (Double, String) -> Void
    ) -> [URL] {
        guard !frames.isEmpty else { return [] }
        guard targetCount > 0 else { return [] }
        var scored: [(URL, FrameScore)] = []
        scored.reserveCapacity(frames.count)
        for (index, url) in frames.enumerated() {
            if let score = try? FrameScoring.scoreFrame(at: url) {
                scored.append((url, score))
            }
            progress(Double(index + 1) / Double(frames.count), "Scoring frames")
        }
        if scored.isEmpty {
            return downsample(frames: frames, targetCount: targetCount)
        }

        switch mode {
        case .legacy:
            let blurScores = scored.map { $0.1.blurScore }.sorted()
            let blurThreshold = blurScores.isEmpty ? 0 : blurScores[Int(Double(blurScores.count) * 0.3)]
            let filtered = scored.filter { $0.1.blurScore >= blurThreshold && $0.1.clippedFraction < 0.35 }
            let deduped = dedupeByHash(filtered)
            let fallback = filtered.isEmpty ? scored : filtered
            let candidates = deduped.isEmpty ? fallback : deduped
            return downsample(frames: candidates.map { $0.0 }, targetCount: targetCount)
        case .smartExtracted:
            let deduped = dedupeByHash(scored)
            let candidates = deduped.isEmpty ? scored : deduped
            return downsample(frames: candidates.map { $0.0 }, targetCount: targetCount)
        }
    }

    private func downsample(frames: [URL], targetCount: Int) -> [URL] {
        guard !frames.isEmpty else { return [] }
        guard targetCount > 0 else { return [] }
        if targetCount == 1 {
            return [frames[frames.count / 2]]
        }
        if frames.count <= targetCount { return frames }
        let step = Double(frames.count - 1) / Double(targetCount - 1)
        var selected: [URL] = []
        for i in 0..<targetCount {
            let index = Int(round(Double(i) * step))
            selected.append(frames[index])
        }
        return selected
    }

    private func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    private func dedupeByHash(_ scored: [(URL, FrameScore)]) -> [(URL, FrameScore)] {
        var deduped: [(URL, FrameScore)] = []
        var lastHash: UInt64?
        for (url, score) in scored {
            if let last = lastHash {
                if hammingDistance(score.dHash, last) < 8 {
                    continue
                }
            }
            deduped.append((url, score))
            lastHash = score.dHash
        }
        return deduped
    }
}
