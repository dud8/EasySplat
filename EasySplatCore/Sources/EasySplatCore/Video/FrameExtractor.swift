import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct FrameExtractionOptions: Sendable {
    public var targetCount: Int
    public var maxDimension: CGFloat

    public init(targetCount: Int, maxDimension: CGFloat) {
        self.targetCount = targetCount
        self.maxDimension = maxDimension
    }
}

public final class FrameExtractor {
    public enum ExtractionError: Error {
        case invalidVideo
        case extractionFailed
    }

    public init() {}

    public func extractFrames(
        from videoURL: URL,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ExtractionError.invalidVideo
        }
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { throw ExtractionError.invalidVideo }

        let sampleCount = max(options.targetCount * 2, options.targetCount)
        let step = durationSeconds / Double(sampleCount)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let maxSize = try await track.load(.naturalSize)
        let scale = min(options.maxDimension / max(maxSize.width, maxSize.height), 1.0)
        generator.maximumSize = CGSize(width: maxSize.width * scale, height: maxSize.height * scale)

        let times = (0..<sampleCount).map { index in
            CMTimeMakeWithSeconds(Double(index) * step, preferredTimescale: 600)
        }
        return try await generateImages(
            generator: generator,
            times: times,
            stepSeconds: step,
            outputDir: outputDir,
            progress: progress
        )
    }

    private func generateImages(
        generator: AVAssetImageGenerator,
        times: [CMTime],
        stepSeconds: Double,
        outputDir: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        guard !times.isEmpty else { throw ExtractionError.extractionFailed }
        let requestedTimes = times.map { NSValue(time: $0) }
        let maxIndex = max(times.count - 1, 0)

        return try await withCheckedThrowingContinuation { continuation in
            let state = FrameExtractionState(count: times.count)

            generator.generateCGImagesAsynchronously(forTimes: requestedTimes) { requestedTime, cgImage, _, result, _ in
                let index = Self.indexForRequestedTime(requestedTime, stepSeconds: stepSeconds, maxIndex: maxIndex)
                let snapshot = state.withLock { state -> (progress: Double, isComplete: Bool, urls: [URL]?) in
                    if result == .succeeded,
                       let cgImage {
                        let fileURL = outputDir.appendingPathComponent(String(format: "frame_%06d.jpg", index))
                        if (try? Self.writeJPEG(cgImage: cgImage, to: fileURL)) != nil {
                            state.outputURLs[index] = fileURL
                        }
                    }

                    state.completed += 1
                    let progressValue = Double(state.completed) / Double(times.count)
                    if state.completed == times.count {
                        return (progressValue, true, state.outputURLs.compactMap { $0 })
                    }
                    return (progressValue, false, nil)
                }

                progress(snapshot.progress, "Extracting frames")

                if snapshot.isComplete {
                    if let urls = snapshot.urls, !urls.isEmpty {
                        continuation.resume(returning: urls)
                    } else {
                        continuation.resume(throwing: ExtractionError.extractionFailed)
                    }
                }
            }
        }
    }

    private static func writeJPEG(cgImage: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExtractionError.extractionFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw ExtractionError.extractionFailed
        }
    }

    private static func indexForRequestedTime(_ time: CMTime, stepSeconds: Double, maxIndex: Int) -> Int {
        guard stepSeconds > 0 else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        let rawIndex = Int(round(seconds / stepSeconds))
        return min(max(rawIndex, 0), maxIndex)
    }
}

private final class FrameExtractionState: @unchecked Sendable {
    var completed: Int
    var outputURLs: [URL?]
    private let lock = NSLock()

    init(count: Int) {
        self.completed = 0
        self.outputURLs = Array(repeating: nil, count: count)
    }

    func withLock<T>(_ body: (FrameExtractionState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}
