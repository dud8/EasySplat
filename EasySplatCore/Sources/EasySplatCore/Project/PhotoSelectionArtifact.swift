import CryptoKit
import Darwin
import Foundation

public enum PhotoSelectionStrategy: String, Codable, Sendable, Equatable {
    case visualDiversity
    case continuousEvenSpacing
    case useAll
}

public struct PhotoSelectionCandidateArtifact: Codable, Sendable, Equatable {
    public var admissionOrdinal: Int
    public var evidence: PhotoAnalysisEvidence
    public var retainedRank: Int?

    public init(
        admissionOrdinal: Int,
        evidence: PhotoAnalysisEvidence,
        retainedRank: Int?
    ) {
        self.admissionOrdinal = admissionOrdinal
        self.evidence = evidence
        self.retainedRank = retainedRank
    }
}

public struct PhotoSelectionArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let tiePolicyIdentifier = "source-sha256-final-tie-v1"

    public var schemaVersion: Int
    public var strategy: PhotoSelectionStrategy
    public var analysisRecipeVersion: Int
    public var analysisRecipeSHA256: String
    public var selectorPolicyVersion: Int
    public var selectorPolicySHA256: String
    public var inputOrdering: InputOrdering
    public var requestedPhotoSelection: PhotoSelection
    public var admissionCapacity: Int
    public var discoveredCount: Int
    public var acceptedCount: Int
    public var unreadableCount: Int
    public var exactDuplicateCount: Int
    public var companionDuplicateCount: Int
    public var candidates: [PhotoSelectionCandidateArtifact]
    public var retainedSourceSHA256s: [String]
    public var canonicalRetainedSourceSHA256s: [String]
    public var tiePolicyIdentifier: String

    public init<Candidates: Sequence>(
        strategy: PhotoSelectionStrategy,
        analysisRecipeVersion: Int,
        analysisRecipeSHA256: String,
        selectorPolicyVersion: Int,
        selectorPolicySHA256: String,
        inputOrdering: InputOrdering,
        requestedPhotoSelection: PhotoSelection,
        admissionCapacity: Int,
        discoveredCount: Int,
        acceptedCount: Int,
        unreadableCount: Int,
        exactDuplicateCount: Int,
        companionDuplicateCount: Int,
        candidates: Candidates,
        retainedSourceSHA256s: [String],
        canonicalRetainedSourceSHA256s: [String],
        tiePolicyIdentifier: String = Self.tiePolicyIdentifier
    ) where Candidates.Element == PhotoSelectionCandidateArtifact {
        schemaVersion = Self.currentSchemaVersion
        self.strategy = strategy
        self.analysisRecipeVersion = analysisRecipeVersion
        self.analysisRecipeSHA256 = analysisRecipeSHA256
        self.selectorPolicyVersion = selectorPolicyVersion
        self.selectorPolicySHA256 = selectorPolicySHA256
        self.inputOrdering = inputOrdering
        self.requestedPhotoSelection = requestedPhotoSelection
        self.admissionCapacity = admissionCapacity
        self.discoveredCount = discoveredCount
        self.acceptedCount = acceptedCount
        self.unreadableCount = unreadableCount
        self.exactDuplicateCount = exactDuplicateCount
        self.companionDuplicateCount = companionDuplicateCount
        self.candidates = candidates.sorted {
            $0.evidence.sourceSHA256 < $1.evidence.sourceSHA256
        }
        self.retainedSourceSHA256s = retainedSourceSHA256s
        self.canonicalRetainedSourceSHA256s = canonicalRetainedSourceSHA256s
        self.tiePolicyIdentifier = tiePolicyIdentifier
    }
}

struct PhotoSelectionArtifactFileEvidence: Equatable, Sendable {
    let byteCount: Int64
    let sha256: String
}

struct PhotoSelectionArtifactDirectoryLeaseEvidence: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt32

    fileprivate init(_ status: stat) {
        device = UInt64(bitPattern: Int64(status.st_dev))
        inode = UInt64(status.st_ino)
        owner = UInt32(status.st_uid)
        mode = UInt32(status.st_mode)
    }

    fileprivate var isSafeOwnedDirectory: Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
            && owner == UInt32(getuid())
            && mode & 0o022 == 0
    }

    fileprivate func matches(_ status: stat) -> Bool {
        isSafeOwnedDirectory
            && (status.st_mode & S_IFMT) == S_IFDIR
            && UInt64(bitPattern: Int64(status.st_dev)) == device
            && UInt64(status.st_ino) == inode
            && UInt32(status.st_uid) == owner
            && UInt32(status.st_mode) == mode
    }
}

