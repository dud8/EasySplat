import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PhotoInputPreflightLimits: Equatable, Sendable {
    public var maximumPhotoCount: Int
    public var maximumTotalBytes: Int64
    public var maximumSinglePhotoBytes: Int64
    public var maximumPixelCount: Int64
    public var maximumDecodedDimension: Int
    public var maximumTraversalEntryCount: Int
    public var maximumRecursionDepth: Int
    public var minimumFreeSpaceReserveBytes: Int64

    public init(
        maximumPhotoCount: Int = 10_000,
        maximumTotalBytes: Int64 = 256 * 1_024 * 1_024 * 1_024,
        maximumSinglePhotoBytes: Int64 = 512 * 1_024 * 1_024,
        maximumPixelCount: Int64 = 250_000_000,
        maximumDecodedDimension: Int = 4_096,
        maximumTraversalEntryCount: Int = 50_000,
        maximumRecursionDepth: Int = 64,
        minimumFreeSpaceReserveBytes: Int64 = 1_024 * 1_024 * 1_024
    ) {
        self.maximumPhotoCount = maximumPhotoCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumSinglePhotoBytes = min(maximumSinglePhotoBytes, maximumTotalBytes)
        self.maximumPixelCount = maximumPixelCount
        self.maximumDecodedDimension = maximumDecodedDimension
        self.maximumTraversalEntryCount = maximumTraversalEntryCount
        self.maximumRecursionDepth = maximumRecursionDepth
        self.minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes
    }

    fileprivate var isValid: Bool {
        maximumPhotoCount > 0
            && maximumTotalBytes > 0
            && maximumSinglePhotoBytes > 0
            && maximumSinglePhotoBytes <= maximumTotalBytes
            && maximumPixelCount > 0
            && maximumDecodedDimension > 0
            && maximumDecodedDimension <= 8_192
            && maximumTraversalEntryCount >= maximumPhotoCount
            && maximumRecursionDepth > 0
            && maximumRecursionDepth <= 256
            && minimumFreeSpaceReserveBytes >= 0
    }
}

public enum PhotoInputPreflightIssue: Equatable, Sendable {
    case folderUnavailable
    case accessDenied(relativePath: String)
    case symbolicLink(relativePath: String)
    case unreadableEntry(relativePath: String)
    case sourceChanged(relativePath: String)
    case tooManyPhotos(maximum: Int)
    case totalBytesExceeded(maximum: Int64)
    case noValidPhotos
    case useAllExceedsBudget(selected: Int, maximum: Int)
    case insufficientSpace(required: Int64, available: Int64)
    case capacityUnavailable
    case traversalLimitExceeded
    case invalidLimits
    case stagingUnavailable
    case copyFailed(relativePath: String)
    case unsupportedSpherical(UnsupportedSphericalMediaIssue)
}

public struct PhotoInputPreflightFailure: Error, Equatable, Sendable {
    public let issue: PhotoInputPreflightIssue

    public init(issue: PhotoInputPreflightIssue) {
        self.issue = issue
    }
}

/// Classifies the file-system call that just failed. `errno` is the only thing
/// that separates a refused read from a file that moved or changed underneath
/// us, and the two need opposite answers: one is fixed by picking the photos
/// again, the other by leaving them alone. Call this before any other system
/// call, which would overwrite `errno`.
private func photoIssueForFailedCall(
    relativePath: String,
    otherwise fallback: @autoclosure () -> PhotoInputPreflightIssue
) -> PhotoInputPreflightIssue {
    let code = errno
    guard code == EACCES || code == EPERM else { return fallback() }
    return .accessDenied(relativePath: relativePath)
}

private struct PhotoFileEvidence: Equatable, Sendable {
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

    func matches(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == (mode & S_IFMT)
            && status.st_dev == device
            && status.st_ino == inode
            && status.st_nlink == linkCount
            && status.st_size == size
            && status.st_mtimespec.tv_sec == modifiedSeconds
            && status.st_mtimespec.tv_nsec == modifiedNanoseconds
            && status.st_ctimespec.tv_sec == changedSeconds
            && status.st_ctimespec.tv_nsec == changedNanoseconds
    }

