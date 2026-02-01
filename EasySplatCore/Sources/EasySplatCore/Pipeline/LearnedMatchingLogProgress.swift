import Foundation

@available(*, deprecated, message: "learned_sfm / MASt3R is deprecated; use vggt-mps instead.")
struct LearnedMatchingProgressTracker {
    func ingest(_ line: String) -> (fraction: Double, message: String)? {
        if let progress = parsePairProgress(line) {
            return progress
        }
        if let counts = parseCounts(line) {
            return counts
        }
        return nil
    }

    private func parsePairProgress(_ line: String) -> (fraction: Double, message: String)? {
        let prefix = "Processed "
        let suffix = " pairs"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }

        let middle = String(line.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = middle.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let done = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              total > 0 else {
            return nil
        }

        let fraction = min(1.0, max(0.0, Double(done) / Double(total)))
        return (fraction: fraction, message: "Learned matching (\(done)/\(total) pairs)")
    }

    private func parseCounts(_ line: String) -> (fraction: Double, message: String)? {
        // Example: "Image count: 50 | Pair count: 500"
        guard line.hasPrefix("Image count:") else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let imagePart = parts[0].replacingOccurrences(of: "Image count:", with: "").trimmingCharacters(in: .whitespaces)
        let pairPart = parts[1].replacingOccurrences(of: "Pair count:", with: "").trimmingCharacters(in: .whitespaces)
        guard let imageCount = Int(imagePart),
              let pairCount = Int(pairPart) else {
            return nil
        }

        return (fraction: 0.0, message: "Learned matching (\(imageCount) images, \(pairCount) pairs)")
    }
}
