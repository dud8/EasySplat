import CryptoKit
import Darwin
import Foundation
import OSLog

/// Stages a new project beside its final destination and makes it visible with one
/// exclusive rename. A transaction never creates or deletes a visible project path.
public final class ProjectPublicationTransaction {
    public static let containerName = ".easysplat-project-transactions"

    public enum Checkpoint: String, CaseIterable, Sendable {
        case transactionRecordDurable
        case bundleRecordTemporaryDurable
        case bundleDirectoryCreated
        case stagedRootCreated
        case videoAdoptionRecordTemporaryDurable
        case videoAdopted
        case photoAdoptionRecordTemporaryDurable
        case photosAdopted
        case metadataValidationRecordTemporaryDurable
        case initialMetadataValidated
        case inputContentHashed
        case metadataDurable
        case readyReceiptDurable
        case renameComplete
        case librarySynced
        case cleanupIntentDurable
        case envelopeQuarantined
        case outerCleanupDurable
        case bundleCleanupDurable
        case cleanupProofRemoved
        case cleanupComplete
    }

    public typealias CheckpointHandler = @Sendable (Checkpoint) throws -> Void

    public let baseURL: URL
    public let envelopeURL: URL
    public let bundleURL: URL

    private static let bundleLeaf = "project.easysplatproj"
    private static let lockLeaf = "publication.lock"
    private static let recordLeaf = "transaction.json"
    private static let recordTemporaryLeaf = ".transaction.tmp"
    private static let readyLeaf = "ready.json"
    private static let readyTemporaryLeaf = ".ready.tmp"
    private static let cleanupPrefix = ".cleanup-"
    private static let cleanupSuffix = ".json"
    private static let transactionSchemaVersion = 3
    private static let readySchemaVersion = 1
    private static let cleanupSchemaVersion = 2
    private static let maximumRecordBytes = 16 * 1_024 * 1_024
    private static let maximumLeafAttempts = 999_999
    private static let logger = Logger(
        subsystem: "com.easysplat.app",
        category: "ProjectPublication"
    )

    private let transactionID: UUID
    private let projectID: UUID
    private let title: String
    private let baseIdentity: FileIdentity
    private let containerIdentity: FileIdentity
    private let envelopeIdentity: FileIdentity
    private let bundleIdentity: FileIdentity
    private let checkpointHandler: CheckpointHandler
    private var baseDescriptor: Int32
    private var containerDescriptor: Int32
    private var envelopeDescriptor: Int32
    private var bundleDescriptor: Int32
    private var lockDescriptor: Int32
    private var record: TransactionRecord
    private var readyRecord: ReadyRecord?
    private var publishedURL: URL?
    private var isFinished = false

    private init(
        baseURL: URL,
        envelopeURL: URL,
        bundleURL: URL,
        transactionID: UUID,
        projectID: UUID,
        title: String,
        baseIdentity: FileIdentity,
        containerIdentity: FileIdentity,
        envelopeIdentity: FileIdentity,
        bundleIdentity: FileIdentity,
        checkpointHandler: @escaping CheckpointHandler,
        baseDescriptor: Int32,
        containerDescriptor: Int32,
        envelopeDescriptor: Int32,
        bundleDescriptor: Int32,
        lockDescriptor: Int32,
        record: TransactionRecord
    ) {
        self.baseURL = baseURL
        self.envelopeURL = envelopeURL
        self.bundleURL = bundleURL
        self.transactionID = transactionID
        self.projectID = projectID
        self.title = title
        self.baseIdentity = baseIdentity
        self.containerIdentity = containerIdentity
        self.envelopeIdentity = envelopeIdentity
        self.bundleIdentity = bundleIdentity
        self.checkpointHandler = checkpointHandler
        self.baseDescriptor = baseDescriptor
        self.containerDescriptor = containerDescriptor
        self.envelopeDescriptor = envelopeDescriptor
        self.bundleDescriptor = bundleDescriptor
        self.lockDescriptor = lockDescriptor
        self.record = record
    }

    deinit {
        closeDescriptors()
    }

    public static func begin(
        in requestedBaseURL: URL,
        title: String,
        projectID: UUID,
        checkpointHandler: @escaping CheckpointHandler = { _ in }
    ) throws -> ProjectPublicationTransaction {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: requestedBaseURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            // Two processes can race while creating a previously absent library.
            // Continue only when the requested leaf now exists as a real directory;
            // the descriptor-bound ownership checks below remain authoritative.
            var racedStatus = stat()
            guard lstat(requestedBaseURL.path, &racedStatus) == 0,
                  racedStatus.st_mode & S_IFMT == S_IFDIR else {
                throw error
            }
        }
        let baseURL = try canonicalExistingDirectoryURL(requestedBaseURL)
        let baseDescriptor = try openAbsoluteDirectory(baseURL)
        var ownsBase = true
        defer { if ownsBase { Darwin.close(baseDescriptor) } }
        let baseIdentity = try FileIdentity.read(
            from: baseDescriptor,
            expectedType: S_IFDIR
        )
        guard baseIdentity.owner == getuid(), baseIdentity.permissions & 0o022 == 0 else {
            throw ProjectPublicationError.unsafeProjectLibrary
        }

        let createdContainer = mkdirat(baseDescriptor, containerName, S_IRWXU) == 0
        if !createdContainer, errno != EEXIST { throw posixError(errno) }
        let containerDescriptor = try openChildDirectory(
            parent: baseDescriptor,
            leaf: containerName
        )
        var ownsContainer = true
        defer { if ownsContainer { Darwin.close(containerDescriptor) } }
        let containerIdentity = try FileIdentity.read(
            from: containerDescriptor,
            expectedType: S_IFDIR
        )
        guard containerIdentity.owner == getuid(),
              containerIdentity.permissions == 0o700,
              containerIdentity.device == baseIdentity.device,
              try nameStillRefersToDescriptor(
                  parent: baseDescriptor,
                  leaf: containerName,
                  descriptor: containerDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.unsafeTransactionContainer
        }
        if createdContainer {
            try syncDirectory(containerDescriptor)
            try syncDirectory(baseDescriptor)
        }

        let lockDescriptor = try openPublicationLock(in: containerDescriptor)
        var ownsLock = true
        defer {
            if ownsLock {
                unlockOpenFileDescription(lockDescriptor)
                Darwin.close(lockDescriptor)
            }
        }
        try lockOpenFileDescription(lockDescriptor, waits: true)
        _ = try reconcileLocked(
            baseURL: baseURL,
            baseDescriptor: baseDescriptor,
            baseIdentity: baseIdentity,
            containerDescriptor: containerDescriptor,
            containerIdentity: containerIdentity
        )

        let transactionID = UUID()
        let envelopeLeaf = transactionLeaf(for: transactionID)
        guard mkdirat(containerDescriptor, envelopeLeaf, S_IRWXU) == 0 else {
            throw posixError(errno)
        }
        let envelopeDescriptor = try openChildDirectory(
            parent: containerDescriptor,
            leaf: envelopeLeaf
        )
        var ownsEnvelope = true
        defer { if ownsEnvelope { Darwin.close(envelopeDescriptor) } }
        let envelopeIdentity = try FileIdentity.read(
            from: envelopeDescriptor,
            expectedType: S_IFDIR
        )
        guard envelopeIdentity.owner == getuid(),
              envelopeIdentity.permissions == 0o700,
              envelopeIdentity.device == containerIdentity.device,
              try nameStillRefersToDescriptor(
                  parent: containerDescriptor,
                  leaf: envelopeLeaf,
                  descriptor: envelopeDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }

        var record = TransactionRecord(
            schemaVersion: transactionSchemaVersion,
            transactionID: transactionID,
            projectID: projectID,
            projectFormatVersion: ProjectMetadataStore.supportedFormatVersion,
            title: title,
            phase: .recorded,
            library: baseIdentity,
            envelope: envelopeIdentity,
            bundle: nil,
            ownedBundleManifest: nil,
            plannedFinalLeaf: nil,
            validatedMetadataSHA256: nil,
            validatedReceiptDigest: nil,
            validatedManifestDigest: nil
        )
        try writeInitialRecord(record, in: envelopeDescriptor)
        try syncDirectory(envelopeDescriptor)
        try syncDirectory(containerDescriptor)
        try checkpointHandler(.transactionRecordDurable)

        guard mkdirat(envelopeDescriptor, bundleLeaf, S_IRWXU) == 0 else {
            throw posixError(errno)
        }
        let bundleDescriptor = try openChildDirectory(
            parent: envelopeDescriptor,
            leaf: bundleLeaf
        )
        var ownsBundle = true
        defer { if ownsBundle { Darwin.close(bundleDescriptor) } }
        let bundleIdentity = try FileIdentity.read(
            from: bundleDescriptor,
            expectedType: S_IFDIR
        )
        guard bundleIdentity.owner == getuid(),
              bundleIdentity.permissions == 0o700,
              bundleIdentity.device == baseIdentity.device,
              try nameStillRefersToDescriptor(
                  parent: envelopeDescriptor,
                  leaf: bundleLeaf,
                  descriptor: bundleDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.unsafePendingBundle
        }
        var bundleStatus = stat()
        guard fstat(bundleDescriptor, &bundleStatus) == 0 else {
            throw posixError(errno)
        }
        let ownedBundleManifest = [TreeEntry(
            relativePath: ".",
            status: bundleStatus,
            kind: .directory,
            sha256: nil
        )]
        try syncDirectory(bundleDescriptor)
        try syncDirectory(envelopeDescriptor)
        record = record.replacing(
            phase: .building,
            bundle: bundleIdentity,
            ownedBundleManifest: ownedBundleManifest
        )
        try replaceRecord(
            record,
            in: envelopeDescriptor,
            beforeCommit: { [checkpointHandler] in
                try checkpointHandler(.bundleRecordTemporaryDurable)
            }
        )
        try syncDirectory(containerDescriptor)
        try checkpointHandler(.bundleDirectoryCreated)
        try syncDirectory(bundleDescriptor)
        try syncDirectory(envelopeDescriptor)
        try checkpointHandler(.stagedRootCreated)

