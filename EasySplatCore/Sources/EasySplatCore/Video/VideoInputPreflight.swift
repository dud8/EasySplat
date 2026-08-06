import CoreGraphics
import CoreMedia
import CryptoKit
import Darwin
import Foundation

public struct VideoInputPreflightLimits: Equatable, Sendable {
    public var maximumVideoCount: Int
    public var maximumTotalBytes: Int64
    public var minimumFreeSpaceReserveBytes: Int64
    public var maximumConcurrentDecoders: Int

    public init(
        maximumVideoCount: Int = 64,
        maximumTotalBytes: Int64 = 512 * 1_024 * 1_024 * 1_024,
        minimumFreeSpaceReserveBytes: Int64 = 1_024 * 1_024 * 1_024,
        maximumConcurrentDecoders: Int = 2
    ) {
        self.maximumVideoCount = maximumVideoCount
        self.maximumTotalBytes = maximumTotalBytes
        self.minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes
        self.maximumConcurrentDecoders = min(2, maximumConcurrentDecoders)
    }

    var isValid: Bool {
        maximumVideoCount > 0
            && maximumTotalBytes > 0
            && minimumFreeSpaceReserveBytes >= 0
            && maximumConcurrentDecoders > 0
            && maximumConcurrentDecoders <= 2
    }
}

public enum VideoInputPreflightIssue: Equatable, Sendable {
    case noVideosSelected
    case sourceUnavailable
    case accessDenied
    case symbolicLink
    case notRegularFile
    case emptyFile
    case duplicateSource(firstIndex: Int)
    case sourceChanged
    case unreadableMedia
    case noUsableVideoTrack
    case decodeFailed
    case tooManyVideos(maximum: Int)
    case totalBytesExceeded(maximum: Int64)
    case insufficientSpace(required: Int64, available: Int64)
    case invalidLimits
    case stagingUnavailable
    case capacityUnavailable
    case copyFailed
    case unsupportedSpherical(UnsupportedSphericalMediaIssue)
}

public struct VideoInputRejection: Equatable, Sendable {
    public let index: Int
    public let safeDisplayName: String
    public let issue: VideoInputPreflightIssue

    public init(index: Int, safeDisplayName: String, issue: VideoInputPreflightIssue) {
        self.index = index
        self.safeDisplayName = safeDisplayName
        self.issue = issue
    }
}

public struct VideoInputPreflightFailure: Error, Equatable, Sendable {
    public let rejectedVideos: [VideoInputRejection]

    public init(rejectedVideos: [VideoInputRejection]) {
        self.rejectedVideos = rejectedVideos
    }
}

enum VideoInputCapacityEvidenceError: Error, Equatable {
    case unavailable
}

struct VideoInputAnalysisEvidence: Equatable, Sendable {
    let trackID: Int32
    let pixelWidth: Int
    let pixelHeight: Int
    let durationSeconds: Double
    let nominalFrameRate: Double
    let isHDR: Bool
    let decodedFrameCount: Int
    let preferredTransform: CGAffineTransform
    let candidates: [TimedFrameCandidate]
    let hadRepairedTimestamps: Bool

    init(
        trackID: Int32,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        nominalFrameRate: Double,
        isHDR: Bool,
        decodedFrameCount: Int,
        preferredTransform: CGAffineTransform,
        candidates: [TimedFrameCandidate]? = nil,
        hadRepairedTimestamps: Bool = false
    ) {
        self.trackID = trackID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.nominalFrameRate = nominalFrameRate
        self.isHDR = isHDR
        self.decodedFrameCount = decodedFrameCount
        self.preferredTransform = preferredTransform
        self.hadRepairedTimestamps = hadRepairedTimestamps
        if let candidates {
            self.candidates = candidates
        } else {
            let count = max(1, min(decodedFrameCount, 3))
            self.candidates = (0..<count).map { offset in
                let frameIndex = count == 1
                    ? 0
                    : Int((Double(offset) * Double(max(0, decodedFrameCount - 1))
                        / Double(count - 1)).rounded())
                let timestamp = count == 1
                    ? 0
                    : Double(offset) * durationSeconds / Double(count - 1)
                return TimedFrameCandidate(
                    frameIndex: frameIndex,
                    timestampSeconds: timestamp,
                    candidate: SmartFrameCandidate(
                        index: frameIndex,
                        sharpness: 1,
                        brightness: 0.5,
                        clippedFraction: 0,
                        motionScore: 0,
                        dHash: UInt64(frameIndex)
                    ),
                    presentationTime: CMTime(
                        seconds: timestamp,
                        preferredTimescale: 600
                    )
                )
            }
        }
    }
}

fileprivate struct VideoInputFileEvidence: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t
    let linkCount: nlink_t
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        owner = status.st_uid
        mode = status.st_mode
        linkCount = status.st_nlink
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }

    var isPrivateDirectory: Bool {
        (mode & S_IFMT) == S_IFDIR
            && owner == getuid()
            && mode & mode_t(0o7777) == mode_t(0o700)
    }

    var isPrivateRegularFile: Bool {
        (mode & S_IFMT) == S_IFREG
            && owner == getuid()
            && linkCount == 1
            && size > 0
            && mode & mode_t(0o7777) == mode_t(0o600)
    }

    func matchesDirectory(_ status: stat) -> Bool {
        isPrivateDirectory
            && (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_dev == device
            && status.st_ino == inode
            && status.st_uid == owner
            && status.st_mode & mode_t(0o7777) == mode_t(0o700)
    }

    func matchesFile(_ status: stat) -> Bool {
        isPrivateRegularFile
            && (status.st_mode & S_IFMT) == S_IFREG
            && status.st_dev == device
            && status.st_ino == inode
            && status.st_uid == owner
            && status.st_nlink == linkCount
            && status.st_size == size
            && status.st_mode & mode_t(0o7777) == mode_t(0o600)
            && status.st_mtimespec.tv_sec == modifiedSeconds
            && status.st_mtimespec.tv_nsec == modifiedNanoseconds
            && status.st_ctimespec.tv_sec == changedSeconds
            && status.st_ctimespec.tv_nsec == changedNanoseconds
    }
}

