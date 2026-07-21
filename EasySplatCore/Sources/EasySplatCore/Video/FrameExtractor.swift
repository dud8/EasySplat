import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import Metal
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
    public var outputFormat: FrameOutputFormat

    public init(
        targetCount: Int,
        maxDimension: CGFloat,
        targetFPS: Int = 3,
        minDistanceRatio: Double = 0.20,
        outputFormat: FrameOutputFormat = .jpeg
    ) {
        self.targetCount = targetCount
        self.maxDimension = maxDimension
        self.targetFPS = targetFPS
        self.minDistanceRatio = minDistanceRatio
        self.outputFormat = outputFormat
    }
}

struct VideoTrackDescriptor: Equatable, Sendable {
    let index: Int
    let trackID: Int32
    let width: Int
    let height: Int
    let nominalFrameRate: Double
    let durationSeconds: Double
    let estimatedDataRate: Double
    let isEnabled: Bool
    let isDecodable: Bool
    let isAuxiliary: Bool
    let isHDR: Bool

    init(
        index: Int,
        trackID: Int32,
        width: Int,
        height: Int,
        nominalFrameRate: Double,
        durationSeconds: Double,
        estimatedDataRate: Double,
        isEnabled: Bool,
        isDecodable: Bool = true,
        isAuxiliary: Bool = false,
        isHDR: Bool = false
    ) {
        self.index = index
        self.trackID = trackID
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.durationSeconds = durationSeconds
        self.estimatedDataRate = estimatedDataRate
        self.isEnabled = isEnabled
        self.isDecodable = isDecodable
        self.isAuxiliary = isAuxiliary
        self.isHDR = isHDR
    }
}

struct PrimaryVideoTrackSelection {
    let track: AVAssetTrack
    let descriptor: VideoTrackDescriptor
}

struct FrameAnalysisDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct FrameAnalysisScheduler: Sendable {
    private let interval: Double
    private let tolerance: Double
    private var nextAnalysisTime: Double?

    init(analysisRate: Double, sourceFPS: Double) {
        let safeAnalysisRate = analysisRate.isFinite && analysisRate > 0
            ? max(analysisRate, 1)
            : 1
        let safeSourceRate = sourceFPS.isFinite && sourceFPS > 0
            ? sourceFPS
            : 1
        interval = 1 / safeAnalysisRate
        tolerance = 0.5 / max(safeSourceRate, safeAnalysisRate)
    }

    mutating func shouldAnalyze(_ timestamp: Double) -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else { return false }
        guard let scheduledTime = nextAnalysisTime else {
            nextAnalysisTime = nextRepresentableSchedule(after: timestamp)
            return true
        }
        let threshold = timestamp + tolerance
        let analysisThreshold = threshold.isFinite ? threshold : timestamp
        guard analysisThreshold >= scheduledTime else { return false }

        let elapsed = analysisThreshold - scheduledTime
        let skippedIntervals = floor(elapsed / interval) + 1
        let advanced = scheduledTime + skippedIntervals * interval
        if advanced.isFinite, advanced > analysisThreshold {
            nextAnalysisTime = advanced
        } else {
            nextAnalysisTime = nextRepresentableSchedule(after: analysisThreshold)
        }
        return true
    }

    private func nextRepresentableSchedule(after timestamp: Double) -> Double {
        let advanced = timestamp + interval
        guard advanced.isFinite, advanced > timestamp else {
            return timestamp.nextUp
        }
        return advanced
    }
}

struct FrameExtractionAnalysis: Sendable {
    let videoURL: URL
    let primaryTrack: VideoTrackDescriptor
    let durationSeconds: Double
    let preferredTransform: CGAffineTransform
    let candidates: [TimedFrameCandidate]
    let decodedFrameCount: Int
    let hadRepairedTimestamps: Bool

    var availableCandidateCount: Int { candidates.count }
}

enum FrameSecondPassStrategy: Equatable, Sendable {
    case sparse
    case sequential
}

struct NormalizedFrameTimestamp: Equatable, Sendable {
    let seconds: Double
    let presentationTime: CMTime?
    let wasRepaired: Bool
}

private struct FrameAnalysisPass: Sendable {
    let candidates: [TimedFrameCandidate]
    let decodedFrameCount: Int
    let hadRepairedTimestamps: Bool
}

struct FrameExtractionSource: @unchecked Sendable {
    let videoURL: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let primaryTrack: VideoTrackDescriptor
    let preferredTransform: CGAffineTransform

    var durationSeconds: Double { primaryTrack.durationSeconds }
}

struct ExtractedFrameOutput: Equatable, Sendable {
    let url: URL
    let origin: VideoFrameOrigin
}

public final class FrameExtractor {
    private static let maximumConcurrentFrameJobs = 4

    public enum ExtractionError: Error {
        case invalidVideo
        case extractionFailed
    }

    private enum SparseDecodeError: Error {
        case readerSetup
        case readerFailed
        case frameMissing
    }

    private struct SparseDecodedFrame: @unchecked Sendable {
        let selectedIndex: Int
        let image: CGImage
    }

    /// One bounded reader belongs to one child task. AVFoundation reader objects are
    /// not Sendable, so this wrapper documents and enforces single-task ownership.
    private final class SparseReaderJob: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let targetTime: CMTime
        let maximumDeltaSeconds: Double
        let context: CIContext
        let preferredTransform: CGAffineTransform