        let envelopeURL = baseURL
            .appendingPathComponent(containerName, isDirectory: true)
            .appendingPathComponent(envelopeLeaf, isDirectory: true)
        let bundleURL = envelopeURL.appendingPathComponent(bundleLeaf, isDirectory: true)
        let transaction = ProjectPublicationTransaction(
            baseURL: baseURL,
            envelopeURL: envelopeURL,
            bundleURL: bundleURL,
            transactionID: transactionID,
            projectID: projectID,
            title: title,
            baseIdentity: baseIdentity,
            containerIdentity: containerIdentity,
            envelopeIdentity: envelopeIdentity,
            bundleIdentity: bundleIdentity,
            checkpointHandler: checkpointHandler,
            baseDescriptor: baseDescriptor,
            containerDescriptor: containerDescriptor,
            envelopeDescriptor: envelopeDescriptor,
            bundleDescriptor: bundleDescriptor,
            lockDescriptor: lockDescriptor,
            record: record
        )
        ownsBase = false
        ownsContainer = false
        ownsEnvelope = false
        ownsBundle = false
        ownsLock = false
        return transaction
    }

    public func reached(_ checkpoint: Checkpoint) throws {
        guard !isFinished else { throw ProjectPublicationError.transactionFinished }
        if checkpoint == .videoAdopted || checkpoint == .photosAdopted {
            try requireLivePendingBundle()
            let observedBundleManifest = try Self.captureDemonstrablyOwnedIncompleteBundle(
                rootDescriptor: bundleDescriptor,
                expectedBundle: bundleIdentity
            )
            try Self.normalizeOwnedDirectoryPermissions(
                manifest: observedBundleManifest,
                rootDescriptor: bundleDescriptor
            )
            let ownedBundleManifest = try Self.captureDemonstrablyOwnedIncompleteBundle(
                rootDescriptor: bundleDescriptor,
                expectedBundle: bundleIdentity
            )
            try Self.syncInitialBundle(
                manifest: ownedBundleManifest,
                rootDescriptor: bundleDescriptor
            )
            record = record.replacing(
                phase: .building,
                ownedBundleManifest: ownedBundleManifest
            )
            let temporaryCheckpoint: Checkpoint = checkpoint == .videoAdopted
                ? .videoAdoptionRecordTemporaryDurable
                : .photoAdoptionRecordTemporaryDurable
            try Self.replaceRecord(
                record,
                in: envelopeDescriptor,
                beforeCommit: { [checkpointHandler] in
                    try checkpointHandler(temporaryCheckpoint)
                }
            )
            try Self.syncDirectory(envelopeDescriptor)
            try Self.syncDirectory(containerDescriptor)
        }
        try checkpointHandler(checkpoint)
    }

    /// Validates the complete initial bundle, durably syncs it, and writes the
    /// readiness receipt required by both normal publication and crash recovery.
    public func validateAndSeal(expectedMetadata: ProjectMetadata) throws {
        try requireLivePendingBundle()
        let validated = try Self.validateCompleteInitialBundle(
            at: bundleURL,
            expectedProjectID: projectID,
            expectedTitle: title,
            expectedMetadata: expectedMetadata,
            expectedBundle: bundleIdentity,
            normalizesPermissions: true,
            hashesInputContents: true,
            afterMetadataValidation: { [self] metadataSHA256, receiptDigest in
                let ownedBundleManifest = try Self.captureDemonstrablyOwnedIncompleteBundle(
                    rootDescriptor: bundleDescriptor,
                    expectedBundle: bundleIdentity
                )
                try Self.syncInitialBundle(
                    manifest: ownedBundleManifest,
                    rootDescriptor: bundleDescriptor
                )
                record = record.replacing(
                    phase: .building,
                    ownedBundleManifest: ownedBundleManifest,
                    validatedMetadataSHA256: metadataSHA256,
                    validatedReceiptDigest: receiptDigest
                )
                try Self.replaceRecord(
                    record,
                    in: envelopeDescriptor,
                    beforeCommit: { [checkpointHandler] in
                        try checkpointHandler(.metadataValidationRecordTemporaryDurable)
                    }
                )
                try Self.syncDirectory(envelopeDescriptor)
                try Self.syncDirectory(containerDescriptor)
                try checkpointHandler(.initialMetadataValidated)
            },
            afterInputHash: { [checkpointHandler] in
                try checkpointHandler(.inputContentHashed)
            }
        )
        try Self.syncInitialBundle(
            manifest: validated.manifest,
            rootDescriptor: bundleDescriptor
        )
        // This checkpoint intentionally follows the file, child-directory, project-root,
        // transaction-directory, and transaction-root barriers. Crash tests depend on
        // "metadataDurable" meaning the complete initial bundle can be recovered.
        try Self.syncDirectory(envelopeDescriptor)
        try Self.syncDirectory(containerDescriptor)
        record = record.replacing(
            phase: .building,
            validatedManifestDigest: try Self.manifestDigest(validated.manifest)
        )
        try Self.replaceRecord(record, in: envelopeDescriptor)
        try Self.syncDirectory(envelopeDescriptor)
        try Self.syncDirectory(containerDescriptor)
        try checkpointHandler(.metadataDurable)
        let stable = try Self.validateCompleteInitialBundle(
            at: bundleURL,
            expectedProjectID: projectID,
            expectedTitle: title,
            expectedMetadata: expectedMetadata,
            expectedBundle: bundleIdentity,
            normalizesPermissions: false,
            hashesInputContents: false
        )
        guard stable.metadataSHA256 == validated.metadataSHA256,
              stable.receiptDigest == validated.receiptDigest,
              stable.manifest == validated.manifest else {
            throw ProjectPublicationError.pendingBundleChanged
        }

        let ready = ReadyRecord(
            schemaVersion: Self.readySchemaVersion,
            transactionID: transactionID,
            projectID: projectID,
            projectFormatVersion: ProjectMetadataStore.supportedFormatVersion,
            bundle: bundleIdentity,
            metadataSHA256: stable.metadataSHA256,
            receiptDigest: stable.receiptDigest,
            manifest: stable.manifest
        )
        try Self.writeReadyRecord(ready, in: envelopeDescriptor)
        record = record.replacing(phase: .ready)
        try Self.replaceRecord(record, in: envelopeDescriptor)
        try Self.syncDirectory(envelopeDescriptor)
        try Self.syncDirectory(containerDescriptor)
        readyRecord = ready
        try checkpointHandler(.readyReceiptDurable)
    }

    public func publish() throws -> URL {
        try publishResult(attestationHandoff: nil).projectURL
    }

    public func publishWithFreshAttestation(
        videoInputIntegrityHandoff: VideoInputIntegrityHandoff
    ) throws -> FreshProjectPublication {
        try publishWithFreshAttestationImpl(consumeVideoIntegrityHandoff: {
            try videoInputIntegrityHandoff.consumeAfterSuccessorArmed()
        })
    }

    public func publishWithFreshAttestationForProjectWithoutVideos() throws
        -> FreshProjectPublication
    {
        guard let readyRecord,
              !readyRecord.manifest.contains(where: Self.isControlledVideoInput) else {
            throw ProjectPublicationError.pendingBundleNotReady
        }
        return try publishWithFreshAttestationImpl(
            consumeVideoIntegrityHandoff: nil
        )
    }

    /// Internal seam used by transaction tests to prove monitor-generation overlap.
    func publishWithFreshAttestationForTesting(
        consumeVideoIntegrityHandoff: (() throws -> Void)? = nil,
        beforePublicationAttestation: (() throws -> Void)? = nil
    ) throws -> FreshProjectPublication {
        try publishWithFreshAttestationImpl(
            consumeVideoIntegrityHandoff: consumeVideoIntegrityHandoff,
            beforePublicationAttestation: beforePublicationAttestation
        )
    }

    private func publishWithFreshAttestationImpl(
        consumeVideoIntegrityHandoff: (() throws -> Void)?,
        beforePublicationAttestation: (() throws -> Void)? = nil
    ) throws -> FreshProjectPublication {
        let result = try publishResult(
            attestationHandoff: .init(
                consume: consumeVideoIntegrityHandoff,
                beforePublicationAttestation: beforePublicationAttestation
            )
        )
        guard let attestation = result.attestation else {
            throw ProjectPublicationError.pendingBundleNotReady
        }
        return FreshProjectPublication(projectURL: result.projectURL, attestation: attestation)
    }

    private struct AttestationHandoff {
        let consume: (() throws -> Void)?
        let beforePublicationAttestation: (() throws -> Void)?
    }

    private struct PublicationResult {
        let projectURL: URL
        let attestation: FreshProjectPublicationAttestation?
    }

    private func publishResult(attestationHandoff: AttestationHandoff?) throws
        -> PublicationResult
    {
        try requireLivePendingBundle()
        guard let readyRecord else { throw ProjectPublicationError.pendingBundleNotReady }
        try Self.validateReadyBundleWithoutRehash(
            at: bundleURL,
            expectedTransactionID: transactionID,
            expectedProjectID: projectID,
            expectedTitle: title,
            expectedBundle: bundleIdentity,
            ready: readyRecord
        )

        var pendingAttestation: FreshProjectPublicationAttestation?
        defer { pendingAttestation?.discard() }
        if let attestationHandoff {
            pendingAttestation = try FreshProjectPublicationAttestation(
                baseDescriptor: baseDescriptor,
                bundleDescriptor: bundleDescriptor,
                expectedBundle: .init(
                    device: bundleIdentity.device,
                    inode: bundleIdentity.inode,
                    owner: bundleIdentity.owner,
                    permissions: bundleIdentity.permissions
                ),
                metadataSHA256: readyRecord.metadataSHA256,
                receiptDigest: readyRecord.receiptDigest,
                manifest: readyRecord.manifest.map {
                    .init(
                        relativePath: $0.relativePath,
                        isDirectory: $0.kind == .directory,
                        device: $0.device,
                        inode: $0.inode,
                        owner: $0.owner,
                        permissions: $0.permissions,
                        linkCount: $0.linkCount,
                        byteCount: $0.byteCount,
                        modifiedSeconds: $0.modifiedSeconds,
                        modifiedNanoseconds: $0.modifiedNanoseconds,
                        changedSeconds: $0.changedSeconds,
                        changedNanoseconds: $0.changedNanoseconds
                    )
                },
                consumeVideoIntegrityHandoff: attestationHandoff.consume
            )
        }
        for attempt in 0..<Self.maximumLeafAttempts {
            let leaf = Self.projectBundleLeaf(for: title, attempt: attempt)
            record = record.replacing(phase: .publishing, plannedFinalLeaf: leaf)
            try Self.replaceRecord(record, in: envelopeDescriptor)
            try Self.syncDirectory(envelopeDescriptor)
            try Self.syncDirectory(containerDescriptor)
            try requireLivePendingBundle()
            let destinationURL = baseURL.appendingPathComponent(leaf, isDirectory: true)

            let result = renameatx_np(
                envelopeDescriptor,
                Self.bundleLeaf,
                baseDescriptor,
                leaf,
                UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
            )
            if result != 0 {
                let code = errno
                if code == EEXIST { continue }
                if code == EXDEV { throw ProjectPublicationError.crossVolumePublication }
                if code == ENOTSUP || code == ENOSYS {
                    throw ProjectPublicationError.exclusiveRenameUnavailable
                }
                throw Self.posixError(code)
            }

            guard try Self.nameStillRefersToDescriptor(
                parent: baseDescriptor,
                leaf: leaf,
                descriptor: bundleDescriptor,
                expectedType: S_IFDIR
            ), try Self.absoluteDirectoryStillRefers(
                to: baseDescriptor,
                identity: baseIdentity,
                at: baseURL
            ) else {
                try Self.rollbackPublishedBundle(
                    baseDescriptor: baseDescriptor,
                    visibleLeaf: leaf,
                    envelopeDescriptor: envelopeDescriptor,
                    bundleDescriptor: bundleDescriptor
                )
                throw ProjectPublicationError.publishedBundleIdentityChanged
            }
            publishedURL = destinationURL
            record = record.replacing(phase: .published, plannedFinalLeaf: leaf)
            try checkpointHandler(.renameComplete)
            try Self.syncDirectory(baseDescriptor)
            try Self.fullSync(baseDescriptor)
            guard try Self.absoluteDirectoryStillRefers(
                to: baseDescriptor,
                identity: baseIdentity,
                at: baseURL
            ) else {
                try Self.rollbackPublishedBundle(
                    baseDescriptor: baseDescriptor,
                    visibleLeaf: leaf,
                    envelopeDescriptor: envelopeDescriptor,
                    bundleDescriptor: bundleDescriptor
                )
                publishedURL = nil
                throw ProjectPublicationError.transactionIdentityChanged
            }
            try checkpointHandler(.librarySynced)
            do {
                try Self.validateVisiblePublishedBundle(
                    at: destinationURL,
                    expectedTransactionID: transactionID,
                    expectedProjectID: projectID,
                    expectedTitle: title,
                    expectedBundle: bundleIdentity,
                    ready: readyRecord
                )
                guard try Self.absoluteDirectoryStillRefers(
                    to: baseDescriptor,
                    identity: baseIdentity,
                    at: baseURL
                ) else {
                    throw ProjectPublicationError.transactionIdentityChanged
                }
                // Complete the monitor-generation transition while rollback is
                // still possible. A failed attestation must never leave a visible
                // project after its hidden transaction envelope is destroyed.
                try attestationHandoff?.beforePublicationAttestation?()
                try pendingAttestation?.publicationDidComplete(projectURL: destinationURL)
            } catch {
                try Self.rollbackPublishedBundle(
                    baseDescriptor: baseDescriptor,
                    visibleLeaf: leaf,
                    envelopeDescriptor: envelopeDescriptor,
                    bundleDescriptor: bundleDescriptor
                )
                publishedURL = nil
                throw error
            }
            try Self.replaceRecord(record, in: envelopeDescriptor)
            try Self.syncDirectory(envelopeDescriptor)
            try cleanupEnvelope(disposition: .published, expectedBundle: nil)
            isFinished = true
            closeDescriptors()
            try pendingAttestation?.publicationCleanupDidComplete()
            let attestation = pendingAttestation
            self.publishedURL = destinationURL
            pendingAttestation = nil
            return PublicationResult(projectURL: destinationURL, attestation: attestation)
        }
        throw ProjectPublicationError.projectNameExhausted
    }

    private static func isControlledVideoInput(_ entry: TreeEntry) -> Bool {
        guard entry.kind == .file,
              entry.relativePath.hasPrefix("Originals/video-") else { return false }
        let leaf = String(entry.relativePath.dropFirst("Originals/video-".count))
        guard let separator = leaf.firstIndex(of: ".") else { return false }
        let ordinal = leaf[..<separator]
        return ordinal.count == 4 && ordinal.allSatisfy { $0.isNumber }
    }

    /// Removes only a still-hidden transaction whose entire closure is recognized
    /// as app-created. Suspicious or replaced entries are deliberately preserved.
    public func abort() throws {
        guard !isFinished else { return }
        guard publishedURL == nil else {
            closeDescriptors()
            return
        }
        try requireLivePendingBundle()
        guard let ownedBundleManifest = record.ownedBundleManifest else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        try Self.validateDemonstrablyOwnedIncompleteBundle(
            at: bundleURL,
            expectedBundle: bundleIdentity,
            expectedManifest: ownedBundleManifest
        )
        try cleanupEnvelope(disposition: .abort, expectedBundle: bundleIdentity)
        isFinished = true
        closeDescriptors()
    }

    /// Reconciles abandoned hidden transactions. It never rewrites or removes a
    /// pre-existing visible project, including incompatible project formats.
    @discardableResult
    public static func reconcile(in requestedBaseURL: URL) -> [ProjectPublicationReconciliationEvent] {
        let baseURL: URL
        do {
            baseURL = try canonicalExistingDirectoryURL(requestedBaseURL)
        } catch {
            return []
        }
        let containerURL = baseURL.appendingPathComponent(containerName, isDirectory: true)
        var containerStatus = stat()
        guard lstat(containerURL.path, &containerStatus) == 0 else { return [] }
        guard (containerStatus.st_mode & S_IFMT) == S_IFDIR,
              containerStatus.st_uid == getuid(),
              containerStatus.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            logger.error("Preserving unsafe project transaction container at \(containerURL.path, privacy: .private)")
            return [.preserved(containerURL, reason: "unsafe transaction container")]
        }

        do {
            let baseDescriptor = try openAbsoluteDirectory(baseURL)
            defer { Darwin.close(baseDescriptor) }
            let baseIdentity = try FileIdentity.read(from: baseDescriptor, expectedType: S_IFDIR)
            guard baseIdentity.owner == getuid(), baseIdentity.permissions & 0o022 == 0 else {
                throw ProjectPublicationError.unsafeProjectLibrary
            }
            let containerDescriptor = try openChildDirectory(
                parent: baseDescriptor,
                leaf: containerName
            )
            defer { Darwin.close(containerDescriptor) }
            let containerIdentity = try FileIdentity.read(
                from: containerDescriptor,
                expectedType: S_IFDIR
            )
            guard containerIdentity == FileIdentity(containerStatus),
                  containerIdentity.device == baseIdentity.device else {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
            let lockDescriptor = try openPublicationLock(in: containerDescriptor)
            defer {
                unlockOpenFileDescription(lockDescriptor)
                Darwin.close(lockDescriptor)
            }
            do {
                try lockOpenFileDescription(lockDescriptor, waits: false)
            } catch ProjectPublicationError.publicationBusy {
                return [.active(containerURL)]
            }
            return try reconcileLocked(
                baseURL: baseURL,
                baseDescriptor: baseDescriptor,
                baseIdentity: baseIdentity,
                containerDescriptor: containerDescriptor,
                containerIdentity: containerIdentity
            )
        } catch {
            logger.error("Project transaction reconciliation failed: \(String(describing: error), privacy: .public)")
            return [.preserved(containerURL, reason: error.localizedDescription)]
        }
    }

    public static func candidateURL(in baseURL: URL, title: String, attempt: Int) -> URL {
        baseURL.appendingPathComponent(
            projectBundleLeaf(for: title, attempt: max(0, attempt)),
            isDirectory: true
        )
    }

#if DEBUG
    static func repeatedDirectoryListingForTesting(at directory: URL) throws -> ([String], [String]) {
        let descriptor = try Self.openAbsoluteDirectory(
            try Self.canonicalExistingDirectoryURL(directory)
        )
        defer { Darwin.close(descriptor) }
        return (
            try Self.directoryLeafNames(descriptor: descriptor, maximumCount: 100),
            try Self.directoryLeafNames(descriptor: descriptor, maximumCount: 100)
        )
    }

    static func inputReceiptDigestForTesting(_ metadata: ProjectMetadata) -> String {
        inputReceiptDigest(metadata)
    }