fileprivate final class VideoInputIntegrityLease: @unchecked Sendable {
    private enum Strategy {
        case vnode(root: VnodeMutationMonitor, files: [String: VnodeMutationMonitor])
        case controlledRename(files: [String: VnodeMutationMonitor])
        case retryAfterControlledRenameFailure(files: [String: VnodeMutationMonitor])
        case adopted(files: [String: VnodeMutationMonitor])
        case unavailable
        case closed
    }

    private let lock = NSLock()
    private let rootURL: URL
    private let rootEvidence: VideoInputFileEvidence
    private let expectedLeaves: Set<String>
    private var strategy: Strategy

    init(
        rootURL: URL,
        rootEvidence: VideoInputFileEvidence,
        snapshots: [VideoInputPreflight.Snapshot],
        rootMonitor: VnodeMutationMonitor?
    ) {
        self.rootURL = rootURL
        self.rootEvidence = rootEvidence
        self.expectedLeaves = Set(snapshots.map { $0.url.lastPathComponent })
        let fileMonitors = Dictionary(
            uniqueKeysWithValues: snapshots.compactMap { snapshot in
                snapshot.fileMonitor.map { (snapshot.url.lastPathComponent, $0) }
            }
        )
        if let rootMonitor, fileMonitors.count == snapshots.count {
            strategy = .vnode(root: rootMonitor, files: fileMonitors)
        } else {
            rootMonitor?.close()
            snapshots.forEach { $0.fileMonitor?.close() }
            strategy = .unavailable
        }
    }

    func validates(_ snapshot: VideoInputPreflight.Snapshot) -> Bool {
        lock.withLock {
            guard validatesRootBinding() else { return false }
            switch strategy {
            case let .vnode(root, files):
                guard root.poll().isTrustworthy,
                      let monitor = files[snapshot.url.lastPathComponent],
                      monitor.poll().isTrustworthy else {
                    return false
                }
                return validatesFileBinding(
                    url: snapshot.url,
                    evidence: snapshot.fileEvidence
                )
            case .controlledRename, .retryAfterControlledRenameFailure, .adopted,
                 .unavailable, .closed:
                return false
            }
        }
    }

    func validates(videos: [PreparedVideoInput.Video], at rootURL: URL) -> Bool {
        lock.withLock {
            guard validatesRootBinding(at: rootURL, videos: videos) else { return false }
            switch strategy {
            case let .vnode(root, files):
                guard rootURL.standardizedFileURL.path == self.rootURL.standardizedFileURL.path,
                      root.poll().isTrustworthy else {
                    return false
                }
                return videos.allSatisfy { video in
                    guard let monitor = files[video.stagedURL.lastPathComponent] else {
                        return false
                    }
                    return monitor.poll().isTrustworthy
                        && validatesFileBinding(url: video.stagedURL, evidence: video.fileEvidence)
                }
            case let .retryAfterControlledRenameFailure(files):
                return videos.allSatisfy { video in
                    files[video.stagedURL.lastPathComponent]?.poll().isTrustworthy == true
                        && validatesFileBinding(url: video.stagedURL, evidence: video.fileEvidence)
                }
            case .controlledRename, .adopted, .unavailable, .closed:
                return false
            }
        }
    }

    /// The root rename is EasySplat's only expected vnode mutation. File
    /// watches remain armed across it and the destination binding is rechecked.
    func prepareForControlledRename(videos: [PreparedVideoInput.Video]) -> Bool {
        lock.withLock {
            guard validatesRootBinding(at: rootURL, videos: videos) else { return false }
            switch strategy {
            case let .vnode(root, files):
                guard root.poll().isTrustworthy,
                      videos.allSatisfy({ video in
                          files[video.stagedURL.lastPathComponent]?.poll().isTrustworthy == true
                              && validatesFileBinding(
                                  url: video.stagedURL,
                                  evidence: video.fileEvidence
                              )
                      }) else {
                    return false
                }
                root.close()
                strategy = .controlledRename(files: files)
                return true
            case let .retryAfterControlledRenameFailure(files):
                guard videos.allSatisfy({ video in
                    files[video.stagedURL.lastPathComponent]?.poll().isTrustworthy == true
                        && validatesFileBinding(url: video.stagedURL, evidence: video.fileEvidence)
                }) else {
                    return false
                }
                strategy = .controlledRename(files: files)
                return true
            case .controlledRename, .adopted, .unavailable, .closed:
                return false
            }
        }
    }

    func validatesAfterControlledRename(
        videos: [PreparedVideoInput.Video],
        at destinationRoot: URL,
        monitorFactory: ([VnodeMutationMonitor.Watch]) throws -> VnodeMutationMonitor
    ) -> Bool {
        lock.withLock {
            guard validatesRootBinding(at: destinationRoot, videos: videos) else { return false }
            switch strategy {
            case let .controlledRename(files):
                var successorMonitors: [String: VnodeMutationMonitor] = [:]
                for video in videos {
                    let descriptor = Darwin.open(
                        video.stagedURL.path,
                        O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
                    )
                    guard descriptor >= 0 else {
                        successorMonitors.values.forEach { $0.close() }
                        return false
                    }
                    defer { Darwin.close(descriptor) }
                    var status = stat()
                    guard fstat(descriptor, &status) == 0,
                          video.fileEvidence.matchesFile(status),
                          let monitor = try? monitorFactory([.init(
                              descriptor: descriptor,
                              label: video.stagedURL.lastPathComponent,
                              ownership: .duplicated
                          )]) else {
                        successorMonitors.values.forEach { $0.close() }
                        return false
                    }
                    successorMonitors[video.stagedURL.lastPathComponent] = monitor
                }
                let oldWatchesTrustworthy = files.values.allSatisfy { monitor in
                    let snapshot = monitor.poll()
                    return snapshot.failure == nil
                        && snapshot.mutations.allSatisfy { $0.flags == [.rename] }
                }
                let successorWatchesTrustworthy = successorMonitors.values.allSatisfy {
                    $0.poll().isTrustworthy
                }
                guard oldWatchesTrustworthy, successorWatchesTrustworthy else {
                    successorMonitors.values.forEach { $0.close() }
                    return false
                }
                files.values.forEach { $0.close() }
                strategy = .adopted(files: successorMonitors)
                return true
            case .vnode, .retryAfterControlledRenameFailure, .adopted,
                 .unavailable, .closed:
                return false
            }
        }
    }

    func controlledRenameFailed() {
        lock.withLock {
            guard case let .controlledRename(files) = strategy else { return }
            strategy = .retryAfterControlledRenameFailure(files: files)
        }
    }

    func completeSuccessorHandoff() -> Bool {
        lock.withLock {
            guard case let .adopted(files) = strategy else { return false }
            let trustworthy = files.values.allSatisfy { monitor in
                monitor.poll().isTrustworthy
            }
            files.values.forEach { $0.close() }
            strategy = .closed
            return trustworthy
        }
    }

    func close() {
        lock.withLock {
            switch strategy {
            case let .vnode(root, files):
                root.close()
                files.values.forEach { $0.close() }
            case let .controlledRename(files):
                files.values.forEach { $0.close() }
            case let .retryAfterControlledRenameFailure(files):
                files.values.forEach { $0.close() }
            case let .adopted(files):
                files.values.forEach { $0.close() }
            case .unavailable, .closed:
                break
            }
            strategy = .closed
        }
    }

    private func validatesRootBinding() -> Bool {
        guard let currentRoot = Self.status(at: rootURL),
              rootEvidence.matchesDirectory(currentRoot),
              let leaves = try? Set(FileManager.default.contentsOfDirectory(atPath: rootURL.path))
        else { return false }
        return leaves == expectedLeaves
    }

    private func validatesRootBinding(
        at rootURL: URL,
        videos: [PreparedVideoInput.Video]
    ) -> Bool {
        guard let currentRoot = Self.status(at: rootURL),
              rootEvidence.matchesDirectory(currentRoot),
              let leaves = try? Set(FileManager.default.contentsOfDirectory(atPath: rootURL.path))
        else { return false }
        return leaves == Set(videos.map { $0.stagedURL.lastPathComponent })
    }

    private func validatesFileBinding(url: URL, evidence: VideoInputFileEvidence) -> Bool {
        guard let current = Self.status(at: url) else { return false }
        return evidence.matchesFile(current)
    }

    private static func status(at url: URL) -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return value
    }
}

public enum VideoInputIntegrityHandoffError: Error, Equatable, Sendable {
    case unavailable
    case alreadyIssued
    case alreadyConsumed
    case discarded
    case filesystemChanged
}

/// One-shot overlap between preflight's file watches and the publication
/// transaction's independently bound successor watches.
public final class VideoInputIntegrityHandoff: @unchecked Sendable {
    private enum State {
        case prepared
        case consumed
        case discarded
    }

    private let lock = NSLock()
    private let integrityLease: VideoInputIntegrityLease?
    private let testingMonitors: [VnodeMutationMonitor]
    private var state = State.prepared

    fileprivate init(integrityLease: VideoInputIntegrityLease) {
        self.integrityLease = integrityLease
        testingMonitors = []
    }

    init(testingMonitors: [VnodeMutationMonitor]) {
        integrityLease = nil
        self.testingMonitors = testingMonitors
    }

    deinit {
        discard()
    }

    func consumeAfterSuccessorArmed() throws {
        try lock.withLock {
            switch state {
            case .consumed:
                throw VideoInputIntegrityHandoffError.alreadyConsumed
            case .discarded:
                throw VideoInputIntegrityHandoffError.discarded
            case .prepared:
                state = .consumed
            }
            let trustworthy: Bool
            if let integrityLease {
                trustworthy = integrityLease.completeSuccessorHandoff()
            } else {
                trustworthy = testingMonitors.allSatisfy { monitor in
                    let snapshot = monitor.poll()
                    return snapshot.failure == nil
                        && snapshot.mutations.allSatisfy { $0.flags == [.rename] }
                }
                testingMonitors.forEach { $0.close() }
            }
            guard trustworthy else {
                throw VideoInputIntegrityHandoffError.filesystemChanged
            }
        }
    }

    public func discard() {
        let shouldClose = lock.withLock { () -> Bool in
            guard state == .prepared else { return false }
            state = .discarded
            return true
        }
        if shouldClose {
            integrityLease?.close()
            testingMonitors.forEach { $0.close() }
        }
    }
}

public final class PreparedVideoInput: @unchecked Sendable {
    public struct Video: Equatable, Sendable {
        public let index: Int
        public let safeDisplayName: String
        public let stagedURL: URL
        public let byteCount: Int64
        public let sha256: String
        public let trackID: Int32
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let durationSeconds: Double
        public let nominalFrameRate: Double
        public let isHDR: Bool
        public let decodedFrameCount: Int
        public let transformA: Double
        public let transformB: Double
        public let transformC: Double
        public let transformD: Double
        public let transformTX: Double
        public let transformTY: Double
        public let clipGroupID: String
        public let analysisPolicy: VideoFrameAnalysisPolicy
        let analysisEvidence: VideoInputAnalysisEvidence
        fileprivate let fileEvidence: VideoInputFileEvidence

        fileprivate init(
            index: Int,
            safeDisplayName: String,
            stagedURL: URL,
            byteCount: Int64,
            sha256: String,
            analysis: VideoInputAnalysisEvidence,
            clipGroupID: String,
            analysisPolicy: VideoFrameAnalysisPolicy,
            fileEvidence: VideoInputFileEvidence
        ) {
            self.index = index
            self.safeDisplayName = safeDisplayName
            self.stagedURL = stagedURL
            self.byteCount = byteCount
            self.sha256 = sha256
            self.trackID = analysis.trackID
            self.pixelWidth = analysis.pixelWidth
            self.pixelHeight = analysis.pixelHeight
            self.durationSeconds = analysis.durationSeconds
            self.nominalFrameRate = analysis.nominalFrameRate
            self.isHDR = analysis.isHDR
            self.decodedFrameCount = analysis.decodedFrameCount
            self.transformA = analysis.preferredTransform.a
            self.transformB = analysis.preferredTransform.b
            self.transformC = analysis.preferredTransform.c
            self.transformD = analysis.preferredTransform.d
            self.transformTX = analysis.preferredTransform.tx
            self.transformTY = analysis.preferredTransform.ty
            self.clipGroupID = clipGroupID
            self.analysisPolicy = analysisPolicy
            self.analysisEvidence = analysis
            self.fileEvidence = fileEvidence
        }