        init(
            reader: AVAssetReader,
            output: AVAssetReaderTrackOutput,
            targetTime: CMTime,
            maximumDeltaSeconds: Double,
            context: CIContext,
            preferredTransform: CGAffineTransform
        ) {
            self.reader = reader
            self.output = output
            self.targetTime = targetTime
            self.maximumDeltaSeconds = maximumDeltaSeconds
            self.context = context
            self.preferredTransform = preferredTransform
        }

        func decode() throws -> CGImage {
            try Task.checkCancellation()
            guard reader.startReading() else {
                throw SparseDecodeError.readerFailed
            }
            defer {
                if reader.status == .reading {
                    reader.cancelReading()
                }
            }

            var bestSample: CMSampleBuffer?
            var bestTime: CMTime?
            var bestDelta = Double.infinity
            while reader.status == .reading {
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard CMSampleBufferGetNumSamples(sample) > 0,
                      CMSampleBufferGetImageBuffer(sample) != nil else {
                    continue
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let seconds = CMTimeGetSeconds(time)
                guard time.isValid,
                      time.isNumeric,
                      time.epoch == 0,
                      seconds.isFinite,
                      seconds >= 0 else {
                    continue
                }
                let delta = abs(CMTimeGetSeconds(CMTimeSubtract(time, targetTime)))
                guard delta.isFinite else { continue }
                let isEarlierTie = abs(delta - bestDelta) <= 1e-12
                    && bestTime.map({ CMTimeCompare(time, $0) < 0 }) ?? false
                if delta < bestDelta || isEarlierTie {
                    bestSample = sample
                    bestTime = time
                    bestDelta = delta
                }
            }
            try Task.checkCancellation()
            guard reader.status == .completed else {
                throw SparseDecodeError.readerFailed
            }
            guard bestDelta <= maximumDeltaSeconds,
                  let bestSample,
                  let bestTime,
                  CMTimeCompare(bestTime, targetTime) == 0,
                  let imageBuffer = CMSampleBufferGetImageBuffer(bestSample),
                  let image = FrameExtractor.makeCGImage(
                    from: imageBuffer,
                    context: context,
                    maxDimension: 0,
                    transform: preferredTransform
                  ) else {
                throw SparseDecodeError.frameMissing
            }
            return image
        }
    }

    public init() {}

    public func extractFrames(
        from videoURL: URL,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        let analysis = try await analyze(
            videoURL,
            options: options,
            progress: { fraction, message in
                progress(fraction * 0.45, message)
            }
        )
        return try await extractFrameOutputs(
            from: analysis,
            targetCount: options.targetCount,
            to: outputDir,
            options: options,
            progress: { fraction, message in
                progress(0.45 + fraction * 0.55, message)
            }
        ).map(\.url)
    }

    func analyze(
        _ videoURL: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FrameExtractionAnalysis {
        let source = try await inspect(videoURL)
        return try await analyze(source, options: options, progress: progress)
    }

    func inspect(_ videoURL: URL) async throws -> FrameExtractionSource {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let primary = try await Self.loadPrimaryTrack(from: tracks)
        let track = primary.track
        let durationSeconds = primary.descriptor.durationSeconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ExtractionError.invalidVideo
        }
        let preferredTransform = try await track.load(.preferredTransform)
        return FrameExtractionSource(
            videoURL: videoURL,
            asset: asset,
            track: track,
            primaryTrack: primary.descriptor,
            preferredTransform: preferredTransform
        )
    }