private struct PhotoSelectionArtifactFileLeaseEvidence: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt32
    let linkCount: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let sha256: String

    fileprivate init(_ status: stat, sha256: String) {
        device = UInt64(bitPattern: Int64(status.st_dev))
        inode = UInt64(status.st_ino)
        owner = UInt32(status.st_uid)
        mode = UInt32(status.st_mode)
        linkCount = UInt64(status.st_nlink)
        byteCount = Int64(status.st_size)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        self.sha256 = sha256
    }

    fileprivate var isPrivateRegularFile: Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFREG)
            && owner == UInt32(getuid())
            && linkCount == 1
            && byteCount > 0
            && mode & 0o7777 == 0o600
    }

    fileprivate func matches(_ status: stat) -> Bool {
        isPrivateRegularFile
            && UInt64(bitPattern: Int64(status.st_dev)) == device
            && UInt64(status.st_ino) == inode
            && UInt32(status.st_uid) == owner
            && UInt32(status.st_mode) == mode
            && UInt64(status.st_nlink) == linkCount
            && Int64(status.st_size) == byteCount
            && Int64(status.st_mtimespec.tv_sec) == modifiedSeconds
            && Int64(status.st_mtimespec.tv_nsec) == modifiedNanoseconds
            && Int64(status.st_ctimespec.tv_sec) == changedSeconds
            && Int64(status.st_ctimespec.tv_nsec) == changedNanoseconds
    }
}

struct PhotoSelectionArtifactLeaseEvidence: Equatable, Sendable {
    let projectRoot: PhotoSelectionArtifactDirectoryLeaseEvidence
    let framesDirectory: PhotoSelectionArtifactDirectoryLeaseEvidence
    private let file: PhotoSelectionArtifactFileLeaseEvidence

    var device: UInt64 { file.device }
    var inode: UInt64 { file.inode }
    var owner: UInt32 { file.owner }
    var mode: UInt32 { file.mode }
    var linkCount: UInt64 { file.linkCount }
    var byteCount: Int64 { file.byteCount }
    var modifiedSeconds: Int64 { file.modifiedSeconds }
    var modifiedNanoseconds: Int64 { file.modifiedNanoseconds }
    var changedSeconds: Int64 { file.changedSeconds }
    var changedNanoseconds: Int64 { file.changedNanoseconds }
    var sha256: String { file.sha256 }

    fileprivate init(
        projectRoot: PhotoSelectionArtifactDirectoryLeaseEvidence,
        framesDirectory: PhotoSelectionArtifactDirectoryLeaseEvidence,
        file: PhotoSelectionArtifactFileLeaseEvidence
    ) {
        self.projectRoot = projectRoot
        self.framesDirectory = framesDirectory
        self.file = file
    }

    fileprivate var isPrivateRegularFile: Bool {
        projectRoot.isSafeOwnedDirectory
            && framesDirectory.isSafeOwnedDirectory
            && file.isPrivateRegularFile
    }

    fileprivate func matchesFile(_ status: stat) -> Bool {
        file.matches(status)
    }
}

enum PhotoSelectionArtifactStoreError: Error, LocalizedError, Equatable {
    case invalidArtifact
    case unsupportedSchema(Int)
    case artifactSizeMismatch
    case artifactDigestMismatch
    case policyMismatch

    var errorDescription: String? {
        switch self {
        case .invalidArtifact:
            "Photo selection evidence is invalid."
        case .unsupportedSchema(let schemaVersion):
            "Unsupported photo selection schema \(schemaVersion)."
        case .artifactSizeMismatch:
            "Photo selection evidence has changed size."
        case .artifactDigestMismatch:
            "Photo selection evidence has changed."
        case .policyMismatch:
            "Photo selection evidence was produced with a different policy."
        }
    }
}

