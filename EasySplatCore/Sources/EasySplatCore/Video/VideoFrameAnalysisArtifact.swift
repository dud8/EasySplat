import CoreMedia
import CryptoKit
import Foundation

public struct VideoFrameAnalysisPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentAnalyzerVersion = 1
    public static let productionMaximumLongEdge = 384

    public let schemaVersion: Int
    public let analyzerVersion: Int
    public let maximumLongEdge: Int
    public let targetFrameCeiling: Int
    public let targetFPS: Int
    public let maximumConcurrentDecoders: Int

    public init(
        schemaVersion: Int = VideoFrameAnalysisPolicy.currentSchemaVersion,
        analyzerVersion: Int = VideoFrameAnalysisPolicy.currentAnalyzerVersion,
        maximumLongEdge: Int = VideoFrameAnalysisPolicy.productionMaximumLongEdge,
        targetFrameCeiling: Int,
        targetFPS: Int,
        maximumConcurrentDecoders: Int = 2
    ) {
        self.schemaVersion = schemaVersion
        self.analyzerVersion = analyzerVersion
        self.maximumLongEdge = maximumLongEdge
        self.targetFrameCeiling = targetFrameCeiling
        self.targetFPS = targetFPS
        self.maximumConcurrentDecoders = maximumConcurrentDecoders
    }

    public init(resolvedRunPlan: ResolvedRunPlan) {
        self.init(
            targetFrameCeiling: resolvedRunPlan.keyframeBudget,
            targetFPS: resolvedRunPlan.analysisFrameRate,
            maximumConcurrentDecoders: min(
                2,
                resolvedRunPlan.geometryWorkerBudget
                    .maximumConcurrentVideoSourceAnalysisTasks
            )
        )
    }

    public var sha256: String {
        let binding = [
            "video-frame-analysis-policy",
            String(schemaVersion),
            String(analyzerVersion),
            String(maximumLongEdge),
            String(targetFrameCeiling),
            String(targetFPS),
            String(maximumConcurrentDecoders),
        ].joined(separator: "\t")
        return SHA256.hash(data: Data(binding.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && analyzerVersion == Self.currentAnalyzerVersion
            && maximumLongEdge == Self.productionMaximumLongEdge
            && (1...100_000).contains(targetFrameCeiling)
            && (1...240).contains(targetFPS)
            && (1...2).contains(maximumConcurrentDecoders)
    }

    var extractionOptions: FrameExtractionOptions {
        FrameExtractionOptions(
            targetCount: targetFrameCeiling,
            maxDimension: CGFloat(maximumLongEdge),
            targetFPS: targetFPS,
            minDistanceRatio: 0,
            outputFormat: .jpeg
        )
    }
}

struct VideoFrameAnalysisCandidate: Codable, Equatable, Sendable {
    let frameIndex: Int
    let timestampSeconds: Double
    let presentationTimeValue: Int64?
    let presentationTimeTimescale: Int32?
    let sharpness: Double
    let brightness: Double
    let clippedFraction: Double
    let motionScore: Double
    let dHash: UInt64?

    init(
        frameIndex: Int,
        timestampSeconds: Double,
        presentationTimeValue: Int64?,
        presentationTimeTimescale: Int32?,
        sharpness: Double,
        brightness: Double,
        clippedFraction: Double,
        motionScore: Double,
        dHash: UInt64?
    ) {
        self.frameIndex = frameIndex
        self.timestampSeconds = timestampSeconds
        self.presentationTimeValue = presentationTimeValue
        self.presentationTimeTimescale = presentationTimeTimescale
        self.sharpness = sharpness
        self.brightness = brightness
        self.clippedFraction = clippedFraction
        self.motionScore = motionScore
        self.dHash = dHash
    }

    init(_ candidate: TimedFrameCandidate) {
        frameIndex = candidate.frameIndex
        timestampSeconds = candidate.timestampSeconds
        presentationTimeValue = candidate.presentationTime?.value
        presentationTimeTimescale = candidate.presentationTime?.timescale
        sharpness = candidate.candidate.sharpness
        brightness = candidate.candidate.brightness
        clippedFraction = candidate.candidate.clippedFraction
        motionScore = candidate.candidate.motionScore
        dHash = candidate.candidate.dHash
    }

    var timedCandidate: TimedFrameCandidate {
        TimedFrameCandidate(
            frameIndex: frameIndex,
            timestampSeconds: timestampSeconds,
            candidate: SmartFrameCandidate(
                index: frameIndex,
                sharpness: sharpness,
                brightness: brightness,
                clippedFraction: clippedFraction,
                motionScore: motionScore,
                dHash: dHash
            ),
            presentationTime: presentationTime
        )
    }

    private var presentationTime: CMTime? {
        guard let presentationTimeValue,
              let presentationTimeTimescale,
              presentationTimeTimescale > 0 else {
            return nil
        }
        return CMTime(value: presentationTimeValue, timescale: presentationTimeTimescale)
    }

    var isValid: Bool {
        guard frameIndex >= 0,
              timestampSeconds.isFinite,
              timestampSeconds >= 0,
              sharpness.isFinite,
              sharpness >= 0,
              brightness.isFinite,
              (0...1).contains(brightness),
              clippedFraction.isFinite,
              (0...1).contains(clippedFraction),
              motionScore.isFinite,
              (0...1).contains(motionScore) else {
            return false
        }
        let hasValue = presentationTimeValue != nil
        let hasTimescale = presentationTimeTimescale != nil
        guard hasValue == hasTimescale else { return false }
        guard let presentationTime else { return true }
        return presentationTime.isValid
            && presentationTime.isNumeric
            && presentationTime.epoch == 0
            && abs(CMTimeGetSeconds(presentationTime) - timestampSeconds) <= 1e-6
    }
}

struct VideoFrameAnalysisArtifact: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sourceIndex: Int
    let sourceProjectRelativePath: String
    let sourceByteCount: Int64
    let sourceSHA256: String
    let clipGroupID: String
    let policy: VideoFrameAnalysisPolicy
    let trackID: Int32
    let pixelWidth: Int
    let pixelHeight: Int
    let durationSeconds: Double
    let nominalFrameRate: Double
    let isHDR: Bool
    let decodedFrameCount: Int
    let hadRepairedTimestamps: Bool
    let transformA: Double
    let transformB: Double
    let transformC: Double
    let transformD: Double
    let transformTX: Double
    let transformTY: Double
    let candidates: [VideoFrameAnalysisCandidate]

    init(
        schemaVersion: Int = VideoFrameAnalysisArtifact.currentSchemaVersion,
        sourceIndex: Int,
        sourceProjectRelativePath: String,
        sourceByteCount: Int64,
        sourceSHA256: String,
        clipGroupID: String,
        policy: VideoFrameAnalysisPolicy,
        trackID: Int32,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        nominalFrameRate: Double,
        isHDR: Bool,
        decodedFrameCount: Int,
        hadRepairedTimestamps: Bool,
        transformA: Double,
        transformB: Double,
        transformC: Double,
        transformD: Double,
        transformTX: Double,
        transformTY: Double,
        candidates: [VideoFrameAnalysisCandidate]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceIndex = sourceIndex
        self.sourceProjectRelativePath = sourceProjectRelativePath
        self.sourceByteCount = sourceByteCount
        self.sourceSHA256 = sourceSHA256
        self.clipGroupID = clipGroupID
        self.policy = policy
        self.trackID = trackID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.nominalFrameRate = nominalFrameRate
        self.isHDR = isHDR
        self.decodedFrameCount = decodedFrameCount
        self.hadRepairedTimestamps = hadRepairedTimestamps
        self.transformA = transformA
        self.transformB = transformB
        self.transformC = transformC
        self.transformD = transformD
        self.transformTX = transformTX
        self.transformTY = transformTY
        self.candidates = candidates
    }

    init(
        video: PreparedVideoInput.Video,
        sourceProjectRelativePath: String
    ) {
        let analysis = video.analysisEvidence
        self.init(
            sourceIndex: video.index,
            sourceProjectRelativePath: sourceProjectRelativePath,
            sourceByteCount: video.byteCount,
            sourceSHA256: video.sha256,
            clipGroupID: video.clipGroupID,
            policy: video.analysisPolicy,
            trackID: analysis.trackID,
            pixelWidth: analysis.pixelWidth,
            pixelHeight: analysis.pixelHeight,
            durationSeconds: analysis.durationSeconds,
            nominalFrameRate: analysis.nominalFrameRate,
            isHDR: analysis.isHDR,
            decodedFrameCount: analysis.decodedFrameCount,
            hadRepairedTimestamps: analysis.hadRepairedTimestamps,
            transformA: analysis.preferredTransform.a,
            transformB: analysis.preferredTransform.b,
            transformC: analysis.preferredTransform.c,
            transformD: analysis.preferredTransform.d,
            transformTX: analysis.preferredTransform.tx,
            transformTY: analysis.preferredTransform.ty,
            candidates: analysis.candidates.map(VideoFrameAnalysisCandidate.init)
        )
    }

    init(
        receipt: VideoInputReceipt,
        sourceIndex: Int,
        clipGroupID: String,
        policy: VideoFrameAnalysisPolicy,
        analysis: FrameExtractionAnalysis
    ) {
        self.init(
            sourceIndex: sourceIndex,
            sourceProjectRelativePath: receipt.projectRelativePath,
            sourceByteCount: receipt.byteCount,
            sourceSHA256: receipt.sha256,
            clipGroupID: clipGroupID,
            policy: policy,
            trackID: analysis.primaryTrack.trackID,
            pixelWidth: analysis.primaryTrack.width,
            pixelHeight: analysis.primaryTrack.height,
            durationSeconds: analysis.durationSeconds,
            nominalFrameRate: analysis.primaryTrack.nominalFrameRate,
            isHDR: analysis.primaryTrack.isHDR,
            decodedFrameCount: analysis.decodedFrameCount,
            hadRepairedTimestamps: analysis.hadRepairedTimestamps,
            transformA: analysis.preferredTransform.a,
            transformB: analysis.preferredTransform.b,
            transformC: analysis.preferredTransform.c,
            transformD: analysis.preferredTransform.d,
            transformTX: analysis.preferredTransform.tx,
            transformTY: analysis.preferredTransform.ty,
            candidates: analysis.candidates.map(VideoFrameAnalysisCandidate.init)
        )
    }

    func frameExtractionAnalysis(
        source: FrameExtractionSource
    ) throws -> FrameExtractionAnalysis {
        guard source.primaryTrack.trackID == trackID,
              source.primaryTrack.width == pixelWidth,
              source.primaryTrack.height == pixelHeight,
              approximatelyEqual(source.durationSeconds, durationSeconds),
              approximatelyEqual(source.primaryTrack.nominalFrameRate, nominalFrameRate),
              source.primaryTrack.isHDR == isHDR,
              approximatelyEqual(source.preferredTransform.a, transformA),
              approximatelyEqual(source.preferredTransform.b, transformB),
              approximatelyEqual(source.preferredTransform.c, transformC),
              approximatelyEqual(source.preferredTransform.d, transformD),
              approximatelyEqual(source.preferredTransform.tx, transformTX),
              approximatelyEqual(source.preferredTransform.ty, transformTY) else {
            throw VideoFrameAnalysisArtifactStoreError.sourceTrackMismatch
        }
        return FrameExtractionAnalysis(
            videoURL: source.videoURL,
            primaryTrack: source.primaryTrack,
            durationSeconds: durationSeconds,
            preferredTransform: source.preferredTransform,
            candidates: candidates.map(\.timedCandidate),
            decodedFrameCount: decodedFrameCount,
            hadRepairedTimestamps: hadRepairedTimestamps
        )
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = max(1, abs(lhs), abs(rhs))
        return abs(lhs - rhs) <= scale * 1e-9
    }
}