    func analyze(
        _ source: FrameExtractionSource,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FrameExtractionAnalysis {
        let durationSeconds = source.durationSeconds
        let sourceFPS = source.primaryTrack.nominalFrameRate
        let analysisDimensions = Self.analysisDimensions(
            width: source.primaryTrack.width,
            height: source.primaryTrack.height
        )
        let analysisRate = Self.analysisFrameRate(
            options: options,
            duration: durationSeconds,
            videoFPS: sourceFPS
        )

        progress(0, "Analyzing video")
        let pass = try await analyzeFrames(
            asset: source.asset,
            track: source.track,
            durationSeconds: durationSeconds,
            sourceFPS: sourceFPS,
            analysisRate: analysisRate,
            dimensions: analysisDimensions,
            preferredTransform: source.preferredTransform,
            isHDR: source.primaryTrack.isHDR,
            progress: progress
        )
        return FrameExtractionAnalysis(
            videoURL: source.videoURL,
            primaryTrack: source.primaryTrack,
            durationSeconds: durationSeconds,
            preferredTransform: source.preferredTransform,
            candidates: pass.candidates,
            decodedFrameCount: pass.decodedFrameCount,
            hadRepairedTimestamps: pass.hadRepairedTimestamps
        )
    }

    func extractFrames(
        from analysis: FrameExtractionAnalysis,
        targetCount: Int,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        try await extractFrameOutputs(
            from: analysis,
            targetCount: targetCount,
            to: outputDir,
            options: options,
            progress: progress
        ).map(\.url)
    }

    func extractFrameOutputs(
        from analysis: FrameExtractionAnalysis,
        targetCount: Int,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [ExtractedFrameOutput] {
        let selected = SmartFrameSelection.selectTimeline(
            analysis.candidates,
            targetCount: max(1, targetCount),
            minimumTimeDistance: options.minDistanceRatio
        )
        guard !selected.isEmpty else { throw ExtractionError.extractionFailed }

        let asset = AVURLAsset(url: analysis.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let primary = try await Self.loadPrimaryTrack(from: tracks)
        guard primary.descriptor.trackID == analysis.primaryTrack.trackID,
              primary.descriptor.width == analysis.primaryTrack.width,
              primary.descriptor.height == analysis.primaryTrack.height,
              primary.descriptor.isHDR == analysis.primaryTrack.isHDR else {
            throw ExtractionError.invalidVideo
        }
        let sourceDimensions = FrameAnalysisDimensions(
            width: analysis.primaryTrack.width,
            height: analysis.primaryTrack.height
        )
        let trackTimeRange = try await primary.track.load(.timeRange)
        let outputs = try await extractSelectedFramesThroughStaging(
            selected,
            analysis: analysis,
            asset: asset,
            track: primary.track,
            trackTimeRange: trackTimeRange,
            sourceDimensions: sourceDimensions,
            to: outputDir,
            options: options,
            progress: progress
        )
        progress(1, "Extracted \(outputs.count) frame(s)")
        return outputs
    }

    func reextractRecordedFrames(
        from videoURL: URL,
        origins: [VideoFrameOrigin],
        to outputDir: URL,
        options: FrameExtractionOptions
    ) async throws -> (source: FrameExtractionSource, outputs: [ExtractedFrameOutput]) {
        guard !origins.isEmpty,
              Set(origins.map(\.decodedFrameIndex)).count == origins.count else {
            throw ExtractionError.invalidVideo
        }
        let source = try await inspect(videoURL)
        let candidates = origins.map { origin in
            TimedFrameCandidate(
                frameIndex: origin.decodedFrameIndex,
                timestampSeconds: origin.timestampSeconds,
                candidate: SmartFrameCandidate(
                    index: origin.decodedFrameIndex,
                    sharpness: 1
                ),
                presentationTime: origin.presentationTime
            )
        }
        let analysis = FrameExtractionAnalysis(
            videoURL: videoURL,
            primaryTrack: source.primaryTrack,
            durationSeconds: source.durationSeconds,
            preferredTransform: source.preferredTransform,
            candidates: candidates,
            decodedFrameCount: (origins.map(\.decodedFrameIndex).max() ?? -1) + 1,
            hadRepairedTimestamps: origins.contains(where: \.timestampWasRepaired)
        )
        var exactOptions = options
        exactOptions.targetCount = origins.count
        exactOptions.minDistanceRatio = 0
        let outputs = try await extractFrameOutputs(
            from: analysis,
            targetCount: origins.count,
            to: outputDir,
            options: exactOptions,
            progress: { _, _ in }
        )
        guard outputs.map(\.origin) == origins else {
            throw ExtractionError.extractionFailed
        }
        return (source, outputs)
    }

    static func loadPrimaryTrack(
        from tracks: [AVAssetTrack]
    ) async throws -> PrimaryVideoTrackSelection {
        var descriptors: [VideoTrackDescriptor] = []
        descriptors.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            let naturalSize = try await track.load(.naturalSize)
            let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
            let timeRange = try await track.load(.timeRange)
            let durationSeconds = CMTimeGetSeconds(timeRange.duration)
            let estimatedDataRate = Double(try await track.load(.estimatedDataRate))
            let characteristics = try await track.load(.mediaCharacteristics)
            descriptors.append(VideoTrackDescriptor(
                index: index,
                trackID: track.trackID,
                width: pixelDimension(naturalSize.width),
                height: pixelDimension(naturalSize.height),
                nominalFrameRate: nominalFrameRate.isFinite ? nominalFrameRate : 0,
                durationSeconds: durationSeconds.isFinite ? max(0, durationSeconds) : 0,
                estimatedDataRate: estimatedDataRate.isFinite
                    ? max(0, estimatedDataRate)
                    : 0,
                isEnabled: try await track.load(.isEnabled),
                isDecodable: try await track.load(.isDecodable),
                isAuxiliary: characteristics.contains(.isAuxiliaryContent),
                isHDR: characteristics.contains(.containsHDRVideo)
            ))
        }
        guard let selectedIndex = primaryTrackIndex(descriptors),
              tracks.indices.contains(selectedIndex),
              let descriptor = descriptors.first(where: { $0.index == selectedIndex }),
              descriptor.width > 0,
              descriptor.height > 0 else {
            throw ExtractionError.invalidVideo
        }
        return PrimaryVideoTrackSelection(
            track: tracks[selectedIndex],
            descriptor: descriptor
        )
    }

    private func analyzeFrames(
        asset: AVAsset,
        track: AVAssetTrack,
        durationSeconds: Double,
        sourceFPS: Double,
        analysisRate: Double,
        dimensions: FrameAnalysisDimensions,
        preferredTransform: CGAffineTransform,
        isHDR: Bool,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FrameAnalysisPass {
        try Task.checkCancellation()
        let (reader, output) = try Self.makeReader(
            asset: asset,
            track: track,
            dimensions: dimensions,
            isHDR: isHDR
        )
        try Task.checkCancellation()
        guard reader.startReading() else { throw ExtractionError.extractionFailed }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }
        let context = isHDR ? Self.makeCIContext() : nil
        var scheduler = FrameAnalysisScheduler(
            analysisRate: analysisRate,
            sourceFPS: sourceFPS
        )
        var candidates: [TimedFrameCandidate] = []
        var previousLuma: [UInt8]?
        var previousTimestamp: Double?
        var firstTimestamp: Double?
        var frameIndex = 0
        var lastProgressTime = -Double.infinity
        var lastSample: (
            buffer: CMSampleBuffer,
            index: Int,
            timestamp: NormalizedFrameTimestamp
        )?
        var hadRepairedTimestamps = false

        func appendCandidate(
            from sampleBuffer: CMSampleBuffer,
            index: Int,
            timestamp: NormalizedFrameTimestamp
        ) {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            let luma: [UInt8]
            let score: FrameScore
            if let context {
                guard let image = Self.makeCGImage(
                    from: imageBuffer,
                    context: context,
                    maxDimension: 0,
                    transform: preferredTransform
                ) else { return }
                luma = FrameScoring.lumaPixels(cgImage: image, width: 64, height: 64)
                score = FrameScoring.scoreFrame(cgImage: image, lumaPixels: luma)
            } else if let sampled = Self.sampledLumaPixels(from: imageBuffer) {
                luma = sampled
                score = FrameScoring.scoreLumaPixels(sampled, width: 64, height: 64)
            } else {
                return
            }
            candidates.append(TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: timestamp.seconds,
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: max(score.blurScore, score.laplacianScore),
                    brightness: score.brightness,
                    clippedFraction: score.clippedFraction,
                    motionScore: Self.lumaMotionScore(luma, previous: previousLuma),
                    dHash: score.dHash
                ),
                presentationTime: timestamp.presentationTime
            ))
            previousLuma = luma
        }

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
                continue
            }
            let rawPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestamp = Self.normalizedPresentationTime(
                rawPresentationTime,
                frameIndex: frameIndex,
                sourceFPS: sourceFPS,
                previous: previousTimestamp
            )
            previousTimestamp = timestamp.seconds
            hadRepairedTimestamps = hadRepairedTimestamps || timestamp.wasRepaired
            if firstTimestamp == nil { firstTimestamp = timestamp.seconds }
            lastSample = (sampleBuffer, frameIndex, timestamp)
            if scheduler.shouldAnalyze(timestamp.seconds) {
                appendCandidate(
                    from: sampleBuffer,
                    index: frameIndex,
                    timestamp: timestamp
                )
            }
            let elapsed = max(
                0,
                timestamp.seconds - (firstTimestamp ?? timestamp.seconds)
            )
            if elapsed - lastProgressTime >= 0.5 {
                lastProgressTime = elapsed
                let fraction = min(max(elapsed / durationSeconds, 0), 1)
                progress(fraction, "Analyzing video")
            }
            frameIndex += 1
        }
        guard reader.status == .completed else {
            throw ExtractionError.extractionFailed
        }
        if let lastSample,
           candidates.last?.frameIndex != lastSample.index {
            appendCandidate(
                from: lastSample.buffer,
                index: lastSample.index,
                timestamp: lastSample.timestamp
            )
        }
        guard !candidates.isEmpty else { throw ExtractionError.extractionFailed }
        progress(1, "Choosing frames")
        return FrameAnalysisPass(
            candidates: candidates,
            decodedFrameCount: frameIndex,
            hadRepairedTimestamps: hadRepairedTimestamps
        )
    }

    private func extractSelectedFramesThroughStaging(
        _ selected: [TimedFrameCandidate],
        analysis: FrameExtractionAnalysis,
        asset: AVAsset,
        track: AVAssetTrack,
        trackTimeRange: CMTimeRange,
        sourceDimensions: FrameAnalysisDimensions,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [ExtractedFrameOutput] {
        let fileManager = FileManager.default
        let parent = outputDir.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(outputDir.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        let strategy = Self.secondPassStrategy(
            selected: selected,
            decodedFrameCount: analysis.decodedFrameCount,
            hadRepairedTimestamps: analysis.hadRepairedTimestamps
        )
        let stagedOutputs: [ExtractedFrameOutput]
        switch strategy {
        case .sparse:
            do {
                stagedOutputs = try await extractSelectedFramesSparsely(
                    selected,
                    asset: asset,
                    track: track,
                    trackTimeRange: trackTimeRange,
                    sourceDimensions: sourceDimensions,
                    preferredTransform: analysis.preferredTransform,
                    sourceFPS: analysis.primaryTrack.nominalFrameRate,
                    decodedFrameCount: analysis.decodedFrameCount,
                    durationSeconds: analysis.durationSeconds,
                    isHDR: analysis.primaryTrack.isHDR,
                    to: staging,
                    options: options,
                    progress: { fraction, message in
                        progress(fraction * 0.2, message)
                    }
                )
            } catch is SparseDecodeError {
                try Task.checkCancellation()
                try fileManager.removeItem(at: staging)
                try fileManager.createDirectory(
                    at: staging,
                    withIntermediateDirectories: false
                )
                stagedOutputs = try await extractSelectedFramesSequentially(
                    selected,
                    asset: asset,
                    track: track,
                    sourceDimensions: sourceDimensions,
                    preferredTransform: analysis.preferredTransform,
                    isHDR: analysis.primaryTrack.isHDR,
                    to: staging,
                    options: options,
                    progress: { fraction, message in
                        progress(0.2 + fraction * 0.8, message)
                    }
                )
            }
        case .sequential:
            stagedOutputs = try await extractSelectedFramesSequentially(
                selected,
                asset: asset,
                track: track,
                sourceDimensions: sourceDimensions,
                preferredTransform: analysis.preferredTransform,
                isHDR: analysis.primaryTrack.isHDR,
                to: staging,
                options: options,
                progress: progress
            )
        }

        try Task.checkCancellation()
        guard stagedOutputs.count == selected.count else {
            throw ExtractionError.extractionFailed
        }
        let destinationExists = fileManager.fileExists(atPath: outputDir.path)
            || ((try? fileManager.destinationOfSymbolicLink(atPath: outputDir.path)) != nil)
        if destinationExists {
            try fileManager.removeItem(at: outputDir)
        }
        try fileManager.moveItem(at: staging, to: outputDir)
        return stagedOutputs.map {
            ExtractedFrameOutput(
                url: outputDir.appendingPathComponent($0.url.lastPathComponent),
                origin: $0.origin
            )
        }
    }

    private func extractSelectedFramesSequentially(
        _ selected: [TimedFrameCandidate],
        asset: AVAsset,
        track: AVAssetTrack,
        sourceDimensions: FrameAnalysisDimensions,
        preferredTransform: CGAffineTransform,
        isHDR: Bool,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [ExtractedFrameOutput] {
        let requestedLongEdge = Int(options.maxDimension.rounded(.down))
        let outputDimensions = requestedLongEdge > 1
            ? Self.analysisDimensions(
                width: sourceDimensions.width,
                height: sourceDimensions.height,
                maximumLongEdge: requestedLongEdge
            )
            : nil
        let (reader, output) = try Self.makeReader(
            asset: asset,
            track: track,
            dimensions: outputDimensions,
            isHDR: isHDR
        )
        guard reader.startReading() else { throw ExtractionError.extractionFailed }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }
        let context = Self.makeCIContext()
        var outputs: [ExtractedFrameOutput] = []
        outputs.reserveCapacity(selected.count)
        var pendingWrites: [(image: CGImage, url: URL)] = []
        pendingWrites.reserveCapacity(Self.maximumConcurrentFrameJobs)
        var selectedIndex = 0
        var frameIndex = 0

        while reader.status == .reading, selectedIndex < selected.count {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            let target = selected[selectedIndex]
            guard frameIndex <= target.frameIndex else {
                throw ExtractionError.extractionFailed
            }
            guard frameIndex == target.frameIndex else {
                frameIndex += 1
                continue
            }
            if let expectedPresentationTime = target.presentationTime {
                let actualPresentationTime = CMSampleBufferGetPresentationTimeStamp(
                    sampleBuffer
                )
                guard actualPresentationTime.isValid,
                      actualPresentationTime.isNumeric,
                      actualPresentationTime.epoch == 0,
                      CMTimeCompare(actualPresentationTime, expectedPresentationTime) == 0 else {
                    throw ExtractionError.extractionFailed
                }
            }
            guard let image = Self.makeCGImage(
                    from: imageBuffer,
                    context: context,
                    maxDimension: 0,
                    transform: preferredTransform
                  ) else {
                throw ExtractionError.extractionFailed
            }
            let fileURL = outputDir.appendingPathComponent(
                Self.timestampedFilename(
                    index: selectedIndex,
                    seconds: target.timestampSeconds,
                    format: options.outputFormat
                )
            )
            pendingWrites.append((image, fileURL))
            if pendingWrites.count == Self.maximumConcurrentFrameJobs {
                try Task.checkCancellation()
                try await Self.writeImages(
                    pendingWrites,
                    format: options.outputFormat
                )
                outputs.append(contentsOf: pendingWrites.enumerated().map { offset, write in
                    let selectedOffset = outputs.count + offset
                    return ExtractedFrameOutput(
                        url: write.url,
                        origin: VideoFrameOrigin(candidate: selected[selectedOffset])
                    )
                })
                let fraction = Double(outputs.count) / Double(selected.count)
                progress(
                    fraction,
                    "Extracting selected frames \(outputs.count)/\(selected.count)"
                )
                pendingWrites.removeAll(keepingCapacity: true)
            }
            selectedIndex += 1
            frameIndex += 1
        }

        try Task.checkCancellation()
        if !pendingWrites.isEmpty {
            try await Self.writeImages(pendingWrites, format: options.outputFormat)
            outputs.append(contentsOf: pendingWrites.enumerated().map { offset, write in
                ExtractedFrameOutput(
                    url: write.url,
                    origin: VideoFrameOrigin(candidate: selected[outputs.count + offset])
                )
            })
            let fraction = Double(outputs.count) / Double(selected.count)
            progress(
                fraction,
                "Extracting selected frames \(outputs.count)/\(selected.count)"
            )
        }
        guard outputs.count == selected.count else {
            throw ExtractionError.extractionFailed
        }
        return outputs
    }

    private func extractSelectedFramesSparsely(
        _ selected: [TimedFrameCandidate],
        asset: AVAsset,
        track: AVAssetTrack,
        trackTimeRange: CMTimeRange,
        sourceDimensions: FrameAnalysisDimensions,
        preferredTransform: CGAffineTransform,
        sourceFPS: Double,
        decodedFrameCount: Int,
        durationSeconds: Double,
        isHDR: Bool,
        to outputDir: URL,
        options: FrameExtractionOptions,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [ExtractedFrameOutput] {
        let requestedLongEdge = Int(options.maxDimension.rounded(.down))
        let outputDimensions = requestedLongEdge > 1
            ? Self.analysisDimensions(
                width: sourceDimensions.width,
                height: sourceDimensions.height,
                maximumLongEdge: requestedLongEdge
            )
            : nil
        let estimatedFPS = durationSeconds > 0
            ? Double(decodedFrameCount) / durationSeconds
            : 0
        let effectiveFPS = sourceFPS.isFinite && sourceFPS > 0
            ? sourceFPS
            : max(estimatedFPS, 1)
        let searchHalfWindow = min(0.25, max(0.05, 1.5 / effectiveFPS))
        let maximumDelta = 0.5 / effectiveFPS
        let context = Self.makeCIContext()
        var outputs: [ExtractedFrameOutput] = []
        outputs.reserveCapacity(selected.count)

        for batchStart in stride(
            from: 0,
            to: selected.count,
            by: Self.maximumConcurrentFrameJobs
        ) {
            try Task.checkCancellation()
            let batchEnd = min(
                selected.count,
                batchStart + Self.maximumConcurrentFrameJobs
            )
            var jobs: [(index: Int, job: SparseReaderJob)] = []
            jobs.reserveCapacity(batchEnd - batchStart)
            for selectedIndex in batchStart..<batchEnd {
                guard let targetTime = selected[selectedIndex].presentationTime else {
                    throw SparseDecodeError.readerSetup
                }
                jobs.append((
                    selectedIndex,
                    try Self.makeSparseReaderJob(
                        asset: asset,
                        track: track,
                        trackTimeRange: trackTimeRange,
                        targetTime: targetTime,
                        searchHalfWindow: searchHalfWindow,
                        maximumDelta: maximumDelta,
                        dimensions: outputDimensions,
                        isHDR: isHDR,
                        context: context,
                        preferredTransform: preferredTransform
                    )
                ))
            }

            let decoded = try await withThrowingTaskGroup(
                of: SparseDecodedFrame.self,
                returning: [SparseDecodedFrame].self
            ) { group in
                for item in jobs {
                    group.addTask {
                        SparseDecodedFrame(
                            selectedIndex: item.index,
                            image: try item.job.decode()
                        )
                    }
                }
                var results: [SparseDecodedFrame] = []
                results.reserveCapacity(jobs.count)
                for try await result in group {
                    results.append(result)
                }
                return results.sorted { $0.selectedIndex < $1.selectedIndex }
            }

            let writes = decoded.map { result in
                let target = selected[result.selectedIndex]
                let url = outputDir.appendingPathComponent(
                    Self.timestampedFilename(
                        index: result.selectedIndex,
                        seconds: target.timestampSeconds,
                        format: options.outputFormat
                    )
                )
                return (image: result.image, url: url)
            }
            try await Self.writeImages(writes, format: options.outputFormat)
            outputs.append(contentsOf: writes.enumerated().map { offset, write in
                let selectedIndex = outputs.count + offset
                return ExtractedFrameOutput(
                    url: write.url,
                    origin: VideoFrameOrigin(candidate: selected[selectedIndex])
                )
            })
            let fraction = Double(outputs.count) / Double(selected.count)
            progress(
                fraction,
                "Extracting selected frames \(outputs.count)/\(selected.count)"
            )
        }
        return outputs
    }

    private static func makeSparseReaderJob(
        asset: AVAsset,
        track: AVAssetTrack,
        trackTimeRange: CMTimeRange,
        targetTime: CMTime,
        searchHalfWindow: Double,
        maximumDelta: Double,
        dimensions: FrameAnalysisDimensions?,
        isHDR: Bool,
        context: CIContext,
        preferredTransform: CGAffineTransform
    ) throws -> SparseReaderJob {
        let targetSeconds = CMTimeGetSeconds(targetTime)
        let trackStartSeconds = CMTimeGetSeconds(trackTimeRange.start)
        guard targetTime.isValid,
              targetTime.isNumeric,
              targetTime.epoch == 0,
              targetSeconds.isFinite,
              targetSeconds >= 0,
              searchHalfWindow.isFinite,
              searchHalfWindow > 0,
              maximumDelta.isFinite,
              maximumDelta > 0 else {
            throw SparseDecodeError.readerSetup
        }
        let lowerBound = trackStartSeconds.isFinite ? trackStartSeconds : 0
        let startSeconds = max(lowerBound, targetSeconds - searchHalfWindow)
        let endSeconds = targetSeconds + searchHalfWindow
        guard endSeconds > startSeconds else {
            throw SparseDecodeError.readerSetup
        }
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        do {
            (reader, output) = try makeReader(
                asset: asset,
                track: track,
                dimensions: dimensions,
                isHDR: isHDR
            )
        } catch {
            throw SparseDecodeError.readerSetup
        }
        let rangeTimescale = max(CMTimeScale(600_000), targetTime.timescale)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: rangeTimescale),
            duration: CMTime(
                seconds: endSeconds - startSeconds,
                preferredTimescale: rangeTimescale
            )
        )
        return SparseReaderJob(
            reader: reader,
            output: output,
            targetTime: targetTime,
            maximumDeltaSeconds: maximumDelta,
            context: context,
            preferredTransform: preferredTransform
        )
    }

    private static func makeReader(
        asset: AVAsset,
        track: AVAssetTrack,
        dimensions: FrameAnalysisDimensions?,
        isHDR: Bool
    ) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        var outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                isHDR
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        if let dimensions {
            outputSettings[kCVPixelBufferWidthKey as String] = dimensions.width
            outputSettings[kCVPixelBufferHeightKey as String] = dimensions.height
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractionError.invalidVideo }
        reader.add(output)
        return (reader, output)
    }

    private static func writeImages(
        _ images: [(image: CGImage, url: URL)],
        format: FrameOutputFormat
    ) async throws {
        precondition(images.count <= maximumConcurrentFrameJobs)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in images {
                group.addTask {
                    try writeImage(cgImage: item.image, to: item.url, format: format)
                }
            }
            try await group.waitForAll()
        }
    }

    private static func primaryTrackIndex(
        _ descriptors: [VideoTrackDescriptor]
    ) -> Int? {
        let enabled = descriptors.filter {
            $0.isEnabled
                && $0.isDecodable
                && !$0.isAuxiliary
                && $0.width > 0
                && $0.height > 0
                && $0.durationSeconds > 0
        }
        guard let longestDuration = enabled.map(\.durationSeconds).max() else {
            return nil
        }
        let nearFullDuration = enabled.filter {
            $0.durationSeconds >= longestDuration * 0.95
        }
        return nearFullDuration
            .max { lhs, rhs in
                let lhsPixels = pixelArea(width: lhs.width, height: lhs.height)
                let rhsPixels = pixelArea(width: rhs.width, height: rhs.height)
                if lhsPixels != rhsPixels { return lhsPixels < rhsPixels }
                if lhs.estimatedDataRate != rhs.estimatedDataRate {
                    return lhs.estimatedDataRate < rhs.estimatedDataRate
                }
                if lhs.durationSeconds != rhs.durationSeconds {
                    return lhs.durationSeconds < rhs.durationSeconds
                }
                return lhs.trackID > rhs.trackID
            }?
            .index
    }

    private static func pixelDimension(_ value: CGFloat) -> Int {
        let rounded = abs(Double(value)).rounded()
        guard rounded.isFinite,
              rounded > 0,
              rounded < Double(Int.max) else {
            return 0
        }
        return Int(rounded)
    }

    private static func pixelArea(width: Int, height: Int) -> UInt64 {
        guard width > 0, height > 0 else { return 0 }
        let product = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        return product.overflow ? .max : product.partialValue
    }

    private static func analysisDimensions(
        width: Int,
        height: Int,
        maximumLongEdge: Int = 384
    ) -> FrameAnalysisDimensions {
        guard width > 0, height > 0, maximumLongEdge > 1 else {
            return FrameAnalysisDimensions(width: 2, height: 2)
        }
        let scale = min(1, Double(maximumLongEdge) / Double(max(width, height)))
        func evenFloor(_ value: Double) -> Int {
            max(2, Int(floor(value / 2)) * 2)
        }
        return FrameAnalysisDimensions(
            width: evenFloor(Double(width) * scale),
            height: evenFloor(Double(height) * scale)
        )
    }

    private static func analysisFrameRate(
        options: FrameExtractionOptions,
        duration: Double,
        videoFPS _: Double
    ) -> Double {
        let baseRate = Double(max(1, options.targetFPS))
        guard duration.isFinite, duration > 0 else { return baseRate }
        let alternativesPerOutput = 3.0
        let coverageRate = Double(max(1, options.targetCount))
            * alternativesPerOutput
            / duration
        let requestedRate = max(baseRate, coverageRate)
        return requestedRate.isFinite ? requestedRate : Double.greatestFiniteMagnitude
    }

    private static func secondPassStrategy(
        selected: [TimedFrameCandidate],
        decodedFrameCount: Int,
        hadRepairedTimestamps: Bool
    ) -> FrameSecondPassStrategy {
        guard !selected.isEmpty,
              decodedFrameCount > 0,
              selected.count <= decodedFrameCount / 20,
              !hadRepairedTimestamps,
              selected.allSatisfy({ $0.presentationTime != nil }) else {
            return .sequential
        }
        return .sparse
    }

    private static func normalizedPresentationTime(
        _ rawPresentationTime: CMTime,
        frameIndex: Int,
        sourceFPS: Double,
        previous: Double?
    ) -> NormalizedFrameTimestamp {
        let rawSeconds = CMTimeGetSeconds(rawPresentationTime)
        let isExact = rawPresentationTime.isValid
            && rawPresentationTime.isNumeric
            && rawPresentationTime.epoch == 0
            && rawPresentationTime.timescale > 0
            && rawSeconds.isFinite
            && rawSeconds >= 0
            && previous.map({ rawSeconds > $0 }) ?? true
        if isExact {
            return NormalizedFrameTimestamp(
                seconds: rawSeconds,
                presentationTime: rawPresentationTime,
                wasRepaired: false
            )
        }
        return NormalizedFrameTimestamp(
            seconds: monotonicTimestamp(
                rawSeconds,
                frameIndex: frameIndex,
                sourceFPS: sourceFPS,
                previous: previous
            ),
            presentationTime: nil,
            wasRepaired: true
        )
    }

    private static func monotonicTimestamp(
        _ rawTimestamp: Double,
        frameIndex: Int,
        sourceFPS: Double,
        previous: Double?
    ) -> Double {
        let fallbackFPS = sourceFPS.isFinite && sourceFPS > 0 ? sourceFPS : 30
        let fallback = Double(frameIndex) / fallbackFPS
        let candidate = rawTimestamp.isFinite && rawTimestamp >= 0
            ? rawTimestamp
            : fallback
        guard let previous else { return candidate }
        return candidate > previous ? candidate : previous + 1 / fallbackFPS
    }

    static func timestampedFilename(index: Int, seconds: Double, format: FrameOutputFormat) -> String {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let scaled = (safeSeconds * 1_000_000).rounded()
        let microseconds = scaled.isFinite && scaled < Double(Int64.max)
            ? Int64(scaled)
            : Int64.max
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

    private static func sampledLumaPixels(
        from buffer: CVPixelBuffer,
        width: Int = 64,
        height: Int = 64
    ) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let baseAddress = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return nil
        }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard sourceWidth > 0, sourceHeight > 0, bytesPerRow >= sourceWidth else {
            return nil
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            return nil
        }
        let usesVideoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for targetY in 0..<height {
            let sourceY = min(sourceHeight - 1, targetY * sourceHeight / height)
            let row = bytes.advanced(by: sourceY * bytesPerRow)
            for targetX in 0..<width {
                let sourceX = min(sourceWidth - 1, targetX * sourceWidth / width)
                let raw = Int(row[sourceX])
                let value: Int
                if usesVideoRange {
                    value = min(255, max(0, (raw - 16) * 255 / 219))
                } else {
                    value = raw
                }
                pixels[targetY * width + targetX] = UInt8(value)
            }
        }
        return pixels
    }

    private static func lumaMotionScore(
        _ pixels: [UInt8],
        previous: [UInt8]?
    ) -> Double {
        guard let previous, previous.count == pixels.count, !pixels.isEmpty else {
            return 0
        }
        let mean = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
        let previousMean = Double(previous.reduce(0) { $0 + Int($1) })
            / Double(previous.count)
        var totalDifference = 0.0
        for (lhs, rhs) in zip(pixels, previous) {
            let currentCentered = Double(lhs) - mean
            let previousCentered = Double(rhs) - previousMean
            totalDifference += abs(currentCentered - previousCentered)
        }
        let meanDifference = totalDifference / Double(pixels.count)
        return min(1, meanDifference / 32)
    }

    private static func makeCIContext() -> CIContext {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options.merging([.useSoftwareRenderer: false]) { first, _ in first })
    }

    private static func makeCGImage(
        from buffer: CVPixelBuffer,
        context: CIContext,
        maxDimension: CGFloat,
        transform: CGAffineTransform
    ) -> CGImage? {
        var image = CIImage(
            cvPixelBuffer: buffer,
            options: [.toneMapHDRtoSDR: true]
        ).transformed(by: transform)
        let transformedExtent = image.extent
        if transformedExtent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -transformedExtent.origin.x, y: -transformedExtent.origin.y))
        }
        let extent = image.extent
        let largest = max(extent.width, extent.height)
        if maxDimension > 0, largest > maxDimension {
            let scale = maxDimension / largest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.createCGImage(
            image,
            from: image.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
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

#if DEBUG
extension FrameExtractor {
    static func test_primaryTrackIndex(_ descriptors: [VideoTrackDescriptor]) -> Int? {
        primaryTrackIndex(descriptors)
    }

    static func test_analysisDimensions(width: Int, height: Int) -> FrameAnalysisDimensions {
        analysisDimensions(width: width, height: height)
    }

    static func test_pixelDimension(_ value: CGFloat) -> Int {
        pixelDimension(value)
    }

    static func test_analysisFrameRate(
        options: FrameExtractionOptions,
        duration: Double,
        videoFPS: Double
    ) -> Double {
        analysisFrameRate(options: options, duration: duration, videoFPS: videoFPS)
    }

    static func test_lumaMotionScore(
        _ pixels: [UInt8],
        previous: [UInt8]?
    ) -> Double {
        lumaMotionScore(pixels, previous: previous)
    }

    static func test_monotonicTimestamp(
        _ rawTimestamp: Double,
        frameIndex: Int,
        sourceFPS: Double,
        previous: Double?
    ) -> Double {
        monotonicTimestamp(
            rawTimestamp,
            frameIndex: frameIndex,
            sourceFPS: sourceFPS,
            previous: previous
        )
    }

    static func test_secondPassStrategy(
        selected: [TimedFrameCandidate],
        decodedFrameCount: Int,
        hadRepairedTimestamps: Bool
    ) -> FrameSecondPassStrategy {
        secondPassStrategy(
            selected: selected,
            decodedFrameCount: decodedFrameCount,
            hadRepairedTimestamps: hadRepairedTimestamps
        )
    }

    static func test_normalizedPresentationTime(
        _ rawPresentationTime: CMTime,
        frameIndex: Int,
        sourceFPS: Double,
        previous: Double?
    ) -> NormalizedFrameTimestamp {
        normalizedPresentationTime(
            rawPresentationTime,
            frameIndex: frameIndex,
            sourceFPS: sourceFPS,
            previous: previous
        )
    }

    static func test_timestampedFilename(index: Int, seconds: Double, format: FrameOutputFormat) -> String {
        timestampedFilename(index: index, seconds: seconds, format: format)
    }

    static func test_timestampSeconds(from filename: String) -> Double? {
        timestampSeconds(from: filename)
    }

    static func test_sampledLumaPixels(from buffer: CVPixelBuffer) -> [UInt8]? {
        sampledLumaPixels(from: buffer)
    }

}
#endif
