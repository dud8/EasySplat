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
    ) throws -> [URL] {
        let asset = AVAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ExtractionError.invalidVideo
        }
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds > 0 else { throw ExtractionError.invalidVideo }

        let sampleCount = max(options.targetCount * 2, options.targetCount)
        let step = durationSeconds / Double(sampleCount)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let maxSize = track.naturalSize
        let scale = min(options.maxDimension / max(maxSize.width, maxSize.height), 1.0)
        generator.maximumSize = CGSize(width: maxSize.width * scale, height: maxSize.height * scale)

        var outputURLs: [URL] = []
        for index in 0..<sampleCount {
            let time = CMTimeMakeWithSeconds(Double(index) * step, preferredTimescale: 600)
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let fileURL = outputDir.appendingPathComponent(String(format: "frame_%06d.jpg", index))
                try writeJPEG(cgImage: cgImage, to: fileURL)
                outputURLs.append(fileURL)
                progress(Double(index + 1) / Double(sampleCount), "Extracting frames")
            } catch {
                continue
            }
        }

        if outputURLs.isEmpty { throw ExtractionError.extractionFailed }
        return outputURLs
    }

    private func writeJPEG(cgImage: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExtractionError.extractionFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw ExtractionError.extractionFailed
        }
    }
}
