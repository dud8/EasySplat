import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VideoFrameAllocationInput: Equatable, Sendable {
    let durationSeconds: Double
    let availableCandidateCount: Int
}

enum VideoFrameAllocationError: Error, Equatable {
    case invalidInput(index: Int)
    case insufficientBudgetForClipCoverage(required: Int, available: Int)
}

enum LocalFileCopyStrategy: Equatable, Sendable {
    case copyOnWriteClone
    case streamed
}

struct GlobalFrameTargets: Equatable, Sendable {
    let videoTargets: [Int]
    let photoTarget: Int

    var totalTargetCount: Int { videoTargets.reduce(0, +) + photoTarget }
}

struct IndexedFrameAnalysis: Sendable {
    let index: Int
    let analysis: FrameExtractionAnalysis
}

struct RefreshedVideoFrameAnalysis: Sendable {
    let receipts: [VideoInputReceipt]
    let supersededArtifactRemovals: [VideoFrameAnalysisArtifactRemovalToken]
    let creationLedger: VideoFrameAnalysisArtifactCreationLedger
}

struct VideoSourceAnalysisConcurrencySnapshot: Sendable, Equatable {
    let startedAnalysisTaskCount: Int
    let peakInFlightAnalysisTaskCount: Int
}

final class VideoSourceAnalysisConcurrencyMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var startedAnalysisTaskCount = 0
    private var peakInFlightAnalysisTaskCount = 0

    func measure<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        lock.withLock {
            activeCount += 1
            startedAnalysisTaskCount += 1
            peakInFlightAnalysisTaskCount = max(peakInFlightAnalysisTaskCount, activeCount)
        }
        defer {
            lock.withLock {
                activeCount -= 1
            }
        }
        return try await operation()
    }

    func snapshot() -> VideoSourceAnalysisConcurrencySnapshot {
        lock.withLock {
            VideoSourceAnalysisConcurrencySnapshot(
                startedAnalysisTaskCount: startedAnalysisTaskCount,
                peakInFlightAnalysisTaskCount: peakInFlightAnalysisTaskCount
            )
        }
    }
}

final class WeightedVideoAnalysisProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let weights: [Double]
    private let totalWeight: Double
    private let base: Double
    private let span: Double
    private let report: @Sendable (Double) -> Void
    private var fractions: [Double]
    private var lastReported: Double?

    init(
        weights: [Double],
        base: Double,
        span: Double,
        report: @escaping @Sendable (Double) -> Void
    ) {
        let sanitizedWeights = weights.map {
            $0.isFinite && $0 > 0 ? $0 : 1
        }
        self.weights = sanitizedWeights
        self.totalWeight = max(1, sanitizedWeights.reduce(0, +))
        self.base = base
        self.span = span
        self.report = report
        self.fractions = [Double](repeating: 0, count: weights.count)
    }

    func update(index: Int, fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard fractions.indices.contains(index) else { return }
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        fractions[index] = max(fractions[index], clamped)
        let aggregate = zip(weights, fractions).reduce(0.0) {
            $0 + $1.0 * $1.1
        } / totalWeight
        let next = base + span * aggregate
        guard lastReported.map({ next > $0 }) ?? true else { return }
        lastReported = next
        report(next)
    }
}

extension PipelineRunner {
    static func shouldFallBackFromCloneError(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EXDEV
    }

    static func videoSourceAnalysisConcurrency(
        maximumConcurrentTasks: Int,
        videoSourceCount: Int
    ) -> Int {
        guard videoSourceCount > 0 else { return 0 }
        return min(videoSourceCount, max(1, maximumConcurrentTasks))
    }

