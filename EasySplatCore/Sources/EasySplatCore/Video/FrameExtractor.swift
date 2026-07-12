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
    public var maxExtractedFrames: Int?

    public init(
        targetCount: Int,
        maxDimension: CGFloat,
        targetFPS: Int = 3,
        minDistanceRatio: Double = 0.20,
        sharpnessFloor: Double = 40.0,
        sharpnessRatio: Double = 0.6,
        outputFormat: FrameOutputFormat = .jpeg,
        maxExtractedFrames: Int? = nil
    ) {
        self.targetCount = targetCount
        self.maxDimension = maxDimension
        self.targetFPS = targetFPS
        self.minDistanceRatio = minDistanceRatio
        self.sharpnessFloor = sharpnessFloor
        self.sharpnessRatio = sharpnessRatio
        self.outputFormat = outputFormat
        self.maxExtractedFrames = maxExtractedFrames.flatMap { $0 > 0 ? $0 : nil }
    }
}

struct CappedExtractionSlot: Sendable {
    let preferredTime: Double
    let candidateTimes: [Double]
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
        // Batch is roughly one second of video frames so progress updates feel steady without being spammy.
        let batchSize = max(1, Int(round(videoFPS)))
        let totalFramesEstimate = Int(round(durationSeconds * videoFPS))

        progress(0.0, "Extracting frames (analyzing video)")

        if Self.shouldUseCappedRandomAccessExtraction(
            options: options,
            duration: durationSeconds,
            videoFPS: videoFPS
        ) {
            return try await extractCappedFrames(
                from: asset,
                duration: durationSeconds,
                videoFPS: videoFPS,
                to: outputDir,
                options: options,
                progress: progress
            )
        }

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

        var bufferFrames: [Int: (image: CGImage, timestampSeconds: Double)] = [:]
        var bufferCandidates: [SmartFrameCandidate] = []
        var recentHashes: [UInt64] = []
        var lastSelectedIndex = -999
        var savedCount = 0
        var outputURLs: [URL] = []
        var frameIndex = 0
        var batchCount = 0
        var lastProgressFrameIndex = 0

        func reachedExtractionLimit() -> Bool {
            guard let maxExtractedFrames = options.maxExtractedFrames else { return false }
            return savedCount >= maxExtractedFrames
        }

        func flushBatch() {
            guard !bufferCandidates.isEmpty else { return }
            if reachedExtractionLimit() {
                bufferCandidates.removeAll(keepingCapacity: true)
                bufferFrames.removeAll(keepingCapacity: true)
                return
            }
            let result = SmartFrameSelection.selectBatch(
                candidates: bufferCandidates,
                config: selectionConfig,
                fps: videoFPS,
                lastSelectedIndex: &lastSelectedIndex,
                recentHashes: &recentHashes
            )
            let remaining = options.maxExtractedFrames.map { max(0, $0 - savedCount) } ?? Int.max
            for index in result.selectedIndices.prefix(remaining) {
                guard let frame = bufferFrames[index] else { continue }
                let fileURL = outputDir.appendingPathComponent(
                    Self.timestampedFilename(
                        index: savedCount,
                        seconds: frame.timestampSeconds,
                        format: options.outputFormat
                    )
                )
                outputURLs.append(fileURL)
                let format = options.outputFormat
                writeQueue.addOperation {
                    do {
                        try Self.writeImage(cgImage: frame.image, to: fileURL, format: format)
                    } catch {
                        errorState.record(error)
                    }
                }
                savedCount += 1
            }
            bufferCandidates.removeAll(keepingCapacity: true)
            bufferFrames.removeAll(keepingCapacity: true)
        }

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            let presentationSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let timestampSeconds = presentationSeconds.isFinite
                ? presentationSeconds
                : Double(frameIndex) / videoFPS
            autoreleasepool {
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                   let cgImage = Self.makeCGImage(from: imageBuffer, context: context, maxDimension: options.maxDimension, transform: preferredTransform) {
                    let score = FrameScoring.scoreFrame(cgImage: cgImage)
                    let sharpness = max(score.blurScore, score.laplacianScore)
                    bufferFrames[frameIndex] = (cgImage, timestampSeconds)
                    bufferCandidates.append(
                        SmartFrameCandidate(
                            index: frameIndex,
                            sharpness: sharpness,
                            brightness: score.brightness,
                            clippedFraction: score.clippedFraction,
                            dHash: score.dHash
                        )
                    )
                }
            }

            frameIndex += 1
            batchCount += 1

            if totalFramesEstimate > 0 && (frameIndex - lastProgressFrameIndex) >= batchSize {
                lastProgressFrameIndex = frameIndex
                let fraction = min(Double(frameIndex) / Double(totalFramesEstimate), 1.0)
                progress(
                    fraction,
                    "Extracting frames (scanned \(frameIndex)/\(totalFramesEstimate), selected \(savedCount))"
                )
            }