        func replacingURL(_ url: URL) -> Video {
            Video(
                index: index,
                safeDisplayName: safeDisplayName,
                stagedURL: url,
                byteCount: byteCount,
                sha256: sha256,
                analysis: VideoInputAnalysisEvidence(
                    trackID: trackID,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    durationSeconds: durationSeconds,
                    nominalFrameRate: nominalFrameRate,
                    isHDR: isHDR,
                    decodedFrameCount: decodedFrameCount,
                    preferredTransform: CGAffineTransform(
                        a: transformA,
                        b: transformB,
                        c: transformC,
                        d: transformD,
                        tx: transformTX,
                        ty: transformTY
                    ),
                    candidates: analysisEvidence.candidates,
                    hadRepairedTimestamps: analysisEvidence.hadRepairedTimestamps
                ),
                clipGroupID: clipGroupID,
                analysisPolicy: analysisPolicy,
                fileEvidence: fileEvidence
            )
        }
    }

    public let stagingRoot: URL
    public let videos: [Video]
    private let stagingContainer: URL
    private let containerEvidence: VideoInputFileEvidence
    private let rootEvidence: VideoInputFileEvidence
    private let requiredFreeBytesAtAdoption: Int64
    private let availableCapacity: @Sendable (URL) throws -> Int64
    private let integrityLease: VideoInputIntegrityLease
    private let discardBoundary: @Sendable (URL) -> Void
    private let monitorFactory: @Sendable (
        [VnodeMutationMonitor.Watch]
    ) throws -> VnodeMutationMonitor
    private let lock = NSLock()
    private var state = State.active
    private var adoptedVideos: [Video]?
    private var integrityHandoffIssued = false

    private enum State: Equatable {
        case active
        case adopting
        case adopted
        case discarded
    }

    fileprivate init(
        stagingContainer: URL,
        containerEvidence: VideoInputFileEvidence,
        stagingRoot: URL,
        rootEvidence: VideoInputFileEvidence,
        videos: [Video],
        requiredFreeBytesAtAdoption: Int64,
        availableCapacity: @escaping @Sendable (URL) throws -> Int64,
        integrityLease: VideoInputIntegrityLease,
        discardBoundary: @escaping @Sendable (URL) -> Void,
        monitorFactory: @escaping @Sendable (
            [VnodeMutationMonitor.Watch]
        ) throws -> VnodeMutationMonitor
    ) {
        self.stagingContainer = stagingContainer
        self.containerEvidence = containerEvidence
        self.stagingRoot = stagingRoot
        self.rootEvidence = rootEvidence
        self.videos = videos
        self.requiredFreeBytesAtAdoption = requiredFreeBytesAtAdoption
        self.availableCapacity = availableCapacity
        self.integrityLease = integrityLease
        self.discardBoundary = discardBoundary
        self.monitorFactory = monitorFactory
    }

    deinit {
        discard()
        if lock.withLock({ state == .adopted && !integrityHandoffIssued }) {
            integrityLease.close()
        }
    }

    public func discard() {
        let shouldDiscard = lock.withLock { () -> Bool in
            guard state == .active else { return false }
            state = .discarded
            return true
        }
        guard shouldDiscard else { return }
        guard integrityLease.validates(videos: videos, at: stagingRoot) else {
            integrityLease.close()
            return
        }
        discardBoundary(stagingRoot)
        guard integrityLease.validates(videos: videos, at: stagingRoot) else {
            integrityLease.close()
            return
        }
        try? Self.removeValidatedStagingRoot(
            stagingContainer: stagingContainer,
            containerEvidence: containerEvidence,
            stagingRoot: stagingRoot,
            rootEvidence: rootEvidence,
            videos: videos
        )
        integrityLease.close()
    }

    public func adopt(into originalsURL: URL) throws -> [Video] {
        try Task.checkCancellation()
        if let existing = lock.withLock({ state == .adopted ? adoptedVideos : nil }) {
            return existing
        }
        let mayAdopt = lock.withLock { () -> Bool in
            guard state == .active else { return false }
            state = .adopting
            return true
        }
        guard mayAdopt else { throw CocoaError(.fileWriteFileExists) }
        var didMove = false
        do {
            guard integrityLease.validates(videos: videos, at: stagingRoot) else {
                throw Self.integrityFailure(for: videos)
            }
            try Self.validateLease(
                stagingContainer: stagingContainer,
                containerEvidence: containerEvidence,
                stagingRoot: stagingRoot,
                rootEvidence: rootEvidence,
                videos: videos
            )
            let projectPaths = ProjectPaths(root: originalsURL.deletingLastPathComponent())
            try projectPaths.validateRootDirectory()
            guard originalsURL.standardizedFileURL.path
                    == projectPaths.originalsURL.standardizedFileURL.path else {
                throw Self.stagingFailure(for: videos)
            }
            var destinationStatus = stat()
            guard lstat(originalsURL.path, &destinationStatus) != 0, errno == ENOENT else {
                throw Self.stagingFailure(for: videos)
            }
            let available: Int64
            do {
                available = try availableCapacity(stagingContainer)
            } catch {
                throw Self.capacityFailure(for: videos)
            }
            guard available >= 0 else { throw Self.capacityFailure(for: videos) }
            guard available >= requiredFreeBytesAtAdoption else {
                throw Self.spaceFailure(
                    for: videos,
                    required: requiredFreeBytesAtAdoption,
                    available: max(0, available)
                )
            }
            try Task.checkCancellation()
            guard integrityLease.prepareForControlledRename(videos: videos) else {
                throw Self.integrityFailure(for: videos)
            }
            try Self.renameValidatedStagingRoot(
                stagingContainer: stagingContainer,
                containerEvidence: containerEvidence,
                stagingRoot: stagingRoot,
                rootEvidence: rootEvidence,
                projectRoot: projectPaths.root,
                originalsURL: originalsURL,
                videos: videos
            )
            didMove = true
            let adopted = videos.map { video in
                video.replacingURL(
                    originalsURL.appendingPathComponent(video.stagedURL.lastPathComponent)
                )
            }
            try Self.validateAdoptedRoot(
                originalsURL: originalsURL,
                rootEvidence: rootEvidence,
                videos: adopted
            )
            guard integrityLease.validatesAfterControlledRename(
                videos: adopted,
                at: originalsURL,
                monitorFactory: monitorFactory
            ) else {
                throw Self.integrityFailure(for: videos)
            }
            lock.withLock {
                adoptedVideos = adopted
                state = .adopted
            }
            Self.syncDirectoryBestEffort(originalsURL.deletingLastPathComponent())
            return adopted
        } catch {
            if !didMove {
                integrityLease.controlledRenameFailed()
                lock.withLock {
                    if state == .adopting { state = .active }
                }
            }
            throw error
        }
    }

    public func takeIntegrityHandoff() throws -> VideoInputIntegrityHandoff {
        try lock.withLock {
            guard state == .adopted else {
                throw VideoInputIntegrityHandoffError.unavailable
            }
            guard !integrityHandoffIssued else {
                throw VideoInputIntegrityHandoffError.alreadyIssued
            }
            integrityHandoffIssued = true
            return VideoInputIntegrityHandoff(integrityLease: integrityLease)
        }
    }

    private static func removeValidatedStagingRoot(
        stagingContainer: URL,
        containerEvidence: VideoInputFileEvidence,
        stagingRoot: URL,
        rootEvidence: VideoInputFileEvidence,
        videos: [Video]
    ) throws {
        try validateLease(
            stagingContainer: stagingContainer,
            containerEvidence: containerEvidence,
            stagingRoot: stagingRoot,
            rootEvidence: rootEvidence,
            videos: videos
        )
        try VideoInputPreflight.removeControlledRun(
            at: stagingRoot,
            in: stagingContainer,
            expectedContainerEvidence: containerEvidence,
            expectedRootEvidence: rootEvidence
        )
    }

    private static func validateLease(
        stagingContainer: URL,
        containerEvidence: VideoInputFileEvidence,
        stagingRoot: URL,
        rootEvidence: VideoInputFileEvidence,
        videos: [Video]
    ) throws {
        guard stagingContainer.lastPathComponent == VideoInputPreflight.stagingParentName,
              stagingRoot.deletingLastPathComponent().standardizedFileURL.path
                == stagingContainer.standardizedFileURL.path,
              VideoInputPreflight.isControlledRunLeaf(stagingRoot.lastPathComponent),
              let currentContainer = status(at: stagingContainer),
              containerEvidence.matchesDirectory(currentContainer),
              let currentRoot = status(at: stagingRoot),
              rootEvidence.matchesDirectory(currentRoot) else {
            throw stagingFailure(for: videos)
        }
        let expectedLeaves = Set(videos.map { $0.stagedURL.lastPathComponent })
        let actualLeaves = try Set(
            FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        )
        guard actualLeaves == expectedLeaves else {
            throw stagingFailure(for: videos)
        }
        for video in videos {
            guard video.stagedURL.deletingLastPathComponent().standardizedFileURL.path
                    == stagingRoot.standardizedFileURL.path,
                  let currentFile = status(at: video.stagedURL),
                  video.fileEvidence.matchesFile(currentFile) else {
                throw stagingFailure(for: videos)
            }
        }
    }

