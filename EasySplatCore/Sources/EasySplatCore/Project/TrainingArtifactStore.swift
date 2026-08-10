import Darwin
import CryptoKit
import Foundation

package enum TrainingFilesystemCheckpoint: Sendable, Equatable {
    case manifestDirectoryBound
    case preparedManifestDirectoryBound
    case preparedManifestReadyToInstall
    case preparedManifestInstalled
    case checkpointDiscardDirectoryBound
    case checkpointDiscardIntentDurable
    case checkpointDiscardCheckpointRenamed
    case checkpointDiscardManifestRenamed
    case checkpointDiscardQuarantineRetired(String)
    case checkpointDiscardJournalUnlinked
    case completedDiscardDirectoryBound
    case disposableCleanupDirectoryBound
    case disposableCleanupIntentDurable
    case disposableCleanupCheckpointRenamed
    case disposableCleanupCheckpointDurable
    case disposableCleanupMsplatRenamed
    case disposableCleanupMsplatDurable
    case disposableCleanupWillRetireEntry(String)
    case disposableCleanupQuarantineRetired(String)
    case disposableCleanupJournalUnlinked
    case previewCleanupDirectoryBound
}

package struct TrainingFilesystemOperations: Sendable {
    package var checkpoint: @Sendable (TrainingFilesystemCheckpoint) throws -> Void
    package var makeCleanupID: @Sendable () -> UUID
    package var synchronizeCleanupFile: @Sendable (Int32) -> Int32
    package var synchronizeCleanupDirectory: @Sendable (Int32) -> Int32
    package var renameCleanupExclusive: @Sendable (
        Int32,
        String,
        Int32,
        String
    ) -> Int32
    package var unlinkCleanupEntry: @Sendable (Int32, String, Int32) -> Int32

    package init(
        checkpoint: @escaping @Sendable (TrainingFilesystemCheckpoint) throws -> Void = { _ in }
    ) {
        self.checkpoint = checkpoint
        self.makeCleanupID = UUID.init
        self.synchronizeCleanupFile = { descriptor in
            while true {
                if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return 0 }
                let code = errno
                if code == EINTR { continue }
                guard code == EINVAL || code == ENOTSUP else {
                    errno = code
                    return -1
                }
                while Darwin.fsync(descriptor) != 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                return 0
            }
        }
        self.synchronizeCleanupDirectory = { descriptor in
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                return -1
            }
            return 0
        }
        self.renameCleanupExclusive = {
            sourceDirectory,
            source,
            destinationDirectory,
            destination in
            source.withCString { sourcePointer in
                destination.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        sourceDirectory,
                        sourcePointer,
                        destinationDirectory,
                        destinationPointer,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
        }
        self.unlinkCleanupEntry = { directory, leaf, flags in
            leaf.withCString { Darwin.unlinkat(directory, $0, flags) }
        }
    }

    package static let live = TrainingFilesystemOperations()
}

package enum CompletedTrainingCleanupAuthorization: Sendable, Equatable {
    /// Inspect and retire already-unreachable quarantines, but return before a
    /// canonical root would require a published-result generation decision.
    case deferred
    /// No current validated result exists. Exact canonical roots are preserved
    /// and the obsolete intent can be retired without granting deletion authority.
    case unavailable
    /// A pair-lock-bound result that may authorize moving exact canonical roots.
    case published(ValidatedPublishedResult)
}

package enum CompletedTrainingCleanupReconciliation: Sendable, Equatable {
    case noTraining
    case noJournal
    case completed
    case requiresPublishedResult
    case deferredConflict
}

private final class CompletedTrainingCleanupReconciliationBox {
    var value: CompletedTrainingCleanupReconciliation

    init(_ value: CompletedTrainingCleanupReconciliation) {
        self.value = value
    }
}

/// The exact canonical manifest file authenticated before the published-result
/// pair commits. Publication carries this value across the pair/manifest
/// boundary so a byte-identical pathname replacement cannot inherit authority.
package struct PreparedTrainingManifestSourceIdentity: Sendable, Equatable {
    package let device: dev_t
    package let inode: ino_t
    package let byteCount: off_t
    package let owner: uid_t
    package let mode: mode_t
    package let linkCount: nlink_t
    package let modifiedSeconds: time_t
    package let modifiedNanoseconds: Int64
    package let changedSeconds: time_t
    package let changedNanoseconds: Int64

    package init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        byteCount = status.st_size
        owner = status.st_uid
        mode = status.st_mode
        linkCount = status.st_nlink
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    package func matches(_ status: stat) -> Bool {
        self == PreparedTrainingManifestSourceIdentity(status)
    }
}

private struct TrainingNodeIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
    let flags: UInt32

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        owner = status.st_uid
        group = status.st_gid
        mode = status.st_mode
        flags = status.st_flags
    }

    func matches(_ status: stat) -> Bool {
        self == TrainingNodeIdentity(status)
    }
}

private struct TrainingFileIdentity: Equatable {
    let node: TrainingNodeIdentity
    let linkCount: nlink_t
    let size: off_t
    let modifiedSeconds: time_t
    let modifiedNanoseconds: Int64
    let createdSeconds: time_t
    let createdNanoseconds: Int64

    init(_ status: stat) {
        node = TrainingNodeIdentity(status)
        linkCount = status.st_nlink
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        createdSeconds = status.st_birthtimespec.tv_sec
        createdNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
    }

    func matches(_ status: stat) -> Bool {
        self == TrainingFileIdentity(status)
    }
}

private struct TrainingRollbackFileIdentity: Equatable {
    let file: TrainingFileIdentity
    let changedSeconds: time_t
    let changedNanoseconds: Int64

    init(_ status: stat) {
        file = TrainingFileIdentity(status)
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    func matches(_ status: stat) -> Bool {
        self == TrainingRollbackFileIdentity(status)
    }
}

private struct TrainingCleanupDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireTrainingCleanupKeys(
    _ decoder: Decoder,
    required: Set<String>,
    optional: Set<String> = []
) throws -> Set<String> {
    let container = try decoder.container(keyedBy: TrainingCleanupDynamicCodingKey.self)
    let keys = Set(container.allKeys.map(\.stringValue))
    guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Completed-training cleanup keys do not match schema v1."
            )
        )
    }
    return keys
}

private func trainingCleanupIsSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

private let trainingCleanupZeroUUID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
)

private struct CompletedTrainingCleanupIdentityDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case inode
        case birthSeconds
        case birthNanoseconds
        case nodeType
    }

    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let nodeType: String

    init(_ status: stat) {
        inode = UInt64(status.st_ino)
        birthSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        nodeType = "directory"
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inode = try container.decode(UInt64.self, forKey: .inode)
        birthSeconds = try container.decode(Int64.self, forKey: .birthSeconds)
        birthNanoseconds = try container.decode(Int64.self, forKey: .birthNanoseconds)
        nodeType = try container.decode(String.self, forKey: .nodeType)
        guard inode > 0,
              birthSeconds >= 0,
              (0..<1_000_000_000).contains(birthNanoseconds),
              nodeType == "directory" else {
            throw DecodingError.dataCorruptedError(
                forKey: .inode,
                in: container,
                debugDescription: "Completed-training cleanup identity is invalid."
            )
        }
    }

    func matches(_ status: stat, trainingDevice: dev_t) -> Bool {
        status.st_dev == trainingDevice
            && UInt64(status.st_ino) == inode
            && Int64(status.st_birthtimespec.tv_sec) == birthSeconds
            && Int64(status.st_birthtimespec.tv_nsec) == birthNanoseconds
            && (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == geteuid()
            && (status.st_mode & mode_t(0o022)) == 0
            && status.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0
    }
}

private struct CompletedTrainingCleanupTargetDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case original
        case quarantine
        case identity
    }

    let original: String
    let quarantine: String
    let identity: CompletedTrainingCleanupIdentityDocument

    init(
        original: String,
        quarantine: String,
        identity: CompletedTrainingCleanupIdentityDocument
    ) {
        self.original = original
        self.quarantine = quarantine
        self.identity = identity
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        original = try container.decode(String.self, forKey: .original)
        quarantine = try container.decode(String.self, forKey: .quarantine)
        identity = try container.decode(
            CompletedTrainingCleanupIdentityDocument.self,
            forKey: .identity
        )
    }
}

private struct CompletedTrainingCleanupPointDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case x, y, z }

    let x: Double
    let y: Double
    let z: Double

    init(_ point: ScenePoint3D) {
        x = point.x
        y = point.y
        z = point.z
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        z = try container.decode(Double.self, forKey: .z)
        guard x.isFinite, y.isFinite, z.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Completed-training cleanup bounds are non-finite."
            )
        }
    }

    var point: ScenePoint3D { ScenePoint3D(x: x, y: y, z: z) }
}

private struct CompletedTrainingCleanupBoundsDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case center, radius }

    let center: CompletedTrainingCleanupPointDocument
    let radius: Double

    init(_ bounds: SplatSceneBounds) {
        center = CompletedTrainingCleanupPointDocument(bounds.center)
        radius = bounds.radius
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decode(
            CompletedTrainingCleanupPointDocument.self,
            forKey: .center
        )
        radius = try container.decode(Double.self, forKey: .radius)
        guard radius.isFinite, radius > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .radius,
                in: container,
                debugDescription: "Completed-training cleanup radius is invalid."
            )
        }
    }

    var bounds: SplatSceneBounds { SplatSceneBounds(center: center.point, radius: radius) }
}

private struct CompletedTrainingCleanupEvidenceDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case byteCount
        case gaussianCount
        case format
        case sha256
        case sceneBounds
    }

    let byteCount: UInt64
    let gaussianCount: Int
    let format: String
    let sha256: String
    let sceneBounds: CompletedTrainingCleanupBoundsDocument

    init(_ evidence: ValidatedPlyArtifactEvidence) {
        byteCount = evidence.byteCount
        gaussianCount = evidence.vertexCount
        format = evidence.format
        sha256 = evidence.sha256
        sceneBounds = CompletedTrainingCleanupBoundsDocument(evidence.sceneBounds)
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byteCount = try container.decode(UInt64.self, forKey: .byteCount)
        gaussianCount = try container.decode(Int.self, forKey: .gaussianCount)
        format = try container.decode(String.self, forKey: .format)
        sha256 = try container.decode(String.self, forKey: .sha256)
        sceneBounds = try container.decode(
            CompletedTrainingCleanupBoundsDocument.self,
            forKey: .sceneBounds
        )
        guard byteCount > 0,
              byteCount <= UInt64(Int64.max),
              gaussianCount > 0,
              UInt64(gaussianCount) <= byteCount,
              ["ascii", "binary_little_endian", "binary_big_endian"].contains(format),
              trainingCleanupIsSHA256(sha256) else {
            throw DecodingError.dataCorruptedError(
                forKey: .byteCount,
                in: container,
                debugDescription: "Completed-training cleanup PLY evidence is invalid."
            )
        }
    }

    var evidence: ValidatedPlyArtifactEvidence {
        ValidatedPlyArtifactEvidence(
            byteCount: byteCount,
            vertexCount: gaussianCount,
            format: format,
            sha256: sha256,
            sceneBounds: sceneBounds.bounds
        )
    }
}

private struct CompletedTrainingCleanupGenerationDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case projectID
        case publicationID
        case outputEvidence
        case trainingManifestSHA256
        case trainingInputDigest
        case trainingGeometryDigest
    }

    let projectID: UUID
    let publicationID: UUID
    let outputEvidence: CompletedTrainingCleanupEvidenceDocument
    let trainingManifestSHA256: String
    let trainingInputDigest: String
    let trainingGeometryDigest: String

    init(validating result: ValidatedPublishedResult) throws {
        let receipt = result.receipt
        guard receipt.schemaVersion == PublishedSplatReceipt.currentSchemaVersion,
              receipt.projectID != trainingCleanupZeroUUID,
              receipt.publicationID != trainingCleanupZeroUUID,
              receipt.outputPath == PublishedSplatReceipt.canonicalOutputPath,
              receipt.outputEvidence == result.outputEvidence,
              trainingCleanupIsSHA256(receipt.lineage.trainingManifestSHA256),
              trainingCleanupIsSHA256(receipt.lineage.trainingInputDigest),
              trainingCleanupIsSHA256(receipt.lineage.trainingGeometryDigest) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        projectID = receipt.projectID
        publicationID = receipt.publicationID
        outputEvidence = CompletedTrainingCleanupEvidenceDocument(result.outputEvidence)
        trainingManifestSHA256 = receipt.lineage.trainingManifestSHA256
        trainingInputDigest = receipt.lineage.trainingInputDigest
        trainingGeometryDigest = receipt.lineage.trainingGeometryDigest
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        publicationID = try container.decode(UUID.self, forKey: .publicationID)
        outputEvidence = try container.decode(
            CompletedTrainingCleanupEvidenceDocument.self,
            forKey: .outputEvidence
        )
        trainingManifestSHA256 = try container.decode(
            String.self,
            forKey: .trainingManifestSHA256
        )
        trainingInputDigest = try container.decode(
            String.self,
            forKey: .trainingInputDigest
        )
        trainingGeometryDigest = try container.decode(
            String.self,
            forKey: .trainingGeometryDigest
        )
        guard projectID != trainingCleanupZeroUUID,
              publicationID != trainingCleanupZeroUUID,
              trainingCleanupIsSHA256(trainingManifestSHA256),
              trainingCleanupIsSHA256(trainingInputDigest),
              trainingCleanupIsSHA256(trainingGeometryDigest) else {
            throw DecodingError.dataCorruptedError(
                forKey: .projectID,
                in: container,
                debugDescription: "Completed-training cleanup generation is invalid."
            )
        }
    }
}

private struct CompletedTrainingCleanupJournalDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case cleanupID
        case generation
        case checkpointTarget
        case msplatTarget
    }

    let schemaVersion: Int
    let cleanupID: UUID
    let generation: CompletedTrainingCleanupGenerationDocument
    let checkpointTarget: CompletedTrainingCleanupTargetDocument?
    let msplatTarget: CompletedTrainingCleanupTargetDocument?

    init(
        cleanupID: UUID,
        generation: CompletedTrainingCleanupGenerationDocument,
        checkpointTarget: CompletedTrainingCleanupTargetDocument?,
        msplatTarget: CompletedTrainingCleanupTargetDocument?
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.cleanupID = cleanupID
        self.generation = generation
        self.checkpointTarget = checkpointTarget
        self.msplatTarget = msplatTarget
        try validate()
    }

    init(from decoder: Decoder) throws {
        let keys = try requireTrainingCleanupKeys(
            decoder,
            required: [
                CodingKeys.schemaVersion.rawValue,
                CodingKeys.cleanupID.rawValue,
                CodingKeys.generation.rawValue,
            ],
            optional: [
                CodingKeys.checkpointTarget.rawValue,
                CodingKeys.msplatTarget.rawValue,
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        cleanupID = try container.decode(UUID.self, forKey: .cleanupID)
        generation = try container.decode(
            CompletedTrainingCleanupGenerationDocument.self,
            forKey: .generation
        )
        checkpointTarget = keys.contains(CodingKeys.checkpointTarget.rawValue)
            ? try container.decode(
                CompletedTrainingCleanupTargetDocument.self,
                forKey: .checkpointTarget
            )
            : nil
        msplatTarget = keys.contains(CodingKeys.msplatTarget.rawValue)
            ? try container.decode(
                CompletedTrainingCleanupTargetDocument.self,
                forKey: .msplatTarget
            )
            : nil
        try validate()
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              cleanupID != trainingCleanupZeroUUID,
              checkpointTarget != nil || msplatTarget != nil else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let prefix = ".completed-training-cleanup.\(cleanupID.uuidString)."
        if let checkpointTarget {
            guard checkpointTarget.original == "checkpoints/msplat",
                  checkpointTarget.quarantine == prefix + "checkpoints" else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
        if let msplatTarget {
            guard msplatTarget.original == "msplat",
                  msplatTarget.quarantine == prefix + "msplat" else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
        guard checkpointTarget?.quarantine != msplatTarget?.quarantine else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }
}

private struct CheckpointDiscardCleanupIdentityDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case inode
        case birthSeconds
        case birthNanoseconds
        case nodeType
    }

    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let nodeType: String

    init(validating status: stat) throws {
        let type: String
        switch status.st_mode & S_IFMT {
        case S_IFDIR: type = "directory"
        case S_IFREG: type = "regular"
        case S_IFLNK: type = "symlink"
        default: throw TrainingArtifactStoreError.invalidManifest
        }
        inode = UInt64(status.st_ino)
        birthSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        nodeType = type
        try validate()
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inode = try container.decode(UInt64.self, forKey: .inode)
        birthSeconds = try container.decode(Int64.self, forKey: .birthSeconds)
        birthNanoseconds = try container.decode(Int64.self, forKey: .birthNanoseconds)
        nodeType = try container.decode(String.self, forKey: .nodeType)
        try validate()
    }

    private func validate() throws {
        guard inode > 0,
              birthSeconds >= 0,
              (0..<1_000_000_000).contains(birthNanoseconds),
              ["directory", "regular", "symlink"].contains(nodeType) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    func matches(_ status: stat, trainingDevice: dev_t) -> Bool {
        guard status.st_dev == trainingDevice,
              UInt64(status.st_ino) == inode,
              Int64(status.st_birthtimespec.tv_sec) == birthSeconds,
              Int64(status.st_birthtimespec.tv_nsec) == birthNanoseconds,
              status.st_uid == geteuid(),
              status.st_flags
                & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0 else {
            return false
        }
        switch nodeType {
        case "directory":
            return (status.st_mode & S_IFMT) == S_IFDIR
                && status.st_nlink > 0
                && (status.st_mode & mode_t(0o022)) == 0
        case "regular":
            return (status.st_mode & S_IFMT) == S_IFREG
                && status.st_nlink == 1
                && (status.st_mode & mode_t(0o022)) == 0
        case "symlink":
            return (status.st_mode & S_IFMT) == S_IFLNK
                && status.st_nlink == 1
        default:
            return false
        }
    }
}

private struct CheckpointDiscardCleanupTargetDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case original
        case quarantine
        case identity
    }

    let original: String
    let quarantine: String
    let identity: CheckpointDiscardCleanupIdentityDocument

    init(
        original: String,
        quarantine: String,
        identity: CheckpointDiscardCleanupIdentityDocument
    ) {
        self.original = original
        self.quarantine = quarantine
        self.identity = identity
    }

    init(from decoder: Decoder) throws {
        _ = try requireTrainingCleanupKeys(
            decoder,
            required: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        original = try container.decode(String.self, forKey: .original)
        quarantine = try container.decode(String.self, forKey: .quarantine)
        identity = try container.decode(
            CheckpointDiscardCleanupIdentityDocument.self,
            forKey: .identity
        )
    }
}

private struct CheckpointDiscardCleanupJournalDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case cleanupID
        case checkpointTarget
        case manifestTarget
    }

    let schemaVersion: Int
    let cleanupID: UUID
    let checkpointTarget: CheckpointDiscardCleanupTargetDocument?
    let manifestTarget: CheckpointDiscardCleanupTargetDocument?

    init(
        cleanupID: UUID,
        checkpointTarget: CheckpointDiscardCleanupTargetDocument?,
        manifestTarget: CheckpointDiscardCleanupTargetDocument?
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.cleanupID = cleanupID
        self.checkpointTarget = checkpointTarget
        self.manifestTarget = manifestTarget
        try validate()
    }

    init(from decoder: Decoder) throws {
        let keys = try requireTrainingCleanupKeys(
            decoder,
            required: [
                CodingKeys.schemaVersion.rawValue,
                CodingKeys.cleanupID.rawValue,
            ],
            optional: [
                CodingKeys.checkpointTarget.rawValue,
                CodingKeys.manifestTarget.rawValue,
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        cleanupID = try container.decode(UUID.self, forKey: .cleanupID)
        checkpointTarget = keys.contains(CodingKeys.checkpointTarget.rawValue)
            ? try container.decode(
                CheckpointDiscardCleanupTargetDocument.self,
                forKey: .checkpointTarget
            )
            : nil
        manifestTarget = keys.contains(CodingKeys.manifestTarget.rawValue)
            ? try container.decode(
                CheckpointDiscardCleanupTargetDocument.self,
                forKey: .manifestTarget
            )
            : nil
        try validate()
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              cleanupID != trainingCleanupZeroUUID,
              checkpointTarget != nil || manifestTarget != nil else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let prefix = ".checkpoint-discard-cleanup.\(cleanupID.uuidString)."
        if let checkpointTarget {
            guard checkpointTarget.original == "checkpoints/msplat",
                  checkpointTarget.quarantine == prefix + "checkpoints",
                  ["directory", "symlink"].contains(
                    checkpointTarget.identity.nodeType
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
        if let manifestTarget {
            guard manifestTarget.original == "training_manifest.json",
                  manifestTarget.quarantine == prefix + "manifest",
                  ["regular", "symlink"].contains(
                    manifestTarget.identity.nodeType
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
        guard checkpointTarget?.quarantine != manifestTarget?.quarantine else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }
}

/// A narrow descriptor-bound view of the mutable Training subtree. It exists so
/// authoritative writes and cleanup never return to pathname traversal after a
/// containment check has succeeded.
private final class BoundTrainingFilesystem {
    private static let maximumTraversalDepth = 64
    private static let maximumTraversalEntries = 50_000
    private static let maximumCleanupJournalBytes = 65_536
    private static let maximumTrainingManifestBytes = 1_048_576
    private static let cleanupJournalLeaf = ".completed-training-cleanup.json"
    private static let checkpointDiscardJournalLeaf = ".checkpoint-discard-cleanup.json"

    private enum CleanupJournalLoad {
        case absent
        case valid(CompletedTrainingCleanupJournalDocument, TrainingFileIdentity)
        case conflict
    }

    private enum CleanupEntryState: Equatable {
        case absent
        case exact
        case different
    }

    private struct CleanupTargetState {
        let target: CompletedTrainingCleanupTargetDocument
        let original: CleanupEntryState
        let quarantine: CleanupEntryState
    }

    private enum CheckpointDiscardJournalLoad {
        case absent
        case valid(
            CheckpointDiscardCleanupJournalDocument,
            TrainingFileIdentity
        )
        case conflict
    }

    private struct CheckpointDiscardTargetState {
        let target: CheckpointDiscardCleanupTargetDocument
        let original: CleanupEntryState
        let quarantine: CleanupEntryState
    }

    private enum CheckpointManifestDisposition {
        case absent
        case preserve
        case regular(CheckpointDiscardCleanupIdentityDocument)
        case symbolicLink(CheckpointDiscardCleanupIdentityDocument)
    }

    private let paths: ProjectPaths
    private let projectDescriptor: Int32
    private let trainingDescriptor: Int32
    private let projectIdentity: TrainingNodeIdentity
    private let trainingIdentity: TrainingNodeIdentity
    private let requiresAbsoluteProjectRevalidation: Bool

    convenience init(paths: ProjectPaths) throws {
        let projectDescriptor = Darwin.open(
            paths.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard projectDescriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try self.init(
            paths: paths,
            owningProjectDescriptor: projectDescriptor,
            requiresAbsoluteProjectRevalidation: true
        )
    }

    convenience init(paths: ProjectPaths, projectRootDescriptor: Int32) throws {
        let duplicate = Darwin.fcntl(
            projectRootDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard duplicate >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try self.init(
            paths: paths,
            owningProjectDescriptor: duplicate,
            requiresAbsoluteProjectRevalidation: false
        )
    }

    private init(
        paths: ProjectPaths,
        owningProjectDescriptor projectDescriptor: Int32,
        requiresAbsoluteProjectRevalidation: Bool
    ) throws {
        var keepProjectDescriptor = false
        defer {
            if !keepProjectDescriptor { Darwin.close(projectDescriptor) }
        }

        var projectStatus = stat()
        guard Darwin.fstat(projectDescriptor, &projectStatus) == 0,
              (projectStatus.st_mode & S_IFMT) == S_IFDIR,
              projectStatus.st_uid == geteuid() else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        var namedTrainingStatus = stat()
        let namedTrainingResult = "Training".withCString {
            Darwin.fstatat(
                projectDescriptor,
                $0,
                &namedTrainingStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard namedTrainingResult == 0,
              (namedTrainingStatus.st_mode & S_IFMT) == S_IFDIR,
              namedTrainingStatus.st_uid == geteuid() else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        let trainingDescriptor = "Training".withCString {
            Darwin.openat(
                projectDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard trainingDescriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var keepTrainingDescriptor = false
        defer {
            if !keepTrainingDescriptor { Darwin.close(trainingDescriptor) }
        }

        var openedTrainingStatus = stat()
        guard Darwin.fstat(trainingDescriptor, &openedTrainingStatus) == 0,
              TrainingNodeIdentity(namedTrainingStatus).matches(openedTrainingStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        self.paths = paths
        self.projectDescriptor = projectDescriptor
        self.trainingDescriptor = trainingDescriptor
        self.projectIdentity = TrainingNodeIdentity(projectStatus)
        self.trainingIdentity = TrainingNodeIdentity(openedTrainingStatus)
        self.requiresAbsoluteProjectRevalidation =
            requiresAbsoluteProjectRevalidation
        keepProjectDescriptor = true
        keepTrainingDescriptor = true
    }

    deinit {
        Darwin.close(trainingDescriptor)
        Darwin.close(projectDescriptor)
    }

    func verifyNamespace() throws {
        var projectStatus = stat()
        var trainingStatus = stat()
        var namedTrainingStatus = stat()
        guard Darwin.fstat(projectDescriptor, &projectStatus) == 0,
              projectIdentity.matches(projectStatus),
              Darwin.fstat(trainingDescriptor, &trainingStatus) == 0,
              trainingStatus.st_nlink > 0,
              trainingIdentity.matches(trainingStatus),
              "Training".withCString({
                  Darwin.fstatat(
                      projectDescriptor,
                      $0,
                      &namedTrainingStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              namedTrainingStatus.st_nlink > 0,
              trainingIdentity.matches(namedTrainingStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        if requiresAbsoluteProjectRevalidation {
            let reboundProject = Darwin.open(
                paths.root.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard reboundProject >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            defer { Darwin.close(reboundProject) }
            var reboundStatus = stat()
            guard Darwin.fstat(reboundProject, &reboundStatus) == 0,
                  projectIdentity.matches(reboundStatus) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
    }

    func readBoundGeometryManifestData(maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try verifyNamespace()
        let sfmDescriptor = "SfM".withCString {
            Darwin.openat(
                projectDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard sfmDescriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(sfmDescriptor) }
        var namedSfmStatus = stat()
        var openedSfmStatus = stat()
        guard "SfM".withCString({
            Darwin.fstatat(
                projectDescriptor,
                $0,
                &namedSfmStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        Darwin.fstat(sfmDescriptor, &openedSfmStatus) == 0,
        TrainingNodeIdentity(namedSfmStatus).matches(openedSfmStatus),
        (openedSfmStatus.st_mode & S_IFMT) == S_IFDIR,
        openedSfmStatus.st_dev == projectIdentity.device,
        openedSfmStatus.st_uid == geteuid(),
        (openedSfmStatus.st_mode & mode_t(0o022)) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let sfmIdentity = TrainingNodeIdentity(openedSfmStatus)

        let leaf = "geometry_manifest.json"
        let descriptor = leaf.withCString {
            Darwin.openat(
                sfmDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(descriptor) }
        var namedStatus = stat()
        var openedStatus = stat()
        guard leaf.withCString({
            Darwin.fstatat(
                sfmDescriptor,
                $0,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        Darwin.fstat(descriptor, &openedStatus) == 0,
        TrainingRollbackFileIdentity(namedStatus).matches(openedStatus),
        (openedStatus.st_mode & S_IFMT) == S_IFREG,
        openedStatus.st_dev == projectIdentity.device,
        openedStatus.st_uid == geteuid(),
        openedStatus.st_nlink == 1,
        (openedStatus.st_mode & mode_t(0o022)) == 0,
        openedStatus.st_size > 0,
        openedStatus.st_size <= off_t(maximumBytes) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let identity = TrainingRollbackFileIdentity(openedStatus)
        var data = Data(count: Int(openedStatus.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0, count <= bytes.count - offset else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                offset += count
            }
        }
        var finalOpenedStatus = stat()
        var finalNamedStatus = stat()
        var finalSfmStatus = stat()
        guard Darwin.fstat(descriptor, &finalOpenedStatus) == 0,
              identity.matches(finalOpenedStatus),
              leaf.withCString({
                  Darwin.fstatat(
                      sfmDescriptor,
                      $0,
                      &finalNamedStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              identity.matches(finalNamedStatus),
              Darwin.fstat(sfmDescriptor, &finalSfmStatus) == 0,
              sfmIdentity.matches(finalSfmStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try verifyNamespace()
        return data
    }

    func replaceManifest(with data: Data, maximumBytes: Int) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try verifyNamespace()

        let temporaryName = ".training-manifest.\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(descriptor) }

        var published = false
        var temporaryIdentity: TrainingFileIdentity?
        defer {
            if !published {
                var openedStatus = stat()
                var namedStatus = stat()
                if Darwin.fstat(descriptor, &openedStatus) == 0,
                   temporaryName.withCString({
                       Darwin.fstatat(
                           trainingDescriptor,
                           $0,
                           &namedStatus,
                           AT_SYMLINK_NOFOLLOW
                       )
                   }) == 0,
                   TrainingNodeIdentity(openedStatus).matches(namedStatus),
                   temporaryIdentity.map({ $0.matches(namedStatus) }) ?? true {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(trainingDescriptor, $0, 0)
                    }
                }
            }
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try writeAll(data, to: descriptor)
        try synchronize(descriptor)

        var stagedStatus = stat()
        guard Darwin.fstat(descriptor, &stagedStatus) == 0,
              (stagedStatus.st_mode & S_IFMT) == S_IFREG,
              (stagedStatus.st_mode & 0o7777) == mode_t(0o600),
              stagedStatus.st_uid == geteuid(),
              stagedStatus.st_nlink == 1,
              stagedStatus.st_size == off_t(data.count) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let stagedIdentity = TrainingFileIdentity(stagedStatus)
        temporaryIdentity = stagedIdentity

        try verifyNamespace()
        let renameResult = temporaryName.withCString { temporary in
            "training_manifest.json".withCString { canonical in
                Darwin.renameatx_np(
                    trainingDescriptor,
                    temporary,
                    trainingDescriptor,
                    canonical,
                    UInt32(RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard renameResult == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        published = true
        try synchronize(trainingDescriptor)
        try verifyNamespace()

        let persistedDescriptor = "training_manifest.json".withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard persistedDescriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(persistedDescriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(persistedDescriptor, &openedStatus) == 0,
              stagedIdentity.matches(openedStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let persistedData = try readBounded(
            descriptor: persistedDescriptor,
            expected: stagedIdentity,
            maximumBytes: maximumBytes
        )
        var reboundStatus = stat()
        guard "training_manifest.json".withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &reboundStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        stagedIdentity.matches(reboundStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try verifyNamespace()
        return persistedData
    }

    /// Rebinds the completed training manifest only when the canonical file is
    /// still the exact file and bytes the publication decision authenticated.
    /// `RENAME_SWAP` makes the replacement reversible: the displaced manifest
    /// remains available under the private candidate name until both lineage
    /// boundaries and the newly installed canonical bytes have been verified.
    func compareAndSwapManifest(
        expectingSourceIdentity expectedSourceIdentity: PreparedTrainingManifestSourceIdentity,
        expecting allowedCurrentData: [Data],
        with replacementData: Data,
        maximumBytes: Int,
        validateBeforeSwap: () throws -> Void,
        willInstall: () throws -> Void,
        validateAfterSwap: () throws -> Void
    ) throws -> Data {
        guard !allowedCurrentData.isEmpty,
              allowedCurrentData.allSatisfy({ !$0.isEmpty && $0.count <= maximumBytes }),
              !replacementData.isEmpty,
              replacementData.count <= maximumBytes else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try verifyNamespace()

        var namedSourceStatus = stat()
        guard "training_manifest.json".withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &namedSourceStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        (namedSourceStatus.st_mode & S_IFMT) == S_IFREG,
        (namedSourceStatus.st_mode & 0o7777) == mode_t(0o600),
        namedSourceStatus.st_uid == geteuid(),
        namedSourceStatus.st_nlink == 1,
        namedSourceStatus.st_size > 0,
        namedSourceStatus.st_size <= off_t(maximumBytes),
        expectedSourceIdentity.matches(namedSourceStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let sourceIdentity = TrainingFileIdentity(namedSourceStatus)
        let sourceDescriptor = "training_manifest.json".withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard sourceDescriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(sourceDescriptor) }
        var openedSourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &openedSourceStatus) == 0,
              sourceIdentity.matches(openedSourceStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let sourceData = try readBounded(
                descriptor: sourceDescriptor,
                expected: sourceIdentity,
                maximumBytes: maximumBytes
            )
        guard allowedCurrentData.contains(sourceData) else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        func canonicalStillNamesSource() -> Bool {
            var reboundStatus = stat()
            return "training_manifest.json".withCString({
                Darwin.fstatat(
                    trainingDescriptor,
                    $0,
                    &reboundStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0 && sourceIdentity.matches(reboundStatus)
        }

        if sourceData == replacementData {
            try validateBeforeSwap()
            try verifyNamespace()
            guard canonicalStillNamesSource(),
                  try readBounded(
                    descriptor: sourceDescriptor,
                    expected: sourceIdentity,
                    maximumBytes: maximumBytes
                  ) == replacementData else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            try validateAfterSwap()
            try verifyNamespace()
            guard canonicalStillNamesSource(),
                  try readBounded(
                    descriptor: sourceDescriptor,
                    expected: sourceIdentity,
                    maximumBytes: maximumBytes
                  ) == replacementData else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            return replacementData
        }

        let temporaryName = ".training-manifest.\(UUID().uuidString).tmp"
        let stagedDescriptor = temporaryName.withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard stagedDescriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(stagedDescriptor) }

        enum TemporaryContents: Equatable {
            case staged
            case displacedSource
            case absent
            case ambiguous
        }
        var temporaryContents = TemporaryContents.staged
        var stagedIdentity: TrainingFileIdentity?
        defer {
            if temporaryContents == .staged,
               let stagedIdentity {
                var namedStatus = stat()
                if temporaryName.withCString({
                    Darwin.fstatat(
                        trainingDescriptor,
                        $0,
                        &namedStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0,
                stagedIdentity.matches(namedStatus) {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(trainingDescriptor, $0, 0)
                    }
                }
            }
        }

        guard Darwin.fchmod(stagedDescriptor, mode_t(0o600)) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try writeAll(replacementData, to: stagedDescriptor)
        try synchronize(stagedDescriptor)
        var stagedStatus = stat()
        guard Darwin.fstat(stagedDescriptor, &stagedStatus) == 0,
              (stagedStatus.st_mode & S_IFMT) == S_IFREG,
              (stagedStatus.st_mode & 0o7777) == mode_t(0o600),
              stagedStatus.st_uid == geteuid(),
              stagedStatus.st_nlink == 1,
              stagedStatus.st_size == off_t(replacementData.count) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let exactStagedIdentity = TrainingFileIdentity(stagedStatus)
        stagedIdentity = exactStagedIdentity

        try validateBeforeSwap()
        try verifyNamespace()
        var reboundSourceStatus = stat()
        guard "training_manifest.json".withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &reboundSourceStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        sourceIdentity.matches(reboundSourceStatus),
        try readBounded(
            descriptor: sourceDescriptor,
            expected: sourceIdentity,
            maximumBytes: maximumBytes
        ) == sourceData else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try willInstall()
        try verifyNamespace()
        var preSwapStagedStatus = stat()
        var preSwapOpenedStagedStatus = stat()
        guard canonicalStillNamesSource(),
              temporaryName.withCString({
                  Darwin.fstatat(
                      trainingDescriptor,
                      $0,
                      &preSwapStagedStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              exactStagedIdentity.matches(preSwapStagedStatus),
              Darwin.fstat(stagedDescriptor, &preSwapOpenedStagedStatus) == 0,
              exactStagedIdentity.matches(preSwapOpenedStagedStatus),
              try readBounded(
                  descriptor: sourceDescriptor,
                  expected: sourceIdentity,
                  maximumBytes: maximumBytes
              ) == sourceData,
              try readBounded(
                  descriptor: stagedDescriptor,
                  expected: exactStagedIdentity,
                  maximumBytes: maximumBytes
              ) == replacementData else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        let swapResult = temporaryName.withCString { temporary in
            "training_manifest.json".withCString { canonical in
                Darwin.renameatx_np(
                    trainingDescriptor,
                    temporary,
                    trainingDescriptor,
                    canonical,
                    UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard swapResult == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        temporaryContents = .displacedSource

        func exactSwappedState(
            displacedIdentity: TrainingRollbackFileIdentity
        ) throws -> Bool {
            var canonicalStatus = stat()
            var displacedStatus = stat()
            var openedStagedStatus = stat()
            var openedDisplacedStatus = stat()
            guard "training_manifest.json".withCString({
                Darwin.fstatat(
                    trainingDescriptor,
                    $0,
                    &canonicalStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0
                && temporaryName.withCString({
                    Darwin.fstatat(
                        trainingDescriptor,
                        $0,
                        &displacedStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0
                && exactStagedIdentity.matches(canonicalStatus)
                && displacedIdentity.matches(displacedStatus)
                && Darwin.fstat(stagedDescriptor, &openedStagedStatus) == 0
                && exactStagedIdentity.matches(openedStagedStatus)
                && Darwin.fstat(sourceDescriptor, &openedDisplacedStatus) == 0
                && displacedIdentity.matches(openedDisplacedStatus) else {
                return false
            }
            return try readBounded(
                descriptor: stagedDescriptor,
                expected: exactStagedIdentity,
                maximumBytes: maximumBytes
            ) == replacementData
                && readBounded(
                    descriptor: sourceDescriptor,
                    expected: displacedIdentity.file,
                    maximumBytes: maximumBytes
                ) == sourceData
        }

        func exactRestoredState(
            displacedIdentity: TrainingRollbackFileIdentity
        ) throws -> Bool {
            var canonicalStatus = stat()
            var returnedStagedStatus = stat()
            var openedStagedStatus = stat()
            var openedDisplacedStatus = stat()
            guard "training_manifest.json".withCString({
                Darwin.fstatat(
                    trainingDescriptor,
                    $0,
                    &canonicalStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0,
            temporaryName.withCString({
                Darwin.fstatat(
                    trainingDescriptor,
                    $0,
                    &returnedStagedStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0,
            displacedIdentity.file.matches(canonicalStatus),
            exactStagedIdentity.matches(returnedStagedStatus),
            Darwin.fstat(stagedDescriptor, &openedStagedStatus) == 0,
            exactStagedIdentity.matches(openedStagedStatus),
            Darwin.fstat(sourceDescriptor, &openedDisplacedStatus) == 0,
            displacedIdentity.file.matches(openedDisplacedStatus) else {
                return false
            }
            let restoredIdentity = TrainingRollbackFileIdentity(
                openedDisplacedStatus
            )
            guard restoredIdentity.matches(canonicalStatus),
                  try readBounded(
                descriptor: sourceDescriptor,
                expected: displacedIdentity.file,
                maximumBytes: maximumBytes
            ) == sourceData,
                  try readBounded(
                    descriptor: stagedDescriptor,
                    expected: exactStagedIdentity,
                    maximumBytes: maximumBytes
                  ) == replacementData else {
                return false
            }
            var finalCanonicalStatus = stat()
            var finalOpenedDisplacedStatus = stat()
            return "training_manifest.json".withCString({
                Darwin.fstatat(
                    trainingDescriptor,
                    $0,
                    &finalCanonicalStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0
                && Darwin.fstat(
                    sourceDescriptor,
                    &finalOpenedDisplacedStatus
                ) == 0
                && restoredIdentity.matches(finalCanonicalStatus)
                && restoredIdentity.matches(finalOpenedDisplacedStatus)
        }

        func restoreInstalledManifestIfStagedTemporaryIsExact() {
            var temporaryStatus = stat()
            var openedStagedStatus = stat()
            guard temporaryName.withCString({
                Darwin.fstatat(
                    trainingDescriptor,
                    $0,
                    &temporaryStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0,
            exactStagedIdentity.matches(temporaryStatus),
            Darwin.fstat(stagedDescriptor, &openedStagedStatus) == 0,
            exactStagedIdentity.matches(openedStagedStatus),
            (try? readBounded(
                descriptor: stagedDescriptor,
                expected: exactStagedIdentity,
                maximumBytes: maximumBytes
            )) == replacementData else {
                return
            }
            let result = temporaryName.withCString { temporary in
                "training_manifest.json".withCString { canonical in
                    Darwin.renameatx_np(
                        trainingDescriptor,
                        temporary,
                        trainingDescriptor,
                        canonical,
                        UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard result == 0 else { return }
            try? synchronize(trainingDescriptor)
        }

        var displacedSourceIdentity: TrainingRollbackFileIdentity?
        do {
            try synchronize(trainingDescriptor)
            var openedDisplacedStatus = stat()
            var namedDisplacedStatus = stat()
            guard Darwin.fstat(sourceDescriptor, &openedDisplacedStatus) == 0,
                  temporaryName.withCString({
                    Darwin.fstatat(
                        trainingDescriptor,
                        $0,
                        &namedDisplacedStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                  }) == 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            let exactDisplacedIdentity = TrainingRollbackFileIdentity(
                openedDisplacedStatus
            )
            guard exactDisplacedIdentity.matches(namedDisplacedStatus),
                  try exactSwappedState(displacedIdentity: exactDisplacedIdentity) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            displacedSourceIdentity = exactDisplacedIdentity
            try validateAfterSwap()
            try verifyNamespace()
            guard try exactSwappedState(displacedIdentity: exactDisplacedIdentity) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        } catch {
            temporaryContents = .ambiguous
            if let displacedSourceIdentity,
               (try? exactSwappedState(
                    displacedIdentity: displacedSourceIdentity
               )) == true {
                let rollbackResult = temporaryName.withCString { temporary in
                    "training_manifest.json".withCString { canonical in
                        Darwin.renameatx_np(
                            trainingDescriptor,
                            temporary,
                            trainingDescriptor,
                            canonical,
                            UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
                        )
                    }
                }
                if rollbackResult == 0 {
                    try? synchronize(trainingDescriptor)
                    if (try? exactRestoredState(
                        displacedIdentity: displacedSourceIdentity
                    )) == true {
                        temporaryContents = .staged
                    } else {
                        restoreInstalledManifestIfStagedTemporaryIsExact()
                    }
                }
            }
            throw error
        }

        guard temporaryName.withCString({
            Darwin.unlinkat(trainingDescriptor, $0, 0)
        }) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        temporaryContents = .absent
        try synchronize(trainingDescriptor)
        try verifyNamespace()
        var finalStatus = stat()
        guard "training_manifest.json".withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &finalStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        exactStagedIdentity.matches(finalStatus),
        try readBounded(
            descriptor: stagedDescriptor,
            expected: exactStagedIdentity,
            maximumBytes: maximumBytes
        ) == replacementData else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return replacementData
    }

    func removeDisposableCompletedPayload(
        publishedResult: ValidatedPublishedResult,
        operations: TrainingFilesystemOperations,
        shouldCancel: @Sendable () -> Bool
    ) throws {
        let prior = try reconcileDisposableCompletedPayload(
            authorization: .published(publishedResult),
            operations: operations
        )
        guard prior != .deferredConflict,
              prior != .requiresPublishedResult else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        if shouldCancel() { throw CancellationError() }

        try verifyNamespace()
        let generation = try validatedCleanupGeneration(publishedResult)
        var visitedEntries = 0
        let cleanupID = operations.makeCleanupID()
        guard cleanupID != trainingCleanupZeroUUID else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let checkpointTarget = try captureCleanupTarget(
            original: "checkpoints/msplat",
            quarantine: cleanupQuarantineLeaf(
                cleanupID: cleanupID,
                suffix: "checkpoints"
            ),
            visitedEntries: &visitedEntries
        )
        let msplatTarget = try captureCleanupTarget(
            original: "msplat",
            quarantine: cleanupQuarantineLeaf(
                cleanupID: cleanupID,
                suffix: "msplat"
            ),
            visitedEntries: &visitedEntries
        )
        guard checkpointTarget != nil || msplatTarget != nil else { return }
        if shouldCancel() { throw CancellationError() }

        let journal = try CompletedTrainingCleanupJournalDocument(
            cleanupID: cleanupID,
            generation: generation,
            checkpointTarget: checkpointTarget,
            msplatTarget: msplatTarget
        )
        try publishCleanupJournal(journal, operations: operations)

        var deferredCancellation = shouldCancel()
        let reconciled = try reconcileDisposableCompletedPayload(
            authorization: .published(publishedResult),
            operations: operations
        )
        deferredCancellation = deferredCancellation || shouldCancel()
        guard reconciled == .completed || reconciled == .noJournal else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        if deferredCancellation { throw CancellationError() }
    }

    func discardCheckpointedArtifact(
        maximumManifestBytes: Int,
        operations: TrainingFilesystemOperations
    ) throws {
        try verifyNamespace()
        let prior = try reconcileCheckpointDiscard(operations: operations)
        guard prior != .deferredConflict else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let manifestDisposition = try checkpointManifestDisposition(
            maximumBytes: maximumManifestBytes
        )
        let cleanupID = operations.makeCleanupID()
        guard cleanupID != trainingCleanupZeroUUID else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var validationEntries = 0
        let checkpointTarget = try captureCheckpointDiscardTarget(
            original: "checkpoints/msplat",
            quarantine: checkpointDiscardQuarantineLeaf(
                cleanupID: cleanupID,
                suffix: "checkpoints"
            ),
            expectedIdentity: nil,
            validationEntries: &validationEntries
        )
        let manifestIdentity: CheckpointDiscardCleanupIdentityDocument?
        switch manifestDisposition {
        case .absent, .preserve:
            manifestIdentity = nil
        case .regular(let identity):
            manifestIdentity = identity
        case .symbolicLink(let identity):
            manifestIdentity = identity
        }
        let manifestTarget: CheckpointDiscardCleanupTargetDocument?
        if let manifestIdentity {
            manifestTarget = try captureCheckpointDiscardTarget(
                original: "training_manifest.json",
                quarantine: checkpointDiscardQuarantineLeaf(
                    cleanupID: cleanupID,
                    suffix: "manifest"
                ),
                expectedIdentity: manifestIdentity,
                validationEntries: &validationEntries
            )
        } else {
            manifestTarget = nil
        }
        guard checkpointTarget != nil || manifestTarget != nil else { return }
        let journal = try CheckpointDiscardCleanupJournalDocument(
            cleanupID: cleanupID,
            checkpointTarget: checkpointTarget,
            manifestTarget: manifestTarget
        )
        try publishCheckpointDiscardJournal(journal, operations: operations)
        guard try reconcileCheckpointDiscard(operations: operations) == .completed else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try verifyNamespace()
    }

    func reconcileCheckpointDiscard(
        operations: TrainingFilesystemOperations
    ) throws -> CompletedTrainingCleanupReconciliation {
        try verifyNamespace()
        let loaded = try loadCheckpointDiscardJournal()
        let journal: CheckpointDiscardCleanupJournalDocument
        let journalIdentity: TrainingFileIdentity
        switch loaded {
        case .absent:
            return .noJournal
        case .conflict:
            return .deferredConflict
        case .valid(let loadedJournal, let loadedIdentity):
            journal = loadedJournal
            journalIdentity = loadedIdentity
        }

        var states = try inspectCheckpointDiscardTargets(journal)
        guard checkpointDiscardStatesAreUnambiguous(states) else {
            return .deferredConflict
        }
        var validationEntries = 0
        for state in states.sorted(by: checkpointDiscardTargetOrder) where
            state.original == .exact && state.quarantine == .absent {
            try moveCanonicalCheckpointDiscardTarget(
                state.target,
                operations: operations,
                validationEntries: &validationEntries
            )
        }

        states = try inspectCheckpointDiscardTargets(journal)
        guard checkpointDiscardStatesAreUnambiguous(states) else {
            return .deferredConflict
        }
        var retirementEntries = 0
        for state in states.sorted(by: checkpointDiscardTargetOrder) where
            state.quarantine == .exact {
            try retireCheckpointDiscardQuarantine(
                state.target,
                operations: operations,
                validationEntries: &validationEntries,
                retirementEntries: &retirementEntries
            )
        }

        states = try inspectCheckpointDiscardTargets(journal)
        guard checkpointDiscardStatesAreUnambiguous(states),
              !states.contains(where: { $0.quarantine == .exact }) else {
            return .deferredConflict
        }
        guard try unlinkCheckpointDiscardJournal(
            expected: journalIdentity,
            operations: operations
        ) else {
            return .deferredConflict
        }
        try verifyNamespace()
        return .completed
    }

    private func checkpointDiscardQuarantineLeaf(
        cleanupID: UUID,
        suffix: String
    ) -> String {
        ".checkpoint-discard-cleanup.\(cleanupID.uuidString).\(suffix)"
    }

    private func captureCheckpointDiscardTarget(
        original: String,
        quarantine: String,
        expectedIdentity: CheckpointDiscardCleanupIdentityDocument?,
        validationEntries: inout Int
    ) throws -> CheckpointDiscardCleanupTargetDocument? {
        guard isSafeLeaf(quarantine) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var quarantineStatus = stat()
        errno = 0
        let quarantineResult = quarantine.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &quarantineStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard quarantineResult != 0, errno == ENOENT else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        guard let (parent, leaf) = try checkpointDiscardSourceParent(
            for: original
        ) else {
            return nil
        }
        defer { Darwin.close(parent) }
        var namedStatus = stat()
        errno = 0
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let identity = try CheckpointDiscardCleanupIdentityDocument(
            validating: namedStatus
        )
        if let expectedIdentity, identity != expectedIdentity {
            throw TrainingArtifactStoreError.invalidManifest
        }
        switch original {
        case "checkpoints/msplat":
            guard identity.nodeType == "directory"
                    || identity.nodeType == "symlink" else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        case "training_manifest.json":
            guard expectedIdentity != nil,
                  identity.nodeType == "regular"
                    || identity.nodeType == "symlink" else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        default:
            throw TrainingArtifactStoreError.invalidManifest
        }

        if identity.nodeType == "directory" {
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            defer { Darwin.close(descriptor) }
            var openedStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                  identity.matches(
                    openedStatus,
                    trainingDevice: trainingIdentity.device
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            try validateCleanupDirectoryContents(
                descriptor: descriptor,
                depth: 0,
                visitedEntries: &validationEntries
            )
        } else if identity.nodeType == "regular" {
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            defer { Darwin.close(descriptor) }
            var openedStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                  identity.matches(
                    openedStatus,
                    trainingDevice: trainingIdentity.device
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
        var reboundStatus = stat()
        guard leaf.withCString({
            Darwin.fstatat(parent, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        identity.matches(
            reboundStatus,
            trainingDevice: trainingIdentity.device
        ) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return CheckpointDiscardCleanupTargetDocument(
            original: original,
            quarantine: quarantine,
            identity: identity
        )
    }

    private func publishCheckpointDiscardJournal(
        _ journal: CheckpointDiscardCleanupJournalDocument,
        operations: TrainingFilesystemOperations
    ) throws {
        try verifyNamespace()
        var existingStatus = stat()
        errno = 0
        let existingResult = Self.checkpointDiscardJournalLeaf.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &existingStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard existingResult != 0, errno == ENOENT else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        let data = try encodedCheckpointDiscardJournal(journal)
        let temporary = ".checkpoint-discard-cleanup.\(journal.cleanupID.uuidString).journal.tmp"
        guard isSafeLeaf(temporary) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let descriptor = temporary.withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(descriptor) }
        var initialTemporaryStatus = stat()
        guard Darwin.fstat(descriptor, &initialTemporaryStatus) == 0,
              (initialTemporaryStatus.st_mode & S_IFMT) == S_IFREG,
              (initialTemporaryStatus.st_mode & mode_t(0o7777)) == mode_t(0o600),
              initialTemporaryStatus.st_uid == geteuid(),
              initialTemporaryStatus.st_nlink == 1 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let temporaryNodeIdentity = TrainingNodeIdentity(initialTemporaryStatus)
        var published = false
        defer {
            if !published {
                var namedStatus = stat()
                if temporary.withCString({
                    Darwin.fstatat(
                        trainingDescriptor,
                        $0,
                        &namedStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0,
                temporaryNodeIdentity.matches(namedStatus),
                (namedStatus.st_mode & S_IFMT) == S_IFREG,
                namedStatus.st_nlink == 1 {
                    _ = temporary.withCString {
                        Darwin.unlinkat(trainingDescriptor, $0, 0)
                    }
                    _ = Darwin.fsync(trainingDescriptor)
                }
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try writeAll(data, to: descriptor)
        guard operations.synchronizeCleanupFile(descriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var stagedStatus = stat()
        guard Darwin.fstat(descriptor, &stagedStatus) == 0,
              (stagedStatus.st_mode & S_IFMT) == S_IFREG,
              (stagedStatus.st_mode & mode_t(0o7777)) == mode_t(0o600),
              stagedStatus.st_uid == geteuid(),
              stagedStatus.st_nlink == 1,
              stagedStatus.st_size == off_t(data.count) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let stagedIdentity = TrainingFileIdentity(stagedStatus)
        try verifyNamespace()
        guard operations.renameCleanupExclusive(
            trainingDescriptor,
            temporary,
            trainingDescriptor,
            Self.checkpointDiscardJournalLeaf
        ) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        published = true
        var canonicalStatus = stat()
        var openedCanonicalStatus = stat()
        var temporaryStatus = stat()
        errno = 0
        let temporaryResult = temporary.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &temporaryStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let temporaryError = errno
        guard Self.checkpointDiscardJournalLeaf.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &canonicalStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        stagedIdentity.matches(canonicalStatus),
        Darwin.fstat(descriptor, &openedCanonicalStatus) == 0,
        stagedIdentity.matches(openedCanonicalStatus),
        temporaryResult != 0,
        temporaryError == ENOENT,
        try readBounded(
            descriptor: descriptor,
            expected: stagedIdentity,
            maximumBytes: Self.maximumCleanupJournalBytes
        ) == data,
        operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try operations.checkpoint(.checkpointDiscardIntentDurable)
    }

    private func loadCheckpointDiscardJournal() throws -> CheckpointDiscardJournalLoad {
        var namedStatus = stat()
        errno = 0
        let result = Self.checkpointDiscardJournalLeaf.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0, errno == ENOENT { return .absent }
        guard result == 0,
              (namedStatus.st_mode & S_IFMT) == S_IFREG,
              (namedStatus.st_mode & mode_t(0o7777)) == mode_t(0o600),
              namedStatus.st_uid == geteuid(),
              namedStatus.st_nlink == 1,
              namedStatus.st_size > 0,
              namedStatus.st_size <= off_t(Self.maximumCleanupJournalBytes),
              namedStatus.st_flags
                & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0 else {
            return .conflict
        }
        let identity = TrainingFileIdentity(namedStatus)
        let descriptor = Self.checkpointDiscardJournalLeaf.withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return .conflict }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              identity.matches(openedStatus) else {
            return .conflict
        }
        let data: Data
        do {
            data = try readBounded(
                descriptor: descriptor,
                expected: identity,
                maximumBytes: Self.maximumCleanupJournalBytes
            )
            try StrictJSONDocument.validate(
                data,
                maximumBytes: Self.maximumCleanupJournalBytes
            )
        } catch {
            return .conflict
        }
        let journal: CheckpointDiscardCleanupJournalDocument
        do {
            journal = try JSONDecoder().decode(
                CheckpointDiscardCleanupJournalDocument.self,
                from: data
            )
            guard try encodedCheckpointDiscardJournal(journal) == data else {
                return .conflict
            }
        } catch {
            return .conflict
        }
        var reboundStatus = stat()
        guard Self.checkpointDiscardJournalLeaf.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &reboundStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        identity.matches(reboundStatus) else {
            return .conflict
        }
        return .valid(journal, identity)
    }

    private func encodedCheckpointDiscardJournal(
        _ journal: CheckpointDiscardCleanupJournalDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(journal)
        guard !data.isEmpty, data.count <= Self.maximumCleanupJournalBytes else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try StrictJSONDocument.validate(
            data,
            maximumBytes: Self.maximumCleanupJournalBytes
        )
        return data
    }

    private func inspectCheckpointDiscardTargets(
        _ journal: CheckpointDiscardCleanupJournalDocument
    ) throws -> [CheckpointDiscardTargetState] {
        try verifyNamespace()
        return try [journal.checkpointTarget, journal.manifestTarget].compactMap {
            target in
            guard let target else { return nil }
            let original = try inspectCheckpointDiscardOriginal(target)
            let quarantine = try inspectCheckpointDiscardEntry(
                parent: trainingDescriptor,
                leaf: target.quarantine,
                expected: target.identity
            )
            return CheckpointDiscardTargetState(
                target: target,
                original: original,
                quarantine: quarantine
            )
        }
    }

    private func inspectCheckpointDiscardOriginal(
        _ target: CheckpointDiscardCleanupTargetDocument
    ) throws -> CleanupEntryState {
        guard let (parent, leaf) = try checkpointDiscardSourceParent(
            for: target.original
        ) else {
            return .absent
        }
        defer { Darwin.close(parent) }
        return try inspectCheckpointDiscardEntry(
            parent: parent,
            leaf: leaf,
            expected: target.identity
        )
    }

    private func inspectCheckpointDiscardEntry(
        parent: Int32,
        leaf: String,
        expected: CheckpointDiscardCleanupIdentityDocument
    ) throws -> CleanupEntryState {
        guard isSafeLeaf(leaf) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var status = stat()
        errno = 0
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0, errno == ENOENT { return .absent }
        guard result == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return expected.matches(status, trainingDevice: trainingIdentity.device)
            ? .exact
            : .different
    }

    private func checkpointDiscardStatesAreUnambiguous(
        _ states: [CheckpointDiscardTargetState]
    ) -> Bool {
        !states.contains { state in
            state.quarantine == .different
                || (state.original == .exact && state.quarantine == .exact)
        }
    }

    private func checkpointDiscardTargetOrder(
        _ lhs: CheckpointDiscardTargetState,
        _ rhs: CheckpointDiscardTargetState
    ) -> Bool {
        let lhsRank = lhs.target.original == "checkpoints/msplat" ? 0 : 1
        let rhsRank = rhs.target.original == "checkpoints/msplat" ? 0 : 1
        return lhsRank < rhsRank
    }

    private func moveCanonicalCheckpointDiscardTarget(
        _ target: CheckpointDiscardCleanupTargetDocument,
        operations: TrainingFilesystemOperations,
        validationEntries: inout Int
    ) throws {
        try verifyNamespace()
        guard let (parent, leaf) = try checkpointDiscardSourceParent(
            for: target.original
        ) else {
            return
        }
        defer { Darwin.close(parent) }

        var heldDescriptor: Int32 = -1
        defer {
            if heldDescriptor >= 0 { Darwin.close(heldDescriptor) }
        }
        switch target.identity.nodeType {
        case "directory":
            heldDescriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard heldDescriptor >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            var opened = stat()
            guard Darwin.fstat(heldDescriptor, &opened) == 0,
                  target.identity.matches(
                    opened,
                    trainingDevice: trainingIdentity.device
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            try validateCleanupDirectoryContents(
                descriptor: heldDescriptor,
                depth: 0,
                visitedEntries: &validationEntries
            )
        case "regular":
            heldDescriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard heldDescriptor >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            var opened = stat()
            guard Darwin.fstat(heldDescriptor, &opened) == 0,
                  target.identity.matches(
                    opened,
                    trainingDevice: trainingIdentity.device
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        case "symlink":
            break
        default:
            throw TrainingArtifactStoreError.invalidManifest
        }

        var named = stat()
        var quarantine = stat()
        errno = 0
        let quarantineResult = target.quarantine.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &quarantine,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard leaf.withCString({
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        target.identity.matches(named, trainingDevice: trainingIdentity.device),
        quarantineResult != 0,
        errno == ENOENT,
        operations.renameCleanupExclusive(
            parent,
            leaf,
            trainingDescriptor,
            target.quarantine
        ) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        if target.original == "checkpoints/msplat" {
            try operations.checkpoint(.checkpointDiscardCheckpointRenamed)
        } else {
            try operations.checkpoint(.checkpointDiscardManifestRenamed)
        }
        if heldDescriptor >= 0 {
            let synchronized: Int32
            if target.identity.nodeType == "directory" {
                synchronized = operations.synchronizeCleanupDirectory(
                    heldDescriptor
                )
            } else {
                synchronized = operations.synchronizeCleanupFile(heldDescriptor)
            }
            guard synchronized == 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
        guard operations.synchronizeCleanupDirectory(parent) == 0,
              operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private func retireCheckpointDiscardQuarantine(
        _ target: CheckpointDiscardCleanupTargetDocument,
        operations: TrainingFilesystemOperations,
        validationEntries: inout Int,
        retirementEntries: inout Int
    ) throws {
        try verifyNamespace()
        let flags: Int32
        switch target.identity.nodeType {
        case "directory":
            let descriptor = target.quarantine.withCString {
                Darwin.openat(
                    trainingDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            var isOpen = true
            defer { if isOpen { Darwin.close(descriptor) } }
            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  target.identity.matches(
                    opened,
                    trainingDevice: trainingIdentity.device
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            try validateCleanupDirectoryContents(
                descriptor: descriptor,
                depth: 0,
                visitedEntries: &validationEntries
            )
            try removeCleanupDirectoryContents(
                descriptor: descriptor,
                relativePath: target.quarantine,
                depth: 0,
                visitedEntries: &retirementEntries,
                operations: operations
            )
            guard operations.synchronizeCleanupDirectory(descriptor) == 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            Darwin.close(descriptor)
            isOpen = false
            flags = AT_REMOVEDIR
        case "regular":
            let descriptor = target.quarantine.withCString {
                Darwin.openat(
                    trainingDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  target.identity.matches(
                    opened,
                    trainingDevice: trainingIdentity.device
                  ) else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            flags = 0
        case "symlink":
            flags = 0
        default:
            throw TrainingArtifactStoreError.invalidManifest
        }

        var rebound = stat()
        guard target.quarantine.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &rebound,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        target.identity.matches(rebound, trainingDevice: trainingIdentity.device),
        operations.unlinkCleanupEntry(
            trainingDescriptor,
            target.quarantine,
            flags
        ) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try operations.checkpoint(
            .checkpointDiscardQuarantineRetired(target.quarantine)
        )
        guard operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private func unlinkCheckpointDiscardJournal(
        expected: TrainingFileIdentity,
        operations: TrainingFilesystemOperations
    ) throws -> Bool {
        try verifyNamespace()
        var status = stat()
        guard Self.checkpointDiscardJournalLeaf.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        expected.matches(status) else {
            return false
        }
        guard operations.unlinkCleanupEntry(
            trainingDescriptor,
            Self.checkpointDiscardJournalLeaf,
            0
        ) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try operations.checkpoint(.checkpointDiscardJournalUnlinked)
        guard operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return true
    }

    private func checkpointDiscardSourceParent(
        for original: String
    ) throws -> (descriptor: Int32, leaf: String)? {
        switch original {
        case "checkpoints/msplat":
            guard let parent = try openDirectory(components: ["checkpoints"]) else {
                return nil
            }
            return (parent, "msplat")
        case "training_manifest.json":
            let duplicate = Darwin.dup(trainingDescriptor)
            guard duplicate >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            return (duplicate, "training_manifest.json")
        default:
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    func discardCompletedArtifact() throws {
        try verifyNamespace()
        var visitedEntries = 0
        try validateDirectoryContents(
            descriptor: trainingDescriptor,
            depth: 0,
            visitedEntries: &visitedEntries
        )
        try verifyNamespace()
        visitedEntries = 0
        try removeDirectoryContents(
            descriptor: trainingDescriptor,
            depth: 0,
            visitedEntries: &visitedEntries
        )
        try synchronize(trainingDescriptor)
        try verifyNamespace()
    }

    func removePreviewPayload(operations: TrainingFilesystemOperations) throws {
        try verifyNamespace()
        guard let msplat = try openDirectory(components: ["msplat"]) else { return }
        defer { Darwin.close(msplat) }
        try unlinkRegularCleanupFileIfPresent(
            parent: msplat,
            leaf: "preview.ply",
            operations: operations
        )

        for name in try directoryNames(descriptor: msplat) {
            let prefix = ".preview.ply.preview.tmp."
            guard name.hasPrefix(prefix), name.hasSuffix(".ply") else { continue }
            let pid = name.dropFirst(prefix.count).dropLast(".ply".count)
            guard !pid.isEmpty,
                  pid.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                continue
            }
            try unlinkRegularCleanupFileIfPresent(
                parent: msplat,
                leaf: name,
                operations: operations
            )
        }
        try verifyNamespace()
    }

    func reconcileDisposableCompletedPayload(
        authorization: CompletedTrainingCleanupAuthorization,
        operations: TrainingFilesystemOperations
    ) throws -> CompletedTrainingCleanupReconciliation {
        try verifyNamespace()
        let loaded = try loadCleanupJournal()
        let journal: CompletedTrainingCleanupJournalDocument
        let journalIdentity: TrainingFileIdentity
        switch loaded {
        case .absent:
            return .noJournal
        case .conflict:
            return .deferredConflict
        case .valid(let document, let identity):
            journal = document
            journalIdentity = identity
        }

        var states = try inspectCleanupTargets(journal)
        guard cleanupStatesAreUnambiguous(states) else {
            return .deferredConflict
        }

        // Quarantines are already unreachable from every canonical trainer path.
        // Their exact journal identity alone authorizes retirement, so startup can
        // finish this portion without hashing the canonical PLY again.
        var validationEntries = 0
        var retirementEntries = 0
        for state in states where state.quarantine == .exact && state.original != .exact {
            try retireCleanupQuarantine(
                state.target,
                operations: operations,
                validationEntries: &validationEntries,
                retirementEntries: &retirementEntries
            )
        }

        states = try inspectCleanupTargets(journal)
        guard cleanupStatesAreUnambiguous(states) else {
            return .deferredConflict
        }
        let exactCanonicalTargets = states.filter {
            $0.original == .exact && $0.quarantine == .absent
        }
        if !exactCanonicalTargets.isEmpty {
            switch authorization {
            case .deferred:
                return .requiresPublishedResult
            case .unavailable:
                break
            case .published(let result):
                let currentGeneration = try validatedCleanupGeneration(result)
                if currentGeneration == journal.generation {
                    for state in exactCanonicalTargets.sorted(by: cleanupTargetOrder) {
                        try moveCanonicalCleanupTarget(
                            state.target,
                            operations: operations,
                            validationEntries: &validationEntries
                        )
                    }
                }
            }
        }

        states = try inspectCleanupTargets(journal)
        guard cleanupStatesAreUnambiguous(states) else {
            return .deferredConflict
        }
        for state in states where state.quarantine == .exact && state.original != .exact {
            try retireCleanupQuarantine(
                state.target,
                operations: operations,
                validationEntries: &validationEntries,
                retirementEntries: &retirementEntries
            )
        }

        states = try inspectCleanupTargets(journal)
        guard cleanupStatesAreUnambiguous(states),
              !states.contains(where: { $0.quarantine == .exact }) else {
            return .deferredConflict
        }
        guard try unlinkCleanupJournal(
            expected: journalIdentity,
            operations: operations
        ) else {
            return .deferredConflict
        }
        try verifyNamespace()
        return .completed
    }

    private func validatedCleanupGeneration(
        _ result: ValidatedPublishedResult
    ) throws -> CompletedTrainingCleanupGenerationDocument {
        let generation = try CompletedTrainingCleanupGenerationDocument(
            validating: result
        )
        guard result.outputURL.standardizedFileURL.path
                == paths.outputSplatURL.standardizedFileURL.path else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        var namedStatus = stat()
        guard "training_manifest.json".withCString({
                  Darwin.fstatat(
                    trainingDescriptor,
                    $0,
                    &namedStatus,
                    AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              (namedStatus.st_mode & S_IFMT) == S_IFREG,
              (namedStatus.st_mode & mode_t(0o7777)) == mode_t(0o600),
              namedStatus.st_uid == geteuid(),
              namedStatus.st_nlink == 1,
              namedStatus.st_size > 0,
              namedStatus.st_size <= off_t(Self.maximumTrainingManifestBytes) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let identity = TrainingFileIdentity(namedStatus)
        let descriptor = "training_manifest.json".withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              identity.matches(openedStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let data = try readBounded(
            descriptor: descriptor,
            expected: identity,
            maximumBytes: Self.maximumTrainingManifestBytes
        )
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        let artifact = try JSONDecoder().decode(TrainingArtifact.self, from: data)
        guard digest == generation.trainingManifestSHA256,
              data == (try TrainingArtifactStore.encodedManifestData(
                artifact,
                projectPaths: paths,
                projectRootDescriptor: projectDescriptor
              )),
              artifact.outputPath == PublishedSplatReceipt.canonicalOutputPath,
              artifact.inputDigest == generation.trainingInputDigest,
              artifact.geometryDigest == generation.trainingGeometryDigest else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try TrainingArtifactStore.validateCompletedOutput(
            artifact,
            evidence: result.outputEvidence
        )
        var reboundStatus = stat()
        guard "training_manifest.json".withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &reboundStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        identity.matches(reboundStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return generation
    }

    private func captureCleanupTarget(
        original: String,
        quarantine: String,
        visitedEntries: inout Int
    ) throws -> CompletedTrainingCleanupTargetDocument? {
        guard isSafeLeaf(quarantine) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var quarantineStatus = stat()
        errno = 0
        let quarantineResult = quarantine.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &quarantineStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard quarantineResult != 0, errno == ENOENT else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        guard let (parent, leaf) = try cleanupSourceParent(for: original) else {
            return nil
        }
        defer { Darwin.close(parent) }
        var namedStatus = stat()
        errno = 0
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0, cleanupDirectoryIsSafe(namedStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let identity = CompletedTrainingCleanupIdentityDocument(namedStatus)
        let directory = leaf.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directory >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(directory) }
        var openedStatus = stat()
        guard Darwin.fstat(directory, &openedStatus) == 0,
              identity.matches(openedStatus, trainingDevice: trainingIdentity.device) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try validateCleanupDirectoryContents(
            descriptor: directory,
            depth: 0,
            visitedEntries: &visitedEntries
        )
        var reboundStatus = stat()
        guard leaf.withCString({
            Darwin.fstatat(parent, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        identity.matches(reboundStatus, trainingDevice: trainingIdentity.device) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return CompletedTrainingCleanupTargetDocument(
            original: original,
            quarantine: quarantine,
            identity: identity
        )
    }

    private func publishCleanupJournal(
        _ journal: CompletedTrainingCleanupJournalDocument,
        operations: TrainingFilesystemOperations
    ) throws {
        try verifyNamespace()
        var existingStatus = stat()
        errno = 0
        let existingResult = Self.cleanupJournalLeaf.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &existingStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard existingResult != 0, errno == ENOENT else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        let data = try encodedCleanupJournal(journal)
        let temporary = ".completed-training-cleanup.\(journal.cleanupID.uuidString).journal.tmp"
        guard isSafeLeaf(temporary) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let descriptor = temporary.withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(descriptor) }
        var initialTemporaryStatus = stat()
        guard Darwin.fstat(descriptor, &initialTemporaryStatus) == 0,
              (initialTemporaryStatus.st_mode & S_IFMT) == S_IFREG,
              (initialTemporaryStatus.st_mode & mode_t(0o7777)) == mode_t(0o600),
              initialTemporaryStatus.st_uid == geteuid(),
              initialTemporaryStatus.st_nlink == 1 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let temporaryNodeIdentity = TrainingNodeIdentity(initialTemporaryStatus)
        var published = false
        defer {
            if !published {
                var namedStatus = stat()
                if temporary.withCString({
                    Darwin.fstatat(
                        trainingDescriptor,
                        $0,
                        &namedStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0,
                temporaryNodeIdentity.matches(namedStatus),
                (namedStatus.st_mode & S_IFMT) == S_IFREG,
                namedStatus.st_nlink == 1 {
                    _ = temporary.withCString {
                        Darwin.unlinkat(trainingDescriptor, $0, 0)
                    }
                    _ = Darwin.fsync(trainingDescriptor)
                }
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try writeAll(data, to: descriptor)
        guard operations.synchronizeCleanupFile(descriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var stagedStatus = stat()
        guard Darwin.fstat(descriptor, &stagedStatus) == 0,
              (stagedStatus.st_mode & S_IFMT) == S_IFREG,
              (stagedStatus.st_mode & mode_t(0o7777)) == mode_t(0o600),
              stagedStatus.st_uid == geteuid(),
              stagedStatus.st_nlink == 1,
              stagedStatus.st_size == off_t(data.count) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let stagedIdentity = TrainingFileIdentity(stagedStatus)
        try verifyNamespace()
        guard operations.renameCleanupExclusive(
            trainingDescriptor,
            temporary,
            trainingDescriptor,
            Self.cleanupJournalLeaf
        ) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        published = true
        var canonicalStatus = stat()
        var openedCanonicalStatus = stat()
        var temporaryStatus = stat()
        errno = 0
        let temporaryResult = temporary.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &temporaryStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let temporaryError = errno
        guard Self.cleanupJournalLeaf.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &canonicalStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        stagedIdentity.matches(canonicalStatus),
        Darwin.fstat(descriptor, &openedCanonicalStatus) == 0,
        stagedIdentity.matches(openedCanonicalStatus),
        temporaryResult != 0,
        temporaryError == ENOENT,
        try readBounded(
            descriptor: descriptor,
            expected: stagedIdentity,
            maximumBytes: Self.maximumCleanupJournalBytes
        ) == data else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        guard operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var durableStatus = stat()
        guard Self.cleanupJournalLeaf.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &durableStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        stagedIdentity.matches(durableStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try operations.checkpoint(.disposableCleanupIntentDurable)
    }

    private func loadCleanupJournal() throws -> CleanupJournalLoad {
        var namedStatus = stat()
        errno = 0
        let result = Self.cleanupJournalLeaf.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0, errno == ENOENT { return .absent }
        guard result == 0,
              (namedStatus.st_mode & S_IFMT) == S_IFREG,
              (namedStatus.st_mode & mode_t(0o7777)) == mode_t(0o600),
              namedStatus.st_uid == geteuid(),
              namedStatus.st_nlink == 1,
              namedStatus.st_size > 0,
              namedStatus.st_size <= off_t(Self.maximumCleanupJournalBytes),
              namedStatus.st_flags
                & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0 else {
            return .conflict
        }
        let identity = TrainingFileIdentity(namedStatus)
        let descriptor = Self.cleanupJournalLeaf.withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return .conflict }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              identity.matches(openedStatus) else {
            return .conflict
        }
        let data: Data
        do {
            data = try readBounded(
                descriptor: descriptor,
                expected: identity,
                maximumBytes: Self.maximumCleanupJournalBytes
            )
            try StrictJSONDocument.validate(
                data,
                maximumBytes: Self.maximumCleanupJournalBytes
            )
        } catch {
            return .conflict
        }
        let journal: CompletedTrainingCleanupJournalDocument
        do {
            journal = try JSONDecoder().decode(
                CompletedTrainingCleanupJournalDocument.self,
                from: data
            )
            guard try encodedCleanupJournal(journal) == data else {
                return .conflict
            }
        } catch {
            return .conflict
        }
        var reboundStatus = stat()
        guard Self.cleanupJournalLeaf.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &reboundStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        identity.matches(reboundStatus) else {
            return .conflict
        }
        return .valid(journal, identity)
    }

    private func encodedCleanupJournal(
        _ journal: CompletedTrainingCleanupJournalDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(journal)
        guard !data.isEmpty, data.count <= Self.maximumCleanupJournalBytes else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try StrictJSONDocument.validate(data, maximumBytes: Self.maximumCleanupJournalBytes)
        return data
    }

    private func inspectCleanupTargets(
        _ journal: CompletedTrainingCleanupJournalDocument
    ) throws -> [CleanupTargetState] {
        try verifyNamespace()
        return try [journal.checkpointTarget, journal.msplatTarget].compactMap { target in
            guard let target else { return nil }
            let original = try inspectCleanupOriginal(target)
            let quarantine = try inspectCleanupQuarantine(target)
            return CleanupTargetState(
                target: target,
                original: original,
                quarantine: quarantine
            )
        }
    }

    private func inspectCleanupOriginal(
        _ target: CompletedTrainingCleanupTargetDocument
    ) throws -> CleanupEntryState {
        guard let (parent, leaf) = try cleanupSourceParent(for: target.original) else {
            return .absent
        }
        defer { Darwin.close(parent) }
        return try inspectCleanupEntry(
            parent: parent,
            leaf: leaf,
            expected: target.identity
        )
    }

    private func inspectCleanupQuarantine(
        _ target: CompletedTrainingCleanupTargetDocument
    ) throws -> CleanupEntryState {
        try inspectCleanupEntry(
            parent: trainingDescriptor,
            leaf: target.quarantine,
            expected: target.identity
        )
    }

    private func inspectCleanupEntry(
        parent: Int32,
        leaf: String,
        expected: CompletedTrainingCleanupIdentityDocument
    ) throws -> CleanupEntryState {
        guard isSafeLeaf(leaf) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var status = stat()
        errno = 0
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0, errno == ENOENT { return .absent }
        guard result == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return expected.matches(status, trainingDevice: trainingIdentity.device)
            ? .exact
            : .different
    }

    private func cleanupStatesAreUnambiguous(_ states: [CleanupTargetState]) -> Bool {
        !states.contains { state in
            state.quarantine == .different
                || (state.original == .exact && state.quarantine == .exact)
        }
    }

    private func cleanupTargetOrder(
        _ lhs: CleanupTargetState,
        _ rhs: CleanupTargetState
    ) -> Bool {
        let lhsRank = lhs.target.original == "checkpoints/msplat" ? 0 : 1
        let rhsRank = rhs.target.original == "checkpoints/msplat" ? 0 : 1
        return lhsRank < rhsRank
    }

    private func moveCanonicalCleanupTarget(
        _ target: CompletedTrainingCleanupTargetDocument,
        operations: TrainingFilesystemOperations,
        validationEntries: inout Int
    ) throws {
        try verifyNamespace()
        guard let (parent, leaf) = try cleanupSourceParent(for: target.original) else {
            return
        }
        defer { Darwin.close(parent) }
        var namedStatus = stat()
        guard leaf.withCString({
            Darwin.fstatat(parent, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        target.identity.matches(namedStatus, trainingDevice: trainingIdentity.device) else {
            return
        }
        let directory = leaf.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directory >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(directory) }
        var openedStatus = stat()
        guard Darwin.fstat(directory, &openedStatus) == 0,
              target.identity.matches(
                openedStatus,
                trainingDevice: trainingIdentity.device
              ) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try validateCleanupDirectoryContents(
            descriptor: directory,
            depth: 0,
            visitedEntries: &validationEntries
        )
        try verifyNamespace()
        var reboundStatus = stat()
        var quarantineStatus = stat()
        errno = 0
        let quarantineResult = target.quarantine.withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &quarantineStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard leaf.withCString({
            Darwin.fstatat(parent, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        target.identity.matches(reboundStatus, trainingDevice: trainingIdentity.device),
        quarantineResult != 0,
        errno == ENOENT else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        guard operations.renameCleanupExclusive(
            parent,
            leaf,
            trainingDescriptor,
            target.quarantine
        ) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        if target.original == "checkpoints/msplat" {
            try operations.checkpoint(.disposableCleanupCheckpointRenamed)
        } else {
            try operations.checkpoint(.disposableCleanupMsplatRenamed)
        }
        guard operations.synchronizeCleanupDirectory(directory) == 0,
              operations.synchronizeCleanupDirectory(parent) == 0,
              operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        if target.original == "checkpoints/msplat" {
            try operations.checkpoint(.disposableCleanupCheckpointDurable)
        } else {
            try operations.checkpoint(.disposableCleanupMsplatDurable)
        }
    }

    private func retireCleanupQuarantine(
        _ target: CompletedTrainingCleanupTargetDocument,
        operations: TrainingFilesystemOperations,
        validationEntries: inout Int,
        retirementEntries: inout Int
    ) throws {
        try verifyNamespace()
        let directory = target.quarantine.withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directory >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var directoryIsOpen = true
        defer {
            if directoryIsOpen { Darwin.close(directory) }
        }
        var openedStatus = stat()
        guard Darwin.fstat(directory, &openedStatus) == 0,
              target.identity.matches(
                openedStatus,
                trainingDevice: trainingIdentity.device
              ) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try validateCleanupDirectoryContents(
            descriptor: directory,
            depth: 0,
            visitedEntries: &validationEntries
        )
        try removeCleanupDirectoryContents(
            descriptor: directory,
            relativePath: target.quarantine,
            depth: 0,
            visitedEntries: &retirementEntries,
            operations: operations
        )
        guard operations.synchronizeCleanupDirectory(directory) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        Darwin.close(directory)
        directoryIsOpen = false
        try verifyNamespace()
        var reboundStatus = stat()
        guard target.quarantine.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &reboundStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        target.identity.matches(reboundStatus, trainingDevice: trainingIdentity.device),
        operations.unlinkCleanupEntry(
            trainingDescriptor,
            target.quarantine,
            AT_REMOVEDIR
        ) == 0,
        operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try operations.checkpoint(
            .disposableCleanupQuarantineRetired(target.quarantine)
        )
    }

    private func validateCleanupDirectoryContents(
        descriptor: Int32,
        depth: Int,
        visitedEntries: inout Int
    ) throws {
        guard depth <= Self.maximumTraversalDepth else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        for name in try directoryNames(descriptor: descriptor) {
            visitedEntries += 1
            guard visitedEntries <= Self.maximumTraversalEntries else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            var namedStatus = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            namedStatus.st_dev == trainingIdentity.device,
            namedStatus.st_uid == geteuid(),
            (namedStatus.st_mode & mode_t(0o022)) == 0,
            namedStatus.st_flags
                & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            switch namedStatus.st_mode & S_IFMT {
            case S_IFDIR:
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                do {
                    var openedStatus = stat()
                    guard Darwin.fstat(child, &openedStatus) == 0,
                          TrainingNodeIdentity(namedStatus).matches(openedStatus) else {
                        throw TrainingArtifactStoreError.invalidManifest
                    }
                    try validateCleanupDirectoryContents(
                        descriptor: child,
                        depth: depth + 1,
                        visitedEntries: &visitedEntries
                    )
                } catch {
                    Darwin.close(child)
                    throw error
                }
                Darwin.close(child)
                var reboundStatus = stat()
                guard name.withCString({
                    Darwin.fstatat(
                        descriptor,
                        $0,
                        &reboundStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0,
                TrainingNodeIdentity(namedStatus).matches(reboundStatus) else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            case S_IFREG:
                guard namedStatus.st_nlink == 1 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                let file = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard file >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                var openedStatus = stat()
                let isStable = Darwin.fstat(file, &openedStatus) == 0
                    && TrainingFileIdentity(namedStatus).matches(openedStatus)
                Darwin.close(file)
                guard isStable else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            default:
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
    }

    private func removeCleanupDirectoryContents(
        descriptor: Int32,
        relativePath: String,
        depth: Int,
        visitedEntries: inout Int,
        operations: TrainingFilesystemOperations
    ) throws {
        guard depth <= Self.maximumTraversalDepth else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        for name in try directoryNames(descriptor: descriptor) {
            visitedEntries += 1
            guard visitedEntries <= Self.maximumTraversalEntries else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            let childPath = relativePath + "/" + name
            var namedStatus = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            namedStatus.st_dev == trainingIdentity.device,
            namedStatus.st_uid == geteuid(),
            namedStatus.st_flags
                & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            switch namedStatus.st_mode & S_IFMT {
            case S_IFDIR:
                guard (namedStatus.st_mode & mode_t(0o022)) == 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                let expected = TrainingNodeIdentity(namedStatus)
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                var childIsOpen = true
                defer {
                    if childIsOpen { Darwin.close(child) }
                }
                var openedStatus = stat()
                guard Darwin.fstat(child, &openedStatus) == 0,
                      expected.matches(openedStatus) else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                try removeCleanupDirectoryContents(
                    descriptor: child,
                    relativePath: childPath,
                    depth: depth + 1,
                    visitedEntries: &visitedEntries,
                    operations: operations
                )
                guard operations.synchronizeCleanupDirectory(child) == 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                Darwin.close(child)
                childIsOpen = false
                var reboundStatus = stat()
                guard name.withCString({
                    Darwin.fstatat(
                        descriptor,
                        $0,
                        &reboundStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0,
                expected.matches(reboundStatus) else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                try operations.checkpoint(
                    .disposableCleanupWillRetireEntry(childPath)
                )
                guard operations.unlinkCleanupEntry(descriptor, name, AT_REMOVEDIR) == 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            case S_IFREG:
                guard (namedStatus.st_mode & mode_t(0o022)) == 0,
                      namedStatus.st_nlink == 1 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                let expected = TrainingFileIdentity(namedStatus)
                let file = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard file >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                var openedStatus = stat()
                let isStable = Darwin.fstat(file, &openedStatus) == 0
                    && expected.matches(openedStatus)
                Darwin.close(file)
                var reboundStatus = stat()
                guard isStable,
                      name.withCString({
                        Darwin.fstatat(
                            descriptor,
                            $0,
                            &reboundStatus,
                            AT_SYMLINK_NOFOLLOW
                        )
                      }) == 0,
                      expected.matches(reboundStatus) else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                try operations.checkpoint(
                    .disposableCleanupWillRetireEntry(childPath)
                )
                guard operations.unlinkCleanupEntry(descriptor, name, 0) == 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            default:
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
        guard operations.synchronizeCleanupDirectory(descriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private func unlinkCleanupJournal(
        expected: TrainingFileIdentity,
        operations: TrainingFilesystemOperations
    ) throws -> Bool {
        try verifyNamespace()
        var status = stat()
        guard Self.cleanupJournalLeaf.withCString({
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        expected.matches(status) else {
            return false
        }
        guard operations.unlinkCleanupEntry(
            trainingDescriptor,
            Self.cleanupJournalLeaf,
            0
        ) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try operations.checkpoint(.disposableCleanupJournalUnlinked)
        guard operations.synchronizeCleanupDirectory(trainingDescriptor) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return true
    }

    private func unlinkRegularCleanupFileIfPresent(
        parent: Int32,
        leaf: String,
        operations: TrainingFilesystemOperations
    ) throws {
        guard isSafeLeaf(leaf) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var namedStatus = stat()
        errno = 0
        let result = leaf.withCString {
            Darwin.fstatat(parent, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0, errno == ENOENT { return }
        guard result == 0,
              (namedStatus.st_mode & S_IFMT) == S_IFREG,
              namedStatus.st_dev == trainingIdentity.device,
              namedStatus.st_uid == geteuid(),
              namedStatus.st_nlink == 1 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let identity = TrainingFileIdentity(namedStatus)
        let descriptor = leaf.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var openedStatus = stat()
        let stable = Darwin.fstat(descriptor, &openedStatus) == 0
            && identity.matches(openedStatus)
        Darwin.close(descriptor)
        var reboundStatus = stat()
        guard stable,
              leaf.withCString({
                Darwin.fstatat(parent, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              identity.matches(reboundStatus),
              operations.unlinkCleanupEntry(parent, leaf, 0) == 0,
              operations.synchronizeCleanupDirectory(parent) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private func cleanupSourceParent(
        for original: String
    ) throws -> (descriptor: Int32, leaf: String)? {
        switch original {
        case "checkpoints/msplat":
            guard let parent = try openDirectory(components: ["checkpoints"]) else {
                return nil
            }
            return (parent, "msplat")
        case "msplat":
            let duplicate = Darwin.dup(trainingDescriptor)
            guard duplicate >= 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            return (duplicate, "msplat")
        default:
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private func cleanupDirectoryIsSafe(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_dev == trainingIdentity.device
            && status.st_uid == geteuid()
            && (status.st_mode & mode_t(0o022)) == 0
            && status.st_flags
                & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0
    }

    private func cleanupQuarantineLeaf(cleanupID: UUID, suffix: String) -> String {
        ".completed-training-cleanup.\(cleanupID.uuidString).\(suffix)"
    }

    private func validateDirectoryContents(
        descriptor: Int32,
        depth: Int,
        visitedEntries: inout Int
    ) throws {
        guard depth <= Self.maximumTraversalDepth else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        for name in try directoryNames(descriptor: descriptor) {
            visitedEntries += 1
            guard visitedEntries <= Self.maximumTraversalEntries,
                  !name.hasPrefix(".training-cleanup.") else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            var namedStatus = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            namedStatus.st_uid == geteuid() else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            switch namedStatus.st_mode & S_IFMT {
            case S_IFDIR:
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                do {
                    var openedStatus = stat()
                    guard Darwin.fstat(child, &openedStatus) == 0,
                          TrainingNodeIdentity(namedStatus).matches(openedStatus) else {
                        throw TrainingArtifactStoreError.invalidManifest
                    }
                    try validateDirectoryContents(
                        descriptor: child,
                        depth: depth + 1,
                        visitedEntries: &visitedEntries
                    )
                    var finalStatus = stat()
                    guard Darwin.fstat(child, &finalStatus) == 0,
                          TrainingNodeIdentity(namedStatus).matches(finalStatus) else {
                        throw TrainingArtifactStoreError.invalidManifest
                    }
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                var reboundStatus = stat()
                guard name.withCString({
                    Darwin.fstatat(descriptor, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                TrainingNodeIdentity(namedStatus).matches(reboundStatus) else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            case S_IFREG:
                guard namedStatus.st_nlink == 1 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                let file = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard file >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                var openedStatus = stat()
                let isStable = Darwin.fstat(file, &openedStatus) == 0
                    && TrainingFileIdentity(namedStatus).matches(openedStatus)
                Darwin.close(file)
                guard isStable else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            default:
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
    }

    private func removeDirectoryContents(
        descriptor: Int32,
        depth: Int,
        visitedEntries: inout Int
    ) throws {
        guard depth <= Self.maximumTraversalDepth else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        for name in try directoryNames(descriptor: descriptor) {
            visitedEntries += 1
            guard visitedEntries <= Self.maximumTraversalEntries else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            var namedStatus = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            if (namedStatus.st_mode & S_IFMT) == S_IFDIR {
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                do {
                    var openedStatus = stat()
                    guard Darwin.fstat(child, &openedStatus) == 0,
                          TrainingNodeIdentity(namedStatus).matches(openedStatus) else {
                        throw TrainingArtifactStoreError.invalidManifest
                    }
                    try removeDirectoryContents(
                        descriptor: child,
                        depth: depth + 1,
                        visitedEntries: &visitedEntries
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                var reboundStatus = stat()
                guard name.withCString({
                    Darwin.fstatat(descriptor, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                TrainingNodeIdentity(namedStatus).matches(reboundStatus),
                name.withCString({ Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            } else {
                guard (namedStatus.st_mode & S_IFMT) == S_IFREG,
                      namedStatus.st_uid == geteuid(),
                      namedStatus.st_nlink == 1 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                let file = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard file >= 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                var openedStatus = stat()
                let isStable = Darwin.fstat(file, &openedStatus) == 0
                    && TrainingFileIdentity(namedStatus).matches(openedStatus)
                Darwin.close(file)
                guard isStable,
                      name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
            }
        }
    }

    private func checkpointManifestDisposition(
        maximumBytes: Int
    ) throws -> CheckpointManifestDisposition {
        var namedStatus = stat()
        let result = "training_manifest.json".withCString {
            Darwin.fstatat(
                trainingDescriptor,
                $0,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0, errno == ENOENT {
            return .absent
        }
        guard result == 0,
              namedStatus.st_uid == geteuid() else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        if (namedStatus.st_mode & S_IFMT) == S_IFLNK {
            return .symbolicLink(
                try CheckpointDiscardCleanupIdentityDocument(
                    validating: namedStatus
                )
            )
        }
        guard (namedStatus.st_mode & S_IFMT) == S_IFREG,
              namedStatus.st_nlink == 1,
              namedStatus.st_size > 0,
              namedStatus.st_size <= off_t(maximumBytes) else {
            return .preserve
        }

        let descriptor = "training_manifest.json".withCString {
            Darwin.openat(
                trainingDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let identity = TrainingFileIdentity(openedStatus)
        guard TrainingFileIdentity(namedStatus) == identity else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let data = try readBounded(
            descriptor: descriptor,
            expected: identity,
            maximumBytes: maximumBytes
        )
        guard let artifact = try? JSONDecoder().decode(TrainingArtifact.self, from: data),
              (try? TrainingArtifactStore.validateManifest(
                  artifact,
                  projectPaths: paths
              )) != nil,
              artifact.completionStatus == .checkpointed else {
            return .preserve
        }
        return .regular(
            try CheckpointDiscardCleanupIdentityDocument(
                validating: openedStatus
            )
        )
    }

    private func openDirectory(components: [String]) throws -> Int32? {
        var current = Darwin.dup(trainingDescriptor)
        guard current >= 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        if components.isEmpty { return current }

        for component in components {
            guard isSafeLeaf(component) else {
                Darwin.close(current)
                throw TrainingArtifactStoreError.invalidManifest
            }
            var namedStatus = stat()
            let namedResult = component.withCString {
                Darwin.fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }
            if namedResult != 0, errno == ENOENT {
                Darwin.close(current)
                return nil
            }
            guard namedResult == 0,
                  (namedStatus.st_mode & S_IFMT) == S_IFDIR,
                  namedStatus.st_uid == geteuid() else {
                Darwin.close(current)
                throw TrainingArtifactStoreError.invalidManifest
            }
            let child = component.withCString {
                Darwin.openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard child >= 0 else {
                Darwin.close(current)
                throw TrainingArtifactStoreError.invalidManifest
            }
            var openedStatus = stat()
            guard Darwin.fstat(child, &openedStatus) == 0,
                  TrainingNodeIdentity(namedStatus).matches(openedStatus) else {
                Darwin.close(child)
                Darwin.close(current)
                throw TrainingArtifactStoreError.invalidManifest
            }
            Darwin.close(current)
            current = child
        }
        return current
    }

    private func directoryNames(descriptor: Int32) throws -> [String] {
        let duplicate = ".".withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw TrainingArtifactStoreError.invalidManifest
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                guard names.count < Self.maximumTraversalEntries else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return names.sorted()
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0, count <= bytes.count - offset else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                offset += count
            }
        }
    }

    private func readBounded(
        descriptor: Int32,
        expected: TrainingFileIdentity,
        maximumBytes: Int
    ) throws -> Data {
        guard expected.size > 0,
              expected.size <= off_t(maximumBytes) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var data = Data(count: Int(expected.size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0, count <= data.count - offset else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            offset += count
        }
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              expected.matches(finalStatus) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return data
    }

    private func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private func isSafeLeaf(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum TrainingArtifactStore {
    private static let maximumBytes = 1_048_576

    private struct DescriptorBoundPublicationLineage: Equatable {
        let geometryArtifact: GeometryArtifact
        let geometryManifestSHA256: String
    }

    public static func load(from url: URL, projectPaths: ProjectPaths) throws -> TrainingArtifact {
        let artifact = try loadManifest(from: url, projectPaths: projectPaths)
        try validateArtifact(artifact, projectPaths: projectPaths)
        guard try loadManifest(from: url, projectPaths: projectPaths) == artifact else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return artifact
    }

    static func loadManifest(
        from url: URL,
        projectPaths: ProjectPaths
    ) throws -> TrainingArtifact {
        try validateManifestLocation(url, projectPaths: projectPaths)
        let data = try BoundedFileReader.readRegularFile(at: url, maximumBytes: maximumBytes)
        guard !data.isEmpty else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let artifact = try JSONDecoder().decode(
            TrainingArtifact.self,
            from: data
        )
        try validateManifest(artifact, projectPaths: projectPaths)
        let stableData = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumBytes
        )
        guard stableData == data else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return artifact
    }

    public static func save(
        _ artifact: TrainingArtifact,
        to url: URL,
        projectPaths: ProjectPaths
    ) throws {
        try save(
            artifact,
            to: url,
            projectPaths: projectPaths,
            operations: .live
        )
    }

    package static func save(
        _ artifact: TrainingArtifact,
        to url: URL,
        projectPaths: ProjectPaths,
        operations: TrainingFilesystemOperations
    ) throws {
        try validateManifestLocation(url, projectPaths: projectPaths)
        try validateArtifact(artifact, projectPaths: projectPaths)
        let data = try encodedManifestData(artifact, projectPaths: projectPaths)
        let filesystem = try BoundTrainingFilesystem(paths: projectPaths)
        try operations.checkpoint(.manifestDirectoryBound)
        let persistedData = try filesystem.replaceManifest(
            with: data,
            maximumBytes: maximumBytes
        )
        guard persistedData == data else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    public static func persist(
        _ artifact: TrainingArtifact,
        paths: ProjectPaths
    ) throws {
        try persist(artifact, paths: paths, operations: .live)
    }

    package static func persist(
        _ artifact: TrainingArtifact,
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations
    ) throws {
        try save(
            artifact,
            to: paths.trainingManifestURL,
            projectPaths: paths,
            operations: operations
        )
        guard try load(from: paths.trainingManifestURL, projectPaths: paths) == artifact else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    /// Returns the exact deterministic bytes that `persist` would write without
    /// requiring the artifact's rebound output to exist yet. Publication uses
    /// these bytes to bind the receipt before either canonical file is replaced.
    package static func encodedManifestData(
        _ artifact: TrainingArtifact,
        projectPaths: ProjectPaths
    ) throws -> Data {
        try validateManifest(artifact, projectPaths: projectPaths)
        return try encodeManifestData(artifact)
    }

    /// Encodes a manifest against the project tree held by the caller rather
    /// than reopening `projectPaths.root`. Publication uses this overload after
    /// its run lease has bound the exact project inode, so a copied replacement
    /// bundle cannot influence path validation or the resulting receipt bytes.
    package static func encodedManifestData(
        _ artifact: TrainingArtifact,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32
    ) throws -> Data {
        let filesystem = try BoundTrainingFilesystem(
            paths: projectPaths,
            projectRootDescriptor: projectRootDescriptor
        )
        return try encodedManifestData(
            artifact,
            filesystem: filesystem
        )
    }

    package static func validateManifest(
        _ artifact: TrainingArtifact,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32
    ) throws {
        let filesystem = try BoundTrainingFilesystem(
            paths: projectPaths,
            projectRootDescriptor: projectRootDescriptor
        )
        try validateManifest(
            artifact,
            filesystem: filesystem
        )
    }

    private static func encodedManifestData(
        _ artifact: TrainingArtifact,
        filesystem: BoundTrainingFilesystem
    ) throws -> Data {
        try validateManifest(artifact, filesystem: filesystem)
        let data = try encodeManifestData(artifact)
        try filesystem.verifyNamespace()
        return data
    }

    private static func validateManifest(
        _ artifact: TrainingArtifact,
        filesystem: BoundTrainingFilesystem
    ) throws {
        try filesystem.verifyNamespace()
        try validateManifest(
            artifact,
            validateProjectRelativePath: validateDescriptorBoundRelativePath
        )
        try filesystem.verifyNamespace()
    }

    private static func encodeManifestData(
        _ artifact: TrainingArtifact
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        return data
    }

    /// Persists bytes that were prepared before canonical publication and proves
    /// that no re-encoding drift occurred between receipt creation and commit.
    package static func persistPreparedManifest(
        _ data: Data,
        artifact: TrainingArtifact,
        paths: ProjectPaths
    ) throws {
        let outputURL = try paths.resolveProjectRelativePath(
            artifact.outputPath ?? ""
        )
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: outputURL
        )
        try persistPreparedManifest(
            data,
            artifact: artifact,
            validatedOutputEvidence: evidence,
            paths: paths
        )
    }

    /// Persists a rebound manifest while the published-result lock still binds
    /// the canonical PLY to this already-authenticated evidence. This avoids
    /// reopening and hashing the same large output during the commit boundary.
    package static func persistPreparedManifest(
        _ data: Data,
        artifact: TrainingArtifact,
        validatedOutputEvidence: ValidatedPlyArtifactEvidence,
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        var sourceStatus = stat()
        guard Darwin.lstat(paths.trainingManifestURL.path, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFREG,
              (sourceStatus.st_mode & 0o7777) == mode_t(0o600),
              sourceStatus.st_uid == geteuid(),
              sourceStatus.st_nlink == 1,
              sourceStatus.st_size > 0,
              sourceStatus.st_size <= off_t(maximumBytes) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try persistPreparedManifest(
            data,
            artifact: artifact,
            validatedOutputEvidence: validatedOutputEvidence,
            expectedSourceIdentity: PreparedTrainingManifestSourceIdentity(sourceStatus),
            paths: paths,
            operations: operations
        )
    }

    /// Persists a rebound manifest only if the canonical source remains the
    /// exact file authenticated by the caller before its publication boundary.
    package static func persistPreparedManifest(
        _ data: Data,
        artifact: TrainingArtifact,
        validatedOutputEvidence: ValidatedPlyArtifactEvidence,
        expectedSourceIdentity: PreparedTrainingManifestSourceIdentity,
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        try validateManifestLocation(paths.trainingManifestURL, projectPaths: paths)
        try validateManifest(artifact, projectPaths: paths)
        try validateCompletedOutput(
            artifact,
            evidence: validatedOutputEvidence
        )
        guard artifact.outputPath == "Output/splat.ply",
              data == (try encodedManifestData(artifact, projectPaths: paths)) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var completedSource = artifact
        completedSource.outputPath = "Training/msplat/splat.ply"
        let completedSourceData = try encodedManifestData(
            completedSource,
            projectPaths: paths
        )
        let lineage = try MsplatPublicationLineageSnapshot.capture(
            matching: artifact,
            paths: paths
        )
        let filesystem = try BoundTrainingFilesystem(paths: paths)
        let persistedData = try filesystem.compareAndSwapManifest(
            expectingSourceIdentity: expectedSourceIdentity,
            expecting: [completedSourceData, data],
            with: data,
            maximumBytes: maximumBytes,
            validateBeforeSwap: {
                try operations.checkpoint(.preparedManifestDirectoryBound)
                try lineage.revalidate(matching: artifact, paths: paths)
            },
            willInstall: {
                try operations.checkpoint(.preparedManifestReadyToInstall)
            },
            validateAfterSwap: {
                try operations.checkpoint(.preparedManifestInstalled)
                try lineage.revalidate(matching: artifact, paths: paths)
            }
        )
        guard persistedData == data else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let persistedArtifact = try JSONDecoder().decode(
            TrainingArtifact.self,
            from: persistedData
        )
        try validateManifest(persistedArtifact, projectPaths: paths)
        guard persistedArtifact == artifact else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    package static func persistPreparedManifest(
        _ data: Data,
        artifact: TrainingArtifact,
        validatedOutputEvidence: ValidatedPlyArtifactEvidence,
        expectedSourceIdentity: PreparedTrainingManifestSourceIdentity,
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        guard paths.trainingManifestURL.path == paths.root.appendingPathComponent(
            "Training/training_manifest.json"
        ).path else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let filesystem = try BoundTrainingFilesystem(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        try validateManifest(artifact, filesystem: filesystem)
        try validateCompletedOutput(
            artifact,
            evidence: validatedOutputEvidence
        )
        guard artifact.outputPath == "Output/splat.ply",
              data == (try encodedManifestData(
                  artifact,
                  filesystem: filesystem
              )) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        var completedSource = artifact
        completedSource.outputPath = "Training/msplat/splat.ply"
        let completedSourceData = try encodedManifestData(
            completedSource,
            filesystem: filesystem
        )
        let lineage = try descriptorBoundPublicationLineage(
            matching: artifact,
            filesystem: filesystem
        )
        let persistedData = try filesystem.compareAndSwapManifest(
            expectingSourceIdentity: expectedSourceIdentity,
            expecting: [completedSourceData, data],
            with: data,
            maximumBytes: maximumBytes,
            validateBeforeSwap: {
                try operations.checkpoint(.preparedManifestDirectoryBound)
                guard try descriptorBoundPublicationLineage(
                    matching: artifact,
                    filesystem: filesystem
                ) == lineage else {
                    throw GeometryArtifactStore.Error.artifactDigestMismatch(
                        "training publication lineage"
                    )
                }
            },
            willInstall: {
                try operations.checkpoint(.preparedManifestReadyToInstall)
            },
            validateAfterSwap: {
                try operations.checkpoint(.preparedManifestInstalled)
                guard try descriptorBoundPublicationLineage(
                    matching: artifact,
                    filesystem: filesystem
                ) == lineage else {
                    throw GeometryArtifactStore.Error.artifactDigestMismatch(
                        "training publication lineage"
                    )
                }
            }
        )
        guard persistedData == data else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let persistedArtifact = try JSONDecoder().decode(
            TrainingArtifact.self,
            from: persistedData
        )
        try validateManifest(persistedArtifact, filesystem: filesystem)
        guard persistedArtifact == artifact else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private static func descriptorBoundPublicationLineage(
        matching training: TrainingArtifact,
        filesystem: BoundTrainingFilesystem
    ) throws -> DescriptorBoundPublicationLineage {
        let data = try filesystem.readBoundGeometryManifestData(
            maximumBytes: GeometryArtifactStore.maximumManifestBytes
        )
        let geometry = try JSONDecoder().decode(GeometryArtifact.self, from: data)
        guard geometry.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw GeometryArtifactStore.Error.invalidSchema(geometry.schemaVersion)
        }
        try validateDescriptorBoundRelativePath(geometry.sourceModelPath)
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        let derivation = training.datasetDerivation
        guard training.completionStatus == .completed,
              derivation.sourceGeometryManifestSHA256 == digest,
              derivation.sourceSelectedFramesDigest
                == geometry.selectedFramesDigest else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch(
                "training publication lineage"
            )
        }
        return DescriptorBoundPublicationLineage(
            geometryArtifact: geometry,
            geometryManifestSHA256: digest
        )
    }

    package static func removeDisposableCompletedPayload(
        paths: ProjectPaths,
        publishedResult: ValidatedPublishedResult,
        operations: TrainingFilesystemOperations = .live,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws {
        let filesystem = try BoundTrainingFilesystem(paths: paths)
        try operations.checkpoint(.disposableCleanupDirectoryBound)
        try filesystem.removeDisposableCompletedPayload(
            publishedResult: publishedResult,
            operations: operations,
            shouldCancel: shouldCancel
        )
    }

    package static func removeDisposableCompletedPayload(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        publishedResult: ValidatedPublishedResult,
        operations: TrainingFilesystemOperations = .live,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws {
        let filesystem = try BoundTrainingFilesystem(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        try operations.checkpoint(.disposableCleanupDirectoryBound)
        try filesystem.removeDisposableCompletedPayload(
            publishedResult: publishedResult,
            operations: operations,
            shouldCancel: shouldCancel
        )
    }

    package static func reconcileDisposableCompletedPayload(
        paths: ProjectPaths,
        authorization: CompletedTrainingCleanupAuthorization,
        operations: TrainingFilesystemOperations = .live
    ) throws -> CompletedTrainingCleanupReconciliation {
        var status = stat()
        while Darwin.lstat(paths.trainingURL.path, &status) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return .noTraining }
            throw TrainingArtifactStoreError.invalidManifest
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let filesystem = try BoundTrainingFilesystem(paths: paths)
        try operations.checkpoint(.disposableCleanupDirectoryBound)
        return try filesystem.reconcileDisposableCompletedPayload(
            authorization: authorization,
            operations: operations
        )
    }

    package static func reconcileDisposableCompletedPayload(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        authorization: CompletedTrainingCleanupAuthorization,
        operations: TrainingFilesystemOperations = .live
    ) throws -> CompletedTrainingCleanupReconciliation {
        var status = stat()
        errno = 0
        let result = "Training".withCString {
            Darwin.fstatat(
                projectRootDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0, errno == ENOENT { return .noTraining }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let filesystem = try BoundTrainingFilesystem(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        try operations.checkpoint(.disposableCleanupDirectoryBound)
        return try filesystem.reconcileDisposableCompletedPayload(
            authorization: authorization,
            operations: operations
        )
    }

    package static func reconcileCheckpointDiscardForPipelineStartup(
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations = .live
    ) throws -> CompletedTrainingCleanupReconciliation {
        var status = stat()
        while Darwin.lstat(paths.trainingURL.path, &status) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return .noTraining }
            throw TrainingArtifactStoreError.invalidManifest
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let filesystem = try BoundTrainingFilesystem(paths: paths)
        try operations.checkpoint(.checkpointDiscardDirectoryBound)
        return try filesystem.reconcileCheckpointDiscard(
            operations: operations
        )
    }

    package static func reconcileCheckpointDiscardForPipelineStartup(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        operations: TrainingFilesystemOperations = .live
    ) throws -> CompletedTrainingCleanupReconciliation {
        var status = stat()
        errno = 0
        let result = "Training".withCString {
            Darwin.fstatat(
                projectRootDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0, errno == ENOENT { return .noTraining }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let filesystem = try BoundTrainingFilesystem(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        try operations.checkpoint(.checkpointDiscardDirectoryBound)
        return try filesystem.reconcileCheckpointDiscard(
            operations: operations
        )
    }

    /// Reconciles a completed-training cleanup intent before a pipeline run may
    /// mutate metadata or any canonical Training path. Publication-dependent
    /// canonical renames remain inside the published-pair lock.
    package static func reconcileDisposableCompletedPayloadForPipelineStartup(
        paths: ProjectPaths,
        publishedResultOperations: PublishedResultPairOperations,
        trainingOperations: TrainingFilesystemOperations,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> CompletedTrainingCleanupReconciliation {
        if shouldCancel() { throw CancellationError() }
        let checkpointDiscard = try reconcileCheckpointDiscardForPipelineStartup(
            paths: paths,
            operations: trainingOperations
        )
        guard checkpointDiscard != .deferredConflict,
              checkpointDiscard != .noTraining else {
            return checkpointDiscard
        }
        let initial: CompletedTrainingCleanupReconciliation = try
            reconcileDisposableCompletedPayload(
                paths: paths,
                authorization: .deferred,
                operations: trainingOperations
            )
        guard initial == .requiresPublishedResult else { return initial }

        let lockedResult = CompletedTrainingCleanupReconciliationBox(initial)
        let resolved: ValidatedPublishedResult? = try PublishedResultPairStore
            .commitResolvedResultIf(
                projectPaths: paths,
                operations: publishedResultOperations,
                shouldCancel: shouldCancel,
                matches: { (_: ValidatedPublishedResult) throws -> Bool in true },
                afterCommit: { (result: ValidatedPublishedResult) throws -> Void in
                    lockedResult.value = try reconcileDisposableCompletedPayload(
                        paths: paths,
                        authorization: .published(result),
                        operations: trainingOperations
                    )
                }
            )
        guard resolved == nil else { return lockedResult.value }
        return try reconcileDisposableCompletedPayload(
            paths: paths,
            authorization: .unavailable,
            operations: trainingOperations
        )
    }

    package static func reconcileDisposableCompletedPayloadForPipelineStartup(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        publishedResultOperations: PublishedResultPairOperations,
        trainingOperations: TrainingFilesystemOperations,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> CompletedTrainingCleanupReconciliation {
        if shouldCancel() { throw CancellationError() }
        let checkpointDiscard = try reconcileCheckpointDiscardForPipelineStartup(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            operations: trainingOperations
        )
        guard checkpointDiscard != .deferredConflict,
              checkpointDiscard != .noTraining else {
            return checkpointDiscard
        }
        let initial: CompletedTrainingCleanupReconciliation = try
            reconcileDisposableCompletedPayload(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor,
                authorization: .deferred,
                operations: trainingOperations
            )
        guard initial == .requiresPublishedResult else { return initial }

        let lockedResult = CompletedTrainingCleanupReconciliationBox(initial)
        let resolved: ValidatedPublishedResult? = try PublishedResultPairStore
            .commitResolvedResultIf(
                projectPaths: paths,
                projectRootDescriptor: projectRootDescriptor,
                operations: publishedResultOperations,
                shouldCancel: shouldCancel,
                matches: { (_: ValidatedPublishedResult) throws -> Bool in true },
                afterCommit: { (result: ValidatedPublishedResult) throws -> Void in
                    lockedResult.value = try reconcileDisposableCompletedPayload(
                        paths: paths,
                        projectRootDescriptor: projectRootDescriptor,
                        authorization: .published(result),
                        operations: trainingOperations
                    )
                }
            )
        guard resolved == nil else { return lockedResult.value }
        return try reconcileDisposableCompletedPayload(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            authorization: .unavailable,
            operations: trainingOperations
        )
    }

    package static func removePreviewPayload(
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        let filesystem = try BoundTrainingFilesystem(paths: paths)
        try operations.checkpoint(.previewCleanupDirectoryBound)
        try filesystem.removePreviewPayload(operations: operations)
    }

    public static func discardCheckpointedArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        try discardCheckpointedArtifact(
            metadata: &metadata,
            paths: paths,
            operations: .live
        )
    }

    package static func discardCheckpointedArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations
    ) throws {
        try discardCheckpointedPayload(
            paths: paths,
            operations: operations
        )
        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
    }

    package static func discardCheckpointedPayload(
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        let filesystem = try BoundTrainingFilesystem(paths: paths)
        try operations.checkpoint(.checkpointDiscardDirectoryBound)
        try filesystem.discardCheckpointedArtifact(
            maximumManifestBytes: maximumBytes,
            operations: operations
        )
    }

    package static func discardCheckpointedPayload(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        let filesystem = try BoundTrainingFilesystem(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        try operations.checkpoint(.checkpointDiscardDirectoryBound)
        try filesystem.discardCheckpointedArtifact(
            maximumManifestBytes: maximumBytes,
            operations: operations
        )
    }

    public static func discardCompletedArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        try discardCompletedArtifact(
            metadata: &metadata,
            paths: paths,
            operations: .live
        )
    }

    package static func discardCompletedArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations
    ) throws {
        try discardCompletedPayload(
            paths: paths,
            operations: operations
        )
        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
    }

    package static func discardCompletedPayload(
        paths: ProjectPaths,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        let filesystem = try BoundTrainingFilesystem(paths: paths)
        try operations.checkpoint(.completedDiscardDirectoryBound)
        try filesystem.discardCompletedArtifact()
    }

    package static func discardCompletedPayload(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        operations: TrainingFilesystemOperations = .live
    ) throws {
        let filesystem = try BoundTrainingFilesystem(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        try operations.checkpoint(.completedDiscardDirectoryBound)
        try filesystem.discardCompletedArtifact()
    }

    static func validateArtifact(
        _ artifact: TrainingArtifact,
        projectPaths: ProjectPaths
    ) throws {
        try validateManifest(artifact, projectPaths: projectPaths)
        if artifact.completionStatus == .completed, let path = artifact.outputPath {
            try validateOutputBinding(
                artifact,
                outputURL: projectPaths.resolveProjectRelativePath(path)
            )
        }
    }

    static func validateManifest(
        _ artifact: TrainingArtifact,
        projectPaths: ProjectPaths
    ) throws {
        try validateManifest(artifact) { path in
            _ = try projectPaths.resolveProjectRelativePath(path)
        }
    }

    private static func validateManifest(
        _ artifact: TrainingArtifact,
        validateProjectRelativePath: (String) throws -> Void
    ) throws {
        let sanctionedBudgets = RunPlanResolver.sanctionedTrainerBudgets(
            for: artifact.detailProfile
        )
        let derivation = artifact.datasetDerivation
        guard artifact.schemaVersion == TrainingArtifact.currentSchemaVersion,
              !artifact.trainerVersion.isEmpty,
              !artifact.runtimeVersion.isEmpty,
              isSHA256(artifact.trainerBuildDigest),
              isSHA256(artifact.inputDigest),
              isSHA256(artifact.geometryDigest),
              derivation.schemaVersion == MsplatDatasetDerivationArtifact.currentSchemaVersion,
              isSHA256(derivation.sourceGeometryManifestSHA256),
              isSHA256(derivation.sourceSelectedFramesDigest),
              derivation.maximumImageDimension > 0,
              !derivation.toolchainVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              // The dataset was prepared from either a COLMAP solve or a directly
              // adopted external model; both pin a solver provenance here.
              ["colmap", "imported"].contains(derivation.colmapProvenance.identifier),
              !derivation.colmapProvenance.version
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !derivation.colmapProvenance.revision
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isSHA256(derivation.colmapProvenance.payloadSHA256),
              !derivation.registeredImageNames.isEmpty,
              Set(derivation.registeredImageNames).count
                == derivation.registeredImageNames.count,
              derivation.registeredImageNames.allSatisfy(isSafeImageName),
              derivation.datasetInputDigest == artifact.inputDigest,
              derivation.datasetGeometryDigest == artifact.geometryDigest,
              sanctionedBudgets.contains(where: {
                  $0.iterations == artifact.iterationLimit
                      && $0.plateau == artifact.plateauWindow
              }),
              artifact.completedIteration >= 0,
              artifact.completedIteration <= artifact.iterationLimit,
              artifact.gaussianCount > 0,
              artifact.elapsedSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              artifact.peakMemoryBytes > 0,
              artifact.memoryBudgetBytes > 0,
              TrainingMemoryBudget.isValid(artifact.resourceAdmission),
              UInt64(exactly: artifact.memoryBudgetBytes).map({
                  $0 <= artifact.resourceAdmission.allowedTrainerBytes
              }) == true,
              artifact.rasterFallbackCount >= 0,
              artifact.rasterFallbackCount <= min(
                  artifact.completedIteration,
                  Int(UInt32.max)
              ),
              artifact.rasterExactFallbackElapsedSeconds.isFinite,
              artifact.rasterExactFallbackElapsedSeconds >= 0,
              artifact.rasterExactBufferGrowthCount >= 0,
              artifact.rasterExactBufferGrowthCount <= artifact.rasterFallbackCount,
              artifact.rasterExactBufferBytesAdded >= 0,
              artifact.rasterReplayElapsedSeconds.isFinite,
              artifact.rasterReplayElapsedSeconds >= 0,
              artifact.rasterPeakExactIntersectionCapacity >= 0,
              artifact.rasterPeakExactIntersectionCapacity <= Int64(UInt32.max),
              (artifact.rasterExactBufferBytesAdded == 0
                  || 1 + ((artifact.rasterExactBufferBytesAdded - 1)
                      / artifact.memoryBudgetBytes)
                      <= Int64(artifact.rasterExactBufferGrowthCount)),
              ((artifact.rasterFallbackCount == 0
                  && artifact.rasterExactFallbackElapsedSeconds == 0
                  && artifact.rasterExactBufferGrowthCount == 0
                  && artifact.rasterExactBufferBytesAdded == 0
                  && artifact.rasterReplayElapsedSeconds == 0
                  && artifact.rasterPeakExactIntersectionCapacity == 0)
               || (artifact.rasterFallbackCount > 0
                  && artifact.rasterExactFallbackElapsedSeconds > 0
                  && artifact.rasterExactBufferGrowthCount > 0
                  && artifact.rasterExactBufferBytesAdded > 0
                  && artifact.rasterReplayElapsedSeconds > 0
                  && artifact.rasterPeakExactIntersectionCapacity > 2_048)),
              artifact.droppedIntersectionCount == 0 else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        switch artifact.completionStatus {
        case .checkpointed:
            guard let path = artifact.checkpointPath,
                  path == "Training/checkpoints/msplat",
                  let digest = artifact.checkpointDigest,
                  isSHA256(digest),
                  artifact.completedIteration < artifact.iterationLimit,
                  artifact.outputPath == nil,
                  artifact.outputSHA256 == nil,
                  artifact.outputBytes == nil,
                  artifact.elapsedSeconds == nil,
                  artifact.sceneBounds == nil else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            try validateProjectRelativePath(path)
        case .completed:
            guard let path = artifact.outputPath,
                  path == "Training/msplat/splat.ply" || path == "Output/splat.ply",
                  let outputSHA256 = artifact.outputSHA256,
                  isSHA256(outputSHA256),
                  let outputBytes = artifact.outputBytes,
                  outputBytes > 0,
                  artifact.completedIteration > 0,
                  artifact.checkpointPath == nil,
                  artifact.checkpointDigest == nil,
                  artifact.sceneBounds?.isValid == true,
                  let elapsedSeconds = artifact.elapsedSeconds,
                  artifact.rasterExactFallbackElapsedSeconds <= elapsedSeconds,
                  artifact.rasterReplayElapsedSeconds <= elapsedSeconds else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            try validateProjectRelativePath(path)
        }
    }

    private static func validateDescriptorBoundRelativePath(
        _ path: String
    ) throws {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              components.count <= 64,
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              components.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
              }) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    static func validateOutputBinding(
        _ artifact: TrainingArtifact,
        outputURL: URL
    ) throws {
        guard let evidence = try? ProjectArtifactValidator.validatedPlyEvidence(
            at: outputURL
        ) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try validateCompletedOutput(artifact, evidence: evidence)
    }

    package static func validateCompletedOutput(
        _ artifact: TrainingArtifact,
        evidence: ValidatedPlyArtifactEvidence
    ) throws {
        guard artifact.completionStatus == .completed,
              let expectedDigest = artifact.outputSHA256,
              let expectedBytes = artifact.outputBytes,
              expectedBytes > 0,
              evidence.vertexCount == artifact.gaussianCount,
              evidence.byteCount == UInt64(expectedBytes),
              evidence.sha256 == expectedDigest,
              let recordedBounds = artifact.sceneBounds,
              SplatSceneBoundsCalculator.matches(recordedBounds, evidence.sceneBounds) else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    public static func validateCompletedOutput(
        _ artifact: TrainingArtifact,
        at outputURL: URL
    ) throws {
        try validateOutputBinding(artifact, outputURL: outputURL)
    }

    private static func validateManifestLocation(_ url: URL, projectPaths: ProjectPaths) throws {
        do {
            _ = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: "Training/training_manifest.json"
            )
        } catch {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isSafeImageName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              URL(fileURLWithPath: name).lastPathComponent == name else {
            return false
        }
        return ["jpg", "jpeg", "png"].contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        )
    }
}

public enum TrainingArtifactStoreError: Error, LocalizedError {
    case invalidManifest

    public var errorDescription: String? {
        "Training manifest is invalid or incompatible with this run."
    }
}