#endif

    static func receiptDigestForFreshAttestation(_ metadata: ProjectMetadata) -> String {
        inputReceiptDigest(metadata)
    }

    private func requireLivePendingBundle() throws {
        guard !isFinished, publishedURL == nil else {
            throw ProjectPublicationError.transactionFinished
        }
        guard try Self.absoluteDirectoryStillRefers(
                  to: baseDescriptor,
                  identity: baseIdentity,
                  at: baseURL
              ),
              try Self.FileIdentity.read(from: baseDescriptor, expectedType: S_IFDIR) == baseIdentity,
              try Self.FileIdentity.read(from: containerDescriptor, expectedType: S_IFDIR) == containerIdentity,
              try Self.FileIdentity.read(from: envelopeDescriptor, expectedType: S_IFDIR) == envelopeIdentity,
              try Self.FileIdentity.read(from: bundleDescriptor, expectedType: S_IFDIR) == bundleIdentity,
              try Self.nameStillRefersToDescriptor(
                  parent: baseDescriptor,
                  leaf: Self.containerName,
                  descriptor: containerDescriptor,
                  expectedType: S_IFDIR
              ),
              try Self.nameStillRefersToDescriptor(
                  parent: containerDescriptor,
                  leaf: envelopeURL.lastPathComponent,
                  descriptor: envelopeDescriptor,
                  expectedType: S_IFDIR
              ),
              try Self.nameStillRefersToDescriptor(
                  parent: envelopeDescriptor,
                  leaf: Self.bundleLeaf,
                  descriptor: bundleDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
    }

    private static func absoluteDirectoryStillRefers(
        to descriptor: Int32,
        identity: FileIdentity,
        at url: URL
    ) throws -> Bool {
        let reopened: Int32
        do {
            reopened = try openAbsoluteDirectory(url)
        } catch {
            return false
        }
        defer { Darwin.close(reopened) }
        let heldIdentity = try FileIdentity.read(from: descriptor, expectedType: S_IFDIR)
        let reopenedIdentity = try FileIdentity.read(from: reopened, expectedType: S_IFDIR)
        return heldIdentity == identity && reopenedIdentity == identity
    }

    private static func rollbackPublishedBundle(
        baseDescriptor: Int32,
        visibleLeaf: String,
        envelopeDescriptor: Int32,
        bundleDescriptor: Int32
    ) throws {
        guard safeVisibleProjectLeaf(visibleLeaf),
              try nameStillRefersToDescriptor(
                parent: baseDescriptor,
                leaf: visibleLeaf,
                descriptor: bundleDescriptor,
                expectedType: S_IFDIR
              ),
              renameatx_np(
                baseDescriptor,
                visibleLeaf,
                envelopeDescriptor,
                bundleLeaf,
                UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
              ) == 0,
              try nameStillRefersToDescriptor(
                parent: envelopeDescriptor,
                leaf: bundleLeaf,
                descriptor: bundleDescriptor,
                expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.publishedBundleIdentityChanged
        }
        try syncDirectory(baseDescriptor)
        try syncDirectory(envelopeDescriptor)
    }

    private func cleanupEnvelope(
        disposition: CleanupRecord.Disposition,
        expectedBundle: FileIdentity?
    ) throws {
        if bundleDescriptor >= 0 {
            Darwin.close(bundleDescriptor)
            bundleDescriptor = -1
        }
        try Self.removeEnvelopeDescriptorRelative(
            baseURL: baseURL,
            baseDescriptor: baseDescriptor,
            baseIdentity: baseIdentity,
            containerDescriptor: containerDescriptor,
            sourceLeaf: envelopeURL.lastPathComponent,
            envelopeDescriptor: envelopeDescriptor,
            envelopeIdentity: envelopeIdentity,
            disposition: disposition,
            expectedBundle: expectedBundle,
            checkpointHandler: checkpointHandler
        )
        Darwin.close(envelopeDescriptor)
        envelopeDescriptor = -1
    }

    private func closeBundleAndEnvelopeDescriptors() {
        if bundleDescriptor >= 0 {
            Darwin.close(bundleDescriptor)
            bundleDescriptor = -1
        }
        if envelopeDescriptor >= 0 {
            Darwin.close(envelopeDescriptor)
            envelopeDescriptor = -1
        }
    }

    private func closeDescriptors() {
        closeBundleAndEnvelopeDescriptors()
        if lockDescriptor >= 0 {
            Self.unlockOpenFileDescription(lockDescriptor)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
        if containerDescriptor >= 0 {
            Darwin.close(containerDescriptor)
            containerDescriptor = -1
        }
        if baseDescriptor >= 0 {
            Darwin.close(baseDescriptor)
            baseDescriptor = -1
        }
    }
}

public enum ProjectPublicationError: Error, LocalizedError, Equatable, Sendable {
    case unsafeProjectLibrary
    case unsafeTransactionContainer
    case unsafeTransactionEnvelope
    case unsafePendingBundle
    case unsupportedFilesystemEntry(String)
    case transactionIdentityChanged
    case pendingBundleChanged
    case pendingBundleEntryChanged(String)
    case pendingBundleNotReady
    case invalidInitialMetadata
    case invalidReadinessReceipt
    case publishedBundleIdentityChanged
    case crossVolumePublication
    case exclusiveRenameUnavailable
    case publicationBusy
    case projectNameExhausted
    case transactionFinished

    public var errorDescription: String? {
        switch self {
        case .unsafeProjectLibrary: "The project library is not private and safe."
        case .unsafeTransactionContainer: "The project transaction folder is not private and safe."
        case .unsafeTransactionEnvelope: "The pending project transaction is not private and safe."
        case .unsafePendingBundle: "The pending project bundle is not private and safe."
        case .unsupportedFilesystemEntry(let path): "The pending project contains an unsupported entry: \(path)"
        case .transactionIdentityChanged: "The pending project changed while it was being prepared."
        case .pendingBundleChanged: "The pending project changed after validation."
        case .pendingBundleEntryChanged(let path): "The pending project changed after validation: \(path)"
        case .pendingBundleNotReady: "The pending project has not passed publication validation."
        case .invalidInitialMetadata: "The pending project metadata is not a valid new project."
        case .invalidReadinessReceipt: "The pending project readiness receipt is invalid."
        case .publishedBundleIdentityChanged: "The published project does not match the validated pending project."
        case .crossVolumePublication: "The pending project is not on the project library volume."
        case .exclusiveRenameUnavailable: "This volume does not support safe exclusive project publication."
        case .publicationBusy: "Another EasySplat process is publishing a project."
        case .projectNameExhausted: "EasySplat could not allocate a unique project name."
        case .transactionFinished: "The project publication transaction is already finished."
        }
    }
}

public enum ProjectPublicationReconciliationEvent: Equatable, Sendable {
    case active(URL)
    case published(URL)
    case removedIncomplete(URL)
    case cleanedPublished(URL)
    case preserved(URL, reason: String)
}

private extension ProjectPublicationTransaction {
    enum TransactionPhase: String, Codable {
        case recorded
        case building
        case ready
        case publishing
        case published
    }

    struct FileIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let permissions: UInt16

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            owner = status.st_uid
            permissions = UInt16(status.st_mode & mode_t(0o7777))
        }

        static func read(from descriptor: Int32, expectedType: mode_t) throws -> FileIdentity {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw ProjectPublicationTransaction.posixError(errno)
            }
            guard status.st_mode & S_IFMT == expectedType else {
                throw ProjectPublicationError.unsupportedFilesystemEntry("descriptor")
            }
            return FileIdentity(status)
        }

        static func read(at url: URL, expectedType: mode_t) throws -> FileIdentity {
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw ProjectPublicationTransaction.posixError(errno)
            }
            guard status.st_mode & S_IFMT == expectedType else {
                throw ProjectPublicationError.unsupportedFilesystemEntry(url.lastPathComponent)
            }
            return FileIdentity(status)
        }
    }

    struct TransactionRecord: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let projectID: UUID
        let projectFormatVersion: Int
        let title: String
        let phase: TransactionPhase
        let library: FileIdentity
        let envelope: FileIdentity
        let bundle: FileIdentity?
        let ownedBundleManifest: [TreeEntry]?
        let plannedFinalLeaf: String?
        let validatedMetadataSHA256: String?
        let validatedReceiptDigest: String?
        let validatedManifestDigest: String?

        func replacing(
            phase: TransactionPhase,
            bundle: FileIdentity? = nil,
            ownedBundleManifest: [TreeEntry]? = nil,
            plannedFinalLeaf: String? = nil,
            validatedMetadataSHA256: String? = nil,
            validatedReceiptDigest: String? = nil,
            validatedManifestDigest: String? = nil
        ) -> TransactionRecord {
            TransactionRecord(
                schemaVersion: schemaVersion,
                transactionID: transactionID,
                projectID: projectID,
                projectFormatVersion: projectFormatVersion,
                title: title,
                phase: phase,
                library: library,
                envelope: envelope,
                bundle: bundle ?? self.bundle,
                ownedBundleManifest: ownedBundleManifest ?? self.ownedBundleManifest,
                plannedFinalLeaf: plannedFinalLeaf ?? self.plannedFinalLeaf,
                validatedMetadataSHA256: validatedMetadataSHA256 ?? self.validatedMetadataSHA256,
                validatedReceiptDigest: validatedReceiptDigest ?? self.validatedReceiptDigest,
                validatedManifestDigest: validatedManifestDigest ?? self.validatedManifestDigest
            )
        }
    }

    struct TreeEntry: Codable, Equatable {
        enum Kind: String, Codable { case directory, file }

        let relativePath: String
        let kind: Kind
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let permissions: UInt16
        let linkCount: UInt16
        let byteCount: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let sha256: String?

        init(relativePath: String, status: stat, kind: Kind, sha256: String?) {
            self.relativePath = relativePath
            self.kind = kind
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            owner = status.st_uid
            permissions = UInt16(status.st_mode & mode_t(0o7777))
            linkCount = UInt16(clamping: status.st_nlink)
            // APFS can advance directory ctime while flushing otherwise unchanged
            // directory metadata. Exact child names and identities bind directory
            // contents; volatile directory size/timestamps are therefore normalized.
            byteCount = kind == .directory ? 0 : Int64(status.st_size)
            modifiedSeconds = kind == .directory ? 0 : Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = kind == .directory ? 0 : Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = kind == .directory ? 0 : Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = kind == .directory ? 0 : Int64(status.st_ctimespec.tv_nsec)
            self.sha256 = sha256
        }

        init(
            relativePath: String,
            photoSelectionLease: PhotoSelectionArtifactLeaseEvidence
        ) {
            self.relativePath = relativePath
            kind = .file
            device = photoSelectionLease.device
            inode = photoSelectionLease.inode
            owner = photoSelectionLease.owner
            permissions = UInt16(photoSelectionLease.mode & 0o7777)
            linkCount = UInt16(clamping: photoSelectionLease.linkCount)
            byteCount = photoSelectionLease.byteCount
            modifiedSeconds = photoSelectionLease.modifiedSeconds
            modifiedNanoseconds = photoSelectionLease.modifiedNanoseconds
            changedSeconds = photoSelectionLease.changedSeconds
            changedNanoseconds = photoSelectionLease.changedNanoseconds
            sha256 = photoSelectionLease.sha256
        }

        func matches(_ status: stat) -> Bool {
            let expectedType: mode_t = kind == .directory ? S_IFDIR : S_IFREG
            let identityMatches = status.st_mode & S_IFMT == expectedType
                && UInt64(status.st_dev) == device
                && UInt64(status.st_ino) == inode
                && status.st_uid == owner
                && UInt16(status.st_mode & mode_t(0o7777)) == permissions
                && UInt16(clamping: status.st_nlink) == linkCount
            if kind == .directory { return identityMatches }
            return identityMatches
                && Int64(status.st_size) == byteCount
                && Int64(status.st_mtimespec.tv_sec) == modifiedSeconds
                && Int64(status.st_mtimespec.tv_nsec) == modifiedNanoseconds
                && Int64(status.st_ctimespec.tv_sec) == changedSeconds
                && Int64(status.st_ctimespec.tv_nsec) == changedNanoseconds
        }

        func matchesIdentity(_ status: stat) -> Bool {
            let expectedType: mode_t = kind == .directory ? S_IFDIR : S_IFREG
            return status.st_mode & S_IFMT == expectedType
                && UInt64(status.st_dev) == device
                && UInt64(status.st_ino) == inode
                && status.st_uid == owner
                && UInt16(status.st_mode & mode_t(0o7777)) == permissions
                && (kind == .directory || UInt16(clamping: status.st_nlink) == linkCount)
        }
    }

    struct ProtectedInitialDirectoryIdentity {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32

        init(_ lease: PhotoSelectionArtifactDirectoryLeaseEvidence) {
            device = lease.device
            inode = lease.inode
            owner = lease.owner
        }

        func matches(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFDIR
                && UInt64(bitPattern: Int64(status.st_dev)) == device
                && UInt64(status.st_ino) == inode
                && UInt32(status.st_uid) == owner
        }
    }

    struct ReadyRecord: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let projectID: UUID
        let projectFormatVersion: Int
        let bundle: FileIdentity
        let metadataSHA256: String
        let receiptDigest: String
        let manifest: [TreeEntry]
    }

    struct CleanupRecord: Codable, Equatable {
        enum Disposition: String, Codable {
            case abort
            case published
        }

        let schemaVersion: Int
        let transactionID: UUID
        let library: FileIdentity
        let container: FileIdentity
        let envelope: FileIdentity
        let originalEnvelopeLeaf: String
        let disposition: Disposition
        let transactionRecord: TransactionRecord
        let readyRecord: ReadyRecord?
        let expectedBundle: FileIdentity?
        let plannedFinalLeaf: String?
        let outerFiles: [TreeEntry]
        let bundleManifest: [TreeEntry]?
    }

    struct ValidatedInitialBundle {
        let metadata: ProjectMetadata
        let metadataSHA256: String
        let receiptDigest: String
        let manifest: [TreeEntry]
    }

    struct StableFileRead {
        let data: Data
        let status: stat
    }

    struct ProjectDirectoryName {
        let readablePrefix: String
        let digest: String
        let requiresDigest: Bool
    }

    static let projectBundleLeafMaximumUTF8Bytes = 240

    static let initialDirectoryPaths: Set<String> = [
        ".",
        "Originals",
        "Frames",
        "Frames/raw",
        "Frames/selected",
        "SfM",
        "SfM/colmap",
        "SfM/colmap/seed",
        "SfM/colmap/sparse",
        "Output",
        "Logs",
        "Training",
        "Training/checkpoints",
        "Training/checkpoints/msplat",
        "Training/msplat",
        "Training/msplat_dataset",
        "Training/msplat_dataset/images",
        "Training/msplat_dataset/sparse",
        "Training/msplat_dataset/sparse/0",
    ]

    static func transactionLeaf(for id: UUID) -> String {
        "txn-\(id.uuidString.lowercased())"
    }

    static func transactionID(from leaf: String) -> UUID? {
        let prefix: String
        if leaf.hasPrefix("txn-") {
            prefix = "txn-"
        } else if leaf.hasPrefix(".deleting-") {
            prefix = ".deleting-"
        } else {
            return nil
        }
        return UUID(uuidString: String(leaf.dropFirst(prefix.count)))
    }

    static func cleanupLeaf(for id: UUID) -> String {
        "\(cleanupPrefix)\(id.uuidString.lowercased())\(cleanupSuffix)"
    }

    static func cleanupTransactionID(from leaf: String) -> UUID? {
        guard leaf.hasPrefix(cleanupPrefix), leaf.hasSuffix(cleanupSuffix) else {
            return nil
        }
        return UUID(uuidString: String(
            leaf.dropFirst(cleanupPrefix.count).dropLast(cleanupSuffix.count)
        ))
    }

    static func projectBundleLeaf(for title: String, attempt: Int) -> String {
        let name = projectDirectoryName(for: title)
        let stem: String
        if attempt == 0 {
            stem = name.requiresDigest
                ? "\(name.readablePrefix)-\(name.digest)"
                : name.readablePrefix
        } else if attempt == 1, !name.requiresDigest {
            stem = "\(name.readablePrefix)-\(name.digest)"
        } else {
            let counter = name.requiresDigest ? attempt + 1 : attempt
            stem = "\(name.readablePrefix)-\(name.digest)-\(counter)"
        }
        let leaf = stem + ".easysplatproj"
        precondition(leaf.utf8.count <= projectBundleLeafMaximumUTF8Bytes)
        return leaf
    }

    static func projectDirectoryName(for title: String) -> ProjectDirectoryName {
        let normalizedTitle = title.precomposedStringWithCanonicalMapping
        var normalizedComponent = ""
        var separatorPending = false
        for scalar in normalizedTitle.unicodeScalars {
            let isUnsafeSeparator = scalar == "/" || scalar == "\\" || scalar == ":"
            let isSpacing = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if isUnsafeSeparator || isSpacing {
                if !normalizedComponent.isEmpty { separatorPending = true }
                continue
            }
            if separatorPending {
                normalizedComponent.append(" ")
                separatorPending = false
            }
            normalizedComponent.unicodeScalars.append(scalar)
        }
        normalizedComponent = normalizedComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedComponent.first == "." { normalizedComponent.removeFirst() }
        normalizedComponent = normalizedComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedComponent.isEmpty { normalizedComponent = "Project" }

        let maximumPrefixBytes = projectBundleLeafMaximumUTF8Bytes
            - ".easysplatproj".utf8.count
            - "-000000000000-999999".utf8.count
        var readablePrefix = utf8Prefix(normalizedComponent, maximumBytes: maximumPrefixBytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if readablePrefix.isEmpty { readablePrefix = "Project" }
        let normalizedBytes = Data(normalizedTitle.utf8)
        let digest = SHA256.hash(data: normalizedBytes)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return ProjectDirectoryName(
            readablePrefix: readablePrefix,
            digest: digest,
            requiresDigest: Data(normalizedComponent.utf8) != normalizedBytes
                || Data(readablePrefix.utf8) != Data(normalizedComponent.utf8)
        )
    }

    static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= maximumBytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result
    }

    static func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return descriptor
    }

    static func canonicalExistingDirectoryURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw posixError(errno) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func openChildDirectory(parent: Int32, leaf: String) throws -> Int32 {
        guard safeLeaf(leaf) else { throw ProjectPublicationError.unsafeTransactionEnvelope }
        let descriptor = openat(
            parent,
            leaf,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw posixError(errno) }
        return descriptor
    }

    static func openPublicationLock(in containerDescriptor: Int32) throws -> Int32 {
        var descriptor: Int32 = -1
        var created = false
        for attempt in 0..<32 {
            descriptor = openat(
                containerDescriptor,
                lockLeaf,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                S_IRUSR | S_IWUSR
            )
            if descriptor >= 0 {
                created = true
                break
            }
            let createError = errno
            if createError == EINTR { continue }
            guard createError == EEXIST else { throw posixError(createError) }

            descriptor = openat(
                containerDescriptor,
                lockLeaf,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW_ANY
            )
            if descriptor >= 0 { break }
            let openError = errno
            if openError == EINTR { continue }
            if openError == ENOENT, attempt < 31 {
                _ = sched_yield()
                continue
            }
            throw posixError(openError)
        }
        guard descriptor >= 0 else { throw posixError(ENOENT) }
        do {
            if created, fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 {
                throw posixError(errno)
            }
            var opened = stat()
            var named = stat()
            guard fstat(descriptor, &opened) == 0,
                  fstatat(containerDescriptor, lockLeaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  sameRegularFile(opened, named),
                  opened.st_uid == getuid(),
                  opened.st_nlink == 1,
                  opened.st_mode & mode_t(0o7777) == mode_t(0o600) else {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
            if created {
                try syncFile(descriptor)
                try syncDirectory(containerDescriptor)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func lockOpenFileDescription(_ descriptor: Int32, waits: Bool) throws {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        let command = waits ? F_OFD_SETLKW : F_OFD_SETLK
        while true {
            let result = withUnsafeMutablePointer(to: &lock) {
                Darwin.fcntl(descriptor, command, $0)
            }
            if result == 0 { return }
            if errno == EINTR { continue }
            if !waits, errno == EAGAIN || errno == EACCES {
                throw ProjectPublicationError.publicationBusy
            }
            throw posixError(errno)
        }
    }

    static func unlockOpenFileDescription(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = withUnsafeMutablePointer(to: &lock) {
            Darwin.fcntl(descriptor, F_OFD_SETLK, $0)
        }
    }

    static func nameStillRefersToDescriptor(
        parent: Int32,
        leaf: String,
        descriptor: Int32,
        expectedType: mode_t
    ) throws -> Bool {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError(errno) }
        guard fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixError(errno)
        }
        return opened.st_mode & S_IFMT == expectedType
            && named.st_mode & S_IFMT == expectedType
            && opened.st_dev == named.st_dev
            && opened.st_ino == named.st_ino
            && opened.st_uid == named.st_uid
    }

    static func sameRegularFile(_ lhs: stat, _ rhs: stat) -> Bool {
        (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
    }

    static func safeLeaf(_ leaf: String) -> Bool {
        !leaf.isEmpty && leaf != "." && leaf != ".." && !leaf.contains("/") && !leaf.contains("\0")
    }

    static func posixError(
        _ code: Int32,
        function: StaticString = #function,
        line: UInt = #line
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(String(cString: strerror(code))) [\(function):\(line)]"
            ]
        )
    }

    static func syncFile(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError(errno)
        }
    }

    static func syncDirectory(_ descriptor: Int32) throws {
        try syncFile(descriptor)
    }

    static func fullSync(_ descriptor: Int32) throws {
        while fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            if errno == EINVAL || errno == ENOTSUP {
                try syncFile(descriptor)
                return
            }
            throw posixError(errno)
        }
    }
}

private extension ProjectPublicationTransaction {
    static func writeInitialRecord(_ record: TransactionRecord, in directory: Int32) throws {
        let data = try encode(record)
        try writePrivateFileExclusively(data, leaf: recordLeaf, in: directory)
    }

    static func replaceRecord(
        _ record: TransactionRecord,
        in directory: Int32,
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        _ = try requirePrivateRegularFile(
            parent: directory,
            leaf: recordLeaf,
            maximumBytes: maximumRecordBytes
        )
        try removeKnownTemporaryFile(recordTemporaryLeaf, in: directory)
        let data = try encode(record)
        try writePrivateFileExclusively(data, leaf: recordTemporaryLeaf, in: directory)
        try syncDirectory(directory)
        try beforeCommit?()
        guard renameatx_np(
            directory,
            recordTemporaryLeaf,
            directory,
            recordLeaf,
            UInt32(RENAME_NOFOLLOW_ANY)
        ) == 0 else {
            let code = errno
            try? removeKnownTemporaryFile(recordTemporaryLeaf, in: directory)
            throw posixError(code)
        }
        try syncDirectory(directory)
    }

    static func writeReadyRecord(_ ready: ReadyRecord, in directory: Int32) throws {
        try removeKnownTemporaryFile(readyTemporaryLeaf, in: directory)
        let data = try encode(ready)
        try writePrivateFileExclusively(data, leaf: readyTemporaryLeaf, in: directory)
        guard renameatx_np(
            directory,
            readyTemporaryLeaf,
            directory,
            readyLeaf,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        ) == 0 else {
            let code = errno
            try? removeKnownTemporaryFile(readyTemporaryLeaf, in: directory)
            throw posixError(code)
        }
        try syncDirectory(directory)
    }