    func videoFrameAnalysisRequiresRefresh(
        metadata: ProjectMetadata,
        currentPlan: ResolvedRunPlan
    ) throws -> Bool {
        guard metadata.input.hasVideos,
              let receipts = metadata.videoInputReceipts,
              !receipts.isEmpty else {
            return false
        }
        let policy = VideoFrameAnalysisPolicy(resolvedRunPlan: currentPlan)
        let identities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: receipts.map(\.sha256),
            pairingPolicy: currentPlan.pairingPolicy
        )
        let identityBySourceIndex = Dictionary(
            uniqueKeysWithValues: identities.map { ($0.sourceIndex, $0) }
        )
        return receipts.enumerated().contains { index, receipt in
            receipt.analysisPolicySHA256 != policy.sha256
                || receipt.clipGroupID != identityBySourceIndex[index]?.groupID
        }
    }

    func refreshVideoFrameAnalysisIfNeeded(
        metadata: ProjectMetadata,
        currentPlan: ResolvedRunPlan,
        inputLease: RuntimeInputSnapshotLease,
        paths: ProjectPaths
    ) async throws -> RefreshedVideoFrameAnalysis? {
        guard metadata.input.hasVideos,
              let receipts = metadata.videoInputReceipts,
              receipts.count == inputLease.videos.count,
              !receipts.isEmpty else {
            return nil
        }
        let policy = VideoFrameAnalysisPolicy(resolvedRunPlan: currentPlan)
        let identities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: receipts.map(\.sha256),
            pairingPolicy: currentPlan.pairingPolicy
        )
        let identityBySourceIndex = Dictionary(
            uniqueKeysWithValues: identities.map { ($0.sourceIndex, $0) }
        )
        guard try videoFrameAnalysisRequiresRefresh(
            metadata: metadata,
            currentPlan: currentPlan
        ) else { return nil }

        try Task.checkCancellation()
        try inputLease.validate()
        let snapshotsByIndex = Dictionary(
            uniqueKeysWithValues: inputLease.videos.map { ($0.index, $0) }
        )
        guard snapshotsByIndex.count == receipts.count else {
            throw RuntimeInputSnapshotError.invalidMetadata
        }
        let extractor = FrameExtractor()
        var sources: [FrameExtractionSource] = []
        sources.reserveCapacity(receipts.count)
        for index in receipts.indices {
            try Task.checkCancellation()
            guard let snapshot = snapshotsByIndex[index],
                  snapshot.projectRelativePath == receipts[index].projectRelativePath,
                  snapshot.byteCount == receipts[index].byteCount,
                  snapshot.sha256 == receipts[index].sha256 else {
                throw RuntimeInputSnapshotError.invalidMetadata
            }
            sources.append(try await extractor.inspect(snapshot.url))
        }
        let concurrencyMeter = VideoSourceAnalysisConcurrencyMeter()
        let analyses = try await analyzeVideoSources(
            sources,
            options: policy.extractionOptions,
            targetCounts: [Int](
                repeating: policy.targetFrameCeiling,
                count: sources.count
            ),
            maximumConcurrentTasks: policy.maximumConcurrentDecoders,
            concurrencyMeter: concurrencyMeter,
            progress: { _, _ in }
        )
        try inputLease.validate()

        let creationLedger = VideoFrameAnalysisArtifactCreationLedger()
        var handedOffCreationLedger = false
        defer {
            if !handedOffCreationLedger {
                creationLedger.rollback()
            }
        }
        var refreshedReceipts: [VideoInputReceipt] = []
        refreshedReceipts.reserveCapacity(receipts.count)
        var supersededRemovals: [VideoFrameAnalysisArtifactRemovalToken] = []
        supersededRemovals.reserveCapacity(receipts.count)
        for index in receipts.indices {
            try Task.checkCancellation()
            let receipt = receipts[index]
            guard let identity = identityBySourceIndex[index] else {
                throw RuntimeInputSnapshotError.invalidMetadata
            }
            let analysis = analyses[index]
            let artifact = VideoFrameAnalysisArtifact(
                receipt: receipt,
                sourceIndex: index,
                clipGroupID: identity.groupID,
                policy: policy,
                analysis: analysis
            )
            let saved = try VideoFrameAnalysisArtifactStore.saveRegenerated(
                artifact,
                projectPaths: paths
            )
            creationLedger.record(saved.cleanupToken)
            let newRelativePath = try paths.projectRelativePath(for: saved.url)
            guard newRelativePath != receipt.analysisArtifactPath else {
                throw VideoFrameAnalysisArtifactStoreError.unsafePath
            }
            refreshedReceipts.append(VideoInputReceipt(
                projectRelativePath: receipt.projectRelativePath,
                safeDisplayName: receipt.safeDisplayName,
                byteCount: receipt.byteCount,
                sha256: receipt.sha256,
                trackID: analysis.primaryTrack.trackID,
                pixelWidth: analysis.primaryTrack.width,
                pixelHeight: analysis.primaryTrack.height,
                durationSeconds: analysis.durationSeconds,
                nominalFrameRate: analysis.primaryTrack.nominalFrameRate,
                isHDR: analysis.primaryTrack.isHDR,
                decodedFrameCount: analysis.decodedFrameCount,
                transformA: analysis.preferredTransform.a,
                transformB: analysis.preferredTransform.b,
                transformC: analysis.preferredTransform.c,
                transformD: analysis.preferredTransform.d,
                transformTX: analysis.preferredTransform.tx,
                transformTY: analysis.preferredTransform.ty,
                clipGroupID: identity.groupID,
                analysisPolicySHA256: policy.sha256,
                analysisArtifactPath: newRelativePath,
                analysisArtifactByteCount: saved.evidence.byteCount,
                analysisArtifactSHA256: saved.evidence.sha256
            ))
            supersededRemovals.append(
                try VideoFrameAnalysisArtifactStore.makeRemovalToken(
                    at: paths.resolveProjectRelativePath(receipt.analysisArtifactPath),
                    expectedEvidence: VideoFrameAnalysisArtifactFileEvidence(
                        byteCount: receipt.analysisArtifactByteCount,
                        sha256: receipt.analysisArtifactSHA256
                    ),
                    sourceIndex: index,
                    projectPaths: paths
                )
            )
        }
        // This is the transaction boundary: until the atomic metadata save publishes
        // these receipts, the ledger owns and rolls back only files this attempt created.
        try tooling.checkCancellation()
        try inputLease.validate()
        handedOffCreationLedger = true
        return RefreshedVideoFrameAnalysis(
            receipts: refreshedReceipts,
            supersededArtifactRemovals: supersededRemovals,
            creationLedger: creationLedger
        )
    }

    static func durationAwareVideoFrameTarget(
        durations: [Double],
        frameCeiling: Int,
        analysisFrameRate: Int,
        detail: DetailProfile
    ) -> Int? {
        guard !durations.isEmpty,
              frameCeiling > 0,
              analysisFrameRate > 0,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        // Balanced and High Detail are quality contracts: they consume their full
        // resolved keyframe budget whenever the source can supply it. Only Fast
        // trades temporal density for shorter captures.
        guard detail == .fast else { return frameCeiling }
        let totalDuration = durations.reduce(0, +)
        guard totalDuration.isFinite, totalDuration > 0 else { return nil }
        let density = Double(analysisFrameRate)
        let durationTarget = ceil(totalDuration * density)
        guard durationTarget.isFinite, durationTarget > 0 else { return nil }
        if durationTarget >= Double(frameCeiling) {
            return frameCeiling
        }
        let (clipCoverage, overflowed) = durations.count.multipliedReportingOverflow(by: 2)
        guard !overflowed else { return frameCeiling }
        return min(
            frameCeiling,
            max(30, clipCoverage, Int(durationTarget))
        )
    }

    func analyzeVideoSources(
        _ sources: [FrameExtractionSource],
        options: FrameExtractionOptions,
        targetCounts: [Int],
        maximumConcurrentTasks: Int,
        concurrencyMeter: VideoSourceAnalysisConcurrencyMeter,
        progress: @escaping @Sendable (Int, Double) -> Void
    ) async throws -> [FrameExtractionAnalysis] {
        guard !sources.isEmpty,
              sources.count == targetCounts.count,
              targetCounts.allSatisfy({ $0 > 0 }) else {
            throw PipelineError.invalidInput
        }
        let concurrentSourceCount = min(sources.count, max(1, maximumConcurrentTasks))
        return try await withThrowingTaskGroup(
            of: IndexedFrameAnalysis.self,
            returning: [FrameExtractionAnalysis].self
        ) { group in
            var nextIndex = 0
            var results = [FrameExtractionAnalysis?](
                repeating: nil,
                count: sources.count
            )

            func submit(_ index: Int) {
                let source = sources[index]
                var configuredOptions = options
                configuredOptions.targetCount = targetCounts[index]
                let sourceOptions = configuredOptions
                group.addTask {
                    try Task.checkCancellation()
                    let analysis = try await concurrencyMeter.measure {
                        let extractor = FrameExtractor()
                        return try await extractor.analyze(
                            source,
                            options: sourceOptions,
                            progress: { fraction, _ in
                                progress(index, fraction)
                            }
                        )
                    }
                    return IndexedFrameAnalysis(index: index, analysis: analysis)
                }
            }

            while nextIndex < concurrentSourceCount {
                submit(nextIndex)
                nextIndex += 1
            }
            while let result = try await group.next() {
                results[result.index] = result.analysis
                if nextIndex < sources.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
            guard results.allSatisfy({ $0 != nil }) else {
                throw PipelineError.invalidInput
            }
            return results.compactMap { $0 }
        }
    }
    // Selected-frame names and group identifiers are generated by EasySplat. Four
    // MiB allows more than one KiB per entry at the 3,000-frame release boundary.
    private static let maximumSelectedFrameManifestBytes = 4 * 1_024 * 1_024

    enum FrameBudgetProjection: Equatable, Sendable {
        case evenlySpaced
        case rankedPrefix
        case preserve
    }

    struct SelectedFrameGroup: Sendable {
        let id: String
        let frames: [URL]
        let isVideo: Bool
        let budgetProjection: FrameBudgetProjection
        let videoSource: SelectedVideoSource?
        let videoOriginsByFileName: [String: VideoFrameOrigin]
        let sourceBindingsByFileName: [String: SelectedInputSource]

        init(
            id: String,
            frames: [URL],
            isVideo: Bool,
            budgetProjection: FrameBudgetProjection = .evenlySpaced,
            videoSource: SelectedVideoSource? = nil,
            videoOriginsByFileName: [String: VideoFrameOrigin] = [:],
            sourceBindingsByFileName: [String: SelectedInputSource] = [:]
        ) {
            self.id = id
            self.frames = frames
            self.isVideo = isVideo
            self.budgetProjection = budgetProjection
            self.videoSource = videoSource
            self.videoOriginsByFileName = videoOriginsByFileName
            self.sourceBindingsByFileName = sourceBindingsByFileName
        }
    }

    struct SelectedInputSource: Equatable, Sendable {
        let projectRelativePath: String
        let sha256: String
        let photoRetainedRank: Int?

        init(
            projectRelativePath: String,
            sha256: String,
            photoRetainedRank: Int? = nil
        ) {
            self.projectRelativePath = projectRelativePath
            self.sha256 = sha256
            self.photoRetainedRank = photoRetainedRank
        }
    }

    struct SelectedVideoSource: Codable, Equatable, Sendable {
        let projectRelativePath: String
        let sourceSHA256: String
        let trackID: Int32
        let pixelWidth: Int
        let pixelHeight: Int
        let nominalFrameRate: Double
        let transformA: Double
        let transformB: Double
        let transformC: Double
        let transformD: Double
        let transformTX: Double
        let transformTY: Double

        init(
            projectRelativePath: String,
            sourceSHA256: String,
            source: FrameExtractionSource
        ) {
            self.projectRelativePath = projectRelativePath
            self.sourceSHA256 = sourceSHA256
            trackID = source.primaryTrack.trackID
            pixelWidth = source.primaryTrack.width
            pixelHeight = source.primaryTrack.height
            nominalFrameRate = source.primaryTrack.nominalFrameRate
            transformA = source.preferredTransform.a
            transformB = source.preferredTransform.b
            transformC = source.preferredTransform.c
            transformD = source.preferredTransform.d
            transformTX = source.preferredTransform.tx
            transformTY = source.preferredTransform.ty
        }

        var affineTransform: CGAffineTransform {
            CGAffineTransform(
                a: transformA,
                b: transformB,
                c: transformC,
                d: transformD,
                tx: transformTX,
                ty: transformTY
            )
        }

        var isValidEvidence: Bool {
            let sourceComponents = projectRelativePath.split(separator: "/")
            return sourceComponents.count == 2
                && sourceComponents[0] == "Originals"
                && sourceSHA256.count == 64
                && sourceSHA256 == sourceSHA256.lowercased()
                && sourceSHA256.allSatisfy(\.isHexDigit)
                && trackID > 0
                && pixelWidth > 0
                && pixelHeight > 0
                && nominalFrameRate.isFinite
                && nominalFrameRate >= 0
                && [
                    transformA,
                    transformB,
                    transformC,
                    transformD,
                    transformTX,
                    transformTY,
                ].allSatisfy(\.isFinite)
        }
    }

    struct SelectedFrameNormalization: Codable, Equatable, Sendable {
        let sourcePixelWidth: Int
        let sourcePixelHeight: Int
        let sourceOrientation: Int
        let maximumPixelDimension: Int
        let outputPixelWidth: Int
        let outputPixelHeight: Int
        let outputFormat: String
        let transcoded: Bool
    }

    struct SelectedFrameMapping: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 3

        let schemaVersion: Int
        let outputFileName: String
        let groupId: String
        let isVideo: Bool
        let timestampSeconds: Double?
        let lowLightExposureEV: Double?
        let sourceProjectRelativePath: String?
        let sourceSHA256: String?
        let photoRetainedRank: Int?
        let selectedSHA256: String?
        let selectedPixelSHA256: String?
        let normalization: SelectedFrameNormalization?
        let videoSource: SelectedVideoSource?
        let videoOrigin: VideoFrameOrigin?

        init(
            schemaVersion: Int = currentSchemaVersion,
            outputFileName: String,
            groupId: String,
            isVideo: Bool,
            timestampSeconds: Double? = nil,
            lowLightExposureEV: Double? = nil,
            sourceProjectRelativePath: String? = nil,
            sourceSHA256: String? = nil,
            photoRetainedRank: Int? = nil,
            selectedSHA256: String? = nil,
            selectedPixelSHA256: String? = nil,
            normalization: SelectedFrameNormalization? = nil,
            videoSource: SelectedVideoSource? = nil,
            videoOrigin: VideoFrameOrigin? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.outputFileName = outputFileName
            self.groupId = groupId
            self.isVideo = isVideo
            self.timestampSeconds = timestampSeconds
            self.lowLightExposureEV = lowLightExposureEV
            self.sourceProjectRelativePath = sourceProjectRelativePath
            self.sourceSHA256 = sourceSHA256
            self.photoRetainedRank = photoRetainedRank
            self.selectedSHA256 = selectedSHA256
            self.selectedPixelSHA256 = selectedPixelSHA256
            self.normalization = normalization
            self.videoSource = videoSource
            self.videoOrigin = videoOrigin
        }

        var hasValidPhotoRetainedRankLineage: Bool {
            if isVideo {
                return photoRetainedRank == nil
            }
            return photoRetainedRank.map { $0 >= 0 } == true
        }
    }

    var supportedImageExtensions: Set<String> {
        PhotoInputPreflight.supportedExtensions
    }

    func isHeicImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    func selectedFrameOutputExtension(for source: URL) -> String {
        switch source.pathExtension.lowercased() {
        case "", "heic", "heif", "jpeg":
            return "jpg"
        case let ext:
            return ext
        }
    }

    func selectedImagesHaveUniformPixelDimensions(_ images: [URL]) throws -> Bool {
        try selectedImageUniformPixelDimensions(images) != nil
    }

    func selectedImageUniformPixelDimensions(
        _ images: [URL]
    ) throws -> SelectedImagePixelDimensions? {
        do {
            return try SelectedImageCameraGroupingPolicy.uniformPixelDimensions(images)
        } catch SelectedImageCameraGroupingPolicy.Error.unreadableImage(let name) {
            throw PipelineError.imageTranscodeFailed(
                "Failed to inspect selected image: \(name)"
            )
        }
    }

    func transcodeHeicToJpeg(source: URL, destination: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw PipelineError.imageTranscodeFailed("Failed to read HEIC image: \(source.lastPathComponent)")
        }

        let props = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxDim = max(1, max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceShouldCache: false
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(sourceRef, 0, options as CFDictionary) else {
            throw PipelineError.imageTranscodeFailed("Failed to decode HEIC image: \(source.lastPathComponent)")
        }

        guard let destRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PipelineError.imageTranscodeFailed("Failed to create JPEG output: \(destination.lastPathComponent)")
        }

        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        CGImageDestinationAddImage(destRef, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destRef) else {
            throw PipelineError.imageTranscodeFailed("Failed to write JPEG image: \(destination.lastPathComponent)")
        }
    }

    func copySelected(
        groups: [SelectedFrameGroup],
        to directory: URL,
        manifestURL: URL,
        maxDimension: CGFloat,
        projectPaths: ProjectPaths? = nil,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> (frames: [URL], manifest: [SelectedFrameMapping]) {
        let fm = FileManager.default
        var output: [URL] = []
        var manifest: [SelectedFrameMapping] = []
        let total = groups.reduce(0) { $0 + $1.frames.count }
        var index = 0
        var copied = 0
        var lowLightContext: CIContext?
        for group in groups {
            for frame in group.frames {
                try Task.checkCancellation()
                if group.isVideo, projectPaths != nil {
                    let origin = group.videoOriginsByFileName[frame.lastPathComponent]
                    guard group.videoSource != nil,
                          origin?.isValidEvidence == true else {
                        throw PipelineError.invalidInput
                    }
                }
                let destExt = selectedFrameOutputExtension(for: frame)
                let dest = directory.appendingPathComponent(String(format: "frame_%06d.%@", index, destExt))
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                let normalization = try copySelectedFrame(
                    source: frame,
                    destination: dest,
                    maxDimension: maxDimension,
                    context: &lowLightContext
                )
                let sourceProjectRelativePath: String?
                let sourceSHA256: String?
                let photoRetainedRank: Int?
                if projectPaths != nil {
                    if group.isVideo {
                        guard let videoSource = group.videoSource else {
                            throw PipelineError.invalidInput
                        }
                        sourceProjectRelativePath = videoSource.projectRelativePath
                        sourceSHA256 = videoSource.sourceSHA256
                        photoRetainedRank = nil
                    } else {
                        guard let source = group.sourceBindingsByFileName[
                            frame.lastPathComponent
                        ],
                              let retainedRank = source.photoRetainedRank,
                              retainedRank >= 0 else {
                            throw PipelineError.invalidInput
                        }
                        sourceProjectRelativePath = source.projectRelativePath
                        sourceSHA256 = source.sha256
                        photoRetainedRank = retainedRank
                    }
                } else {
                    sourceProjectRelativePath = nil
                    sourceSHA256 = nil
                    photoRetainedRank = nil
                }
                let selectedIdentity = try Self.selectedFrameContentIdentity(
                    at: dest,
                    maximumPixelDimension: normalization.evidence.maximumPixelDimension
                )
                output.append(dest)
                manifest.append(SelectedFrameMapping(
                    outputFileName: dest.lastPathComponent,
                    groupId: group.id,
                    isVideo: group.isVideo,
                    timestampSeconds: group.isVideo
                        ? group.videoOriginsByFileName[frame.lastPathComponent]?.timestampSeconds
                        : nil,
                    lowLightExposureEV: normalization.lowLightExposureEV,
                    sourceProjectRelativePath: sourceProjectRelativePath,
                    sourceSHA256: sourceSHA256,
                    photoRetainedRank: photoRetainedRank,
                    selectedSHA256: selectedIdentity.sha256,
                    selectedPixelSHA256: selectedIdentity.pixelSHA256,
                    normalization: normalization.evidence,
                    videoSource: group.videoSource,
                    videoOrigin: group.videoOriginsByFileName[frame.lastPathComponent]
                ))
                index += 1
                copied += 1
                if let progress, total > 0, copied % 5 == 0 || copied == total {
                    let fraction = Double(copied) / Double(total)
                    progress(fraction, "Copying selected frames \(copied)/\(total)")
                }
            }
        }
        try saveSelectedFrameManifest(manifest, to: manifestURL)
        return (output, manifest)
    }

    private struct SelectedFrameNormalizationResult {
        let lowLightExposureEV: Double?
        let evidence: SelectedFrameNormalization
    }

    static let maximumSelectedFrameDecodeDimension = 4_096
    private static let maximumSelectedFrameEncodedBytes: UInt64 = 512 * 1_024 * 1_024

    struct SelectedFrameContentIdentity: Equatable, Sendable {
        let byteCount: UInt64
        let sha256: String
        let pixelSHA256: String
    }

    static func selectedFrameRequiresTranscode(
        exposureEV: Double,
        sourceExtension: String,
        orientation: Int,
        largestDimension: Int,
        boundedDimension: Int,
        requiresSDRBridge: Bool
    ) -> Bool {
        exposureEV > 0
            || ["heic", "heif"].contains(sourceExtension.lowercased())
            || orientation != 1
            || largestDimension > boundedDimension
            || requiresSDRBridge
    }

    private func copySelectedFrame(
        source: URL,
        destination: URL,
        maxDimension: CGFloat,
        context: inout CIContext?
    ) throws -> SelectedFrameNormalizationResult {
        let exposureEV = (try? FrameScoring.scoreFrame(at: source).lowLightExposureEV) ?? 0
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  sourceRef,
                  CGImageSourceGetPrimaryImageIndex(sourceRef),
                  nil
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to inspect selected image: \(source.lastPathComponent)"
            )
        }
        let largestDimension = max(width, height)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let resolvedMaximumDimension: Int
        if maxDimension.isFinite, maxDimension > 0 {
            resolvedMaximumDimension = maxDimension >= CGFloat(Int.max)
                ? Int.max
                : max(1, Int(maxDimension.rounded(.down)))
        } else {
            resolvedMaximumDimension = largestDimension
        }
        let boundedDimension = min(largestDimension, resolvedMaximumDimension)
        let needsTranscode = Self.selectedFrameRequiresTranscode(
            exposureEV: exposureEV,
            sourceExtension: source.pathExtension,
            orientation: orientation,
            largestDimension: largestDimension,
            boundedDimension: boundedDimension,
            requiresSDRBridge: SDRImageDecoder.bridgeReason(
                source: sourceRef,
                properties: properties
            ) != nil
        )
        guard needsTranscode else {
            try FileManager.default.copyItem(at: source, to: destination)
            return SelectedFrameNormalizationResult(
                lowLightExposureEV: nil,
                evidence: SelectedFrameNormalization(
                    sourcePixelWidth: width,
                    sourcePixelHeight: height,
                    sourceOrientation: orientation,
                    maximumPixelDimension: resolvedMaximumDimension,
                    outputPixelWidth: width,
                    outputPixelHeight: height,
                    outputFormat: destination.pathExtension.lowercased(),
                    transcoded: false
                )
            )
        }

        let outputDimensions = try Self.transcodeSelectedFrame(
            source: source,
            sourceRef: sourceRef,
            properties: properties,
            destination: destination,
            boundedDimension: boundedDimension,
            exposureEV: exposureEV,
            context: &context
        )
        return SelectedFrameNormalizationResult(
            lowLightExposureEV: exposureEV > 0 ? exposureEV : nil,
            evidence: SelectedFrameNormalization(
                sourcePixelWidth: width,
                sourcePixelHeight: height,
                sourceOrientation: orientation,
                maximumPixelDimension: resolvedMaximumDimension,
                outputPixelWidth: outputDimensions.width,
                outputPixelHeight: outputDimensions.height,
                outputFormat: destination.pathExtension.lowercased(),
                transcoded: true
            )
        )
    }

    static func reproduceSelectedFrame(
        source: URL,
        destination: URL,
        normalization: SelectedFrameNormalization,
        exposureEV: Double?
    ) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  sourceRef,
                  CGImageSourceGetPrimaryImageIndex(sourceRef),
                  nil
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width == normalization.sourcePixelWidth,
              height == normalization.sourcePixelHeight,
              ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
                == normalization.sourceOrientation,
              normalization.maximumPixelDimension > 0,
              normalization.outputPixelWidth > 0,
              normalization.outputPixelHeight > 0,
              normalization.outputFormat == destination.pathExtension.lowercased(),
              exposureEV.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw PipelineError.imageTranscodeFailed(
                "Selected-frame normalization evidence does not match its source."
            )
        }
        let boundedDimension = min(
            max(width, height),
            normalization.maximumPixelDimension
        )
        let mustTranscode = Self.selectedFrameRequiresTranscode(
            exposureEV: exposureEV ?? 0,
            sourceExtension: source.pathExtension,
            orientation: normalization.sourceOrientation,
            largestDimension: max(width, height),
            boundedDimension: boundedDimension,
            requiresSDRBridge: SDRImageDecoder.bridgeReason(
                source: sourceRef,
                properties: properties
            ) != nil
        )
        guard mustTranscode == normalization.transcoded else {
            throw PipelineError.imageTranscodeFailed(
                "Selected-frame normalization mode does not match its source."
            )
        }
        if !mustTranscode {
            guard width == normalization.outputPixelWidth,
                  height == normalization.outputPixelHeight else {
                throw PipelineError.imageTranscodeFailed(
                    "Selected-frame output dimensions changed during verification."
                )
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            var context: CIContext?
            let dimensions = try transcodeSelectedFrame(
                source: source,
                sourceRef: sourceRef,
                properties: properties,
                destination: destination,
                boundedDimension: boundedDimension,
                exposureEV: exposureEV ?? 0,
                context: &context
            )
            guard dimensions.width == normalization.outputPixelWidth,
                  dimensions.height == normalization.outputPixelHeight else {
                throw PipelineError.imageTranscodeFailed(
                    "Selected-frame output dimensions changed during verification."
                )
            }
        }
    }

    static func selectedFrameContentIdentity(
        at url: URL,
        maximumBytes: UInt64 = maximumSelectedFrameEncodedBytes,
        maximumPixelDimension: Int = maximumSelectedFrameDecodeDimension
    ) throws -> SelectedFrameContentIdentity {
        try selectedFrameContentIdentity(
            at: url,
            maximumBytes: maximumBytes,
            maximumPixelDimension: maximumPixelDimension,
            afterByteHash: {}
        )
    }

