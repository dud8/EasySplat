import Foundation

final class FastVggtSfmProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalImages: Int
    private var lastEmittedFraction: Double = -1
    private var lastEmittedMessage: String = ""

    init(totalImages: Int) {
        self.totalImages = max(1, totalImages)
    }

    func ingest(_ line: String) -> (fraction: Double, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("FASTVGGT:") else { return nil }

        if trimmed.contains("loading model weights") {
            return emit(fraction: 0.05, message: "Loading FastVGGT model weights…")
        }

        if trimmed.contains("running model") || trimmed.contains("running fastvggt inference") {
            return emit(fraction: 0.1, message: "Running FastVGGT inference…")
        }

        if let points = Self.parseWritingModelPoints(trimmed) {
            return emit(fraction: 0.95, message: "Writing COLMAP model (points=\(points))…")
        }

        if trimmed == "FASTVGGT: done" {
            return emit(fraction: 0.99, message: "Finalizing FastVGGT outputs…")
        }

        return nil
    }

    private func emit(fraction: Double, message: String) -> (fraction: Double, message: String)? {
        lock.lock()
        defer { lock.unlock() }

        let clamped = max(0, min(0.99, fraction))
        let updatedFraction = max(lastEmittedFraction, clamped)

        if updatedFraction == lastEmittedFraction && message == lastEmittedMessage {
            return nil
        }

        lastEmittedFraction = updatedFraction
        lastEmittedMessage = message
        return (updatedFraction, message)
    }

    private static func parseWritingModelPoints(_ line: String) -> Int? {
        guard line.hasPrefix("FASTVGGT: writing COLMAP model") else { return nil }
        guard let range = line.range(of: "points=") else { return nil }
        let after = line[range.upperBound...]
        let digits = after.prefix { $0.isNumber }
        return Int(digits)
    }
}