    func matchesDirectory(_ status: stat) -> Bool {
        isPrivateDirectory
            && (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_dev == device
            && status.st_ino == inode
            && status.st_uid == owner
            && status.st_mode & mode_t(0o7777) == mode_t(0o700)
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
}

public final class PreparedPhotoInput: @unchecked Sendable {
    public struct Photo: Equatable, Sendable {
        public let safeDisplayName: String
        public let stagedURL: URL
        public let byteCount: Int64
        public let sha256: String
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let orientation: Int
        public let typeIdentifier: String
        public let source: PhotoSourceProvenance
        public let importMode: PhotoImportMode
        public let analysisEvidence: PhotoAnalysisEvidence
        public let retainedRank: Int
        fileprivate let fileEvidence: PhotoFileEvidence

        fileprivate func replacingURL(_ url: URL) -> Photo {
            Photo(
                safeDisplayName: safeDisplayName,
                stagedURL: url,
                byteCount: byteCount,
                sha256: sha256,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                orientation: orientation,
                typeIdentifier: typeIdentifier,
                source: source,
                importMode: importMode,
                analysisEvidence: analysisEvidence,
                retainedRank: retainedRank,
                fileEvidence: fileEvidence
            )
        }
    }

    public let stagingRoot: URL
    public let photos: [Photo]
    public let summary: PhotoInputPreflight
    public let selectionArtifact: PhotoSelectionArtifact
    private let stagingContainer: URL
    private let containerEvidence: PhotoFileEvidence
    private let rootEvidence: PhotoFileEvidence
    private let requiredFreeBytesAtAdoption: Int64
    private let availableCapacity: @Sendable (URL) throws -> Int64
    private let lock = NSLock()
    private var state = State.active
    private var adoptedPhotos: [Photo]?

    private enum State { case active, adopting, adopted, discarded }

    fileprivate init(
        stagingContainer: URL,
        containerEvidence: PhotoFileEvidence,
        stagingRoot: URL,
        rootEvidence: PhotoFileEvidence,
        photos: [Photo],
        summary: PhotoInputPreflight,
        selectionArtifact: PhotoSelectionArtifact,
        requiredFreeBytesAtAdoption: Int64,
        availableCapacity: @escaping @Sendable (URL) throws -> Int64
    ) {
        self.stagingContainer = stagingContainer
        self.containerEvidence = containerEvidence
        self.stagingRoot = stagingRoot
        self.rootEvidence = rootEvidence
        self.photos = photos
        self.summary = summary
        self.selectionArtifact = selectionArtifact
        self.requiredFreeBytesAtAdoption = requiredFreeBytesAtAdoption
        self.availableCapacity = availableCapacity
    }

    deinit { discard() }

    public func discard() {
        let mayDiscard = lock.withLock { () -> Bool in
            guard state == .active else { return false }
            state = .discarded
            return true
        }
        guard mayDiscard else { return }
        try? Self.removeValidatedLease(
            container: stagingContainer,
            containerEvidence: containerEvidence,
            root: stagingRoot,
            rootEvidence: rootEvidence,
            photos: photos
        )
    }

    public func adopt(into destination: URL) throws -> [Photo] {
        try Task.checkCancellation()
        if let adopted = lock.withLock({ state == .adopted ? adoptedPhotos : nil }) {
            return adopted
        }
        let mayAdopt = lock.withLock { () -> Bool in
            guard state == .active else { return false }
            state = .adopting
            return true
        }
        guard mayAdopt else { throw PhotoInputPreflightFailure(issue: .stagingUnavailable) }
        var moved = false
        do {
            try Self.validateLease(
                container: stagingContainer,
                containerEvidence: containerEvidence,
                root: stagingRoot,
                rootEvidence: rootEvidence,
                photos: photos
            )
            let paths = ProjectPaths(root: destination.deletingLastPathComponent().deletingLastPathComponent())
            try paths.validateRootDirectory()
            guard destination.standardizedFileURL.path == paths.importedPhotosURL.standardizedFileURL.path else {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
            if mkdir(paths.originalsURL.path, S_IRWXU) != 0, errno != EEXIST {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
            var parentStatus = stat()
            guard lstat(paths.originalsURL.path, &parentStatus) == 0,
                  (parentStatus.st_mode & S_IFMT) == S_IFDIR,
                  parentStatus.st_uid == getuid(),
                  parentStatus.st_mode & mode_t(0o022) == 0 else {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
            var destinationStatus = stat()
            guard lstat(destination.path, &destinationStatus) != 0, errno == ENOENT else {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
            let available: Int64
            do { available = try availableCapacity(stagingContainer) }
            catch { throw PhotoInputPreflightFailure(issue: .capacityUnavailable) }
            guard available >= requiredFreeBytesAtAdoption else {
                throw PhotoInputPreflightFailure(issue: .insufficientSpace(
                    required: requiredFreeBytesAtAdoption,
                    available: max(0, available)
                ))
            }
            try Task.checkCancellation()
            try Self.renameValidatedLease(
                container: stagingContainer,
                containerEvidence: containerEvidence,
                root: stagingRoot,
                rootEvidence: rootEvidence,
                destinationParent: paths.originalsURL,
                destination: destination
            )
            moved = true
            let adopted = photos.map {
                $0.replacingURL(destination.appendingPathComponent($0.stagedURL.lastPathComponent))
            }
            lock.withLock {
                adoptedPhotos = adopted
                state = .adopted
            }
            try Self.validateAdopted(destination: destination, evidence: rootEvidence, photos: adopted)
            return adopted
        } catch {
            lock.withLock {
                if state == .adopting {
                    state = moved ? .adopted : .active
                }
            }
            throw error
        }
    }

    private static func renameValidatedLease(
        container: URL,
        containerEvidence: PhotoFileEvidence,
        root: URL,
        rootEvidence: PhotoFileEvidence,
        destinationParent: URL,
        destination: URL
    ) throws {
        let sourceDirectory = Darwin.open(
            container.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDirectory >= 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        defer { Darwin.close(sourceDirectory) }
        let destinationDirectory = Darwin.open(
            destinationParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDirectory >= 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        defer { Darwin.close(destinationDirectory) }
        var sourceDirectoryStatus = stat()
        var destinationDirectoryStatus = stat()
        var sourceRootStatus = stat()
        guard fstat(sourceDirectory, &sourceDirectoryStatus) == 0,
              containerEvidence.matchesDirectory(sourceDirectoryStatus),
              fstat(destinationDirectory, &destinationDirectoryStatus) == 0,
              (destinationDirectoryStatus.st_mode & S_IFMT) == S_IFDIR,
              destinationDirectoryStatus.st_uid == getuid(),
              destinationDirectoryStatus.st_mode & mode_t(0o022) == 0,
              destinationDirectoryStatus.st_dev == rootEvidence.device else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        let sourceLeaf = root.lastPathComponent
        guard sourceLeaf.withCString({
            fstatat(sourceDirectory, $0, &sourceRootStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              rootEvidence.matchesDirectory(sourceRootStatus) else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        var existing = stat()
        let destinationLeaf = destination.lastPathComponent
        guard destinationLeaf.withCString({
            fstatat(destinationDirectory, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }) != 0,
              errno == ENOENT else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        let result = sourceLeaf.withCString { sourceName in
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
        guard result == 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        _ = fsync(sourceDirectory)
        _ = fsync(destinationDirectory)
    }

    private static func validateLease(
        container: URL,
        containerEvidence: PhotoFileEvidence,
        root: URL,
        rootEvidence: PhotoFileEvidence,
        photos: [Photo]
    ) throws {
        var containerStatus = stat()
        var rootStatus = stat()
        guard lstat(container.path, &containerStatus) == 0,
              containerEvidence.matchesDirectory(containerStatus),
              lstat(root.path, &rootStatus) == 0,
              rootEvidence.matchesDirectory(rootStatus),
              root.deletingLastPathComponent().standardizedFileURL == container.standardizedFileURL,
              Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
                == Set(photos.map { $0.stagedURL.lastPathComponent }) else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        for photo in photos {
            var status = stat()
            guard lstat(photo.stagedURL.path, &status) == 0,
                  photo.fileEvidence.matches(status),
                  photo.fileEvidence.isPrivateRegularFile else {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
        }
    }

    private static func validateAdopted(
        destination: URL,
        evidence: PhotoFileEvidence,
        photos: [Photo]
    ) throws {
        var status = stat()
        guard lstat(destination.path, &status) == 0, evidence.matchesDirectory(status),
              Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
                == Set(photos.map { $0.stagedURL.lastPathComponent }) else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        for photo in photos {
            var fileStatus = stat()
            guard lstat(photo.stagedURL.path, &fileStatus) == 0,
                  photo.fileEvidence.matches(fileStatus) else {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
        }
    }

    fileprivate static func removeValidatedLease(
        container: URL,
        containerEvidence: PhotoFileEvidence,
        root: URL,
        rootEvidence: PhotoFileEvidence,
        photos: [Photo]
    ) throws {
        try validateLease(
            container: container,
            containerEvidence: containerEvidence,
            root: root,
            rootEvidence: rootEvidence,
            photos: photos
        )
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PhotoInputPreflightFailure(issue: .stagingUnavailable) }
        defer { Darwin.close(descriptor) }
        for photo in photos {
            let leaf = photo.stagedURL.lastPathComponent
            guard leaf.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
        }
        let containerDescriptor = Darwin.open(
            container.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard containerDescriptor >= 0 else { throw PhotoInputPreflightFailure(issue: .stagingUnavailable) }
        defer { Darwin.close(containerDescriptor) }
        guard root.lastPathComponent.withCString({ unlinkat(containerDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
    }
}

extension PhotoInputPreflight {
    typealias PhotoAvailableCapacity = @Sendable (URL) throws -> Int64

    private struct Source: Sendable {
        let discoveryIndex: Int
        let url: URL
        let relativePath: String
        let safeDisplayName: String
        let evidence: PhotoFileEvidence
        let detectedTypeIdentifier: String?
    }

    private struct Analyzed: Sendable {
        let source: Source
        let sha256: String
        let pixelWidth: Int
        let pixelHeight: Int
        let orientation: Int
        let typeIdentifier: String
        let controlledExtension: String
        let rawInspection: RawPhotoInspection?
        let companionEvidence: RawCompanionEvidence?
        let analysisEvidence: PhotoAnalysisEvidence

        var companionCandidate: RawCompanionCandidate? {
            guard let companionEvidence else { return nil }
            return RawCompanionCandidate(
                relativePath: source.relativePath,
                typeIdentifier: typeIdentifier,
                isRaw: rawInspection != nil,
                dimensions: RawPixelDimensions(width: pixelWidth, height: pixelHeight),
                orientation: orientation,
                evidence: companionEvidence
            )
        }

        var sourceProvenance: PhotoSourceProvenance {
            PhotoSourceProvenance(
                byteCount: source.evidence.size,
                sha256: sha256,
                typeIdentifier: typeIdentifier
            )
        }
    }

    typealias PhotoContentTypeResolver = @Sendable (URL) -> String?
    typealias ProjectionProbe = @Sendable (URL) -> NativeProjectionTag?

    public static func prepare(
        folder: URL,
        stagingParent: URL,
        photoSelection: PhotoSelection,
        inputOrdering: InputOrdering,
        keyframeBudget: Int,
        requiredAtomicWorkspaceReserveBytes: Int64,
        limits: PhotoInputPreflightLimits = .init(),
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> PreparedPhotoInput {
        try await prepare(
            folder: folder,
            stagingParent: stagingParent,
            photoSelection: photoSelection,
            inputOrdering: inputOrdering,
            keyframeBudget: keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: requiredAtomicWorkspaceReserveBytes,
            limits: limits,
            availableCapacity: defaultPhotoAvailableCapacity,
            contentTypeResolver: defaultPhotoContentType,
            rawDecoder: RawPhotoDecoder(),
            projectionProbe: NativeProjectionMetadataProbe.tag(inImageAt:),
            progress: progress
        )
    }

    /// Admits an explicit set of photo files, which may originate from several
    /// different folders. Each file is validated with the same symlink, hardlink,
    /// and regular-file guards the folder walk applies to its entries.
    public static func prepare(
        photos: [URL],
        stagingParent: URL,
        photoSelection: PhotoSelection,
        inputOrdering: InputOrdering,
        keyframeBudget: Int,
        requiredAtomicWorkspaceReserveBytes: Int64,
        limits: PhotoInputPreflightLimits = .init(),
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> PreparedPhotoInput {
        try await prepare(
            photos: photos,
            stagingParent: stagingParent,
            photoSelection: photoSelection,
            inputOrdering: inputOrdering,
            keyframeBudget: keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: requiredAtomicWorkspaceReserveBytes,
            limits: limits,
            availableCapacity: defaultPhotoAvailableCapacity,
            contentTypeResolver: defaultPhotoContentType,
            rawDecoder: RawPhotoDecoder(),
            projectionProbe: NativeProjectionMetadataProbe.tag(inImageAt:),
            progress: progress
        )
    }

    static func prepare(
        photos: [URL],
        stagingParent: URL,
        photoSelection: PhotoSelection,
        inputOrdering: InputOrdering,
        keyframeBudget: Int,
        requiredAtomicWorkspaceReserveBytes: Int64,
        limits: PhotoInputPreflightLimits,
        availableCapacity: @escaping PhotoAvailableCapacity,
        contentTypeResolver: @escaping PhotoContentTypeResolver = defaultPhotoContentType,
        rawDecoder: any RawPhotoDecoding = RawPhotoDecoder(),
        projectionProbe: @escaping ProjectionProbe = NativeProjectionMetadataProbe.tag(inImageAt:),
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> PreparedPhotoInput {
        try Task.checkCancellation()
        guard limits.isValid, keyframeBudget > 0, requiredAtomicWorkspaceReserveBytes >= 0 else {
            throw PhotoInputPreflightFailure(issue: .invalidLimits)
        }
        let sources = try securedSources(
            from: photos,
            limits: limits,
            contentTypeResolver: contentTypeResolver
        )
        return try await prepareFromSecuredSources(
            sources: sources,
            stagingParent: stagingParent,
            photoSelection: photoSelection,
            inputOrdering: inputOrdering,
            keyframeBudget: keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: requiredAtomicWorkspaceReserveBytes,
            limits: limits,
            availableCapacity: availableCapacity,
            contentTypeResolver: contentTypeResolver,
            rawDecoder: rawDecoder,
            projectionProbe: projectionProbe,
            progress: progress
        )
    }

    static func prepare(
        folder: URL,
        stagingParent: URL,
        photoSelection: PhotoSelection,
        inputOrdering: InputOrdering,
        keyframeBudget: Int,
        requiredAtomicWorkspaceReserveBytes: Int64,
        limits: PhotoInputPreflightLimits,
        availableCapacity: @escaping PhotoAvailableCapacity,
        contentTypeResolver: @escaping PhotoContentTypeResolver = defaultPhotoContentType,
        rawDecoder: any RawPhotoDecoding = RawPhotoDecoder(),
        projectionProbe: @escaping ProjectionProbe = NativeProjectionMetadataProbe.tag(inImageAt:),
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> PreparedPhotoInput {
        try Task.checkCancellation()
        guard limits.isValid, keyframeBudget > 0, requiredAtomicWorkspaceReserveBytes >= 0 else {
            throw PhotoInputPreflightFailure(issue: .invalidLimits)
        }
        let sources = try secureSources(
            in: folder,
            limits: limits,
            contentTypeResolver: contentTypeResolver
        )
        return try await prepareFromSecuredSources(
            sources: sources,
            stagingParent: stagingParent,
            photoSelection: photoSelection,
            inputOrdering: inputOrdering,
            keyframeBudget: keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: requiredAtomicWorkspaceReserveBytes,
            limits: limits,
            availableCapacity: availableCapacity,
            contentTypeResolver: contentTypeResolver,
            rawDecoder: rawDecoder,
            projectionProbe: projectionProbe,
            progress: progress
        )
    }

    /// Shared admission pipeline once a secured, deduplicated source set exists.
    /// Both the folder walk and the explicit file-list path converge here, so
    /// analysis, selection, and staging stay identical regardless of how the
    /// sources were gathered.
    private static func prepareFromSecuredSources(
        sources: [Source],
        stagingParent: URL,
        photoSelection: PhotoSelection,
        inputOrdering: InputOrdering,
        keyframeBudget: Int,
        requiredAtomicWorkspaceReserveBytes: Int64,
        limits: PhotoInputPreflightLimits,
        availableCapacity: @escaping PhotoAvailableCapacity,
        contentTypeResolver: @escaping PhotoContentTypeResolver,
        rawDecoder: any RawPhotoDecoding,
        projectionProbe: @escaping ProjectionProbe,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> PreparedPhotoInput {
        let container: URL
        let root: URL
        do {
            container = try makeStagingContainer(parent: stagingParent)
            try PhotoStagingCleanup.cleanupStaleRuns(in: container)
            root = try makeStagingRoot(container: container)
        } catch {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        guard let containerEvidence = evidence(at: container), containerEvidence.isPrivateDirectory,
              let initialRootEvidence = evidence(at: root), initialRootEvidence.isPrivateDirectory else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        var shouldClean = true
        var preparedPhotos: [PreparedPhotoInput.Photo] = []
        defer {
            if shouldClean {
                let currentRootEvidence = evidence(at: root) ?? initialRootEvidence
                try? PreparedPhotoInput.removeValidatedLease(
                    container: container,
                    containerEvidence: containerEvidence,
                    root: root,
                    rootEvidence: currentRootEvidence,
                    photos: preparedPhotos
                )
            }
        }
        var analyzed: [Analyzed] = []
        analyzed.reserveCapacity(sources.count)
        var unreadableCount = 0
        var exactDuplicateCount = 0
        var seenDigests = Set<String>()
        for source in sources {
            try Task.checkCancellation()
            progress(
                0.4 * Double(source.discoveryIndex) / Double(max(1, sources.count)),
                "Checking photo \(source.discoveryIndex + 1) of \(sources.count)"
            )
            guard let candidate = try analyze(
                source,
                maximumPixelCount: limits.maximumPixelCount,
                maximumDecodedDimension: limits.maximumDecodedDimension,
                stagingRoot: root,
                availableCapacity: availableCapacity,
                minimumReserve: limits.minimumFreeSpaceReserveBytes,
                contentTypeResolver: contentTypeResolver,
                rawDecoder: rawDecoder,
                projectionProbe: projectionProbe
            ) else {
                unreadableCount += 1
                continue
            }
            guard seenDigests.insert(candidate.sha256).inserted else {
                exactDuplicateCount += 1
                continue
            }
            analyzed.append(candidate)
        }
        var companionGroups: [String: [Int]] = [:]
        for (index, item) in analyzed.enumerated() {
            companionGroups[RawPhotoDecoder.companionPathKey(item.source.relativePath), default: []]
                .append(index)
        }
        var companionDrops = Set<Int>()
        for indexes in companionGroups.values where indexes.count == 2 {
            let first = indexes[0]
            let second = indexes[1]
            guard let firstCandidate = analyzed[first].companionCandidate,
                  let secondCandidate = analyzed[second].companionCandidate,
                  RawPhotoDecoder.areCompanions(firstCandidate, secondCandidate) else {
                continue
            }
            companionDrops.insert(analyzed[first].rawInspection == nil ? first : second)
        }
        let companionDuplicateCount = companionDrops.count
        if !companionDrops.isEmpty {
            analyzed = analyzed.enumerated().compactMap { index, item in
                companionDrops.contains(index) ? nil : item
            }
        }
        guard !analyzed.isEmpty else {
            throw PhotoInputPreflightFailure(issue: .noValidPhotos)
        }
        let ordered = inputOrdering == .continuous
            ? analyzed
            : analyzed.sorted { $0.sha256 < $1.sha256 }
        let strategy: PhotoSelectionStrategy
        let retainedInStrategyOrder: [Analyzed]
        if photoSelection == .useAllValidPhotos {
            guard ordered.count <= keyframeBudget else {
                throw PhotoInputPreflightFailure(issue: .useAllExceedsBudget(
                    selected: ordered.count,
                    maximum: keyframeBudget
                ))
            }
            strategy = .useAll
            retainedInStrategyOrder = ordered
        } else if inputOrdering == .continuous {
            strategy = .continuousEvenSpacing
            retainedInStrategyOrder = evenlySpaced(
                ordered,
                targetCount: keyframeBudget
            )
        } else {
            strategy = .visualDiversity
            let rankedEvidence = try PhotoDiversitySelector.rank(
                ordered.map(\.analysisEvidence),
                targetCount: keyframeBudget
            )
            let analyzedBySHA256 = Dictionary(
                uniqueKeysWithValues: ordered.map { ($0.sha256, $0) }
            )
            retainedInStrategyOrder = try rankedEvidence.map { evidence in
                guard let retained = analyzedBySHA256[evidence.sourceSHA256] else {
                    throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
                }
                return retained
            }
        }
        let rankBySourceSHA256 = Dictionary(
            uniqueKeysWithValues: retainedInStrategyOrder.enumerated().map { index, analyzed in
                (analyzed.sha256, index)
            }
        )
        let selected: [(analyzed: Analyzed, retainedRank: Int)] = ordered.compactMap { analyzed in
            rankBySourceSHA256[analyzed.sha256].map { (analyzed, $0) }
        }
        guard let recipe = analyzed.first?.analysisEvidence else {
            throw PhotoInputPreflightFailure(issue: .noValidPhotos)
        }
        let artifactAdmissionOrder = inputOrdering == .continuous
            ? analyzed
            : ordered
        let selectionArtifact = PhotoSelectionArtifact(
            strategy: strategy,
            analysisRecipeVersion: recipe.analysisRecipeVersion,
            analysisRecipeSHA256: recipe.analysisRecipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: inputOrdering,
            requestedPhotoSelection: photoSelection,
            admissionCapacity: retainedInStrategyOrder.count,
            discoveredCount: sources.count,
            acceptedCount: analyzed.count,
            unreadableCount: unreadableCount,
            exactDuplicateCount: exactDuplicateCount,
            companionDuplicateCount: companionDuplicateCount,
            candidates: artifactAdmissionOrder.enumerated().map {
                admissionOrdinal, candidate in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: admissionOrdinal,
                    evidence: candidate.analysisEvidence,
                    retainedRank: rankBySourceSHA256[candidate.sha256]
                )
            },
            retainedSourceSHA256s: retainedInStrategyOrder.map(\.sha256),
            canonicalRetainedSourceSHA256s: selected.map(\.analyzed.sha256)
        )
        let selectionArtifactByteCount: Int64
        do {
            selectionArtifactByteCount = Int64(
                try PhotoSelectionArtifactStore.canonicalData(selectionArtifact).count
            )
        } catch {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }

        let reserve = max(limits.minimumFreeSpaceReserveBytes, requiredAtomicWorkspaceReserveBytes)
        var selectedBytes = selected.reduce(into: Int64(0)) { total, selection in
            let item = selection.analyzed
            if item.rawInspection == nil {
                total += item.source.evidence.size
            } else {
                total += rawOutputBudget(
                    inspection: item.rawInspection!,
                    maximumDimension: limits.maximumDecodedDimension
                )
            }
        }
        let maximumTransientRawBytes = selected
            .map(\.analyzed)
            .filter { $0.rawInspection != nil }
            .map { $0.source.evidence.size }
            .max() ?? 0
        let (selectedWithTransientRaw, selectedOverflow) = selectedBytes.addingReportingOverflow(
            maximumTransientRawBytes
        )
        guard !selectedOverflow else {
            throw PhotoInputPreflightFailure(issue: .insufficientSpace(required: .max, available: 0))
        }
        let (selectionWorkspaceBytes, selectionWorkspaceOverflow) =
            selectionArtifactByteCount.multipliedReportingOverflow(by: 2)
        let (selectedWithSelectionArtifact, artifactOverflow) =
            selectedWithTransientRaw.addingReportingOverflow(selectionWorkspaceBytes)
        guard !selectionWorkspaceOverflow, !artifactOverflow else {
            throw PhotoInputPreflightFailure(
                issue: .insufficientSpace(required: .max, available: 0)
            )
        }
        selectedBytes = selectedWithSelectionArtifact
        let (required, overflow) = selectedBytes.addingReportingOverflow(reserve)
        guard !overflow else {
            throw PhotoInputPreflightFailure(issue: .insufficientSpace(required: .max, available: 0))
        }
        let available: Int64
        do { available = try availableCapacity(container) }
        catch { throw PhotoInputPreflightFailure(issue: .capacityUnavailable) }
        guard available >= required else {
            throw PhotoInputPreflightFailure(issue: .insufficientSpace(
                required: required,
                available: max(0, available)
            ))
        }
        for (index, selection) in selected.enumerated() {
            try Task.checkCancellation()
            progress(
                0.4 + 0.6 * Double(index) / Double(max(1, selected.count)),
                "Securing photo \(index + 1) of \(selected.count)"
            )
            preparedPhotos.append(try snapshot(
                selection.analyzed,
                index: index,
                retainedRank: selection.retainedRank,
                root: root,
                maximumDecodedDimension: limits.maximumDecodedDimension,
                rawDecoder: rawDecoder
            ))
        }
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw PhotoInputPreflightFailure(issue: .stagingUnavailable) }
        defer { Darwin.close(rootDescriptor) }
        guard fsync(rootDescriptor) == 0,
              let rootEvidence = evidence(at: root),
              rootEvidence.isPrivateDirectory else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        shouldClean = false
        return PreparedPhotoInput(
            stagingContainer: container,
            containerEvidence: containerEvidence,
            stagingRoot: root,
            rootEvidence: rootEvidence,
            photos: preparedPhotos,
            summary: PhotoInputPreflight(
                discoveredPhotoCount: sources.count,
                validPhotoCount: analyzed.count,
                unreadablePhotoCount: unreadableCount,
                duplicatePhotoCount: exactDuplicateCount + companionDuplicateCount
            ),
            selectionArtifact: selectionArtifact,
            requiredFreeBytesAtAdoption: reserve,
            availableCapacity: availableCapacity
        )
    }

    private static func secureSources(
        in folder: URL,
        limits: PhotoInputPreflightLimits,
        contentTypeResolver: PhotoContentTypeResolver
    ) throws -> [Source] {
        guard folder.isFileURL else { throw PhotoInputPreflightFailure(issue: .folderUnavailable) }
        let folderName = folder.lastPathComponent
        var rootStatus = stat()
        guard lstat(folder.path, &rootStatus) == 0 else {
            throw PhotoInputPreflightFailure(issue: photoIssueForFailedCall(
                relativePath: folderName,
                otherwise: .folderUnavailable
            ))
        }
        guard (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw PhotoInputPreflightFailure(issue: .folderUnavailable)
        }
        let rootDescriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw PhotoInputPreflightFailure(issue: photoIssueForFailedCall(
                relativePath: folderName,
                otherwise: .folderUnavailable
            ))
        }
        defer { Darwin.close(rootDescriptor) }
        var descriptorStatus = stat()
        guard fstat(rootDescriptor, &descriptorStatus) == 0,
              descriptorStatus.st_dev == rootStatus.st_dev,
              descriptorStatus.st_ino == rootStatus.st_ino else {
            throw PhotoInputPreflightFailure(issue: .folderUnavailable)
        }
        var relativePaths: [(String, PhotoFileEvidence)] = []
        var traversedEntryCount = 0
        try enumerateDirectory(
            descriptor: rootDescriptor,
            prefix: "",
            depth: 0,
            limits: limits,
            traversedEntryCount: &traversedEntryCount,
            output: &relativePaths
        )
        relativePaths.sort { $0.0 < $1.0 }
        var total: Int64 = 0
        var sources: [Source] = []
        for item in relativePaths {
            let url = folder.appendingPathComponent(item.0)
            let detectedType = try securelyDetectedType(
                at: url,
                evidence: item.1,
                relativePath: item.0,
                resolver: contentTypeResolver
            )
            guard detectedType != nil
                    || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            else {
                continue
            }
            guard sources.count < limits.maximumPhotoCount else {
                throw PhotoInputPreflightFailure(issue: .tooManyPhotos(maximum: limits.maximumPhotoCount))
            }
            guard item.1.size > 0, item.1.size <= limits.maximumSinglePhotoBytes else {
                throw PhotoInputPreflightFailure(
                    issue: .totalBytesExceeded(maximum: limits.maximumTotalBytes)
                )
            }
            let (next, overflow) = total.addingReportingOverflow(item.1.size)
            guard !overflow, next <= limits.maximumTotalBytes else {
                throw PhotoInputPreflightFailure(issue: .totalBytesExceeded(maximum: limits.maximumTotalBytes))
            }
            total = next
            sources.append(Source(
                discoveryIndex: sources.count,
                url: url,
                relativePath: item.0,
                safeDisplayName: safePhotoDisplayName(url.lastPathComponent, index: sources.count),
                evidence: item.1,
                detectedTypeIdentifier: detectedType
            ))
        }
        return sources
    }

    /// Builds admission sources from an explicit file list, which may span several
    /// folders. Applies the same per-entry guards as the folder walk (`lstat`,
    /// reject symbolic links, require a regular file with a single hard link) plus
    /// the same content-type, per-file, and total-byte limits. Sorting by path
    /// gives a deterministic order independent of how the caller collected the URLs.
    private static func securedSources(
        from photoURLs: [URL],
        limits: PhotoInputPreflightLimits,
        contentTypeResolver: PhotoContentTypeResolver
    ) throws -> [Source] {
        let orderedURLs = photoURLs
            .map { $0.standardizedFileURL }
            .sorted { $0.path < $1.path }
        var validated: [(url: URL, relativePath: String, evidence: PhotoFileEvidence)] = []
        var seenIdentities = Set<[UInt64]>()
        for url in orderedURLs {
            try Task.checkCancellation()
            guard url.isFileURL else {
                throw PhotoInputPreflightFailure(issue: .folderUnavailable)
            }
            let relativePath = url.lastPathComponent
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw PhotoInputPreflightFailure(issue: photoIssueForFailedCall(
                    relativePath: relativePath,
                    otherwise: .unreadableEntry(relativePath: relativePath)
                ))
            }
            let kind = status.st_mode & S_IFMT
            if kind == S_IFLNK {
                throw PhotoInputPreflightFailure(issue: .symbolicLink(relativePath: relativePath))
            }
            guard kind == S_IFREG else {
                throw PhotoInputPreflightFailure(issue: .unreadableEntry(relativePath: relativePath))
            }
            guard status.st_nlink == 1 else {
                throw PhotoInputPreflightFailure(issue: .unreadableEntry(relativePath: relativePath))
            }
            let identity: [UInt64] = [UInt64(status.st_dev), UInt64(status.st_ino)]
            guard seenIdentities.insert(identity).inserted else {
                // The same underlying file was named more than once; keep one.
                continue
            }
            guard validated.count < limits.maximumTraversalEntryCount else {
                throw PhotoInputPreflightFailure(issue: .traversalLimitExceeded)
            }
            validated.append((url, relativePath, PhotoFileEvidence(status)))
        }

        var total: Int64 = 0
        var sources: [Source] = []
        for item in validated {
            let detectedType = try securelyDetectedType(
                at: item.url,
                evidence: item.evidence,
                relativePath: item.relativePath,
                resolver: contentTypeResolver
            )
            guard detectedType != nil
                    || UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .image) == true
            else {
                continue
            }
            guard sources.count < limits.maximumPhotoCount else {
                throw PhotoInputPreflightFailure(issue: .tooManyPhotos(maximum: limits.maximumPhotoCount))
            }
            guard item.evidence.size > 0, item.evidence.size <= limits.maximumSinglePhotoBytes else {
                throw PhotoInputPreflightFailure(
                    issue: .totalBytesExceeded(maximum: limits.maximumTotalBytes)
                )
            }
            let (next, overflow) = total.addingReportingOverflow(item.evidence.size)
            guard !overflow, next <= limits.maximumTotalBytes else {
                throw PhotoInputPreflightFailure(issue: .totalBytesExceeded(maximum: limits.maximumTotalBytes))
            }
            total = next
            sources.append(Source(
                discoveryIndex: sources.count,
                url: item.url,
                relativePath: item.relativePath,
                safeDisplayName: safePhotoDisplayName(item.url.lastPathComponent, index: sources.count),
                evidence: item.evidence,
                detectedTypeIdentifier: detectedType
            ))
        }
        return sources
    }

    private static func enumerateDirectory(
        descriptor: Int32,
        prefix: String,
        depth: Int,
        limits: PhotoInputPreflightLimits,
        traversedEntryCount: inout Int,
        output: inout [(String, PhotoFileEvidence)]
    ) throws {
        guard depth <= limits.maximumRecursionDepth else {
            throw PhotoInputPreflightFailure(issue: .traversalLimitExceeded)
        }
        try Task.checkCancellation()
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw PhotoInputPreflightFailure(issue: .unreadableEntry(relativePath: prefix))
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                traversedEntryCount += 1
                guard traversedEntryCount <= limits.maximumTraversalEntryCount else {
                    throw PhotoInputPreflightFailure(issue: .traversalLimitExceeded)
                }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw PhotoInputPreflightFailure(issue: .unreadableEntry(relativePath: prefix))
        }
        for name in names.sorted() {
            try Task.checkCancellation()
            guard !name.hasPrefix(".") else { continue }
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var status = stat()
            guard name.withCString({ fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw PhotoInputPreflightFailure(issue: photoIssueForFailedCall(
                    relativePath: relative,
                    otherwise: .unreadableEntry(relativePath: relative)
                ))
            }
            let kind = status.st_mode & S_IFMT
            if kind == S_IFLNK {
                throw PhotoInputPreflightFailure(issue: .symbolicLink(relativePath: relative))
            }
            if kind == S_IFDIR {
                let child = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else {
                    throw PhotoInputPreflightFailure(issue: photoIssueForFailedCall(
                        relativePath: relative,
                        otherwise: .unreadableEntry(relativePath: relative)
                    ))
                }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      opened.st_dev == status.st_dev,
                      opened.st_ino == status.st_ino else {
                    Darwin.close(child)
                    throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: relative))
                }
                do {
                    try enumerateDirectory(
                        descriptor: child,
                        prefix: relative,
                        depth: depth + 1,
                        limits: limits,
                        traversedEntryCount: &traversedEntryCount,
                        output: &output
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                continue
            }
            guard kind == S_IFREG else {
                throw PhotoInputPreflightFailure(issue: .unreadableEntry(relativePath: relative))
            }
            guard status.st_nlink == 1 else {
                throw PhotoInputPreflightFailure(issue: .unreadableEntry(relativePath: relative))
            }
            output.append((relative, PhotoFileEvidence(status)))
        }
    }

    private static func securelyDetectedType(
        at url: URL,
        evidence: PhotoFileEvidence,
        relativePath: String,
        resolver: PhotoContentTypeResolver
    ) throws -> String? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw PhotoInputPreflightFailure(issue: photoIssueForFailedCall(
                relativePath: relativePath,
                otherwise: .sourceChanged(relativePath: relativePath)
            ))
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, evidence.matches(opened) else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: relativePath))
        }
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        // Sniff bytes first so a rendered image with a RAW suffix keeps its
        // real type. The suffix is only a bounded hint for descriptor-hostile
        // RAW formats that ImageIO could not open at all.
        let type = resolver(descriptorURL) ?? rawHintedPhotoContentType(
            descriptorURL,
            declaredFilename: url.lastPathComponent
        )
        var final = stat()
        var rebound = stat()
        guard fstat(descriptor, &final) == 0,
              lstat(url.path, &rebound) == 0,
              evidence.matches(final),
              evidence.matches(rebound) else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: relativePath))
        }
        return type
    }

    private static func analyze(
        _ source: Source,
        maximumPixelCount: Int64,
        maximumDecodedDimension: Int,
        stagingRoot: URL,
        availableCapacity: PhotoAvailableCapacity,
        minimumReserve: Int64,
        contentTypeResolver: PhotoContentTypeResolver,
        rawDecoder: any RawPhotoDecoding,
        projectionProbe: ProjectionProbe
    ) throws -> Analyzed? {
        let descriptor = Darwin.open(
            source.url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PhotoInputPreflightFailure(issue: photoIssueForFailedCall(
                relativePath: source.safeDisplayName,
                otherwise: .sourceChanged(relativePath: source.safeDisplayName)
            ))
        }
        defer { Darwin.close(descriptor) }
        guard source.evidence.size > 0 else { return nil }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, source.evidence.matches(initial) else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw PhotoInputPreflightFailure(issue: .unreadableEntry(relativePath: source.safeDisplayName))
            }
            if count == 0 { break }
            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            bytesRead += Int64(count)
        }
        guard bytesRead == source.evidence.size,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        guard let type = source.detectedTypeIdentifier ?? contentTypeResolver(descriptorURL) else {
            return nil
        }
        // The release verifier blocks Launch Services brokers. Classify the
        // four directly supported raster types without consulting that service.
        let controlledExtension = controlledPhotoExtension(for: type)
        let rawContentType = controlledExtension == nil ? UTType(type) : nil
        guard controlledExtension != nil
                || rawContentType?.conforms(to: .rawImage) == true
        else { return nil }
        let projectionTag = projectionProbe(descriptorURL)
        var projectionFinal = stat()
        var projectionRebound = stat()
        guard fstat(descriptor, &projectionFinal) == 0,
              lstat(source.url.path, &projectionRebound) == 0,
              source.evidence.matches(projectionFinal),
              source.evidence.matches(projectionRebound) else {
            throw PhotoInputPreflightFailure(
                issue: .sourceChanged(relativePath: source.safeDisplayName)
            )
        }
        if let projectionTag {
            throw PhotoInputPreflightFailure(
                issue: .unsupportedSpherical(.init(tag: projectionTag))
            )
        }
        let sourceSHA256 = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        let analysisProxyDimension = min(maximumDecodedDimension, 256)
        if rawContentType?.conforms(to: .rawImage) == true {
            let proxyBudget = rawProxyBudget(
                sourceBytes: source.evidence.size,
                maximumDimension: analysisProxyDimension
            )
            let available: Int64
            do { available = try availableCapacity(stagingRoot) }
            catch { throw PhotoInputPreflightFailure(issue: .capacityUnavailable) }
            let (required, overflow) = proxyBudget.addingReportingOverflow(minimumReserve)
            guard !overflow, available >= required else {
                throw PhotoInputPreflightFailure(issue: .insufficientSpace(
                    required: overflow ? .max : required,
                    available: max(0, available)
                ))
            }
            let leaf = ".raw-analysis-\(UUID().uuidString.lowercased())"
            let staged = try copyDescriptorToPrivateLeaf(
                descriptor,
                source: source,
                leaf: leaf,
                root: stagingRoot
            )
            defer { try? removePrivateLeaf(staged, expectedSize: source.evidence.size, root: stagingRoot) }
            let inspection: RawPhotoInspection
            do {
                inspection = try rawDecoder.inspect(
                    stagedSource: staged,
                    maximumProxyDimension: analysisProxyDimension
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            guard inspection.nativeDimensions.width > 0,
                  inspection.nativeDimensions.height > 0,
                  Int64(inspection.nativeDimensions.width) <= maximumPixelCount
                    / Int64(inspection.nativeDimensions.height),
                  (1...8).contains(inspection.sourceOrientation) else {
                return nil
            }
            var final = stat()
            var rebound = stat()
            guard fstat(descriptor, &final) == 0,
                  lstat(source.url.path, &rebound) == 0,
                  source.evidence.matches(final),
                  source.evidence.matches(rebound) else {
                throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
            }
            return Analyzed(
                source: source,
                sha256: sourceSHA256,
                pixelWidth: inspection.nativeDimensions.width,
                pixelHeight: inspection.nativeDimensions.height,
                orientation: inspection.sourceOrientation,
                typeIdentifier: type,
                controlledExtension: "png",
                rawInspection: inspection,
                companionEvidence: inspection.companionEvidence,
                analysisEvidence: inspection.analysisMeasurements.evidence(
                    sourceSHA256: sourceSHA256
                )
            )
        }
        guard let controlledExtension,
              let imageSource = CGImageSourceCreateWithURL(
                descriptorURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(imageSource) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0,
              Int64(width.intValue) <= maximumPixelCount / Int64(height.intValue),
              let thumbnail = SDRImageDecoder.createOrientedThumbnail(
                source: imageSource,
                properties: properties,
                maximumPixelDimension: analysisProxyDimension
              ),
              let analysisEvidence = try? PhotoAnalysisEvidenceBuilder.build(
                sourceSHA256: sourceSHA256,
                orientedImage: thumbnail
              ) else {
            return nil
        }
        var final = stat()
        var rebound = stat()
        guard fstat(descriptor, &final) == 0,
              lstat(source.url.path, &rebound) == 0,
              source.evidence.matches(final),
              source.evidence.matches(rebound) else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { return nil }
        return Analyzed(
            source: source,
            sha256: sourceSHA256,
            pixelWidth: width.intValue,
            pixelHeight: height.intValue,
            orientation: orientation,
            typeIdentifier: type,
            controlledExtension: controlledExtension,
            rawInspection: nil,
            companionEvidence: RawPhotoDecoder.companionEvidence(properties: properties),
            analysisEvidence: analysisEvidence
        )
    }

    private static func snapshot(
        _ analyzed: Analyzed,
        index: Int,
        retainedRank: Int,
        root: URL,
        maximumDecodedDimension: Int,
        rawDecoder: any RawPhotoDecoding
    ) throws -> PreparedPhotoInput.Photo {
        if analyzed.rawInspection != nil {
            return try developRaw(
                analyzed,
                index: index,
                retainedRank: retainedRank,
                root: root,
                maximumDecodedDimension: maximumDecodedDimension,
                rawDecoder: rawDecoder
            )
        }
        let source = analyzed.source
        let input = Darwin.open(
            source.url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard input >= 0 else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        defer { Darwin.close(input) }
        var initial = stat()
        guard fstat(input, &initial) == 0, source.evidence.matches(initial) else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        let leaf = String(format: "photo-%04d.%@", index, analyzed.controlledExtension)
        let destination = root.appendingPathComponent(leaf)
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw PhotoInputPreflightFailure(issue: .stagingUnavailable) }
        defer { Darwin.close(rootDescriptor) }
        let cloneResult = leaf.withCString {
            fclonefileat(input, rootDescriptor, $0, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY))
        }
        let cloned = cloneResult == 0
        if !cloned, ![EXDEV, ENOTSUP, ENOSYS].contains(errno) {
            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
        }
        let flags = cloned
            ? O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            : O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let output = leaf.withCString { openat(rootDescriptor, $0, flags, S_IRUSR | S_IWUSR) }
        guard output >= 0 else {
            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
        }
        defer { Darwin.close(output) }
        do {
            if !cloned {
                var buffer = [UInt8](repeating: 0, count: 1_048_576)
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(input, $0.baseAddress, $0.count)
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else {
                        throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.relativePath))
                    }
                    if count == 0 { break }
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
                        if result < 0, errno == EINTR { continue }
                        guard result > 0 else {
                            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.relativePath))
                        }
                        written += result
                    }
                }
            }
            guard fchmod(output, S_IRUSR | S_IWUSR) == 0, fsync(output) == 0 else {
                throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.relativePath))
            }
            var final = stat()
            var rebound = stat()
            guard fstat(input, &final) == 0,
                  lstat(source.url.path, &rebound) == 0,
                  source.evidence.matches(final),
                  source.evidence.matches(rebound) else {
                throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.relativePath))
            }
            guard lseek(output, 0, SEEK_SET) == 0 else {
                throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.relativePath))
            }
            var controlledHasher = SHA256()
            var controlledBytes: Int64 = 0
            var digestBuffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                try Task.checkCancellation()
                let count = digestBuffer.withUnsafeMutableBytes {
                    Darwin.read(output, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else {
                    throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.relativePath))
                }
                if count == 0 { break }
                controlledBytes += Int64(count)
                controlledHasher.update(data: Data(digestBuffer[0..<count]))
            }
            let controlledDigest = controlledHasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
            guard controlledDigest == analyzed.sha256,
                  controlledBytes == source.evidence.size,
                  let fileEvidence = evidence(at: destination),
                  fileEvidence.isPrivateRegularFile else {
                throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.relativePath))
            }
            return PreparedPhotoInput.Photo(
                safeDisplayName: source.safeDisplayName,
                stagedURL: destination,
                byteCount: source.evidence.size,
                sha256: analyzed.sha256,
                pixelWidth: analyzed.pixelWidth,
                pixelHeight: analyzed.pixelHeight,
                orientation: analyzed.orientation,
                typeIdentifier: analyzed.typeIdentifier,
                source: analyzed.sourceProvenance,
                importMode: .unchanged,
                analysisEvidence: analyzed.analysisEvidence,
                retainedRank: retainedRank,
                fileEvidence: fileEvidence
            )
        } catch {
            _ = leaf.withCString { unlinkat(rootDescriptor, $0, 0) }
            throw error
        }
    }

    private static func developRaw(
        _ analyzed: Analyzed,
        index: Int,
        retainedRank: Int,
        root: URL,
        maximumDecodedDimension: Int,
        rawDecoder: any RawPhotoDecoding
    ) throws -> PreparedPhotoInput.Photo {
        let source = analyzed.source
        let input = Darwin.open(source.url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        defer { Darwin.close(input) }
        var initial = stat()
        guard fstat(input, &initial) == 0, source.evidence.matches(initial) else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        let rawLeaf = ".raw-development-\(UUID().uuidString.lowercased())"
        let stagedRaw = try copyDescriptorToPrivateLeaf(
            input,
            source: source,
            leaf: rawLeaf,
            root: root
        )
        defer { try? removePrivateLeaf(stagedRaw, expectedSize: source.evidence.size, root: root) }
        let leaf = String(format: "photo-%04d.png", index)
        let destination = root.appendingPathComponent(leaf)
        let development: RawPhotoDevelopment
        do {
            development = try rawDecoder.develop(
                stagedSource: stagedRaw,
                destination: destination,
                maximumPixelDimension: maximumDecodedDimension
            )
            let validated = try RawPhotoDecoder.validateControlledOutput(
                at: destination,
                expectedMaximumPixelDimension: maximumDecodedDimension
            )
            guard validated == development.controlledDimensions,
                  development.evidence.decoderIdentifier == RawPhotoDecoder.decoderIdentifier,
                  development.evidence.settings == .production(
                    maximumPixelDimension: maximumDecodedDimension
                  ),
                  development.evidence.sourceOrientation == analyzed.orientation else {
                throw RawPhotoDecodingError.invalidControlledOutput
            }
        } catch is CancellationError {
            try? unlinkPrivateOutput(destination, root: root)
            throw CancellationError()
        } catch {
            try? unlinkPrivateOutput(destination, root: root)
            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
        }
        try Task.checkCancellation()
        var final = stat()
        var rebound = stat()
        guard fstat(input, &final) == 0,
              lstat(source.url.path, &rebound) == 0,
              source.evidence.matches(final),
              source.evidence.matches(rebound) else {
            try? unlinkPrivateOutput(destination, root: root)
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        let output = Darwin.open(destination.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else {
            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
        }
        defer { Darwin.close(output) }
        guard fchmod(output, S_IRUSR | S_IWUSR) == 0,
              fsync(output) == 0,
              let closure = try? hashDescriptor(output),
              let fileEvidence = evidence(at: destination),
              fileEvidence.isPrivateRegularFile,
              closure.byteCount == fileEvidence.size else {
            try? unlinkPrivateOutput(destination, root: root)
            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
        }
        return PreparedPhotoInput.Photo(
            safeDisplayName: source.safeDisplayName,
            stagedURL: destination,
            byteCount: closure.byteCount,
            sha256: closure.sha256,
            pixelWidth: development.controlledDimensions.width,
            pixelHeight: development.controlledDimensions.height,
            orientation: 1,
            typeIdentifier: UTType.png.identifier,
            source: analyzed.sourceProvenance,
            importMode: .rawDevelopment(development.evidence),
            analysisEvidence: analyzed.analysisEvidence,
            retainedRank: retainedRank,
            fileEvidence: fileEvidence
        )
    }

    private static func copyDescriptorToPrivateLeaf(
        _ input: Int32,
        source: Source,
        leaf: String,
        root: URL
    ) throws -> URL {
        guard lseek(input, 0, SEEK_SET) == 0 else {
            throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
        }
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw PhotoInputPreflightFailure(issue: .stagingUnavailable) }
        defer { Darwin.close(rootDescriptor) }
        let cloneResult = leaf.withCString {
            fclonefileat(input, rootDescriptor, $0, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY))
        }
        let cloned = cloneResult == 0
        if !cloned, ![EXDEV, ENOTSUP, ENOSYS].contains(errno) {
            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
        }
        let flags = cloned
            ? O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            : O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let output = leaf.withCString { openat(rootDescriptor, $0, flags, S_IRUSR | S_IWUSR) }
        guard output >= 0 else {
            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
        }
        defer { Darwin.close(output) }
        do {
            if !cloned {
                var buffer = [UInt8](repeating: 0, count: 1_048_576)
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else {
                        throw PhotoInputPreflightFailure(issue: .sourceChanged(relativePath: source.safeDisplayName))
                    }
                    if count == 0 { break }
                    var offset = 0
                    while offset < count {
                        let written = buffer.withUnsafeBytes {
                            Darwin.write(output, $0.baseAddress?.advanced(by: offset), count - offset)
                        }
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else {
                            throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
                        }
                        offset += written
                    }
                }
            }
            guard fchmod(output, S_IRUSR | S_IWUSR) == 0,
                  fsync(output) == 0 else {
                throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
            }
            var status = stat()
            guard fstat(output, &status) == 0,
                  status.st_size == source.evidence.size,
                  status.st_uid == getuid(),
                  status.st_nlink == 1,
                  status.st_mode & mode_t(0o7777) == mode_t(0o600) else {
                throw PhotoInputPreflightFailure(issue: .copyFailed(relativePath: source.safeDisplayName))
            }
            return root.appendingPathComponent(leaf)
        } catch {
            _ = leaf.withCString { unlinkat(rootDescriptor, $0, 0) }
            throw error
        }
    }

    private static func removePrivateLeaf(_ url: URL, expectedSize: Int64, root: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_size == expectedSize,
              status.st_mode & mode_t(0o7777) == mode_t(0o600) else { return }
        try unlinkPrivateOutput(url, root: root)
    }

    private static func unlinkPrivateOutput(_ url: URL, root: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { return }
        defer { Darwin.close(rootDescriptor) }
        _ = url.lastPathComponent.withCString { unlinkat(rootDescriptor, $0, 0) }
    }

    private static func hashDescriptor(_ descriptor: Int32) throws -> (sha256: String, byteCount: Int64) {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw CocoaError(.fileReadUnknown) }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            total += Int64(count)
            hasher.update(data: Data(buffer[0..<count]))
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            total
        )
    }

    private static func rawProxyBudget(sourceBytes: Int64, maximumDimension: Int) -> Int64 {
        let pixels = Int64(maximumDimension) * Int64(maximumDimension)
        return sourceBytes + pixels * 4 + 1_048_576
    }

    private static func rawOutputBudget(
        inspection: RawPhotoInspection,
        maximumDimension: Int
    ) -> Int64 {
        let scale = min(
            1.0,
            Double(maximumDimension) / Double(max(
                inspection.nativeDimensions.width,
                inspection.nativeDimensions.height
            ))
        )
        let width = Int64(ceil(Double(inspection.nativeDimensions.width) * scale))
        let height = Int64(ceil(Double(inspection.nativeDimensions.height) * scale))
        return width * height * 4 + height + 1_048_576
    }

    private static func evenlySpaced<Element>(_ items: [Element], targetCount: Int) -> [Element] {
        guard targetCount > 0, !items.isEmpty else { return [] }
        guard items.count > targetCount else { return items }
        guard targetCount > 1 else { return [items[items.count / 2]] }
        let step = Double(items.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { items[Int((Double($0) * step).rounded())] }
    }

    private static func makeStagingContainer(parent: URL) throws -> URL {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var literalParentStatus = stat()
        guard lstat(parent.path, &literalParentStatus) == 0,
              (literalParentStatus.st_mode & S_IFMT) == S_IFDIR,
              let canonicalPointer = realpath(parent.path, nil) else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        defer { free(canonicalPointer) }
        let canonicalParent = URL(fileURLWithPath: String(cString: canonicalPointer))
        let parentDescriptor = try openDirectoryRefusingSymlinks(canonicalParent)
        defer { Darwin.close(parentDescriptor) }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              parentStatus.st_dev == literalParentStatus.st_dev,
              parentStatus.st_ino == literalParentStatus.st_ino,
              parentStatus.st_uid == getuid(),
              parentStatus.st_nlink >= 1,
              parentStatus.st_mode & mode_t(0o022) == 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        let leaf = ".easysplat-photo-input-staging"
        let createResult = leaf.withCString { mkdirat(parentDescriptor, $0, S_IRWXU) }
        if createResult != 0, errno != EEXIST {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        let containerDescriptor = leaf.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard containerDescriptor >= 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        defer { Darwin.close(containerDescriptor) }
        var containerStatus = stat()
        guard fstat(containerDescriptor, &containerStatus) == 0,
              (containerStatus.st_mode & S_IFMT) == S_IFDIR,
              containerStatus.st_uid == getuid(),
              containerStatus.st_nlink >= 1,
              containerStatus.st_dev == parentStatus.st_dev,
              fchmod(containerDescriptor, S_IRWXU) == 0,
              fsync(parentDescriptor) == 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        return canonicalParent.appendingPathComponent(leaf, isDirectory: true)
    }

    private static func makeStagingRoot(container: URL) throws -> URL {
        let containerDescriptor = Darwin.open(
            container.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard containerDescriptor >= 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        defer { Darwin.close(containerDescriptor) }
        var containerStatus = stat()
        guard fstat(containerDescriptor, &containerStatus) == 0,
              PhotoFileEvidence(containerStatus).isPrivateDirectory else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        for _ in 0..<8 {
            let leaf = "run-\(UUID().uuidString)"
            let createResult = leaf.withCString { mkdirat(containerDescriptor, $0, S_IRWXU) }
            if createResult == 0 {
                let rootDescriptor = leaf.withCString {
                    openat(
                        containerDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard rootDescriptor >= 0 else {
                    throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
                }
                defer { Darwin.close(rootDescriptor) }
                var rootStatus = stat()
                guard fstat(rootDescriptor, &rootStatus) == 0,
                      (rootStatus.st_mode & S_IFMT) == S_IFDIR,
                      rootStatus.st_uid == getuid(),
                      rootStatus.st_dev == containerStatus.st_dev,
                      fchmod(rootDescriptor, S_IRWXU) == 0,
                      fsync(containerDescriptor) == 0 else {
                    throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
                }
                return container.appendingPathComponent(leaf, isDirectory: true)
            }
            if errno != EEXIST {
                throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
            }
        }
        throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
    }

    /// Opens a directory, refusing the whole path if any part of it is a
    /// symbolic link.
    ///
    /// This used to walk from the root a component at a time, opening each one
    /// with `O_NOFOLLOW`. Inside the App Sandbox that cannot work: the app may
    /// not open `/Users`, so the walk failed at its first step no matter which
    /// directory it was asked for, and staging was never created. The kernel
    /// applies the same rule to the whole path with `O_NOFOLLOW_ANY`, which
    /// needs no read access to any parent directory.
    private static func openDirectoryRefusingSymlinks(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PhotoInputPreflightFailure(issue: .stagingUnavailable)
        }
        return descriptor
    }

    private static func evidence(at url: URL) -> PhotoFileEvidence? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return PhotoFileEvidence(status)
    }

    private static func defaultPhotoAvailableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let ordinary = values.volumeAvailableCapacity.map(Int64.init),
              let important = values.volumeAvailableCapacityForImportantUsage,
              ordinary >= 0, important >= 0 else {
            throw PhotoInputPreflightFailure(issue: .capacityUnavailable)
        }
        return min(ordinary, important)
    }

    private static func safePhotoDisplayName(_ value: String, index: Int) -> String {
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
                && $0.properties.generalCategory != .format
        }
        let bounded = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? "Photo \(index + 1)" : String(bounded.prefix(96))
    }

    private static func controlledPhotoExtension(for typeIdentifier: String) -> String? {
        switch typeIdentifier {
        case "public.jpeg": return "jpg"
        case "public.png": return "png"
        case "public.heic": return "heic"
        case "public.heif": return "heif"
        default: return nil
        }
    }

    private static func defaultPhotoContentType(_ descriptorURL: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(
            descriptorURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return CGImageSourceGetType(source) as String?
    }

    private static func rawHintedPhotoContentType(
        _ descriptorURL: URL,
        declaredFilename: String
    ) -> String? {
        let pathExtension = (declaredFilename as NSString).pathExtension
        guard let declaredType = UTType(filenameExtension: pathExtension),
              declaredType.conforms(to: .rawImage) else {
            return nil
        }
        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceTypeIdentifierHint: declaredType.identifier,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(
            descriptorURL as CFURL,
            options
        ),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              UTType(typeIdentifier)?.conforms(to: .rawImage) == true else {
            return nil
        }
        return typeIdentifier
    }
}
