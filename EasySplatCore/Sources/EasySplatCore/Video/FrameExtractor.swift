import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum FrameOutputFormat: String, Sendable {
    case jpeg
    case png

    public var fileExtension: String {
        switch self {
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        }
    }

    public var utType: UTType {
        switch self {
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        }
    }
}

public struct FrameExtractionOptions: Sendable {
    public var targetCount: Int
    public var maxDimension: CGFloat
    public var targetFPS: Int
    public var minDistanceRatio: Double
    public var sharpnessFloor: Double
    public var sharpnessRatio: Double
    public var outputFormat: FrameOutputFormat

    public init(
        targetCount: Int,
        maxDimension: CGFloat,
        targetFPS: Int = 3,
        minDistanceRatio: Double = 0.20,
        sharpnessFloor: Double = 40.0,
        sharpnessRatio: Double = 0.6,
        outputFormat: FrameOutputFormat = .jpeg
    ) {
        self.targetCount = targetCount
        self.maxDimension = maxDimension
        self.targetFPS = targetFPS
        self.minDistanceRatio = minDistanceRatio
        self.sharpnessFloor = sharpnessFloor
        self.sharpnessRatio = sharpnessRatio
        self.outputFormat = outputFormat
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

        let nominalFPS = Double(try await track.load(.nominalFrameRate))
        let videoFPS = nominalFPS > 0 ? nominalFPS : 30.0
        let preferredTransform = try await track.load(.preferredTransform)
        let targetFPS = Self.effectiveTargetFPS(options: options, duration: durationSeconds, videoFPS: videoFPS)
        let batchSize = max(1, Int(round(videoFPS)))
        let totalFramesEstimate = Int(round(durationSeconds * videoFPS))

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractionError.invalidVideo }
        reader.add(output)
        guard reader.startReading() else { throw ExtractionError.extractionFailed }

        let context = CIContext(options: nil)
        let selectionConfig = SmartFrameSelectionConfig(
            targetFPS: targetFPS,
            minDistanceRatio: options.minDistanceRatio,
            sharpnessFloor: options.sharpnessFloor,
            sharpnessRatio: options.sharpnessRatio
        )
        let writeQueue = OperationQueue()
        writeQueue.maxConcurrentOperationCount = 4
        let errorState = WriteErrorState()

        var bufferFrames: [Int: CGImage] = [:]
        var bufferScores: [(index: Int, sharpness: Double)] = []
        var lastSelectedIndex = -999
        var savedCount = 0
        var outputURLs: [URL] = []
        var frameIndex = 0
        var batchCount = 0

        func flushBatch() {
            guard !bufferScores.isEmpty else { return }
            let result = SmartFrameSelection.selectBatch(
                scores: bufferScores,
                config: selectionConfig,
                fps: videoFPS,
                lastSelectedIndex: &lastSelectedIndex
            )
            for index in result.selectedIndices {
                guard let image = bufferFrames[index] else { continue }
                let fileURL = outputDir.appendingPathComponent(
                    String(format: "frame_%06d.%@", savedCount, options.outputFormat.fileExtension)
                )
                outputURLs.append(fileURL)
                let format = options.outputFormat
                writeQueue.addOperation {
                    do {
                        try Self.writeImage(cgImage: image, to: fileURL, format: format)
                    } catch {
                        errorState.record(error)
                    }
                }
                savedCount += 1
            }
            bufferScores.removeAll(keepingCapacity: true)
            bufferFrames.removeAll(keepingCapacity: true)
        }

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            autoreleasepool {
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                   let cgImage = Self.makeCGImage(from: imageBuffer, context: context, maxDimension: options.maxDimension, transform: preferredTransform) {
                    let score = FrameScoring.scoreFrame(cgImage: cgImage)
                    let sharpness = max(score.blurScore, score.laplacianScore)
                    bufferFrames[frameIndex] = cgImage
                    bufferScores.append((index: frameIndex, sharpness: sharpness))
                }
            }

            frameIndex += 1
            batchCount += 1

            if totalFramesEstimate > 0 && frameIndex % 5 == 0 {
                let fraction = min(Double(frameIndex) / Double(totalFramesEstimate), 1.0)
                progress(fraction, "Extracting frames")
            }

            if batchCount >= batchSize {
                flushBatch()
                batchCount = 0
            }
        }

        if batchCount > 0 {
            flushBatch()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.addBarrierBlock {
                if let error = errorState.currentError() {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        if reader.status == .failed || reader.status == .cancelled {
            throw ExtractionError.extractionFailed
        }

        if outputURLs.isEmpty {
            throw ExtractionError.extractionFailed
        }

        progress(1.0, "Extracting frames")
        return outputURLs
    }

    private static func effectiveTargetFPS(options: FrameExtractionOptions, duration: Double, videoFPS: Double) -> Int {
        let baseFPS = max(1, options.targetFPS)
        guard duration > 0 else { return baseFPS }
        let fpsForTarget = Double(options.targetCount) / duration
        let desired = max(Double(baseFPS), fpsForTarget)
        let clamped = min(desired, max(videoFPS, 1.0))
        return max(1, Int(round(clamped)))
    }

    private static func makeCGImage(
        from buffer: CVPixelBuffer,
        context: CIContext,
        maxDimension: CGFloat,
        transform: CGAffineTransform
    ) -> CGImage? {
        var image = CIImage(cvImageBuffer: buffer).transformed(by: transform)
        let transformedExtent = image.extent
        if transformedExtent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -transformedExtent.origin.x, y: -transformedExtent.origin.y))
        }
        let extent = image.extent
        let largest = max(extent.width, extent.height)
        if maxDimension > 0, largest > maxDimension {
            let scale = maxDimension / largest
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return context.createCGImage(scaled, from: scaled.extent)
        }
        return context.createCGImage(image, from: extent)
    }

    private static func writeImage(cgImage: CGImage, to url: URL, format: FrameOutputFormat) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ExtractionError.extractionFailed
        }
        let options: CFDictionary
        if format == .jpeg {
            options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        } else {
            options = [:] as CFDictionary
        }
        CGImageDestinationAddImage(destination, cgImage, options)
        if !CGImageDestinationFinalize(destination) {
            throw ExtractionError.extractionFailed
        }
    }
}

private final class WriteErrorState: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ error: Error) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        lock.unlock()
    }

    func currentError() -> Error? {
        lock.lock()
        let current = error
        lock.unlock()
        return current
    }
}