    static func readTransactionRecord(
        descriptor: Int32,
        leaf: String = recordLeaf
    ) throws -> TransactionRecord {
        let data = try readPrivateFile(
            parent: descriptor,
            leaf: leaf,
            maximumBytes: maximumRecordBytes
        )
        let record = try JSONDecoder().decode(TransactionRecord.self, from: data)
        guard record.schemaVersion == transactionSchemaVersion,
              ProjectMetadataStore.acceptedFormatVersions.contains(record.projectFormatVersion),
              record.title.utf8.count <= 1_048_576,
              transactionRecordIsStructurallyValid(record) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        return record
    }

    static func recoverTransactionRecord(descriptor: Int32) throws -> TransactionRecord {
        let current = try readTransactionRecord(descriptor: descriptor)
        var temporaryStatus = stat()
        guard fstatat(
            descriptor,
            recordTemporaryLeaf,
            &temporaryStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return current }
            throw posixError(errno)
        }
        let candidate = try readTransactionRecord(
            descriptor: descriptor,
            leaf: recordTemporaryLeaf
        )
        guard transactionRecord(candidate, isValidSuccessorOf: current) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        guard renameatx_np(
            descriptor,
            recordTemporaryLeaf,
            descriptor,
            recordLeaf,
            UInt32(RENAME_NOFOLLOW_ANY)
        ) == 0 else {
            throw posixError(errno)
        }
        try syncDirectory(descriptor)
        return candidate
    }

    static func transactionRecordIsStructurallyValid(_ record: TransactionRecord) -> Bool {
        let hasMetadataEvidence = record.validatedMetadataSHA256.map(validSHA256) == true
            && record.validatedReceiptDigest.map(validSHA256) == true
        let hasNoMetadataEvidence = record.validatedMetadataSHA256 == nil
            && record.validatedReceiptDigest == nil
        let hasManifestEvidence = record.validatedManifestDigest.map(validSHA256) == true
        switch record.phase {
        case .recorded:
            return record.bundle == nil
                && record.ownedBundleManifest == nil
                && record.plannedFinalLeaf == nil
                && hasNoMetadataEvidence
                && record.validatedManifestDigest == nil
        case .building:
            guard let bundle = record.bundle,
                  let ownedBundleManifest = record.ownedBundleManifest,
                  cleanupManifest(ownedBundleManifest, isBoundTo: bundle) else {
                return false
            }
            return record.plannedFinalLeaf == nil
                && (hasNoMetadataEvidence || hasMetadataEvidence)
                && (record.validatedManifestDigest == nil
                    || (hasMetadataEvidence && hasManifestEvidence))
        case .ready:
            guard let bundle = record.bundle,
                  let ownedBundleManifest = record.ownedBundleManifest,
                  cleanupManifest(ownedBundleManifest, isBoundTo: bundle) else {
                return false
            }
            return record.plannedFinalLeaf == nil
                && hasMetadataEvidence
                && hasManifestEvidence
        case .publishing, .published:
            guard let bundle = record.bundle,
                  let ownedBundleManifest = record.ownedBundleManifest,
                  cleanupManifest(ownedBundleManifest, isBoundTo: bundle) else {
                return false
            }
            return record.plannedFinalLeaf.map(safeVisibleProjectLeaf) == true
                && hasMetadataEvidence
                && hasManifestEvidence
        }
    }

    static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    static func transactionRecord(
        _ candidate: TransactionRecord,
        isValidSuccessorOf current: TransactionRecord
    ) -> Bool {
        guard candidate.schemaVersion == current.schemaVersion,
              candidate.transactionID == current.transactionID,
              candidate.projectID == current.projectID,
              candidate.projectFormatVersion == current.projectFormatVersion,
              candidate.title == current.title,
              candidate.library == current.library,
              candidate.envelope == current.envelope,
              candidate.bundle == current.bundle || current.bundle == nil,
              ownedBundleManifest(
                candidate.ownedBundleManifest,
                isValidSuccessorOf: current.ownedBundleManifest
              ),
              candidate.validatedMetadataSHA256 == current.validatedMetadataSHA256
                || current.validatedMetadataSHA256 == nil,
              candidate.validatedReceiptDigest == current.validatedReceiptDigest
                || current.validatedReceiptDigest == nil,
              candidate.validatedManifestDigest == current.validatedManifestDigest
                || current.validatedManifestDigest == nil else {
            return false
        }
        switch (current.phase, candidate.phase) {
        case (.recorded, .building),
             (.building, .building),
             (.building, .ready),
             (.ready, .publishing),
             (.publishing, .publishing),
             (.publishing, .published):
            return true
        default:
            return false
        }
    }

    static func ownedBundleManifest(
        _ candidate: [TreeEntry]?,
        isValidSuccessorOf current: [TreeEntry]?
    ) -> Bool {
        guard let current else { return candidate != nil }
        guard let candidate else { return false }
        let candidateByPath = Dictionary(
            uniqueKeysWithValues: candidate.map { ($0.relativePath, $0) }
        )
        return current.allSatisfy { persisted in
            guard let successor = candidateByPath[persisted.relativePath] else {
                return false
            }
            // Adding a child changes ancestor directory link counts on Darwin.
            // Bind stable directory identity while retaining every byte of file
            // identity evidence and permit only structurally validated additions.
            return cleanupTreeEntry(successor, matchesPersisted: persisted)
        }
    }

    static func readReadyRecord(descriptor: Int32) throws -> ReadyRecord {
        let data = try readPrivateFile(
            parent: descriptor,
            leaf: readyLeaf,
            maximumBytes: maximumRecordBytes
        )
        let ready = try JSONDecoder().decode(ReadyRecord.self, from: data)
        guard ready.schemaVersion == readySchemaVersion,
              ProjectMetadataStore.acceptedFormatVersions.contains(ready.projectFormatVersion),
              ready.manifest.count <= 20_050 else {
            throw ProjectPublicationError.invalidReadinessReceipt
        }
        return ready
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumRecordBytes else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        return data
    }

    @discardableResult
    static func requirePrivateRegularFile(
        parent: Int32,
        leaf: String,
        maximumBytes: Int
    ) throws -> stat {
        guard safeLeaf(leaf) else { throw ProjectPublicationError.unsafeTransactionEnvelope }
        let descriptor = openat(
            parent,
            leaf,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameRegularFile(opened, named),
              opened.st_uid == getuid(),
              opened.st_nlink == 1,
              opened.st_mode & mode_t(0o7777) == mode_t(0o600),
              opened.st_size >= 0,
              opened.st_size <= off_t(maximumBytes) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        return opened
    }

    static func readPrivateFile(parent: Int32, leaf: String, maximumBytes: Int) throws -> Data {
        let initial = try requirePrivateRegularFile(
            parent: parent,
            leaf: leaf,
            maximumBytes: maximumBytes
        )
        let descriptor = openat(
            parent,
            leaf,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(descriptor) }
        var data = Data()
        data.reserveCapacity(Int(initial.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        if buffer.isEmpty { buffer = [0] }
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError(errno) }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw ProjectPublicationError.unsafeTransactionEnvelope
            }
            data.append(contentsOf: buffer[0..<count])
        }
        var final = stat()
        var named = stat()
        guard fstat(descriptor, &final) == 0,
              fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameRegularFile(initial, final),
              sameRegularFile(final, named),
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              data.count == Int(initial.st_size) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        return data
    }

    static func writePrivateFileExclusively(_ data: Data, leaf: String, in directory: Int32) throws {
        let descriptor = openat(
            directory,
            leaf,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError(errno) }
        var removesOnFailure = true
        defer {
            if removesOnFailure {
                var opened = stat()
                var named = stat()
                if fstat(descriptor, &opened) == 0,
                   fstatat(directory, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   sameRegularFile(opened, named) {
                    _ = unlinkat(directory, leaf, 0)
                }
            }
            Darwin.close(descriptor)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError(errno) }
                offset += count
            }
        }
        try syncFile(descriptor)
        try fullSync(descriptor)
        removesOnFailure = false
    }

    static func removeKnownTemporaryFile(_ leaf: String, in directory: Int32) throws {
        var status = stat()
        if fstatat(directory, leaf, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw posixError(errno)
        }
        _ = try requirePrivateRegularFile(
            parent: directory,
            leaf: leaf,
            maximumBytes: maximumRecordBytes
        )
        guard unlinkat(directory, leaf, 0) == 0 else { throw posixError(errno) }
        try syncDirectory(directory)
    }
}