            if batchCount >= batchSize {
                flushBatch()
                batchCount = 0
                if reachedExtractionLimit() {
                    break
                }
            }
        }

        if batchCount > 0, !reachedExtractionLimit() {
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

        progress(1.0, "Extracted \(outputURLs.count) frame(s)")
        return outputURLs
    }

    private func extractCappedFrames(
        from asset: AVAsset,
        duration: Double,
        videoFPS: Double,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        let slots = Self.cappedExtractionSlots(options: options, duration: duration, videoFPS: videoFPS)
        guard !slots.isEmpty else { throw ExtractionError.extractionFailed }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if options.maxDimension > 0 {
            generator.maximumSize = CGSize(width: options.maxDimension, height: options.maxDimension)
        }
        let tolerance = CMTime(seconds: max(1.0 / max(videoFPS, 1.0), 0.05), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var outputURLs: [URL] = []
        outputURLs.reserveCapacity(slots.count)
        var recentHashes: [UInt64] = []
        var lastSelectedFrameIndex = Int.min / 2
        let minimumFrameDistance = Self.cappedMinimumFrameDistance(options: options, videoFPS: videoFPS)
        let selectionConfig = SmartFrameSelectionConfig(
            targetFPS: options.targetFPS,
            minDistanceRatio: options.minDistanceRatio,
            sharpnessFloor: options.sharpnessFloor,
            sharpnessRatio: options.sharpnessRatio
        )
        let fitnessScale = max(1, Int(round(videoFPS)))
        var lastError: Error?

        for (slotIndex, slot) in slots.enumerated() {
            try Task.checkCancellation()
            var slotCandidates: [(image: CGImage, candidate: SmartFrameCandidate, timestampSeconds: Double)] = []
            slotCandidates.reserveCapacity(slot.candidateTimes.count)

            for seconds in slot.candidateTimes {
                do {
                    let time = CMTime(seconds: seconds, preferredTimescale: 600)
                    let generated = try await Self.generateCGImage(generator: generator, at: time)
                    let score = FrameScoring.scoreFrame(cgImage: generated.image)
                    let sharpness = max(score.blurScore, score.laplacianScore)
                    let actualSeconds = CMTimeGetSeconds(generated.actualTime)
                    let frameSeconds = actualSeconds.isFinite ? actualSeconds : seconds
                    let candidate = SmartFrameCandidate(
                        index: Self.cappedCandidateFrameIndex(seconds: frameSeconds, videoFPS: videoFPS),
                        sharpness: sharpness,
                        brightness: score.brightness,
                        clippedFraction: score.clippedFraction,
                        dHash: score.dHash
                    )
                    slotCandidates.append((image: generated.image, candidate: candidate, timestampSeconds: frameSeconds))
                } catch {
                    lastError = error
                }
            }

            let eligibleIndices = Set(
                SmartFrameSelection.qualityFilteredCandidates(
                    slotCandidates.map(\.candidate),
                    config: selectionConfig
                ).map(\.index)
            )
            let pool = slotCandidates.filter {
                eligibleIndices.contains($0.candidate.index)
                    && $0.candidate.index - lastSelectedFrameIndex >= minimumFrameDistance
            }
            let preferredIndex = Self.cappedCandidateFrameIndex(seconds: slot.preferredTime, videoFPS: videoFPS)
            let best = pool.max { lhs, rhs in
                SmartFrameSelection.candidateFitness(
                    lhs.candidate,
                    targetIndex: preferredIndex,
                    orderedCount: fitnessScale,
                    recentHashes: recentHashes
                ) < SmartFrameSelection.candidateFitness(
                    rhs.candidate,
                    targetIndex: preferredIndex,
                    orderedCount: fitnessScale,
                    recentHashes: recentHashes
                )
            }

            guard let best else {
                continue
            }
            lastSelectedFrameIndex = best.candidate.index
            SmartFrameSelection.appendHash(best.candidate.dHash, to: &recentHashes)

            let fileURL = outputDir.appendingPathComponent(
                Self.timestampedFilename(
                    index: outputURLs.count,
                    seconds: best.timestampSeconds,
                    format: options.outputFormat
                )
            )
            try Self.writeImage(cgImage: best.image, to: fileURL, format: options.outputFormat)
            outputURLs.append(fileURL)

            let completed = slotIndex + 1
            if completed == slots.count || completed % 5 == 0 {
                let fraction = Double(completed) / Double(slots.count)
                progress(fraction, "Extracting frames (sampled \(completed)/\(slots.count), selected \(outputURLs.count))")
            }
        }

        if outputURLs.isEmpty {
            if let lastError {
                throw lastError
            }
            throw ExtractionError.extractionFailed
        }

        progress(1.0, "Extracted \(outputURLs.count) frame(s)")
        return outputURLs
    }

    private static func generateCGImage(generator: AVAssetImageGenerator, at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, actualTime, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: ExtractionError.extractionFailed)
                    return
                }
                continuation.resume(returning: (image, actualTime))
            }
        }
    }

    private static func effectiveTargetFPS(options: FrameExtractionOptions, duration: Double, videoFPS: Double) -> Int {
        let baseFPS = max(1, options.targetFPS)
        guard duration > 0 else { return baseFPS }
        let fpsForTarget = Double(options.targetCount) / duration
        let desired = max(Double(baseFPS), fpsForTarget)
        let clamped = min(desired, max(videoFPS, 1.0))
        return max(1, Int(round(clamped)))
    }

    private static func cappedCandidateFrameIndex(seconds: Double, videoFPS: Double) -> Int {
        max(0, Int((seconds * max(videoFPS, 1.0)).rounded(.down)))
    }

    private static func cappedMinimumFrameDistance(options: FrameExtractionOptions, videoFPS: Double) -> Int {
        max(0, Int((max(videoFPS, 1.0) * options.minDistanceRatio).rounded(.up)))
    }

    static func timestampedFilename(index: Int, seconds: Double, format: FrameOutputFormat) -> String {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let microseconds = Int64((safeSeconds * 1_000_000).rounded())
        return String(
            format: "frame_%06d_t%012lld.%@",
            index,
            microseconds,
            format.fileExtension
        )
    }

    static func timestampSeconds(from filename: String) -> Double? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard let marker = stem.range(of: "_t", options: .backwards) else { return nil }
        let digits = stem[marker.upperBound...]
        guard !digits.isEmpty,
              digits.allSatisfy(\.isNumber),
              let microseconds = Int64(digits) else {
            return nil
        }
        return Double(microseconds) / 1_000_000
    }

    private static func shouldUseCappedRandomAccessExtraction(
        options: FrameExtractionOptions,
        duration: Double,
        videoFPS: Double
    ) -> Bool {
        guard let cap = options.maxExtractedFrames, cap > 0, duration > 0 else { return false }
        let totalFramesEstimate = max(1, Int(round(duration * max(videoFPS, 1.0))))
        return cap < totalFramesEstimate
    }

    private static func cappedExtractionSlots(
        options: FrameExtractionOptions,
        duration: Double,
        videoFPS: Double
    ) -> [CappedExtractionSlot] {
        guard let cap = options.maxExtractedFrames, cap > 0, duration > 0 else { return [] }
        let totalFramesEstimate = max(1, Int(round(duration * max(videoFPS, 1.0))))
        let slotCount = max(1, min(cap, totalFramesEstimate))
        let binDuration = duration / Double(slotCount)
        let frameInterval = 1.0 / max(videoFPS, 1.0)
        let neighborhood = max(frameInterval, min(0.5, binDuration * 0.20))
        let maxCandidateTime = max(0, duration - frameInterval)

        return (0..<slotCount).map { index in
            let preferred = duration * (Double(index) + 0.5) / Double(slotCount)
            let rawTimes = [preferred - neighborhood, preferred, preferred + neighborhood]
            var seen = Set<Int>()
            let candidates = rawTimes.compactMap { value -> Double? in
                let clamped = min(max(0, value), maxCandidateTime)
                let bucket = Int((clamped * 600).rounded())
                guard seen.insert(bucket).inserted else { return nil }
                return clamped
            }
            return CappedExtractionSlot(preferredTime: preferred, candidateTimes: candidates)
        }
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

#if DEBUG
extension FrameExtractor {
    static func test_effectiveTargetFPS(options: FrameExtractionOptions, duration: Double, videoFPS: Double) -> Int {
        effectiveTargetFPS(options: options, duration: duration, videoFPS: videoFPS)
    }

    static func test_cappedExtractionSlots(options: FrameExtractionOptions, duration: Double, videoFPS: Double) -> [CappedExtractionSlot] {
        cappedExtractionSlots(options: options, duration: duration, videoFPS: videoFPS)
    }

    static func test_cappedCandidateFrameIndices(for slot: CappedExtractionSlot, videoFPS: Double) -> [Int] {
        slot.candidateTimes.map { cappedCandidateFrameIndex(seconds: $0, videoFPS: videoFPS) }
    }

    static func test_timestampedFilename(index: Int, seconds: Double, format: FrameOutputFormat) -> String {
        timestampedFilename(index: index, seconds: seconds, format: format)
    }

    static func test_timestampSeconds(from filename: String) -> Double? {
        timestampSeconds(from: filename)
    }

}
#endif
