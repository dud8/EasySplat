import CryptoKit
import Darwin
import Foundation

package typealias PreparedTrainingManifestPersistence = @Sendable (
    Data,
    TrainingArtifact,
    ValidatedPlyArtifactEvidence,
    PreparedTrainingManifestSourceIdentity,
    ProjectPaths
) throws -> Void

package typealias DescriptorBoundPreparedTrainingManifestPersistence = @Sendable (
    Data,
    TrainingArtifact,
    ValidatedPlyArtifactEvidence,
    PreparedTrainingManifestSourceIdentity,
    ProjectPaths,
    Int32
) throws -> Void

private typealias OptionalDescriptorPreparedTrainingManifestPersistence = (
    Data,
    TrainingArtifact,
    ValidatedPlyArtifactEvidence,
    PreparedTrainingManifestSourceIdentity,
    ProjectPaths,
    Int32?
) throws -> Void

private struct PublishedProjectDirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        owner = status.st_uid
        mode = status.st_mode
    }
}

private func duplicatePublishedProjectRootDescriptor(
    _ descriptor: Int32?
) throws -> Int32? {
    guard let descriptor else { return nil }
    let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
    guard duplicate >= 0 else {
        throw PublishedResultPairError.publicationConflict(
            "the project root descriptor could not be retained"
        )
    }
    var status = stat()
    guard Darwin.fstat(duplicate, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR,
          status.st_uid == getuid(),
          (status.st_mode & 0o022) == 0 else {
        Darwin.close(duplicate)
        throw PublishedResultPairError.publicationConflict(
            "the project root descriptor is unsafe"
        )
    }
    return duplicate
}

private func publishedProjectRootDescriptorMatchesPath(
    _ descriptor: Int32,
    path: String
) -> Bool {
    var opened = stat()
    var named = stat()
    return Darwin.fstat(descriptor, &opened) == 0
        && Darwin.lstat(path, &named) == 0
        && (opened.st_mode & S_IFMT) == S_IFDIR
        && (named.st_mode & S_IFMT) == S_IFDIR
        && opened.st_dev == named.st_dev
        && opened.st_ino == named.st_ino
}

/// Resolves the kernel's current name for a retained directory descriptor.
/// This is used only after the authority-conferring receipt is durable and the
/// caller's original pathname has stopped naming that descriptor. It lets the
/// pair store finish reconciliation on the displaced tree without consulting or
/// mutating the copied replacement now present at `paths.root`.
private func publishedProjectPathsBoundToDescriptor(
    _ descriptor: Int32
) throws -> ProjectPaths {
    // Swift exposes F_GETPATH through fcntl's typed flock overload. Aligned
    // flock storage supplies the MAXPATHLEN byte buffer required by the kernel.
    let storageCount = (
        Int(MAXPATHLEN) + MemoryLayout<Darwin.flock>.stride - 1
    ) / MemoryLayout<Darwin.flock>.stride
    var storage = [Darwin.flock](
        repeating: Darwin.flock(),
        count: storageCount
    )
    _ = storage.withUnsafeMutableBytes { bytes in
        bytes.initializeMemory(as: UInt8.self, repeating: 0)
    }
    let status = storage.withUnsafeMutableBufferPointer { buffer in
        Darwin.fcntl(descriptor, F_GETPATH, buffer.baseAddress!)
    }
    guard status == 0 else {
        throw PublishedResultPairError.publicationConflict(
            "the retained project root location could not be resolved"
        )
    }
    let bytes = storage.withUnsafeBytes {
        Array($0.prefix(Int(MAXPATHLEN)))
    }
    guard let terminator = bytes.firstIndex(of: 0),
          terminator > 1,
          let path = String(bytes: bytes[..<terminator], encoding: .utf8),
          path.hasPrefix("/"),
          !path.contains("\0") else {
        throw PublishedResultPairError.publicationConflict(
            "the retained project root location is unsafe"
        )
    }
    let components = path.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard components.first?.isEmpty == true,
          components.dropFirst().allSatisfy({
              !$0.isEmpty && $0 != "." && $0 != ".."
          }) else {
        throw PublishedResultPairError.publicationConflict(
            "the retained project root location is unsafe"
        )
    }
    let paths = ProjectPaths(
        root: URL(fileURLWithPath: path, isDirectory: true)
    )
    guard publishedProjectRootDescriptorMatchesPath(
        descriptor,
        path: paths.root.path
    ) else {
        throw PublishedResultPairError.publicationConflict(
            "the retained project root location changed"
        )
    }
    return paths
}

private final class PublishedResultPublicationAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var proposedReceipt: PublishedSplatReceipt?
    private var receiptAuthorityCommitted = false

    var committedReceipt: PublishedSplatReceipt? {
        lock.withLock {
            receiptAuthorityCommitted ? proposedReceipt : nil
        }
    }

    func recordProposedReceipt(_ receipt: PublishedSplatReceipt) {
        lock.withLock { proposedReceipt = receipt }
    }

    func markReceiptAuthorityCommitted() {
        lock.withLock { receiptAuthorityCommitted = true }
    }
}