private extension ProjectPublicationTransaction {
    static func validateCompleteInitialBundle(
        at bundleURL: URL,
        expectedProjectID: UUID,
        expectedTitle: String,
        expectedMetadata: ProjectMetadata?,
        expectedBundle: FileIdentity,
        normalizesPermissions: Bool,
        hashesInputContents: Bool,
        afterMetadataValidation: ((String, String) throws -> Void)? = nil,
        afterInputHash: (() throws -> Void)? = nil
    ) throws -> ValidatedInitialBundle {
        let rootDescriptor = try openAbsoluteDirectory(bundleURL)
        defer { Darwin.close(rootDescriptor) }
        let rootParentDescriptor = try openAbsoluteDirectory(bundleURL.deletingLastPathComponent())
        defer { Darwin.close(rootParentDescriptor) }
        guard try FileIdentity.read(from: rootDescriptor, expectedType: S_IFDIR) == expectedBundle,
              try nameStillRefersToDescriptor(
                  parent: rootParentDescriptor,
                  leaf: bundleURL.lastPathComponent,
                  descriptor: rootDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        let paths = ProjectPaths(root: bundleURL)
        let metadataRead = try descriptorBoundRead(
            parentDescriptor: rootDescriptor,
            leaf: "project.json",
            maximumBytes: 8 * 1_024 * 1_024,
            normalizesPermissions: normalizesPermissions
        )
        let metadata: ProjectMetadata
        do {
            metadata = try ProjectMetadataStore.decodeValidatedMetadataSnapshot(
                metadataRead.data,
                metadataURL: paths.metadataURL
            )
        } catch {
            throw ProjectPublicationError.invalidInitialMetadata
        }
        try validateInitialMetadata(
            metadata,
            expectedProjectID: expectedProjectID,
            expectedTitle: expectedTitle,
            expectedMetadata: expectedMetadata
        )
        let photoSelectionLease: PhotoSelectionArtifactLeaseEvidence?
        do {
            try PhotoInputReceiptValidator.validateMetadata(metadata, paths: paths)
            photoSelectionLease = try PhotoSelectionProjection.loadProjectBoundVerified(
                metadata: metadata,
                paths: paths
            ).leaseEvidence
        } catch {
            throw ProjectPublicationError.invalidInitialMetadata
        }
        let metadataSHA256 = sha256(metadataRead.data)
        let receiptDigest = inputReceiptDigest(metadata)
        let expectedFiles = try expectedInitialFiles(
            metadata: metadata,
            metadataSHA256: metadataSHA256,
            metadataStatus: metadataRead.status,
            photoSelectionLease: photoSelectionLease
        )
        let protectedDirectoryIdentities: [String: ProtectedInitialDirectoryIdentity]
        if let photoSelectionLease {
            protectedDirectoryIdentities = [
                ".": ProtectedInitialDirectoryIdentity(photoSelectionLease.projectRoot),
                "Frames": ProtectedInitialDirectoryIdentity(
                    photoSelectionLease.framesDirectory
                ),
            ]
        } else {
            protectedDirectoryIdentities = [:]
        }
        let expectedDirectories = metadata.input.hasPhotos
            ? initialDirectoryPaths.union(["Originals/Photos"])
            : initialDirectoryPaths
        let normalizedBeforeMetadataCheckpoint = afterMetadataValidation != nil
            && normalizesPermissions
        if normalizedBeforeMetadataCheckpoint {
            _ = try captureInitialTree(
                rootDescriptor: rootDescriptor,
                expectedBundle: expectedBundle,
                expectedDirectories: expectedDirectories,
                expectedFiles: expectedFiles,
                protectedDirectoryIdentities: protectedDirectoryIdentities,
                normalizesPermissions: true,
                hashesInputContents: false,
                afterInputHash: nil
            )
        }
        try afterMetadataValidation?(metadataSHA256, receiptDigest)
        let manifest = try captureInitialTree(
            rootDescriptor: rootDescriptor,
            expectedBundle: expectedBundle,
            expectedDirectories: expectedDirectories,
            expectedFiles: expectedFiles,
            protectedDirectoryIdentities: protectedDirectoryIdentities,
            normalizesPermissions: normalizedBeforeMetadataCheckpoint
                ? false
                : normalizesPermissions,
            hashesInputContents: hashesInputContents,
            afterInputHash: afterInputHash
        )
        return ValidatedInitialBundle(
            metadata: metadata,
            metadataSHA256: metadataSHA256,
            receiptDigest: receiptDigest,
            manifest: manifest
        )
    }

    static func validateInitialMetadata(
        _ metadata: ProjectMetadata,
        expectedProjectID: UUID,
        expectedTitle: String,
        expectedMetadata: ProjectMetadata?
    ) throws {
        guard ProjectMetadataStore.acceptedFormatVersions.contains(metadata.formatVersion),
              metadata.id == expectedProjectID,
              metadata.title == expectedTitle,
              metadata.title.utf8.count <= 1_048_576,
              metadata.resolvedRunPlan != nil,
              metadata.state.stage == .importInput,
              metadata.state.lastError == nil,
              metadata.lastRunStartedAt != nil,
              metadata.input.hasVideos || metadata.input.hasPhotos,
              metadata.videoInputReceipts?.isEmpty == false || metadata.photoInputReceipts?.isEmpty == false,
              metadata.trainingMemoryRetryBudgetBytes == nil,
              metadata.geometryRecovery == nil,
              metadata.checkpoint == nil,
              metadata.stageTimings?.isEmpty != false,
              metadata.lastFailureAt == nil else {
            throw ProjectPublicationError.invalidInitialMetadata
        }
        if let expectedMetadata {
            guard try canonicalInitialMetadataData(expectedMetadata)
                == canonicalInitialMetadataData(metadata) else {
                throw ProjectPublicationError.invalidInitialMetadata
            }
        }
    }

    static func canonicalInitialMetadataData(_ metadata: ProjectMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(metadata)
    }

    static func expectedInitialFiles(
        metadata: ProjectMetadata,
        metadataSHA256: String,
        metadataStatus: stat,
        photoSelectionLease: PhotoSelectionArtifactLeaseEvidence?
    ) throws -> [String: (byteCount: Int64?, sha256: String, expectedEntry: TreeEntry?)] {
        var files: [String: (byteCount: Int64?, sha256: String, expectedEntry: TreeEntry?)] = [
            "project.json": (
                nil,
                metadataSHA256,
                TreeEntry(
                    relativePath: "project.json",
                    status: metadataStatus,
                    kind: .file,
                    sha256: metadataSHA256
                )
            )
        ]
        for receipt in metadata.videoInputReceipts ?? [] {
            guard files[receipt.projectRelativePath] == nil else {
                throw ProjectPublicationError.invalidInitialMetadata
            }
            files[receipt.projectRelativePath] = (receipt.byteCount, receipt.sha256, nil)
            guard files[receipt.analysisArtifactPath] == nil else {
                throw ProjectPublicationError.invalidInitialMetadata
            }
            files[receipt.analysisArtifactPath] = (
                receipt.analysisArtifactByteCount,
                receipt.analysisArtifactSHA256,
                nil
            )
        }
        for receipt in metadata.photoInputReceipts ?? [] {
            guard files[receipt.projectRelativePath] == nil else {
                throw ProjectPublicationError.invalidInitialMetadata
            }
            files[receipt.projectRelativePath] = (receipt.byteCount, receipt.sha256, nil)
        }
        if let receipt = metadata.photoSelectionReceipt {
            guard let photoSelectionLease,
                  receipt.projectRelativePath == PhotoSelectionReceipt.projectRelativePath,
                  photoSelectionLease.byteCount == receipt.byteCount,
                  photoSelectionLease.sha256 == receipt.sha256,
                  files[receipt.projectRelativePath] == nil else {
                throw ProjectPublicationError.invalidInitialMetadata
            }
            files[receipt.projectRelativePath] = (
                receipt.byteCount,
                receipt.sha256,
                TreeEntry(
                    relativePath: receipt.projectRelativePath,
                    photoSelectionLease: photoSelectionLease
                )
            )
        } else if photoSelectionLease != nil {
            throw ProjectPublicationError.invalidInitialMetadata
        }
        return files
    }

    static func inputReceiptDigest(_ metadata: ProjectMetadata) -> String {
        var lines = ["EasySplat publication input receipts v3"]
        for (index, receipt) in (metadata.videoInputReceipts ?? []).enumerated() {
            lines.append(
                "video\t\(index)\t\(receipt.projectRelativePath)\t\(receipt.byteCount)\t\(receipt.sha256)\t\(receipt.clipGroupID)\t\(receipt.analysisPolicySHA256)\t\(receipt.analysisArtifactPath)\t\(receipt.analysisArtifactByteCount)\t\(receipt.analysisArtifactSHA256)"
            )
        }
        for (index, receipt) in (metadata.photoInputReceipts ?? []).enumerated() {
            lines.append(
                "photo\t\(index)\t\(receipt.projectRelativePath)\t\(receipt.byteCount)\t\(receipt.sha256)\t\(receipt.source.sha256)\t\(receipt.retainedRank)"
            )
        }
        if let receipt = metadata.photoSelectionReceipt {
            lines.append(
                "photo-selection\t\(receipt.schemaVersion)\t\(receipt.projectRelativePath)\t\(receipt.byteCount)\t\(receipt.sha256)\t\(receipt.artifactSchemaVersion)\t\(receipt.analysisRecipeVersion)\t\(receipt.analysisRecipeSHA256)\t\(receipt.selectorPolicyVersion)\t\(receipt.selectorPolicySHA256)"
            )
        }
        return sha256(Data(lines.joined(separator: "\n").utf8))
    }

    static func captureInitialTree(
        rootDescriptor: Int32,
        expectedBundle: FileIdentity,
        expectedDirectories: Set<String>,
        expectedFiles: [String: (byteCount: Int64?, sha256: String, expectedEntry: TreeEntry?)],
        protectedDirectoryIdentities: [String: ProtectedInitialDirectoryIdentity],
        normalizesPermissions: Bool,
        hashesInputContents: Bool,
        afterInputHash: (() throws -> Void)?
    ) throws -> [TreeEntry] {
        var entries: [TreeEntry] = []
        var actualDirectories = Set<String>()
        var actualFiles = Set<String>()

        func captureFile(
            parentDescriptor: Int32,
            leaf: String,
            relativePath: String,
            expected: (byteCount: Int64?, sha256: String, expectedEntry: TreeEntry?)
        ) throws -> TreeEntry {
            let descriptor = leaf.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
                )
            }
            guard descriptor >= 0 else { throw posixError(errno) }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { throw posixError(errno) }
            if normalizesPermissions,
               opened.st_mode & mode_t(0o7777) != mode_t(0o600) {
                guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                      fstat(descriptor, &opened) == 0 else {
                    throw posixError(errno)
                }
            }
            var rebound = stat()
            guard leaf.withCString({
                fstatat(parentDescriptor, $0, &rebound, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            sameRegularFile(opened, rebound),
            opened.st_uid == getuid(),
            opened.st_nlink == 1,
            opened.st_mode & mode_t(0o7777) == mode_t(0o600),
            UInt64(opened.st_dev) == expectedBundle.device,
            expected.byteCount == nil || Int64(opened.st_size) == expected.byteCount else {
                throw ProjectPublicationError.unsafePendingBundle
            }
            if let expectedEntry = expected.expectedEntry,
               !expectedEntry.matches(opened) {
                throw ProjectPublicationError.pendingBundleChanged
            }
            let recordedSHA256: String
            if hashesInputContents, expected.byteCount != nil {
                let computed = try descriptorBoundSHA256(
                    descriptor: descriptor,
                    parentDescriptor: parentDescriptor,
                    leaf: leaf,
                    expected: opened
                )
                guard computed == expected.sha256 else {
                    throw ProjectPublicationError.pendingBundleChanged
                }
                recordedSHA256 = computed
            } else {
                recordedSHA256 = expected.sha256
            }
            return TreeEntry(
                relativePath: relativePath,
                status: opened,
                kind: .file,
                sha256: recordedSHA256
            )
        }

        func captureDirectory(
            descriptor: Int32,
            relativePath: String,
            expectedObservedStatus: stat?
        ) throws {
            guard expectedDirectories.contains(relativePath) else {
                throw ProjectPublicationError.unsupportedFilesystemEntry(relativePath)
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { throw posixError(errno) }
            if let protectedIdentity = protectedDirectoryIdentities[relativePath],
               !protectedIdentity.matches(opened) {
                throw ProjectPublicationError.pendingBundleChanged
            }
            if let expectedObservedStatus {
                guard (opened.st_mode & S_IFMT) == S_IFDIR,
                      (expectedObservedStatus.st_mode & S_IFMT) == S_IFDIR,
                      opened.st_dev == expectedObservedStatus.st_dev,
                      opened.st_ino == expectedObservedStatus.st_ino,
                      opened.st_uid == expectedObservedStatus.st_uid,
                      opened.st_nlink == expectedObservedStatus.st_nlink else {
                    throw ProjectPublicationError.transactionIdentityChanged
                }
            }
            if normalizesPermissions,
               opened.st_mode & mode_t(0o7777) != mode_t(0o700) {
                guard fchmod(descriptor, S_IRWXU) == 0,
                      fstat(descriptor, &opened) == 0 else {
                    throw posixError(errno)
                }
            }
            guard (opened.st_mode & S_IFMT) == S_IFDIR,
                  opened.st_uid == getuid(),
                  opened.st_mode & mode_t(0o7777) == mode_t(0o700),
                  UInt64(opened.st_dev) == expectedBundle.device else {
                throw ProjectPublicationError.unsafePendingBundle
            }
            actualDirectories.insert(relativePath)
            entries.append(TreeEntry(
                relativePath: relativePath,
                status: opened,
                kind: .directory,
                sha256: nil
            ))

            for leaf in try directoryLeafNames(descriptor: descriptor, maximumCount: 20_050) {
                let childRelative = relativePath == "."
                    ? leaf
                    : "\(relativePath)/\(leaf)"
                var status = stat()
                guard leaf.withCString({
                    fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                }) == 0 else { throw posixError(errno) }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    do {
                        let childDescriptor = try openChildDirectory(parent: descriptor, leaf: leaf)
                        defer { Darwin.close(childDescriptor) }
                        try captureDirectory(
                            descriptor: childDescriptor,
                            relativePath: childRelative,
                            expectedObservedStatus: status
                        )
                    }
                case S_IFREG:
                    guard let expected = expectedFiles[childRelative] else {
                        throw ProjectPublicationError.unsupportedFilesystemEntry(childRelative)
                    }
                    actualFiles.insert(childRelative)
                    entries.append(try captureFile(
                        parentDescriptor: descriptor,
                        leaf: leaf,
                        relativePath: childRelative,
                        expected: expected
                    ))
                default:
                    throw ProjectPublicationError.unsupportedFilesystemEntry(childRelative)
                }
            }
        }

        try captureDirectory(
            descriptor: rootDescriptor,
            relativePath: ".",
            expectedObservedStatus: nil
        )
        guard actualDirectories == expectedDirectories,
              actualFiles == Set(expectedFiles.keys),
              entries.first(where: { $0.relativePath == "." }).map({
                  $0.device == expectedBundle.device
                      && $0.inode == expectedBundle.inode
                      && $0.owner == expectedBundle.owner
              }) == true else {
            throw ProjectPublicationError.unsafePendingBundle
        }
        if hashesInputContents { try afterInputHash?() }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    static func directoryLeafNames(
        descriptor: Int32,
        maximumCount: Int
    ) throws -> [String] {
        // `dup` shares the directory cursor on Darwin. Opening `.` creates a new
        // open-file description so repeated exact-set checks cannot see a stale EOF.
        let enumerationDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard enumerationDescriptor >= 0, let stream = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
            throw posixError(errno)
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                guard names.count < maximumCount else {
                    throw ProjectPublicationError.unsafePendingBundle
                }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw posixError(errno) }
        return names.sorted()
    }

    static func descriptorBoundSHA256(
        descriptor: Int32,
        parentDescriptor: Int32,
        leaf: String,
        expected: stat
    ) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw posixError(errno) }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError(errno) }
            if count == 0 { break }
            total += Int64(count)
            guard total <= Int64(expected.st_size) else {
                throw ProjectPublicationError.pendingBundleChanged
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var final = stat()
        var rebound = stat()
        guard fstat(descriptor, &final) == 0,
              leaf.withCString({
                  fstatat(parentDescriptor, $0, &rebound, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              sameStableRegularFile(expected, final),
              sameStableRegularFile(final, rebound),
              total == Int64(expected.st_size) else {
            throw ProjectPublicationError.pendingBundleChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sameStableRegularFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameRegularFile(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func syncInitialBundle(
        manifest: [TreeEntry],
        rootDescriptor: Int32
    ) throws {
        for entry in manifest where entry.kind == .file {
            do {
                let descriptor = try openManifestEntry(
                    rootDescriptor: rootDescriptor,
                    relativePath: entry.relativePath,
                    kind: .file
                )
                defer { Darwin.close(descriptor) }
                var status = stat()
                guard fstat(descriptor, &status) == 0, entry.matches(status) else {
                    throw ProjectPublicationError.pendingBundleChanged
                }
                try syncFile(descriptor)
            }
        }
        let directories = manifest
            .filter { $0.kind == .directory && $0.relativePath != "." }
            .sorted {
                $0.relativePath.split(separator: "/").count
                    > $1.relativePath.split(separator: "/").count
            }
        for entry in directories {
            do {
                let descriptor = try openManifestEntry(
                    rootDescriptor: rootDescriptor,
                    relativePath: entry.relativePath,
                    kind: .directory
                )
                defer { Darwin.close(descriptor) }
                var status = stat()
                guard fstat(descriptor, &status) == 0, entry.matches(status) else {
                    throw ProjectPublicationError.pendingBundleChanged
                }
                try syncDirectory(descriptor)
            }
        }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              manifest.first(where: { $0.relativePath == "." })?.matches(rootStatus) == true else {
            throw ProjectPublicationError.pendingBundleChanged
        }
        try syncDirectory(rootDescriptor)
        try fullSync(rootDescriptor)
    }

    static func normalizeOwnedDirectoryPermissions(
        manifest: [TreeEntry],
        rootDescriptor: Int32
    ) throws {
        for entry in manifest where entry.kind == .directory {
            let descriptor: Int32
            if entry.relativePath == "." {
                descriptor = openat(
                    rootDescriptor,
                    ".",
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                )
                guard descriptor >= 0 else { throw posixError(errno) }
            } else {
                descriptor = try openManifestEntry(
                    rootDescriptor: rootDescriptor,
                    relativePath: entry.relativePath,
                    kind: .directory
                )
            }
            defer { Darwin.close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  entry.matchesIdentity(before) else {
                throw ProjectPublicationError.pendingBundleChanged
            }
            if before.st_mode & mode_t(0o7777) != mode_t(0o700) {
                guard fchmod(descriptor, S_IRWXU) == 0 else {
                    throw posixError(errno)
                }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  (after.st_mode & S_IFMT) == S_IFDIR,
                  after.st_dev == before.st_dev,
                  after.st_ino == before.st_ino,
                  after.st_uid == before.st_uid,
                  after.st_mode & mode_t(0o7777) == mode_t(0o700) else {
                throw ProjectPublicationError.pendingBundleChanged
            }
        }
    }

    static func openManifestEntry(
        rootDescriptor: Int32,
        relativePath: String,
        kind: TreeEntry.Kind
    ) throws -> Int32 {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty, components.allSatisfy(safeLeaf) else {
            throw ProjectPublicationError.unsafePendingBundle
        }
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw posixError(errno) }
        for (index, component) in components.enumerated() {
            let isFinal = index == components.count - 1
            let flags: Int32 = if isFinal, kind == .file {
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
            } else {
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            }
            let next = component.withCString { openat(current, $0, flags) }
            let openError = errno
            Darwin.close(current)
            guard next >= 0 else { throw posixError(openError) }
            current = next
        }
        return current
    }

    static func validateReadyBundleWithoutRehash(
        at bundleURL: URL,
        expectedTransactionID: UUID,
        expectedProjectID: UUID,
        expectedTitle: String,
        expectedBundle: FileIdentity,
        ready: ReadyRecord
    ) throws {
        guard ready.schemaVersion == readySchemaVersion,
              ready.transactionID == expectedTransactionID,
              ready.projectID == expectedProjectID,
              ProjectMetadataStore.acceptedFormatVersions.contains(ready.projectFormatVersion),
              ready.bundle == expectedBundle else {
            throw ProjectPublicationError.invalidReadinessReceipt
        }
        let validated = try validateCompleteInitialBundle(
            at: bundleURL,
            expectedProjectID: expectedProjectID,
            expectedTitle: expectedTitle,
            expectedMetadata: nil,
            expectedBundle: expectedBundle,
            normalizesPermissions: false,
            hashesInputContents: false
        )
        guard validated.metadataSHA256 == ready.metadataSHA256,
              validated.receiptDigest == ready.receiptDigest else {
            throw ProjectPublicationError.pendingBundleChanged
        }
        guard validated.manifest == ready.manifest else {
            throw ProjectPublicationError.pendingBundleEntryChanged(
                firstManifestDifference(validated.manifest, ready.manifest)
            )
        }
    }

    static func validateVisiblePublishedBundle(
        at bundleURL: URL,
        expectedTransactionID: UUID,
        expectedProjectID: UUID,
        expectedTitle: String,
        expectedBundle: FileIdentity,
        ready: ReadyRecord
    ) throws {
        guard try FileIdentity.read(at: bundleURL, expectedType: S_IFDIR) == expectedBundle else {
            throw ProjectPublicationError.publishedBundleIdentityChanged
        }
        try validateReadyBundleWithoutRehash(
            at: bundleURL,
            expectedTransactionID: expectedTransactionID,
            expectedProjectID: expectedProjectID,
            expectedTitle: expectedTitle,
            expectedBundle: expectedBundle,
            ready: ready
        )
    }

    static func descriptorBoundRead(
        parentDescriptor: Int32,
        leaf: String,
        maximumBytes: Int,
        normalizesPermissions: Bool
    ) throws -> StableFileRead {
        guard safeLeaf(leaf) else { throw ProjectPublicationError.unsafePendingBundle }
        let descriptor = openat(
            parentDescriptor,
            leaf,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else { throw posixError(errno) }
        if normalizesPermissions,
           initial.st_mode & mode_t(0o7777) != mode_t(0o600) {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  fstat(descriptor, &initial) == 0 else {
                throw posixError(errno)
            }
        }
        guard (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_uid == getuid(),
              initial.st_nlink == 1,
              initial.st_mode & mode_t(0o7777) == mode_t(0o600),
              initial.st_size >= 0,
              initial.st_size <= off_t(maximumBytes) else {
            throw ProjectPublicationError.unsafePendingBundle
        }
        var data = Data()
        data.reserveCapacity(Int(initial.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError(errno) }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw ProjectPublicationError.unsafePendingBundle
            }
            data.append(contentsOf: buffer[0..<count])
        }
        var final = stat()
        var rebound = stat()
        guard fstat(descriptor, &final) == 0,
              fstatat(parentDescriptor, leaf, &rebound, AT_SYMLINK_NOFOLLOW) == 0,
              sameRegularFile(initial, final),
              sameRegularFile(final, rebound),
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              data.count == Int(initial.st_size) else {
            throw ProjectPublicationError.pendingBundleChanged
        }
        return StableFileRead(data: data, status: final)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func manifestDigest(_ manifest: [TreeEntry]) throws -> String {
        sha256(try encode(manifest))
    }

    static func firstManifestDifference(_ current: [TreeEntry], _ expected: [TreeEntry]) -> String {
        guard current.count == expected.count else {
            return "entry count \(current.count), expected \(expected.count)"
        }
        for (currentEntry, expectedEntry) in zip(current, expected) where currentEntry != expectedEntry {
            return "\(currentEntry.relativePath) current=\(currentEntry) expected=\(expectedEntry)"
        }
        return "unknown manifest difference"
    }
}

private extension ProjectPublicationTransaction {
    static func validateDemonstrablyOwnedIncompleteBundle(
        at root: URL,
        expectedBundle: FileIdentity,
        expectedManifest: [TreeEntry]
    ) throws {
        let rootDescriptor = try openAbsoluteDirectory(root)
        defer { Darwin.close(rootDescriptor) }
        let parentDescriptor = try openAbsoluteDirectory(root.deletingLastPathComponent())
        defer { Darwin.close(parentDescriptor) }
        guard try FileIdentity.read(from: rootDescriptor, expectedType: S_IFDIR) == expectedBundle,
              try nameStillRefersToDescriptor(
                  parent: parentDescriptor,
                  leaf: root.lastPathComponent,
                  descriptor: rootDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        let currentManifest = try captureDemonstrablyOwnedIncompleteBundle(
            rootDescriptor: rootDescriptor,
            expectedBundle: expectedBundle
        )
        guard currentManifest == expectedManifest else {
            throw ProjectPublicationError.pendingBundleEntryChanged(
                firstManifestDifference(currentManifest, expectedManifest)
            )
        }
    }

    static func captureDemonstrablyOwnedIncompleteBundle(
        rootDescriptor: Int32,
        expectedBundle: FileIdentity
    ) throws -> [TreeEntry] {
        let allowedDirectories = initialDirectoryPaths.union(["Originals/Photos"])
        var entries: [TreeEntry] = []

        func inspect(
            descriptor: Int32,
            relativePath: String,
            expectedObservedStatus: stat?
        ) throws {
            guard allowedDirectories.contains(relativePath) else {
                throw ProjectPublicationError.unsupportedFilesystemEntry(relativePath)
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  (opened.st_mode & S_IFMT) == S_IFDIR,
                  opened.st_uid == getuid(),
                  opened.st_mode & mode_t(0o022) == 0,
                  UInt64(opened.st_dev) == expectedBundle.device else {
                throw ProjectPublicationError.unsafePendingBundle
            }
            if let expectedObservedStatus {
                guard (expectedObservedStatus.st_mode & S_IFMT) == S_IFDIR,
                      opened.st_dev == expectedObservedStatus.st_dev,
                      opened.st_ino == expectedObservedStatus.st_ino,
                      opened.st_uid == expectedObservedStatus.st_uid else {
                    throw ProjectPublicationError.transactionIdentityChanged
                }
            }
            entries.append(TreeEntry(
                relativePath: relativePath,
                status: opened,
                kind: .directory,
                sha256: nil
            ))
            for leaf in try directoryLeafNames(descriptor: descriptor, maximumCount: 20_050) {
                let childRelative = relativePath == "."
                    ? leaf
                    : "\(relativePath)/\(leaf)"
                var childStatus = stat()
                guard leaf.withCString({
                    fstatat(descriptor, $0, &childStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0 else { throw posixError(errno) }
                switch childStatus.st_mode & S_IFMT {
                case S_IFDIR:
                    let childDescriptor = try openChildDirectory(parent: descriptor, leaf: leaf)
                    defer { Darwin.close(childDescriptor) }
                    try inspect(
                        descriptor: childDescriptor,
                        relativePath: childRelative,
                        expectedObservedStatus: childStatus
                    )
                case S_IFREG:
                    guard childRelative == "project.json"
                            || isControlledInitialArtifactRelativePath(childRelative),
                          childStatus.st_uid == getuid(),
                          childStatus.st_nlink == 1,
                          childStatus.st_mode & mode_t(0o022) == 0,
                          UInt64(childStatus.st_dev) == expectedBundle.device else {
                        throw ProjectPublicationError.unsupportedFilesystemEntry(childRelative)
                    }
                    let childDescriptor = leaf.withCString {
                        openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
                        )
                    }
                    guard childDescriptor >= 0 else { throw posixError(errno) }
                    defer { Darwin.close(childDescriptor) }
                    var rebound = stat()
                    guard fstat(childDescriptor, &rebound) == 0,
                          sameStableRegularFile(childStatus, rebound) else {
                        throw ProjectPublicationError.transactionIdentityChanged
                    }
                    entries.append(TreeEntry(
                        relativePath: childRelative,
                        status: rebound,
                        kind: .file,
                        sha256: nil
                    ))
                default:
                    throw ProjectPublicationError.unsupportedFilesystemEntry(childRelative)
                }
            }
        }
        try inspect(
            descriptor: rootDescriptor,
            relativePath: ".",
            expectedObservedStatus: nil
        )
        guard entries.first(where: { $0.relativePath == "." }).map({
            $0.device == expectedBundle.device
                && $0.inode == expectedBundle.inode
                && $0.owner == expectedBundle.owner
        }) == true else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    static func isControlledInitialArtifactRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.count == 2, components[0] == "Frames" {
            if components[1] == "photo_selection.json" {
                return true
            }
            return controlledIndexedLeaf(
                components[1],
                prefix: "video-analysis-",
                extensions: ["json"]
            )
        }
        if components.count == 2, components[0] == "Originals" {
            return controlledIndexedLeaf(components[1], prefix: "video-", extensions: nil)
        }
        if components.count == 3,
           components[0] == "Originals",
           components[1] == "Photos" {
            return controlledIndexedLeaf(
                components[2],
                prefix: "photo-",
                extensions: ["jpg", "png", "heic", "heif"]
            )
        }
        return false
    }

    static func controlledIndexedLeaf(
        _ leaf: String,
        prefix: String,
        extensions: Set<String>?
    ) -> Bool {
        guard leaf.hasPrefix(prefix),
              let dot = leaf.lastIndex(of: ".") else { return false }
        let digits = leaf[leaf.index(leaf.startIndex, offsetBy: prefix.count)..<dot]
        let fileExtension = String(leaf[leaf.index(after: dot)...])
        guard digits.utf8.count == 4,
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              !fileExtension.isEmpty,
              fileExtension.utf8.count <= 8,
              fileExtension.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...122).contains($0.value)
              }) else {
            return false
        }
        return extensions?.contains(fileExtension) ?? true
    }

}

private extension ProjectPublicationTransaction {
    static func reconcileLocked(
        baseURL: URL,
        baseDescriptor: Int32,
        baseIdentity: FileIdentity,
        containerDescriptor: Int32,
        containerIdentity: FileIdentity
    ) throws -> [ProjectPublicationReconciliationEvent] {
        let containerURL = baseURL.appendingPathComponent(containerName, isDirectory: true)
        let leaves = try directoryLeafNames(
            descriptor: containerDescriptor,
            maximumCount: 100_000
        )
        var events: [ProjectPublicationReconciliationEvent] = []
        var cleanupRecords: [UUID: CleanupRecord] = [:]
        let cleanupReceiptGroups = Dictionary(
            grouping: leaves.compactMap { leaf in
                cleanupTransactionID(from: leaf).map { ($0, leaf) }
            },
            by: { $0.0 }
        )
        let cleanupReceiptIDsPresent = Set(cleanupReceiptGroups.keys)
        let transactionLeafCounts = Dictionary(
            grouping: leaves.compactMap { leaf in
                transactionID(from: leaf).map { ($0, leaf) }
            },
            by: { $0.0 }
        ).mapValues(\.count)
        for leaf in leaves where cleanupTransactionID(from: leaf) != nil {
            let cleanupURL = containerURL.appendingPathComponent(leaf)
            do {
                let cleanup = try readCleanupRecord(
                    descriptor: containerDescriptor,
                    leaf: leaf
                )
                try validateCleanupRecordStructure(cleanup)
                guard cleanup.library == baseIdentity,
                      cleanup.container == containerIdentity,
                      cleanupReceiptGroups[cleanup.transactionID]?.count == 1,
                      cleanupRecords[cleanup.transactionID] == nil else {
                    throw ProjectPublicationError.unsafeTransactionContainer
                }
                cleanupRecords[cleanup.transactionID] = cleanup
            } catch {
                logger.warning(
                    "Preserving invalid project cleanup receipt at \(cleanupURL.path, privacy: .private): \(String(describing: error), privacy: .public)"
                )
                events.append(.preserved(cleanupURL, reason: error.localizedDescription))
            }
        }
        for leaf in leaves where leaf != lockLeaf && cleanupTransactionID(from: leaf) == nil {
            let envelopeURL = containerURL.appendingPathComponent(leaf, isDirectory: true)
            guard let leafTransactionID = transactionID(from: leaf) else {
                logger.warning("Preserving unknown project transaction entry at \(envelopeURL.path, privacy: .private)")
                events.append(.preserved(envelopeURL, reason: "unknown transaction entry"))
                continue
            }
            guard transactionLeafCounts[leafTransactionID] == 1 else {
                events.append(.preserved(
                    envelopeURL,
                    reason: "duplicate transaction identity"
                ))
                continue
            }
            do {
                let envelopeDescriptor = try openChildDirectory(
                    parent: containerDescriptor,
                    leaf: leaf
                )
                defer { Darwin.close(envelopeDescriptor) }
                let envelopeIdentity = try FileIdentity.read(
                    from: envelopeDescriptor,
                    expectedType: S_IFDIR
                )
                guard envelopeIdentity.owner == getuid(),
                      envelopeIdentity.permissions == 0o700,
                      envelopeIdentity.device == containerIdentity.device else {
                    throw ProjectPublicationError.unsafeTransactionEnvelope
                }
                let cleanupRecord = cleanupRecords[leafTransactionID]
                if cleanupReceiptIDsPresent.contains(leafTransactionID), cleanupRecord == nil {
                    throw ProjectPublicationError.unsafeTransactionEnvelope
                }
                if leaf.hasPrefix(".deleting-") || cleanupRecord != nil {
                    guard let cleanupRecord,
                          cleanupRecord.transactionID == leafTransactionID,
                          cleanupRecord.library == baseIdentity,
                          cleanupRecord.container == containerIdentity,
                          cleanupRecord.envelope == envelopeIdentity else {
                        throw ProjectPublicationError.unsafeTransactionEnvelope
                    }
                    try removeEnvelopeDescriptorRelative(
                        baseURL: baseURL,
                        baseDescriptor: baseDescriptor,
                        baseIdentity: baseIdentity,
                        containerDescriptor: containerDescriptor,
                        sourceLeaf: leaf,
                        envelopeDescriptor: envelopeDescriptor,
                        envelopeIdentity: envelopeIdentity,
                        disposition: cleanupRecord.disposition,
                        expectedBundle: cleanupRecord.expectedBundle
                    )
                    if cleanupRecord.disposition == .published,
                       let plannedLeaf = cleanupRecord.plannedFinalLeaf {
                        events.append(.cleanedPublished(
                            baseURL.appendingPathComponent(plannedLeaf, isDirectory: true)
                        ))
                    } else {
                        events.append(.removedIncomplete(envelopeURL))
                    }
                    continue
                }
                let record = try recoverTransactionRecord(descriptor: envelopeDescriptor)
                guard record.transactionID == leafTransactionID,
                      record.library == baseIdentity,
                      record.envelope == envelopeIdentity,
                      ProjectMetadataStore.acceptedFormatVersions.contains(record.projectFormatVersion) else {
                    throw ProjectPublicationError.unsafeTransactionEnvelope
                }

                var bundleStatus = stat()
                let bundleStatusResult = fstatat(
                    envelopeDescriptor,
                    bundleLeaf,
                    &bundleStatus,
                    AT_SYMLINK_NOFOLLOW
                )
                let bundleStatusError = bundleStatusResult == 0 ? 0 : errno
                if bundleStatusResult == 0 {
                    if record.phase == .recorded, record.bundle == nil {
                        // The durable record predates this name. Its current inode is
                        // therefore not proven to belong to the transaction.
                        throw ProjectPublicationError.transactionIdentityChanged
                    }
                    guard let expectedBundle = record.bundle,
                          let ownedBundleManifest = record.ownedBundleManifest,
                          (bundleStatus.st_mode & S_IFMT) == S_IFDIR,
                          FileIdentity(bundleStatus) == expectedBundle else {
                        throw ProjectPublicationError.transactionIdentityChanged
                    }
                    let bundleDescriptor = try openChildDirectory(
                        parent: envelopeDescriptor,
                        leaf: bundleLeaf
                    )
                    defer { Darwin.close(bundleDescriptor) }
                    let bundleURL = envelopeURL.appendingPathComponent(bundleLeaf, isDirectory: true)
                    try validateDemonstrablyOwnedIncompleteBundle(
                        at: bundleURL,
                        expectedBundle: expectedBundle,
                        expectedManifest: ownedBundleManifest
                    )
                    var readyStatus = stat()
                    let readyStatusResult = fstatat(
                        envelopeDescriptor,
                        readyLeaf,
                        &readyStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                    let readyStatusError = readyStatusResult == 0 ? 0 : errno
                    let hasReady = readyStatusResult == 0
                    if hasReady {
                        try removeKnownTemporaryFile(readyTemporaryLeaf, in: envelopeDescriptor)
                        let ready = try readReadyRecord(descriptor: envelopeDescriptor)
                        guard ready.transactionID == record.transactionID,
                              ready.projectID == record.projectID,
                              ready.bundle == expectedBundle,
                              ready.metadataSHA256 == record.validatedMetadataSHA256,
                              ready.receiptDigest == record.validatedReceiptDigest,
                              try manifestDigest(ready.manifest) == record.validatedManifestDigest else {
                            throw ProjectPublicationError.invalidReadinessReceipt
                        }
                        let validated = try validateCompleteInitialBundle(
                            at: bundleURL,
                            expectedProjectID: record.projectID,
                            expectedTitle: record.title,
                            expectedMetadata: nil,
                            expectedBundle: expectedBundle,
                            normalizesPermissions: false,
                            hashesInputContents: true
                        )
                        guard validated.metadataSHA256 == ready.metadataSHA256,
                              validated.receiptDigest == ready.receiptDigest,
                              validated.manifest == ready.manifest else {
                            throw ProjectPublicationError.invalidReadinessReceipt
                        }
                        let published = try publishRecoveredBundle(
                            baseURL: baseURL,
                            baseDescriptor: baseDescriptor,
                            baseIdentity: baseIdentity,
                            containerDescriptor: containerDescriptor,
                            envelopeURL: envelopeURL,
                            envelopeDescriptor: envelopeDescriptor,
                            envelopeIdentity: envelopeIdentity,
                            bundleDescriptor: bundleDescriptor,
                            record: record,
                            ready: ready
                        )
                        events.append(.published(published))
                        continue
                    }
                    guard readyStatusError == ENOENT else {
                        throw posixError(readyStatusError)
                    }
                    if fstatat(
                        envelopeDescriptor,
                        readyTemporaryLeaf,
                        &readyStatus,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0 {
                        try removeKnownTemporaryFile(readyTemporaryLeaf, in: envelopeDescriptor)
                    }

                    guard let expectedMetadataSHA256 = record.validatedMetadataSHA256,
                          let expectedReceiptDigest = record.validatedReceiptDigest else {
                        try removeReconciledEnvelope(
                            baseURL: baseURL,
                            baseDescriptor: baseDescriptor,
                            baseIdentity: baseIdentity,
                            containerURL: containerURL,
                            containerDescriptor: containerDescriptor,
                            envelopeURL: envelopeURL,
                            envelopeIdentity: envelopeIdentity,
                            disposition: .abort,
                            expectedBundle: expectedBundle
                        )
                        events.append(.removedIncomplete(envelopeURL))
                        continue
                    }

                    let validated = try validateCompleteInitialBundle(
                        at: bundleURL,
                        expectedProjectID: record.projectID,
                        expectedTitle: record.title,
                        expectedMetadata: nil,
                        expectedBundle: expectedBundle,
                        normalizesPermissions: false,
                        hashesInputContents: true
                    )
                    let validatedManifestDigest = try manifestDigest(validated.manifest)
                    guard validated.metadataSHA256 == expectedMetadataSHA256,
                          validated.receiptDigest == expectedReceiptDigest,
                          record.validatedManifestDigest == nil
                            || record.validatedManifestDigest == validatedManifestDigest else {
                        throw ProjectPublicationError.pendingBundleChanged
                    }
                    try syncInitialBundle(
                        manifest: validated.manifest,
                        rootDescriptor: bundleDescriptor
                    )
                    let stable = try validateCompleteInitialBundle(
                        at: bundleURL,
                        expectedProjectID: record.projectID,
                        expectedTitle: record.title,
                        expectedMetadata: nil,
                        expectedBundle: expectedBundle,
                        normalizesPermissions: false,
                        hashesInputContents: false
                    )
                    guard stable.metadataSHA256 == expectedMetadataSHA256,
                          stable.receiptDigest == expectedReceiptDigest,
                          stable.manifest == validated.manifest else {
                        throw ProjectPublicationError.pendingBundleChanged
                    }
                    let sealedRecord = record.replacing(
                        phase: .building,
                        validatedManifestDigest: validatedManifestDigest
                    )
                    try replaceRecord(sealedRecord, in: envelopeDescriptor)
                    try syncDirectory(envelopeDescriptor)
                    try syncDirectory(containerDescriptor)
                    let ready = ReadyRecord(
                        schemaVersion: readySchemaVersion,
                        transactionID: record.transactionID,
                        projectID: record.projectID,
                        projectFormatVersion: ProjectMetadataStore.supportedFormatVersion,
                        bundle: expectedBundle,
                        metadataSHA256: stable.metadataSHA256,
                        receiptDigest: stable.receiptDigest,
                        manifest: stable.manifest
                    )
                    try writeReadyRecord(ready, in: envelopeDescriptor)
                    let readyRecord = sealedRecord.replacing(phase: .ready)
                    try replaceRecord(readyRecord, in: envelopeDescriptor)
                    try syncDirectory(envelopeDescriptor)
                    try syncDirectory(containerDescriptor)
                    let published = try publishRecoveredBundle(
                        baseURL: baseURL,
                        baseDescriptor: baseDescriptor,
                        baseIdentity: baseIdentity,
                        containerDescriptor: containerDescriptor,
                        envelopeURL: envelopeURL,
                        envelopeDescriptor: envelopeDescriptor,
                        envelopeIdentity: envelopeIdentity,
                        bundleDescriptor: bundleDescriptor,
                        record: readyRecord,
                        ready: ready
                    )
                    events.append(.published(published))
                } else if bundleStatusError == ENOENT {
                    if record.phase == .recorded,
                       record.bundle == nil,
                       record.plannedFinalLeaf == nil {
                        try removeReconciledEnvelope(
                            baseURL: baseURL,
                            baseDescriptor: baseDescriptor,
                            baseIdentity: baseIdentity,
                            containerURL: containerURL,
                            containerDescriptor: containerDescriptor,
                            envelopeURL: envelopeURL,
                            envelopeIdentity: envelopeIdentity,
                            disposition: .abort,
                            expectedBundle: nil
                        )
                        events.append(.removedIncomplete(envelopeURL))
                        continue
                    }
                    guard let expectedBundle = record.bundle,
                          let plannedLeaf = record.plannedFinalLeaf,
                          record.phase == .publishing || record.phase == .published,
                          safeVisibleProjectLeaf(plannedLeaf) else {
                        throw ProjectPublicationError.transactionIdentityChanged
                    }
                    let ready = try readReadyRecord(descriptor: envelopeDescriptor)
                    guard ready.transactionID == record.transactionID,
                          ready.projectID == record.projectID,
                          ready.bundle == expectedBundle else {
                        throw ProjectPublicationError.invalidReadinessReceipt
                    }
                    let visibleURL = baseURL.appendingPathComponent(plannedLeaf, isDirectory: true)
                    try validateVisiblePublishedBundle(
                        at: visibleURL,
                        expectedTransactionID: record.transactionID,
                        expectedProjectID: record.projectID,
                        expectedTitle: record.title,
                        expectedBundle: expectedBundle,
                        ready: ready
                    )
                    try syncDirectory(baseDescriptor)
                    let publishedRecord = record.replacing(
                        phase: .published,
                        plannedFinalLeaf: plannedLeaf
                    )
                    try replaceRecord(publishedRecord, in: envelopeDescriptor)
                    try syncDirectory(envelopeDescriptor)
                    try removeReconciledEnvelope(
                        baseURL: baseURL,
                        baseDescriptor: baseDescriptor,
                        baseIdentity: baseIdentity,
                        containerURL: containerURL,
                        containerDescriptor: containerDescriptor,
                        envelopeURL: envelopeURL,
                        envelopeIdentity: envelopeIdentity,
                        disposition: .published,
                        expectedBundle: nil
                    )
                    events.append(.cleanedPublished(visibleURL))
                } else {
                    throw posixError(bundleStatusError)
                }
            } catch {
                logger.warning(
                    "Preserving project transaction at \(envelopeURL.path, privacy: .private): \(String(describing: error), privacy: .public)"
                )
                events.append(.preserved(envelopeURL, reason: error.localizedDescription))
            }
        }
        for (id, cleanup) in cleanupRecords {
            let receiptLeaf = cleanupLeaf(for: id)
            var receiptStatus = stat()
            guard fstatat(
                containerDescriptor,
                receiptLeaf,
                &receiptStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                if errno == ENOENT { continue }
                throw posixError(errno)
            }
            var originalStatus = stat()
            let originalResult = fstatat(
                containerDescriptor,
                cleanup.originalEnvelopeLeaf,
                &originalStatus,
                AT_SYMLINK_NOFOLLOW
            )
            let originalError = originalResult == 0 ? 0 : errno
            let quarantineLeaf = ".deleting-\(id.uuidString.lowercased())"
            var quarantineStatus = stat()
            let quarantineResult = fstatat(
                containerDescriptor,
                quarantineLeaf,
                &quarantineStatus,
                AT_SYMLINK_NOFOLLOW
            )
            let quarantineError = quarantineResult == 0 ? 0 : errno
            guard originalResult != 0, originalError == ENOENT,
                  quarantineResult != 0, quarantineError == ENOENT else {
                continue
            }
            let receiptURL = containerURL.appendingPathComponent(receiptLeaf)
            do {
                let captured = try readCleanupRecordAndEntry(
                    descriptor: containerDescriptor,
                    leaf: receiptLeaf
                )
                guard captured.record == cleanup else {
                    throw ProjectPublicationError.unsafeTransactionContainer
                }
                try validatePublishedCleanupDestinationIfNeeded(
                    cleanup,
                    baseURL: baseURL,
                    baseDescriptor: baseDescriptor,
                    baseIdentity: baseIdentity
                )
                try unlinkCapturedFile(
                    parentDescriptor: containerDescriptor,
                    leaf: receiptLeaf,
                    entry: captured.entry,
                    errorPath: receiptLeaf
                )
                if cleanup.disposition == .published,
                   let plannedLeaf = cleanup.plannedFinalLeaf {
                    events.append(.cleanedPublished(
                        baseURL.appendingPathComponent(plannedLeaf, isDirectory: true)
                    ))
                } else {
                    events.append(.removedIncomplete(receiptURL))
                }
            } catch {
                logger.warning(
                    "Preserving orphaned project cleanup receipt at \(receiptURL.path, privacy: .private): \(String(describing: error), privacy: .public)"
                )
                events.append(.preserved(receiptURL, reason: error.localizedDescription))
            }
        }
        return events
    }

    static func publishRecoveredBundle(
        baseURL: URL,
        baseDescriptor: Int32,
        baseIdentity: FileIdentity,
        containerDescriptor: Int32,
        envelopeURL: URL,
        envelopeDescriptor: Int32,
        envelopeIdentity: FileIdentity,
        bundleDescriptor: Int32,
        record originalRecord: TransactionRecord,
        ready: ReadyRecord
    ) throws -> URL {
        var record = originalRecord
        for attempt in 0..<maximumLeafAttempts {
            let leaf = projectBundleLeaf(for: record.title, attempt: attempt)
            record = record.replacing(phase: .publishing, plannedFinalLeaf: leaf)
            try replaceRecord(record, in: envelopeDescriptor)
            try syncDirectory(envelopeDescriptor)
            try syncDirectory(containerDescriptor)
            guard try absoluteDirectoryStillRefers(
                to: baseDescriptor,
                identity: baseIdentity,
                at: baseURL
            ), try nameStillRefersToDescriptor(
                parent: envelopeDescriptor,
                leaf: bundleLeaf,
                descriptor: bundleDescriptor,
                expectedType: S_IFDIR
            ) else {
                throw ProjectPublicationError.transactionIdentityChanged
            }
            let result = renameatx_np(
                envelopeDescriptor,
                bundleLeaf,
                baseDescriptor,
                leaf,
                UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
            )
            if result != 0 {
                let code = errno
                if code == EEXIST { continue }
                if code == EXDEV { throw ProjectPublicationError.crossVolumePublication }
                if code == ENOTSUP || code == ENOSYS {
                    throw ProjectPublicationError.exclusiveRenameUnavailable
                }
                throw posixError(code)
            }
            let visibleURL = baseURL.appendingPathComponent(leaf, isDirectory: true)
            guard try nameStillRefersToDescriptor(
                parent: baseDescriptor,
                leaf: leaf,
                descriptor: bundleDescriptor,
                expectedType: S_IFDIR
            ), try absoluteDirectoryStillRefers(
                to: baseDescriptor,
                identity: baseIdentity,
                at: baseURL
            ) else {
                try rollbackPublishedBundle(
                    baseDescriptor: baseDescriptor,
                    visibleLeaf: leaf,
                    envelopeDescriptor: envelopeDescriptor,
                    bundleDescriptor: bundleDescriptor
                )
                throw ProjectPublicationError.publishedBundleIdentityChanged
            }
            try syncDirectory(baseDescriptor)
            try fullSync(baseDescriptor)
            do {
                try validateVisiblePublishedBundle(
                    at: visibleURL,
                    expectedTransactionID: record.transactionID,
                    expectedProjectID: record.projectID,
                    expectedTitle: record.title,
                    expectedBundle: ready.bundle,
                    ready: ready
                )
                guard try absoluteDirectoryStillRefers(
                    to: baseDescriptor,
                    identity: baseIdentity,
                    at: baseURL
                ) else {
                    throw ProjectPublicationError.transactionIdentityChanged
                }
            } catch {
                try rollbackPublishedBundle(
                    baseDescriptor: baseDescriptor,
                    visibleLeaf: leaf,
                    envelopeDescriptor: envelopeDescriptor,
                    bundleDescriptor: bundleDescriptor
                )
                throw error
            }
            record = record.replacing(phase: .published, plannedFinalLeaf: leaf)
            try replaceRecord(record, in: envelopeDescriptor)
            try syncDirectory(envelopeDescriptor)
            try removeReconciledEnvelope(
                baseURL: baseURL,
                baseDescriptor: baseDescriptor,
                baseIdentity: baseIdentity,
                containerURL: envelopeURL.deletingLastPathComponent(),
                containerDescriptor: containerDescriptor,
                envelopeURL: envelopeURL,
                envelopeIdentity: envelopeIdentity,
                disposition: .published,
                expectedBundle: nil
            )
            return visibleURL
        }
        throw ProjectPublicationError.projectNameExhausted
    }

    struct CleanupClosure {
        let record: TransactionRecord
        let outerFiles: [TreeEntry]
        let bundleManifest: [TreeEntry]?
    }

    static func removeReconciledEnvelope(
        baseURL: URL,
        baseDescriptor: Int32,
        baseIdentity: FileIdentity,
        containerURL _: URL,
        containerDescriptor: Int32,
        envelopeURL: URL,
        envelopeIdentity: FileIdentity,
        disposition: CleanupRecord.Disposition,
        expectedBundle: FileIdentity?
    ) throws {
        let envelopeDescriptor = try openChildDirectory(
            parent: containerDescriptor,
            leaf: envelopeURL.lastPathComponent
        )
        defer { Darwin.close(envelopeDescriptor) }
        try removeEnvelopeDescriptorRelative(
            baseURL: baseURL,
            baseDescriptor: baseDescriptor,
            baseIdentity: baseIdentity,
            containerDescriptor: containerDescriptor,
            sourceLeaf: envelopeURL.lastPathComponent,
            envelopeDescriptor: envelopeDescriptor,
            envelopeIdentity: envelopeIdentity,
            disposition: disposition,
            expectedBundle: expectedBundle
        )
    }

    static func removeEnvelopeDescriptorRelative(
        baseURL: URL,
        baseDescriptor: Int32,
        baseIdentity: FileIdentity,
        containerDescriptor: Int32,
        sourceLeaf: String,
        envelopeDescriptor: Int32,
        envelopeIdentity: FileIdentity,
        disposition: CleanupRecord.Disposition,
        expectedBundle: FileIdentity?,
        checkpointHandler: CheckpointHandler? = nil
    ) throws {
        guard transactionID(from: sourceLeaf) != nil,
              try FileIdentity.read(from: envelopeDescriptor, expectedType: S_IFDIR) == envelopeIdentity,
              try nameStillRefersToDescriptor(
                  parent: containerDescriptor,
                  leaf: sourceLeaf,
                  descriptor: envelopeDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        guard let id = transactionID(from: sourceLeaf) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        let containerIdentity = try FileIdentity.read(
            from: containerDescriptor,
            expectedType: S_IFDIR
        )
        let receiptLeaf = cleanupLeaf(for: id)
        let cleanup: CleanupRecord
        let cleanupReceiptEntry: TreeEntry
        var createdCleanupReceipt = false
        var receiptStatus = stat()
        if fstatat(containerDescriptor, receiptLeaf, &receiptStatus, AT_SYMLINK_NOFOLLOW) == 0 {
            let captured = try readCleanupRecordAndEntry(
                descriptor: containerDescriptor,
                leaf: receiptLeaf
            )
            cleanup = captured.record
            cleanupReceiptEntry = captured.entry
        } else {
            let receiptLookupError = errno
            guard receiptLookupError == ENOENT else { throw posixError(receiptLookupError) }
            let original = try captureCleanupClosure(
                envelopeDescriptor: envelopeDescriptor,
                envelopeIdentity: envelopeIdentity,
                expectedBundle: expectedBundle
            )
            guard original.record.transactionID == id else {
                throw ProjectPublicationError.unsafeTransactionEnvelope
            }
            let ready: ReadyRecord?
            if disposition == .published {
                ready = try readReadyRecord(descriptor: envelopeDescriptor)
            } else {
                ready = nil
            }
            cleanup = CleanupRecord(
                schemaVersion: cleanupSchemaVersion,
                transactionID: id,
                library: original.record.library,
                container: containerIdentity,
                envelope: envelopeIdentity,
                originalEnvelopeLeaf: transactionLeaf(for: id),
                disposition: disposition,
                transactionRecord: original.record,
                readyRecord: ready,
                expectedBundle: expectedBundle,
                plannedFinalLeaf: disposition == .published
                    ? original.record.plannedFinalLeaf
                    : nil,
                outerFiles: original.outerFiles,
                bundleManifest: original.bundleManifest
            )
            try validateCleanupRecordStructure(cleanup)
            try ensureCleanupRecord(cleanup, in: containerDescriptor)
            let captured = try readCleanupRecordAndEntry(
                descriptor: containerDescriptor,
                leaf: receiptLeaf
            )
            guard captured.record == cleanup else {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
            cleanupReceiptEntry = captured.entry
            createdCleanupReceipt = true
        }
        guard cleanup.disposition == disposition,
              cleanup.expectedBundle == expectedBundle,
              cleanup.library == baseIdentity,
              cleanup.container == containerIdentity,
              cleanup.envelope == envelopeIdentity else {
            throw ProjectPublicationError.unsafeTransactionContainer
        }
        try validateCleanupRecordStructure(cleanup)
        guard try absoluteDirectoryStillRefers(
            to: baseDescriptor,
            identity: baseIdentity,
            at: baseURL
        ) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        try validatePublishedCleanupDestinationIfNeeded(
            cleanup,
            baseURL: baseURL,
            baseDescriptor: baseDescriptor,
            baseIdentity: baseIdentity
        )
        let closure = try captureRemainingCleanupClosure(
            envelopeDescriptor: envelopeDescriptor,
            cleanup: cleanup
        )
        if createdCleanupReceipt {
            try checkpointHandler?(.cleanupIntentDurable)
        }
        let quarantineLeaf = ".deleting-\(id.uuidString.lowercased())"
        if quarantineLeaf != sourceLeaf {
            guard renameatx_np(
                containerDescriptor,
                sourceLeaf,
                containerDescriptor,
                quarantineLeaf,
                UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
            ) == 0 else {
                throw posixError(errno)
            }
            try syncDirectory(containerDescriptor)
        }
        guard try nameStillRefersToDescriptor(
            parent: containerDescriptor,
            leaf: quarantineLeaf,
            descriptor: envelopeDescriptor,
            expectedType: S_IFDIR
        ) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        try checkpointHandler?(.envelopeQuarantined)

        for entry in closure.outerFiles where entry.relativePath != recordLeaf {
            try unlinkCapturedFile(
                parentDescriptor: envelopeDescriptor,
                leaf: entry.relativePath,
                entry: entry,
                errorPath: entry.relativePath
            )
        }
        try checkpointHandler?(.outerCleanupDurable)
        if let manifest = closure.bundleManifest {
            let bundleDescriptor = try openChildDirectory(
                parent: envelopeDescriptor,
                leaf: bundleLeaf
            )
            defer { Darwin.close(bundleDescriptor) }
            try deleteCapturedBundleTree(
                manifest: manifest,
                rootDescriptor: bundleDescriptor,
                envelopeDescriptor: envelopeDescriptor
            )
        }
        try checkpointHandler?(.bundleCleanupDurable)

        // Keep the transaction record as the durable proof of ownership until
        // every descendant is gone. A crash before this point is resumable.
        let remaining = try directoryLeafNames(
            descriptor: envelopeDescriptor,
            maximumCount: 8
        )
        if remaining == [recordLeaf] {
            try validatePublishedCleanupDestinationIfNeeded(
                cleanup,
                baseURL: baseURL,
                baseDescriptor: baseDescriptor,
                baseIdentity: baseIdentity
            )
            guard let recordEntry = cleanup.outerFiles.first(where: {
                $0.relativePath == recordLeaf
            }) else {
                throw ProjectPublicationError.unsafeTransactionEnvelope
            }
            try unlinkCapturedFile(
                parentDescriptor: envelopeDescriptor,
                leaf: recordLeaf,
                entry: recordEntry,
                errorPath: recordLeaf
            )
            try checkpointHandler?(.cleanupProofRemoved)
        } else if !remaining.isEmpty {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        guard try directoryLeafNames(
            descriptor: envelopeDescriptor,
            maximumCount: 1
        ).isEmpty,
        try nameStillRefersToDescriptor(
            parent: containerDescriptor,
            leaf: quarantineLeaf,
            descriptor: envelopeDescriptor,
            expectedType: S_IFDIR
        ) else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        guard unlinkat(containerDescriptor, quarantineLeaf, AT_REMOVEDIR) == 0 else {
            throw posixError(errno)
        }
        try syncDirectory(containerDescriptor)
        try validatePublishedCleanupDestinationIfNeeded(
            cleanup,
            baseURL: baseURL,
            baseDescriptor: baseDescriptor,
            baseIdentity: baseIdentity
        )
        try unlinkCapturedFile(
            parentDescriptor: containerDescriptor,
            leaf: receiptLeaf,
            entry: cleanupReceiptEntry,
            errorPath: receiptLeaf
        )
        try checkpointHandler?(.cleanupComplete)
    }

    static func validatePublishedCleanupDestinationIfNeeded(
        _ cleanup: CleanupRecord,
        baseURL: URL,
        baseDescriptor: Int32,
        baseIdentity: FileIdentity
    ) throws {
        guard cleanup.disposition == .published else { return }
        guard let leaf = cleanup.plannedFinalLeaf,
              let ready = cleanup.readyRecord,
              try absoluteDirectoryStillRefers(
                to: baseDescriptor,
                identity: baseIdentity,
                at: baseURL
              ) else {
            throw ProjectPublicationError.publishedBundleIdentityChanged
        }
        try validateVisiblePublishedBundle(
            at: baseURL.appendingPathComponent(leaf, isDirectory: true),
            expectedTransactionID: cleanup.transactionRecord.transactionID,
            expectedProjectID: cleanup.transactionRecord.projectID,
            expectedTitle: cleanup.transactionRecord.title,
            expectedBundle: ready.bundle,
            ready: ready
        )
    }

    static func ensureCleanupRecord(
        _ expected: CleanupRecord,
        in containerDescriptor: Int32
    ) throws {
        let leaf = cleanupLeaf(for: expected.transactionID)
        var status = stat()
        if fstatat(containerDescriptor, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            let existing = try readCleanupRecord(
                descriptor: containerDescriptor,
                leaf: leaf
            )
            guard existing == expected else {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
            return
        }
        let statusError = errno
        guard statusError == ENOENT else { throw posixError(statusError) }
        try writePrivateFileExclusively(
            try encode(expected),
            leaf: leaf,
            in: containerDescriptor
        )
        try syncDirectory(containerDescriptor)
    }

    static func readCleanupRecord(
        descriptor: Int32,
        leaf: String
    ) throws -> CleanupRecord {
        try readCleanupRecordAndEntry(descriptor: descriptor, leaf: leaf).record
    }

    static func readCleanupRecordAndEntry(
        descriptor: Int32,
        leaf: String
    ) throws -> (record: CleanupRecord, entry: TreeEntry) {
        guard let leafID = cleanupTransactionID(from: leaf) else {
            throw ProjectPublicationError.unsafeTransactionContainer
        }
        guard leaf == cleanupLeaf(for: leafID) else {
            throw ProjectPublicationError.unsafeTransactionContainer
        }
        let captured = try descriptorBoundRead(
            parentDescriptor: descriptor,
            leaf: leaf,
            maximumBytes: maximumRecordBytes,
            normalizesPermissions: false
        )
        let record = try JSONDecoder().decode(CleanupRecord.self, from: captured.data)
        guard record.schemaVersion == cleanupSchemaVersion,
              record.transactionID == leafID,
              record.originalEnvelopeLeaf == transactionLeaf(for: leafID) else {
            throw ProjectPublicationError.unsafeTransactionContainer
        }
        return (
            record,
            TreeEntry(
                relativePath: leaf,
                status: captured.status,
                kind: .file,
                sha256: sha256(captured.data)
            )
        )
    }

    static func validateCleanupRecordStructure(_ cleanup: CleanupRecord) throws {
        let record = cleanup.transactionRecord
        guard cleanup.schemaVersion == cleanupSchemaVersion,
              cleanup.transactionID == record.transactionID,
              cleanup.library == record.library,
              cleanup.envelope == record.envelope,
              cleanup.originalEnvelopeLeaf == transactionLeaf(for: cleanup.transactionID),
              ProjectMetadataStore.acceptedFormatVersions.contains(record.projectFormatVersion),
              transactionRecordIsStructurallyValid(record),
              cleanup.outerFiles.count <= 4 else {
            throw ProjectPublicationError.unsafeTransactionContainer
        }
        let allowedOuter = Set([recordLeaf, readyLeaf, recordTemporaryLeaf, readyTemporaryLeaf])
        let outerPaths = cleanup.outerFiles.map(\.relativePath)
        guard Set(outerPaths).count == outerPaths.count,
              Set(outerPaths).isSubset(of: allowedOuter),
              outerPaths.contains(recordLeaf),
              cleanup.outerFiles.allSatisfy({
                  $0.kind == .file
                      && $0.owner == getuid()
                      && $0.permissions == 0o600
                      && $0.linkCount == 1
                      && $0.device == cleanup.envelope.device
              }) else {
            throw ProjectPublicationError.unsafeTransactionContainer
        }

        switch cleanup.disposition {
        case .published:
            guard cleanup.expectedBundle == nil,
                  cleanup.bundleManifest == nil,
                  record.phase == .published,
                  let plannedLeaf = cleanup.plannedFinalLeaf,
                  plannedLeaf == record.plannedFinalLeaf,
                  safeVisibleProjectLeaf(plannedLeaf),
                  let ready = cleanup.readyRecord,
                  ready.schemaVersion == readySchemaVersion,
                  ready.transactionID == record.transactionID,
                  ready.projectID == record.projectID,
                  ProjectMetadataStore.acceptedFormatVersions.contains(ready.projectFormatVersion),
                  ready.bundle == record.bundle,
                  ready.manifest.count <= 20_050,
                  ready.metadataSHA256 == record.validatedMetadataSHA256,
                  ready.receiptDigest == record.validatedReceiptDigest,
                  try manifestDigest(ready.manifest) == record.validatedManifestDigest,
                  readyManifestIsStructurallyValid(ready.manifest, bundle: ready.bundle),
                  cleanup.outerFiles.contains(where: { $0.relativePath == readyLeaf }) else {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
        case .abort:
            guard cleanup.readyRecord == nil,
                  cleanup.plannedFinalLeaf == nil,
                  record.phase == .recorded
                    || record.phase == .building
                    || record.phase == .ready
                    || record.phase == .publishing else {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
            if record.phase != .publishing, record.plannedFinalLeaf != nil {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
            if let expectedBundle = cleanup.expectedBundle {
                guard record.bundle == expectedBundle,
                      let manifest = cleanup.bundleManifest,
                      manifest == record.ownedBundleManifest,
                      cleanupManifest(
                        manifest,
                        isBoundTo: expectedBundle
                      ) else {
                    throw ProjectPublicationError.unsafeTransactionContainer
                }
            } else if cleanup.bundleManifest != nil {
                throw ProjectPublicationError.unsafeTransactionContainer
            }
        }
    }

    static func cleanupManifest(
        _ manifest: [TreeEntry],
        isBoundTo bundle: FileIdentity
    ) -> Bool {
        guard manifest.count <= 20_050 else { return false }
        let paths = manifest.map(\.relativePath)
        guard Set(paths).count == paths.count,
              let root = manifest.first(where: { $0.relativePath == "." }),
              root.kind == .directory,
              root.device == bundle.device,
              root.inode == bundle.inode,
              root.owner == bundle.owner,
              root.permissions == bundle.permissions else {
            return false
        }
        let allowedDirectories = initialDirectoryPaths.union(["Originals/Photos"])
        return manifest.allSatisfy { entry in
            guard entry.owner == getuid(), entry.device == bundle.device else { return false }
            switch entry.kind {
            case .directory:
                return allowedDirectories.contains(entry.relativePath)
                    && entry.permissions & 0o022 == 0
            case .file:
                return (entry.relativePath == "project.json"
                    || isControlledInitialArtifactRelativePath(entry.relativePath))
                    && entry.permissions & 0o022 == 0
                    && entry.linkCount == 1
            }
        }
    }

    static func readyManifestIsStructurallyValid(
        _ manifest: [TreeEntry],
        bundle: FileIdentity
    ) -> Bool {
        cleanupManifest(manifest, isBoundTo: bundle) && manifest.allSatisfy { entry in
            switch entry.kind {
            case .directory:
                return entry.sha256 == nil
            case .file:
                return entry.sha256.map(validSHA256) == true
            }
        }
    }

    static func captureRemainingCleanupClosure(
        envelopeDescriptor: Int32,
        cleanup: CleanupRecord
    ) throws -> CleanupClosure {
        guard try FileIdentity.read(from: envelopeDescriptor, expectedType: S_IFDIR) == cleanup.envelope else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        let names = try directoryLeafNames(descriptor: envelopeDescriptor, maximumCount: 8)
        if names.isEmpty {
            return CleanupClosure(
                record: cleanup.transactionRecord,
                outerFiles: [],
                bundleManifest: nil
            )
        }
        var allowed = Set(cleanup.outerFiles.map(\.relativePath))
        if cleanup.expectedBundle != nil { allowed.insert(bundleLeaf) }
        guard Set(names).isSubset(of: allowed), names.contains(recordLeaf) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        let currentRecord = try readTransactionRecord(descriptor: envelopeDescriptor)
        guard currentRecord == cleanup.transactionRecord else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        let expectedOuter = Dictionary(
            uniqueKeysWithValues: cleanup.outerFiles.map { ($0.relativePath, $0) }
        )
        var outerFiles: [TreeEntry] = []
        for leaf in names where leaf != bundleLeaf {
            guard let expected = expectedOuter[leaf] else {
                throw ProjectPublicationError.unsafeTransactionEnvelope
            }
            let status = try requirePrivateRegularFile(
                parent: envelopeDescriptor,
                leaf: leaf,
                maximumBytes: maximumRecordBytes
            )
            let current = TreeEntry(
                relativePath: leaf,
                status: status,
                kind: .file,
                sha256: nil
            )
            guard current == expected else {
                throw ProjectPublicationError.pendingBundleEntryChanged(leaf)
            }
            outerFiles.append(current)
        }

        var bundleManifest: [TreeEntry]?
        var bundleStatus = stat()
        if fstatat(envelopeDescriptor, bundleLeaf, &bundleStatus, AT_SYMLINK_NOFOLLOW) == 0 {
            guard let expectedBundle = cleanup.expectedBundle,
                  let expectedManifest = cleanup.bundleManifest,
                  bundleStatus.st_mode & S_IFMT == S_IFDIR,
                  FileIdentity(bundleStatus) == expectedBundle else {
                throw ProjectPublicationError.transactionIdentityChanged
            }
            let descriptor = try openChildDirectory(parent: envelopeDescriptor, leaf: bundleLeaf)
            defer { Darwin.close(descriptor) }
            guard try FileIdentity.read(from: descriptor, expectedType: S_IFDIR) == expectedBundle,
                  try nameStillRefersToDescriptor(
                    parent: envelopeDescriptor,
                    leaf: bundleLeaf,
                    descriptor: descriptor,
                    expectedType: S_IFDIR
                  ) else {
                throw ProjectPublicationError.transactionIdentityChanged
            }
            let current = try captureDemonstrablyOwnedIncompleteBundle(
                rootDescriptor: descriptor,
                expectedBundle: expectedBundle
            )
            let expectedByPath = Dictionary(
                uniqueKeysWithValues: expectedManifest.map { ($0.relativePath, $0) }
            )
            for entry in current {
                guard let expected = expectedByPath[entry.relativePath],
                      cleanupTreeEntry(entry, matchesPersisted: expected) else {
                    throw ProjectPublicationError.pendingBundleEntryChanged(entry.relativePath)
                }
            }
            bundleManifest = current
        } else {
            guard errno == ENOENT else { throw posixError(errno) }
            bundleManifest = nil
        }
        return CleanupClosure(
            record: cleanup.transactionRecord,
            outerFiles: outerFiles.sorted { $0.relativePath < $1.relativePath },
            bundleManifest: bundleManifest
        )
    }

    static func cleanupTreeEntry(
        _ current: TreeEntry,
        matchesPersisted expected: TreeEntry
    ) -> Bool {
        guard current.relativePath == expected.relativePath,
              current.kind == expected.kind else { return false }
        if current.kind == .file { return current == expected }
        return current.device == expected.device
            && current.inode == expected.inode
            && current.owner == expected.owner
            && current.permissions == expected.permissions
    }

    static func captureCleanupClosure(
        envelopeDescriptor: Int32,
        envelopeIdentity: FileIdentity,
        expectedBundle: FileIdentity?
    ) throws -> CleanupClosure {
        guard try FileIdentity.read(from: envelopeDescriptor, expectedType: S_IFDIR) == envelopeIdentity else {
            throw ProjectPublicationError.transactionIdentityChanged
        }
        let record = try recoverTransactionRecord(descriptor: envelopeDescriptor)
        guard record.envelope == envelopeIdentity else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        let names = try directoryLeafNames(descriptor: envelopeDescriptor, maximumCount: 8)
        var allowed = Set([recordLeaf, readyLeaf, recordTemporaryLeaf, readyTemporaryLeaf])
        if expectedBundle != nil { allowed.insert(bundleLeaf) }
        guard Set(names).isSubset(of: allowed), names.contains(recordLeaf),
              (expectedBundle == nil) == !names.contains(bundleLeaf) else {
            throw ProjectPublicationError.unsafeTransactionEnvelope
        }
        var outerFiles: [TreeEntry] = []
        for leaf in names where leaf != bundleLeaf {
            let status = try requirePrivateRegularFile(
                parent: envelopeDescriptor,
                leaf: leaf,
                maximumBytes: maximumRecordBytes
            )
            outerFiles.append(TreeEntry(
                relativePath: leaf,
                status: status,
                kind: .file,
                sha256: nil
            ))
        }
        let bundleManifest: [TreeEntry]?
        if let expectedBundle {
            guard record.bundle == expectedBundle,
                  let ownedBundleManifest = record.ownedBundleManifest else {
                throw ProjectPublicationError.unsafeTransactionEnvelope
            }
            let bundleDescriptor = try openChildDirectory(
                parent: envelopeDescriptor,
                leaf: bundleLeaf
            )
            defer { Darwin.close(bundleDescriptor) }
            guard try FileIdentity.read(from: bundleDescriptor, expectedType: S_IFDIR) == expectedBundle,
                  try nameStillRefersToDescriptor(
                      parent: envelopeDescriptor,
                      leaf: bundleLeaf,
                      descriptor: bundleDescriptor,
                      expectedType: S_IFDIR
                  ) else {
                throw ProjectPublicationError.transactionIdentityChanged
            }
            let currentBundleManifest = try captureDemonstrablyOwnedIncompleteBundle(
                rootDescriptor: bundleDescriptor,
                expectedBundle: expectedBundle
            )
            guard currentBundleManifest == ownedBundleManifest else {
                throw ProjectPublicationError.pendingBundleEntryChanged(
                    firstManifestDifference(currentBundleManifest, ownedBundleManifest)
                )
            }
            bundleManifest = currentBundleManifest
        } else {
            bundleManifest = nil
        }
        return CleanupClosure(
            record: record,
            outerFiles: outerFiles.sorted { $0.relativePath < $1.relativePath },
            bundleManifest: bundleManifest
        )
    }

    static func deleteCapturedBundleTree(
        manifest: [TreeEntry],
        rootDescriptor: Int32,
        envelopeDescriptor: Int32
    ) throws {
        guard let rootEntry = manifest.first(where: { $0.relativePath == "." }) else {
            throw ProjectPublicationError.unsafePendingBundle
        }
        for entry in manifest
            .filter({ $0.kind == .file })
            .sorted(by: cleanupEntrySort) {
            let (parentDescriptor, leaf) = try openCleanupParent(
                rootDescriptor: rootDescriptor,
                relativePath: entry.relativePath
            )
            defer { Darwin.close(parentDescriptor) }
            try unlinkCapturedFile(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                entry: entry,
                errorPath: entry.relativePath
            )
        }
        for entry in manifest
            .filter({ $0.kind == .directory && $0.relativePath != "." })
            .sorted(by: cleanupEntrySort) {
            let (parentDescriptor, leaf) = try openCleanupParent(
                rootDescriptor: rootDescriptor,
                relativePath: entry.relativePath
            )
            defer { Darwin.close(parentDescriptor) }
            let childDescriptor = try openChildDirectory(parent: parentDescriptor, leaf: leaf)
            defer { Darwin.close(childDescriptor) }
            var opened = stat()
            guard fstat(childDescriptor, &opened) == 0,
                  entry.matchesIdentity(opened),
                  try nameStillRefersToDescriptor(
                      parent: parentDescriptor,
                      leaf: leaf,
                      descriptor: childDescriptor,
                      expectedType: S_IFDIR
                  ),
                  try directoryLeafNames(descriptor: childDescriptor, maximumCount: 1).isEmpty else {
                throw ProjectPublicationError.pendingBundleEntryChanged(entry.relativePath)
            }
            guard unlinkat(parentDescriptor, leaf, AT_REMOVEDIR) == 0 else {
                throw posixError(errno)
            }
            try syncDirectory(parentDescriptor)
        }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              rootEntry.matchesIdentity(rootStatus),
              try directoryLeafNames(descriptor: rootDescriptor, maximumCount: 1).isEmpty,
              try nameStillRefersToDescriptor(
                  parent: envelopeDescriptor,
                  leaf: bundleLeaf,
                  descriptor: rootDescriptor,
                  expectedType: S_IFDIR
              ) else {
            throw ProjectPublicationError.pendingBundleChanged
        }
        guard unlinkat(envelopeDescriptor, bundleLeaf, AT_REMOVEDIR) == 0 else {
            throw posixError(errno)
        }
        try syncDirectory(envelopeDescriptor)
    }

    static func cleanupEntrySort(_ lhs: TreeEntry, _ rhs: TreeEntry) -> Bool {
        let lhsDepth = lhs.relativePath.split(separator: "/").count
        let rhsDepth = rhs.relativePath.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
        return lhs.relativePath > rhs.relativePath
    }

    static func openCleanupParent(
        rootDescriptor: Int32,
        relativePath: String
    ) throws -> (descriptor: Int32, leaf: String) {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let leaf = components.last,
              safeLeaf(leaf),
              components.dropLast().allSatisfy(safeLeaf) else {
            throw ProjectPublicationError.unsafePendingBundle
        }
        var descriptor = dup(rootDescriptor)
        guard descriptor >= 0 else { throw posixError(errno) }
        do {
            for component in components.dropLast() {
                let child = component.withCString {
                    openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                    )
                }
                let code = errno
                Darwin.close(descriptor)
                guard child >= 0 else { throw posixError(code) }
                descriptor = child
            }
            return (descriptor, leaf)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func unlinkCapturedFile(
        parentDescriptor: Int32,
        leaf: String,
        entry: TreeEntry,
        errorPath: String
    ) throws {
        let descriptor = leaf.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parentDescriptor, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              entry.matches(opened),
              entry.matches(named),
              sameStableRegularFile(opened, named) else {
            throw ProjectPublicationError.pendingBundleEntryChanged(errorPath)
        }
        guard unlinkat(parentDescriptor, leaf, 0) == 0 else {
            throw posixError(errno)
        }
        try syncDirectory(parentDescriptor)
    }

    static func safeVisibleProjectLeaf(_ leaf: String) -> Bool {
        safeLeaf(leaf)
            && leaf.hasSuffix(".easysplatproj")
            && leaf.utf8.count <= projectBundleLeafMaximumUTF8Bytes
            && !leaf.hasPrefix(".")
    }
}
