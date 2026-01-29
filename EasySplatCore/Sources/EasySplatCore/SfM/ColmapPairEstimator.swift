struct ColmapPairEstimator {
    static func expectedExhaustivePairs(imageCount: Int) -> Int {
        guard imageCount > 1 else { return 0 }
        return imageCount * (imageCount - 1) / 2
    }

    static func expectedSequentialPairs(imageCount: Int, overlap: Int) -> Int {
        guard imageCount > 1 else { return 0 }
        let k = max(1, overlap)
        return (0..<imageCount).reduce(0) { acc, i in
            acc + max(0, min(k, imageCount - 1 - i))
        }
    }
}