private func validatePublishedProjectRelativePath(_ relativePath: String) throws {
    guard !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          !relativePath.contains("\\") else {
        throw PublishedResultPairError.publicationConflict(
            "the project artifact path is unsafe"
        )
    }
    let components = relativePath.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard !components.isEmpty,
          components.count <= 64,
          components.allSatisfy({ component in
              !component.isEmpty
                  && component != "."
                  && component != ".."
                  && !component.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  })
          }) else {
        throw PublishedResultPairError.publicationConflict(
            "the project artifact path is unsafe"
        )
    }
}

private final class BoundPublishedProjectFile {
    let data: Data

    private let rootURL: URL?
    private let directoryName: String
    private let leafName: String
    private let rootDescriptor: Int32
    private let directoryDescriptor: Int32
    private let descriptor: Int32
    private let rootIdentity: PublishedProjectDirectoryIdentity
    private let directoryIdentity: PublishedProjectDirectoryIdentity
    private let identity: PreparedTrainingManifestSourceIdentity

    var sourceIdentity: PreparedTrainingManifestSourceIdentity { identity }

    private init(
        data: Data,
        rootURL: URL?,
        directoryName: String,
        leafName: String,
        rootDescriptor: Int32,
        directoryDescriptor: Int32,
        descriptor: Int32,
        rootIdentity: PublishedProjectDirectoryIdentity,
        directoryIdentity: PublishedProjectDirectoryIdentity,
        identity: PreparedTrainingManifestSourceIdentity
    ) {
        self.data = data
        self.rootURL = rootURL
        self.directoryName = directoryName
        self.leafName = leafName
        self.rootDescriptor = rootDescriptor
        self.directoryDescriptor = directoryDescriptor
        self.descriptor = descriptor
        self.rootIdentity = rootIdentity
        self.directoryIdentity = directoryIdentity
        self.identity = identity
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(directoryDescriptor)
        Darwin.close(rootDescriptor)
    }