enum PhotoSelectionArtifactStore {
    static let maximumArtifactBytes = 64 * 1_024 * 1_024
    private static let maximumCandidateCount = 10_000
    static let projectRelativePath = "Frames/photo_selection.json"

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    static func save(
        _ artifact: PhotoSelectionArtifact,
        to url: URL,
        projectPaths: ProjectPaths,
        beforeAtomicRename: () throws -> Void = {}
    ) throws -> PhotoSelectionArtifactFileEvidence {
        let data = try canonicalData(artifact)
        do {
            _ = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: projectRelativePath
            )
        } catch {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        var rootPathStatus = stat()
        guard lstat(projectPaths.root.path, &rootPathStatus) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let root = Darwin.open(
            projectPaths.root.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard root >= 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(root) }
        var rootDescriptorStatus = stat()
        guard fstat(root, &rootDescriptorStatus) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let rootEvidence = PhotoSelectionArtifactDirectoryLeaseEvidence(
            rootDescriptorStatus
        )
        guard rootEvidence.isSafeOwnedDirectory,
              rootEvidence.matches(rootPathStatus) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        var framesPathStatus = stat()
        let framesPathResult = "Frames".withCString {
            fstatat(root, $0, &framesPathStatus, AT_SYMLINK_NOFOLLOW)
        }
        let frames = "Frames".withCString {
            openat(
                root,
                $0,
                O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard framesPathResult == 0, frames >= 0 else {
            if frames >= 0 { Darwin.close(frames) }
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(frames) }
        var framesDescriptorStatus = stat()
        guard fstat(frames, &framesDescriptorStatus) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let framesEvidence = PhotoSelectionArtifactDirectoryLeaseEvidence(
            framesDescriptorStatus
        )
        guard framesEvidence.isSafeOwnedDirectory,
              framesEvidence.matches(framesPathStatus) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        let verifyReservedDirectoryBinding = {
            var finalRootDescriptor = stat()
            var finalRootPath = stat()
            var finalFramesDescriptor = stat()
            var finalFramesPath = stat()
            let finalFramesPathResult = "Frames".withCString {
                fstatat(root, $0, &finalFramesPath, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(root, &finalRootDescriptor) == 0,
                  lstat(projectPaths.root.path, &finalRootPath) == 0,
                  fstat(frames, &finalFramesDescriptor) == 0,
                  finalFramesPathResult == 0,
                  rootEvidence.matches(finalRootDescriptor),
                  rootEvidence.matches(finalRootPath),
                  framesEvidence.matches(finalFramesDescriptor),
                  framesEvidence.matches(finalFramesPath) else {
                throw PhotoSelectionArtifactStoreError.invalidArtifact
            }
        }

        let destinationLeaf = url.lastPathComponent
        let temporaryLeaf = ".\(destinationLeaf).tmp-\(UUID().uuidString)"
        let temporary = temporaryLeaf.withCString {
            openat(
                frames,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard temporary >= 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        var temporaryIsLinked = true
        defer {
            Darwin.close(temporary)
            if temporaryIsLinked {
                _ = temporaryLeaf.withCString { unlinkat(frames, $0, 0) }
            }
        }
        guard fchmod(temporary, S_IRUSR | S_IWUSR) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    temporary,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw PhotoSelectionArtifactStoreError.invalidArtifact
                }
                offset += count
            }
        }
        guard fsync(temporary) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        var stagedDescriptorStatus = stat()
        var stagedPathStatus = stat()
        let stagedPathResult = temporaryLeaf.withCString {
            fstatat(frames, $0, &stagedPathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(temporary, &stagedDescriptorStatus) == 0,
              stagedPathResult == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let stagedEvidence = PhotoSelectionArtifactFileLeaseEvidence(
            stagedDescriptorStatus,
            sha256: sha256(data)
        )
        guard stagedEvidence.isPrivateRegularFile,
              stagedEvidence.byteCount == Int64(data.count),
              stagedEvidence.matches(stagedPathStatus) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        try beforeAtomicRename()
        try verifyReservedDirectoryBinding()
        var reboundStagedDescriptor = stat()
        var reboundStagedPath = stat()
        let reboundStagedPathResult = temporaryLeaf.withCString {
            fstatat(frames, $0, &reboundStagedPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(temporary, &reboundStagedDescriptor) == 0,
              reboundStagedPathResult == 0,
              stagedEvidence.matches(reboundStagedDescriptor),
              stagedEvidence.matches(reboundStagedPath) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let renameResult = temporaryLeaf.withCString { source in
            destinationLeaf.withCString { destination in
                renameat(frames, source, frames, destination)
            }
        }
        guard renameResult == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        temporaryIsLinked = false
        var renamedDescriptor = stat()
        var renamedPath = stat()
        let renamedPathResult = destinationLeaf.withCString {
            fstatat(frames, $0, &renamedPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(temporary, &renamedDescriptor) == 0,
              renamedPathResult == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let renamedEvidence = PhotoSelectionArtifactFileLeaseEvidence(
            renamedDescriptor,
            sha256: stagedEvidence.sha256
        )
        guard renamedEvidence.isPrivateRegularFile,
              renamedEvidence.device == stagedEvidence.device,
              renamedEvidence.inode == stagedEvidence.inode,
              renamedEvidence.owner == stagedEvidence.owner,
              renamedEvidence.mode == stagedEvidence.mode,
              renamedEvidence.linkCount == stagedEvidence.linkCount,
              renamedEvidence.byteCount == stagedEvidence.byteCount,
              renamedEvidence.modifiedSeconds == stagedEvidence.modifiedSeconds,
              renamedEvidence.modifiedNanoseconds == stagedEvidence.modifiedNanoseconds,
              renamedEvidence.matches(renamedPath),
              sha256(try readData(
                descriptor: temporary,
                byteCount: Int(renamedEvidence.byteCount)
              )) == stagedEvidence.sha256,
              fsync(frames) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        try verifyReservedDirectoryBinding()

        var finalPublishedDescriptor = stat()
        var finalPublishedPath = stat()
        let finalPublishedPathResult = destinationLeaf.withCString {
            fstatat(frames, $0, &finalPublishedPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(temporary, &finalPublishedDescriptor) == 0,
              finalPublishedPathResult == 0,
              renamedEvidence.matches(finalPublishedDescriptor),
              renamedEvidence.matches(finalPublishedPath) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        return fileEvidence(for: data)
    }

    static func loadProjectBoundVerified(
        from url: URL,
        projectPaths: ProjectPaths,
        expectedByteCount: Int64,
        expectedSHA256: String,
        expectedAnalysisRecipeVersion: Int,
        expectedAnalysisRecipeSHA256: String,
        expectedSelectorPolicyVersion: Int,
        expectedSelectorPolicySHA256: String,
        beforeFinalPathValidation: () throws -> Void = {}
    ) throws -> (
        artifact: PhotoSelectionArtifact,
        leaseEvidence: PhotoSelectionArtifactLeaseEvidence
    ) {
        guard expectedByteCount > 0,
              expectedByteCount <= Int64(maximumArtifactBytes),
              isSHA256(expectedSHA256) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let loaded = try readProjectBoundPrivateData(
            from: url,
            projectPaths: projectPaths,
            beforeFinalPathValidation: beforeFinalPathValidation
        )
        guard Int64(loaded.data.count) == expectedByteCount else {
            throw PhotoSelectionArtifactStoreError.artifactSizeMismatch
        }
        guard loaded.leaseEvidence.sha256 == expectedSHA256 else {
            throw PhotoSelectionArtifactStoreError.artifactDigestMismatch
        }
        let artifact = try decodeAndValidate(loaded.data)
        guard artifact.analysisRecipeVersion == expectedAnalysisRecipeVersion,
              artifact.analysisRecipeSHA256 == expectedAnalysisRecipeSHA256,
              artifact.selectorPolicyVersion == expectedSelectorPolicyVersion,
              artifact.selectorPolicySHA256 == expectedSelectorPolicySHA256 else {
            throw PhotoSelectionArtifactStoreError.policyMismatch
        }
        return (artifact, loaded.leaseEvidence)
    }

    /// Rebinds retained directory and file identities without rereading or
    /// rehashing the already receipt-authenticated sidecar contents.
    static func revalidateProjectBoundLeaseEvidence(
        _ expected: PhotoSelectionArtifactLeaseEvidence,
        at url: URL,
        projectPaths: ProjectPaths
    ) throws {
        guard expected.isPrivateRegularFile,
              expected.byteCount <= Int64(maximumArtifactBytes),
              isSHA256(expected.sha256) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let rebound = try withProjectBoundFramesDirectory(
            from: url,
            projectPaths: projectPaths
        ) { framesDescriptor, leaf in
            try revalidatePrivateEntry(
                expected,
                parentDescriptor: framesDescriptor,
                leaf: leaf
            )
        }
        guard rebound.projectRoot == expected.projectRoot,
              rebound.framesDirectory == expected.framesDirectory else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
    }

    static func canonicalData(_ artifact: PhotoSelectionArtifact) throws -> Data {
        try validate(artifact)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard !data.isEmpty, data.count <= maximumArtifactBytes else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        return data
    }

    static func validate(_ artifact: PhotoSelectionArtifact) throws {
        guard artifact.schemaVersion == PhotoSelectionArtifact.currentSchemaVersion else {
            throw PhotoSelectionArtifactStoreError.unsupportedSchema(
                artifact.schemaVersion
            )
        }
        guard artifact.analysisRecipeVersion
                == PhotoAnalysisEvidenceBuilder.recipeVersion,
              artifact.analysisRecipeSHA256
                == PhotoAnalysisEvidenceBuilder.recipeSHA256,
              artifact.selectorPolicyVersion
                == PhotoDiversitySelector.selectorPolicyVersion,
              artifact.selectorPolicySHA256
                == PhotoDiversitySelector.selectorPolicySHA256,
              artifact.tiePolicyIdentifier
                == PhotoSelectionArtifact.tiePolicyIdentifier,
              artifact.discoveredCount > 0,
              artifact.acceptedCount > 0,
              artifact.acceptedCount <= maximumCandidateCount,
              artifact.unreadableCount >= 0,
              artifact.exactDuplicateCount >= 0,
              artifact.companionDuplicateCount >= 0,
              artifact.discoveredCount == artifact.acceptedCount
                + artifact.unreadableCount
                + artifact.exactDuplicateCount
                + artifact.companionDuplicateCount,
              artifact.candidates.count == artifact.acceptedCount,
              !artifact.retainedSourceSHA256s.isEmpty,
              artifact.retainedSourceSHA256s.count <= artifact.admissionCapacity,
              artifact.admissionCapacity <= artifact.acceptedCount else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        let sourceSHA256s = artifact.candidates.map(\.evidence.sourceSHA256)
        guard sourceSHA256s == sourceSHA256s.sorted(),
              Set(sourceSHA256s).count == sourceSHA256s.count,
              Set(artifact.candidates.map(\.admissionOrdinal))
                == Set(0..<artifact.acceptedCount),
              Set(artifact.retainedSourceSHA256s).count
                == artifact.retainedSourceSHA256s.count,
              artifact.retainedSourceSHA256s.allSatisfy(Set(sourceSHA256s).contains),
              artifact.canonicalRetainedSourceSHA256s.count
                == artifact.retainedSourceSHA256s.count,
              Set(artifact.canonicalRetainedSourceSHA256s)
                == Set(artifact.retainedSourceSHA256s) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        let evidence = artifact.candidates.map(\.evidence)
        do {
            _ = try PhotoDiversitySelector.rank(evidence, targetCount: 0)
        } catch {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        guard evidence.allSatisfy({ candidate in
            candidate.analysisRecipeVersion == artifact.analysisRecipeVersion
                && candidate.analysisRecipeSHA256 == artifact.analysisRecipeSHA256
        }) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        let retainedRankBySHA256 = Dictionary(
            uniqueKeysWithValues: artifact.retainedSourceSHA256s.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        guard artifact.candidates.allSatisfy({ candidate in
            candidate.retainedRank
                == retainedRankBySHA256[candidate.evidence.sourceSHA256]
        }), Set(artifact.candidates.compactMap(\.retainedRank))
                == Set(0..<artifact.retainedSourceSHA256s.count) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        let admissionOrder = artifact.candidates.sorted {
            $0.admissionOrdinal < $1.admissionOrdinal
        }.map(\.evidence.sourceSHA256)
        switch artifact.strategy {
        case .visualDiversity:
            guard artifact.requestedPhotoSelection == .automatic,
                  artifact.inputOrdering != .continuous,
                  artifact.retainedSourceSHA256s.count == artifact.admissionCapacity,
                  artifact.canonicalRetainedSourceSHA256s
                    == artifact.retainedSourceSHA256s.sorted() else {
                throw PhotoSelectionArtifactStoreError.invalidArtifact
            }
            let recomputed: [String]
            do {
                recomputed = try PhotoDiversitySelector.rank(
                    evidence,
                    targetCount: artifact.admissionCapacity
                ).map(\.sourceSHA256)
            } catch {
                throw PhotoSelectionArtifactStoreError.invalidArtifact
            }
            guard recomputed == artifact.retainedSourceSHA256s else {
                throw PhotoSelectionArtifactStoreError.invalidArtifact
            }
        case .continuousEvenSpacing:
            let expected = evenlySpacedItems(
                admissionOrder,
                targetCount: artifact.admissionCapacity
            )
            guard artifact.requestedPhotoSelection == .automatic,
                  artifact.inputOrdering == .continuous,
                  artifact.retainedSourceSHA256s.count == artifact.admissionCapacity,
                  artifact.retainedSourceSHA256s == expected,
                  artifact.canonicalRetainedSourceSHA256s == expected else {
                throw PhotoSelectionArtifactStoreError.invalidArtifact
            }
        case .useAll:
            let expected = artifact.inputOrdering == .continuous
                ? admissionOrder
                : sourceSHA256s
            guard artifact.requestedPhotoSelection == .useAllValidPhotos,
                  artifact.admissionCapacity == artifact.acceptedCount,
                  artifact.retainedSourceSHA256s == expected,
                  artifact.canonicalRetainedSourceSHA256s == expected else {
                throw PhotoSelectionArtifactStoreError.invalidArtifact
            }
        }
    }

    private static func evenlySpacedItems<Element>(
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

    private static func readProjectBoundPrivateData(
        from url: URL,
        projectPaths: ProjectPaths,
        beforeFinalPathValidation: () throws -> Void = {}
    ) throws -> (
        data: Data,
        leaseEvidence: PhotoSelectionArtifactLeaseEvidence
    ) {
        let bound = try withProjectBoundFramesDirectory(
            from: url,
            projectPaths: projectPaths
        ) { framesDescriptor, leaf in
            try readPrivateEntry(
                parentDescriptor: framesDescriptor,
                leaf: leaf,
                beforeFinalPathValidation: beforeFinalPathValidation,
                verifyContainer: {}
            )
        }
        return (
            bound.value.data,
            PhotoSelectionArtifactLeaseEvidence(
                projectRoot: bound.projectRoot,
                framesDirectory: bound.framesDirectory,
                file: bound.value.fileEvidence
            )
        )
    }

    private static func withProjectBoundFramesDirectory<Result>(
        from url: URL,
        projectPaths: ProjectPaths,
        operation: (Int32, String) throws -> Result
    ) throws -> (
        value: Result,
        projectRoot: PhotoSelectionArtifactDirectoryLeaseEvidence,
        framesDirectory: PhotoSelectionArtifactDirectoryLeaseEvidence
    ) {
        do {
            _ = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: projectRelativePath
            )
        } catch {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        var rootPathStatus = stat()
        guard lstat(projectPaths.root.path, &rootPathStatus) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let root = Darwin.open(
            projectPaths.root.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard root >= 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(root) }
        var rootDescriptorStatus = stat()
        guard fstat(root, &rootDescriptorStatus) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let rootEvidence = PhotoSelectionArtifactDirectoryLeaseEvidence(
            rootDescriptorStatus
        )
        guard rootEvidence.isSafeOwnedDirectory,
              rootEvidence.matches(rootPathStatus) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        var framesPathStatus = stat()
        let framesPathResult = "Frames".withCString {
            fstatat(root, $0, &framesPathStatus, AT_SYMLINK_NOFOLLOW)
        }
        let frames = "Frames".withCString {
            openat(
                root,
                $0,
                O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard framesPathResult == 0, frames >= 0 else {
            if frames >= 0 { Darwin.close(frames) }
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(frames) }
        var framesDescriptorStatus = stat()
        guard fstat(frames, &framesDescriptorStatus) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let framesEvidence = PhotoSelectionArtifactDirectoryLeaseEvidence(
            framesDescriptorStatus
        )
        guard framesEvidence.isSafeOwnedDirectory,
              framesEvidence.matches(framesPathStatus) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        let value = try operation(frames, url.lastPathComponent)
        var finalRootDescriptor = stat()
        var finalRootPath = stat()
        var finalFramesDescriptor = stat()
        var finalFramesPath = stat()
        let framesResult = "Frames".withCString {
            fstatat(root, $0, &finalFramesPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(root, &finalRootDescriptor) == 0,
              lstat(projectPaths.root.path, &finalRootPath) == 0,
              fstat(frames, &finalFramesDescriptor) == 0,
              framesResult == 0,
              rootEvidence.matches(finalRootDescriptor),
              rootEvidence.matches(finalRootPath),
              framesEvidence.matches(finalFramesDescriptor),
              framesEvidence.matches(finalFramesPath) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        return (
            value: value,
            projectRoot: rootEvidence,
            framesDirectory: framesEvidence
        )
    }

    private static func revalidatePrivateEntry(
        _ expected: PhotoSelectionArtifactLeaseEvidence,
        parentDescriptor: Int32,
        leaf: String
    ) throws {
        var initialPath = stat()
        let initialPathResult = leaf.withCString {
            fstatat(parentDescriptor, $0, &initialPath, AT_SYMLINK_NOFOLLOW)
        }
        guard initialPathResult == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let descriptor = leaf.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              expected.matchesFile(initialPath),
              expected.matchesFile(opened) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }

        var finalDescriptor = stat()
        var finalPath = stat()
        let finalPathResult = leaf.withCString {
            fstatat(parentDescriptor, $0, &finalPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &finalDescriptor) == 0,
              finalPathResult == 0,
              expected.matchesFile(finalDescriptor),
              expected.matchesFile(finalPath) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
    }

    private static func readPrivateEntry(
        parentDescriptor: Int32,
        leaf: String,
        beforeFinalPathValidation: () throws -> Void = {},
        verifyContainer: () throws -> Void
    ) throws -> (
        data: Data,
        fileEvidence: PhotoSelectionArtifactFileLeaseEvidence
    ) {
        var initialPath = stat()
        let initialPathResult = leaf.withCString {
            fstatat(parentDescriptor, $0, &initialPath, AT_SYMLINK_NOFOLLOW)
        }
        guard initialPathResult == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let descriptor = leaf.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let initialEvidence = PhotoSelectionArtifactFileLeaseEvidence(
            opened,
            sha256: ""
        )
        guard initialEvidence.isPrivateRegularFile,
              initialEvidence.byteCount <= Int64(maximumArtifactBytes),
              initialEvidence.matches(initialPath) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let data = try readData(
            descriptor: descriptor,
            byteCount: Int(initialEvidence.byteCount)
        )

        try beforeFinalPathValidation()
        try verifyContainer()

        var finalDescriptor = stat()
        var finalPath = stat()
        let finalPathResult = leaf.withCString {
            fstatat(parentDescriptor, $0, &finalPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &finalDescriptor) == 0,
              finalPathResult == 0,
              initialEvidence.matches(finalDescriptor),
              initialEvidence.matches(finalPath) else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        let digest = sha256(data)
        return (
            data,
            PhotoSelectionArtifactFileLeaseEvidence(
                finalDescriptor,
                sha256: digest
            )
        )
    }

    private static func readData(
        descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        guard byteCount > 0, byteCount <= maximumArtifactBytes else {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
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
                    throw PhotoSelectionArtifactStoreError.invalidArtifact
                }
                offset += count
            }
        }
        return data
    }

    private static func decodeAndValidate(
        _ data: Data
    ) throws -> PhotoSelectionArtifact {
        let envelope: SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        } catch {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        guard envelope.schemaVersion == PhotoSelectionArtifact.currentSchemaVersion else {
            throw PhotoSelectionArtifactStoreError.unsupportedSchema(
                envelope.schemaVersion
            )
        }
        let artifact: PhotoSelectionArtifact
        do {
            artifact = try JSONDecoder().decode(PhotoSelectionArtifact.self, from: data)
        } catch {
            throw PhotoSelectionArtifactStoreError.invalidArtifact
        }
        try validate(artifact)
        return artifact
    }

    private static func fileEvidence(
        for data: Data
    ) -> PhotoSelectionArtifactFileEvidence {
        PhotoSelectionArtifactFileEvidence(
            byteCount: Int64(data.count),
            sha256: sha256(data)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