#if DEBUG
    static func test_selectedFrameContentIdentity(
        at url: URL,
        maximumPixelDimension: Int,
        afterByteHash: () throws -> Void
    ) throws -> SelectedFrameContentIdentity {
        try selectedFrameContentIdentity(
            at: url,
            maximumBytes: maximumSelectedFrameEncodedBytes,
            maximumPixelDimension: maximumPixelDimension,
            afterByteHash: afterByteHash
        )
    }
#endif

    static func selectedFramePixelSHA256(
        at url: URL,
        maximumPixelDimension: Int = maximumSelectedFrameDecodeDimension
    ) throws -> String {
        try selectedFrameContentIdentity(
            at: url,
            maximumPixelDimension: maximumPixelDimension
        ).pixelSHA256
    }

    private static func selectedFrameContentIdentity(
        at url: URL,
        maximumBytes: UInt64,
        maximumPixelDimension: Int,
        afterByteHash: () throws -> Void
    ) throws -> SelectedFrameContentIdentity {
        guard maximumBytes > 0,
              maximumPixelDimension > 0,
              maximumPixelDimension <= maximumSelectedFrameDecodeDimension else {
            throw PipelineError.imageTranscodeFailed(
                "Selected image decode limits are invalid: \(url.lastPathComponent)"
            )
        }
        let parentURL = url.deletingLastPathComponent()
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to open selected image directory: \(url.lastPathComponent)"
            )
        }
        defer { Darwin.close(parent) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to open selected image: \(url.lastPathComponent)"
            )
        }
        defer { Darwin.close(descriptor) }

        var initialFile = stat()
        var initialPath = stat()
        var initialParent = stat()
        var initialParentPath = stat()
        let openedPath = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &initialPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &initialFile) == 0,
              openedPath == 0,
              fstat(parent, &initialParent) == 0,
              lstat(parentURL.path, &initialParentPath) == 0,
              selectedFrameFileStatusMatches(initialFile, initialPath),
              selectedFrameFileStatusMatches(initialParent, initialParentPath),
              (initialFile.st_mode & S_IFMT) == S_IFREG,
              initialFile.st_nlink == 1,
              initialFile.st_size > 0,
              UInt64(initialFile.st_size) <= maximumBytes,
              (initialParent.st_mode & S_IFMT) == S_IFDIR else {
            throw PipelineError.imageTranscodeFailed(
                "Selected image is not a stable regular file: \(url.lastPathComponent)"
            )
        }

        var byteHasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < Int64(initialFile.st_size) {
            let requested = min(buffer.count, Int(Int64(initialFile.st_size) - offset))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, requested, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw PipelineError.imageTranscodeFailed(
                    "Selected image changed while hashing: \(url.lastPathComponent)"
                )
            }
            byteHasher.update(data: Data(buffer[0..<count]))
            offset += Int64(count)
        }
        try afterByteHash()

        guard lseek(descriptor, 0, SEEK_SET) == 0,
              let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: "/dev/fd/\(descriptor)") as CFURL,
                nil
              ) else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to inspect selected image pixels: \(url.lastPathComponent)"
            )
        }
        let pixelSHA256 = try selectedFramePixelSHA256(
            source: source,
            label: url.lastPathComponent,
            maximumPixelDimension: maximumPixelDimension
        )

        var finalFile = stat()
        var finalPath = stat()
        var finalParent = stat()
        var finalParentPath = stat()
        let finalPathStatus = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &finalPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &finalFile) == 0,
              finalPathStatus == 0,
              fstat(parent, &finalParent) == 0,
              lstat(parentURL.path, &finalParentPath) == 0,
              selectedFrameFileStatusMatches(initialFile, finalFile),
              selectedFrameFileStatusMatches(initialFile, finalPath),
              selectedFrameFileStatusMatches(initialParent, finalParent),
              selectedFrameFileStatusMatches(initialParent, finalParentPath),
              offset == Int64(initialFile.st_size) else {
            throw PipelineError.imageTranscodeFailed(
                "Selected image changed while reading: \(url.lastPathComponent)"
            )
        }
        return SelectedFrameContentIdentity(
            byteCount: UInt64(initialFile.st_size),
            sha256: byteHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            pixelSHA256: pixelSHA256
        )
    }

    private static func selectedFramePixelSHA256(
        source: CGImageSource,
        label: String,
        maximumPixelDimension: Int
    ) throws -> String {
        let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                primaryIndex,
                nil
              ) as? [CFString: Any],
              let declaredWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let declaredHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              declaredWidth > 0,
              declaredHeight > 0,
              declaredWidth <= maximumPixelDimension,
              declaredHeight <= maximumPixelDimension,
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                primaryIndex,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
              ),
              image.width > 0,
              image.height > 0,
              image.width == declaredWidth,
              image.height == declaredHeight,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to decode selected image pixels: \(label)"
            )
        }
        let (bytesPerRow, rowOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (pixelBytes, imageOverflow) = bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        let maximumPixelBytes = maximumSelectedFrameDecodeDimension
            * maximumSelectedFrameDecodeDimension * 4
        guard !rowOverflow,
              !imageOverflow,
              pixelBytes > 0,
              pixelBytes <= maximumPixelBytes else {
            throw PipelineError.imageTranscodeFailed(
                "Selected image dimensions are too large: \(label)"
            )
        }
        var pixels = [UInt8](repeating: 0, count: pixelBytes)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to normalize selected image pixels: \(label)"
            )
        }
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        var hasher = SHA256()
        var width = UInt64(image.width).bigEndian
        var height = UInt64(image.height).bigEndian
        withUnsafeBytes(of: &width) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: &height) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(pixels))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func selectedFrameFileStatusMatches(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func transcodeSelectedFrame(
        source: URL,
        sourceRef: CGImageSource,
        properties: [CFString: Any],
        destination: URL,
        boundedDimension: Int,
        exposureEV: Double,
        context: inout CIContext?
    ) throws -> (width: Int, height: Int) {
        try Task.checkCancellation()
        guard let image = SDRImageDecoder.createOrientedThumbnail(
            source: sourceRef,
            properties: properties,
            maximumPixelDimension: boundedDimension
        ) else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to decode selected image: \(source.lastPathComponent)"
            )
        }
        try Task.checkCancellation()
        let outputImage: CGImage
        if exposureEV > 0 {
            let input = CIImage(cgImage: image)
            let adjusted = input.applyingFilter(
                "CIExposureAdjust",
                parameters: [kCIInputEVKey: exposureEV]
            )
            let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let renderingContext = context ?? CIContext(options: [
                .cacheIntermediates: false,
                .workingColorSpace: linearColorSpace,
                .outputColorSpace: outputColorSpace,
            ])
            let adjustedImage: CGImage?
            if let rendered = renderingContext.createCGImage(adjusted, from: input.extent) {
                adjustedImage = rendered
            } else {
                adjustedImage = softwareExposureAdjustedImage(image, exposureEV: exposureEV)
            }
            context = renderingContext
            guard let adjustedImage else {
                throw PipelineError.imageTranscodeFailed(
                    "Failed to adjust low-light image: \(source.lastPathComponent)"
                )
            }
            outputImage = adjustedImage
        } else {
            outputImage = image
        }
        let outputType: UTType = destination.pathExtension.lowercased() == "png" ? .png : .jpeg
        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to create selected image: \(destination.lastPathComponent)"
            )
        }
        var options = safeCameraMetadata(from: properties)
        if outputType == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destinationRef, outputImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else {
            throw PipelineError.imageTranscodeFailed(
                "Failed to write selected image: \(destination.lastPathComponent)"
            )
        }
        return (outputImage.width, outputImage.height)
    }

    static func softwareExposureAdjustedImage(
        _ image: CGImage,
        exposureEV: Double
    ) -> CGImage? {
        guard exposureEV.isFinite,
              image.width > 0,
              image.height > 0 else {
            return nil
        }
        let (pixelCount, pixelCountOverflow) = image.width.multipliedReportingOverflow(
            by: image.height
        )
        let (byteCount, byteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelCountOverflow,
              !byteCountOverflow,
              byteCount > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let multiplier = exp2(exposureEV)
        guard multiplier.isFinite, multiplier > 0 else { return nil }
        // CGContext supplies premultiplied sRGB bytes. Apply exposure to the
        // unpremultiplied linear-light value, then encode and premultiply again.
        var channelLookup = [UInt8](repeating: 0, count: 256 * 256)
        for alphaByte in 1...255 {
            let alpha = Double(alphaByte) / 255
            for channelByte in 0...255 {
                let encoded = min(1, Double(channelByte) / 255 / alpha)
                let linear = encoded <= 0.04045
                    ? encoded / 12.92
                    : pow((encoded + 0.055) / 1.055, 2.4)
                let adjustedLinear = min(1, linear * multiplier)
                let adjustedEncoded = adjustedLinear <= 0.0031308
                    ? adjustedLinear * 12.92
                    : 1.055 * pow(adjustedLinear, 1 / 2.4) - 0.055
                let premultiplied = min(255, max(0, adjustedEncoded * alpha * 255))
                channelLookup[alphaByte * 256 + channelByte] = UInt8(premultiplied.rounded())
            }
        }
        var pixels = [UInt8](repeating: 0, count: byteCount)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return nil
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixelBytes = bytes.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: byteCount, by: 4) {
                let alpha = Int(pixelBytes[offset + 3])
                for channel in 0..<3 {
                    pixelBytes[offset + channel] = channelLookup[
                        alpha * 256 + Int(pixelBytes[offset + channel])
                    ]
                }
            }
            return context.makeImage()
        }
    }

    private static func safeCameraMetadata(from properties: [CFString: Any]) -> [CFString: Any] {
        var output: [CFString: Any] = [kCGImagePropertyOrientation: 1]

        if let sourceTIFF = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var tiff: [CFString: Any] = [:]
            for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] {
                if let value = boundedMetadataString(sourceTIFF[key]) {
                    tiff[key] = value
                }
            }
            if !tiff.isEmpty {
                output[kCGImagePropertyTIFFDictionary] = tiff
            }
        }

        if let sourceExif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var exif: [CFString: Any] = [:]
            for key in [kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm] {
                if let value = sourceExif[key] as? NSNumber,
                   value.doubleValue.isFinite,
                   value.doubleValue > 0,
                   value.doubleValue <= 10_000 {
                    exif[key] = value
                }
            }
            if let lensModel = boundedMetadataString(sourceExif[kCGImagePropertyExifLensModel]) {
                exif[kCGImagePropertyExifLensModel] = lensModel
            }
            if !exif.isEmpty {
                output[kCGImagePropertyExifDictionary] = exif
            }
        }

        return output
    }

    private static func boundedMetadataString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256, !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    func saveSelectedFrameManifest(_ manifest: [SelectedFrameMapping], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    func loadSelectedFrameManifest(from url: URL) throws -> [SelectedFrameMapping] {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: Self.maximumSelectedFrameManifestBytes
        )
        return try loadSelectedFrameManifest(data: data)
    }

    func loadSelectedFrameManifest(data: Data) throws -> [SelectedFrameMapping] {
        guard !data.isEmpty,
              data.count <= Self.maximumSelectedFrameManifestBytes else {
            throw PipelineError.invalidInput
        }
        let manifest = try JSONDecoder().decode([SelectedFrameMapping].self, from: data)
        guard manifest.allSatisfy({
            $0.schemaVersion == SelectedFrameMapping.currentSchemaVersion
                && $0.hasValidPhotoRetainedRankLineage
        }) else {
            throw PipelineError.invalidInput
        }
        return manifest
    }

    func importedVideoURLs(for videoFiles: [String], paths: ProjectPaths) throws -> [URL] {
        try videoFiles.map { try paths.resolveProjectRelativePath($0) }
    }

    func importInputs(
        metadata: ProjectMetadata,
        paths: ProjectPaths,
        progress: (Double, String) -> Void
    ) throws {
        var tasks: [(label: String, action: () throws -> Void)] = []

        let importedVideos = try importedVideoURLs(for: metadata.input.videoFiles, paths: paths)
        for (file, dest) in zip(metadata.input.videoFiles, importedVideos) {
            let source = try paths.resolveProjectRelativePath(file)
            tasks.append((label: dest.lastPathComponent, action: {
                if try self.importedVideoNeedsCopy(dest) {
                    try self.copyFileAtomically(from: source, to: dest)
                }
            }))
        }

        if metadata.input.photosFolder != nil {
            // Photo admission already decoded, selected, and atomically adopted the
            // controlled files. Import must never reopen the external source folder.
            try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
        }

        guard !tasks.isEmpty else { return }
        let total = tasks.count
        for (index, task) in tasks.enumerated() {
            try Task.checkCancellation()
            let message = "Copying input \(index + 1)/\(total): \(task.label)"
            let startFraction = Double(index) / Double(total)
            progress(startFraction, message)
            try task.action()
            let endFraction = Double(index + 1) / Double(total)
            progress(endFraction, message)
        }
    }

    func copySelected(_ frames: [URL], to directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var output: [URL] = []
        for (index, url) in frames.enumerated() {
            try Task.checkCancellation()
            let destExt = selectedFrameOutputExtension(for: url)
            let dest = directory.appendingPathComponent(String(format: "frame_%06d.%@", index, destExt))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            if isHeicImage(url) {
                try transcodeHeicToJpeg(source: url, destination: dest)
            } else {
                try fm.copyItem(at: url, to: dest)
            }
            output.append(dest)
        }
        return output
    }

    func importedVideoNeedsCopy(_ destination: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return true }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size <= 0
    }

    private func importedPhotoEntries(for photos: [URL]) -> [(source: URL, fileName: String)] {
        var usedNames = Set<String>()
        return photos.map { photo in
            let filename = uniqueImportedPhotoName(for: photo, usedNames: &usedNames)
            return (photo, filename)
        }
    }

    private func uniqueImportedPhotoName(for source: URL, usedNames: inout Set<String>) -> String {
        let filename = source.lastPathComponent
        if usedNames.insert(filename.lowercased()).inserted {
            return filename
        }

        let nsName = filename as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var suffix = 2
        while true {
            let candidate = ext.isEmpty
                ? "\(stem)-\(suffix)"
                : "\(stem)-\(suffix).\(ext)"
            if usedNames.insert(candidate.lowercased()).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    func importedPhotoFolderNeedsCopy(
        entries: [(source: URL, fileName: String)],
        destination: URL
    ) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return true }
        try Task.checkCancellation()
        let contents = try fm.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        guard contents.count == entries.count else { return true }
        let expectedNames = Set(entries.map(\.fileName))
        guard Set(contents.map(\.lastPathComponent)) == expectedNames else { return true }
        for file in contents {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile != true || (values.fileSize ?? 0) <= 0 {
                return true
            }
        }
        return false
    }

    func copyFileAtomically(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer {
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: temp)
            }
        }

        try copyFileContents(from: source, to: temp)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }

    private func copyValidPhotosAtomically(
        _ entries: [(source: URL, fileName: String)],
        to destination: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: true)
        defer {
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: temp)
            }
        }

        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        for entry in entries {
            try Task.checkCancellation()
            try copyFileContents(
                from: entry.source,
                to: temp.appendingPathComponent(entry.fileName)
            )
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }

    @discardableResult
    func copyFileContents(
        from source: URL,
        to destination: URL
    ) throws -> LocalFileCopyStrategy {
        try Task.checkCancellation()
        let fm = FileManager.default
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw posixFileError(path: source.path) }
        defer { Darwin.close(input) }
        var initial = stat()
        guard fstat(input, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_size >= 0 else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: source.path])
        }

        if try !isFilesystemCompressed(
            descriptor: input,
            metadata: initial,
            path: source.path
        ) {
            if try cloneFileContents(
                input: input,
                source: source,
                initial: initial,
                destination: destination
            ) {
                return .copyOnWriteClone
            }
        }

        let output = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard output >= 0 else { throw posixFileError(path: destination.path) }
        defer { Darwin.close(output) }
        do {
            var consumed: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(input, bytes.baseAddress, bytes.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw posixFileError(path: source.path) }
                if count == 0 { break }
                consumed += Int64(count)
                var written = 0
                while written < count {
                    try Task.checkCancellation()
                    let result = buffer.withUnsafeBytes { bytes in
                        Darwin.write(output, bytes.baseAddress?.advanced(by: written), count - written)
                    }
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { throw posixFileError(path: destination.path) }
                    written += result
                }
            }
            try Task.checkCancellation()
            guard Darwin.fsync(output) == 0 else { throw posixFileError(path: destination.path) }
            var final = stat()
            var copied = stat()
            guard fstat(input, &final) == 0,
                  fstat(output, &copied) == 0,
                  final.st_dev == initial.st_dev,
                  final.st_ino == initial.st_ino,
                  final.st_size == initial.st_size,
                  final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
                  final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
                  consumed == initial.st_size,
                  (copied.st_mode & S_IFMT) == S_IFREG,
                  copied.st_nlink == 1,
                  copied.st_size == initial.st_size,
                  copied.st_mode & mode_t(0o7777) == mode_t(S_IRUSR | S_IWUSR),
                  copied.st_flags & UInt32(UF_COMPRESSED) == 0 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path])
            }
            return .streamed
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private func cloneFileContents(
        input: Int32,
        source: URL,
        initial: stat,
        destination: URL
    ) throws -> Bool {
        let fm = FileManager.default
        let destinationParent = destination.deletingLastPathComponent()
        let parent = Darwin.open(
            destinationParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { throw posixFileError(path: destinationParent.path) }
        defer { Darwin.close(parent) }

        let result = destination.lastPathComponent.withCString {
            fclonefileat(input, parent, $0, UInt32(CLONE_NOOWNERCOPY))
        }
        if result != 0 {
            let cloneError = errno
            if fm.fileExists(atPath: destination.path)
                || ((try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil) {
                try? fm.removeItem(at: destination)
            }
            guard Self.shouldFallBackFromCloneError(cloneError) else {
                errno = cloneError
                throw posixFileError(path: destination.path)
            }
            return false
        }

        do {
            try Task.checkCancellation()
            let cloned = Darwin.open(
                destination.path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard cloned >= 0 else { throw posixFileError(path: destination.path) }
            defer { Darwin.close(cloned) }
            var cloneMetadata = stat()
            guard fstat(cloned, &cloneMetadata) == 0,
                  (cloneMetadata.st_mode & S_IFMT) == S_IFREG,
                  cloneMetadata.st_nlink == 1,
                  cloneMetadata.st_size == initial.st_size,
                  cloneMetadata.st_ino != initial.st_ino else {
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [NSFilePathErrorKey: destination.path]
                )
            }
            if try isFilesystemCompressed(
                descriptor: cloned,
                metadata: cloneMetadata,
                path: destination.path
            ) {
                try fm.removeItem(at: destination)
                return false
            }
            guard fchflags(cloned, 0) == 0,
                  fchmod(cloned, S_IRUSR | S_IWUSR) == 0 else {
                throw posixFileError(path: destination.path)
            }
            try removeExtendedAttributes(from: cloned, path: destination.path)
            guard Darwin.fsync(cloned) == 0 else {
                throw posixFileError(path: destination.path)
            }
            var sanitized = stat()
            guard fstat(cloned, &sanitized) == 0,
                  (sanitized.st_mode & S_IFMT) == S_IFREG,
                  sanitized.st_nlink == 1,
                  sanitized.st_size == initial.st_size,
                  sanitized.st_ino == cloneMetadata.st_ino,
                  sanitized.st_mode & mode_t(0o7777) == mode_t(S_IRUSR | S_IWUSR),
                  sanitized.st_flags & UInt32(UF_COMPRESSED) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [NSFilePathErrorKey: destination.path]
                )
            }
            try validateUnchangedSource(input: input, source: source, initial: initial)
            return true
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private func isFilesystemCompressed(
        descriptor: Int32,
        metadata: stat,
        path: String
    ) throws -> Bool {
        if metadata.st_flags & UInt32(UF_COMPRESSED) != 0 {
            return true
        }
        let result = "com.apple.decmpfs".withCString { name in
            fgetxattr(descriptor, name, nil, 0, 0, 0)
        }
        if result >= 0 {
            return true
        }
        guard errno == ENOATTR else {
            throw posixFileError(path: path)
        }
        return false
    }

    private func removeExtendedAttributes(from descriptor: Int32, path: String) throws {
        let length = flistxattr(descriptor, nil, 0, 0)
        guard length >= 0 else { throw posixFileError(path: path) }
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        let count = names.withUnsafeMutableBufferPointer {
            flistxattr(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard count >= 0, count <= names.count else {
            throw posixFileError(path: path)
        }
        var removalError: Int32?
        names.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let name = base.advanced(by: offset)
                let nameLength = strlen(name)
                guard nameLength > 0, offset + nameLength < count else {
                    removalError = EINVAL
                    return
                }
                if fremovexattr(descriptor, name, 0) != 0, errno != ENOATTR {
                    removalError = errno
                    return
                }
                offset += nameLength + 1
            }
        }
        if let removalError {
            errno = removalError
            throw posixFileError(path: path)
        }
    }

    private func validateUnchangedSource(
        input: Int32,
        source: URL,
        initial: stat
    ) throws {
        var final = stat()
        guard fstat(input, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec else {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [NSFilePathErrorKey: source.path]
            )
        }
    }

    private func posixFileError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    func rawFramesDirectory(index: Int, paths: ProjectPaths) -> URL {
        paths.framesRawURL.appendingPathComponent(String(format: "video_%03d", index), isDirectory: true)
    }

    func loadImages(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
            .filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func loadPhotos(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try PhotoInputPreflight.discoveredPhotos(in: directory)
    }

    func applyFrameBudget(
        to groups: [SelectedFrameGroup],
        targetCount: Int,
        photoSelection: PhotoSelection = .automatic
    ) throws -> [SelectedFrameGroup] {
        let targets = try resolveGroupTargetCounts(
            capacities: groups.map { $0.frames.count },
            isVideo: groups.map(\.isVideo),
            targetCount: targetCount,
            photoSelection: photoSelection
        )
        return try zip(groups, targets).compactMap { group, count in
            guard count > 0 else { return nil }
            let frames: [URL]
            switch group.budgetProjection {
            case .evenlySpaced:
                frames = evenlySpacedFrames(group.frames, targetCount: count)
            case .rankedPrefix:
                frames = Array(group.frames.prefix(count))
            case .preserve:
                guard count == group.frames.count else {
                    throw PipelineError.photoSelectionExceedsBudget(
                        selected: group.frames.count,
                        maximum: count
                    )
                }
                frames = group.frames
            }
            return SelectedFrameGroup(
                id: group.id,
                frames: frames,
                isVideo: group.isVideo,
                budgetProjection: group.budgetProjection,
                videoSource: group.videoSource,
                videoOriginsByFileName: group.videoOriginsByFileName,
                sourceBindingsByFileName: group.sourceBindingsByFileName
            )
        }
    }

    func resolveGlobalFrameTargets(
        videos: [VideoFrameAllocationInput],
        validPhotoCount: Int,
        targetCount: Int,
        photoSelection: PhotoSelection
    ) throws -> GlobalFrameTargets {
        guard validPhotoCount >= 0 else { throw PipelineError.invalidInput }
        let virtualVideoCapacities = try allocateRequiredVideoFrameTargets(
            videos,
            totalTargetCount: targetCount
        )
        var capacities = virtualVideoCapacities
        var videoFlags = [Bool](repeating: true, count: videos.count)
        if validPhotoCount > 0 {
            capacities.append(validPhotoCount)
            videoFlags.append(false)
        }
        let targets = try resolveGroupTargetCounts(
            capacities: capacities,
            isVideo: videoFlags,
            targetCount: targetCount,
            photoSelection: photoSelection
        )
        return GlobalFrameTargets(
            videoTargets: Array(targets.prefix(videos.count)),
            photoTarget: validPhotoCount > 0 ? targets.last ?? 0 : 0
        )
    }

    private func resolveGroupTargetCounts(
        capacities: [Int],
        isVideo: [Bool],
        targetCount: Int,
        photoSelection: PhotoSelection
    ) throws -> [Int] {
        guard capacities.count == isVideo.count,
              capacities.allSatisfy({ $0 >= 0 }) else {
            throw PipelineError.invalidInput
        }
        guard photoSelection == .useAllValidPhotos else {
            return try resolveNormalGroupTargetCounts(
                capacities: capacities,
                isVideo: isVideo,
                targetCount: targetCount
            )
        }

        let videoIndices = capacities.indices.filter { isVideo[$0] }
        let photoCount = capacities.indices
            .filter { !isVideo[$0] }
            .reduce(0) { $0 + capacities[$1] }
        let availableVideoCount = videoIndices.reduce(0) { $0 + capacities[$1] }
        let reservedVideoCount = min(
            availableVideoCount,
            RunPlanResolver.minimumReservedVideoFrameCount(
                keyframeBudget: targetCount,
                videoCount: videoIndices.count
            )
        )
        let maximumPhotoCount = max(0, targetCount - reservedVideoCount)
        guard photoCount <= maximumPhotoCount else {
            throw PipelineError.photoSelectionExceedsBudget(
                selected: photoCount,
                maximum: maximumPhotoCount
            )
        }
        let videoTargets = try resolveNormalGroupTargetCounts(
            capacities: videoIndices.map { capacities[$0] },
            isVideo: [Bool](repeating: true, count: videoIndices.count),
            targetCount: max(0, targetCount - photoCount)
        )
        var result = capacities.indices.map { isVideo[$0] ? 0 : capacities[$0] }
        for (offset, index) in videoIndices.enumerated() {
            result[index] = videoTargets[offset]
        }
        return result
    }

    private func resolveNormalGroupTargetCounts(
        capacities: [Int],
        isVideo: [Bool],
        targetCount: Int
    ) throws -> [Int] {
        guard targetCount > 0 else {
            return [Int](repeating: 0, count: capacities.count)
        }
        let total = capacities.reduce(0, +)
        guard total > targetCount else { return capacities }

        var targets = capacities.indices.map { index in
            isVideo[index] ? min(2, capacities[index]) : 0
        }
        let requiredVideoCoverage = targets.reduce(0, +)
        guard requiredVideoCoverage <= targetCount else {
            throw PipelineError.videoFrameBudgetTooSmall(
                required: requiredVideoCoverage,
                available: targetCount
            )
        }
        let residualCapacities = zip(capacities, targets).map { capacity, target in
            capacity - target
        }
        let extras = allocateProportionally(
            weights: residualCapacities.map(Double.init),
            capacities: residualCapacities,
            totalCount: targetCount - requiredVideoCoverage
        )
        for index in targets.indices {
            targets[index] += extras[index]
        }
        return targets
    }

    func evenlySpacedFrames(_ frames: [URL], targetCount: Int) -> [URL] {
        evenlySpacedItems(frames, targetCount: targetCount)
    }

    private func evenlySpacedItems<Element>(
        _ items: [Element],
        targetCount: Int
    ) -> [Element] {
        guard targetCount > 0, !items.isEmpty else { return [] }
        guard items.count > targetCount else { return items }
        guard targetCount > 1 else { return [items[items.count / 2]] }
        let step = Double(items.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            items[Int((Double(index) * step).rounded())]
        }
    }

    func allocateVideoFrameTargets(
        _ inputs: [VideoFrameAllocationInput],
        totalTargetCount: Int
    ) throws -> [Int] {
        guard totalTargetCount > 0 else {
            return [Int](repeating: 0, count: inputs.count)
        }
        for (index, input) in inputs.enumerated() {
            guard input.availableCandidateCount >= 0,
                  input.availableCandidateCount == 0
                    || (input.durationSeconds.isFinite && input.durationSeconds > 0) else {
                throw VideoFrameAllocationError.invalidInput(index: index)
            }
        }

        let capacities = inputs.map(\.availableCandidateCount)
        let effectiveBudget = min(totalTargetCount, capacities.reduce(0, +))
        var allocations = capacities.map { min(2, $0) }
        let requiredCoverage = allocations.reduce(0, +)
        guard effectiveBudget >= requiredCoverage else {
            throw VideoFrameAllocationError.insufficientBudgetForClipCoverage(
                required: requiredCoverage,
                available: effectiveBudget
            )
        }

        let residualCapacities = zip(capacities, allocations).map { $0 - $1 }
        let extras = allocateProportionally(
            weights: inputs.map(\.durationSeconds),
            capacities: residualCapacities,
            totalCount: effectiveBudget - requiredCoverage
        )
        for index in allocations.indices {
            allocations[index] += extras[index]
        }
        return allocations
    }

    func allocateRequiredVideoFrameTargets(
        _ inputs: [VideoFrameAllocationInput],
        totalTargetCount: Int
    ) throws -> [Int] {
        do {
            return try allocateVideoFrameTargets(
                inputs,
                totalTargetCount: totalTargetCount
            )
        } catch let error as VideoFrameAllocationError {
            switch error {
            case .invalidInput:
                throw PipelineError.invalidInput
            case let .insufficientBudgetForClipCoverage(required, available):
                throw PipelineError.videoFrameBudgetTooSmall(
                    required: required,
                    available: available
                )
            }
        }
    }

    private func allocateProportionally(
        weights: [Double],
        capacities: [Int],
        totalCount: Int
    ) -> [Int] {
        precondition(weights.count == capacities.count)
        let effectiveTotal = min(max(0, totalCount), capacities.reduce(0, +))
        var allocations = [Int](repeating: 0, count: capacities.count)
        var remaining = effectiveTotal
        var active = capacities.indices.filter {
            capacities[$0] > 0 && weights[$0].isFinite && weights[$0] > 0
        }

        while remaining > 0, !active.isEmpty {
            let totalWeight = active.reduce(0.0) { $0 + weights[$1] }
            let ideals = Dictionary(uniqueKeysWithValues: active.map { index in
                (index, Double(remaining) * weights[index] / totalWeight)
            })
            let saturated = active.filter { index in
                Double(capacities[index] - allocations[index]) <= (ideals[index] ?? 0)
            }
            if !saturated.isEmpty {
                for index in saturated.sorted() {
                    let available = capacities[index] - allocations[index]
                    allocations[index] += available
                    remaining -= available
                }
                let saturatedSet = Set(saturated)
                active.removeAll { saturatedSet.contains($0) }
                continue
            }

            var remainders: [(index: Int, fraction: Double)] = []
            for index in active {
                let ideal = ideals[index] ?? 0
                let whole = min(
                    capacities[index] - allocations[index],
                    Int(floor(ideal))
                )
                allocations[index] += whole
                remaining -= whole
                remainders.append((index, ideal - floor(ideal)))
            }
            remainders.sort {
                $0.fraction == $1.fraction
                    ? $0.index < $1.index
                    : $0.fraction > $1.fraction
            }
            for remainder in remainders where remaining > 0 {
                guard allocations[remainder.index] < capacities[remainder.index] else {
                    continue
                }
                allocations[remainder.index] += 1
                remaining -= 1
            }
        }
        return allocations
    }

    func persistCheckpoint(
        paths: ProjectPaths,
        stage: PipelineStage,
        progress: Double? = nil,
        message: String? = nil,
        details: PipelineCheckpointDetails? = nil
    ) {
        guard var metadata = try? ProjectMetadataStore.load(from: paths.metadataURL) else { return }
        metadata.checkpoint = PipelineCheckpoint(
            stage: stage,
            updatedAt: Date(),
            progressFraction: progress,
            message: message,
            inputReceiptDigest: try? RuntimeInputSnapshotLease.receiptDigest(
                metadata: metadata,
                pairingPolicy: metadata.resolvedRunPlan?.pairingPolicy
            ),
            details: details
        )
        // Use the notes-preserving save so a checkpoint written mid-run cannot clobber a note
        // the user edited since this metadata was loaded, matching every other in-run write.
        try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
    }

    struct FrameExtractionProfile {
        let targetCount: Int
        let maxDimension: CGFloat
        let targetFPS: Int
        let minDistanceRatio: Double
        let outputFormat: FrameOutputFormat
    }

    func frameExtractionProfile(for plan: ResolvedRunPlan, detail: DetailProfile) -> FrameExtractionProfile {
        let minDistanceRatio: Double = switch plan.capturePath {
        case .orbit: 0.12
        case .automatic, .walkthrough: 0.20
        case .largeArea: 0.30
        }
        return FrameExtractionProfile(
            targetCount: plan.keyframeBudget,
            maxDimension: CGFloat(plan.maximumImageDimension),
            targetFPS: plan.analysisFrameRate,
            minDistanceRatio: minDistanceRatio,
            outputFormat: detail == .highDetail ? .png : .jpeg
        )
    }

    func cameraModel(
        detailProfile: DetailProfile,
        capturePath: CapturePath,
        lensProjection: LensProjection = .automatic
    ) -> String {
        ResolvedCameraModelPolicy.model(
            detailProfile: detailProfile,
            capturePath: capturePath,
            lensProjection: lensProjection
        )
    }

    func shouldUseSequential(
        selectedFrames: [URL],
        input: InputSpec,
        forceExhaustive: Bool,
        pairingPolicy: ResolvedPairingPolicy? = nil
    ) -> Bool {
        if forceExhaustive { return false }
        if let pairingPolicy {
            guard pairingPolicy != .unorderedRetrieval else { return false }
            return selectedFrames.count >= 30
        }
        guard input.hasVideos, !input.hasPhotos else { return false }
        guard input.videoFiles.count == 1 else { return false }
        if selectedFrames.count < 30 { return false }
        return true
    }
}