    static func open(
        paths: ProjectPaths,
        projectRootDescriptor suppliedRootDescriptor: Int32? = nil,
        directoryName: String,
        leafName: String,
        maximumBytes: Int,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> BoundPublishedProjectFile {
        if shouldCancel() { throw CancellationError() }
        let rootDescriptor: Int32
        let rootURL: URL?
        if let suppliedRootDescriptor {
            rootDescriptor = Darwin.fcntl(
                suppliedRootDescriptor,
                F_DUPFD_CLOEXEC,
                0
            )
            rootURL = nil
        } else {
            rootDescriptor = Darwin.open(
                paths.root.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            rootURL = paths.root
        }
        guard rootDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "the project root could not be opened safely"
            )
        }
        var directoryDescriptor: Int32 = -1
        var descriptor: Int32 = -1
        var ownershipTransferred = false
        defer {
            if !ownershipTransferred {
                if descriptor >= 0 { Darwin.close(descriptor) }
                if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) }
                Darwin.close(rootDescriptor)
            }
        }
        let rootIdentity = if let rootURL {
            try requireDirectory(
                descriptor: rootDescriptor,
                absolutePath: rootURL.path
            )
        } else {
            try requireDirectory(descriptor: rootDescriptor)
        }
        if shouldCancel() { throw CancellationError() }
        directoryDescriptor = directoryName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "the project artifact directory could not be opened safely"
            )
        }
        let directoryIdentity = try requireDirectory(
            descriptor: directoryDescriptor,
            parent: rootDescriptor,
            name: directoryName
        )
        descriptor = leafName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "the project artifact could not be opened safely"
            )
        }
        let identity = try requireFile(
            descriptor: descriptor,
            parent: directoryDescriptor,
            name: leafName
        )
        guard identity.byteCount > 0,
              identity.byteCount <= off_t(maximumBytes) else {
            throw PublishedResultPairError.publicationConflict(
                "the project artifact is not bounded"
            )
        }
        if shouldCancel() { throw CancellationError() }
        var data = Data(count: Int(identity.byteCount))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                if shouldCancel() { throw CancellationError() }
                let count = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0, count <= bytes.count - offset else {
                    throw PublishedResultPairError.publicationConflict(
                        "the project artifact changed while being read"
                    )
                }
                offset += count
            }
        }
        let bound = BoundPublishedProjectFile(
            data: data,
            rootURL: rootURL,
            directoryName: directoryName,
            leafName: leafName,
            rootDescriptor: rootDescriptor,
            directoryDescriptor: directoryDescriptor,
            descriptor: descriptor,
            rootIdentity: rootIdentity,
            directoryIdentity: directoryIdentity,
            identity: identity
        )
        ownershipTransferred = true
        guard bound.isStillCanonical() else {
            throw PublishedResultPairError.publicationConflict(
                "the project artifact changed while being read"
            )
        }
        return bound
    }

    func isStillCanonical() -> Bool {
        guard let currentRoot = try? Self.requireDirectory(
            descriptor: rootDescriptor
        ), currentRoot == rootIdentity,
        let currentDirectory = try? Self.requireDirectory(
            descriptor: directoryDescriptor,
            parent: rootDescriptor,
            name: directoryName
        ), currentDirectory == directoryIdentity,
        let currentFile = try? Self.requireFile(
            descriptor: descriptor,
            parent: directoryDescriptor,
            name: leafName
        ), currentFile == identity else {
            return false
        }
        if let rootURL {
            guard let namedRoot = try? Self.requireDirectory(
                descriptor: rootDescriptor,
                absolutePath: rootURL.path
            ), namedRoot == rootIdentity else {
                return false
            }
        }
        return true
    }

    private static func requireDirectory(
        descriptor: Int32
    ) throws -> PublishedProjectDirectoryIdentity {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              safeDirectory(opened) else {
            throw PublishedResultPairError.publicationConflict(
                "the project directory changed"
            )
        }
        return PublishedProjectDirectoryIdentity(opened)
    }

    private static func requireDirectory(
        descriptor: Int32,
        absolutePath: String
    ) throws -> PublishedProjectDirectoryIdentity {
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              Darwin.lstat(absolutePath, &named) == 0,
              safeDirectory(opened),
              PublishedProjectDirectoryIdentity(opened)
                == PublishedProjectDirectoryIdentity(named) else {
            throw PublishedResultPairError.publicationConflict(
                "the project directory changed"
            )
        }
        return PublishedProjectDirectoryIdentity(opened)
    }

    private static func requireDirectory(
        descriptor: Int32,
        parent: Int32,
        name: String
    ) throws -> PublishedProjectDirectoryIdentity {
        var opened = stat()
        var named = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &opened) == 0,
              result == 0,
              safeDirectory(opened),
              PublishedProjectDirectoryIdentity(opened)
                == PublishedProjectDirectoryIdentity(named) else {
            throw PublishedResultPairError.publicationConflict(
                "the project artifact directory changed"
            )
        }
        return PublishedProjectDirectoryIdentity(opened)
    }

    private static func requireFile(
        descriptor: Int32,
        parent: Int32,
        name: String
    ) throws -> PreparedTrainingManifestSourceIdentity {
        var opened = stat()
        var named = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &opened) == 0,
              result == 0,
              safeFile(opened),
              PreparedTrainingManifestSourceIdentity(opened)
                == PreparedTrainingManifestSourceIdentity(named) else {
            throw PublishedResultPairError.publicationConflict(
                "the project artifact changed"
            )
        }
        return PreparedTrainingManifestSourceIdentity(opened)
    }

    private static func safeDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == getuid()
            && (status.st_mode & 0o022) == 0
    }

    private static func safeFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == getuid()
            && status.st_nlink == 1
            && (status.st_mode & 0o022) == 0
    }
}

/// Holds the exact canonical training-manifest file open while recovery checks
/// the published pair. Revalidating both the descriptor and its openat-bound
/// canonical entry keeps a replacement from inheriting the old file's authority.
private final class BoundPublishedTrainingManifest {
    let artifact: TrainingArtifact
    let data: Data
    var sourceIdentity: PreparedTrainingManifestSourceIdentity {
        file.sourceIdentity
    }

    private let file: BoundPublishedProjectFile

    private init(
        artifact: TrainingArtifact,
        data: Data,
        file: BoundPublishedProjectFile
    ) {
        self.artifact = artifact
        self.data = data
        self.file = file
    }