struct VideoFrameAnalysisArtifactFileEvidence: Equatable, Sendable {
    let byteCount: Int64
    let sha256: String
}

enum VideoFrameAnalysisArtifactStoreError: Error, LocalizedError, Equatable {
    case unsafePath
    case invalidArtifact
    case unsupportedSchema(Int)
    case artifactDigestMismatch
    case artifactSizeMismatch
    case sourceMismatch
    case sourceTrackMismatch
    case policyMismatch
    case clipIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            "Video analysis is outside its reserved project location."
        case .invalidArtifact:
            "Video analysis evidence is invalid."
        case .unsupportedSchema(let version):
            "Unsupported video analysis schema \(version)."
        case .artifactDigestMismatch:
            "Video analysis evidence has changed."
        case .artifactSizeMismatch:
            "Video analysis evidence has changed size."
        case .sourceMismatch:
            "Video analysis evidence belongs to different source bytes."
        case .sourceTrackMismatch:
            "Video analysis evidence belongs to a different video track."
        case .policyMismatch:
            "Video analysis evidence was produced with a different frame policy."
        case .clipIdentityMismatch:
            "Video analysis evidence has a different clip identity."
        }
    }
}

struct VideoFrameAnalysisArtifactRemovalToken: Sendable {
    let url: URL
    fileprivate let parentDevice: UInt64
    fileprivate let parentInode: UInt64
    fileprivate let fileDevice: UInt64
    fileprivate let fileInode: UInt64
    fileprivate let byteCount: Int64
    fileprivate let sha256: String
}

final class VideoFrameAnalysisArtifactCreationLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [VideoFrameAnalysisArtifactRemovalToken] = []

    func record(_ token: VideoFrameAnalysisArtifactRemovalToken?) {
        guard let token else { return }
        lock.withLock { tokens.append(token) }
    }

    func commit() {
        lock.withLock { tokens.removeAll() }
    }

    func rollback() {
        let pending = lock.withLock {
            let pending = Array(tokens.reversed())
            tokens.removeAll()
            return pending
        }
        for token in pending {
            _ = try? VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(token)
        }
    }
}

enum VideoFrameAnalysisArtifactStore {
    static let maximumArtifactBytes = 64 * 1_024 * 1_024
    private static let maximumCandidateCount = 500_000

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    static func save(
        _ artifact: VideoFrameAnalysisArtifact,
        to url: URL,
        projectPaths: ProjectPaths
    ) throws -> VideoFrameAnalysisArtifactFileEvidence {
        try validateReservedLocation(
            url,
            sourceIndex: artifact.sourceIndex,
            projectPaths: projectPaths
        )
        let data = try encodedData(artifact)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return VideoFrameAnalysisArtifactFileEvidence(
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    static func saveRegenerated(
        _ artifact: VideoFrameAnalysisArtifact,
        projectPaths: ProjectPaths
    ) throws -> (
        url: URL,
        evidence: VideoFrameAnalysisArtifactFileEvidence,
        cleanupToken: VideoFrameAnalysisArtifactRemovalToken?
    ) {
        let data = try encodedData(artifact)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let url = projectPaths.videoFrameAnalysisURL(
            index: artifact.sourceIndex,
            artifactSHA256: digest
        )
        try validateReservedLocation(
            url,
            sourceIndex: artifact.sourceIndex,
            artifactSHA256: digest,
            projectPaths: projectPaths
        )
        let created = try writeContentAddressedFileIfAbsent(data, to: url)
        let existing: Data
        do {
            existing = try BoundedFileReader.readRegularFile(
                at: url,
                maximumBytes: maximumArtifactBytes
            )
        } catch {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        guard existing == data else {
            throw VideoFrameAnalysisArtifactStoreError.artifactDigestMismatch
        }
        let evidence = VideoFrameAnalysisArtifactFileEvidence(
            byteCount: Int64(data.count),
            sha256: digest
        )
        let cleanupToken = created
            ? try makeRemovalToken(
                at: url,
                expectedEvidence: evidence,
                sourceIndex: artifact.sourceIndex,
                projectPaths: projectPaths
            )
            : nil
        if let cleanupToken {
            do {
                try synchronizeParentDirectory(of: url)
            } catch {
                _ = try? removeExpectedRegularFile(cleanupToken)
                throw error
            }
        }
        return (url, evidence, cleanupToken)
    }

    static func makeRemovalToken(
        at url: URL,
        expectedEvidence: VideoFrameAnalysisArtifactFileEvidence,
        sourceIndex: Int,
        projectPaths: ProjectPaths
    ) throws -> VideoFrameAnalysisArtifactRemovalToken {
        try validateReservedLocation(
            url,
            sourceIndex: sourceIndex,
            artifactSHA256: expectedEvidence.sha256,
            projectPaths: projectPaths
        )
        let parentURL = url.deletingLastPathComponent()
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw VideoFrameAnalysisArtifactStoreError.unsafePath
        }
        defer { Darwin.close(parent) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }

        var parentStatus = stat()
        var literalParentStatus = stat()
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(parent, &parentStatus) == 0,
              lstat(parentURL.path, &literalParentStatus) == 0,
              sameFile(parentStatus, literalParentStatus),
              (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              fstat(descriptor, &descriptorStatus) == 0,
              pathResult == 0,
              sameFile(descriptorStatus, pathStatus),
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_size == expectedEvidence.byteCount else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        let data = try readData(
            descriptor: descriptor,
            byteCount: Int(descriptorStatus.st_size)
        )
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedEvidence.sha256 else {
            throw VideoFrameAnalysisArtifactStoreError.artifactDigestMismatch
        }
        return VideoFrameAnalysisArtifactRemovalToken(
            url: url,
            parentDevice: device(parentStatus),
            parentInode: UInt64(parentStatus.st_ino),
            fileDevice: device(descriptorStatus),
            fileInode: UInt64(descriptorStatus.st_ino),
            byteCount: expectedEvidence.byteCount,
            sha256: expectedEvidence.sha256
        )
    }

    @discardableResult
    static func removeExpectedRegularFile(
        _ token: VideoFrameAnalysisArtifactRemovalToken,
        beforeFinalIdentityCheck: () throws -> Void = {},
        beforeQuarantineRename: () throws -> Void = {}
    ) throws -> Bool {
        let parentURL = token.url.deletingLastPathComponent()
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { return false }
        defer { Darwin.close(parent) }

        var parentStatus = stat()
        var literalParentStatus = stat()
        guard fstat(parent, &parentStatus) == 0,
              lstat(parentURL.path, &literalParentStatus) == 0,
              sameFile(parentStatus, literalParentStatus),
              device(parentStatus) == token.parentDevice,
              UInt64(parentStatus.st_ino) == token.parentInode,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        let descriptor = token.url.lastPathComponent.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              device(opened) == token.fileDevice,
              UInt64(opened.st_ino) == token.fileInode,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              opened.st_size == token.byteCount else {
            return false
        }

        try beforeFinalIdentityCheck()

        var finalPath = stat()
        var finalDescriptor = stat()
        var finalParent = stat()
        var finalLiteralParent = stat()
        let finalPathResult = token.url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &finalPath, AT_SYMLINK_NOFOLLOW)
        }
        guard finalPathResult == 0,
              fstat(descriptor, &finalDescriptor) == 0,
              fstat(parent, &finalParent) == 0,
              lstat(parentURL.path, &finalLiteralParent) == 0,
              sameFile(opened, finalDescriptor),
              sameFile(opened, finalPath),
              sameFile(parentStatus, finalParent),
              sameFile(parentStatus, finalLiteralParent),
              (finalPath.st_mode & S_IFMT) == S_IFREG,
              finalPath.st_nlink == 1,
              finalPath.st_size == token.byteCount else {
            return false
        }
        let finalData: Data
        do {
            finalData = try readData(descriptor: descriptor, byteCount: Int(token.byteCount))
        } catch {
            return false
        }
        guard SHA256.hash(data: finalData)
            .map({ String(format: "%02x", $0) })
            .joined() == token.sha256 else {
            return false
        }

        try beforeQuarantineRename()

        let quarantineName = ".\(token.url.lastPathComponent).superseded.\(UUID().uuidString).tmp"
        let renamed = token.url.lastPathComponent.withCString { sourcePointer in
            quarantineName.withCString { quarantinePointer in
                Darwin.renameatx_np(
                    parent,
                    sourcePointer,
                    parent,
                    quarantinePointer,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard renamed == 0 else { return false }

        var movedPath = stat()
        let movedPathResult = quarantineName.withCString {
            Darwin.fstatat(parent, $0, &movedPath, AT_SYMLINK_NOFOLLOW)
        }
        guard movedPathResult == 0 else { return false }
        var restoreQuarantine = true
        defer {
            if restoreQuarantine {
                _ = restoreQuarantinedEntry(
                    quarantineName,
                    to: token.url.lastPathComponent,
                    expected: movedPath,
                    directory: parent
                )
            }
        }

        let quarantinedDescriptor = quarantineName.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard quarantinedDescriptor >= 0 else { return false }
        defer { Darwin.close(quarantinedDescriptor) }
        var quarantined = stat()
        var quarantinedPath = stat()
        let quarantinedPathResult = quarantineName.withCString {
            Darwin.fstatat(parent, $0, &quarantinedPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(quarantinedDescriptor, &quarantined) == 0,
              quarantinedPathResult == 0,
              sameFile(quarantined, quarantinedPath),
              device(quarantined) == token.fileDevice,
              UInt64(quarantined.st_ino) == token.fileInode,
              (quarantined.st_mode & S_IFMT) == S_IFREG,
              quarantined.st_nlink == 1,
              quarantined.st_size == token.byteCount else {
            return false
        }
        let quarantinedData: Data
        do {
            quarantinedData = try readData(
                descriptor: quarantinedDescriptor,
                byteCount: Int(token.byteCount)
            )
        } catch {
            return false
        }
        guard SHA256.hash(data: quarantinedData)
            .map({ String(format: "%02x", $0) })
            .joined() == token.sha256 else {
            return false
        }

        var finalQuarantined = stat()
        var finalQuarantinedPath = stat()
        let finalQuarantinedPathResult = quarantineName.withCString {
            Darwin.fstatat(parent, $0, &finalQuarantinedPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(quarantinedDescriptor, &finalQuarantined) == 0,
              finalQuarantinedPathResult == 0,
              sameFile(quarantined, finalQuarantined),
              sameFile(quarantined, finalQuarantinedPath),
              (finalQuarantined.st_mode & S_IFMT) == S_IFREG,
              finalQuarantined.st_nlink == 1,
              finalQuarantined.st_size == token.byteCount else {
            return false
        }
        let unlinked = quarantineName.withCString {
            Darwin.unlinkat(parent, $0, AT_SYMLINK_NOFOLLOW_ANY)
        } == 0
        if unlinked {
            restoreQuarantine = false
        }
        return unlinked
    }

    static func load(
        from url: URL,
        receipt: VideoInputReceipt,
        expectedPolicy: VideoFrameAnalysisPolicy,
        expectedClipGroupID: String,
        expectedSourceIndex: Int,
        projectPaths: ProjectPaths
    ) throws -> VideoFrameAnalysisArtifact {
        try validateReservedLocation(
            url,
            sourceIndex: expectedSourceIndex,
            artifactSHA256: receipt.analysisArtifactSHA256,
            projectPaths: projectPaths
        )
        guard receipt.analysisArtifactPath
                == (try? projectPaths.projectRelativePath(for: url)) else {
            throw VideoFrameAnalysisArtifactStoreError.unsafePath
        }
        let data: Data
        do {
            data = try BoundedFileReader.readRegularFile(
                at: url,
                maximumBytes: maximumArtifactBytes
            )
        } catch {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        guard Int64(data.count) == receipt.analysisArtifactByteCount else {
            throw VideoFrameAnalysisArtifactStoreError.artifactSizeMismatch
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == receipt.analysisArtifactSHA256 else {
            throw VideoFrameAnalysisArtifactStoreError.artifactDigestMismatch
        }
        let envelope: SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        } catch {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        guard envelope.schemaVersion == VideoFrameAnalysisArtifact.currentSchemaVersion else {
            throw VideoFrameAnalysisArtifactStoreError.unsupportedSchema(
                envelope.schemaVersion
            )
        }
        let artifact: VideoFrameAnalysisArtifact
        do {
            artifact = try JSONDecoder().decode(VideoFrameAnalysisArtifact.self, from: data)
        } catch {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        try validate(artifact)
        guard artifact.sourceIndex == expectedSourceIndex,
              artifact.sourceProjectRelativePath == receipt.projectRelativePath,
              artifact.sourceByteCount == receipt.byteCount,
              artifact.sourceSHA256 == receipt.sha256 else {
            throw VideoFrameAnalysisArtifactStoreError.sourceMismatch
        }
        guard artifact.trackID == receipt.trackID,
              artifact.pixelWidth == receipt.pixelWidth,
              artifact.pixelHeight == receipt.pixelHeight,
              approximatelyEqual(artifact.durationSeconds, receipt.durationSeconds),
              approximatelyEqual(artifact.nominalFrameRate, receipt.nominalFrameRate),
              artifact.isHDR == receipt.isHDR,
              artifact.decodedFrameCount == receipt.decodedFrameCount,
              approximatelyEqual(artifact.transformA, receipt.transformA),
              approximatelyEqual(artifact.transformB, receipt.transformB),
              approximatelyEqual(artifact.transformC, receipt.transformC),
              approximatelyEqual(artifact.transformD, receipt.transformD),
              approximatelyEqual(artifact.transformTX, receipt.transformTX),
              approximatelyEqual(artifact.transformTY, receipt.transformTY) else {
            throw VideoFrameAnalysisArtifactStoreError.sourceTrackMismatch
        }
        guard expectedPolicy.isValid,
              artifact.policy == expectedPolicy,
              receipt.analysisPolicySHA256 == expectedPolicy.sha256 else {
            throw VideoFrameAnalysisArtifactStoreError.policyMismatch
        }
        guard artifact.clipGroupID == expectedClipGroupID,
              receipt.clipGroupID == expectedClipGroupID else {
            throw VideoFrameAnalysisArtifactStoreError.clipIdentityMismatch
        }
        return artifact
    }

    static func validate(_ artifact: VideoFrameAnalysisArtifact) throws {
        let determinant = artifact.transformA * artifact.transformD
            - artifact.transformB * artifact.transformC
        guard artifact.schemaVersion == VideoFrameAnalysisArtifact.currentSchemaVersion,
              (0..<10_000).contains(artifact.sourceIndex),
              controlledVideoPath(
                  artifact.sourceProjectRelativePath,
                  sourceIndex: artifact.sourceIndex
              ),
              artifact.sourceByteCount > 0,
              isSHA256(artifact.sourceSHA256),
              !artifact.clipGroupID.isEmpty,
              artifact.clipGroupID.utf8.count <= 160,
              artifact.clipGroupID.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 122)
                    || $0 == "_"
              }),
              artifact.policy.isValid,
              artifact.trackID > 0,
              (1...131_072).contains(artifact.pixelWidth),
              (1...131_072).contains(artifact.pixelHeight),
              artifact.durationSeconds.isFinite,
              artifact.durationSeconds > 0,
              artifact.nominalFrameRate.isFinite,
              artifact.nominalFrameRate >= 0,
              artifact.decodedFrameCount > 0,
              !artifact.candidates.isEmpty,
              artifact.candidates.count <= maximumCandidateCount,
              artifact.candidates.count <= artifact.decodedFrameCount,
              [
                  artifact.transformA,
                  artifact.transformB,
                  artifact.transformC,
                  artifact.transformD,
                  artifact.transformTX,
                  artifact.transformTY,
              ].allSatisfy(\.isFinite),
              determinant.isFinite,
              abs(determinant) > 1e-12 else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        var priorFrameIndex = -1
        var priorTimestamp = -Double.infinity
        for candidate in artifact.candidates {
            guard candidate.isValid,
                  candidate.frameIndex > priorFrameIndex,
                  candidate.frameIndex < artifact.decodedFrameCount,
                  candidate.timestampSeconds >= priorTimestamp,
                  candidate.timestampSeconds <= artifact.durationSeconds + 1 else {
                throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
            }
            if candidate.presentationTimeValue == nil,
               !artifact.hadRepairedTimestamps {
                throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
            }
            priorFrameIndex = candidate.frameIndex
            priorTimestamp = candidate.timestampSeconds
        }
    }

    private static func validateReservedLocation(
        _ url: URL,
        sourceIndex: Int,
        artifactSHA256: String? = nil,
        projectPaths: ProjectPaths
    ) throws {
        guard (0..<10_000).contains(sourceIndex) else {
            throw VideoFrameAnalysisArtifactStoreError.unsafePath
        }
        let fixedPath = String(
            format: "Frames/video-analysis-%04d.json",
            sourceIndex
        )
        let contentAddressedPath = artifactSHA256.map {
            String(
                format: "Frames/video-analysis-%04d-%@.json",
                sourceIndex,
                $0
            )
        }
        let relativePath: String
        if url.path == projectPaths.root.appendingPathComponent(fixedPath).path {
            relativePath = fixedPath
        } else if let contentAddressedPath,
                  isSHA256(artifactSHA256 ?? ""),
                  url.path == projectPaths.root.appendingPathComponent(contentAddressedPath).path {
            relativePath = contentAddressedPath
        } else {
            throw VideoFrameAnalysisArtifactStoreError.unsafePath
        }
        do {
            _ = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: relativePath
            )
        } catch {
            throw VideoFrameAnalysisArtifactStoreError.unsafePath
        }
    }

    private static func encodedData(
        _ artifact: VideoFrameAnalysisArtifact
    ) throws -> Data {
        try validate(artifact)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard !data.isEmpty, data.count <= maximumArtifactBytes else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        return data
    }

    private static func writeContentAddressedFileIfAbsent(
        _ data: Data,
        to url: URL
    ) throws -> Bool {
        let directory = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw VideoFrameAnalysisArtifactStoreError.unsafePath
        }
        defer { Darwin.close(directory) }
        var directoryStatus = stat()
        var literalDirectoryStatus = stat()
        guard fstat(directory, &directoryStatus) == 0,
              lstat(url.deletingLastPathComponent().path, &literalDirectoryStatus) == 0,
              sameFile(directoryStatus, literalDirectoryStatus),
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw VideoFrameAnalysisArtifactStoreError.unsafePath
        }
        var existing = stat()
        let existingResult = url.lastPathComponent.withCString {
            Darwin.fstatat(directory, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        if existingResult == 0 { return false }
        guard errno == ENOENT else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }

        let temporaryName = ".video-analysis-\(UUID().uuidString).tmp"
        let temporary = temporaryName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporary >= 0 else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        var removeTemporary = true
        defer {
            Darwin.close(temporary)
            if removeTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(directory, $0, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    temporary,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
                }
                offset += count
            }
        }
        guard Darwin.fsync(temporary) == 0 else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        let renamed = temporaryName.withCString { temporaryPointer in
            url.lastPathComponent.withCString { destinationPointer in
                Darwin.renameatx_np(
                    directory,
                    temporaryPointer,
                    directory,
                    destinationPointer,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        if renamed == 0 {
            removeTemporary = false
            return true
        }
        guard errno == EEXIST else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        return false
    }

    private static func synchronizeParentDirectory(of url: URL) throws {
        let directory = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(directory) }
        while Darwin.fsync(directory) != 0 {
            if errno == EINTR { continue }
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
    }

    private static func readData(descriptor: Int32, byteCount: Int) throws -> Data {
        guard byteCount >= 0, byteCount <= maximumArtifactBytes else {
            throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
        }
        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < byteCount {
                let count = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw VideoFrameAnalysisArtifactStoreError.invalidArtifact
                }
                offset += count
            }
        }
        return data
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func restoreQuarantinedEntry(
        _ quarantineName: String,
        to originalName: String,
        expected: stat,
        directory: Int32
    ) -> Bool {
        var current = stat()
        let currentResult = quarantineName.withCString {
            Darwin.fstatat(directory, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard currentResult == 0, sameFile(current, expected) else { return false }
        return quarantineName.withCString { quarantinePointer in
            originalName.withCString { originalPointer in
                Darwin.renameatx_np(
                    directory,
                    quarantinePointer,
                    directory,
                    originalPointer,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        } == 0
    }

    private static func device(_ status: stat) -> UInt64 {
        UInt64(bitPattern: Int64(status.st_dev))
    }

    private static func controlledVideoPath(_ path: String, sourceIndex: Int) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 2, components[0] == "Originals" else {
            return false
        }
        let prefix = String(format: "video-%04d.", sourceIndex)
        guard components[1].hasPrefix(prefix) else { return false }
        let suffix = components[1].dropFirst(prefix.count)
        return !suffix.isEmpty
            && suffix.utf8.count <= 8
            && suffix.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 122)
            }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = max(1, abs(lhs), abs(rhs))
        return abs(lhs - rhs) <= scale * 1e-9
    }
}
