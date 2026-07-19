import CryptoKit
import Darwin
import Foundation

enum RuntimeInputKind: String, Equatable, Sendable {
    case video
    case photo
}

enum RuntimeInputSnapshotError: Error, Equatable, Sendable {
    case invalidMetadata
    case unsafeSource(kind: RuntimeInputKind, index: Int)
    case sizeMismatch(kind: RuntimeInputKind, index: Int)
    case digestMismatch(kind: RuntimeInputKind, index: Int)
    case sourceChanged(kind: RuntimeInputKind, index: Int)
    case leaseUnavailable
    case capacityUnavailable(kind: RuntimeInputKind, index: Int)
    case insufficientCapacity(kind: RuntimeInputKind, index: Int)
    case copyFailed(kind: RuntimeInputKind, index: Int)
}

/// A per-run, receipt-bound copy of every controlled input. Consumers receive only
/// URLs inside this private directory, never the mutable project `Originals` paths.
final class RuntimeInputSnapshotLease: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let kind: RuntimeInputKind
        let index: Int
        let url: URL
        let projectRelativePath: String
        let byteCount: Int64
        let sha256: String
    }

    typealias CloneSnapshot = (
        _ sourceDescriptor: Int32,
        _ destinationDirectoryDescriptor: Int32,
        _ destinationLeaf: String
    ) throws -> Bool
    typealias CheckCancellation = () throws -> Void
    typealias AvailableCapacity = (
        _ directoryURL: URL
    ) throws -> (ordinary: Int64?, important: Int64?)
    typealias WriteChunk = (
        _ destinationDescriptor: Int32,
        _ bytes: UnsafeRawPointer?,
        _ count: Int
    ) throws -> Int
    typealias LoadPhotoSelectionProjection = (
        _ metadata: ProjectMetadata,
        _ paths: ProjectPaths
    ) throws -> (
        projection: PhotoSelectionProjection?,
        leaseEvidence: PhotoSelectionArtifactLeaseEvidence?
    )

    let directoryURL: URL
    let videos: [Snapshot]
    let photos: [Snapshot]
    let photoSelectionProjection: PhotoSelectionProjection?
    let receiptDigest: String

    private static let parentLeaf = ".runtime-input-leases"
    private static let maximumInputCount = 10_064
    private static let maximumAggregateBytes: Int64 = 512 * 1_024 * 1_024 * 1_024
    private static let bufferSize = 1_048_576

    private let projectRootURL: URL
    private let rootDescriptor: Int32
    private let projectRootEvidence: DirectoryEvidence
    private let parentDescriptor: Int32
    private let runDescriptor: Int32
    private let parentEvidence: DirectoryEvidence
    private let runEvidence: DirectoryEvidence
    private let createdParent: Bool
    private let files: [FileEvidence]
    private let photoSelectionBinding: PhotoSelectionLeaseBinding?
    private let lock = NSLock()
    private var active = true

    private init(
        directoryURL: URL,
        videos: [Snapshot],
        photos: [Snapshot],
        photoSelectionProjection: PhotoSelectionProjection?,
        receiptDigest: String,
        projectRootURL: URL,
        rootDescriptor: Int32,
        projectRootEvidence: DirectoryEvidence,
        parentDescriptor: Int32,
        runDescriptor: Int32,
        parentEvidence: DirectoryEvidence,
        runEvidence: DirectoryEvidence,
        createdParent: Bool,
        files: [FileEvidence],
        photoSelectionBinding: PhotoSelectionLeaseBinding?
    ) {
        self.directoryURL = directoryURL
        self.videos = videos
        self.photos = photos
        self.photoSelectionProjection = photoSelectionProjection
        self.receiptDigest = receiptDigest
        self.projectRootURL = projectRootURL
        self.rootDescriptor = rootDescriptor
        self.projectRootEvidence = projectRootEvidence
        self.parentDescriptor = parentDescriptor
        self.runDescriptor = runDescriptor
        self.parentEvidence = parentEvidence
        self.runEvidence = runEvidence
        self.createdParent = createdParent
        self.files = files
        self.photoSelectionBinding = photoSelectionBinding
    }

    deinit {
        discard()
    }

    func validate() throws {
        let isActive = lock.withLock { active }
        guard isActive,
              projectRootEvidence.isSafeOwnedDirectory,
              parentEvidence.isWritablePrivate,
              runEvidence.isSealedPrivate else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        try Self.verifyLiteralDirectoryBinding(
            url: projectRootURL,
            descriptor: rootDescriptor,
            evidence: projectRootEvidence
        )
        try Self.verifyDirectoryBinding(
            parentDescriptor: rootDescriptor,
            leaf: Self.parentLeaf,
            evidence: parentEvidence
        )
        try Self.verifyDirectoryBinding(
            parentDescriptor: parentDescriptor,
            leaf: directoryURL.lastPathComponent,
            evidence: runEvidence
        )
        var runStatus = stat()
        guard fstat(runDescriptor, &runStatus) == 0,
              runEvidence.matches(runStatus) else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        for file in files {
            var status = stat()
            let result = file.leaf.withCString {
                fstatat(runDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0, file.matches(status) else {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
        }
        if let photoSelectionBinding {
            do {
                try PhotoSelectionArtifactStore.revalidateProjectBoundLeaseEvidence(
                    photoSelectionBinding.evidence,
                    at: photoSelectionBinding.url,
                    projectPaths: photoSelectionBinding.projectPaths
                )
            } catch {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
        }
    }

    func discard() {
        let shouldDiscard = lock.withLock { () -> Bool in
            guard active else { return false }
            active = false
            return true
        }
        guard shouldDiscard else { return }
        defer {
            Darwin.close(runDescriptor)
            Darwin.close(parentDescriptor)
            Darwin.close(rootDescriptor)
        }
        try? Self.removeBoundRun(
            rootDescriptor: rootDescriptor,
            parentDescriptor: parentDescriptor,
            runDescriptor: runDescriptor,
            parentEvidence: parentEvidence,
            runEvidence: runEvidence,
            runLeaf: directoryURL.lastPathComponent,
            files: files,
            createdParent: createdParent
        )
    }

    static func prepare(
        metadata: ProjectMetadata,
        paths: ProjectPaths,
        pairingPolicy: ResolvedPairingPolicy? = nil,
        cloneSnapshot: @escaping CloneSnapshot = defaultCloneSnapshot,
        checkCancellation: @escaping CheckCancellation = { try Task.checkCancellation() },
        availableCapacity: @escaping AvailableCapacity = defaultAvailableCapacity,
        writeChunk: @escaping WriteChunk = defaultWriteChunk,
        loadPhotoSelectionProjection: LoadPhotoSelectionProjection = {
            try PhotoSelectionProjection.loadProjectBoundVerified(
                metadata: $0,
                paths: $1
            )
        }
    ) throws -> RuntimeInputSnapshotLease {
        let photoSelectionProjection: PhotoSelectionProjection?
        let photoSelectionBinding: PhotoSelectionLeaseBinding?
        do {
            try VideoInputReceiptValidator.validateMetadata(metadata, paths: paths)
            try PhotoInputReceiptValidator.validateMetadata(metadata, paths: paths)
            let loaded = try loadPhotoSelectionProjection(metadata, paths)
            photoSelectionProjection = loaded.projection
            photoSelectionBinding = loaded.leaseEvidence.map {
                PhotoSelectionLeaseBinding(
                    url: paths.photoSelectionArtifactURL,
                    projectPaths: paths,
                    evidence: $0
                )
            }
        } catch {
            throw RuntimeInputSnapshotError.invalidMetadata
        }
        let videoBindings = videoBindings(metadata: metadata)
        let photoBindings = photoBindings(metadata: metadata)
        let bindings = videoBindings + photoBindings
        guard !bindings.isEmpty,
              bindings.count <= maximumInputCount,
              try aggregateByteCount(bindings) <= maximumAggregateBytes else {
            throw RuntimeInputSnapshotError.invalidMetadata
        }
        try checkCancellation()

        var rootPathStatus = stat()
        guard lstat(paths.root.path, &rootPathStatus) == 0,
              safeProjectDirectory(rootPathStatus) else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        let rootDescriptor = Darwin.open(
            paths.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        var transferred = false
        var parentDescriptor: Int32 = -1
        var runDescriptor: Int32 = -1
        var originalsDescriptor: Int32 = -1
        var photosDescriptor: Int32 = -1
        var createdParent = false
        var parentEvidence: DirectoryEvidence?
        var runEvidence: DirectoryEvidence?
        var snapshots: [Snapshot] = []
        var fileEvidence: [FileEvidence] = []
        var runLeaf: String?
        defer {
            if photosDescriptor >= 0 { Darwin.close(photosDescriptor) }
            if originalsDescriptor >= 0 { Darwin.close(originalsDescriptor) }
            if !transferred {
                if let parentEvidence,
                   let runEvidence,
                   let runLeaf,
                   parentDescriptor >= 0,
                   runDescriptor >= 0 {
                    try? removeBoundRun(
                        rootDescriptor: rootDescriptor,
                        parentDescriptor: parentDescriptor,
                        runDescriptor: runDescriptor,
                        parentEvidence: parentEvidence,
                        runEvidence: runEvidence,
                        runLeaf: runLeaf,
                        files: fileEvidence,
                        createdParent: createdParent
                    )
                }
                if runDescriptor >= 0 { Darwin.close(runDescriptor) }
                if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
                Darwin.close(rootDescriptor)
            }
        }

        var rootDescriptorStatus = stat()
        guard fstat(rootDescriptor, &rootDescriptorStatus) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        let projectRootEvidence = DirectoryEvidence(rootDescriptorStatus)
        guard projectRootEvidence.matchesSafeOwnedDirectory(rootPathStatus) else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        originalsDescriptor = try openSourceDirectory(
            parent: rootDescriptor,
            leaf: "Originals"
        )
        let originalsEvidence = try sourceDirectoryEvidence(originalsDescriptor)
        if !photoBindings.isEmpty {
            photosDescriptor = try openSourceDirectory(
                parent: originalsDescriptor,
                leaf: "Photos"
            )
        }
        let photoDirectoryEvidence = photosDescriptor >= 0
            ? try sourceDirectoryEvidence(photosDescriptor)
            : nil

        let parentResult = try openOrCreateLeaseParent(rootDescriptor: rootDescriptor)
        parentDescriptor = parentResult.descriptor
        createdParent = parentResult.created
        parentEvidence = parentResult.evidence
        let runResult = try createRun(parentDescriptor: parentDescriptor, paths: paths)
        runDescriptor = runResult.descriptor
        runLeaf = runResult.leaf
        var initialRunStatus = stat()
        guard fstat(runDescriptor, &initialRunStatus) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        runEvidence = DirectoryEvidence(initialRunStatus)
        guard runEvidence?.isWritablePrivate == true else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }

        snapshots.reserveCapacity(bindings.count)
        fileEvidence.reserveCapacity(bindings.count)
        for binding in bindings {
            try checkCancellation()
            let sourceParent = binding.kind == .video
                ? originalsDescriptor
                : photosDescriptor
            let result = try snapshot(
                binding,
                sourceParentDescriptor: sourceParent,
                runDescriptor: runDescriptor,
                runURL: runResult.url,
                cloneSnapshot: cloneSnapshot,
                checkCancellation: checkCancellation,
                availableCapacity: availableCapacity,
                writeChunk: writeChunk
            )
            snapshots.append(result.snapshot)
            fileEvidence.append(result.evidence)
        }
        try checkCancellation()
        try verifySourceDirectoryBinding(
            parentDescriptor: rootDescriptor,
            leaf: "Originals",
            evidence: originalsEvidence
        )
        if let photoDirectoryEvidence {
            try verifySourceDirectoryBinding(
                parentDescriptor: originalsDescriptor,
                leaf: "Photos",
                evidence: photoDirectoryEvidence
            )
        }
        if let photoSelectionBinding {
            do {
                try PhotoSelectionArtifactStore.revalidateProjectBoundLeaseEvidence(
                    photoSelectionBinding.evidence,
                    at: photoSelectionBinding.url,
                    projectPaths: photoSelectionBinding.projectPaths
                )
            } catch {
                throw RuntimeInputSnapshotError.invalidMetadata
            }
        }
        guard fchmod(runDescriptor, S_IRUSR | S_IXUSR) == 0,
              fsync(runDescriptor) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        var finalRunStatus = stat()
        guard fstat(runDescriptor, &finalRunStatus) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        runEvidence = DirectoryEvidence(finalRunStatus)
        guard runEvidence?.isSealedPrivate == true else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        try verifyDirectoryBinding(
            parentDescriptor: parentDescriptor,
            leaf: runResult.leaf,
            evidence: runEvidence!
        )
        try verifyLiteralDirectoryBinding(
            url: paths.root,
            descriptor: rootDescriptor,
            evidence: projectRootEvidence
        )

        let lease = RuntimeInputSnapshotLease(
            directoryURL: runResult.url,
            videos: snapshots.filter { $0.kind == .video },
            photos: snapshots.filter { $0.kind == .photo },
            photoSelectionProjection: photoSelectionProjection,
            receiptDigest: try receiptDigest(
                bindings: bindings,
                pairingPolicy: pairingPolicy ?? metadata.resolvedRunPlan?.pairingPolicy,
                photoSelectionReceipt: metadata.photoSelectionReceipt
            ),
            projectRootURL: paths.root,
            rootDescriptor: rootDescriptor,
            projectRootEvidence: projectRootEvidence,
            parentDescriptor: parentDescriptor,
            runDescriptor: runDescriptor,
            parentEvidence: parentEvidence!,
            runEvidence: runEvidence!,
            createdParent: createdParent,
            files: fileEvidence,
            photoSelectionBinding: photoSelectionBinding
        )
        transferred = true
        return lease
    }

    static func receiptDigest(
        metadata: ProjectMetadata,
        pairingPolicy: ResolvedPairingPolicy? = nil
    ) throws -> String {
        let bindings = videoBindings(metadata: metadata) + photoBindings(metadata: metadata)
        guard !bindings.isEmpty,
              bindings.count <= maximumInputCount,
              try aggregateByteCount(bindings) <= maximumAggregateBytes,
              bindings.allSatisfy({
                  !$0.projectRelativePath.isEmpty
                      && validSHA256($0.sha256)
              }) else {
            throw RuntimeInputSnapshotError.invalidMetadata
        }
        return try receiptDigest(
            bindings: bindings,
            pairingPolicy: pairingPolicy ?? metadata.resolvedRunPlan?.pairingPolicy,
            photoSelectionReceipt: metadata.photoSelectionReceipt
        )
    }

    private static func videoBindings(metadata: ProjectMetadata) -> [Binding] {
        (metadata.videoInputReceipts ?? []).enumerated().map {
            Binding(
                kind: .video,
                index: $0.offset,
                projectRelativePath: $0.element.projectRelativePath,
                byteCount: $0.element.byteCount,
                sha256: $0.element.sha256,
                sourceSHA256: nil,
                retainedRank: nil
            )
        }
    }

    private static func photoBindings(metadata: ProjectMetadata) -> [Binding] {
        (metadata.photoInputReceipts ?? []).enumerated().map {
            Binding(
                kind: .photo,
                index: $0.offset,
                projectRelativePath: $0.element.projectRelativePath,
                byteCount: $0.element.byteCount,
                sha256: $0.element.sha256,
                sourceSHA256: $0.element.source.sha256,
                retainedRank: $0.element.retainedRank
            )
        }
    }

    private static func receiptDigest(
        bindings: [Binding],
        pairingPolicy: ResolvedPairingPolicy?,
        photoSelectionReceipt: PhotoSelectionReceipt?
    ) throws -> String {
        guard let pairingPolicy else { throw RuntimeInputSnapshotError.invalidMetadata }
        let videos = bindings.filter { $0.kind == .video }
        let videoIdentities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: videos.map(\.sha256),
            pairingPolicy: pairingPolicy
        )
        let orderedVideos = videoIdentities.map { videos[$0.sourceIndex] }
        let orderedPhotos = bindings
            .filter { $0.kind == .photo }
            .sorted {
                let left = $0.sourceSHA256 ?? ""
                let right = $1.sourceSHA256 ?? ""
                if left != right { return left < right }
                if $0.sha256 != $1.sha256 { return $0.sha256 < $1.sha256 }
                return $0.byteCount < $1.byteCount
            }
        guard orderedPhotos.allSatisfy({ binding in
            binding.sourceSHA256.map { validSHA256($0) } == true
                && binding.retainedRank.map { $0 >= 0 } == true
        }), orderedPhotos.isEmpty == (photoSelectionReceipt == nil) else {
            throw RuntimeInputSnapshotError.invalidMetadata
        }
        let identityBindings = orderedVideos + orderedPhotos
        var hasher = SHA256()
        updateDigestField(Data("EasySplat runtime content receipts v3".utf8), in: &hasher)
        if let receipt = photoSelectionReceipt {
            guard receipt.schemaVersion == PhotoSelectionReceipt.currentSchemaVersion,
                  receipt.projectRelativePath == PhotoSelectionReceipt.projectRelativePath,
                  receipt.byteCount > 0,
                  receipt.byteCount <= Int64(PhotoSelectionArtifactStore.maximumArtifactBytes),
                  validSHA256(receipt.sha256),
                  receipt.artifactSchemaVersion == PhotoSelectionArtifact.currentSchemaVersion,
                  receipt.analysisRecipeVersion == PhotoAnalysisEvidenceBuilder.recipeVersion,
                  receipt.analysisRecipeSHA256 == PhotoAnalysisEvidenceBuilder.recipeSHA256,
                  receipt.selectorPolicyVersion == PhotoDiversitySelector.selectorPolicyVersion,
                  receipt.selectorPolicySHA256 == PhotoDiversitySelector.selectorPolicySHA256 else {
                throw RuntimeInputSnapshotError.invalidMetadata
            }
            updateDigestInteger(1, in: &hasher)
            updateDigestField(Data(receipt.projectRelativePath.utf8), in: &hasher)
            updateDigestInteger(UInt64(receipt.byteCount), in: &hasher)
            updateDigestField(Data(receipt.sha256.utf8), in: &hasher)
            updateDigestInteger(UInt64(receipt.artifactSchemaVersion), in: &hasher)
            updateDigestInteger(UInt64(receipt.analysisRecipeVersion), in: &hasher)
            updateDigestField(Data(receipt.analysisRecipeSHA256.utf8), in: &hasher)
            updateDigestInteger(UInt64(receipt.selectorPolicyVersion), in: &hasher)
            updateDigestField(Data(receipt.selectorPolicySHA256.utf8), in: &hasher)
        } else {
            updateDigestInteger(0, in: &hasher)
        }
        updateDigestInteger(UInt64(identityBindings.count), in: &hasher)
        for (index, binding) in identityBindings.enumerated() {
            updateDigestField(Data(binding.kind.rawValue.utf8), in: &hasher)
            updateDigestInteger(UInt64(index), in: &hasher)
            updateDigestInteger(UInt64(binding.byteCount), in: &hasher)
            updateDigestField(Data(binding.sha256.utf8), in: &hasher)
            if binding.kind == .photo,
               let sourceSHA256 = binding.sourceSHA256,
               let retainedRank = binding.retainedRank,
               retainedRank >= 0 {
                updateDigestField(Data(sourceSHA256.utf8), in: &hasher)
                updateDigestInteger(UInt64(retainedRank), in: &hasher)
            } else if binding.kind == .photo {
                throw RuntimeInputSnapshotError.invalidMetadata
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
    }

    private static func updateDigestField(_ data: Data, in hasher: inout SHA256) {
        updateDigestInteger(UInt64(data.count), in: &hasher)
        hasher.update(data: data)
    }

    private static func updateDigestInteger(_ value: UInt64, in hasher: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            hasher.update(bufferPointer: bytes)
        }
    }

    private struct Binding {
        let kind: RuntimeInputKind
        let index: Int
        let projectRelativePath: String
        let byteCount: Int64
        let sha256: String
        let sourceSHA256: String?
        let retainedRank: Int?

        var sourceLeaf: String {
            projectRelativePath.split(separator: "/").last.map(String.init) ?? ""
        }

        var leaseLeaf: String {
            switch kind {
            case .video: return String(format: "video-%04d.%@", index, extensionName)
            case .photo: return String(format: "photo-%04d.%@", index, extensionName)
            }
        }

        private var extensionName: String {
            URL(fileURLWithPath: sourceLeaf).pathExtension.lowercased()
        }
    }

    private struct DirectoryEvidence {
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

        var isWritablePrivate: Bool {
            (mode & S_IFMT) == S_IFDIR
                && owner == getuid()
                && mode & mode_t(0o7777) == mode_t(0o700)
        }

        var isSealedPrivate: Bool {
            (mode & S_IFMT) == S_IFDIR
                && owner == getuid()
                && mode & mode_t(0o7777) == mode_t(0o500)
        }

        var isSafeOwnedDirectory: Bool {
            (mode & S_IFMT) == S_IFDIR
                && owner == getuid()
                && mode & mode_t(0o022) == 0
        }

        func matches(_ status: stat) -> Bool {
            (isWritablePrivate || isSealedPrivate)
                && (status.st_mode & S_IFMT) == S_IFDIR
                && status.st_dev == device
                && status.st_ino == inode
                && status.st_uid == owner
                && status.st_mode & mode_t(0o7777) == (mode & mode_t(0o7777))
        }

        func matchesSourceDirectory(_ status: stat) -> Bool {
            (mode & S_IFMT) == S_IFDIR
                && owner == getuid()
                && mode & mode_t(0o022) == 0
                && (status.st_mode & S_IFMT) == S_IFDIR
                && status.st_dev == device
                && status.st_ino == inode
                && status.st_uid == owner
                && status.st_mode & mode_t(0o022) == 0
        }

        func matchesSafeOwnedDirectory(_ status: stat) -> Bool {
            isSafeOwnedDirectory
                && (status.st_mode & S_IFMT) == S_IFDIR
                && status.st_dev == device
                && status.st_ino == inode
                && status.st_uid == owner
                && status.st_mode == mode
        }
    }

    private struct SourceEvidence {
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

        var isOwnedSingleLinkRegularFile: Bool {
            (mode & S_IFMT) == S_IFREG
                && owner == getuid()
                && linkCount == 1
                && size > 0
        }

        var isSealedRuntimeFile: Bool {
            isOwnedSingleLinkRegularFile
                && mode & mode_t(0o7777) == mode_t(0o400)
        }

        func matches(_ status: stat) -> Bool {
            isOwnedSingleLinkRegularFile
                && (status.st_mode & S_IFMT) == S_IFREG
                && status.st_dev == device
                && status.st_ino == inode
                && status.st_uid == owner
                && status.st_nlink == linkCount
                && status.st_size == size
                && status.st_mode & mode_t(0o7777) == (mode & mode_t(0o7777))
                && status.st_mtimespec.tv_sec == modifiedSeconds
                && status.st_mtimespec.tv_nsec == modifiedNanoseconds
                && status.st_ctimespec.tv_sec == changedSeconds
                && status.st_ctimespec.tv_nsec == changedNanoseconds
        }
    }

    private struct FileEvidence {
        let leaf: String
        let source: SourceEvidence

        func matches(_ status: stat) -> Bool {
            source.isSealedRuntimeFile && source.matches(status)
        }
    }

    private struct PhotoSelectionLeaseBinding: Sendable {
        let url: URL
        let projectPaths: ProjectPaths
        let evidence: PhotoSelectionArtifactLeaseEvidence
    }

    private static func aggregateByteCount(_ bindings: [Binding]) throws -> Int64 {
        var total: Int64 = 0
        for binding in bindings {
            guard binding.byteCount > 0 else {
                throw RuntimeInputSnapshotError.invalidMetadata
            }
            let (next, overflow) = total.addingReportingOverflow(binding.byteCount)
            guard !overflow else { throw RuntimeInputSnapshotError.invalidMetadata }
            total = next
        }
        return total
    }

    private static func safeProjectDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == getuid()
            && status.st_mode & mode_t(0o022) == 0
    }

    private static func openSourceDirectory(parent: Int32, leaf: String) throws -> Int32 {
        let descriptor = leaf.withCString {
            openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw RuntimeInputSnapshotError.leaseUnavailable }
        do {
            _ = try sourceDirectoryEvidence(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func sourceDirectoryEvidence(_ descriptor: Int32) throws -> DirectoryEvidence {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & mode_t(0o022) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        return DirectoryEvidence(status)
    }

    private static func openOrCreateLeaseParent(
        rootDescriptor: Int32
    ) throws -> (descriptor: Int32, evidence: DirectoryEvidence, created: Bool) {
        let createResult = parentLeaf.withCString {
            mkdirat(rootDescriptor, $0, S_IRWXU)
        }
        let created: Bool
        if createResult == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        let descriptor = parentLeaf.withCString {
            openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw RuntimeInputSnapshotError.leaseUnavailable }
        do {
            if created, fchmod(descriptor, S_IRWXU) != 0 {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
            let evidence = DirectoryEvidence(status)
            guard evidence.isWritablePrivate else {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
            try verifyDirectoryBinding(
                parentDescriptor: rootDescriptor,
                leaf: parentLeaf,
                evidence: evidence
            )
            return (descriptor, evidence, created)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func createRun(
        parentDescriptor: Int32,
        paths: ProjectPaths
    ) throws -> (descriptor: Int32, leaf: String, url: URL) {
        for _ in 0..<8 {
            let leaf = "run-\(UUID().uuidString)"
            let result = leaf.withCString { mkdirat(parentDescriptor, $0, S_IRWXU) }
            if result != 0 {
                if errno == EEXIST { continue }
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
            let descriptor = leaf.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                _ = leaf.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
            guard fchmod(descriptor, S_IRWXU) == 0 else {
                Darwin.close(descriptor)
                _ = leaf.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
            return (
                descriptor,
                leaf,
                paths.root
                    .appendingPathComponent(parentLeaf, isDirectory: true)
                    .appendingPathComponent(leaf, isDirectory: true)
            )
        }
        throw RuntimeInputSnapshotError.leaseUnavailable
    }

    private static func snapshot(
        _ binding: Binding,
        sourceParentDescriptor: Int32,
        runDescriptor: Int32,
        runURL: URL,
        cloneSnapshot: CloneSnapshot,
        checkCancellation: CheckCancellation,
        availableCapacity: AvailableCapacity,
        writeChunk: WriteChunk
    ) throws -> (snapshot: Snapshot, evidence: FileEvidence) {
        var pathStatus = stat()
        let pathResult = binding.sourceLeaf.withCString {
            fstatat(sourceParentDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard pathResult == 0,
              safeSource(pathStatus) else {
            throw RuntimeInputSnapshotError.unsafeSource(
                kind: binding.kind,
                index: binding.index
            )
        }
        guard pathStatus.st_size == binding.byteCount else {
            throw RuntimeInputSnapshotError.sizeMismatch(
                kind: binding.kind,
                index: binding.index
            )
        }
        let input = binding.sourceLeaf.withCString {
            openat(
                sourceParentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard input >= 0 else {
            throw RuntimeInputSnapshotError.unsafeSource(
                kind: binding.kind,
                index: binding.index
            )
        }
        defer { Darwin.close(input) }
        var descriptorStatus = stat()
        guard fstat(input, &descriptorStatus) == 0,
              safeSource(descriptorStatus),
              sameFile(pathStatus, descriptorStatus) else {
            throw RuntimeInputSnapshotError.sourceChanged(
                kind: binding.kind,
                index: binding.index
            )
        }
        let sourceEvidence = SourceEvidence(descriptorStatus)
        let leaf = binding.leaseLeaf
        var created = false
        do {
            try checkCancellation()
            let cloned = try cloneSnapshot(input, runDescriptor, leaf)
            created = cloned
            if !cloned {
                var unexpected = stat()
                let statusResult = leaf.withCString {
                    fstatat(runDescriptor, $0, &unexpected, AT_SYMLINK_NOFOLLOW)
                }
                guard statusResult != 0, errno == ENOENT else {
                    throw RuntimeInputSnapshotError.copyFailed(
                        kind: binding.kind,
                        index: binding.index
                    )
                }
                try requireFallbackCapacity(
                    binding: binding,
                    runURL: runURL,
                    availableCapacity: availableCapacity
                )
            }
            let outputFlags = cloned
                ? O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                : O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
            let output = leaf.withCString {
                openat(runDescriptor, $0, outputFlags, S_IRUSR | S_IWUSR)
            }
            guard output >= 0 else {
                throw RuntimeInputSnapshotError.copyFailed(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            created = true
            defer { Darwin.close(output) }

            let digest: String
            if cloned {
                digest = try hash(
                    descriptor: output,
                    byteCount: binding.byteCount,
                    checkCancellation: checkCancellation,
                    failure: .copyFailed(kind: binding.kind, index: binding.index)
                )
            } else {
                digest = try copyAndHash(
                    source: input,
                    destination: output,
                    byteCount: binding.byteCount,
                    checkCancellation: checkCancellation,
                    writeChunk: writeChunk,
                    binding: binding
                )
            }
            guard digest == binding.sha256 else {
                throw RuntimeInputSnapshotError.digestMismatch(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            try checkCancellation()
            guard fchmod(output, S_IRUSR | S_IWUSR) == 0,
                  fsync(output) == 0 else {
                throw RuntimeInputSnapshotError.copyFailed(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            var finalSource = stat()
            var finalPath = stat()
            var finalOutput = stat()
            let finalPathResult = binding.sourceLeaf.withCString {
                fstatat(
                    sourceParentDescriptor,
                    $0,
                    &finalPath,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard fstat(input, &finalSource) == 0,
                  finalPathResult == 0,
                  fstat(output, &finalOutput) == 0,
                  sourceEvidence.matches(finalSource),
                  sourceEvidence.matches(finalPath),
                  safeSource(finalOutput),
                  finalOutput.st_size == binding.byteCount,
                  finalOutput.st_dev == (try directoryDevice(runDescriptor)) else {
                throw RuntimeInputSnapshotError.sourceChanged(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            guard fchmod(output, S_IRUSR) == 0,
                  fsync(output) == 0 else {
                throw RuntimeInputSnapshotError.copyFailed(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            var sealedOutput = stat()
            var sealedPath = stat()
            let sealedPathResult = leaf.withCString {
                fstatat(runDescriptor, $0, &sealedPath, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(output, &sealedOutput) == 0,
                  sealedPathResult == 0 else {
                throw RuntimeInputSnapshotError.copyFailed(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            let outputEvidence = SourceEvidence(sealedOutput)
            guard outputEvidence.isSealedRuntimeFile,
                  outputEvidence.matches(sealedPath) else {
                throw RuntimeInputSnapshotError.copyFailed(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            return (
                Snapshot(
                    kind: binding.kind,
                    index: binding.index,
                    url: runURL.appendingPathComponent(leaf),
                    projectRelativePath: binding.projectRelativePath,
                    byteCount: binding.byteCount,
                    sha256: binding.sha256
                ),
                FileEvidence(leaf: leaf, source: outputEvidence)
            )
        } catch is CancellationError {
            if created { _ = leaf.withCString { unlinkat(runDescriptor, $0, 0) } }
            throw CancellationError()
        } catch let error as RuntimeInputSnapshotError {
            if created { _ = leaf.withCString { unlinkat(runDescriptor, $0, 0) } }
            throw error
        } catch {
            if created { _ = leaf.withCString { unlinkat(runDescriptor, $0, 0) } }
            throw RuntimeInputSnapshotError.copyFailed(
                kind: binding.kind,
                index: binding.index
            )
        }
    }

    private static func safeSource(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == getuid()
            && status.st_nlink == 1
            && status.st_size > 0
            && status.st_mode & mode_t(0o7777) == mode_t(0o600)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func directoryDevice(_ descriptor: Int32) throws -> dev_t {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        return status.st_dev
    }

    private static func copyAndHash(
        source: Int32,
        destination: Int32,
        byteCount: Int64,
        checkCancellation: CheckCancellation,
        writeChunk: WriteChunk,
        binding: Binding
    ) throws -> String {
        guard lseek(source, 0, SEEK_SET) == 0 else {
            throw RuntimeInputSnapshotError.sourceChanged(
                kind: binding.kind,
                index: binding.index
            )
        }
        var hasher = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while consumed < byteCount {
            try checkCancellation()
            let remaining = Int(min(Int64(buffer.count), byteCount - consumed))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(source, $0.baseAddress, remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeInputSnapshotError.sourceChanged(
                    kind: binding.kind,
                    index: binding.index
                )
            }
            buffer.withUnsafeBytes {
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])
                )
            }
            var written = 0
            while written < count {
                try checkCancellation()
                let result = try buffer.withUnsafeBytes {
                    try writeChunk(
                        destination,
                        $0.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else {
                    throw RuntimeInputSnapshotError.copyFailed(
                        kind: binding.kind,
                        index: binding.index
                    )
                }
                written += result
            }
            consumed += Int64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(
        descriptor: Int32,
        byteCount: Int64,
        checkCancellation: CheckCancellation,
        failure: RuntimeInputSnapshotError
    ) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw failure }
        var hasher = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while consumed < byteCount {
            try checkCancellation()
            let remaining = Int(min(Int64(buffer.count), byteCount - consumed))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw failure }
            buffer.withUnsafeBytes {
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])
                )
            }
            consumed += Int64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyDirectoryBinding(
        parentDescriptor: Int32,
        leaf: String,
        evidence: DirectoryEvidence
    ) throws {
        var status = stat()
        let result = leaf.withCString {
            fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, evidence.matches(status) else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
    }

    private static func verifyLiteralDirectoryBinding(
        url: URL,
        descriptor: Int32,
        evidence: DirectoryEvidence
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(url.path, &pathStatus) == 0,
              evidence.matchesSafeOwnedDirectory(descriptorStatus),
              evidence.matchesSafeOwnedDirectory(pathStatus) else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
    }

    private static func verifySourceDirectoryBinding(
        parentDescriptor: Int32,
        leaf: String,
        evidence: DirectoryEvidence
    ) throws {
        var status = stat()
        let result = leaf.withCString {
            fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, evidence.matchesSourceDirectory(status) else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
    }

    private static func removeBoundRun(
        rootDescriptor: Int32,
        parentDescriptor: Int32,
        runDescriptor: Int32,
        parentEvidence: DirectoryEvidence,
        runEvidence: DirectoryEvidence,
        runLeaf: String,
        files: [FileEvidence],
        createdParent: Bool
    ) throws {
        try verifyDirectoryBinding(
            parentDescriptor: rootDescriptor,
            leaf: parentLeaf,
            evidence: parentEvidence
        )
        try verifyDirectoryBinding(
            parentDescriptor: parentDescriptor,
            leaf: runLeaf,
            evidence: runEvidence
        )
        var descriptorStatus = stat()
        guard fstat(runDescriptor, &descriptorStatus) == 0,
              runEvidence.matches(descriptorStatus) else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        for file in files {
            var status = stat()
            let statusResult = file.leaf.withCString {
                fstatat(runDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0, file.matches(status) else {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
        }
        guard fchmod(runDescriptor, S_IRWXU) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        var writableStatus = stat()
        guard fstat(runDescriptor, &writableStatus) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        let writableEvidence = DirectoryEvidence(writableStatus)
        guard writableEvidence.isWritablePrivate else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        try verifyDirectoryBinding(
            parentDescriptor: parentDescriptor,
            leaf: runLeaf,
            evidence: writableEvidence
        )
        for file in files {
            guard file.leaf.withCString({ unlinkat(runDescriptor, $0, 0) }) == 0 else {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
        }
        try verifyDirectoryBinding(
            parentDescriptor: parentDescriptor,
            leaf: runLeaf,
            evidence: writableEvidence
        )
        guard runLeaf.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
            throw RuntimeInputSnapshotError.leaseUnavailable
        }
        if createdParent {
            try verifyDirectoryBinding(
                parentDescriptor: rootDescriptor,
                leaf: parentLeaf,
                evidence: parentEvidence
            )
            let result = parentLeaf.withCString {
                unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
            }
            if result != 0, errno != ENOTEMPTY, errno != EEXIST {
                throw RuntimeInputSnapshotError.leaseUnavailable
            }
        }
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

    private static func requireFallbackCapacity(
        binding: Binding,
        runURL: URL,
        availableCapacity: AvailableCapacity
    ) throws {
        let capacity: (ordinary: Int64?, important: Int64?)
        do {
            capacity = try availableCapacity(runURL)
        } catch {
            throw RuntimeInputSnapshotError.capacityUnavailable(
                kind: binding.kind,
                index: binding.index
            )
        }
        guard let ordinary = capacity.ordinary,
              let important = capacity.important,
              let ordinaryBytes = UInt64(exactly: ordinary),
              let importantBytes = UInt64(exactly: important),
              let requiredBytes = UInt64(exactly: binding.byteCount) else {
            throw RuntimeInputSnapshotError.capacityUnavailable(
                kind: binding.kind,
                index: binding.index
            )
        }
        guard min(ordinaryBytes, importantBytes) >= requiredBytes else {
            throw RuntimeInputSnapshotError.insufficientCapacity(
                kind: binding.kind,
                index: binding.index
            )
        }
    }

    private static func defaultAvailableCapacity(
        directoryURL: URL
    ) throws -> (ordinary: Int64?, important: Int64?) {
        let values = try directoryURL.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let ordinary = values.volumeAvailableCapacity.flatMap(Int64.init(exactly:))
        return (
            ordinary: ordinary,
            important: values.volumeAvailableCapacityForImportantUsage
        )
    }

    private static func defaultWriteChunk(
        destinationDescriptor: Int32,
        bytes: UnsafeRawPointer?,
        count: Int
    ) throws -> Int {
        Darwin.write(destinationDescriptor, bytes, count)
    }
}