    static func open(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> BoundPublishedTrainingManifest {
        let file = try BoundPublishedProjectFile.open(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            directoryName: "Training",
            leafName: "training_manifest.json",
            maximumBytes: PublishedSplatReceiptStore.maximumBytes,
            shouldCancel: shouldCancel
        )
        if shouldCancel() { throw CancellationError() }
        let artifact = try JSONDecoder().decode(
            TrainingArtifact.self,
            from: file.data
        )
        let canonicalData: Data
        if let projectRootDescriptor {
            canonicalData = try TrainingArtifactStore.encodedManifestData(
                artifact,
                projectPaths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        } else {
            canonicalData = try TrainingArtifactStore.encodedManifestData(
                artifact,
                projectPaths: paths
            )
        }
        guard file.data == canonicalData else {
            throw PublishedResultPairError.publicationConflict(
                "the completed training manifest is not canonical"
            )
        }
        return BoundPublishedTrainingManifest(
            artifact: artifact,
            data: file.data,
            file: file
        )
    }

    func isStillCanonical() -> Bool {
        file.isStillCanonical()
    }
}

private final class BoundPublishedGeometryManifest {
    let artifact: GeometryArtifact
    let digest: String

    private let file: BoundPublishedProjectFile

    private init(
        artifact: GeometryArtifact,
        digest: String,
        file: BoundPublishedProjectFile
    ) {
        self.artifact = artifact
        self.digest = digest
        self.file = file
    }

    static func open(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> BoundPublishedGeometryManifest {
        let file = try BoundPublishedProjectFile.open(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            directoryName: "SfM",
            leafName: "geometry_manifest.json",
            maximumBytes: GeometryArtifactStore.maximumManifestBytes,
            shouldCancel: shouldCancel
        )
        if shouldCancel() { throw CancellationError() }
        let artifact = try JSONDecoder().decode(
            GeometryArtifact.self,
            from: file.data
        )
        guard artifact.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw PublishedResultPairError.publicationConflict(
                "the canonical geometry manifest has an unsupported schema"
            )
        }
        try validatePublishedProjectRelativePath(artifact.sourceModelPath)
        let digest = SHA256.hash(data: file.data).map {
            String(format: "%02x", $0)
        }.joined()
        return BoundPublishedGeometryManifest(
            artifact: artifact,
            digest: digest,
            file: file
        )
    }

    func isStillCanonical() -> Bool {
        file.isStillCanonical()
    }
}

/// Publishes the trainer-private PLY and its authority receipt as one pair, then
/// durably rebinds the training manifest to that canonical pair. If a crash
/// occurs between those boundaries, the exact committed receipt is adopted on
/// retry instead of assigning the same bytes a second publication identity.
package enum PublishedResultPublisher {
    /// Records the first current-result viewer readiness without changing the
    /// publication UUID or any lineage. A repeated identical callback is a
    /// no-op; conflicting or stale callbacks fail closed.
    package static func recordFirstViewerReadyTiming(
        _ seconds: Double,
        publicationID: UUID,
        expectedGeneration: PublishedResultGeneration? = nil,
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        pairOperations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        beforeLockedUpdate: @escaping @Sendable () -> Void = {}
    ) throws -> ValidatedPublishedResult {
        try PublishedResultPairStore.recordFirstViewerReadyTiming(
            seconds,
            expectedPublicationID: publicationID,
            expectedGeneration: expectedGeneration,
            projectPaths: paths,
            projectRootDescriptor: projectRootDescriptor,
            operations: pairOperations,
            shouldCancel: shouldCancel,
            beforeLockedUpdate: beforeLockedUpdate
        )
    }

    /// Resolves a completed canonical publication without independently hashing
    /// the PLY a second time. The pair resolver supplies the single validated
    /// evidence record used to bind the manifest and result-era receipt.
    package static func resolveCompletedTraining(
        metadata: ProjectMetadata,
        resolvedRunPlan: ResolvedRunPlan,
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        pairOperations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ValidatedPublishedResult? {
        if shouldCancel() { throw CancellationError() }
        let retainedProjectRootDescriptor = try
            duplicatePublishedProjectRootDescriptor(projectRootDescriptor)
        defer {
            if let retainedProjectRootDescriptor {
                Darwin.close(retainedProjectRootDescriptor)
            }
        }
        let boundManifest = try BoundPublishedTrainingManifest.open(
            paths: paths,
            projectRootDescriptor: retainedProjectRootDescriptor,
            shouldCancel: shouldCancel
        )
        let boundGeometry = try BoundPublishedGeometryManifest.open(
            paths: paths,
            projectRootDescriptor: retainedProjectRootDescriptor,
            shouldCancel: shouldCancel
        )
        let training = boundManifest.artifact
        guard training.completionStatus == .completed,
              training.outputPath == PublishedSplatReceipt.canonicalOutputPath,
              boundGeometry.digest
                == training.datasetDerivation.sourceGeometryManifestSHA256 else {
            return nil
        }
        let manifest = boundManifest.data
        guard case .available(let result) = try PublishedResultPairStore.resolve(
            projectPaths: paths,
            projectRootDescriptor: retainedProjectRootDescriptor,
            operations: pairOperations,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }
        if shouldCancel() { throw CancellationError() }
        let expected = try PublishedSplatReceiptFactory.makeAdoptionCandidate(
            existing: result.receipt,
            metadata: metadata,
            resolvedRunPlan: resolvedRunPlan,
            geometry: boundGeometry.artifact,
            geometryManifestDigest: boundGeometry.digest,
            reboundTraining: training,
            reboundTrainingManifestData: manifest,
            outputEvidence: result.outputEvidence,
            projectPaths: paths,
            projectRootDescriptor: retainedProjectRootDescriptor
        )
        if shouldCancel() { throw CancellationError() }
        guard PublishedSplatReceiptFactory.isBound(result.receipt, to: expected) else {
            return nil
        }
        guard boundManifest.isStillCanonical(),
              boundGeometry.isStillCanonical() else { return nil }
        return result
    }

    package static func publishCompletedTraining(
        metadata: ProjectMetadata,
        resolvedRunPlan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        paths: ProjectPaths,
        publicationID: UUID,
        publishedAt: Date,
        expectedDatasetDerivation: MsplatDatasetDerivationArtifact? = nil,
        pairOperations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        beforePublish: @escaping @Sendable () -> Void = {},
        persistPreparedManifest: @escaping PreparedTrainingManifestPersistence = {
            data,
            artifact,
            evidence,
            expectedSourceIdentity,
            paths in
            try TrainingArtifactStore.persistPreparedManifest(
                data,
                artifact: artifact,
                validatedOutputEvidence: evidence,
                expectedSourceIdentity: expectedSourceIdentity,
                paths: paths
            )
        }
    ) throws -> ValidatedPublishedResult {
        try publishCompletedTrainingBound(
            metadata: metadata,
            resolvedRunPlan: resolvedRunPlan,
            geometry: geometry,
            paths: paths,
            projectRootDescriptor: nil,
            publicationID: publicationID,
            publishedAt: publishedAt,
            expectedDatasetDerivation: expectedDatasetDerivation,
            pairOperations: pairOperations,
            shouldCancel: shouldCancel,
            beforePublish: beforePublish,
            persistPreparedManifest: {
                data,
                artifact,
                evidence,
                expectedSourceIdentity,
                paths,
                descriptor in
                precondition(descriptor == nil)
                try persistPreparedManifest(
                    data,
                    artifact,
                    evidence,
                    expectedSourceIdentity,
                    paths
                )
            }
        )
    }

    /// Publishes while retaining authority over one lease-owned project root.
    /// Every filesystem participant duplicates this descriptor; none reopens
    /// `paths.root`, even if that pathname is replaced during publication.
    package static func publishCompletedTraining(
        metadata: ProjectMetadata,
        resolvedRunPlan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        publicationID: UUID,
        publishedAt: Date,
        expectedDatasetDerivation: MsplatDatasetDerivationArtifact? = nil,
        pairOperations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        beforePublish: @escaping @Sendable () -> Void = {},
        persistPreparedManifest: @escaping DescriptorBoundPreparedTrainingManifestPersistence = {
            data,
            artifact,
            evidence,
            expectedSourceIdentity,
            paths,
            projectRootDescriptor in
            try TrainingArtifactStore.persistPreparedManifest(
                data,
                artifact: artifact,
                validatedOutputEvidence: evidence,
                expectedSourceIdentity: expectedSourceIdentity,
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        }
    ) throws -> ValidatedPublishedResult {
        try publishCompletedTrainingBound(
            metadata: metadata,
            resolvedRunPlan: resolvedRunPlan,
            geometry: geometry,
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            publicationID: publicationID,
            publishedAt: publishedAt,
            expectedDatasetDerivation: expectedDatasetDerivation,
            pairOperations: pairOperations,
            shouldCancel: shouldCancel,
            beforePublish: beforePublish,
            persistPreparedManifest: {
                data,
                artifact,
                evidence,
                expectedSourceIdentity,
                paths,
                descriptor in
                guard let descriptor else {
                    throw PublishedResultPairError.publicationConflict(
                        "the project root descriptor was lost"
                    )
                }
                try persistPreparedManifest(
                    data,
                    artifact,
                    evidence,
                    expectedSourceIdentity,
                    paths,
                    descriptor
                )
            }
        )
    }

    private static func publishCompletedTrainingBound(
        metadata: ProjectMetadata,
        resolvedRunPlan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        paths: ProjectPaths,
        projectRootDescriptor: Int32?,
        publicationID: UUID,
        publishedAt: Date,
        expectedDatasetDerivation: MsplatDatasetDerivationArtifact?,
        pairOperations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool,
        beforePublish: @escaping @Sendable () -> Void,
        persistPreparedManifest: OptionalDescriptorPreparedTrainingManifestPersistence
    ) throws -> ValidatedPublishedResult {
        if shouldCancel() { throw CancellationError() }
        let retainedProjectRootDescriptor = try
            duplicatePublishedProjectRootDescriptor(projectRootDescriptor)
        defer {
            if let retainedProjectRootDescriptor {
                Darwin.close(retainedProjectRootDescriptor)
            }
        }
        guard metadata.pendingPublicationID == publicationID else {
            throw PublishedResultPairError.publicationConflict(
                "the proposed publication does not match the durable run identity"
            )
        }
        let boundTrainingManifest = try BoundPublishedTrainingManifest.open(
            paths: paths,
            projectRootDescriptor: retainedProjectRootDescriptor,
            shouldCancel: shouldCancel
        )
        let boundGeometryManifest = try BoundPublishedGeometryManifest.open(
            paths: paths,
            projectRootDescriptor: retainedProjectRootDescriptor,
            shouldCancel: shouldCancel
        )
        let persistedTraining = boundTrainingManifest.artifact
        guard persistedTraining.completionStatus == .completed,
              persistedTraining.outputPath == "Training/msplat/splat.ply"
                || persistedTraining.outputPath == PublishedSplatReceipt.canonicalOutputPath else {
            throw PublishedResultPairError.invalidSource
        }
        if let expectedDatasetDerivation,
           persistedTraining.datasetDerivation != expectedDatasetDerivation {
            throw PublishedResultPairError.publicationConflict(
                "the completed training manifest no longer matches the validated dataset"
            )
        }
        guard boundGeometryManifest.artifact == geometry,
              boundGeometryManifest.digest
                == persistedTraining.datasetDerivation.sourceGeometryManifestSHA256 else {
            throw PublishedResultPairError.publicationConflict(
                "the canonical geometry manifest changed before publication"
            )
        }

        var reboundTraining = persistedTraining
        reboundTraining.outputPath = PublishedSplatReceipt.canonicalOutputPath
        if shouldCancel() { throw CancellationError() }
        let reboundManifest: Data
        if let retainedProjectRootDescriptor {
            reboundManifest = try TrainingArtifactStore.encodedManifestData(
                reboundTraining,
                projectPaths: paths,
                projectRootDescriptor: retainedProjectRootDescriptor
            )
        } else {
            reboundManifest = try TrainingArtifactStore.encodedManifestData(
                reboundTraining,
                projectPaths: paths
            )
        }
        func requireCanonicalGeometry() throws -> GeometryArtifact {
            guard boundGeometryManifest.isStillCanonical(),
                  boundGeometryManifest.artifact == geometry,
                  boundGeometryManifest.digest
                    == persistedTraining.datasetDerivation.sourceGeometryManifestSHA256 else {
                throw PublishedResultPairError.publicationConflict(
                    "the canonical geometry manifest changed before publication"
                )
            }
            return boundGeometryManifest.artifact
        }
        func currentCanonicalGeometry() throws -> GeometryArtifact {
            if shouldCancel() { throw CancellationError() }
            let canonicalGeometry = try requireCanonicalGeometry()
            if shouldCancel() { throw CancellationError() }
            return canonicalGeometry
        }
        func proposedReceipt(
            evidence: ValidatedPlyArtifactEvidence,
            canonicalGeometry: GeometryArtifact,
            publicationDate: Date
        ) throws -> PublishedSplatReceipt {
            do {
                try TrainingArtifactStore.validateCompletedOutput(
                    persistedTraining,
                    evidence: evidence
                )
            } catch {
                throw PublishedResultPairError.invalidSource
            }
            return try PublishedSplatReceiptFactory.make(
                metadata: metadata,
                resolvedRunPlan: resolvedRunPlan,
                geometry: canonicalGeometry,
                geometryManifestDigest: boundGeometryManifest.digest,
                reboundTraining: reboundTraining,
                reboundTrainingManifestData: reboundManifest,
                outputEvidence: evidence,
                projectPaths: paths,
                projectRootDescriptor: retainedProjectRootDescriptor,
                publicationID: publicationID,
                publishedAt: publicationDate
            )
        }

        func requirePublicationInputsUnchanged() throws {
            guard boundTrainingManifest.isStillCanonical() else {
                throw PublishedResultPairError.publicationConflict(
                    "the completed training manifest changed before publication"
                )
            }
            _ = try currentCanonicalGeometry()
            guard boundTrainingManifest.isStillCanonical() else {
                throw PublishedResultPairError.publicationConflict(
                    "the completed training manifest changed before publication"
                )
            }
        }

        func canonicalTrainingManifestForThisAttempt(
            using manifestPaths: ProjectPaths,
            reportCancellation: Bool
        ) throws -> BoundPublishedTrainingManifest {
            if boundTrainingManifest.isStillCanonical() {
                return boundTrainingManifest
            }
            let manifestCancellationCheck: @Sendable () -> Bool
            if reportCancellation {
                manifestCancellationCheck = shouldCancel
            } else {
                manifestCancellationCheck = { false }
            }
            let rebound = try BoundPublishedTrainingManifest.open(
                paths: manifestPaths,
                projectRootDescriptor: retainedProjectRootDescriptor,
                shouldCancel: manifestCancellationCheck
            )
            guard rebound.data == reboundManifest,
                  rebound.artifact == reboundTraining else {
                throw PublishedResultPairError.publicationConflict(
                    "the completed training manifest changed before adoption"
                )
            }
            return rebound
        }

        func requireAdoptionInputsUnchanged() throws {
            _ = try canonicalTrainingManifestForThisAttempt(
                using: paths,
                reportCancellation: true
            )
            _ = try currentCanonicalGeometry()
            _ = try canonicalTrainingManifestForThisAttempt(
                using: paths,
                reportCancellation: true
            )
        }

        func persistManifest(
            _ result: ValidatedPublishedResult,
            using persistencePaths: ProjectPaths,
            reportCancellation: Bool
        ) throws {
            let sourceManifest = try canonicalTrainingManifestForThisAttempt(
                using: persistencePaths,
                reportCancellation: reportCancellation
            )
            try persistPreparedManifest(
                reboundManifest,
                reboundTraining,
                result.outputEvidence,
                sourceManifest.sourceIdentity,
                persistencePaths,
                retainedProjectRootDescriptor
            )
            // Receipt installation is the authority-conferring commit. Surface
            // cancellation only after the exact manifest it authenticates is
            // durable, while the pair lock still protects the decision.
            if reportCancellation, shouldCancel() { throw CancellationError() }
        }

        func persistManifest(_ result: ValidatedPublishedResult) throws {
            try persistManifest(
                result,
                using: paths,
                reportCancellation: true
            )
        }

        func finishCommittedPublicationAfterRootReplacement(
            expectedReceipt: PublishedSplatReceipt,
            projectRootDescriptor: Int32
        ) throws {
            let reboundPaths = try publishedProjectPathsBoundToDescriptor(
                projectRootDescriptor
            )
            guard reboundPaths.root.path != paths.root.path else {
                throw PublishedResultPairError.publicationConflict(
                    "the displaced project root could not be rebound"
                )
            }
            let committed = try PublishedResultPairStore.commitResolvedResultIf(
                projectPaths: reboundPaths,
                projectRootDescriptor: projectRootDescriptor,
                operations: pairOperations,
                // Receipt authority already committed. From this point onward,
                // pair reconciliation and manifest rebound are non-cancellable.
                shouldCancel: { false },
                matches: { existing in
                    guard existing.receipt == expectedReceipt,
                          existing.outputEvidence == expectedReceipt.outputEvidence,
                          boundTrainingManifest.isStillCanonical(),
                          try requireCanonicalGeometry() == geometry else {
                        return false
                    }
                    return true
                },
                afterCommit: { existing in
                    try persistManifest(
                        existing,
                        using: reboundPaths,
                        reportCancellation: false
                    )
                    let rebound = try BoundPublishedTrainingManifest.open(
                        paths: reboundPaths,
                        projectRootDescriptor: projectRootDescriptor,
                        shouldCancel: { false }
                    )
                    guard rebound.artifact == reboundTraining,
                          rebound.data == reboundManifest,
                          boundGeometryManifest.isStillCanonical() else {
                        throw PublishedResultPairError.publicationConflict(
                            "the committed publication manifest did not revalidate"
                        )
                    }
                }
            )
            guard let committed,
                  committed.receipt == expectedReceipt,
                  committed.outputEvidence == expectedReceipt.outputEvidence else {
                throw PublishedResultPairError.publicationConflict(
                    "the committed publication could not be rebound"
                )
            }
        }

        if let adopted = try PublishedResultPairStore.commitResolvedResultIf(
            projectPaths: paths,
            projectRootDescriptor: retainedProjectRootDescriptor,
            operations: pairOperations,
            shouldCancel: shouldCancel,
            matches: { existing in
                guard boundTrainingManifest.isStillCanonical() else {
                    return false
                }
                guard existing.receipt.publicationID == publicationID else {
                    return false
                }
                let canonicalGeometry = try currentCanonicalGeometry()
                try TrainingArtifactStore.validateCompletedOutput(
                    persistedTraining,
                    evidence: existing.outputEvidence
                )
                let expected = try PublishedSplatReceiptFactory.makeAdoptionCandidate(
                    existing: existing.receipt,
                    metadata: metadata,
                    resolvedRunPlan: resolvedRunPlan,
                    geometry: canonicalGeometry,
                    geometryManifestDigest: boundGeometryManifest.digest,
                    reboundTraining: reboundTraining,
                    reboundTrainingManifestData: reboundManifest,
                    outputEvidence: existing.outputEvidence,
                    projectPaths: paths,
                    projectRootDescriptor: retainedProjectRootDescriptor
                )
                return PublishedSplatReceiptFactory.isBound(
                    existing.receipt,
                    to: expected
                ) && boundTrainingManifest.isStillCanonical()
            },
            afterCommit: persistManifest
        ) {
            return adopted
        }

        guard persistedTraining.outputPath == "Training/msplat/splat.ply" else {
            throw PublishedResultPairError.publicationConflict(
                "the canonical training manifest does not match its receipt"
            )
        }
        if shouldCancel() { throw CancellationError() }
        beforePublish()
        if shouldCancel() { throw CancellationError() }
        let publicationAttempt = PublishedResultPublicationAttempt()
        let reportCheckpoint = pairOperations.didReachCheckpoint
        var publicationOperations = pairOperations
        publicationOperations.didReachCheckpoint = { checkpoint in
            if checkpoint == .newReceiptInstalled {
                publicationAttempt.markReceiptAuthorityCommitted()
            }
            reportCheckpoint(checkpoint)
        }
        do {
            return try PublishedResultPairStore.publish(
                sourceProjectRelativePath: "Training/msplat/splat.ply",
                projectPaths: paths,
                projectRootDescriptor: retainedProjectRootDescriptor,
                operations: publicationOperations,
                shouldCancel: shouldCancel,
                adoptExisting: { existing, proposed in
                    existing.receipt.publicationID == publicationID
                        && PublishedSplatReceiptFactory.isBound(
                            existing.receipt,
                            to: proposed
                        )
                },
                beforeAdopt: requireAdoptionInputsUnchanged,
                beforeCommit: requirePublicationInputsUnchanged,
                afterCommit: persistManifest,
                makeReceipt: { evidence in
                    let canonicalGeometry = try currentCanonicalGeometry()
                    let receipt = try proposedReceipt(
                        evidence: evidence,
                        canonicalGeometry: canonicalGeometry,
                        publicationDate: publishedAt
                    )
                    publicationAttempt.recordProposedReceipt(receipt)
                    return receipt
                }
            )
        } catch let publicationError {
            guard let retainedProjectRootDescriptor,
                  let committedReceipt = publicationAttempt.committedReceipt,
                  !publishedProjectRootDescriptorMatchesPath(
                    retainedProjectRootDescriptor,
                    path: paths.root.path
                  ) else {
                throw publicationError
            }
            try finishCommittedPublicationAfterRootReplacement(
                expectedReceipt: committedReceipt,
                projectRootDescriptor: retainedProjectRootDescriptor
            )
            // Consistency on the descriptor-bound original is now complete.
            // Preserve the path/lease failure so the caller cannot treat the
            // copied pathname replacement as the active project.
            throw publicationError
        }
    }
}