    private static func validateAdoptedRoot(
        originalsURL: URL,
        rootEvidence: VideoInputFileEvidence,
        videos: [Video]
    ) throws {
        guard let currentRoot = status(at: originalsURL),
              rootEvidence.matchesDirectory(currentRoot),
              Set(try FileManager.default.contentsOfDirectory(atPath: originalsURL.path))
                == Set(videos.map { $0.stagedURL.lastPathComponent }) else {
            throw stagingFailure(for: videos)
        }
        for video in videos {
            guard let currentFile = status(at: video.stagedURL),
                  video.fileEvidence.matchesFile(currentFile) else {
                throw stagingFailure(for: videos)
            }
        }
    }

    private static func renameValidatedStagingRoot(
        stagingContainer: URL,
        containerEvidence: VideoInputFileEvidence,
        stagingRoot: URL,
        rootEvidence: VideoInputFileEvidence,
        projectRoot: URL,
        originalsURL: URL,
        videos: [Video]
    ) throws {
        let sourceDirectory = Darwin.open(
            stagingContainer.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDirectory >= 0 else { throw stagingFailure(for: videos) }
        defer { Darwin.close(sourceDirectory) }
        let destinationDirectory = Darwin.open(
            projectRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDirectory >= 0 else { throw stagingFailure(for: videos) }
        defer { Darwin.close(destinationDirectory) }

        var sourceDirectoryStatus = stat()
        var destinationDirectoryStatus = stat()
        var sourceRootStatus = stat()
        guard fstat(sourceDirectory, &sourceDirectoryStatus) == 0,
              containerEvidence.matchesDirectory(sourceDirectoryStatus),
              sourceDirectoryStatus.st_dev == rootEvidence.device,
              fstat(destinationDirectory, &destinationDirectoryStatus) == 0,
              (destinationDirectoryStatus.st_mode & S_IFMT) == S_IFDIR,
              destinationDirectoryStatus.st_uid == getuid(),
              destinationDirectoryStatus.st_dev == rootEvidence.device else {
            throw stagingFailure(for: videos)
        }
        let sourceLeaf = stagingRoot.lastPathComponent
        let sourceStatusResult = sourceLeaf.withCString {
            fstatat(sourceDirectory, $0, &sourceRootStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceStatusResult == 0, rootEvidence.matchesDirectory(sourceRootStatus) else {
            throw stagingFailure(for: videos)
        }
        let destinationLeaf = originalsURL.lastPathComponent
        var existingDestination = stat()
        let destinationStatusResult = destinationLeaf.withCString {
            fstatat(destinationDirectory, $0, &existingDestination, AT_SYMLINK_NOFOLLOW)
        }
        guard destinationStatusResult != 0, errno == ENOENT else {
            throw stagingFailure(for: videos)
        }
        let renameResult = sourceLeaf.withCString { sourceName in
            destinationLeaf.withCString { destinationName in
                renameatx_np(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard renameResult == 0 else { throw stagingFailure(for: videos) }
        _ = fsync(sourceDirectory)
        _ = fsync(destinationDirectory)
    }

    private static func status(at url: URL) -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return value
    }

    private static func stagingFailure(for videos: [Video]) -> VideoInputPreflightFailure {
        VideoInputPreflightFailure(rejectedVideos: [VideoInputRejection(
            index: videos.first?.index ?? 0,
            safeDisplayName: videos.first?.safeDisplayName ?? "Video 1",
            issue: .stagingUnavailable
        )])
    }

    private static func integrityFailure(for videos: [Video]) -> VideoInputPreflightFailure {
        VideoInputPreflightFailure(rejectedVideos: [VideoInputRejection(
            index: videos.first?.index ?? 0,
            safeDisplayName: videos.first?.safeDisplayName ?? "Video 1",
            issue: .copyFailed
        )])
    }

    private static func capacityFailure(for videos: [Video]) -> VideoInputPreflightFailure {
        VideoInputPreflightFailure(rejectedVideos: [VideoInputRejection(
            index: videos.first?.index ?? 0,
            safeDisplayName: videos.first?.safeDisplayName ?? "Video 1",
            issue: .capacityUnavailable
        )])
    }

    private static func spaceFailure(
        for videos: [Video],
        required: Int64,
        available: Int64
    ) -> VideoInputPreflightFailure {
        VideoInputPreflightFailure(rejectedVideos: [VideoInputRejection(
            index: videos.first?.index ?? 0,
            safeDisplayName: videos.first?.safeDisplayName ?? "Video 1",
            issue: .insufficientSpace(required: required, available: available)
        )])
    }

    private static func syncDirectoryBestEffort(_ url: URL) {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = fsync(descriptor)
    }
}

public struct VideoInputPreflight: Sendable {
    typealias AvailableCapacity = @Sendable (URL) throws -> Int64
    typealias Analyze = @Sendable (
        URL,
        FrameExtractionOptions
    ) async throws -> VideoInputAnalysisEvidence
    typealias CloneSnapshot = @Sendable (Int32, Int32, String) throws -> Bool
    typealias ProjectionProbe = @Sendable (URL) async throws -> NativeVideoProjectionInspection?
    typealias MonitorFactory = @Sendable ([VnodeMutationMonitor.Watch]) throws -> VnodeMutationMonitor
    enum ContentPass: Equatable, Sendable {
        case streamingSourceCopyAndDigest
        case stagedOutputAuthentication
        case retainedCloneSourceAuthentication
    }
    typealias ContentPassObserver = @Sendable (ContentPass, URL) -> Void
    typealias DiscardBoundary = @Sendable (URL) -> Void

    static let stagingParentName = ".easysplat-input-staging"

    public let limits: VideoInputPreflightLimits
    private let availableCapacity: AvailableCapacity
    private let analyze: Analyze
    private let cloneSnapshot: CloneSnapshot
    private let projectionProbe: ProjectionProbe
    private let monitorFactory: MonitorFactory
    private let contentPassObserver: ContentPassObserver
    private let discardBoundary: DiscardBoundary

    /// Leaves room for selected-frame replacements and geometry/training checkpoints
    /// while preserving one full copy-sized overlap for atomic publication.
    public static func requiredAtomicWorkspaceReserveBytes(
        keyframeBudget: Int,
        maximumImageDimension: Int,
        maximumFeatureCount: Int = 8_192,
        maximumMatchCount: Int = 8_192,
        retrievalCandidateCount: Int = 20
    ) -> Int64 {
        let floor: Int64 = 4 * 1_024 * 1_024 * 1_024
        let trainerAtomicPublication: Int64 = 2 * 1_024 * 1_024 * 1_024
        guard keyframeBudget > 0,
              maximumImageDimension > 0,
              maximumFeatureCount > 0,
              maximumMatchCount > 0,
              retrievalCandidateCount > 0 else {
            return Int64.max
        }

        func product(_ values: [Int64]) -> Int64? {
            var result: Int64 = 1
            for value in values {
                let (next, overflow) = result.multipliedReportingOverflow(by: value)
                guard !overflow else { return nil }
                result = next
            }
            return result
        }
        func sum(_ values: [Int64]) -> Int64? {
            var result: Int64 = 0
            for value in values {
                let (next, overflow) = result.addingReportingOverflow(value)
                guard !overflow else { return nil }
                result = next
            }
            return result
        }

        let frames = Int64(keyframeBudget)
        let dimension = Int64(maximumImageDimension)
        let features = Int64(maximumFeatureCount)
        let matches = Int64(min(maximumFeatureCount, maximumMatchCount))
        let candidates = Int64(retrievalCandidateCount)
        guard let encodedFramePixels = product([frames, dimension, dimension]),
              let featureBytes = product([frames, features, 160]),
              let matchBytes = product([frames, candidates, matches, 8]) else {
            return Int64.max
        }
        // The accepted 250-frame/1600px proof measured about 0.16 encoded byte per
        // source pixel. Use 0.25 here, plus explicit COLMAP records and atomic trainer
        // publication, then apply a bounded 1.5x high-water margin.
        let selectedFrameBytes = encodedFramePixels / 4
        guard let measuredTerms = sum([
            selectedFrameBytes,
            featureBytes,
            matchBytes,
            trainerAtomicPublication,
        ]),
              let withHalfMargin = sum([measuredTerms, measuredTerms / 2]) else {
            return Int64.max
        }
        return max(floor, withHalfMargin)
    }

    public init(limits: VideoInputPreflightLimits = .init()) {
        self.init(
            limits: limits,
            availableCapacity: Self.defaultAvailableCapacity,
            analyze: Self.defaultAnalyze,
            cloneSnapshot: Self.defaultCloneSnapshot,
            projectionProbe: { try await NativeProjectionMetadataProbe.inspection(inVideoAt: $0) },
            monitorFactory: { try VnodeMutationMonitor(watches: $0) },
            contentPassObserver: { _, _ in },
            discardBoundary: { _ in }
        )
    }

    init(
        limits: VideoInputPreflightLimits,
        availableCapacity: @escaping AvailableCapacity,
        analyze: @escaping Analyze,
        cloneSnapshot: @escaping CloneSnapshot = Self.defaultCloneSnapshot,
        projectionProbe: @escaping ProjectionProbe = { _ in nil },
        monitorFactory: @escaping MonitorFactory = { try VnodeMutationMonitor(watches: $0) },
        contentPassObserver: @escaping ContentPassObserver = { _, _ in },
        discardBoundary: @escaping DiscardBoundary = { _ in }
    ) {
        self.limits = limits
        self.availableCapacity = availableCapacity
        self.analyze = analyze
        self.cloneSnapshot = cloneSnapshot
        self.projectionProbe = projectionProbe
        self.monitorFactory = monitorFactory
        self.contentPassObserver = contentPassObserver
        self.discardBoundary = discardBoundary
    }

    public func prepare(
        videoURLs: [URL],
        stagingParent: URL,
        requiredAtomicWorkspaceReserveBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        analysisPolicy: VideoFrameAnalysisPolicy = VideoFrameAnalysisPolicy(
            targetFrameCeiling: 1,
            targetFPS: 1
        ),
        pairingPolicy: ResolvedPairingPolicy = .orderedContinuous,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> PreparedVideoInput {
        try Task.checkCancellation()
        guard !videoURLs.isEmpty else {
            throw VideoInputPreflightFailure(
                rejectedVideos: [VideoInputRejection(
                    index: 0,
                    safeDisplayName: "Video 1",
                    issue: .noVideosSelected
                )]
            )
        }
        guard limits.isValid, analysisPolicy.isValid else {
            throw failure(index: 0, url: videoURLs[0], issue: .invalidLimits)
        }
        guard videoURLs.count <= limits.maximumVideoCount else {
            throw failure(
                index: limits.maximumVideoCount,
                url: videoURLs[limits.maximumVideoCount],
                issue: .tooManyVideos(maximum: limits.maximumVideoCount)
            )
        }
        guard requiredAtomicWorkspaceReserveBytes >= 0 else {
            throw failure(index: 0, url: videoURLs[0], issue: .invalidLimits)
        }

        let sources = try inspectSources(videoURLs)
        let reserve = max(
            limits.minimumFreeSpaceReserveBytes,
            requiredAtomicWorkspaceReserveBytes
        )
        let required = try checkedRequiredBytes(for: sources, reserve: reserve)
        let stagingContainer: URL
        do {
            stagingContainer = try Self.ensureStagingContainer(beside: stagingParent)
            try Self.cleanupStaleRuns(in: stagingContainer)
        } catch {
            throw failure(index: 0, url: videoURLs[0], issue: .stagingUnavailable)
        }
        let available: Int64
        do {
            available = try availableCapacity(stagingContainer)
        } catch {
            throw failure(index: 0, url: videoURLs[0], issue: .capacityUnavailable)
        }
        guard available >= 0 else {
            throw failure(index: 0, url: videoURLs[0], issue: .capacityUnavailable)
        }
        guard available >= required else {
            throw failure(
                index: 0,
                url: videoURLs[0],
                issue: .insufficientSpace(required: required, available: max(0, available))
            )
        }
        let stagingRoot: URL
        do {
            stagingRoot = try Self.createStagingRoot(in: stagingContainer)
        } catch {
            throw failure(index: 0, url: videoURLs[0], issue: .stagingUnavailable)
        }
        guard let cleanupContainerEvidence = Self.evidence(at: stagingContainer),
              let cleanupRootEvidence = Self.evidence(at: stagingRoot),
              cleanupContainerEvidence.isPrivateDirectory,
              cleanupRootEvidence.isPrivateDirectory else {
            throw failure(index: 0, url: videoURLs[0], issue: .stagingUnavailable)
        }
        var shouldClean = true
        defer {
            if shouldClean {
                try? Self.removeControlledRun(
                    at: stagingRoot,
                    in: stagingContainer,
                    expectedContainerEvidence: cleanupContainerEvidence,
                    expectedRootEvidence: cleanupRootEvidence
                )
            }
        }

        var snapshots: [Snapshot] = []
        snapshots.reserveCapacity(sources.count)
        for source in sources {
            try Task.checkCancellation()
            let fraction = Double(source.index) / Double(max(1, sources.count)) * 0.45
            progress(fraction, "Copying video \(source.index + 1) of \(sources.count)")
            do {
                snapshots.append(try copy(source, to: stagingRoot))
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as VideoInputPreflightFailure {
                throw failure
            } catch {
                throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
            }
        }
        do {
            try Self.syncDirectory(stagingRoot)
        } catch {
            throw failure(index: 0, url: videoURLs[0], issue: .stagingUnavailable)
        }
        guard let containerEvidence = Self.evidence(at: stagingContainer),
              let rootEvidence = Self.evidence(at: stagingRoot),
              containerEvidence.isPrivateDirectory,
              rootEvidence.isPrivateDirectory else {
            throw failure(index: 0, url: videoURLs[0], issue: .stagingUnavailable)
        }
        let rootEventDescriptor = Darwin.open(
            stagingRoot.path,
            O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
        )
        let rootMonitor: VnodeMutationMonitor?
        if rootEventDescriptor >= 0 {
            var monitoredRoot = stat()
            if fstat(rootEventDescriptor, &monitoredRoot) == 0,
               rootEvidence.matchesDirectory(monitoredRoot) {
                rootMonitor = try? monitorFactory([.init(
                    descriptor: rootEventDescriptor,
                    label: "staging-root",
                    ownership: .duplicated
                )])
            } else {
                rootMonitor = nil
            }
            Darwin.close(rootEventDescriptor)
        } else {
            rootMonitor = nil
        }
        guard rootMonitor != nil else {
            throw failure(index: 0, url: videoURLs[0], issue: .copyFailed)
        }
        let integrityLease = VideoInputIntegrityLease(
            rootURL: stagingRoot,
            rootEvidence: rootEvidence,
            snapshots: snapshots,
            rootMonitor: rootMonitor
        )

        var firstIndexByDigest: [String: Int] = [:]
        var duplicateRejections: [VideoInputRejection] = []
        for snapshot in snapshots {
            if let firstIndex = firstIndexByDigest[snapshot.sha256] {
                duplicateRejections.append(VideoInputRejection(
                    index: snapshot.source.index,
                    safeDisplayName: snapshot.source.safeDisplayName,
                    issue: .duplicateSource(firstIndex: firstIndex)
                ))
            } else {
                firstIndexByDigest[snapshot.sha256] = snapshot.source.index
            }
        }
        if !duplicateRejections.isEmpty {
            throw VideoInputPreflightFailure(rejectedVideos: duplicateRejections)
        }

        let analyses = try await analyzeSnapshots(
            snapshots,
            integrityLease: integrityLease,
            options: analysisPolicy.extractionOptions,
            maximumConcurrentDecoders: analysisPolicy.maximumConcurrentDecoders,
            progress: progress
        )
        let clipIdentities: [Int: VideoClipIdentity]
        do {
            clipIdentities = Dictionary(
                uniqueKeysWithValues: try VideoClipIdentityResolver.resolve(
                    sourceSHA256s: snapshots.map(\.sha256),
                    pairingPolicy: pairingPolicy
                ).map { ($0.sourceIndex, $0) }
            )
        } catch {
            throw failure(index: 0, url: videoURLs[0], issue: .sourceChanged)
        }
        let videos = zip(snapshots, analyses).map { snapshot, analysis in
            let clipIdentity = clipIdentities[snapshot.source.index]!
            return PreparedVideoInput.Video(
                index: snapshot.source.index,
                safeDisplayName: snapshot.source.safeDisplayName,
                stagedURL: snapshot.url,
                byteCount: snapshot.source.size,
                sha256: snapshot.sha256,
                analysis: analysis,
                clipGroupID: clipIdentity.groupID,
                analysisPolicy: analysisPolicy,
                fileEvidence: snapshot.fileEvidence
            )
        }
        progress(1, "Videos are ready")
        shouldClean = false
        return PreparedVideoInput(
            stagingContainer: stagingContainer,
            containerEvidence: containerEvidence,
            stagingRoot: stagingRoot,
            rootEvidence: rootEvidence,
            videos: videos,
            requiredFreeBytesAtAdoption: reserve,
            availableCapacity: availableCapacity,
            integrityLease: integrityLease,
            discardBoundary: discardBoundary,
            monitorFactory: monitorFactory
        )
    }

    fileprivate struct Source: Sendable {
        let index: Int
        let url: URL
        let safeDisplayName: String
        let device: dev_t
        let inode: ino_t
        let linkCount: nlink_t
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let controlledExtension: String
    }

    fileprivate struct Snapshot: Sendable {
        let source: Source
        let url: URL
        let sha256: String
        let fileEvidence: VideoInputFileEvidence
        let fileMonitor: VnodeMutationMonitor?
    }

    private func inspectSources(_ urls: [URL]) throws -> [Source] {
        var sources: [Source] = []
        var identities: [FileIdentity: Int] = [:]
        var total: Int64 = 0
        var rejections: [VideoInputRejection] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let source: Source
            do {
                source = try inspectSource(url, index: index)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as VideoInputPreflightFailure {
                rejections.append(contentsOf: failure.rejectedVideos)
                continue
            } catch {
                rejections.append(VideoInputRejection(
                    index: index,
                    safeDisplayName: Self.safeDisplayName(for: url, fallbackIndex: index),
                    issue: .sourceUnavailable
                ))
                continue
            }
            let identity = FileIdentity(device: source.device, inode: source.inode)
            if let firstIndex = identities[identity] {
                rejections.append(VideoInputRejection(
                    index: index,
                    safeDisplayName: source.safeDisplayName,
                    issue: .duplicateSource(firstIndex: firstIndex)
                ))
                continue
            }
            identities[identity] = index
            let (nextTotal, overflow) = total.addingReportingOverflow(source.size)
            if overflow || nextTotal > limits.maximumTotalBytes {
                rejections.append(VideoInputRejection(
                    index: index,
                    safeDisplayName: source.safeDisplayName,
                    issue: .totalBytesExceeded(maximum: limits.maximumTotalBytes)
                ))
                continue
            }
            total = nextTotal
            sources.append(source)
        }
        if !rejections.isEmpty {
            throw VideoInputPreflightFailure(
                rejectedVideos: rejections.sorted { $0.index < $1.index }
            )
        }
        return sources
    }

    /// Separates a refused read from a file that is gone. `errno` is the only
    /// evidence that tells them apart, so read it before any other system call.
    /// The sandbox refuses a source once the grant that came with the user's
    /// selection lapses, and "the file is no longer available" sends the user
    /// looking for a missing file that is still where they left it.
    private static func issueForFailedCall(
        otherwise fallback: @autoclosure () -> VideoInputPreflightIssue
    ) -> VideoInputPreflightIssue {
        let code = errno
        guard code == EACCES || code == EPERM else { return fallback() }
        return .accessDenied
    }

    private func inspectSource(_ url: URL, index: Int) throws -> Source {
        let name = Self.safeDisplayName(for: url, fallbackIndex: index)
        var pathStatus = stat()
        guard url.isFileURL else {
            throw failure(index: index, name: name, issue: .sourceUnavailable)
        }
        guard lstat(url.path, &pathStatus) == 0 else {
            throw failure(
                index: index,
                name: name,
                issue: Self.issueForFailedCall(otherwise: .sourceUnavailable)
            )
        }
        if (pathStatus.st_mode & S_IFMT) == S_IFLNK {
            throw failure(index: index, name: name, issue: .symbolicLink)
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFREG else {
            throw failure(index: index, name: name, issue: .notRegularFile)
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw failure(
                index: index,
                name: name,
                issue: Self.issueForFailedCall(otherwise: .sourceUnavailable)
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_dev == pathStatus.st_dev,
              status.st_ino == pathStatus.st_ino,
              status.st_nlink > 0 else {
            throw failure(index: index, name: name, issue: .sourceChanged)
        }
        guard status.st_size > 0 else {
            throw failure(index: index, name: name, issue: .emptyFile)
        }
        return Source(
            index: index,
            url: url,
            safeDisplayName: name,
            device: status.st_dev,
            inode: status.st_ino,
            linkCount: status.st_nlink,
            size: status.st_size,
            modifiedSeconds: status.st_mtimespec.tv_sec,
            modifiedNanoseconds: status.st_mtimespec.tv_nsec,
            changedSeconds: status.st_ctimespec.tv_sec,
            changedNanoseconds: status.st_ctimespec.tv_nsec,
            controlledExtension: Self.controlledExtension(for: url)
        )
    }

    private func checkedRequiredBytes(for sources: [Source], reserve: Int64) throws -> Int64 {
        let total = sources.reduce(into: Int64(0)) { $0 += $1.size }
        let (required, overflow) = total.addingReportingOverflow(reserve)
        guard !overflow else {
            throw failure(
                index: 0,
                name: sources[0].safeDisplayName,
                issue: .insufficientSpace(required: Int64.max, available: 0)
            )
        }
        return required
    }

    private func copy(_ source: Source, to stagingRoot: URL) throws -> Snapshot {
        let input = Darwin.open(
            source.url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard input >= 0 else {
            throw failure(
                index: source.index,
                name: source.safeDisplayName,
                issue: Self.issueForFailedCall(otherwise: .sourceUnavailable)
            )
        }
        defer { Darwin.close(input) }
        var initial = stat()
        guard fstat(input, &initial) == 0, Self.matches(initial, source: source) else {
            throw failure(index: source.index, name: source.safeDisplayName, issue: .sourceChanged)
        }
        let leaf = String(format: "video-%04d.%@", source.index, source.controlledExtension)
        let destination = stagingRoot.appendingPathComponent(leaf)
        let stagingDescriptor = Darwin.open(
            stagingRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard stagingDescriptor >= 0 else {
            throw failure(index: source.index, name: source.safeDisplayName, issue: .stagingUnavailable)
        }
        defer { Darwin.close(stagingDescriptor) }
        var stagingStatus = stat()
        guard fstat(stagingDescriptor, &stagingStatus) == 0,
              VideoInputFileEvidence(stagingStatus).isPrivateDirectory else {
            throw failure(index: source.index, name: source.safeDisplayName, issue: .stagingUnavailable)
        }

        let cloned: Bool
        do {
            cloned = try cloneSnapshot(input, stagingDescriptor, leaf)
        } catch {
            throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
        }
        let outputFlags = cloned
            ? O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            : O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let output = leaf.withCString {
            openat(stagingDescriptor, $0, outputFlags, S_IRUSR | S_IWUSR)
        }
        guard output >= 0 else {
            throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
        }
        defer { Darwin.close(output) }

        var copiedBytes: Int64 = 0
        var copiedSourceHasher = SHA256()
        var fileMonitor: VnodeMutationMonitor?
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        do {
            if !cloned {
                contentPassObserver(.streamingSourceCopyAndDigest, source.url)
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(input, $0.baseAddress, $0.count)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else {
                        throw failure(index: source.index, name: source.safeDisplayName, issue: .sourceChanged)
                    }
                    if count == 0 { break }
                    copiedSourceHasher.update(data: Data(buffer[0..<count]))
                    copiedBytes += Int64(count)
                    guard copiedBytes <= source.size else {
                        throw failure(
                            index: source.index,
                            name: source.safeDisplayName,
                            issue: .sourceChanged
                        )
                    }
                    var written = 0
                    while written < count {
                        try Task.checkCancellation()
                        let result = buffer.withUnsafeBytes {
                            Darwin.write(
                                output,
                                $0.baseAddress?.advanced(by: written),
                                count - written
                            )
                        }
                        if result < 0 && errno == EINTR { continue }
                        guard result > 0 else {
                            throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
                        }
                        written += result
                    }
                }
            }
            try Task.checkCancellation()
            guard fchmod(output, S_IRUSR | S_IWUSR) == 0,
                  fsync(output) == 0 else {
                throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
            }
            var finalSource = stat()
            var finalPath = stat()
            var copied = stat()
            guard fstat(input, &finalSource) == 0,
                  lstat(source.url.path, &finalPath) == 0,
                  fstat(output, &copied) == 0,
                  Self.matches(finalSource, source: source),
                  Self.matches(finalPath, source: source),
                  cloned || copiedBytes == source.size,
                  (copied.st_mode & S_IFMT) == S_IFREG,
                  copied.st_nlink == 1,
                  copied.st_size == source.size,
                  copied.st_dev == stagingStatus.st_dev,
                  copied.st_mode & mode_t(0o7777) == mode_t(S_IRUSR | S_IWUSR) else {
                throw failure(index: source.index, name: source.safeDisplayName, issue: .sourceChanged)
            }

            guard lseek(output, 0, SEEK_SET) == 0 else {
                throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
            }
            let eventDescriptor = leaf.withCString {
                openat(stagingDescriptor, $0, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            if eventDescriptor >= 0 {
                var outputStatus = stat()
                var monitoredStatus = stat()
                if fstat(output, &outputStatus) == 0,
                   fstat(eventDescriptor, &monitoredStatus) == 0,
                   outputStatus.st_dev == monitoredStatus.st_dev,
                   outputStatus.st_ino == monitoredStatus.st_ino {
                    fileMonitor = try? monitorFactory([.init(
                        descriptor: eventDescriptor,
                        label: "video-\(source.index)",
                        ownership: .duplicated
                    )])
                }
                Darwin.close(eventDescriptor)
            }
        } catch {
            _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
            throw error
        }

        guard let fileMonitor else {
            _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
            throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
        }
        contentPassObserver(.stagedOutputAuthentication, destination)
        var stagedOutputHasher = SHA256()
        var hashedBytes: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(output, $0.baseAddress, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else {
                    throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
                }
                if count == 0 { break }
                hashedBytes += Int64(count)
                guard hashedBytes <= source.size else {
                    throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
                }
                stagedOutputHasher.update(data: Data(buffer[0..<count]))
            }
            var finalSource = stat()
            var finalPath = stat()
            guard hashedBytes == source.size,
                  fstat(input, &finalSource) == 0,
                  lstat(source.url.path, &finalPath) == 0,
                  Self.matches(finalSource, source: source),
                  Self.matches(finalPath, source: source) else {
                throw failure(index: source.index, name: source.safeDisplayName, issue: .sourceChanged)
            }
        } catch {
            _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
            throw error
        }
        let stagedOutputDigest = stagedOutputHasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        if cloned {
            guard lseek(input, 0, SEEK_SET) == 0 else {
                fileMonitor.close()
                _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
                throw failure(index: source.index, name: source.safeDisplayName, issue: .sourceChanged)
            }
            contentPassObserver(.retainedCloneSourceAuthentication, source.url)
            var retainedSourceHasher = SHA256()
            var sourceHashedBytes: Int64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(input, $0.baseAddress, $0.count)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else {
                        throw failure(
                            index: source.index,
                            name: source.safeDisplayName,
                            issue: .sourceChanged
                        )
                    }
                    if count == 0 { break }
                    sourceHashedBytes += Int64(count)
                    guard sourceHashedBytes <= source.size else {
                        throw failure(
                            index: source.index,
                            name: source.safeDisplayName,
                            issue: .sourceChanged
                        )
                    }
                    retainedSourceHasher.update(data: Data(buffer[0..<count]))
                }
                var finalSource = stat()
                var finalPath = stat()
                guard sourceHashedBytes == source.size,
                      fstat(input, &finalSource) == 0,
                      lstat(source.url.path, &finalPath) == 0,
                      Self.matches(finalSource, source: source),
                      Self.matches(finalPath, source: source) else {
                    throw failure(
                        index: source.index,
                        name: source.safeDisplayName,
                        issue: .sourceChanged
                    )
                }
            } catch {
                fileMonitor.close()
                _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
                throw error
            }
            let retainedSourceDigest = retainedSourceHasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            guard retainedSourceDigest == stagedOutputDigest else {
                fileMonitor.close()
                _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
                throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
            }
        } else {
            let copiedSourceDigest = copiedSourceHasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            guard copiedSourceDigest == stagedOutputDigest else {
                fileMonitor.close()
                _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
                throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
            }
        }
        var openedOutput = stat()
        var namedOutput = stat()
        let namedResult = leaf.withCString {
            fstatat(stagingDescriptor, $0, &namedOutput, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(output, &openedOutput) == 0, namedResult == 0 else {
            throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
        }
        let fileEvidence = VideoInputFileEvidence(openedOutput)
        guard fileEvidence.isPrivateRegularFile,
              fileEvidence.matchesFile(namedOutput) else {
            if openedOutput.st_dev == namedOutput.st_dev,
               openedOutput.st_ino == namedOutput.st_ino {
                _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
            }
            throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
        }
        guard fileMonitor.poll().isTrustworthy else {
            fileMonitor.close()
            _ = leaf.withCString { unlinkat(stagingDescriptor, $0, 0) }
            throw failure(index: source.index, name: source.safeDisplayName, issue: .copyFailed)
        }
        return Snapshot(
            source: source,
            url: destination,
            sha256: stagedOutputDigest,
            fileEvidence: fileEvidence,
            fileMonitor: fileMonitor
        )
    }

    private func analyzeSnapshots(
        _ snapshots: [Snapshot],
        integrityLease: VideoInputIntegrityLease,
        options: FrameExtractionOptions,
        maximumConcurrentDecoders: Int,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [VideoInputAnalysisEvidence] {
        enum Result: Sendable {
            case accepted(index: Int, evidence: VideoInputAnalysisEvidence)
            case rejected(VideoInputRejection)
        }
        let concurrency = min(
            limits.maximumConcurrentDecoders,
            maximumConcurrentDecoders,
            snapshots.count
        )
        return try await withThrowingTaskGroup(
            of: Result.self,
            returning: [VideoInputAnalysisEvidence].self
        ) { group in
            var nextIndex = 0
            var results = [VideoInputAnalysisEvidence?](repeating: nil, count: snapshots.count)
            var rejections: [VideoInputRejection] = []
            func submit(_ index: Int) {
                let snapshot = snapshots[index]
                group.addTask {
                    do {
                        guard integrityLease.validates(snapshot) else {
                            return .rejected(VideoInputRejection(
                                index: snapshot.source.index,
                                safeDisplayName: snapshot.source.safeDisplayName,
                                issue: .copyFailed
                            ))
                        }
                        let projectionInspection = try await projectionProbe(snapshot.url)
                        guard integrityLease.validates(snapshot) else {
                            return .rejected(VideoInputRejection(
                                index: snapshot.source.index,
                                safeDisplayName: snapshot.source.safeDisplayName,
                                issue: .copyFailed
                            ))
                        }
                        if let projectionTag = projectionInspection?.tag {
                            return .rejected(VideoInputRejection(
                                index: snapshot.source.index,
                                safeDisplayName: snapshot.source.safeDisplayName,
                                issue: .unsupportedSpherical(.init(tag: projectionTag))
                            ))
                        }
                        let evidence = try await analyze(snapshot.url, options)
                        guard integrityLease.validates(snapshot) else {
                            return .rejected(VideoInputRejection(
                                index: snapshot.source.index,
                                safeDisplayName: snapshot.source.safeDisplayName,
                                issue: .copyFailed
                            ))
                        }
                        guard Self.analysisEvidenceIsValid(evidence),
                              projectionInspection.map({ evidence.trackID == $0.primaryTrackID })
                                ?? true else {
                            return .rejected(VideoInputRejection(
                                index: snapshot.source.index,
                                safeDisplayName: snapshot.source.safeDisplayName,
                                issue: .unreadableMedia
                            ))
                        }
                        return .accepted(index: index, evidence: evidence)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let extraction as FrameExtractor.ExtractionError {
                        guard integrityLease.validates(snapshot) else {
                            return .rejected(VideoInputRejection(
                                index: snapshot.source.index,
                                safeDisplayName: snapshot.source.safeDisplayName,
                                issue: .copyFailed
                            ))
                        }
                        let issue: VideoInputPreflightIssue
                        switch extraction {
                        case .invalidVideo:
                            issue = .noUsableVideoTrack
                        case .extractionFailed:
                            issue = .decodeFailed
                        }
                        return .rejected(VideoInputRejection(
                            index: snapshot.source.index,
                            safeDisplayName: snapshot.source.safeDisplayName,
                            issue: issue
                        ))
                    } catch {
                        guard integrityLease.validates(snapshot) else {
                            return .rejected(VideoInputRejection(
                                index: snapshot.source.index,
                                safeDisplayName: snapshot.source.safeDisplayName,
                                issue: .copyFailed
                            ))
                        }
                        return .rejected(VideoInputRejection(
                            index: snapshot.source.index,
                            safeDisplayName: snapshot.source.safeDisplayName,
                            issue: .unreadableMedia
                        ))
                    }
                }
            }
            while nextIndex < concurrency {
                submit(nextIndex)
                nextIndex += 1
            }
            while let result = try await group.next() {
                switch result {
                case .accepted(let index, let evidence):
                    results[index] = evidence
                case .rejected(let rejection):
                    rejections.append(rejection)
                }
                let completed = results.compactMap { $0 }.count + rejections.count
                progress(
                    0.45 + 0.55 * Double(completed) / Double(snapshots.count),
                    "Checking video \(completed) of \(snapshots.count)"
                )
                if nextIndex < snapshots.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
            if !rejections.isEmpty {
                throw VideoInputPreflightFailure(
                    rejectedVideos: rejections.sorted { $0.index < $1.index }
                )
            }
            return try results.map { value in
                guard let value else { throw CancellationError() }
                return value
            }
        }
    }

    private static func analysisEvidenceIsValid(_ evidence: VideoInputAnalysisEvidence) -> Bool {
        let transform = evidence.preferredTransform
        let determinant = transform.a * transform.d - transform.b * transform.c
        return evidence.trackID > 0
            && (1...131_072).contains(evidence.pixelWidth)
            && (1...131_072).contains(evidence.pixelHeight)
            && evidence.durationSeconds.isFinite
            && evidence.durationSeconds > 0
            && evidence.nominalFrameRate.isFinite
            && evidence.nominalFrameRate >= 0
            && evidence.decodedFrameCount > 0
            && !evidence.candidates.isEmpty
            && evidence.candidates.count <= evidence.decodedFrameCount
            && evidence.candidates.allSatisfy { candidate in
                candidate.frameIndex >= 0
                    && candidate.frameIndex < evidence.decodedFrameCount
                    && candidate.timestampSeconds.isFinite
                    && candidate.timestampSeconds >= 0
                    && candidate.candidate.index == candidate.frameIndex
                    && candidate.candidate.sharpness.isFinite
                    && candidate.candidate.sharpness >= 0
                    && candidate.candidate.brightness.isFinite
                    && (0...1).contains(candidate.candidate.brightness)
                    && candidate.candidate.clippedFraction.isFinite
                    && (0...1).contains(candidate.candidate.clippedFraction)
                    && candidate.candidate.motionScore.isFinite
                    && (0...1).contains(candidate.candidate.motionScore)
            }
            && [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                .allSatisfy(\.isFinite)
            && determinant.isFinite
            && abs(determinant) > 1e-12
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func matches(_ status: stat, source: Source) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_dev == source.device
            && status.st_ino == source.inode
            && status.st_nlink == source.linkCount
            && status.st_size == source.size
            && status.st_mtimespec.tv_sec == source.modifiedSeconds
            && status.st_mtimespec.tv_nsec == source.modifiedNanoseconds
            && status.st_ctimespec.tv_sec == source.changedSeconds
            && status.st_ctimespec.tv_nsec == source.changedNanoseconds
    }

    private static func ensureStagingContainer(beside parent: URL) throws -> URL {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var literalParentStatus = stat()
        guard lstat(parent.path, &literalParentStatus) == 0,
              (literalParentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw currentPOSIXError()
        }
        guard let canonicalPointer = realpath(parent.path, nil) else {
            throw currentPOSIXError()
        }
        defer { free(canonicalPointer) }
        let canonicalParent = URL(fileURLWithPath: String(cString: canonicalPointer))
        let parentDescriptor = try openDirectoryChain(canonicalParent)
        defer { Darwin.close(parentDescriptor) }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              parentStatus.st_dev == literalParentStatus.st_dev,
              parentStatus.st_ino == literalParentStatus.st_ino,
              parentStatus.st_uid == getuid(),
              parentStatus.st_nlink >= 1,
              parentStatus.st_mode & mode_t(0o022) == 0 else {
            throw currentPOSIXError()
        }
        let container = parent.appendingPathComponent(stagingParentName, isDirectory: true)
        let createResult = stagingParentName.withCString {
            mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        if createResult != 0, errno != EEXIST {
            throw currentPOSIXError()
        }
        let descriptor = stagingParentName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              status.st_nlink >= 1,
              fchmod(descriptor, S_IRWXU) == 0,
              fsync(parentDescriptor) == 0 else {
            throw currentPOSIXError()
        }
        return container
    }

    private static func openDirectoryChain(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            for component in url.pathComponents where component != "/" {
                let next = component.withCString {
                    openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else { throw currentPOSIXError() }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func createStagingRoot(in container: URL) throws -> URL {
        for _ in 0..<8 {
            let root = container.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
            if mkdir(root.path, S_IRWXU) == 0 {
                try syncDirectory(container)
                return root
            }
            if errno != EEXIST { throw posixError(path: root.path) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func cleanupStaleRuns(in container: URL) throws {
        let expiration = Date().addingTimeInterval(-24 * 60 * 60)
        let entries = try FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: []
        )
        var removed = 0
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard removed < 4,
                  isControlledRunLeaf(entry.lastPathComponent),
                  let evidence = evidence(at: entry),
                  evidence.isPrivateDirectory,
                  Date(timeIntervalSince1970: TimeInterval(evidence.modifiedSeconds)) < expiration else {
                continue
            }
            do {
                try removeControlledRun(at: entry, in: container)
                removed += 1
            } catch {
                continue
            }
        }
    }

    fileprivate static func removeControlledRun(
        at root: URL,
        in container: URL,
        expectedContainerEvidence: VideoInputFileEvidence? = nil,
        expectedRootEvidence: VideoInputFileEvidence? = nil
    ) throws {
        guard root.deletingLastPathComponent().standardizedFileURL.path
                == container.standardizedFileURL.path,
              isControlledRunLeaf(root.lastPathComponent) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let containerDescriptor = Darwin.open(
            container.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard containerDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(containerDescriptor) }
        var containerStatus = stat()
        guard fstat(containerDescriptor, &containerStatus) == 0,
              VideoInputFileEvidence(containerStatus).isPrivateDirectory,
              expectedContainerEvidence?.matchesDirectory(containerStatus) != false else {
            throw currentPOSIXError()
        }
        let rootDescriptor = root.lastPathComponent.withCString {
            openat(
                containerDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              VideoInputFileEvidence(rootStatus).isPrivateDirectory,
              expectedRootEvidence?.matchesDirectory(rootStatus) != false else {
            throw currentPOSIXError()
        }

        let leaves = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard leaves.count <= 64, leaves.allSatisfy(isControlledVideoLeaf) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for leaf in leaves {
            var status = stat()
            let statusResult = leaf.withCString {
                fstatat(rootDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0,
                  VideoInputFileEvidence(status).isPrivateRegularFile else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let unlinkResult = leaf.withCString { unlinkat(rootDescriptor, $0, 0) }
            guard unlinkResult == 0 else { throw currentPOSIXError() }
        }

        var reboundRootStatus = stat()
        let rebindResult = root.lastPathComponent.withCString {
            fstatat(containerDescriptor, $0, &reboundRootStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard rebindResult == 0,
              reboundRootStatus.st_dev == rootStatus.st_dev,
              reboundRootStatus.st_ino == rootStatus.st_ino else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let removeResult = root.lastPathComponent.withCString {
            unlinkat(containerDescriptor, $0, AT_REMOVEDIR)
        }
        guard removeResult == 0 else { throw currentPOSIXError() }
        guard fsync(containerDescriptor) == 0 else { throw currentPOSIXError() }
    }

    private static func isControlledVideoLeaf(_ leaf: String) -> Bool {
        guard leaf.hasPrefix("video-"),
              let dot = leaf.firstIndex(of: ".") else { return false }
        let digits = leaf[leaf.index(leaf.startIndex, offsetBy: 6)..<dot]
        let fileExtension = leaf[leaf.index(after: dot)...]
        return digits.utf8.count == 4
            && digits.utf8.allSatisfy { (48...57).contains($0) }
            && !fileExtension.isEmpty
            && fileExtension.utf8.count <= 8
            && fileExtension.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 97 && scalar.value <= 122)
            }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    fileprivate static func isControlledRunLeaf(_ leaf: String) -> Bool {
        guard leaf.hasPrefix("run-") else { return false }
        return UUID(uuidString: String(leaf.dropFirst(4))) != nil
    }

    private static func evidence(at url: URL) -> VideoInputFileEvidence? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return VideoInputFileEvidence(status)
    }

    private static func defaultAvailableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return try provenAvailableCapacity(
            ordinary: values.volumeAvailableCapacity.map(Int64.init),
            important: values.volumeAvailableCapacityForImportantUsage
        )
    }

    static func provenAvailableCapacity(
        ordinary: Int64?,
        important: Int64?
    ) throws -> Int64 {
        guard let ordinary,
              let important,
              ordinary >= 0,
              important >= 0 else {
            throw VideoInputCapacityEvidenceError.unavailable
        }
        return min(ordinary, important)
    }

    private static func defaultCloneSnapshot(
        sourceDescriptor: Int32,
        destinationDirectoryDescriptor: Int32,
        destinationLeaf: String
    ) throws -> Bool {
        let result = destinationLeaf.withCString {
            fclonefileat(
                sourceDescriptor,
                destinationDirectoryDescriptor,
                $0,
                UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
            )
        }
        if result == 0 { return true }
        let code = errno
        switch code {
        case EXDEV, ENOTSUP, ENOSYS:
            return false
        default:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private static func defaultAnalyze(
        url: URL,
        options: FrameExtractionOptions
    ) async throws -> VideoInputAnalysisEvidence {
        let analysis = try await FrameExtractor().analyze(
            url,
            options: options,
            progress: { _, _ in }
        )
        return VideoInputAnalysisEvidence(
            trackID: analysis.primaryTrack.trackID,
            pixelWidth: analysis.primaryTrack.width,
            pixelHeight: analysis.primaryTrack.height,
            durationSeconds: analysis.durationSeconds,
            nominalFrameRate: analysis.primaryTrack.nominalFrameRate,
            isHDR: analysis.primaryTrack.isHDR,
            decodedFrameCount: analysis.decodedFrameCount,
            preferredTransform: analysis.preferredTransform,
            candidates: analysis.candidates,
            hadRepairedTimestamps: analysis.hadRepairedTimestamps
        )
    }

    static func safeDisplayName(for url: URL, fallbackIndex: Int) -> String {
        let raw = url.lastPathComponent
        var output = ""
        var previousWasSpace = false
        for scalar in raw.unicodeScalars {
            let unsafe = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
            if unsafe || CharacterSet.newlines.contains(scalar) {
                if !previousWasSpace { output.append(" ") }
                previousWasSpace = true
            } else {
                output.unicodeScalars.append(scalar)
                previousWasSpace = scalar.properties.isWhitespace
            }
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(trimmed.prefix(96))
        return bounded.isEmpty ? "Video \(fallbackIndex + 1)" : bounded
    }

    private static func controlledExtension(for url: URL) -> String {
        let candidate = url.pathExtension.lowercased()
        guard !candidate.isEmpty,
              candidate.utf8.count <= 8,
              candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return "media"
        }
        return candidate
    }
}

private func failure(
    index: Int,
    url: URL,
    issue: VideoInputPreflightIssue
) -> VideoInputPreflightFailure {
    failure(
        index: index,
        name: VideoInputPreflight.safeDisplayName(for: url, fallbackIndex: index),
        issue: issue
    )
}

private func failure(
    index: Int,
    name: String,
    issue: VideoInputPreflightIssue
) -> VideoInputPreflightFailure {
    VideoInputPreflightFailure(
        rejectedVideos: [VideoInputRejection(
            index: index,
            safeDisplayName: name,
            issue: issue
        )]
    )
}

private func posixError(path: String) -> Error {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSFilePathErrorKey: path]
    )
}

private func currentPOSIXError() -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}
