import Foundation

final class ColmapFeatureProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction: Double = 0

    func ingest(_ line: String) -> (fraction: Double, message: String)? {
        guard let parsed = Self.parseProcessedFile(line) else { return nil }
        let (done, total) = parsed
        guard total > 0 else { return nil }
        let rawFraction = Double(done) / Double(total)
        let fraction = max(0, min(0.99, rawFraction))

        lock.lock()
        defer { lock.unlock() }
        guard fraction > lastFraction else { return nil }
        lastFraction = fraction
        return (fraction, "Finding features (\(done)/\(total))")
    }

    private static func parseProcessedFile(_ line: String) -> (done: Int, total: Int)? {
        guard let range = line.range(of: "Processed file [") else { return nil }
        let afterLeft = range.upperBound
        guard let right = line[afterLeft...].firstIndex(of: "]") else { return nil }
        let inside = line[afterLeft..<right]
        let parts = inside.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let done = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let total = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (done, total)
    }
}

final class ColmapMatchingProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction: Double = 0

    func ingest(_ line: String) -> (fraction: Double, message: String)? {
        guard let parsed = Self.parseProcessingBlock(line) else { return nil }
        let (outerIndex, outerTotal, innerIndex, innerTotal) = parsed
        guard outerIndex > 0, outerTotal > 0, innerIndex > 0, innerTotal > 0 else { return nil }

        let totalBlocks = outerTotal * innerTotal
        guard totalBlocks > 0 else { return nil }

        // 0-based index across the 2D block grid.
        let currentIndex = (outerIndex - 1) * innerTotal + (innerIndex - 1)
        let completedBlocks = currentIndex + 1
        let rawFraction = Double(completedBlocks) / Double(totalBlocks)
        let fraction = max(0, min(0.99, rawFraction))

        lock.lock()
        defer { lock.unlock() }
        guard fraction > lastFraction else { return nil }
        lastFraction = fraction
        let message = "Matching views (block \(completedBlocks)/\(totalBlocks), tile \(outerIndex)/\(outerTotal) x \(innerIndex)/\(innerTotal))"
        return (fraction, message)
    }

    private static func parseProcessingBlock(_ line: String) -> (outerIndex: Int, outerTotal: Int, innerIndex: Int, innerTotal: Int)? {
        guard let range = line.range(of: "Processing block [") else { return nil }
        let afterLeft = range.upperBound
        guard let right = line[afterLeft...].firstIndex(of: "]") else { return nil }
        let inside = line[afterLeft..<right]
        let parts = inside.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        func parseFraction(_ part: Substring) -> (Int, Int)? {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let pair = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let a = Int(pair[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let b = Int(pair[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return (a, b)
        }

        guard let outer = parseFraction(parts[0]),
              let inner = parseFraction(parts[1]) else { return nil }
        return (outer.0, outer.1, inner.0, inner.1)
    }
}

final class ColmapMappingProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalImages: Int
    private var lastFraction: Double = 0

    init(totalImages: Int) {
        self.totalImages = totalImages
    }

    func ingest(_ line: String) -> (fraction: Double, message: String)? {
        if line.contains("Keeping successful reconstruction") {
            return update(fraction: 0.99, message: "Solving cameras (finalizing reconstruction)")
        }

        guard let numRegistered = Self.parseNumRegistered(line) else { return nil }
        let denom = max(totalImages, 1)
        let rawFraction = Double(numRegistered) / Double(denom)
        let fraction = max(0, min(0.99, rawFraction))
        return update(fraction: fraction, message: "Solving cameras (\(numRegistered)/\(denom) registered)")
    }

    private func update(fraction: Double, message: String) -> (fraction: Double, message: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard fraction > lastFraction else { return nil }
        lastFraction = fraction
        return (fraction, message)
    }

    private static func parseNumRegistered(_ line: String) -> Int? {
        guard let range = line.range(of: "num_reg_frames=") else { return nil }
        let after = line[range.upperBound...]
        let digits = after.prefix { $0.isNumber }
        return Int(digits)
    }
}
