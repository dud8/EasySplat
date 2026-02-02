import Foundation

final class VggtSfmProgressTracker: @unchecked Sendable {
    private struct ChunkInfo: Sendable {
        let index: Int
        let total: Int
        let start: Int
        let end: Int
    }

    private let lock = NSLock()
    private let totalImages: Int
    private var lastEndExclusive: Int = 0
    private var lastEmittedFraction: Double = -1
    private var lastEmittedMessage: String = ""

    init(totalImages: Int) {
        self.totalImages = max(1, totalImages)
    }

    func ingest(_ line: String) -> (fraction: Double, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("VGGT:") else { return nil }

        if trimmed.contains("loading model weights") {
            return emit(fraction: currentFraction(), message: "Loading VGGT model weights…")
        }

        if let chunking = Self.parseChunkingEnabled(trimmed) {
            let message = "Preparing VGGT chunks (chunk=\(chunking.chunk), overlap=\(chunking.overlap), stride=\(chunking.stride))…"
            return emit(fraction: currentFraction(), message: message)
        }

        if let chunk = Self.parseChunkLine(trimmed) {
            let completed = currentCompletedImages()
            let message = Self.chunkMessage(chunk: chunk, completed: completed, total: totalImages)
            defer { advance(endExclusive: chunk.end) }
            return emit(fraction: fraction(forCompletedImages: completed), message: message)
        }

        if let points = Self.parseWritingModelPoints(trimmed) {
            return emit(fraction: nearCompleteFraction(), message: "Writing COLMAP model (points=\(points))…")
        }

        if trimmed == "VGGT: done" {
            return emit(fraction: nearCompleteFraction(), message: "Finalizing VGGT outputs…")
        }

        return nil
    }

    private func currentCompletedImages() -> Int {
        lock.lock()
        let value = min(max(lastEndExclusive, 0), totalImages)
        lock.unlock()
        return value
    }

    private func currentFraction() -> Double {
        fraction(forCompletedImages: currentCompletedImages())
    }

    private func nearCompleteFraction() -> Double {
        min(0.99, max(currentFraction(), 0.95))
    }

    private func fraction(forCompletedImages completedImages: Int) -> Double {
        guard totalImages > 0 else { return 0.0 }
        let raw = Double(max(0, completedImages)) / Double(totalImages)
        return max(0, min(0.99, raw))
    }

    private func advance(endExclusive: Int) {
        lock.lock()
        lastEndExclusive = max(lastEndExclusive, endExclusive)
        lock.unlock()
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

    private static func chunkMessage(chunk: ChunkInfo, completed: Int, total: Int) -> String {
        let start = max(0, chunk.start)
        let end = max(start, chunk.end)

        if start + 1 >= end {
            return "VGGT chunk \(chunk.index)/\(chunk.total) (\(completed)/\(total) complete) — processing image \(start + 1)"
        }
        return "VGGT chunk \(chunk.index)/\(chunk.total) (\(completed)/\(total) complete) — processing images \(start + 1)–\(end)"
    }

    private static func parseChunkingEnabled(_ line: String) -> (chunk: Int, overlap: Int, stride: Int)? {
        guard line.hasPrefix("VGGT: chunking enabled (") else { return nil }

        func parseInt(after label: String) -> Int? {
            guard let range = line.range(of: label) else { return nil }
            let suffix = line[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            return Int(digits)
        }

        guard let chunk = parseInt(after: "chunk="),
              let overlap = parseInt(after: "overlap="),
              let stride = parseInt(after: "stride=") else { return nil }
        return (chunk, overlap, stride)
    }

    private static func parseChunkLine(_ line: String) -> ChunkInfo? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        guard parts[0] == "VGGT:", parts[1] == "chunk" else { return nil }

        let frac = parts[2].split(separator: "/", omittingEmptySubsequences: false)
        guard frac.count == 2,
              let index = Int(frac[0]),
              let total = Int(frac[1]) else { return nil }

        let imagesPart = String(parts[3])
        guard let open = imagesPart.firstIndex(of: "["),
              let close = imagesPart.firstIndex(of: "]"),
              open < close else { return nil }
        let inside = imagesPart[imagesPart.index(after: open)..<close]
        let rangeParts = inside.split(separator: ":", omittingEmptySubsequences: false)
        guard rangeParts.count == 2,
              let start = Int(rangeParts[0]),
              let end = Int(rangeParts[1]) else { return nil }

        return ChunkInfo(index: index, total: total, start: start, end: end)
    }

    private static func parseWritingModelPoints(_ line: String) -> Int? {
        guard line.hasPrefix("VGGT: writing COLMAP model") else { return nil }
        guard let range = line.range(of: "points=") else { return nil }
        let after = line[range.upperBound...]
        let digits = after.prefix { $0.isNumber }
        return Int(digits)
    }
}

