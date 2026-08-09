import CryptoKit
import Darwin
import Foundation

package struct PublishedResultGeneration: Sendable, Equatable {
    package let projectID: UUID
    package let publicationID: UUID
    package let outputEvidence: ValidatedPlyArtifactEvidence

    fileprivate let receipt: PublishedSplatReceipt
    fileprivate let plyIdentity: PublishedResultGenerationFileIdentity
    fileprivate let receiptIdentity: PublishedResultGenerationFileIdentity
    fileprivate let receiptSHA256: String

    fileprivate init(
        receipt: PublishedSplatReceipt,
        outputEvidence: ValidatedPlyArtifactEvidence,
        plyIdentity: PublishedResultGenerationFileIdentity,
        receiptIdentity: PublishedResultGenerationFileIdentity,
        receiptSHA256: String
    ) {
        projectID = receipt.projectID
        publicationID = receipt.publicationID
        self.outputEvidence = outputEvidence
        self.receipt = receipt
        self.plyIdentity = plyIdentity
        self.receiptIdentity = receiptIdentity
        self.receiptSHA256 = receiptSHA256
    }
}

private struct PublishedResultGenerationFileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let owner: uid_t
    let mode: mode_t
    let linkCount: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

private extension PublishedResultGenerationFileIdentity {
    init(_ identity: PublishedResultPairStore.FileIdentity) {
        self.init(
            device: identity.device,
            inode: identity.inode,
            byteCount: identity.byteCount,
            owner: identity.owner,
            mode: identity.mode,
            linkCount: identity.linkCount,
            modifiedSeconds: identity.modifiedSeconds,
            modifiedNanoseconds: identity.modifiedNanoseconds,
            changedSeconds: identity.changedSeconds,
            changedNanoseconds: identity.changedNanoseconds
        )
    }
}

package struct ValidatedPublishedResult: Sendable, Equatable {
    package let receipt: PublishedSplatReceipt
    package let outputURL: URL
    package let outputEvidence: ValidatedPlyArtifactEvidence
    package let generation: PublishedResultGeneration?

    package init(
        receipt: PublishedSplatReceipt,
        outputURL: URL,
        outputEvidence: ValidatedPlyArtifactEvidence,
        generation: PublishedResultGeneration? = nil
    ) {
        self.receipt = receipt
        self.outputURL = outputURL
        self.outputEvidence = outputEvidence
        self.generation = generation
    }

    package static func == (
        lhs: ValidatedPublishedResult,
        rhs: ValidatedPublishedResult
    ) -> Bool {
        lhs.receipt == rhs.receipt
            && lhs.outputURL == rhs.outputURL
            && lhs.outputEvidence == rhs.outputEvidence
    }
}

package enum PublishedResultUnavailability: Sendable, Equatable {
    case missingPair
    case incompletePair
    case unsafePair
    case invalidReceipt
    case invalidPly
    case evidenceMismatch
}

package enum PublishedResultConflict: Sendable, Equatable {
    case pendingTransaction
    case unsafeTransaction
}

package enum PublishedResultAvailability: Sendable, Equatable {
    case available(ValidatedPublishedResult)
    case unavailable(PublishedResultUnavailability)
    case conflict(PublishedResultConflict)
}

package enum PublishedResultPairCheckpoint: Sendable, Equatable {
    case lockWaitStarted
    case lockAcquired
    case transactionCreated
    case newPlyDurable
    case newReceiptDurable
    case prepared
    case previousPlyMoved
    case previousPairMoved
    case newPlyInstalled
    case newReceiptInstalled
    case canonicalPairValidated
    case transactionDirectoryRemoved
    case transactionRetired
    case receiptCleanupPlaceholderDurable
    case receiptTransactionActivated
    case transactionBuildOwnershipDurable
    case receiptTransactionBuildOwnershipDurable
}

package enum PublishedResultPairJournalPhase: Int, CaseIterable, Codable, Sendable {
    case created = 0
    case newPlyDurable = 1
    case newReceiptDurable = 2
    case prepared = 3
    case previousPlyMoved = 4
    case previousPairMoved = 5
    case newPlyInstalled = 6
    case receiptCommitted = 7
    case validated = 8

    package var leaf: String {
        "journal-\(rawValue)-\(String(describing: self)).json"
    }

    package var pendingLeaf: String { leaf + ".pending" }
}

package enum PublishedResultPairError: Error, LocalizedError, Equatable {
    case unsafeOutput
    case invalidSource
    case publicationConflict(String)
    case persistence(operation: String, code: Int32)

    package var errorDescription: String? {
        switch self {
        case .unsafeOutput:
            "The project Output folder is not safe to update."
        case .invalidSource:
            "The completed splat is invalid or changed while it was being published."
        case .publicationConflict(let detail):
            "The published result changed during publication: \(detail)"
        case .persistence(let operation, let code):
            "Could not durably publish the result during \(operation) (POSIX \(code))."
        }
    }
}

package struct PublishedResultPairOperations: @unchecked Sendable {
    package var synchronizeFile: @Sendable (Int32) -> Int32
    package var synchronizeDirectory: @Sendable (Int32) -> Int32
    package var renameExclusive: @Sendable (Int32, String, Int32, String) -> Int32
    package var swap: @Sendable (Int32, String, Int32, String) -> Int32
    package var readAt: @Sendable (
        Int32,
        UnsafeMutableRawPointer?,
        Int,
        off_t
    ) -> Int
    package var write: @Sendable (Int32, UnsafeRawPointer?, Int) -> Int
    package var openTransactionDirectory: @Sendable (Int32, String) -> Int32
    package var volumeCaseSensitivity: @Sendable (Int32) -> Int
    package var willOpenProjectRoot: @Sendable () throws -> Void
    package var willValidatePly: @Sendable (String) -> Void
    package var makeUUID: @Sendable () -> UUID
    package var didReachCheckpoint: @Sendable (PublishedResultPairCheckpoint) -> Void
    package var willQuarantineOwnedEntry: @Sendable (String) throws -> Void
    package var willUnlinkQuarantinedEntry: @Sendable (String) throws -> Void
    package var didValidateOwnedEntryForRemoval:
        @Sendable (Int32, String, Bool) -> Void

    package static func system() -> Self {
        Self(
            synchronizeFile: { descriptor in
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
            },
            synchronizeDirectory: { descriptor in
                while Darwin.fsync(descriptor) != 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                return 0
            },
            renameExclusive: { sourceDirectory, source, destinationDirectory, destination in
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
            },
            swap: { firstDirectory, first, secondDirectory, second in
                first.withCString { firstPointer in
                    second.withCString { secondPointer in
                        Darwin.renameatx_np(
                            firstDirectory,
                            firstPointer,
                            secondDirectory,
                            secondPointer,
                            UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
                        )
                    }
                }
            },
            readAt: { Darwin.pread($0, $1, $2, $3) },
            write: { Darwin.write($0, $1, $2) },
            openTransactionDirectory: { parent, name in
                name.withCString {
                    Darwin.openat(
                        parent,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            },
            volumeCaseSensitivity: {
                Darwin.fpathconf($0, _PC_CASE_SENSITIVE)
            },
            willOpenProjectRoot: {},
            willValidatePly: { _ in },
            makeUUID: UUID.init,
            didReachCheckpoint: { _ in },
            willQuarantineOwnedEntry: { _ in },
            willUnlinkQuarantinedEntry: { _ in },
            didValidateOwnedEntryForRemoval: { _, _, _ in }
        )
    }
}

package enum PublishedResultPairStore {
    /// Reconciles an interrupted publication when the Output directory already
    /// exists. A brand-new project has nothing to reconcile and must not gain
    /// filesystem state merely because pipeline startup inspected it.
    package static func reconcileIfPresent(
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try checkCancellation(shouldCancel)
        let root = try acquireProjectRootDescriptor(
            projectPaths: projectPaths,
            suppliedDescriptor: projectRootDescriptor,
            operations: operations
        )
        defer { Darwin.close(root.descriptor) }
        var status = stat()
        let outputStatus = "Output".withCString {
            Darwin.fstatat(root.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if outputStatus != 0, errno == ENOENT { return }
        guard outputStatus == 0, safeDirectory(status, exactMode: nil) else {
            throw PublishedResultPairError.unsafeOutput
        }
        try reconcile(
            projectPaths: projectPaths,
            projectRootDescriptor: root.descriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
    }

    package static func resolve(
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> PublishedResultAvailability {
        try checkCancellation(shouldCancel)
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let reconciled: PairResolution?
        do {
            reconciled = try reconcileLocked(
                output: output,
                operations: operations,
                shouldCancel: shouldCancel
            )
        } catch let error as PublishedResultPairError {
            switch error {
            case .publicationConflict:
                return .conflict(.pendingTransaction)
            case .unsafeOutput:
                return .conflict(.unsafeTransaction)
            default:
                throw error
            }
        }
        let resolution: PairResolution
        if let reconciled {
            resolution = reconciled
        } else {
            try output.revalidate()
            resolution = try resolveCanonicalPair(
                output: output,
                operations: operations,
                shouldCancel: shouldCancel
            )
        }
        try output.revalidate()
        return resolution.availability
    }

    package static func reconcile(
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try checkCancellation(shouldCancel)
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        _ = try reconcileLocked(
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        )
        try output.revalidate()
    }

    /// Commits state that depends on an already-published pair while retaining
    /// the same publication lock used to validate that pair. A non-matching or
    /// absent pair returns `nil` without invoking the commit closure.
    package static func commitResolvedResultIf(
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        matches: (ValidatedPublishedResult) throws -> Bool,
        afterCommit: (ValidatedPublishedResult) throws -> Void
    ) throws -> ValidatedPublishedResult? {
        try checkCancellation(shouldCancel)
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let reconciled = try reconcileLocked(
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let resolution = try reconciled ?? resolveCanonicalPair(
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let boundPair: BoundPair
        switch resolution {
        case .missing:
            return nil
        case .available(let pair):
            boundPair = pair
        case .unavailable:
            throw PublishedResultPairError.publicationConflict(
                "the existing canonical files do not form a validated pair"
            )
        }
        let result = boundPair.result
        let matched: Bool
        do {
            matched = try matches(result)
        } catch {
            try requireCanonicalPairUnchanged(pair: boundPair, output: output)
            throw error
        }
        try requireCanonicalPairUnchanged(pair: boundPair, output: output)
        guard matched else { return nil }
        do {
            try afterCommit(result)
        } catch {
            try requireCanonicalPairUnchanged(pair: boundPair, output: output)
            throw error
        }
        try requireCanonicalPairUnchanged(pair: boundPair, output: output)
        try checkCancellation(shouldCancel)
        return result
    }

    /// Runs a small state commit against one previously validated canonical
    /// generation while the publication lock remains held. The clean path
    /// opens the PLY only to prove its descriptor identity; it never reads or
    /// hashes the payload a second time.
    @discardableResult
    package static func commitReceiptBoundStateIf(
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        expectedGeneration: PublishedResultGeneration,
        expectedViewerReadySeconds: Double? = nil,
        allowingFirstViewerTimingTransition: Bool = false,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        afterValidation: () throws -> Void
    ) throws -> Bool {
        if let expectedViewerReadySeconds {
            guard expectedViewerReadySeconds.isFinite,
                  expectedViewerReadySeconds >= 0 else {
                throw PublishedResultPairError.invalidSource
            }
        }
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let initialNames = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 50_000
        )
        let hasPairTransaction = initialNames.contains {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionBuildPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionBuildAuthorityPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.retiredPrefix,
                output: output
            )
        }
        guard !hasPairTransaction else {
            throw PublishedResultPairError.publicationConflict(
                "a published-pair transaction is pending"
            )
        }
        let hasReceiptTransaction = initialNames.contains {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionBuildPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionBuildAuthorityPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptRetiredPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptCleanupPrefix,
                output: output
            )
        }
        if hasReceiptTransaction {
            try reconcileRetiredTransactionsLocked(
                output: output,
                operations: operations
            )
            _ = try reconcileReceiptTransactionLocked(
                output: output,
                operations: operations,
                shouldCancel: shouldCancel
            )
            let remaining = try directoryNames(
                descriptor: output.descriptor,
                maximumCount: 50_000
            )
            guard !remaining.contains(where: {
                hasReservedNamespacePrefix(
                    $0,
                    prefix: Names.receiptTransactionPrefix,
                    output: output
                ) || hasReservedNamespacePrefix(
                    $0,
                    prefix: Names.receiptTransactionBuildPrefix,
                    output: output
                ) || hasReservedNamespacePrefix(
                    $0,
                    prefix: Names.receiptTransactionBuildAuthorityPrefix,
                    output: output
                ) || hasReservedNamespacePrefix(
                    $0,
                    prefix: Names.receiptRetiredPrefix,
                    output: output
                ) || hasReservedNamespacePrefix(
                    $0,
                    prefix: Names.receiptCleanupPrefix,
                    output: output
                )
            }) else {
                throw PublishedResultPairError.publicationConflict(
                    "a viewer timing transaction remains pending"
                )
            }
        }
        switch entryPresence(
            parent: output.descriptor,
            name: Names.canonicalPly
        ) {
        case .missing:
            return false
        case .unsafe:
            throw PublishedResultPairError.publicationConflict(
                "the canonical PLY is unsafe"
            )
        case .present:
            break
        }
        switch entryPresence(
            parent: output.descriptor,
            name: Names.canonicalReceipt
        ) {
        case .missing:
            return false
        case .unsafe:
            throw PublishedResultPairError.publicationConflict(
                "the canonical receipt is unsafe"
            )
        case .present:
            break
        }
        let plyDescriptor = openReadOnly(
            parent: output.descriptor,
            name: Names.canonicalPly
        )
        guard plyDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "the canonical PLY could not be opened safely"
            )
        }
        defer { Darwin.close(plyDescriptor) }
        let receiptDescriptor = openReadOnly(
            parent: output.descriptor,
            name: Names.canonicalReceipt
        )
        guard receiptDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "the canonical receipt could not be opened safely"
            )
        }
        defer { Darwin.close(receiptDescriptor) }
        let plyIdentity = try requireBoundFile(
            descriptor: plyDescriptor,
            parent: output.descriptor,
            name: Names.canonicalPly,
            exactMode: 0o600
        )
        let receiptIdentity = try requireBoundFile(
            descriptor: receiptDescriptor,
            parent: output.descriptor,
            name: Names.canonicalReceipt,
            exactMode: 0o600
        )
        let data = try readBoundFile(
            descriptor: receiptDescriptor,
            identity: receiptIdentity,
            maximumBytes: PublishedSplatReceiptStore.maximumBytes
        )
        let receipt: PublishedSplatReceipt
        do {
            receipt = try PublishedSplatReceiptStore.decode(data)
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "the canonical receipt is invalid"
            )
        }

        let currentGeneration = generation(
            receipt: receipt,
            outputEvidence: receipt.outputEvidence,
            plyIdentity: plyIdentity,
            receiptIdentity: receiptIdentity,
            receiptData: data
        )
        let currentPair = BoundPair(
            result: ValidatedPublishedResult(
                receipt: receipt,
                outputURL: projectPaths.outputSplatURL,
                outputEvidence: receipt.outputEvidence,
                generation: currentGeneration
            ),
            plyIdentity: plyIdentity,
            receiptIdentity: receiptIdentity,
            receiptData: data
        )
        guard receipt.projectID == expectedGeneration.projectID,
              receipt.publicationID == expectedGeneration.publicationID else {
            return false
        }
        guard generation(
            currentPair,
            matches: expectedGeneration,
            allowingFirstViewerReadySeconds:
                allowingFirstViewerTimingTransition
                    ? expectedViewerReadySeconds
                    : nil
        ) else {
            throw PublishedResultPairError.publicationConflict(
                "the canonical published generation changed"
            )
        }

        func requireGenerationUnchanged() throws {
            try output.revalidate()
            let currentPly = try requireBoundFile(
                descriptor: plyDescriptor,
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            let beforeRead = try requireBoundFile(
                descriptor: receiptDescriptor,
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            guard currentPly == plyIdentity,
                  beforeRead == receiptIdentity else {
                throw PublishedResultPairError.publicationConflict(
                    "the canonical published generation changed"
                )
            }
            let currentData = try readBoundFile(
                descriptor: receiptDescriptor,
                identity: receiptIdentity,
                maximumBytes: PublishedSplatReceiptStore.maximumBytes
            )
            let afterRead = try requireBoundFile(
                descriptor: receiptDescriptor,
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            let finalPly = try requireBoundFile(
                descriptor: plyDescriptor,
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            guard afterRead == receiptIdentity,
                  finalPly == plyIdentity,
                  currentData == data else {
                throw PublishedResultPairError.publicationConflict(
                    "the canonical published generation changed"
                )
            }
        }

        try requireGenerationUnchanged()
        if let expectedViewerReadySeconds,
           receipt.presentation.createToViewerReadySeconds
            != expectedViewerReadySeconds {
            return false
        }
        do {
            try afterValidation()
        } catch {
            try requireGenerationUnchanged()
            throw error
        }
        try requireGenerationUnchanged()
        return true
    }

    package static func publish(
        sourceURL: URL,
        receipt: PublishedSplatReceipt,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        beforeCommit: () throws -> Void = {},
        afterCommit: (ValidatedPublishedResult) throws -> Void = { _ in }
    ) throws -> ValidatedPublishedResult {
        let relativePath = try projectRelativeSourcePath(
            sourceURL,
            projectPaths: projectPaths
        )
        return try publish(
            sourceProjectRelativePath: relativePath,
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel,
            beforeCommit: beforeCommit,
            afterCommit: afterCommit
        ) { evidence in
            guard evidence == receipt.outputEvidence else {
                throw PublishedResultPairError.invalidSource
            }
            return receipt
        }
    }

    /// Validates the exact opened source descriptor before constructing the
    /// receipt, so callers bind authority to the same evidence the transaction
    /// will copy instead of hashing the private PLY independently first.
    package static func publish(
        sourceURL: URL,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        adoptExisting: (
            ValidatedPublishedResult,
            PublishedSplatReceipt
        ) throws -> Bool = { _, _ in false },
        beforeAdopt: () throws -> Void = {},
        beforeCommit: () throws -> Void = {},
        afterCommit: (ValidatedPublishedResult) throws -> Void = { _ in },
        makeReceipt: (ValidatedPlyArtifactEvidence) throws -> PublishedSplatReceipt
    ) throws -> ValidatedPublishedResult {
        try publish(
            sourceProjectRelativePath: projectRelativeSourcePath(
                sourceURL,
                projectPaths: projectPaths
            ),
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel,
            adoptExisting: adoptExisting,
            beforeAdopt: beforeAdopt,
            beforeCommit: beforeCommit,
            afterCommit: afterCommit,
            makeReceipt: makeReceipt
        )
    }

    package static func publish(
        sourceProjectRelativePath: String,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        adoptExisting: (
            ValidatedPublishedResult,
            PublishedSplatReceipt
        ) throws -> Bool = { _, _ in false },
        beforeAdopt: () throws -> Void = {},
        beforeCommit: () throws -> Void = {},
        afterCommit: (ValidatedPublishedResult) throws -> Void = { _ in },
        makeReceipt: (ValidatedPlyArtifactEvidence) throws -> PublishedSplatReceipt
    ) throws -> ValidatedPublishedResult {
        try checkCancellation(shouldCancel)
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let reconciled = try reconcileLocked(
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let previousOutcome: PairResolution
        if let reconciled {
            previousOutcome = reconciled
        } else {
            previousOutcome = try resolveCanonicalPair(
                output: output,
                operations: operations,
                shouldCancel: shouldCancel
            )
        }
        try output.revalidate()
        let previous: BoundPair?
        switch previousOutcome {
        case .missing:
            previous = nil
        case .available(let pair):
            previous = pair
        case .unavailable:
            throw PublishedResultPairError.publicationConflict(
                "the existing canonical files do not form a validated pair"
            )
        }

        let source = try BoundSource.open(
            projectRelativePath: sourceProjectRelativePath,
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let receipt = try makeReceipt(source.evidence)
        guard source.evidence == receipt.outputEvidence else {
            throw PublishedResultPairError.invalidSource
        }
        let receiptData: Data
        do {
            receiptData = try PublishedSplatReceiptStore.encode(receipt)
        } catch {
            throw PublishedResultPairError.invalidSource
        }
        try checkCancellation(shouldCancel)
        try output.revalidate()

        if let previous, previous.result.outputEvidence == source.evidence {
            let shouldAdopt: Bool
            do {
                shouldAdopt = try adoptExisting(previous.result, receipt)
            } catch {
                try requireCanonicalPairUnchanged(pair: previous, output: output)
                throw error
            }
            try requireCanonicalPairUnchanged(pair: previous, output: output)
            if shouldAdopt {
                do {
                    try beforeAdopt()
                    try requireCanonicalPairUnchanged(pair: previous, output: output)
                    try afterCommit(previous.result)
                } catch {
                    try requireCanonicalPairUnchanged(pair: previous, output: output)
                    throw error
                }
                try requireCanonicalPairUnchanged(pair: previous, output: output)
                try checkCancellation(shouldCancel)
                return previous.result
            }
        }
        if previous?.result.receipt.publicationID == receipt.publicationID {
            throw PublishedResultPairError.publicationConflict(
                "one publication identity cannot authorize different result bytes"
            )
        }

        let transaction = try TransactionDirectory.create(
            output: output,
            transactionID: operations.makeUUID(),
            publicationID: receipt.publicationID,
            previousPublicationID: previous?.result.receipt.publicationID,
            previousPairIdentities: previous.map {
                PreviousPairJournalIdentities(
                    ply: JournalFileIdentity($0.plyIdentity),
                    receipt: JournalFileIdentity($0.receiptIdentity)
                )
            },
            operations: operations
        )
        operations.didReachCheckpoint(.transactionCreated)

        var previousPlyMoved = false
        var previousReceiptMoved = false
        var newPlyInstalled = false
        var newReceiptInstalled = false
        var receiptCommitDurable = false
        var didAttemptAfterCommit = false
        var didAttemptRetirement = false
        var transactionRetired = false
        var deferredCancellation = false
        var committedPair: BoundPair?
        var stagedPlyIdentity: FileIdentity?
        var stagedReceiptIdentity: FileIdentity?
        func observeDeferredCancellation() {
            if shouldCancel() { deferredCancellation = true }
        }
        do {
            try checkCancellation(shouldCancel)
            stagedPlyIdentity = try transaction.copySource(
                source,
                expectedEvidence: receipt.outputEvidence,
                operations: operations,
                shouldCancel: shouldCancel
            )
            try transaction.record(phase: .newPlyDurable, operations: operations)
            operations.didReachCheckpoint(.newPlyDurable)
            try checkCancellation(shouldCancel)
            stagedReceiptIdentity = try transaction.writePrivateFile(
                named: Names.newReceipt,
                data: receiptData,
                operations: operations
            )
            try transaction.record(phase: .newReceiptDurable, operations: operations)
            operations.didReachCheckpoint(.newReceiptDurable)
            try checkCancellation(shouldCancel)
            guard let stagedPlyIdentity, let stagedReceiptIdentity else {
                throw PublishedResultPairError.publicationConflict(
                    "staging identities missing"
                )
            }
            try transaction.requireUnchangedPrivateFile(
                named: Names.newPly,
                expected: stagedPlyIdentity
            )
            try transaction.requireUnchangedPrivateFile(
                named: Names.newReceipt,
                expected: stagedReceiptIdentity
            )
            try transaction.record(
                phase: .prepared,
                operations: operations
            )
            operations.didReachCheckpoint(.prepared)
            try transaction.requireUnchangedPrivateFile(
                named: Names.newPly,
                expected: stagedPlyIdentity
            )
            try transaction.requireUnchangedPrivateFile(
                named: Names.newReceipt,
                expected: stagedReceiptIdentity
            )
            try source.revalidatePath()
            try checkCancellation(shouldCancel)
            try output.revalidate()
            try beforeCommit()
            try source.revalidatePath()
            try output.revalidate()

            if let previous {
                let currentPly = try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalPly,
                    exactMode: 0o600
                )
                let currentReceipt = try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt,
                    exactMode: 0o600
                )
                guard currentPly == previous.plyIdentity,
                      currentReceipt == previous.receiptIdentity else {
                    throw PublishedResultPairError.publicationConflict(
                        "the previous pair changed during staging"
                    )
                }
                try moveExpected(
                    from: output.descriptor,
                    name: Names.canonicalPly,
                    expected: previous.plyIdentity,
                    to: transaction.descriptor,
                    destinationName: Names.oldPly,
                    operations: operations,
                    operation: "preserve previous PLY",
                    didRename: { previousPlyMoved = true }
                )
                try synchronizeDirectories(
                    [output.descriptor, transaction.descriptor],
                    operations: operations,
                    operation: "preserve previous PLY"
                )
                try transaction.record(phase: .previousPlyMoved, operations: operations)
                operations.didReachCheckpoint(.previousPlyMoved)
                observeDeferredCancellation()
                if deferredCancellation { throw CancellationError() }

                try output.revalidate()
                try moveExpected(
                    from: output.descriptor,
                    name: Names.canonicalReceipt,
                    expected: previous.receiptIdentity,
                    to: transaction.descriptor,
                    destinationName: Names.oldReceipt,
                    operations: operations,
                    operation: "preserve previous receipt",
                    didRename: { previousReceiptMoved = true }
                )
                try synchronizeDirectories(
                    [output.descriptor, transaction.descriptor],
                    operations: operations,
                    operation: "preserve previous receipt"
                )
                try transaction.record(phase: .previousPairMoved, operations: operations)
                operations.didReachCheckpoint(.previousPairMoved)
                observeDeferredCancellation()
                if deferredCancellation { throw CancellationError() }
            }

            try output.revalidate()
            try moveExpected(
                from: transaction.descriptor,
                name: Names.newPly,
                expected: stagedPlyIdentity,
                to: output.descriptor,
                destinationName: Names.canonicalPly,
                operations: operations,
                operation: "install new PLY",
                didRename: { newPlyInstalled = true }
            )
            try synchronizeDirectories(
                [transaction.descriptor, output.descriptor],
                operations: operations,
                operation: "install new PLY"
            )
            try transaction.record(
                phase: .newPlyInstalled,
                output: output,
                operations: operations
            )
            operations.didReachCheckpoint(.newPlyInstalled)
            observeDeferredCancellation()
            if deferredCancellation { throw CancellationError() }

            try output.revalidate()
            try moveExpected(
                from: transaction.descriptor,
                name: Names.newReceipt,
                expected: stagedReceiptIdentity,
                to: output.descriptor,
                destinationName: Names.canonicalReceipt,
                operations: operations,
                operation: "commit new receipt",
                didRename: { newReceiptInstalled = true }
            )
            try synchronizeDirectories(
                [transaction.descriptor, output.descriptor],
                operations: operations,
                operation: "commit new receipt"
            )
            receiptCommitDurable = true
            try transaction.record(
                phase: .receiptCommitted,
                output: output,
                operations: operations
            )
            operations.didReachCheckpoint(.newReceiptInstalled)
            observeDeferredCancellation()

            try output.revalidate()
            let finalOutcome = try resolveCanonicalPair(
                output: output,
                operations: operations
            )
            try output.revalidate()
            guard case .available(let finalPair) = finalOutcome,
                  canonicalReceiptData(
                    for: finalPair.result.receipt
                  ) == receiptData else {
                throw PublishedResultPairError.publicationConflict(
                    "the committed pair did not revalidate"
                )
            }
            committedPair = finalPair
            try transaction.record(
                phase: .validated,
                output: output,
                operations: operations
            )
            operations.didReachCheckpoint(.canonicalPairValidated)
            observeDeferredCancellation()
            try requireCanonicalPairUnchanged(pair: finalPair, output: output)
            didAttemptAfterCommit = true
            try afterCommit(finalPair.result)
            try requireCanonicalPairUnchanged(pair: finalPair, output: output)
            didAttemptRetirement = true
            try transaction.retire(output: output, operations: operations)
            transactionRetired = true
            observeDeferredCancellation()
            try requireCanonicalPairUnchanged(pair: finalPair, output: output)
            if deferredCancellation { throw CancellationError() }
            return finalPair.result
        } catch {
            if transactionRetired, let committedPair {
                try requireCanonicalPairUnchanged(pair: committedPair, output: output)
                throw error
            }
            if didAttemptAfterCommit, let committedPair {
                try requireCanonicalPairUnchanged(pair: committedPair, output: output)
                if didAttemptRetirement,
                   let reconciled = try reconciledCommittedPairWithoutResidue(
                    expected: committedPair,
                    output: output,
                    operations: operations
                   ) {
                    transactionRetired = true
                    observeDeferredCancellation()
                    if deferredCancellation { throw CancellationError() }
                    return reconciled.result
                }
                try transaction.retire(output: output, operations: operations)
                transactionRetired = true
                observeDeferredCancellation()
                try requireCanonicalPairUnchanged(pair: committedPair, output: output)
                if didAttemptRetirement {
                    if deferredCancellation { throw CancellationError() }
                    return committedPair.result
                }
                throw error
            }
            if receiptCommitDurable {
                var recoveredCommit: BoundPair?
                do {
                    try output.revalidate()
                    let resolution = try resolveCanonicalPair(
                        output: output,
                        operations: operations
                    )
                    try output.revalidate()
                    if case .available(let committed) = resolution,
                       canonicalReceiptData(
                        for: committed.result.receipt
                       ) == receiptData {
                        recoveredCommit = committed
                    }
                } catch {
                    // Recovery below is safe only while the original lock and
                    // Output pathname still refer to their bound descriptors.
                }
                if let recoveredCommit {
                    committedPair = recoveredCommit
                    try requireCanonicalPairUnchanged(
                        pair: recoveredCommit,
                        output: output
                    )
                    observeDeferredCancellation()
                    var callbackError: Error?
                    do {
                        try afterCommit(recoveredCommit.result)
                    } catch {
                        callbackError = error
                    }
                    try requireCanonicalPairUnchanged(
                        pair: recoveredCommit,
                        output: output
                    )
                    do {
                        try transaction.retire(output: output, operations: operations)
                    } catch let retirementError as PublishedResultPairError {
                        if case .persistence = retirementError {
                            try transaction.retire(output: output, operations: operations)
                        } else {
                            throw PublishedResultPairError.publicationConflict(
                                "committed publication cleanup conflicted"
                            )
                        }
                    } catch {
                        throw PublishedResultPairError.publicationConflict(
                            "committed publication cleanup conflicted"
                        )
                    }
                    transactionRetired = true
                    observeDeferredCancellation()
                    try requireCanonicalPairUnchanged(
                        pair: recoveredCommit,
                        output: output
                    )
                    if let callbackError {
                        throw callbackError
                    }
                    if deferredCancellation { throw CancellationError() }
                    return recoveredCommit.result
                }
            }
            do {
                try output.revalidate()
            } catch {
                throw PublishedResultPairError.publicationConflict(
                    "the publication lock or Output directory changed"
                )
            }
            if previousPlyMoved || newPlyInstalled || newReceiptInstalled {
                do {
                    try rollbackLivePublication(
                        output: output,
                        transaction: transaction,
                        previous: previous,
                        previousPlyMoved: previousPlyMoved,
                        previousReceiptMoved: previousReceiptMoved,
                        newPlyInstalled: newPlyInstalled,
                        newReceiptInstalled: newReceiptInstalled,
                        stagedPlyIdentity: stagedPlyIdentity,
                        stagedReceiptIdentity: stagedReceiptIdentity,
                        operations: operations
                    )
                } catch {
                    throw PublishedResultPairError.publicationConflict(
                        "rollback could not restore the previous pair"
                    )
                }
            } else {
                let canonical = try resolveCanonicalPair(
                    output: output,
                    operations: operations
                )
                if let previous {
                    guard case .available(let current) = canonical,
                          current.result == previous.result else {
                        throw PublishedResultPairError.publicationConflict(
                            "the canonical pair changed before cleanup"
                        )
                    }
                } else {
                    guard case .missing = canonical else {
                        throw PublishedResultPairError.publicationConflict(
                            "canonical files appeared before cleanup"
                        )
                    }
                }
                var stagedFiles: [String: FileIdentity] = [:]
                if let stagedPlyIdentity {
                    stagedFiles[Names.newPly] = stagedPlyIdentity
                }
                if let stagedReceiptIdentity {
                    stagedFiles[Names.newReceipt] = stagedReceiptIdentity
                }
                try? transaction.discardUncommitted(
                    output: output,
                    operations: operations,
                    additionalOwnedFiles: stagedFiles
                )
            }
            throw error
        }
    }

    /// Commits the first-viewer timing by replacing only the authority receipt.
    /// The publication lock covers the predecessor check, PLY validation, and
    /// receipt swap, so stale or conflicting callbacks cannot roll a generation
    /// backward. The canonical PLY inode is never copied, moved, or truncated.
    package static func recordFirstViewerReadyTiming(
        _ seconds: Double,
        expectedPublicationID: UUID,
        expectedGeneration: PublishedResultGeneration? = nil,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        beforeLockedUpdate: @escaping @Sendable () -> Void = {}
    ) throws -> ValidatedPublishedResult {
        guard seconds.isFinite, seconds >= 0 else {
            throw PublishedResultPairError.invalidSource
        }
        try checkCancellation(shouldCancel)
        beforeLockedUpdate()
        try checkCancellation(shouldCancel)

        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let reconciled = try reconcileLocked(
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let currentResolution: PairResolution
        if let reconciled {
            currentResolution = reconciled
        } else if let expectedGeneration {
            currentResolution = try resolveCanonicalPair(
                output: output,
                expectedGeneration: expectedGeneration,
                allowingFirstViewerReadySeconds: seconds,
                shouldCancel: shouldCancel
            )
        } else {
            currentResolution = try resolveCanonicalPair(
                output: output,
                operations: operations,
                shouldCancel: shouldCancel
            )
        }
        let current: BoundPair
        switch currentResolution {
        case .available(let pair):
            current = pair
        case .missing, .unavailable:
            throw PublishedResultPairError.invalidSource
        }
        if let expectedGeneration,
           !generation(
                current,
                matches: expectedGeneration,
                allowingFirstViewerReadySeconds: seconds
           ) {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing predecessor changed"
            )
        }
        guard current.result.receipt.publicationID == expectedPublicationID else {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing belongs to a stale publication"
            )
        }
        if let recorded = current.result.receipt.presentation
            .createToViewerReadySeconds {
            guard recorded == seconds else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing was already recorded"
                )
            }
            return current.result
        }
        try checkCancellation(shouldCancel)

        let updatedReceipt = receipt(
            current.result.receipt,
            recordingFirstViewerReadySeconds: seconds
        )
        return try commitReceiptReplacement(
            updatedReceipt,
            output: output,
            current: current,
            operations: operations,
            shouldCancel: shouldCancel
        )
    }

    /// Rebinds result-era stage timings to the exact validated publication
    /// without reopening or hashing the canonical PLY payload.
    package static func recordStageTimings(
        _ stageTimings: [StageTimingRecord],
        expectedGeneration: PublishedResultGeneration,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        operations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ValidatedPublishedResult {
        try checkCancellation(shouldCancel)
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let reconciled = try reconcileLocked(
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        )
        let resolution: PairResolution
        if let reconciled {
            resolution = reconciled
        } else {
            resolution = try resolveCanonicalPair(
                output: output,
                expectedGeneration: expectedGeneration,
                shouldCancel: shouldCancel
            )
        }
        let current: BoundPair
        switch resolution {
        case .available(let pair):
            current = pair
        case .missing, .unavailable:
            throw PublishedResultPairError.invalidSource
        }
        guard generation(
            current,
            matches: expectedGeneration,
            allowingFirstViewerReadySeconds: nil
        ) else {
            throw PublishedResultPairError.publicationConflict(
                "stage timings belong to a stale publication"
            )
        }
        if current.result.receipt.presentation.stageTimings == stageTimings {
            return current.result
        }
        try checkCancellation(shouldCancel)
        return try commitReceiptReplacement(
            receipt(
                current.result.receipt,
                recordingStageTimings: stageTimings
            ),
            output: output,
            current: current,
            operations: operations,
            shouldCancel: shouldCancel,
            allowPublicationTimeAdvance: true
        )
    }

    fileprivate static func commitReceiptReplacement(
        _ updatedReceipt: PublishedSplatReceipt,
        output: BoundOutput,
        current: BoundPair,
        operations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool,
        allowPublicationTimeAdvance: Bool = false
    ) throws -> ValidatedPublishedResult {
        let latestStageCompletion = updatedReceipt.presentation.stageTimings
            .reduce(current.result.receipt.publishedAt) { latest, timing in
                let completed = timing.startedAt.addingTimeInterval(
                    timing.durationSeconds
                )
                return completed > latest ? completed : latest
            }
        let publicationTimeIsValid = updatedReceipt.publishedAt
            == current.result.receipt.publishedAt
            || (allowPublicationTimeAdvance
                && updatedReceipt.publishedAt == latestStageCompletion)
        guard updatedReceipt.schemaVersion == current.result.receipt.schemaVersion,
              updatedReceipt.publicationID == current.result.receipt.publicationID,
              updatedReceipt.projectID == current.result.receipt.projectID,
              publicationTimeIsValid,
              updatedReceipt.outputPath == current.result.receipt.outputPath,
              updatedReceipt.outputEvidence == current.result.outputEvidence,
              updatedReceipt.lineage == current.result.receipt.lineage else {
            throw PublishedResultPairError.invalidSource
        }
        let updatedData: Data
        do {
            updatedData = try PublishedSplatReceiptStore.encode(updatedReceipt)
        } catch {
            throw PublishedResultPairError.invalidSource
        }
        let transaction = try ReceiptTransactionDirectory.create(
            output: output,
            current: current,
            updatedReceiptData: updatedData,
            operations: operations
        )
        var swapCompleted = false
        var commitDurable = false
        do {
            try checkCancellation(shouldCancel)
            try output.revalidate()
            try transaction.requirePreSwapState(output: output)

            let swapResult = operations.swap(
                transaction.descriptor,
                Names.receiptCandidate,
                output.descriptor,
                Names.canonicalReceipt
            )
            guard swapResult == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "commit viewer timing receipt",
                    code: errno
                )
            }
            swapCompleted = true
            try synchronizeDirectories(
                [transaction.descriptor, output.descriptor],
                operations: operations,
                operation: "commit viewer timing receipt"
            )
            commitDurable = true

            let committed = try transaction.requirePostSwapState(
                output: output,
                operations: operations,
                previouslyValidated: current,
                shouldCancel: { false }
            )
            transaction.retireAfterCommit(output: output, operations: operations)
            return committed.result
        } catch {
            if swapCompleted {
                let committed = try? transaction.requirePostSwapState(
                    output: output,
                    operations: operations,
                    previouslyValidated: current,
                    shouldCancel: { false }
                )
                if let committed, commitDurable {
                    transaction.retireAfterCommit(
                        output: output,
                        operations: operations
                    )
                    return committed.result
                }
                try transaction.rollbackSwapIfOwned(
                    output: output,
                    operations: operations
                )
            }
            transaction.retireBeforeCommit(output: output, operations: operations)
            throw error
        }
    }

#if DEBUG
    package static func testCreateTransactionFixture(
        projectPaths: ProjectPaths,
        transactionID: UUID,
        publicationID: UUID,
        previousPublicationID: UUID?
    ) throws -> URL {
        let operations = PublishedResultPairOperations.system()
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            operations: operations
        )
        let active = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 256
        ).filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionPrefix,
                output: output
            )
        }
        guard active.isEmpty else {
            throw PublishedResultPairError.publicationConflict(
                "a test transaction already exists"
            )
        }
        let previousPairIdentities: PreviousPairJournalIdentities?
        if previousPublicationID != nil {
            previousPairIdentities = PreviousPairJournalIdentities(
                ply: JournalFileIdentity(try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalPly,
                    exactMode: 0o600
                )),
                receipt: JournalFileIdentity(try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt,
                    exactMode: 0o600
                ))
            )
        } else {
            previousPairIdentities = nil
        }
        let transaction = try TransactionDirectory.create(
            output: output,
            transactionID: transactionID,
            publicationID: publicationID,
            previousPublicationID: previousPublicationID,
            previousPairIdentities: previousPairIdentities,
            operations: operations
        )
        return projectPaths.outputURL.appendingPathComponent(
            transaction.leaf,
            isDirectory: true
        )
    }

    package static func testRecordTransactionFixturePhase(
        _ phase: PublishedResultPairJournalPhase,
        projectPaths: ProjectPaths,
        transactionID: UUID
    ) throws {
        let operations = PublishedResultPairOperations.system()
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            operations: operations
        )
        let leaf = Names.transactionPrefix + transactionID.uuidString.lowercased()
        let ephemeralOwnedNames: Set<String>
        switch phase {
        case .newPlyDurable:
            ephemeralOwnedNames = [Names.newPly]
        case .newReceiptDurable:
            ephemeralOwnedNames = [Names.newReceipt]
        default:
            ephemeralOwnedNames = []
        }
        let transaction = try TransactionDirectory.openRecovered(
            output: output,
            leaf: leaf,
            testingEphemeralOwnedNames: ephemeralOwnedNames
        )
        let expected = journalTrajectory(
            hasPrevious: transaction.previousPublicationID != nil
        )
        guard let current = transaction.lastJournal?.phase,
              let index = expected.firstIndex(of: current),
              expected.indices.contains(index + 1),
              expected[index + 1] == phase else {
            throw PublishedResultPairError.publicationConflict(
                "test journal phases must be contiguous"
            )
        }
        switch phase {
        case .previousPlyMoved:
            guard transaction.previousPublicationID != nil else {
                throw PublishedResultPairError.publicationConflict(
                    "test transaction has no previous publication"
                )
            }
            let expected = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            try moveExpected(
                from: output.descriptor,
                name: Names.canonicalPly,
                expected: expected,
                to: transaction.descriptor,
                destinationName: Names.oldPly,
                operations: operations,
                operation: "build previous-PLY test fixture",
                didRename: {}
            )
            try synchronizeDirectories(
                [output.descriptor, transaction.descriptor],
                operations: operations,
                operation: "build previous-PLY test fixture"
            )
        case .previousPairMoved:
            guard transaction.previousPublicationID != nil else {
                throw PublishedResultPairError.publicationConflict(
                    "test transaction has no previous publication"
                )
            }
            let expected = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            try moveExpected(
                from: output.descriptor,
                name: Names.canonicalReceipt,
                expected: expected,
                to: transaction.descriptor,
                destinationName: Names.oldReceipt,
                operations: operations,
                operation: "build previous-receipt test fixture",
                didRename: {}
            )
            try synchronizeDirectories(
                [output.descriptor, transaction.descriptor],
                operations: operations,
                operation: "build previous-receipt test fixture"
            )
        case .newPlyInstalled:
            guard let expected = transaction.lastJournal?
                .ownedFiles[Names.newPly]?.identity else {
                throw PublishedResultPairError.publicationConflict(
                    "test transaction has no staged PLY"
                )
            }
            try moveExpected(
                from: transaction.descriptor,
                name: Names.newPly,
                expected: expected,
                to: output.descriptor,
                destinationName: Names.canonicalPly,
                operations: operations,
                operation: "install test fixture PLY",
                didRename: {}
            )
            try synchronizeDirectories(
                [transaction.descriptor, output.descriptor],
                operations: operations,
                operation: "install test fixture PLY"
            )
        case .receiptCommitted:
            guard let expected = transaction.lastJournal?
                .ownedFiles[Names.newReceipt]?.identity else {
                throw PublishedResultPairError.publicationConflict(
                    "test transaction has no staged receipt"
                )
            }
            try moveExpected(
                from: transaction.descriptor,
                name: Names.newReceipt,
                expected: expected,
                to: output.descriptor,
                destinationName: Names.canonicalReceipt,
                operations: operations,
                operation: "commit test fixture receipt",
                didRename: {}
            )
            try synchronizeDirectories(
                [transaction.descriptor, output.descriptor],
                operations: operations,
                operation: "commit test fixture receipt"
            )
        case .created, .newPlyDurable, .newReceiptDurable, .prepared, .validated:
            break
        }
        try transaction.record(
            phase: phase,
            output: phase.rawValue
                >= PublishedResultPairJournalPhase.newPlyInstalled.rawValue
                ? output : nil,
            operations: operations
        )
    }

    package static func testOverwriteTransactionFixtureFile(
        named name: String,
        data: Data,
        projectPaths: ProjectPaths,
        transactionID: UUID
    ) throws {
        guard name == Names.newPly || name == Names.newReceipt else {
            throw PublishedResultPairError.publicationConflict(
                "unsupported test transaction fixture file"
            )
        }
        let operations = PublishedResultPairOperations.system()
        let output = try BoundOutput.acquire(
            projectPaths: projectPaths,
            operations: operations
        )
        let leaf = Names.transactionPrefix + transactionID.uuidString.lowercased()
        let transaction = try TransactionDirectory.openRecovered(
            output: output,
            leaf: leaf
        )
        if entryPresence(parent: transaction.descriptor, name: name) == .present {
            let currentIdentity = try namedFileIdentity(
                parent: transaction.descriptor,
                name: name,
                exactMode: 0o600
            )
            guard let plannedIdentity = transaction.lastJournal?
                .ownedFiles[name]?.identity,
                  currentIdentity.sameInode(as: plannedIdentity) else {
                throw PublishedResultPairError.publicationConflict(
                    "test transaction fixture file changed"
                )
            }
            transaction.ephemeralOwnedFiles[name] = currentIdentity
        }
        _ = try transaction.writePrivateFile(
            named: name,
            data: data,
            operations: operations
        )
    }
#endif
}

private extension PublishedResultPairStore {
    enum Names {
        static let canonicalPly = "splat.ply"
        static let canonicalReceipt = "splat_receipt.json"
        static let lock = ".published-result.lock"
        static let transactionBuildPrefix = ".published-result-build-"
        static let transactionBuildAuthorityPrefix =
            ".published-result-build-authority-"
        static let transactionPrefix = ".published-result-tx-"
        static let retiredPrefix = ".published-result-retired-"
        static let receiptTransactionBuildPrefix = ".published-receipt-build-"
        static let receiptTransactionBuildAuthorityPrefix =
            ".published-receipt-build-authority-"
        static let receiptTransactionPrefix = ".published-receipt-tx-"
        static let receiptRetiredPrefix = ".published-receipt-retired-"
        static let receiptCleanupPrefix = ".published-receipt-cleanup-"
        static let receiptCreatedJournal = "journal-created.json"
        static let receiptPreparedJournal = "journal-prepared.json"
        static let receiptCandidate = "next-receipt.json"
        static let receiptCleanupStaged = "parent-cleanup-authority.json"
        static let receiptDisplacedIdentity = "displaced-receipt-identity"
        static let newPly = "new.ply"
        static let newReceipt = "new-receipt.json"
        static let oldPly = "old.ply"
        static let oldReceipt = "old-receipt.json"
        static let cleanupAuthorization = "cleanup-authorized.json"
        static let cleanupAuthorizationPending = cleanupAuthorization + ".pending"
    }

    enum PairResolution {
        case missing
        case available(BoundPair)
        case unavailable(PublishedResultUnavailability)

        var availability: PublishedResultAvailability {
            switch self {
            case .missing:
                return .unavailable(.missingPair)
            case .available(let pair):
                return .available(pair.result)
            case .unavailable(let reason):
                return .unavailable(reason)
            }
        }
    }

    struct BoundPair {
        let result: ValidatedPublishedResult
        let plyIdentity: FileIdentity
        let receiptIdentity: FileIdentity
        let receiptData: Data
    }

    enum ReceiptJournalPhase: String, Codable {
        case created
        case prepared
    }

    struct ReceiptJournalDocument: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let publicationID: UUID
        let phase: ReceiptJournalPhase
        let plyIdentity: JournalFileIdentity
        let oldReceiptIdentity: JournalFileIdentity
        let newReceiptIdentity: JournalFileIdentity?
        let cleanupAuthorizationIdentity: JournalFileIdentity
        let oldReceiptSHA256: String
        let newReceiptSHA256: String
    }

    struct JournalDocument: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let publicationID: UUID
        let previousPublicationID: UUID?
        let previousPairIdentities: PreviousPairJournalIdentities?
        let canonicalPlyIdentity: JournalFileIdentity?
        let canonicalReceiptIdentity: JournalFileIdentity?
        let phase: PublishedResultPairJournalPhase
        let ownedFiles: [String: JournalFileIdentity]
    }

    struct BuildAuthorizationDocument: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let publicationID: UUID
        let previousPublicationID: UUID?
        let previousPairIdentities: PreviousPairJournalIdentities?
        let directoryIdentity: JournalDirectoryIdentity

        var isPrecreationIntent: Bool {
            schemaVersion == 2 && directoryIdentity.isUnboundIntent
        }
    }

    struct ReceiptBuildAuthorizationDocument: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let publicationID: UUID
        let directoryIdentity: JournalDirectoryIdentity
        let plyIdentity: JournalFileIdentity
        let oldReceiptIdentity: JournalFileIdentity
        let oldReceiptSHA256: String
        let newReceiptSHA256: String
        let ownedFiles: [String: JournalFileIdentity]

        var isPrecreationIntent: Bool {
            schemaVersion == 2
                && directoryIdentity.isUnboundIntent
                && ownedFiles.isEmpty
        }
    }

    struct PreviousPairJournalIdentities: Codable, Equatable {
        let ply: JournalFileIdentity
        let receipt: JournalFileIdentity
    }

    struct CleanupJournalDocument: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let publicationID: UUID
        let previousPublicationID: UUID?
        let directoryIdentity: JournalDirectoryIdentity
        let ownedFiles: [String: JournalFileIdentity]
    }

    struct JournalDirectoryIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: uid_t
        let mode: mode_t

        init(device: UInt64, inode: UInt64, owner: uid_t, mode: mode_t) {
            self.device = device
            self.inode = inode
            self.owner = owner
            self.mode = mode
        }

        static var unboundIntent: Self {
            Self(device: 0, inode: 0, owner: getuid(), mode: 0)
        }

        var isUnboundIntent: Bool {
            device == 0 && inode == 0 && owner == getuid() && mode == 0
        }

        init(_ identity: DirectoryIdentity) {
            device = identity.device
            inode = identity.inode
            owner = identity.owner
            mode = identity.mode
        }

        var identity: DirectoryIdentity {
            DirectoryIdentity(
                device: device,
                inode: inode,
                owner: owner,
                mode: mode
            )
        }
    }

    struct JournalFileIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let owner: uid_t
        let mode: mode_t
        let linkCount: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ identity: FileIdentity) {
            device = identity.device
            inode = identity.inode
            byteCount = identity.byteCount
            owner = identity.owner
            mode = identity.mode
            linkCount = identity.linkCount
            modifiedSeconds = identity.modifiedSeconds
            modifiedNanoseconds = identity.modifiedNanoseconds
            changedSeconds = identity.changedSeconds
            changedNanoseconds = identity.changedNanoseconds
        }

        var identity: FileIdentity {
            FileIdentity(
                device: device,
                inode: inode,
                byteCount: byteCount,
                owner: owner,
                mode: mode,
                linkCount: linkCount,
                modifiedSeconds: modifiedSeconds,
                modifiedNanoseconds: modifiedNanoseconds,
                changedSeconds: changedSeconds,
                changedNanoseconds: changedNanoseconds
            )
        }
    }

    struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: uid_t
        let mode: mode_t

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            owner = status.st_uid
            mode = status.st_mode
        }

        init(device: UInt64, inode: UInt64, owner: uid_t, mode: mode_t) {
            self.device = device
            self.inode = inode
            self.owner = owner
            self.mode = mode
        }
    }

    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let owner: uid_t
        let mode: mode_t
        let linkCount: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            byteCount = status.st_size
            owner = status.st_uid
            mode = status.st_mode
            linkCount = UInt64(status.st_nlink)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }

        init(
            device: UInt64,
            inode: UInt64,
            byteCount: Int64,
            owner: uid_t,
            mode: mode_t,
            linkCount: UInt64,
            modifiedSeconds: Int64,
            modifiedNanoseconds: Int64,
            changedSeconds: Int64,
            changedNanoseconds: Int64
        ) {
            self.device = device
            self.inode = inode
            self.byteCount = byteCount
            self.owner = owner
            self.mode = mode
            self.linkCount = linkCount
            self.modifiedSeconds = modifiedSeconds
            self.modifiedNanoseconds = modifiedNanoseconds
            self.changedSeconds = changedSeconds
            self.changedNanoseconds = changedNanoseconds
        }

        func sameObject(as other: Self) -> Bool {
            device == other.device
                && inode == other.inode
                && byteCount == other.byteCount
                && owner == other.owner
                && mode == other.mode
                && linkCount == other.linkCount
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }

        func sameUnchangedFile(as other: Self) -> Bool {
            sameObject(as: other)
                && changedSeconds == other.changedSeconds
                && changedNanoseconds == other.changedNanoseconds
        }

        func sameInode(as other: Self) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    final class BoundOutput {
        let projectPaths: ProjectPaths
        let rootDescriptor: Int32
        let descriptor: Int32
        let lockDescriptor: Int32
        let rootIdentity: DirectoryIdentity
        let outputIdentity: DirectoryIdentity
        let lockIdentity: FileIdentity
        let caseSensitiveNames: Bool

        init(
            projectPaths: ProjectPaths,
            rootDescriptor: Int32,
            descriptor: Int32,
            lockDescriptor: Int32,
            rootIdentity: DirectoryIdentity,
            outputIdentity: DirectoryIdentity,
            lockIdentity: FileIdentity,
            caseSensitiveNames: Bool
        ) {
            self.projectPaths = projectPaths
            self.rootDescriptor = rootDescriptor
            self.descriptor = descriptor
            self.lockDescriptor = lockDescriptor
            self.rootIdentity = rootIdentity
            self.outputIdentity = outputIdentity
            self.lockIdentity = lockIdentity
            self.caseSensitiveNames = caseSensitiveNames
        }

        deinit {
            unlockOpenFileDescription(lockDescriptor)
            Darwin.close(lockDescriptor)
            Darwin.close(descriptor)
            Darwin.close(rootDescriptor)
        }

        static func acquire(
            projectPaths: ProjectPaths,
            projectRootDescriptor: Int32? = nil,
            operations: PublishedResultPairOperations,
            shouldCancel: @escaping @Sendable () -> Bool = { false }
        ) throws -> BoundOutput {
            guard projectPaths.publishedResultLockURL.path
                    == projectPaths.root.appendingPathComponent(
                        "Output/.published-result.lock"
                    ).path else {
                throw PublishedResultPairError.unsafeOutput
            }
            try checkCancellation(shouldCancel)
            let rootBinding = try acquireProjectRootDescriptor(
                projectPaths: projectPaths,
                suppliedDescriptor: projectRootDescriptor,
                operations: operations
            )
            let root = rootBinding.descriptor
            var output: Int32 = -1
            var lockDescriptor: Int32 = -1
            var ownershipTransferred = false
            defer {
                if !ownershipTransferred {
                    if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
                    if output >= 0 { Darwin.close(output) }
                    Darwin.close(root)
                }
            }
            let rootIdentity = rootBinding.identity
            try checkCancellation(shouldCancel)
            output = "Output".withCString {
                Darwin.openat(
                    root,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard output >= 0 else { throw PublishedResultPairError.unsafeOutput }
            let outputIdentity = try requireBoundChildDirectory(
                descriptor: output,
                parent: root,
                name: "Output",
                exactMode: nil
            )
            guard try requireBoundAbsoluteDirectory(
                descriptor: root,
                path: projectPaths.root.path
            ) == rootIdentity,
            try requireBoundChildDirectory(
                descriptor: output,
                parent: root,
                name: "Output",
                exactMode: nil
            ) == outputIdentity else {
                throw PublishedResultPairError.unsafeOutput
            }
            let caseSensitivity = operations.volumeCaseSensitivity(output)
            guard caseSensitivity == 0 || caseSensitivity == 1 else {
                throw PublishedResultPairError.unsafeOutput
            }
            let caseSensitiveNames = caseSensitivity == 1
            try checkCancellation(shouldCancel)
            let lock = try openLock(output: output, operations: operations)
            lockDescriptor = lock.descriptor
            operations.didReachCheckpoint(.lockWaitStarted)
            try lockOpenFileDescription(
                lockDescriptor,
                shouldCancel: shouldCancel
            )
            operations.didReachCheckpoint(.lockAcquired)
            let lockedIdentity = try requireBoundFile(
                descriptor: lockDescriptor,
                parent: output,
                name: Names.lock,
                exactMode: 0o600
            )
            guard lockedIdentity.sameObject(as: lock.identity) else {
                throw PublishedResultPairError.unsafeOutput
            }
            let bound = BoundOutput(
                projectPaths: projectPaths,
                rootDescriptor: root,
                descriptor: output,
                lockDescriptor: lockDescriptor,
                rootIdentity: rootIdentity,
                outputIdentity: outputIdentity,
                lockIdentity: lockedIdentity,
                caseSensitiveNames: caseSensitiveNames
            )
            ownershipTransferred = true
            try bound.revalidate()
            return bound
        }

        func revalidate() throws {
            guard try requireBoundAbsoluteDirectory(
                descriptor: rootDescriptor,
                path: projectPaths.root.path
            ) == rootIdentity,
            try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: rootDescriptor,
                name: "Output",
                exactMode: nil
            ) == outputIdentity,
            try requireBoundFile(
                descriptor: lockDescriptor,
                parent: descriptor,
                name: Names.lock,
                exactMode: 0o600
            ).sameObject(as: lockIdentity) else {
                throw PublishedResultPairError.unsafeOutput
            }
        }
    }

    final class BoundSource {
        struct BoundDirectory {
            let name: String
            let descriptor: Int32
            let identity: DirectoryIdentity
        }

        let output: BoundOutput
        let directories: [BoundDirectory]
        let leaf: String
        let descriptor: Int32
        let identity: FileIdentity
        let evidence: ValidatedPlyArtifactEvidence

        init(
            output: BoundOutput,
            directories: [BoundDirectory],
            leaf: String,
            descriptor: Int32,
            identity: FileIdentity,
            evidence: ValidatedPlyArtifactEvidence
        ) {
            self.output = output
            self.directories = directories
            self.leaf = leaf
            self.descriptor = descriptor
            self.identity = identity
            self.evidence = evidence
        }

        deinit {
            Darwin.close(descriptor)
            for directory in directories.reversed() {
                Darwin.close(directory.descriptor)
            }
        }

        static func open(
            projectRelativePath: String,
            output: BoundOutput,
            operations: PublishedResultPairOperations,
            shouldCancel: @escaping @Sendable () -> Bool
        ) throws -> BoundSource {
            let components = try projectRelativeSourceComponents(
                projectRelativePath
            )
            let leaf = components[components.count - 1]
            var directories: [BoundDirectory] = []
            var parent = output.rootDescriptor
            var descriptor: Int32 = -1
            var ownershipTransferred = false
            defer {
                if !ownershipTransferred {
                    if descriptor >= 0 { Darwin.close(descriptor) }
                    for directory in directories.reversed() {
                        Darwin.close(directory.descriptor)
                    }
                }
            }
            do {
                for component in components.dropLast() {
                    let opened = component.withCString {
                        Darwin.openat(
                            parent,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard opened >= 0 else {
                        throw PublishedResultPairError.invalidSource
                    }
                    let identity: DirectoryIdentity
                    do {
                        identity = try requireBoundChildDirectory(
                            descriptor: opened,
                            parent: parent,
                            name: component,
                            exactMode: nil
                        )
                    } catch {
                        Darwin.close(opened)
                        throw PublishedResultPairError.invalidSource
                    }
                    directories.append(BoundDirectory(
                        name: component,
                        descriptor: opened,
                        identity: identity
                    ))
                    parent = opened
                }
                descriptor = openReadOnly(parent: parent, name: leaf)
                guard descriptor >= 0 else {
                    throw PublishedResultPairError.invalidSource
                }
                let identity = try requireBoundFile(
                    descriptor: descriptor,
                    parent: parent,
                    name: leaf,
                    exactMode: nil
                )
                operations.willValidatePly(leaf)
                let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
                    descriptor: descriptor,
                    label: leaf,
                    shouldCancel: shouldCancel
                )
                let bound = BoundSource(
                    output: output,
                    directories: directories,
                    leaf: leaf,
                    descriptor: descriptor,
                    identity: identity,
                    evidence: evidence
                )
                try bound.revalidatePath()
                ownershipTransferred = true
                return bound
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PublishedResultPairError.invalidSource
            }
        }

        func revalidatePath() throws {
            do {
                try output.revalidate()
                var parent = output.rootDescriptor
                for directory in directories {
                    guard try requireBoundChildDirectory(
                        descriptor: directory.descriptor,
                        parent: parent,
                        name: directory.name,
                        exactMode: nil
                    ) == directory.identity else {
                        throw PublishedResultPairError.invalidSource
                    }
                    parent = directory.descriptor
                }
                guard try requireBoundFile(
                    descriptor: descriptor,
                    parent: parent,
                    name: leaf,
                    exactMode: nil
                ) == identity else {
                    throw PublishedResultPairError.invalidSource
                }
            } catch {
                throw PublishedResultPairError.invalidSource
            }
        }
    }

    final class TransactionDirectory {
        let leaf: String
        let transactionID: UUID
        let publicationID: UUID
        let previousPublicationID: UUID?
        let previousPairIdentities: PreviousPairJournalIdentities?
        let descriptor: Int32
        let identity: DirectoryIdentity
        var lastJournal: JournalDocument?
        var cleanupAuthorization: CleanupJournalDocument?
        var cleanupAuthorizationFileIdentity: FileIdentity?
        var ownedFileHistory: [String: [FileIdentity]]
        var ephemeralOwnedFiles: [String: FileIdentity]

        init(
            leaf: String,
            transactionID: UUID,
            publicationID: UUID,
            previousPublicationID: UUID?,
            previousPairIdentities: PreviousPairJournalIdentities? = nil,
            descriptor: Int32,
            identity: DirectoryIdentity,
            lastJournal: JournalDocument? = nil,
            cleanupAuthorization: CleanupJournalDocument? = nil,
            cleanupAuthorizationFileIdentity: FileIdentity? = nil,
            ownedFileHistory: [String: [FileIdentity]] = [:]
        ) {
            self.leaf = leaf
            self.transactionID = transactionID
            self.publicationID = publicationID
            self.previousPublicationID = previousPublicationID
            self.previousPairIdentities = previousPairIdentities
            self.descriptor = descriptor
            self.identity = identity
            self.lastJournal = lastJournal
            self.cleanupAuthorization = cleanupAuthorization
            self.cleanupAuthorizationFileIdentity = cleanupAuthorizationFileIdentity
            self.ownedFileHistory = ownedFileHistory
            ephemeralOwnedFiles = [:]
        }

        deinit { Darwin.close(descriptor) }

        static func create(
            output: BoundOutput,
            transactionID: UUID,
            publicationID: UUID,
            previousPublicationID: UUID?,
            previousPairIdentities: PreviousPairJournalIdentities?,
            operations: PublishedResultPairOperations
        ) throws -> TransactionDirectory {
            let leaf = Names.transactionPrefix + transactionID.uuidString.lowercased()
            let buildLeaf = Names.transactionBuildPrefix
                + transactionID.uuidString.lowercased()
            let authorityLeaf = Names.transactionBuildAuthorityPrefix
                + transactionID.uuidString.lowercased()
                + ".json"
            let authorization = BuildAuthorizationDocument(
                schemaVersion: 2,
                transactionID: transactionID,
                publicationID: publicationID,
                previousPublicationID: previousPublicationID,
                previousPairIdentities: previousPairIdentities,
                directoryIdentity: .unboundIntent
            )
            let authorizationData = try encodeBuildAuthorization(authorization)
            let authorityIdentity = try writeOutputPrivateFile(
                parent: output.descriptor,
                pendingName: authorityLeaf + ".pending",
                finalName: authorityLeaf,
                data: authorizationData,
                operations: operations,
                operation: "authorize publication build"
            )
            operations.didReachCheckpoint(.transactionBuildOwnershipDurable)
            try output.revalidate()
            var buildCreated = false
            var transaction: TransactionDirectory?
            var activated = false
            do {
                let created = buildLeaf.withCString {
                    Darwin.mkdirat(output.descriptor, $0, mode_t(0o700))
                }
                guard created == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "create publication transaction",
                        code: errno
                    )
                }
                buildCreated = true
                try syncDirectory(
                    output.descriptor,
                    operations: operations,
                    operation: "create publication transaction"
                )
                guard let identity = try optionalChildDirectoryIdentity(
                    parent: output.descriptor,
                    name: buildLeaf,
                    exactMode: 0o700
                ) else {
                    throw PublishedResultPairError.publicationConflict(
                        "new publication build directory disappeared"
                    )
                }
                let descriptor = operations.openTransactionDirectory(
                    output.descriptor,
                    buildLeaf
                )
                guard descriptor >= 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "open publication transaction",
                        code: errno
                    )
                }
                var descriptorTransferred = false
                defer {
                    if !descriptorTransferred { Darwin.close(descriptor) }
                }
                guard try requireBoundChildDirectory(
                    descriptor: descriptor,
                    parent: output.descriptor,
                    name: buildLeaf,
                    exactMode: 0o700
                ) == identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "new publication build directory changed"
                    )
                }
                let createdTransaction = TransactionDirectory(
                    leaf: leaf,
                    transactionID: transactionID,
                    publicationID: publicationID,
                    previousPublicationID: previousPublicationID,
                    previousPairIdentities: previousPairIdentities,
                    descriptor: descriptor,
                    identity: identity
                )
                transaction = createdTransaction
                descriptorTransferred = true
                try createdTransaction.record(phase: .created, operations: operations)
                try output.revalidate()
                guard operations.renameExclusive(
                    output.descriptor,
                    buildLeaf,
                    output.descriptor,
                    leaf
                ) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "activate publication transaction",
                        code: errno
                    )
                }
                activated = true
                try syncDirectory(
                    output.descriptor,
                    operations: operations,
                    operation: "create publication transaction"
                )
                guard try requireBoundChildDirectory(
                    descriptor: descriptor,
                    parent: output.descriptor,
                    name: leaf,
                    exactMode: 0o700
                ) == identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "activated publication transaction changed"
                    )
                }
                try quarantineAndRemoveOwnedEntry(
                    parent: output.descriptor,
                    name: authorityLeaf,
                    expected: authorityIdentity,
                    operations: operations,
                    operation: "retire publication build authority"
                )
                try output.revalidate()
                return createdTransaction
            } catch {
                if activated, let transaction {
                    do {
                        try transaction.discardUncommitted(
                            output: output,
                            operations: operations
                        )
                    } catch {
                        try? transaction.discardUncommitted(
                            output: output,
                            operations: operations,
                            transactionLeaf: buildLeaf
                        )
                    }
                } else if let transaction {
                    let discarded = (try? transaction.discardInactiveBuildBeforeActivation(
                        output: output,
                        operations: operations,
                        buildLeaf: buildLeaf
                    )) != nil
                    if discarded,
                       let current = try? namedFileIdentity(
                        parent: output.descriptor,
                        name: authorityLeaf,
                        exactMode: 0o600
                       ), current.sameInode(as: authorityIdentity) {
                        try? quarantineAndRemoveOwnedEntry(
                            parent: output.descriptor,
                            name: authorityLeaf,
                            expected: current,
                            operations: operations,
                            operation: "discard publication build authority"
                        )
                    }
                } else if buildCreated {
                    let discarded = (try? removeEmptyTransactionDirectory(
                        output: output,
                        leaf: buildLeaf,
                        operations: operations
                    )) != nil
                    if discarded,
                       let current = try? namedFileIdentity(
                        parent: output.descriptor,
                        name: authorityLeaf,
                        exactMode: 0o600
                       ), current.sameInode(as: authorityIdentity) {
                        try? quarantineAndRemoveOwnedEntry(
                            parent: output.descriptor,
                            name: authorityLeaf,
                            expected: current,
                            operations: operations,
                            operation: "discard publication build authority"
                        )
                    }
                } else if let current = try? namedFileIdentity(
                    parent: output.descriptor,
                    name: authorityLeaf,
                    exactMode: 0o600
                ), current.sameInode(as: authorityIdentity) {
                    try? quarantineAndRemoveOwnedEntry(
                        parent: output.descriptor,
                        name: authorityLeaf,
                        expected: current,
                        operations: operations,
                        operation: "discard publication build authority"
                    )
                }
                throw error
            }
        }

        static func openRecovered(
            output: BoundOutput,
            leaf: String,
            prefix: String = Names.transactionPrefix,
            testingEphemeralOwnedNames: Set<String> = []
        ) throws -> TransactionDirectory {
            guard prefix == Names.transactionPrefix
                    || prefix == Names.transactionBuildPrefix
                    || prefix == Names.retiredPrefix,
                  leaf.hasPrefix(prefix) else {
                throw PublishedResultPairError.publicationConflict(
                    "unknown transaction name"
                )
            }
            let suffix = String(leaf.dropFirst(prefix.count))
            guard let transactionID = UUID(uuidString: suffix),
                  transactionID.uuidString.lowercased() == suffix else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed transaction identity"
                )
            }
            let descriptor = leaf.withCString {
                Darwin.openat(
                    output.descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw PublishedResultPairError.publicationConflict(
                    "unsafe transaction directory"
                )
            }
            var ownershipTransferred = false
            defer {
                if !ownershipTransferred { Darwin.close(descriptor) }
            }
            let identity = try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: output.descriptor,
                name: leaf,
                exactMode: 0o700
            )
            let names = try directoryNames(descriptor: descriptor, maximumCount: 32)
            let dataNames = Set([
                Names.newPly, Names.newReceipt, Names.oldPly, Names.oldReceipt,
            ])
            let journalNames = Set(
                PublishedResultPairJournalPhase.allCases.map(\.leaf)
                    + PublishedResultPairJournalPhase.allCases.map(\.pendingLeaf)
                    + [
                        Names.cleanupAuthorization,
                        Names.cleanupAuthorizationPending,
                    ]
            )
            let ordinaryNames = dataNames.union(journalNames)
            let quarantineNames = Set(ordinaryNames.map(cleanupQuarantineName))
            guard testingEphemeralOwnedNames.isSubset(of: dataNames) else {
                throw PublishedResultPairError.publicationConflict(
                    "unsupported ephemeral transaction ownership"
                )
            }
            guard Set(names).isSubset(of: ordinaryNames.union(quarantineNames)) else {
                throw PublishedResultPairError.publicationConflict(
                    "unknown transaction entry"
                )
            }
            let presentPhases = PublishedResultPairJournalPhase.allCases.filter {
                names.contains($0.leaf)
            }
            guard let createdData = try? readPrivateFile(
                parent: descriptor,
                name: PublishedResultPairJournalPhase.created.leaf,
                maximumBytes: 65_536
            ), let createdDocument = try? decodeJournal(createdData) else {
                throw PublishedResultPairError.publicationConflict(
                    "publication journal is incomplete"
                )
            }
            let trajectory = journalTrajectory(
                hasPrevious: createdDocument.previousPublicationID != nil
            )
            guard let latestPhase = presentPhases.last,
                  let latestIndex = trajectory.firstIndex(of: latestPhase),
                  presentPhases == Array(trajectory.prefix(latestIndex + 1)) else {
                throw PublishedResultPairError.publicationConflict(
                    "publication journal is incomplete"
                )
            }

            var documents: [JournalDocument] = []
            for phase in presentPhases {
                let data = try readPrivateFile(
                    parent: descriptor,
                    name: phase.leaf,
                    maximumBytes: 65_536
                )
                let document = try decodeJournal(data)
                guard document.phase == phase,
                      document.transactionID == transactionID else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication journal identity mismatch"
                    )
                }
                documents.append(document)
            }
            guard let first = documents.first,
                  documents.allSatisfy({
                      $0.schemaVersion == 3
                          && $0.transactionID == first.transactionID
                          && $0.publicationID == first.publicationID
                          && $0.previousPublicationID == first.previousPublicationID
                          && $0.previousPairIdentities == first.previousPairIdentities
                  }), let latest = documents.last else {
                throw PublishedResultPairError.publicationConflict(
                    "publication journal history mismatch"
                )
            }
            var installedPly: JournalFileIdentity?
            var installedReceipt: JournalFileIdentity?
            for document in documents {
                switch document.phase {
                case .created, .newPlyDurable, .newReceiptDurable, .prepared,
                     .previousPlyMoved, .previousPairMoved:
                    guard document.canonicalPlyIdentity == nil,
                          document.canonicalReceiptIdentity == nil else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication journal records premature canonical authority"
                        )
                    }
                case .newPlyInstalled:
                    guard let currentPly = document.canonicalPlyIdentity,
                          document.canonicalReceiptIdentity == nil else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication journal lacks installed PLY authority"
                        )
                    }
                    installedPly = currentPly
                case .receiptCommitted, .validated:
                    guard let currentPly = document.canonicalPlyIdentity,
                          let currentReceipt = document.canonicalReceiptIdentity,
                          installedPly == nil || installedPly == currentPly,
                          installedReceipt == nil || installedReceipt == currentReceipt else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication journal canonical authority changed"
                        )
                    }
                    installedPly = currentPly
                    installedReceipt = currentReceipt
                }
            }
            guard (first.previousPublicationID == nil)
                    == (first.previousPairIdentities == nil) else {
                throw PublishedResultPairError.publicationConflict(
                    "publication journal previous-pair intent is incomplete"
                )
            }
            if let previousPairIdentities = first.previousPairIdentities {
                for recorded in [
                    previousPairIdentities.ply,
                    previousPairIdentities.receipt,
                ] {
                    let identity = recorded.identity
                    guard identity.byteCount > 0,
                          identity.owner == getuid(),
                          identity.linkCount == 1,
                          identity.mode & S_IFMT == S_IFREG,
                          identity.mode & 0o7777 == 0o600 else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication journal previous-pair intent is unsafe"
                        )
                    }
                }
            }
            let cleanupAuthorizationNames = names.filter {
                $0 == Names.cleanupAuthorization
                    || $0 == Names.cleanupAuthorizationPending
            }
            guard cleanupAuthorizationNames.count <= 1 else {
                throw PublishedResultPairError.publicationConflict(
                    "publication cleanup ownership is incomplete"
                )
            }
            let cleanupAuthorization: CleanupJournalDocument?
            let cleanupAuthorizationFileIdentity: FileIdentity?
            if names.contains(Names.cleanupAuthorization) {
                let initialIdentity = try namedFileIdentity(
                    parent: descriptor,
                    name: Names.cleanupAuthorization,
                    exactMode: 0o600
                )
                let data = try readPrivateFile(
                    parent: descriptor,
                    name: Names.cleanupAuthorization,
                    maximumBytes: 65_536
                )
                let document: CleanupJournalDocument
                do {
                    document = try decodeCleanupJournal(data)
                } catch {
                    throw PublishedResultPairError.publicationConflict(
                        "publication cleanup journal is invalid"
                    )
                }
                guard document.schemaVersion == 1,
                      document.transactionID == transactionID,
                      document.publicationID == first.publicationID,
                      document.previousPublicationID
                        == first.previousPublicationID,
                      document.directoryIdentity.identity == identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication cleanup identity mismatch"
                    )
                }
                cleanupAuthorization = document
                let finalIdentity = try namedFileIdentity(
                    parent: descriptor,
                    name: Names.cleanupAuthorization,
                    exactMode: 0o600
                )
                guard finalIdentity == initialIdentity else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication cleanup authority changed while reading"
                    )
                }
                cleanupAuthorizationFileIdentity = finalIdentity
            } else {
                cleanupAuthorization = nil
                cleanupAuthorizationFileIdentity = nil
            }
            let ownedNames = dataNames.union(
                PublishedResultPairJournalPhase.allCases.map(\.leaf)
            ).union([Names.cleanupAuthorization])
            for document in documents {
                for (name, recorded) in document.ownedFiles {
                    guard ownedNames.contains(name), recorded.identity.byteCount >= 0,
                          recorded.identity.owner == getuid(),
                          recorded.identity.linkCount == 1,
                          recorded.identity.mode & S_IFMT == S_IFREG,
                          recorded.identity.mode & 0o7777 == 0o600 else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication journal contains unsafe ownership"
                        )
                    }
                }
            }
            if let cleanupAuthorization {
                for (name, recorded) in cleanupAuthorization.ownedFiles {
                    guard ownedNames.contains(name), recorded.identity.byteCount >= 0,
                          recorded.identity.owner == getuid(),
                          recorded.identity.linkCount == 1,
                          recorded.identity.mode & S_IFMT == S_IFREG,
                          recorded.identity.mode & 0o7777 == 0o600 else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication cleanup journal contains unsafe ownership"
                        )
                    }
                    var current = stat()
                    let result = name.withCString {
                        Darwin.fstatat(descriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
                    }
                    if result == 0,
                       !FileIdentity(current).sameInode(as: recorded.identity) {
                        throw PublishedResultPairError.publicationConflict(
                            "cleanup-owned file identity changed"
                        )
                    }
                    if result != 0, errno != ENOENT {
                        throw PublishedResultPairError.publicationConflict(
                            "cleanup-owned file became inaccessible"
                        )
                    }
                }
            }
            if let cleanupAuthorizationFileIdentity {
                let recordedIdentities = documents.compactMap {
                    $0.ownedFiles[Names.cleanupAuthorization]?.identity
                }
                guard recordedIdentities.contains(where: {
                    cleanupAuthorizationFileIdentity.sameInode(as: $0)
                }) else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication cleanup authority is not journal-bound"
                    )
                }
            }
            var testingEphemeralOwnedFiles: [String: FileIdentity] = [:]
            for name in names
            where name != Names.cleanupAuthorization {
                let logicalName = logicalCleanupOwnedName(name)
                var recordedIdentities: [FileIdentity]
                if let authorized = cleanupAuthorization?.ownedFiles[logicalName] {
                    recordedIdentities = [authorized.identity]
                } else {
                    recordedIdentities = documents.compactMap {
                        $0.ownedFiles[logicalName]?.identity
                    }
                }
                if recordedIdentities.isEmpty,
                   let previous = first.previousPairIdentities {
                    if name == Names.oldPly, latest.phase == .prepared {
                        recordedIdentities = [previous.ply.identity]
                    } else if name == Names.oldReceipt,
                              latest.phase == .previousPlyMoved {
                        recordedIdentities = [previous.receipt.identity]
                    }
                }
                let current = try namedFileIdentity(
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
                if recordedIdentities.isEmpty,
                   testingEphemeralOwnedNames.contains(name) {
                    // Production keeps a newly-created candidate's identity in
                    // memory until the next durable journal owns it. The crash
                    // fixture has to reopen between those two test-only calls,
                    // so carry only the explicitly named candidate across that
                    // artificial boundary. All production recovery remains
                    // strict because its callers use the empty default.
                    recordedIdentities = [current]
                    testingEphemeralOwnedFiles[name] = current
                }
                if recordedIdentities.isEmpty, name == latest.phase.leaf {
                    recordedIdentities = [current]
                }
                guard !recordedIdentities.isEmpty else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication transaction ownership is missing"
                    )
                }
                guard recordedIdentities.contains(where: {
                    current.sameInode(as: $0)
                }) else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication transaction ownership changed"
                    )
                }
            }
            for (name, recorded) in latest.ownedFiles {
                var current = stat()
                let result = name.withCString {
                    Darwin.fstatat(descriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
                }
                if result == 0,
                   !FileIdentity(current).sameInode(as: recorded.identity) {
                    throw PublishedResultPairError.publicationConflict(
                        "transaction-owned file identity changed"
                    )
                }
                if result != 0, errno != ENOENT {
                    throw PublishedResultPairError.publicationConflict(
                        "transaction-owned file became inaccessible"
                    )
                }
            }
            var history: [String: [FileIdentity]] = [:]
            for document in documents {
                for (name, recorded) in document.ownedFiles {
                    let identity = recorded.identity
                    if let existing = history[name],
                       !existing.allSatisfy({ $0.sameInode(as: identity) }) {
                        throw PublishedResultPairError.publicationConflict(
                            "publication journal changed an owned inode"
                        )
                    }
                    if history[name]?.contains(identity) != true {
                        history[name, default: []].append(identity)
                    }
                }
            }
            if history[latest.phase.leaf] == nil {
                history[latest.phase.leaf] = [try namedFileIdentity(
                    parent: descriptor,
                    name: latest.phase.leaf,
                    exactMode: 0o600
                )]
            }
            if let cleanupAuthorization {
                for (name, recorded) in cleanupAuthorization.ownedFiles {
                    let identity = recorded.identity
                    if let existing = history[name],
                       !existing.allSatisfy({ $0.sameInode(as: identity) }) {
                        throw PublishedResultPairError.publicationConflict(
                            "publication cleanup journal changed an owned inode"
                        )
                    }
                    if history[name]?.contains(identity) != true {
                        history[name, default: []].append(identity)
                    }
                }
            }
            if let previous = first.previousPairIdentities {
                if names.contains(Names.oldPly),
                   history[Names.oldPly] == nil,
                   latest.phase == .prepared {
                    history[Names.oldPly] = [previous.ply.identity]
                }
                if names.contains(Names.oldReceipt),
                   history[Names.oldReceipt] == nil,
                   latest.phase == .previousPlyMoved {
                    history[Names.oldReceipt] = [previous.receipt.identity]
                }
            }
            let transaction = TransactionDirectory(
                leaf: leaf,
                transactionID: transactionID,
                publicationID: first.publicationID,
                previousPublicationID: first.previousPublicationID,
                previousPairIdentities: first.previousPairIdentities,
                descriptor: descriptor,
                identity: identity,
                lastJournal: latest,
                cleanupAuthorization: cleanupAuthorization,
                cleanupAuthorizationFileIdentity: cleanupAuthorizationFileIdentity,
                ownedFileHistory: history
            )
            transaction.ephemeralOwnedFiles = testingEphemeralOwnedFiles
            ownershipTransferred = true
            return transaction
        }

        static func openRetiredForCleanup(
            output: BoundOutput,
            leaf: String
        ) throws -> TransactionDirectory {
            guard leaf.hasPrefix(Names.retiredPrefix) else {
                throw PublishedResultPairError.publicationConflict(
                    "unknown retired transaction name"
                )
            }
            let suffix = String(leaf.dropFirst(Names.retiredPrefix.count))
            guard let transactionID = UUID(uuidString: suffix),
                  Names.retiredPrefix + transactionID.uuidString.lowercased() == leaf else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed retired transaction identity"
                )
            }
            let descriptor = leaf.withCString {
                Darwin.openat(
                    output.descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw PublishedResultPairError.publicationConflict(
                    "retired transaction disappeared"
                )
            }
            var transferred = false
            defer { if !transferred { Darwin.close(descriptor) } }
            let identity = try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: output.descriptor,
                name: leaf,
                exactMode: 0o700
            )
            let names = try directoryNames(descriptor: descriptor, maximumCount: 32)
            let cleanupAuthorizationNames = names.filter {
                $0 == Names.cleanupAuthorization
                    || $0 == cleanupQuarantineName(Names.cleanupAuthorization)
            }
            guard cleanupAuthorizationNames.count == 1,
                  let cleanupAuthorizationName = cleanupAuthorizationNames.first else {
                throw PublishedResultPairError.publicationConflict(
                    "retired publication lacks cleanup authority"
                )
            }
            let authorizationIdentity = try namedFileIdentity(
                parent: descriptor,
                name: cleanupAuthorizationName,
                exactMode: 0o600
            )
            let data = try readPrivateFile(
                parent: descriptor,
                name: cleanupAuthorizationName,
                maximumBytes: 65_536
            )
            let authorization: CleanupJournalDocument
            do {
                authorization = try decodeCleanupJournal(data)
            } catch {
                throw PublishedResultPairError.publicationConflict(
                    "retired cleanup authority is invalid"
                )
            }
            guard authorization.schemaVersion == 1,
                  authorization.transactionID == transactionID,
                  authorization.directoryIdentity.identity == identity,
                  try namedFileIdentity(
                    parent: descriptor,
                    name: cleanupAuthorizationName,
                    exactMode: 0o600
                  ) == authorizationIdentity else {
                throw PublishedResultPairError.publicationConflict(
                    "retired cleanup authority changed"
                )
            }
            let logicalNames = Set([
                Names.newPly, Names.newReceipt, Names.oldPly, Names.oldReceipt,
            ]).union(PublishedResultPairJournalPhase.allCases.map(\.leaf))
            var history: [String: [FileIdentity]] = [:]
            for (name, recorded) in authorization.ownedFiles {
                let expected = recorded.identity
                guard logicalNames.contains(name), expected.owner == getuid(),
                      expected.linkCount == 1,
                      expected.mode & S_IFMT == S_IFREG,
                      expected.mode & 0o7777 == 0o600 else {
                    throw PublishedResultPairError.publicationConflict(
                        "retired cleanup authority contains unsafe ownership"
                    )
                }
                history[name] = [expected]
            }
            for name in names where name != cleanupAuthorizationName {
                let logicalName = logicalCleanupOwnedName(name)
                guard let expected = authorization.ownedFiles[logicalName]?.identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "retired publication contains unowned state"
                    )
                }
                let current = try namedFileIdentity(
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
                guard current.sameInode(as: expected) else {
                    throw PublishedResultPairError.publicationConflict(
                        "retired publication ownership changed"
                    )
                }
            }
            let transaction = TransactionDirectory(
                leaf: leaf,
                transactionID: transactionID,
                publicationID: authorization.publicationID,
                previousPublicationID: authorization.previousPublicationID,
                descriptor: descriptor,
                identity: identity,
                cleanupAuthorization: authorization,
                cleanupAuthorizationFileIdentity: authorizationIdentity,
                ownedFileHistory: history
            )
            transferred = true
            return transaction
        }

        func copySource(
            _ source: BoundSource,
            expectedEvidence: ValidatedPlyArtifactEvidence,
            operations: PublishedResultPairOperations,
            shouldCancel: @escaping @Sendable () -> Bool
        ) throws -> FileIdentity {
            let target = try createPrivateFile(named: Names.newPly)
            var keepBytes = false
            defer {
                if !keepBytes {
                    ephemeralOwnedFiles[Names.newPly] = try? requireBoundFile(
                        descriptor: target,
                        parent: descriptor,
                        name: Names.newPly,
                        exactMode: 0o600
                    )
                }
                Darwin.close(target)
            }
            var hasher = SHA256()
            var offset: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while offset < expectedEvidence.byteCount {
                try checkCancellation(shouldCancel)
                let requested = min(
                    buffer.count,
                    Int(expectedEvidence.byteCount - offset)
                )
                let count = buffer.withUnsafeMutableBytes {
                    operations.readAt(
                        source.descriptor,
                        $0.baseAddress,
                        requested,
                        off_t(offset)
                    )
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0, count <= requested else {
                    throw PublishedResultPairError.invalidSource
                }
                hasher.update(data: Data(buffer[0..<count]))
                try writeAll(
                    descriptor: target,
                    bytes: buffer,
                    count: count,
                    operations: operations,
                    operation: "stage new PLY"
                )
                offset += UInt64(count)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard offset == expectedEvidence.byteCount,
                  digest == expectedEvidence.sha256 else {
                throw PublishedResultPairError.invalidSource
            }
            try syncFile(target, operations: operations, operation: "stage new PLY")
            try source.revalidatePath()
            let identity = try requireBoundFile(
                descriptor: target,
                parent: descriptor,
                name: Names.newPly,
                exactMode: 0o600
            )
            ephemeralOwnedFiles[Names.newPly] = identity
            keepBytes = true
            return identity
        }

        func writePrivateFile(
            named name: String,
            data: Data,
            operations: PublishedResultPairOperations
        ) throws -> FileIdentity {
            let file = try createPrivateFile(named: name)
            var keepBytes = false
            defer {
                if !keepBytes {
                    ephemeralOwnedFiles[name] = try? requireBoundFile(
                        descriptor: file,
                        parent: descriptor,
                        name: name,
                        exactMode: 0o600
                    )
                }
                Darwin.close(file)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = operations.write(
                        file,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0, count <= bytes.count - offset else {
                        throw PublishedResultPairError.persistence(
                            operation: "write \(name)",
                            code: count < 0 ? errno : EIO
                        )
                    }
                    offset += count
                }
            }
            try syncFile(file, operations: operations, operation: "write \(name)")
            let identity = try requireBoundFile(
                descriptor: file,
                parent: descriptor,
                name: name,
                exactMode: 0o600
            )
            ephemeralOwnedFiles[name] = identity
            keepBytes = true
            return identity
        }

        func requireUnchangedPrivateFile(
            named name: String,
            expected: FileIdentity
        ) throws {
            let current: FileIdentity
            do {
                current = try namedFileIdentity(
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
            } catch {
                throw PublishedResultPairError.invalidSource
            }
            guard current == expected else {
                throw PublishedResultPairError.invalidSource
            }
        }

        func record(
            phase: PublishedResultPairJournalPhase,
            output: BoundOutput? = nil,
            operations: PublishedResultPairOperations
        ) throws {
            let canonicalPlyIdentity: JournalFileIdentity?
            let canonicalReceiptIdentity: JournalFileIdentity?
            if phase.rawValue >= PublishedResultPairJournalPhase.newPlyInstalled.rawValue {
                guard let output else {
                    throw PublishedResultPairError.publicationConflict(
                        "canonical publication identity was not supplied"
                    )
                }
                canonicalPlyIdentity = JournalFileIdentity(try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalPly,
                    exactMode: 0o600
                ))
                if phase.rawValue >= PublishedResultPairJournalPhase.receiptCommitted.rawValue {
                    canonicalReceiptIdentity = JournalFileIdentity(try namedFileIdentity(
                        parent: output.descriptor,
                        name: Names.canonicalReceipt,
                        exactMode: 0o600
                    ))
                } else {
                    canonicalReceiptIdentity = nil
                }
            } else {
                canonicalPlyIdentity = nil
                canonicalReceiptIdentity = nil
            }
            let document = JournalDocument(
                schemaVersion: 3,
                transactionID: transactionID,
                publicationID: publicationID,
                previousPublicationID: previousPublicationID,
                previousPairIdentities: previousPairIdentities,
                canonicalPlyIdentity: canonicalPlyIdentity,
                canonicalReceiptIdentity: canonicalReceiptIdentity,
                phase: phase,
                ownedFiles: try captureOwnedFiles()
            )
            let data = try encodeJournal(document)
            let pendingIdentity = try writePrivateFile(
                named: phase.pendingLeaf,
                data: data,
                operations: operations
            )
            guard operations.renameExclusive(
                descriptor,
                phase.pendingLeaf,
                descriptor,
                phase.leaf
            ) == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "install publication phase journal",
                    code: errno
                )
            }
            ephemeralOwnedFiles.removeValue(forKey: phase.pendingLeaf)
            ephemeralOwnedFiles[phase.leaf] = pendingIdentity
            try syncDirectory(
                descriptor,
                operations: operations,
                operation: "record publication phase"
            )
            lastJournal = document
            for (name, recorded) in document.ownedFiles {
                let identity = recorded.identity
                if ownedFileHistory[name]?.contains(identity) != true {
                    ownedFileHistory[name, default: []].append(identity)
                }
            }
        }

        func historicalIdentity(named name: String) -> FileIdentity? {
            ownedFileHistory[name]?.last
        }

        func captureOwnedFiles() throws -> [String: JournalFileIdentity] {
            let dataNames = Set([
                Names.newPly, Names.newReceipt, Names.oldPly, Names.oldReceipt,
            ])
            let journalNames = Set(
                PublishedResultPairJournalPhase.allCases.map(\.leaf)
                    + PublishedResultPairJournalPhase.allCases.map(\.pendingLeaf)
                    + [Names.cleanupAuthorizationPending]
            )
            var result: [String: JournalFileIdentity] = [:]
            for name in try directoryNames(descriptor: descriptor, maximumCount: 32) {
                guard dataNames.contains(name) || journalNames.contains(name) else {
                    throw PublishedResultPairError.publicationConflict(
                        "unknown transaction entry \(name)"
                    )
                }
                let file = openReadOnly(parent: descriptor, name: name)
                guard file >= 0 else {
                    throw PublishedResultPairError.publicationConflict(
                        "unsafe transaction entry \(name)"
                    )
                }
                defer { Darwin.close(file) }
                let identity = try requireBoundFile(
                    descriptor: file,
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
                let logicalName = logicalTransactionOwnedName(name)
                if let existing = result[logicalName],
                   !existing.identity.sameInode(as: identity) {
                    throw PublishedResultPairError.publicationConflict(
                        "publication journal has duplicate ownership"
                    )
                }
                result[logicalName] = JournalFileIdentity(identity)
            }
            return result
        }

        func createPrivateFile(named name: String) throws -> Int32 {
            if let planned = ephemeralOwnedFiles[name] {
                let reopened = name.withCString {
                    Darwin.openat(
                        self.descriptor,
                        $0,
                        O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard reopened >= 0 else {
                    throw PublishedResultPairError.publicationConflict(
                        "planned transaction file disappeared"
                    )
                }
                do {
                    let current = try requireBoundFile(
                        descriptor: reopened,
                        parent: self.descriptor,
                        name: name,
                        exactMode: 0o600
                    )
                    guard current.sameInode(as: planned),
                          Darwin.ftruncate(reopened, 0) == 0 else {
                        throw PublishedResultPairError.publicationConflict(
                            "planned transaction file changed"
                        )
                    }
                    return reopened
                } catch {
                    Darwin.close(reopened)
                    throw error
                }
            }
            let descriptor = name.withCString {
                Darwin.openat(
                    self.descriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "create \(name)",
                    code: errno
                )
            }
            do {
                guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "secure \(name)",
                        code: errno
                    )
                }
                ephemeralOwnedFiles[name] = try requireBoundFile(
                    descriptor: descriptor,
                    parent: self.descriptor,
                    name: name,
                    exactMode: 0o600
                )
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        func retire(
            output: BoundOutput,
            operations: PublishedResultPairOperations,
            additionalOwnedFiles: [String: FileIdentity] = [:],
            transactionLeaf: String? = nil
        ) throws {
            let activeLeaf = transactionLeaf ?? (
                Names.transactionPrefix + transactionID.uuidString.lowercased()
            )
            let retiredLeaf = Names.retiredPrefix
                + transactionID.uuidString.lowercased()
            let dataNames = Set([
                Names.newPly, Names.newReceipt, Names.oldPly, Names.oldReceipt,
            ])
            var ownedFiles = ownedFileHistory.compactMapValues(\.last)
            for candidates in [ephemeralOwnedFiles, additionalOwnedFiles] {
                for (name, identity) in candidates {
                    let logicalName = logicalCleanupOwnedName(name)
                    if let existing = ownedFiles[logicalName],
                       !existing.sameInode(as: identity) {
                        throw PublishedResultPairError.publicationConflict(
                            "transaction cleanup ownership changed"
                        )
                    }
                    ownedFiles[logicalName] = identity
                }
            }
            try output.revalidate()
            let activeIdentity = try optionalChildDirectoryIdentity(
                parent: output.descriptor,
                name: activeLeaf,
                exactMode: 0o700
            )
            let retiredIdentity = try optionalChildDirectoryIdentity(
                parent: output.descriptor,
                name: retiredLeaf,
                exactMode: 0o700
            )
            guard !(
                activeIdentity != nil && retiredIdentity != nil
            ) else {
                throw PublishedResultPairError.publicationConflict(
                    "publication transaction exists in two cleanup states"
                )
            }
            if activeIdentity == nil, retiredIdentity == nil {
                throw PublishedResultPairError.publicationConflict(
                    "publication transaction was renamed during cleanup"
                )
            }
            guard (activeIdentity ?? retiredIdentity) == identity else {
                throw PublishedResultPairError.publicationConflict(
                    "transaction directory identity changed before cleanup"
                )
            }
            let logicalOwnedNames = dataNames.union(
                PublishedResultPairJournalPhase.allCases.map(\.leaf)
            ).union([Names.cleanupAuthorization])
            for name in try directoryNames(descriptor: descriptor, maximumCount: 32) {
                let logicalName = logicalCleanupOwnedName(name)
                if logicalName == Names.cleanupAuthorization {
                    let expected = cleanupAuthorizationFileIdentity
                        ?? ownedFiles[Names.cleanupAuthorization]
                    guard let expected,
                          try namedFileIdentity(
                            parent: descriptor,
                            name: name,
                            exactMode: 0o600
                          ).sameInode(as: expected) else {
                        throw PublishedResultPairError.publicationConflict(
                            "transaction cleanup authority changed"
                        )
                    }
                    continue
                }
                guard logicalOwnedNames.contains(logicalName),
                      let expected = ownedFiles[logicalName] else {
                    throw PublishedResultPairError.publicationConflict(
                        "transaction cleanup found an unowned entry"
                    )
                }
                let current = try namedFileIdentity(
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
                guard current.sameInode(as: expected) else {
                    throw PublishedResultPairError.publicationConflict(
                        "transaction cleanup identity changed"
                    )
                }
            }
            if cleanupAuthorization == nil {
                var authorizedFiles: [String: JournalFileIdentity] = [:]
                for name in try directoryNames(
                    descriptor: descriptor,
                    maximumCount: 32
                ) where logicalCleanupOwnedName(name) != Names.cleanupAuthorization {
                    let logicalName = logicalCleanupOwnedName(name)
                    guard logicalOwnedNames.contains(logicalName) else {
                        throw PublishedResultPairError.publicationConflict(
                            "cleanup authorization found an unknown entry"
                        )
                    }
                    let identity = try namedFileIdentity(
                        parent: descriptor,
                        name: name,
                        exactMode: 0o600
                    )
                    if let existing = authorizedFiles[logicalName],
                       !existing.identity.sameInode(as: identity) {
                        throw PublishedResultPairError.publicationConflict(
                            "cleanup authorization found duplicate ownership"
                        )
                    }
                    authorizedFiles[logicalName] = JournalFileIdentity(identity)
                }
                let authorization = CleanupJournalDocument(
                    schemaVersion: 1,
                    transactionID: transactionID,
                    publicationID: publicationID,
                    previousPublicationID: previousPublicationID,
                    directoryIdentity: JournalDirectoryIdentity(identity),
                    ownedFiles: authorizedFiles
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let authorizationIdentity: FileIdentity
                do {
                    authorizationIdentity = try writePrivateFile(
                        named: Names.cleanupAuthorizationPending,
                        data: try encoder.encode(authorization),
                        operations: operations
                    )
                } catch let writeError {
                    // A short write has no crash-safe authority of its own. In
                    // this live process, however, writePrivateFile retained the
                    // exact inode it created. Remove only that inode so a later
                    // reconciliation can retry from the durable phase journals.
                    // If the process crashes first, recovery still preserves the
                    // ambiguous pending file as a conflict.
                    guard let partial = ephemeralOwnedFiles[
                        Names.cleanupAuthorizationPending
                    ] else {
                        throw writeError
                    }
                    do {
                        try quarantineAndRemoveOwnedEntry(
                            parent: descriptor,
                            name: Names.cleanupAuthorizationPending,
                            expected: partial,
                            operations: operations,
                            operation: "discard incomplete publication cleanup authority"
                        )
                        ephemeralOwnedFiles.removeValue(
                            forKey: Names.cleanupAuthorizationPending
                        )
                    } catch {
                        throw error
                    }
                    throw writeError
                }
                guard operations.renameExclusive(
                    descriptor,
                    Names.cleanupAuthorizationPending,
                    descriptor,
                    Names.cleanupAuthorization
                ) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "install publication cleanup authority",
                        code: errno
                    )
                }
                ephemeralOwnedFiles.removeValue(
                    forKey: Names.cleanupAuthorizationPending
                )
                ephemeralOwnedFiles[Names.cleanupAuthorization]
                    = authorizationIdentity
                try syncDirectory(
                    descriptor,
                    operations: operations,
                    operation: "authorize publication cleanup"
                )
                cleanupAuthorization = authorization
                cleanupAuthorizationFileIdentity = authorizationIdentity
                for (name, recorded) in authorizedFiles {
                    let identity = recorded.identity
                    if ownedFileHistory[name]?.contains(identity) != true {
                        ownedFileHistory[name, default: []].append(identity)
                    }
                }
            }
            if activeIdentity != nil {
                let result = operations.renameExclusive(
                    output.descriptor,
                    activeLeaf,
                    output.descriptor,
                    retiredLeaf
                )
                guard result == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "retire publication transaction",
                        code: errno
                    )
                }
            }
            try syncDirectory(
                output.descriptor,
                operations: operations,
                operation: "retire publication transaction"
            )
            guard try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: output.descriptor,
                name: retiredLeaf,
                exactMode: 0o700
            ) == identity else {
                throw PublishedResultPairError.publicationConflict(
                    "retired transaction identity changed"
                )
            }

            guard let cleanupAuthorization else {
                throw PublishedResultPairError.publicationConflict(
                    "publication cleanup authority is missing"
                )
            }
            for (logicalName, recorded) in cleanupAuthorization.ownedFiles.sorted(
                by: { $0.key < $1.key }
            ) {
                let matchingNames = try directoryNames(
                    descriptor: descriptor,
                    maximumCount: 32
                ).filter {
                    logicalCleanupOwnedName($0) != Names.cleanupAuthorization
                        && logicalCleanupOwnedName($0) == logicalName
                }
                guard matchingNames.count <= 1 else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication cleanup found duplicate names"
                    )
                }
                guard let actualName = matchingNames.first else { continue }
                try quarantineAndRemoveOwnedEntry(
                    parent: descriptor,
                    name: cleanupOriginalEntryName(actualName),
                    expected: recorded.identity,
                    operations: operations,
                    operation: "remove retired publication entry"
                )
            }

            let remainingJournals = try directoryNames(
                descriptor: descriptor,
                maximumCount: 2
            )
            let cleanupAuthorizationNames = remainingJournals.filter {
                $0 == Names.cleanupAuthorization
                    || $0 == cleanupQuarantineName(Names.cleanupAuthorization)
            }
            guard remainingJournals.count == cleanupAuthorizationNames.count,
                  cleanupAuthorizationNames.count <= 1 else {
                throw PublishedResultPairError.publicationConflict(
                    "retired publication contains unowned state"
                )
            }
            if let cleanupAuthorizationName = cleanupAuthorizationNames.first {
                guard let cleanupAuthorizationFileIdentity else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication cleanup authority identity is missing"
                    )
                }
                try quarantineAndRemoveOwnedEntry(
                    parent: descriptor,
                    name: cleanupOriginalEntryName(cleanupAuthorizationName),
                    expected: cleanupAuthorizationFileIdentity,
                    operations: operations,
                    operation: "remove publication cleanup authority"
                )
            }
            try quarantineAndRemoveOwnedDirectory(
                parent: output.descriptor,
                name: retiredLeaf,
                expected: identity,
                operations: operations,
                operation: "remove retired publication transaction",
                didRemoveCheckpoint: .transactionDirectoryRemoved
            )
            operations.didReachCheckpoint(.transactionRetired)
        }

        func discardUncommitted(
            output: BoundOutput,
            operations: PublishedResultPairOperations,
            additionalOwnedFiles: [String: FileIdentity] = [:],
            transactionLeaf: String? = nil
        ) throws {
            try retire(
                output: output,
                operations: operations,
                additionalOwnedFiles: additionalOwnedFiles,
                transactionLeaf: transactionLeaf
            )
        }

        func discardInactiveBuildBeforeActivation(
            output: BoundOutput,
            operations: PublishedResultPairOperations,
            buildLeaf: String
        ) throws {
            try output.revalidate()
            guard try optionalChildDirectoryIdentity(
                parent: output.descriptor,
                name: buildLeaf,
                exactMode: 0o700
            ) == identity else {
                throw PublishedResultPairError.publicationConflict(
                    "inactive publication transaction changed"
                )
            }
            for actualName in try directoryNames(
                descriptor: descriptor,
                maximumCount: 32
            ).sorted() {
                let logicalName = logicalCleanupOwnedName(actualName)
                var candidates = ownedFileHistory[logicalName] ?? []
                if let ephemeral = ephemeralOwnedFiles[actualName] {
                    candidates.append(ephemeral)
                }
                let current = try namedFileIdentity(
                    parent: descriptor,
                    name: actualName,
                    exactMode: 0o600
                )
                guard candidates.contains(where: {
                    current.sameInode(as: $0)
                }) else {
                    throw PublishedResultPairError.publicationConflict(
                        "inactive publication transaction ownership changed"
                    )
                }
                try quarantineAndRemoveOwnedEntry(
                    parent: descriptor,
                    name: cleanupOriginalEntryName(actualName),
                    expected: current,
                    operations: operations,
                    operation: "discard inactive publication transaction"
                )
            }
            guard try directoryNames(
                descriptor: descriptor,
                maximumCount: 1
            ).isEmpty else {
                throw PublishedResultPairError.publicationConflict(
                    "inactive publication transaction changed before removal"
                )
            }
            try quarantineAndRemoveOwnedDirectory(
                parent: output.descriptor,
                name: buildLeaf,
                expected: identity,
                operations: operations,
                operation: "discard inactive publication transaction"
            )
        }
    }

    final class ReceiptTransactionDirectory {
        enum State {
            case beforeSwap
            case afterSwap
        }

        let leaf: String
        var boundLeaf: String
        let transactionID: UUID
        let descriptor: Int32
        let identity: DirectoryIdentity
        let created: ReceiptJournalDocument
        var prepared: ReceiptJournalDocument?
        var ownedIdentities: [String: [FileIdentity]]
        let isPreactivationAuthorityBound: Bool

        init(
            leaf: String,
            boundLeaf: String? = nil,
            transactionID: UUID,
            descriptor: Int32,
            identity: DirectoryIdentity,
            created: ReceiptJournalDocument,
            prepared: ReceiptJournalDocument?,
            ownedIdentities: [String: [FileIdentity]],
            isPreactivationAuthorityBound: Bool = false
        ) {
            self.leaf = leaf
            self.boundLeaf = boundLeaf ?? leaf
            self.transactionID = transactionID
            self.descriptor = descriptor
            self.identity = identity
            self.created = created
            self.prepared = prepared
            self.ownedIdentities = ownedIdentities
            self.isPreactivationAuthorityBound = isPreactivationAuthorityBound
        }

        deinit { Darwin.close(descriptor) }

        private static func createEmptyPrivateFile(
            parent: Int32,
            name: String,
            operations: PublishedResultPairOperations
        ) throws -> FileIdentity {
            let file = name.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard file >= 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "create viewer timing cleanup authority",
                    code: errno
                )
            }
            var ownedIdentity: FileIdentity?
            do {
                guard Darwin.fchmod(file, mode_t(0o600)) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "secure viewer timing cleanup authority",
                        code: errno
                    )
                }
                try syncFile(
                    file,
                    operations: operations,
                    operation: "prepare viewer timing cleanup authority"
                )
                let identity = try requireBoundFile(
                    descriptor: file,
                    parent: parent,
                    name: name,
                    exactMode: 0o600
                )
                ownedIdentity = identity
                Darwin.close(file)
                return identity
            } catch {
                if ownedIdentity == nil {
                    ownedIdentity = try? requireBoundFile(
                        descriptor: file,
                        parent: parent,
                        name: name,
                        exactMode: 0o600
                    )
                }
                Darwin.close(file)
                if let ownedIdentity {
                    try? quarantineAndRemoveOwnedEntry(
                        parent: parent,
                        name: name,
                        expected: ownedIdentity,
                        operations: operations,
                        operation: "discard incomplete viewer timing authority"
                    )
                }
                throw error
            }
        }

        static func create(
            output: BoundOutput,
            current: BoundPair,
            updatedReceiptData: Data,
            operations: PublishedResultPairOperations
        ) throws -> ReceiptTransactionDirectory {
            let transactionID = operations.makeUUID()
            let leaf = Names.receiptTransactionPrefix
                + transactionID.uuidString.lowercased()
            let buildLeaf = Names.receiptTransactionBuildPrefix
                + transactionID.uuidString.lowercased()
            let buildAuthorityLeaf = Names.receiptTransactionBuildAuthorityPrefix
                + transactionID.uuidString.lowercased()
                + ".json"
            let authorization = ReceiptBuildAuthorizationDocument(
                schemaVersion: 2,
                transactionID: transactionID,
                publicationID: current.result.receipt.publicationID,
                directoryIdentity: .unboundIntent,
                plyIdentity: JournalFileIdentity(current.plyIdentity),
                oldReceiptIdentity: JournalFileIdentity(current.receiptIdentity),
                oldReceiptSHA256: sha256(current.receiptData),
                newReceiptSHA256: sha256(updatedReceiptData),
                ownedFiles: [:]
            )
            let buildAuthorityIdentity = try writeOutputPrivateFile(
                parent: output.descriptor,
                pendingName: buildAuthorityLeaf + ".pending",
                finalName: buildAuthorityLeaf,
                data: try encodeReceiptBuildAuthorization(authorization),
                operations: operations,
                operation: "authorize viewer timing build"
            )
            operations.didReachCheckpoint(.receiptTransactionBuildOwnershipDurable)
            try output.revalidate()
            let createdResult = buildLeaf.withCString {
                Darwin.mkdirat(output.descriptor, $0, mode_t(0o700))
            }
            guard createdResult == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "create viewer timing transaction",
                    code: errno
                )
            }
            try syncDirectory(
                output.descriptor,
                operations: operations,
                operation: "create viewer timing transaction"
            )
            let descriptor = buildLeaf.withCString {
                Darwin.openat(
                    output.descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "open viewer timing transaction",
                    code: errno
                )
            }
            var transferred = false
            defer { if !transferred { Darwin.close(descriptor) } }
            let identity = try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: output.descriptor,
                name: buildLeaf,
                exactMode: 0o700
            )
            let cleanupPendingName = Names.cleanupAuthorization + ".pending"
            let placeholderNames = [
                cleanupPendingName,
                Names.receiptCreatedJournal + ".pending",
                Names.receiptCandidate,
                Names.receiptPreparedJournal + ".pending",
                Names.receiptCleanupStaged,
            ]
            var initialOwned: [String: FileIdentity] = [:]
            do {
                for name in placeholderNames {
                    initialOwned[name] = try createEmptyPrivateFile(
                        parent: descriptor,
                        name: name,
                        operations: operations
                    )
                }
                try syncDirectory(
                    descriptor,
                    operations: operations,
                    operation: "prepare viewer timing build ownership"
                )
            } catch {
                for (name, expected) in initialOwned {
                    guard let current = try? namedFileIdentity(
                        parent: descriptor,
                        name: name,
                        exactMode: 0o600
                    ), current.sameInode(as: expected) else { continue }
                    try? quarantineAndRemoveOwnedEntry(
                        parent: descriptor,
                        name: name,
                        expected: current,
                        operations: operations,
                        operation: "discard incomplete viewer timing ownership"
                    )
                }
                let removed = (try? removeEmptyTransactionDirectory(
                    output: output,
                    leaf: buildLeaf,
                    operations: operations
                )) != nil
                if removed,
                   let current = try? namedFileIdentity(
                    parent: output.descriptor,
                    name: buildAuthorityLeaf,
                    exactMode: 0o600
                   ), current.sameInode(as: buildAuthorityIdentity) {
                    try? quarantineAndRemoveOwnedEntry(
                        parent: output.descriptor,
                        name: buildAuthorityLeaf,
                        expected: current,
                        operations: operations,
                        operation: "discard viewer timing build authority"
                    )
                }
                throw error
            }
            operations.didReachCheckpoint(.receiptCleanupPlaceholderDurable)
            guard let cleanupPendingIdentity = initialOwned[cleanupPendingName] else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build ownership is incomplete"
                )
            }
            let document = ReceiptJournalDocument(
                schemaVersion: 1,
                transactionID: transactionID,
                publicationID: current.result.receipt.publicationID,
                phase: .created,
                plyIdentity: JournalFileIdentity(current.plyIdentity),
                oldReceiptIdentity: JournalFileIdentity(current.receiptIdentity),
                newReceiptIdentity: nil,
                cleanupAuthorizationIdentity: JournalFileIdentity(
                    cleanupPendingIdentity
                ),
                oldReceiptSHA256: sha256(current.receiptData),
                newReceiptSHA256: sha256(updatedReceiptData)
            )
            let transaction = ReceiptTransactionDirectory(
                leaf: leaf,
                boundLeaf: buildLeaf,
                transactionID: transactionID,
                descriptor: descriptor,
                identity: identity,
                created: document,
                prepared: nil,
                ownedIdentities: initialOwned.mapValues { [$0] }
            )
            transferred = true
            do {
                _ = try transaction.writeJournal(
                    named: Names.receiptCreatedJournal,
                    data: try encodeReceiptJournal(document),
                    operations: operations
                )
                try transaction.stageUpdatedReceipt(
                    updatedReceiptData,
                    output: output,
                    operations: operations
                )
                try transaction.prepareCleanupAuthorization(
                    operations: operations
                )
                try syncDirectory(
                    transaction.descriptor,
                    operations: operations,
                    operation: "create viewer timing transaction"
                )
                guard operations.renameExclusive(
                    output.descriptor,
                    buildLeaf,
                    output.descriptor,
                    leaf
                ) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "activate viewer timing transaction",
                        code: errno
                    )
                }
                transaction.boundLeaf = leaf
                try syncDirectory(
                    output.descriptor,
                    operations: operations,
                    operation: "activate viewer timing transaction"
                )
                guard try requireBoundChildDirectory(
                    descriptor: transaction.descriptor,
                    parent: output.descriptor,
                    name: leaf,
                    exactMode: 0o700
                ) == transaction.identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "activated viewer timing transaction changed"
                    )
                }
                try? quarantineAndRemoveOwnedEntry(
                    parent: output.descriptor,
                    name: buildAuthorityLeaf,
                    expected: buildAuthorityIdentity,
                    operations: operations,
                    operation: "retire viewer timing build authority"
                )
                operations.didReachCheckpoint(.receiptTransactionActivated)
                return transaction
            } catch {
                if transaction.boundLeaf != leaf {
                    let discarded = (try? transaction.discardBuild(
                        output: output,
                        operations: operations
                    )) != nil
                    if discarded {
                        try? quarantineAndRemoveOwnedEntry(
                            parent: output.descriptor,
                            name: buildAuthorityLeaf,
                            expected: buildAuthorityIdentity,
                            operations: operations,
                            operation: "discard viewer timing build authority"
                        )
                    }
                }
                throw error
            }
        }

        static func openRecovered(
            output: BoundOutput,
            leaf: String,
            prefix: String = Names.receiptTransactionPrefix
        ) throws -> ReceiptTransactionDirectory {
            guard prefix == Names.receiptTransactionPrefix
                    || prefix == Names.receiptTransactionBuildPrefix,
                  leaf.hasPrefix(prefix) else {
                throw PublishedResultPairError.publicationConflict(
                    "unknown viewer timing transaction"
                )
            }
            let suffix = String(leaf.dropFirst(prefix.count))
            guard let transactionID = UUID(uuidString: suffix),
                  transactionID.uuidString.lowercased() == suffix else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed viewer timing transaction identity"
                )
            }
            let descriptor = leaf.withCString {
                Darwin.openat(
                    output.descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw PublishedResultPairError.publicationConflict(
                    "unsafe viewer timing transaction"
                )
            }
            var transferred = false
            defer { if !transferred { Darwin.close(descriptor) } }
            let identity = try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: output.descriptor,
                name: leaf,
                exactMode: 0o700
            )
            let names = try directoryNames(descriptor: descriptor, maximumCount: 5)
            let baseExpected = Set([
                Names.receiptCreatedJournal,
                Names.receiptPreparedJournal,
                Names.receiptCandidate,
                Names.cleanupAuthorization,
            ])
            let authorityLeaf = Names.receiptCleanupPrefix
                + transactionID.uuidString.lowercased()
                + ".json"
            let stagedIsInternal = names.contains(Names.receiptCleanupStaged)
            let authorityPresence = entryPresence(
                parent: output.descriptor,
                name: authorityLeaf
            )
            guard authorityPresence != .unsafe,
                  (stagedIsInternal
                    ? Set(names) == baseExpected.union([Names.receiptCleanupStaged])
                        && authorityPresence == .missing
                    : Set(names) == baseExpected
                        && authorityPresence == .present) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing transaction contains unknown state"
                )
            }
            let createdData = try readPrivateFile(
                parent: descriptor,
                name: Names.receiptCreatedJournal,
                maximumBytes: 65_536
            )
            let created = try decodeReceiptJournal(createdData)
            guard created.schemaVersion == 1,
                  created.transactionID == transactionID,
                  created.phase == .created,
                  created.newReceiptIdentity == nil,
                  validReceiptJournal(created) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing journal is invalid"
                )
            }
            let cleanupIdentity = try namedFileIdentity(
                    parent: descriptor,
                    name: Names.cleanupAuthorization,
                    exactMode: 0o600
                  )
            guard cleanupIdentity.sameInode(
                as: created.cleanupAuthorizationIdentity.identity
            ) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing cleanup ownership changed"
                )
            }
            let preparedData = try readPrivateFile(
                parent: descriptor,
                name: Names.receiptPreparedJournal,
                maximumBytes: 65_536
            )
            let prepared = try decodeReceiptJournal(preparedData)
            guard prepared.schemaVersion == 1,
                  prepared.transactionID == transactionID,
                  prepared.publicationID == created.publicationID,
                  prepared.phase == .prepared,
                  prepared.plyIdentity == created.plyIdentity,
                  prepared.oldReceiptIdentity == created.oldReceiptIdentity,
                  prepared.cleanupAuthorizationIdentity
                    == created.cleanupAuthorizationIdentity,
                  prepared.oldReceiptSHA256 == created.oldReceiptSHA256,
                  prepared.newReceiptSHA256 == created.newReceiptSHA256,
                  prepared.newReceiptIdentity != nil,
                  validReceiptJournal(prepared) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing journal history is invalid"
                )
            }
            let cleanupData = try readPrivateFile(
                parent: descriptor,
                name: Names.cleanupAuthorization,
                maximumBytes: 65_536
            )
            let cleanup: CleanupJournalDocument
            do {
                cleanup = try decodeCleanupJournal(cleanupData)
            } catch {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing cleanup authority is invalid"
                )
            }
            let ownedNames = Set([
                Names.receiptCreatedJournal,
                Names.receiptPreparedJournal,
                Names.receiptCandidate,
                Names.receiptCleanupStaged,
            ])
            guard cleanup.schemaVersion == 1,
                  cleanup.transactionID == transactionID,
                  cleanup.publicationID == created.publicationID,
                  cleanup.previousPublicationID == nil,
                  cleanup.directoryIdentity.identity == identity,
                  Set(cleanup.ownedFiles.keys) == ownedNames else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing cleanup authority does not bind its state"
                )
            }
            var owned: [String: [FileIdentity]] = [:]
            for name in ownedNames {
                let currentParent = name == Names.receiptCleanupStaged
                    && !stagedIsInternal ? output.descriptor : descriptor
                let currentName = name == Names.receiptCleanupStaged
                    && !stagedIsInternal ? authorityLeaf : name
                let current = try namedFileIdentity(
                    parent: currentParent,
                    name: currentName,
                    exactMode: 0o600
                )
                guard let recorded = cleanup.ownedFiles[name]?.identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing transaction ownership changed"
                    )
                }
                let isExpected: Bool
                if name == Names.receiptCandidate {
                    isExpected = current.sameUnchangedFile(as: recorded)
                        || current.sameObject(
                            as: created.oldReceiptIdentity.identity
                        )
                } else if name == Names.receiptCleanupStaged,
                          !stagedIsInternal {
                    isExpected = current.sameObject(as: recorded)
                } else {
                    isExpected = current.sameUnchangedFile(as: recorded)
                }
                guard isExpected else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing transaction ownership changed"
                    )
                }
                owned[name] = [current]
            }
            guard let candidateIdentity = owned[Names.receiptCandidate]?.first,
                  let preparedCandidate = prepared.newReceiptIdentity?.identity,
                  candidateIdentity.sameUnchangedFile(as: preparedCandidate)
                    || candidateIdentity.sameObject(
                        as: created.oldReceiptIdentity.identity
                    ) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing candidate ownership changed"
                )
            }
            let parentData = try readPrivateFile(
                parent: stagedIsInternal ? descriptor : output.descriptor,
                name: stagedIsInternal
                    ? Names.receiptCleanupStaged : authorityLeaf,
                maximumBytes: 65_536
            )
            let parentAuthorization: CleanupJournalDocument
            do {
                parentAuthorization = try decodeCleanupJournal(parentData)
            } catch {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing parent cleanup authority is invalid"
                )
            }
            let parentOwnedNames = Set([
                Names.receiptCreatedJournal,
                Names.receiptPreparedJournal,
                Names.receiptCandidate,
                Names.cleanupAuthorization,
                Names.receiptDisplacedIdentity,
            ])
            guard parentAuthorization.schemaVersion == 1,
                  parentAuthorization.transactionID == transactionID,
                  parentAuthorization.publicationID == created.publicationID,
                  parentAuthorization.previousPublicationID == nil,
                  parentAuthorization.directoryIdentity.identity == identity,
                  Set(parentAuthorization.ownedFiles.keys) == parentOwnedNames else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing parent cleanup authority does not bind its state"
                )
            }
            for name in parentOwnedNames {
                if name == Names.receiptDisplacedIdentity {
                    guard parentAuthorization.ownedFiles[name]
                        == created.oldReceiptIdentity else {
                        throw PublishedResultPairError.publicationConflict(
                            "viewer timing displaced receipt ownership changed"
                        )
                    }
                    continue
                }
                let current: FileIdentity
                if name == Names.cleanupAuthorization {
                    current = cleanupIdentity
                } else if let recorded = owned[name]?.first {
                    current = recorded
                } else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing parent cleanup ownership is incomplete"
                    )
                }
                guard let expectedIdentity = parentAuthorization
                    .ownedFiles[name]?.identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing parent cleanup ownership is incomplete"
                    )
                }
                let displacedIdentity = parentAuthorization.ownedFiles[
                    Names.receiptDisplacedIdentity
                ]?.identity
                guard current.sameInode(as: expectedIdentity)
                        || (name == Names.receiptCandidate
                            && displacedIdentity.map {
                                current.sameInode(as: $0)
                            } == true) else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing parent cleanup ownership changed"
                    )
                }
            }
            owned[Names.cleanupAuthorization] = [cleanupIdentity]
            let transaction = ReceiptTransactionDirectory(
                leaf: leaf,
                boundLeaf: leaf,
                transactionID: transactionID,
                descriptor: descriptor,
                identity: identity,
                created: created,
                prepared: prepared,
                ownedIdentities: owned
            )
            transferred = true
            return transaction
        }

        static func openAuthorizedBuild(
            output: BoundOutput,
            leaf: String,
            authorityName: String
        ) throws -> (transaction: ReceiptTransactionDirectory, authority: FileIdentity) {
            guard leaf.hasPrefix(Names.receiptTransactionBuildPrefix),
                  !leaf.hasPrefix(Names.receiptTransactionBuildAuthorityPrefix) else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed viewer timing build"
                )
            }
            let suffix = String(leaf.dropFirst(
                Names.receiptTransactionBuildPrefix.count
            ))
            guard let transactionID = UUID(uuidString: suffix),
                  transactionID.uuidString.lowercased() == suffix else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed viewer timing build identity"
                )
            }
            let expectedAuthority = Names.receiptTransactionBuildAuthorityPrefix
                + suffix + ".json"
            let originalAuthority = cleanupOriginalEntryName(authorityName)
            let authorityBase = originalAuthority.hasSuffix(".pending")
                ? String(originalAuthority.dropLast(".pending".count))
                : originalAuthority
            guard authorityBase == expectedAuthority else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority identity mismatch"
                )
            }
            let initialAuthority = try namedFileIdentity(
                parent: output.descriptor,
                name: authorityName,
                exactMode: 0o600
            )
            let authorization = try decodeReceiptBuildAuthorization(
                readPrivateFile(
                    parent: output.descriptor,
                    name: authorityName,
                    maximumBytes: 65_536
                )
            )
            guard try namedFileIdentity(
                parent: output.descriptor,
                name: authorityName,
                exactMode: 0o600
            ) == initialAuthority else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority changed while reading"
                )
            }
            let descriptor = leaf.withCString {
                Darwin.openat(
                    output.descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw PublishedResultPairError.publicationConflict(
                    "unsafe authorized viewer timing build"
                )
            }
            var transferred = false
            defer { if !transferred { Darwin.close(descriptor) } }
            let directoryIdentity = try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: output.descriptor,
                name: leaf,
                exactMode: 0o700
            )
            let expectedOwnedNames = Set([
                Names.cleanupAuthorization + ".pending",
                Names.receiptCreatedJournal + ".pending",
                Names.receiptCandidate,
                Names.receiptPreparedJournal + ".pending",
                Names.receiptCleanupStaged,
            ])
            guard authorization.schemaVersion == 1,
                  authorization.transactionID == transactionID,
                  authorization.directoryIdentity.identity == directoryIdentity,
                  Set(authorization.ownedFiles.keys) == expectedOwnedNames,
                  authorization.oldReceiptSHA256.count == 64,
                  authorization.newReceiptSHA256.count == 64 else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority does not bind its state"
                )
            }
            for digest in [
                authorization.oldReceiptSHA256,
                authorization.newReceiptSHA256,
            ] where !digest.allSatisfy({
                $0.isNumber || ("a"..."f").contains(String($0))
            }) {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority has an invalid digest"
                )
            }
            for recorded in authorization.ownedFiles.values {
                let identity = recorded.identity
                guard identity.owner == getuid(), identity.linkCount == 1,
                      identity.mode & S_IFMT == S_IFREG,
                      identity.mode & 0o7777 == 0o600 else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing build authority has unsafe ownership"
                    )
                }
            }
            let names = try directoryNames(descriptor: descriptor, maximumCount: 16)
            var claimedPlaceholders = Set<String>()
            var owned: [String: [FileIdentity]] = [:]
            for name in names {
                let original = cleanupOriginalEntryName(name)
                let placeholder: String
                switch original {
                case Names.receiptCreatedJournal,
                     Names.receiptCreatedJournal + ".pending":
                    placeholder = Names.receiptCreatedJournal + ".pending"
                case Names.receiptPreparedJournal,
                     Names.receiptPreparedJournal + ".pending":
                    placeholder = Names.receiptPreparedJournal + ".pending"
                case Names.cleanupAuthorization,
                     Names.cleanupAuthorization + ".pending":
                    placeholder = Names.cleanupAuthorization + ".pending"
                case Names.receiptCandidate:
                    placeholder = Names.receiptCandidate
                case Names.receiptCleanupStaged:
                    placeholder = Names.receiptCleanupStaged
                default:
                    throw PublishedResultPairError.publicationConflict(
                        "authorized viewer timing build contains foreign state"
                    )
                }
                guard claimedPlaceholders.insert(placeholder).inserted,
                      let expected = authorization.ownedFiles[placeholder]?.identity else {
                    throw PublishedResultPairError.publicationConflict(
                        "authorized viewer timing build has duplicate state"
                    )
                }
                let current = try namedFileIdentity(
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
                guard current.sameInode(as: expected) else {
                    throw PublishedResultPairError.publicationConflict(
                        "authorized viewer timing build ownership changed"
                    )
                }
                owned[name] = [current]
            }
            guard let cleanupPlaceholder = authorization.ownedFiles[
                Names.cleanupAuthorization + ".pending"
            ] else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build cleanup ownership is missing"
                )
            }
            let created = ReceiptJournalDocument(
                schemaVersion: 1,
                transactionID: transactionID,
                publicationID: authorization.publicationID,
                phase: .created,
                plyIdentity: authorization.plyIdentity,
                oldReceiptIdentity: authorization.oldReceiptIdentity,
                newReceiptIdentity: nil,
                cleanupAuthorizationIdentity: cleanupPlaceholder,
                oldReceiptSHA256: authorization.oldReceiptSHA256,
                newReceiptSHA256: authorization.newReceiptSHA256
            )
            guard validReceiptJournal(created) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority has unsafe predecessor state"
                )
            }
            let transaction = ReceiptTransactionDirectory(
                leaf: Names.receiptTransactionPrefix + suffix,
                boundLeaf: leaf,
                transactionID: transactionID,
                descriptor: descriptor,
                identity: directoryIdentity,
                created: created,
                prepared: nil,
                ownedIdentities: owned,
                isPreactivationAuthorityBound: true
            )
            transferred = true
            return (transaction, initialAuthority)
        }

        func stageUpdatedReceipt(
            _ data: Data,
            output: BoundOutput,
            operations: PublishedResultPairOperations
        ) throws {
            guard prepared == nil,
                  sha256(data) == created.newReceiptSHA256 else {
                throw PublishedResultPairError.invalidSource
            }
            let candidate = try writePrivateFile(
                named: Names.receiptCandidate,
                data: data,
                operations: operations
            )
            ownedIdentities[Names.receiptCandidate] = [candidate]
            let document = ReceiptJournalDocument(
                schemaVersion: 1,
                transactionID: transactionID,
                publicationID: created.publicationID,
                phase: .prepared,
                plyIdentity: created.plyIdentity,
                oldReceiptIdentity: created.oldReceiptIdentity,
                newReceiptIdentity: JournalFileIdentity(candidate),
                cleanupAuthorizationIdentity: created.cleanupAuthorizationIdentity,
                oldReceiptSHA256: created.oldReceiptSHA256,
                newReceiptSHA256: created.newReceiptSHA256
            )
            _ = try writeJournal(
                named: Names.receiptPreparedJournal,
                data: try Self.encodeReceiptJournal(document),
                operations: operations
            )
            try syncDirectory(
                descriptor,
                operations: operations,
                operation: "prepare viewer timing receipt"
            )
            prepared = document
        }

        func prepareCleanupAuthorization(
            operations: PublishedResultPairOperations
        ) throws {
            guard prepared != nil,
                  entryPresence(
                    parent: descriptor,
                    name: Names.cleanupAuthorization
                  ) == .missing else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing cleanup authority is already prepared"
                )
            }
            let names = try directoryNames(descriptor: descriptor, maximumCount: 5)
            let expected = Set([
                Names.receiptCreatedJournal,
                Names.receiptPreparedJournal,
                Names.receiptCandidate,
                Names.cleanupAuthorization + ".pending",
                Names.receiptCleanupStaged,
            ])
            guard Set(names) == expected else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build state is incomplete"
                )
            }
            var parentAuthorizedFiles: [String: JournalFileIdentity] = [:]
            for name in names where name != Names.receiptCleanupStaged {
                let logicalName = logicalReceiptOwnedName(name)
                parentAuthorizedFiles[logicalName] = JournalFileIdentity(
                    try namedFileIdentity(
                        parent: descriptor,
                        name: name,
                        exactMode: 0o600
                    )
                )
            }
            parentAuthorizedFiles[Names.receiptDisplacedIdentity] =
                created.oldReceiptIdentity
            let parentAuthorization = CleanupJournalDocument(
                schemaVersion: 1,
                transactionID: transactionID,
                publicationID: created.publicationID,
                previousPublicationID: nil,
                directoryIdentity: JournalDirectoryIdentity(identity),
                ownedFiles: parentAuthorizedFiles
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let stagedParent = try writePrivateFile(
                named: Names.receiptCleanupStaged,
                data: try encoder.encode(parentAuthorization),
                operations: operations
            )
            ownedIdentities[Names.receiptCleanupStaged] = [stagedParent]

            var internalAuthorizedFiles = parentAuthorizedFiles
            internalAuthorizedFiles.removeValue(forKey: Names.cleanupAuthorization)
            internalAuthorizedFiles.removeValue(forKey: Names.receiptDisplacedIdentity)
            internalAuthorizedFiles[Names.receiptCleanupStaged] = JournalFileIdentity(
                stagedParent
            )
            let internalAuthorization = CleanupJournalDocument(
                schemaVersion: 1,
                transactionID: transactionID,
                publicationID: created.publicationID,
                previousPublicationID: nil,
                directoryIdentity: JournalDirectoryIdentity(identity),
                ownedFiles: internalAuthorizedFiles
            )
            _ = try writeJournal(
                named: Names.cleanupAuthorization,
                data: try encoder.encode(internalAuthorization),
                operations: operations
            )
            try syncDirectory(
                descriptor,
                operations: operations,
                operation: "prepare viewer timing cleanup authority"
            )
        }

        func discardBuild(
            output: BoundOutput,
            operations: PublishedResultPairOperations
        ) throws {
            guard boundLeaf.hasPrefix(Names.receiptTransactionBuildPrefix),
                  try requireBoundChildDirectory(
                    descriptor: descriptor,
                    parent: output.descriptor,
                    name: boundLeaf,
                    exactMode: 0o700
                  ) == identity else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build directory changed"
                )
            }
            let names = try directoryNames(descriptor: descriptor, maximumCount: 8)
            let allowed = Set([
                Names.receiptCreatedJournal,
                Names.receiptCreatedJournal + ".pending",
                Names.receiptPreparedJournal,
                Names.receiptPreparedJournal + ".pending",
                Names.receiptCandidate,
                Names.cleanupAuthorization,
                Names.cleanupAuthorization + ".pending",
                Names.receiptCleanupStaged,
            ])
            let allowedWithQuarantines = allowed.union(
                allowed.map(cleanupQuarantineName)
            )
            guard Set(names).isSubset(of: allowedWithQuarantines) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build contains unknown state"
                )
            }
            for name in names {
                let current = try namedFileIdentity(
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
                let original = cleanupOriginalEntryName(name)
                guard (ownedIdentities[name] ?? ownedIdentities[original])?
                    .contains(where: {
                    $0.sameInode(as: current)
                }) == true else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing build ownership changed"
                    )
                }
            }
            let priority = [
                Names.receiptCandidate,
                Names.receiptPreparedJournal,
                Names.receiptCleanupStaged,
                Names.cleanupAuthorization,
                Names.receiptCreatedJournal,
            ]
            let removalOrder = priority.flatMap { logical in
                names.filter { logicalReceiptOwnedName($0) == logical }.sorted()
            }
            for name in removalOrder {
                let current = try namedFileIdentity(
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
                try quarantineAndRemoveOwnedEntry(
                    parent: descriptor,
                    name: cleanupOriginalEntryName(name),
                    expected: current,
                    operations: operations,
                    operation: "discard viewer timing build"
                )
            }
            guard try directoryNames(
                descriptor: descriptor,
                maximumCount: 1
            ).isEmpty else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build could not be safely removed"
                )
            }
            try quarantineAndRemoveOwnedDirectory(
                parent: output.descriptor,
                name: boundLeaf,
                expected: identity,
                operations: operations,
                operation: "discard viewer timing build"
            )
        }

        func requirePreSwapState(output: BoundOutput) throws {
            guard let prepared,
                  let newIdentity = prepared.newReceiptIdentity?.identity else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing receipt was not prepared"
                )
            }
            let ply = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            let receipt = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            let candidate = try namedFileIdentity(
                parent: descriptor,
                name: Names.receiptCandidate,
                exactMode: 0o600
            )
            guard ply == prepared.plyIdentity.identity,
                  receipt == prepared.oldReceiptIdentity.identity,
                  candidate == newIdentity,
                  try digestNamedFile(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt
                  ) == prepared.oldReceiptSHA256,
                  try digestNamedFile(
                    parent: descriptor,
                    name: Names.receiptCandidate
                  ) == prepared.newReceiptSHA256 else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing predecessor changed"
                )
            }
        }

        func requireInactiveBuildPreSwapState(output: BoundOutput) throws {
            let ply = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            let receipt = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            guard ply.sameObject(as: created.plyIdentity.identity),
                  receipt.sameUnchangedFile(
                    as: created.oldReceiptIdentity.identity
                  ),
                  try digestNamedFile(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt
                  ) == created.oldReceiptSHA256 else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing predecessor changed"
                )
            }
            if isPreactivationAuthorityBound { return }
            guard entryPresence(
                parent: descriptor,
                name: Names.receiptCandidate
            ) == .present else { return }
            guard let prepared,
                  let newIdentity = prepared.newReceiptIdentity?.identity else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing candidate lacks durable ownership"
                )
            }
            let candidate = try namedFileIdentity(
                parent: descriptor,
                name: Names.receiptCandidate,
                exactMode: 0o600
            )
            guard candidate.sameUnchangedFile(as: newIdentity),
                  try digestNamedFile(
                    parent: descriptor,
                    name: Names.receiptCandidate
                  ) == prepared.newReceiptSHA256 else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing candidate changed"
                )
            }
        }

        func requirePostSwapState(
            output: BoundOutput,
            operations: PublishedResultPairOperations,
            previouslyValidated: BoundPair? = nil,
            shouldCancel: @escaping @Sendable () -> Bool
        ) throws -> BoundPair {
            guard let prepared,
                  let newIdentity = prepared.newReceiptIdentity?.identity else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing receipt was not prepared"
                )
            }
            let ply = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            let canonicalReceipt = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            let displaced = try namedFileIdentity(
                parent: descriptor,
                name: Names.receiptCandidate,
                exactMode: 0o600
            )
            guard ply.sameObject(as: prepared.plyIdentity.identity),
                  canonicalReceipt.sameObject(as: newIdentity),
                  displaced.sameObject(as: prepared.oldReceiptIdentity.identity),
                  try digestNamedFile(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt
                  ) == prepared.newReceiptSHA256,
                  try digestNamedFile(
                    parent: descriptor,
                    name: Names.receiptCandidate
                  ) == prepared.oldReceiptSHA256 else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing receipt swap changed"
                )
            }
            let result: BoundPair
            if let previouslyValidated {
                result = try rebindCanonicalPairAfterTimingSwap(
                    previous: previouslyValidated,
                    output: output,
                    expectedPly: ply,
                    expectedReceipt: canonicalReceipt,
                    publicationID: prepared.publicationID,
                    receiptSHA256: prepared.newReceiptSHA256
                )
            } else {
                guard case .available(let resolved) = try resolveCanonicalPair(
                    output: output,
                    operations: operations,
                    shouldCancel: shouldCancel
                ) else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing receipt did not revalidate"
                    )
                }
                result = resolved
            }
            guard result.plyIdentity.sameObject(as: ply),
                  result.receiptIdentity.sameObject(as: canonicalReceipt),
                  result.result.receipt.publicationID == prepared.publicationID,
                  sha256(result.receiptData) == prepared.newReceiptSHA256 else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing receipt did not revalidate"
                )
            }
            if ownedIdentities[Names.receiptCandidate]?.contains(
                where: { $0.sameObject(as: displaced) }
            ) != true {
                ownedIdentities[Names.receiptCandidate, default: []].append(displaced)
            }
            return result
        }

        func rollbackSwapIfOwned(
            output: BoundOutput,
            operations: PublishedResultPairOperations
        ) throws {
            guard let prepared,
                  let newIdentity = prepared.newReceiptIdentity?.identity,
                  try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalPly,
                    exactMode: 0o600
                  ).sameInode(as: prepared.plyIdentity.identity),
                  try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt,
                    exactMode: 0o600
                  ).sameObject(as: newIdentity),
                  try namedFileIdentity(
                    parent: descriptor,
                    name: Names.receiptCandidate,
                    exactMode: 0o600
                  ).sameObject(as: prepared.oldReceiptIdentity.identity) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing receipt cannot be safely rolled back"
                )
            }
            guard operations.swap(
                descriptor,
                Names.receiptCandidate,
                output.descriptor,
                Names.canonicalReceipt
            ) == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "roll back viewer timing receipt",
                    code: errno
                )
            }
            try synchronizeDirectories(
                [descriptor, output.descriptor],
                operations: operations,
                operation: "roll back viewer timing receipt"
            )
            let rolledBackReceipt = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            let restoredCandidate = try namedFileIdentity(
                parent: descriptor,
                name: Names.receiptCandidate,
                exactMode: 0o600
            )
            guard rolledBackReceipt.sameObject(
                    as: prepared.oldReceiptIdentity.identity
                  ),
                  restoredCandidate.sameObject(as: newIdentity),
                  try digestNamedFile(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt
                  ) == prepared.oldReceiptSHA256,
                  try digestNamedFile(
                    parent: descriptor,
                    name: Names.receiptCandidate
                  ) == prepared.newReceiptSHA256 else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing receipt rollback changed"
                )
            }
        }

        func recoveryState(output: BoundOutput) throws -> State {
            guard let prepared else {
                let ply = try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalPly,
                    exactMode: 0o600
                )
                let receipt = try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt,
                    exactMode: 0o600
                )
                guard ply == created.plyIdentity.identity,
                      receipt == created.oldReceiptIdentity.identity,
                      try digestNamedFile(
                        parent: output.descriptor,
                        name: Names.canonicalReceipt
                      ) == created.oldReceiptSHA256 else {
                    throw PublishedResultPairError.publicationConflict(
                        "incomplete viewer timing transaction conflicts"
                    )
                }
                if entryPresence(
                    parent: descriptor,
                    name: Names.receiptCandidate
                ) == .present {
                    guard try digestNamedFile(
                        parent: descriptor,
                        name: Names.receiptCandidate
                    ) == created.newReceiptSHA256 else {
                        throw PublishedResultPairError.publicationConflict(
                            "incomplete viewer timing candidate changed"
                        )
                    }
                }
                return .beforeSwap
            }
            let canonicalReceipt = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            let candidate = try namedFileIdentity(
                parent: descriptor,
                name: Names.receiptCandidate,
                exactMode: 0o600
            )
            if canonicalReceipt.sameObject(as: prepared.oldReceiptIdentity.identity),
               prepared.newReceiptIdentity.map({
                   candidate.sameObject(as: $0.identity)
               }) == true {
                try requirePreSwapState(output: output)
                return .beforeSwap
            }
            if prepared.newReceiptIdentity.map({
                canonicalReceipt.sameObject(as: $0.identity)
            }) == true,
               candidate.sameObject(as: prepared.oldReceiptIdentity.identity) {
                return .afterSwap
            }
            throw PublishedResultPairError.publicationConflict(
                "viewer timing transaction identities conflict"
            )
        }

        func retireBeforeCommit(
            output: BoundOutput,
            operations: PublishedResultPairOperations
        ) {
            try? retire(output: output, operations: operations)
        }

        func retireAfterCommit(
            output: BoundOutput,
            operations: PublishedResultPairOperations
        ) {
            try? retire(output: output, operations: operations)
        }

        private func retire(
            output: BoundOutput,
            operations: PublishedResultPairOperations
        ) throws {
            let retiredLeaf = Names.receiptRetiredPrefix
                + transactionID.uuidString.lowercased()
            guard try requireBoundChildDirectory(
                descriptor: descriptor,
                parent: output.descriptor,
                name: leaf,
                exactMode: 0o700
            ) == identity else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing transaction directory changed"
                )
            }
            let names = try directoryNames(
                descriptor: descriptor,
                maximumCount: 5
            )
            let allowed = Set([
                Names.receiptCreatedJournal,
                Names.receiptCreatedJournal + ".pending",
                Names.receiptPreparedJournal,
                Names.receiptPreparedJournal + ".pending",
                Names.receiptCandidate,
                Names.cleanupAuthorization,
                Names.cleanupAuthorization + ".pending",
                Names.receiptCleanupStaged,
            ])
            guard Set(names).isSubset(of: allowed) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing cleanup found an unknown entry"
                )
            }
            for name in names {
                if name == Names.cleanupAuthorization
                    || name == Names.cleanupAuthorization + ".pending" {
                    continue
                }
                guard let histories = ownedIdentities[name],
                      let current = try? namedFileIdentity(
                        parent: descriptor,
                        name: name,
                        exactMode: 0o600
                      ), histories.contains(where: { $0.sameObject(as: current) }) else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing cleanup identity changed"
                    )
                }
            }
            guard names.contains(Names.cleanupAuthorization),
                  let stagedIdentity = ownedIdentities[
                    Names.receiptCleanupStaged
                  ]?.last else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing cleanup authority is incomplete"
                )
            }
            let authorityLeaf = Names.receiptCleanupPrefix
                + transactionID.uuidString.lowercased()
                + ".json"
            let stagedPresence = entryPresence(
                parent: descriptor,
                name: Names.receiptCleanupStaged
            )
            let authorityPresence = entryPresence(
                parent: output.descriptor,
                name: authorityLeaf
            )
            guard stagedPresence != .unsafe,
                  authorityPresence != .unsafe,
                  !(stagedPresence == .present && authorityPresence == .present) else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing parent cleanup authority is ambiguous"
                )
            }
            if stagedPresence == .present {
                _ = try moveOwnedInode(
                    from: descriptor,
                    name: Names.receiptCleanupStaged,
                    expected: stagedIdentity,
                    to: output.descriptor,
                    destinationName: authorityLeaf,
                    operations: operations,
                    operation: "publish viewer timing cleanup authority"
                )
                try synchronizeDirectories(
                    [descriptor, output.descriptor],
                    operations: operations,
                    operation: "publish viewer timing cleanup authority"
                )
            } else {
                guard authorityPresence == .present,
                      try namedFileIdentity(
                        parent: output.descriptor,
                        name: authorityLeaf,
                        exactMode: 0o600
                      ).sameObject(as: stagedIdentity) else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing parent cleanup authority changed"
                    )
                }
            }
            guard operations.renameExclusive(
                output.descriptor,
                leaf,
                output.descriptor,
                retiredLeaf
            ) == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "retire viewer timing transaction",
                    code: errno
                )
            }
            try syncDirectory(
                output.descriptor,
                operations: operations,
                operation: "retire viewer timing transaction"
            )
            try cleanupRetiredReceiptDirectory(
                output: output,
                leaf: retiredLeaf,
                operations: operations
            )
        }

        private func writePrivateFile(
            named name: String,
            data: Data,
            operations: PublishedResultPairOperations
        ) throws -> FileIdentity {
            let expectedExisting = ownedIdentities[name]?.last
            let file = name.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    expectedExisting == nil
                        ? O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                        : O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard file >= 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "create \(name)",
                    code: errno
                )
            }
            defer { Darwin.close(file) }
            do {
                if let expectedExisting {
                    let current = try requireBoundFile(
                        descriptor: file,
                        parent: descriptor,
                        name: name,
                        exactMode: 0o600
                    )
                    guard current.sameInode(as: expectedExisting),
                          Darwin.ftruncate(file, 0) == 0 else {
                        throw PublishedResultPairError.publicationConflict(
                            "viewer timing transaction ownership changed"
                        )
                    }
                }
                guard Darwin.fchmod(file, mode_t(0o600)) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "secure \(name)",
                        code: errno
                    )
                }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = operations.write(
                            file,
                            bytes.baseAddress?.advanced(by: offset),
                            bytes.count - offset
                        )
                        if count < 0, errno == EINTR { continue }
                        guard count > 0, count <= bytes.count - offset else {
                            throw PublishedResultPairError.persistence(
                                operation: "write \(name)",
                                code: count < 0 ? errno : EIO
                            )
                        }
                        offset += count
                    }
                }
                try syncFile(file, operations: operations, operation: "write \(name)")
                return try requireBoundFile(
                    descriptor: file,
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                )
            } catch {
                // The transaction either created this leaf with O_EXCL or
                // reopened an inode already bound by its creation journal.
                // Retain the latest identity so a later recovery can safely
                // overwrite or remove only those app-owned partial bytes.
                if let identity = try? requireBoundFile(
                    descriptor: file,
                    parent: descriptor,
                    name: name,
                    exactMode: 0o600
                ) {
                    ownedIdentities[name, default: []].append(identity)
                }
                throw error
            }
        }

        private func writeJournal(
            named name: String,
            data: Data,
            operations: PublishedResultPairOperations
        ) throws -> FileIdentity {
            let pending = name + ".pending"
            let identity = try writePrivateFile(
                named: pending,
                data: data,
                operations: operations
            )
            ownedIdentities[pending, default: []].append(identity)
            guard operations.renameExclusive(
                descriptor,
                pending,
                descriptor,
                name
            ) == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "install viewer timing journal",
                    code: errno
                )
            }
            ownedIdentities.removeValue(forKey: pending)
            ownedIdentities[name, default: []].append(identity)
            return identity
        }

        private static func encodeReceiptJournal(
            _ document: ReceiptJournalDocument
        ) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(document)
        }

        static func decodeReceiptJournal(
            _ data: Data
        ) throws -> ReceiptJournalDocument {
            do {
                try StrictJSONDocument.validate(data, maximumBytes: 65_536)
                let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] ?? [:]
                let required = Set([
                    "schemaVersion", "transactionID", "publicationID", "phase",
                    "plyIdentity", "oldReceiptIdentity",
                    "cleanupAuthorizationIdentity", "oldReceiptSHA256",
                    "newReceiptSHA256",
                ])
                let optional = Set(["newReceiptIdentity"])
                let identityKeys = Set([
                    "device", "inode", "byteCount", "owner", "mode",
                    "linkCount", "modifiedSeconds", "modifiedNanoseconds",
                    "changedSeconds", "changedNanoseconds",
                ])
                guard required.isSubset(of: object.keys),
                      Set(object.keys).isSubset(of: required.union(optional)) else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing journal has an unexpected shape"
                    )
                }
                for key in [
                    "plyIdentity", "oldReceiptIdentity",
                    "cleanupAuthorizationIdentity", "newReceiptIdentity",
                ] where object[key] != nil {
                    guard let identity = object[key] as? [String: Any],
                          Set(identity.keys) == identityKeys else {
                        throw PublishedResultPairError.publicationConflict(
                            "viewer timing journal has an unexpected file identity"
                        )
                    }
                }
                return try JSONDecoder().decode(ReceiptJournalDocument.self, from: data)
            } catch {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing journal cannot be decoded"
                )
            }
        }

        static func validReceiptJournal(
            _ document: ReceiptJournalDocument
        ) -> Bool {
            for digest in [document.oldReceiptSHA256, document.newReceiptSHA256] {
                guard digest.count == 64,
                      digest.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
                    return false
                }
            }
            return document.plyIdentity.identity.owner == getuid()
                && document.plyIdentity.identity.linkCount == 1
                && document.oldReceiptIdentity.identity.owner == getuid()
                && document.oldReceiptIdentity.identity.linkCount == 1
                && document.cleanupAuthorizationIdentity.identity.owner == getuid()
                && document.cleanupAuthorizationIdentity.identity.linkCount == 1
                && document.cleanupAuthorizationIdentity.identity.mode & S_IFMT == S_IFREG
                && document.cleanupAuthorizationIdentity.identity.mode & 0o7777 == 0o600
                && document.newReceiptIdentity.map {
                    $0.identity.owner == getuid() && $0.identity.linkCount == 1
                } ?? true
        }
    }

    static func discardAuthorizedReceiptIntentBuild(
        output: BoundOutput,
        buildLeaf: String,
        authorization: ReceiptBuildAuthorizationDocument,
        operations: PublishedResultPairOperations
    ) throws {
        guard authorization.isPrecreationIntent,
              authorization.ownedFiles.isEmpty,
              authorization.oldReceiptSHA256.count == 64,
              authorization.newReceiptSHA256.count == 64 else {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing build intent is invalid"
            )
        }
        let currentPly = try namedFileIdentity(
            parent: output.descriptor,
            name: Names.canonicalPly,
            exactMode: 0o600
        )
        let currentReceipt = try namedFileIdentity(
            parent: output.descriptor,
            name: Names.canonicalReceipt,
            exactMode: 0o600
        )
        guard currentPly.sameObject(as: authorization.plyIdentity.identity),
              currentReceipt.sameUnchangedFile(
                as: authorization.oldReceiptIdentity.identity
              ),
              sha256(try readPrivateFile(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                maximumBytes: PublishedSplatReceiptStore.maximumBytes
              )) == authorization.oldReceiptSHA256 else {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing build intent belongs to another result"
            )
        }
        let descriptor = buildLeaf.withCString {
            Darwin.openat(
                output.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "authorized viewer timing build is unsafe"
            )
        }
        defer { Darwin.close(descriptor) }
        _ = try requireBoundChildDirectory(
            descriptor: descriptor,
            parent: output.descriptor,
            name: buildLeaf,
            exactMode: 0o700
        )
        let allowedNames = Set([
            Names.cleanupAuthorization,
            Names.cleanupAuthorization + ".pending",
            Names.receiptCreatedJournal,
            Names.receiptCreatedJournal + ".pending",
            Names.receiptCandidate,
            Names.receiptPreparedJournal,
            Names.receiptPreparedJournal + ".pending",
            Names.receiptCleanupStaged,
        ])
        let names = try directoryNames(descriptor: descriptor, maximumCount: 16)
        var normalizedNames = Set<String>()
        var owned: [(String, FileIdentity)] = []
        for name in names {
            let original = cleanupOriginalEntryName(name)
            guard allowedNames.contains(original),
                  normalizedNames.insert(original).inserted else {
                throw PublishedResultPairError.publicationConflict(
                    "authorized viewer timing build contains foreign state"
                )
            }
            owned.append((name, try namedFileIdentity(
                parent: descriptor,
                name: name,
                exactMode: 0o600
            )))
        }
        for (name, identity) in owned {
            try quarantineAndRemoveOwnedEntry(
                parent: descriptor,
                name: name,
                expected: identity,
                operations: operations,
                operation: "discard interrupted viewer timing build"
            )
        }
        try syncDirectory(
            descriptor,
            operations: operations,
            operation: "discard interrupted viewer timing build"
        )
        _ = try removeEmptyTransactionDirectory(
            output: output,
            leaf: buildLeaf,
            operations: operations
        )
    }

    static func reconcileReceiptTransactionLocked(
        output: BoundOutput,
        operations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> PairResolution? {
        let outputNames = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 50_000
        )
        let receiptBuildAuthorities = outputNames.filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionBuildAuthorityPrefix,
                output: output
            )
        }
        let transactionNames = outputNames.filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionPrefix,
                output: output
            ) || hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionPrefix,
                output: output
            ) || (hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionBuildPrefix,
                output: output
            ) && !hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionBuildAuthorityPrefix,
                output: output
            ))
        }
        let receiptNames = transactionNames.filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionPrefix,
                output: output
            )
        }
        let receiptBuildNames = transactionNames.filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptTransactionBuildPrefix,
                output: output
            )
        }
        guard receiptBuildAuthorities.count <= 1 else {
            throw PublishedResultPairError.publicationConflict(
                "multiple viewer timing build authorities are pending"
            )
        }
        guard !receiptNames.isEmpty || !receiptBuildNames.isEmpty
                || !receiptBuildAuthorities.isEmpty else { return nil }
        guard transactionNames.count <= 1,
              receiptNames.count + receiptBuildNames.count <= 1 else {
            throw PublishedResultPairError.publicationConflict(
                "multiple publication transactions are pending"
            )
        }
        if let authorityName = receiptBuildAuthorities.first {
            let original = cleanupOriginalEntryName(authorityName)
            let base = original.hasSuffix(".pending")
                ? String(original.dropLast(".pending".count))
                : original
            guard base.hasPrefix(Names.receiptTransactionBuildAuthorityPrefix),
                  base.hasSuffix(".json") else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed viewer timing build authority"
                )
            }
            let uuidText = String(base.dropFirst(
                Names.receiptTransactionBuildAuthorityPrefix.count
            ).dropLast(".json".count))
            guard let transactionID = UUID(uuidString: uuidText),
                  transactionID.uuidString.lowercased() == uuidText else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed viewer timing build authority identity"
                )
            }
            let expectedBuild = Names.receiptTransactionBuildPrefix + uuidText
            let expectedActive = Names.receiptTransactionPrefix + uuidText
            let authorityIdentity = try namedFileIdentity(
                parent: output.descriptor,
                name: authorityName,
                exactMode: 0o600
            )
            let authorization = try decodeReceiptBuildAuthorization(
                readPrivateFile(
                    parent: output.descriptor,
                    name: authorityName,
                    maximumBytes: 65_536
                )
            )
            guard authorization.transactionID == transactionID,
                  try namedFileIdentity(
                    parent: output.descriptor,
                    name: authorityName,
                    exactMode: 0o600
                  ) == authorityIdentity else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority changed"
                )
            }
            if let buildLeaf = receiptBuildNames.first {
                if buildLeaf == cleanupQuarantineName(expectedBuild),
                   try removeEmptyTransactionDirectory(
                    output: output,
                    leaf: buildLeaf,
                    operations: operations
                   ) {
                    try quarantineAndRemoveOwnedEntry(
                        parent: output.descriptor,
                        name: cleanupOriginalEntryName(authorityName),
                        expected: authorityIdentity,
                        operations: operations,
                        operation: "remove completed viewer timing build authority"
                    )
                    return try resolveCanonicalPair(
                        output: output,
                        operations: operations,
                        shouldCancel: shouldCancel
                    )
                }
                guard buildLeaf == expectedBuild, receiptNames.isEmpty else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing build authority lost its build"
                    )
                }
                try checkCancellation(shouldCancel)
                if authorization.isPrecreationIntent {
                    try discardAuthorizedReceiptIntentBuild(
                        output: output,
                        buildLeaf: buildLeaf,
                        authorization: authorization,
                        operations: operations
                    )
                    try quarantineAndRemoveOwnedEntry(
                        parent: output.descriptor,
                        name: authorityName,
                        expected: authorityIdentity,
                        operations: operations,
                        operation: "remove viewer timing build authority"
                    )
                    return try resolveCanonicalPair(
                        output: output,
                        operations: operations,
                        shouldCancel: shouldCancel
                    )
                }
                let recovered = try ReceiptTransactionDirectory.openAuthorizedBuild(
                    output: output,
                    leaf: buildLeaf,
                    authorityName: authorityName
                )
                try recovered.transaction.requireInactiveBuildPreSwapState(
                    output: output
                )
                try recovered.transaction.discardBuild(
                    output: output,
                    operations: operations
                )
                try quarantineAndRemoveOwnedEntry(
                    parent: output.descriptor,
                    name: authorityName,
                    expected: recovered.authority,
                    operations: operations,
                    operation: "remove viewer timing build authority"
                )
                return try resolveCanonicalPair(
                    output: output,
                    operations: operations,
                    shouldCancel: shouldCancel
                )
            }
            if receiptNames.isEmpty {
                guard authorization.isPrecreationIntent else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing build authority lost its transaction"
                    )
                }
                let currentPly = try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalPly,
                    exactMode: 0o600
                )
                let currentReceipt = try namedFileIdentity(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt,
                    exactMode: 0o600
                )
                guard currentPly.sameObject(
                    as: authorization.plyIdentity.identity
                ), currentReceipt.sameUnchangedFile(
                    as: authorization.oldReceiptIdentity.identity
                ), sha256(try readPrivateFile(
                    parent: output.descriptor,
                    name: Names.canonicalReceipt,
                    maximumBytes: PublishedSplatReceiptStore.maximumBytes
                )) == authorization.oldReceiptSHA256 else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing build authority belongs to another result"
                    )
                }
                try quarantineAndRemoveOwnedEntry(
                    parent: output.descriptor,
                    name: authorityName,
                    expected: authorityIdentity,
                    operations: operations,
                    operation: "retire unused viewer timing build authority"
                )
                return try resolveCanonicalPair(
                    output: output,
                    operations: operations,
                    shouldCancel: shouldCancel
                )
            }
            guard receiptNames == [expectedActive] else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority lost its transaction"
                )
            }
            let transaction = try ReceiptTransactionDirectory.openRecovered(
                output: output,
                leaf: expectedActive
            )
            guard authorization.transactionID == transactionID,
                  (authorization.schemaVersion == 1
                    || authorization.isPrecreationIntent),
                  authorization.publicationID == transaction.created.publicationID,
                  authorization.plyIdentity == transaction.created.plyIdentity,
                  authorization.oldReceiptIdentity
                    == transaction.created.oldReceiptIdentity,
                  authorization.oldReceiptSHA256
                    == transaction.created.oldReceiptSHA256,
                  authorization.newReceiptSHA256
                    == transaction.created.newReceiptSHA256,
                  (authorization.isPrecreationIntent
                    || authorization.directoryIdentity.identity == transaction.identity),
                  try namedFileIdentity(
                    parent: output.descriptor,
                    name: authorityName,
                    exactMode: 0o600
                  ) == authorityIdentity else {
                throw PublishedResultPairError.publicationConflict(
                    "activated viewer timing build authority changed"
                )
            }
            try quarantineAndRemoveOwnedEntry(
                parent: output.descriptor,
                name: cleanupOriginalEntryName(authorityName),
                expected: authorityIdentity,
                operations: operations,
                operation: "retire activated viewer timing build authority"
            )
        }
        if let buildLeaf = receiptBuildNames.first {
            if buildLeaf.hasPrefix(".cleanup-"),
               try removeEmptyTransactionDirectory(
                output: output,
                leaf: buildLeaf,
                operations: operations
               ) {
                return try resolveCanonicalPair(
                    output: output,
                    operations: operations,
                    shouldCancel: shouldCancel
                )
            }
            throw PublishedResultPairError.publicationConflict(
                "viewer timing build has no durable authority: \(buildLeaf)"
            )
        }
        guard let leaf = receiptNames.first else { return nil }
        try checkCancellation(shouldCancel)
        let transaction = try ReceiptTransactionDirectory.openRecovered(
            output: output,
            leaf: leaf
        )
        switch try transaction.recoveryState(output: output) {
        case .beforeSwap:
            let current = try resolveCanonicalPair(
                output: output,
                operations: operations,
                shouldCancel: shouldCancel
            )
            transaction.retireBeforeCommit(output: output, operations: operations)
            return current
        case .afterSwap:
            let committed = try transaction.requirePostSwapState(
                output: output,
                operations: operations,
                shouldCancel: shouldCancel
            )
            transaction.retireAfterCommit(output: output, operations: operations)
            return .available(committed)
        }
    }

    static func reconcileRetiredTransactionsLocked(
        output: BoundOutput,
        operations: PublishedResultPairOperations
    ) throws {
        let retired = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 50_000
        ).filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.retiredPrefix,
                output: output
            )
        }
        for leaf in retired {
            if try removeEmptyTransactionDirectory(
                output: output,
                leaf: leaf,
                operations: operations
            ) {
                continue
            }
            let transaction = try TransactionDirectory.openRetiredForCleanup(
                output: output,
                leaf: leaf
            )
            try transaction.retire(output: output, operations: operations)
        }

        let retiredReceipts = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 50_000
        ).filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptRetiredPrefix,
                output: output
            )
        }
        for leaf in retiredReceipts {
            if try removeEmptyTransactionDirectory(
                output: output,
                leaf: leaf,
                operations: operations
            ) {
                continue
            }
            try cleanupRetiredReceiptDirectory(
                output: output,
                leaf: leaf,
                operations: operations
            )
        }
        try cleanupOrphanedReceiptAuthorities(
            output: output,
            operations: operations
        )
    }

    static func cleanupOrphanedReceiptAuthorities(
        output: BoundOutput,
        operations: PublishedResultPairOperations
    ) throws {
        _ = operations
        let names = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 50_000
        ).filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.receiptCleanupPrefix,
                output: output
            )
        }
        var grouped: [UUID: [String]] = [:]
        for name in names {
            let original = cleanupOriginalEntryName(name)
            let base = original.hasSuffix(".pending")
                ? String(original.dropLast(".pending".count))
                : original
            guard base.hasPrefix(Names.receiptCleanupPrefix),
                  base.hasSuffix(".json") else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed viewer timing cleanup authority"
                )
            }
            let uuidText = String(base.dropFirst(
                Names.receiptCleanupPrefix.count
            ).dropLast(".json".count))
            guard let transactionID = UUID(uuidString: uuidText),
                  Names.receiptCleanupPrefix
                    + transactionID.uuidString.lowercased()
                    + ".json" == base else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed viewer timing cleanup authority"
                )
            }
            grouped[transactionID, default: []].append(name)
        }
        for (transactionID, authorityNames) in grouped {
            guard authorityNames.count == 1,
                  let authorityName = authorityNames.first else {
                throw PublishedResultPairError.publicationConflict(
                    "duplicate viewer timing cleanup authority"
                )
            }
            let activeLeaf = Names.receiptTransactionPrefix
                + transactionID.uuidString.lowercased()
            let buildLeaf = Names.receiptTransactionBuildPrefix
                + transactionID.uuidString.lowercased()
            let retiredLeaf = Names.receiptRetiredPrefix
                + transactionID.uuidString.lowercased()
            if entryPresence(parent: output.descriptor, name: activeLeaf) == .present
                || entryPresence(parent: output.descriptor, name: buildLeaf) == .present {
                continue
            }
            guard entryPresence(
                parent: output.descriptor,
                name: retiredLeaf
            ) == .missing else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing cleanup authority lost its transaction"
                )
            }
            _ = authorityName
            throw PublishedResultPairError.publicationConflict(
                "standalone viewer timing cleanup authority is unbound"
            )
        }
    }

    static func removeEmptyTransactionDirectory(
        output: BoundOutput,
        leaf: String,
        operations: PublishedResultPairOperations
    ) throws -> Bool {
        let descriptor = leaf.withCString {
            Darwin.openat(
                output.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "transaction disappeared during empty-state cleanup"
            )
        }
        defer { Darwin.close(descriptor) }
        let identity = try requireBoundChildDirectory(
            descriptor: descriptor,
            parent: output.descriptor,
            name: leaf,
            exactMode: 0o700
        )
        guard try directoryNames(
            descriptor: descriptor,
            maximumCount: 50_000
        ).isEmpty else {
            return false
        }
        let originalLeaf = cleanupOriginalEntryName(leaf)
        guard leaf == originalLeaf || leaf == cleanupQuarantineName(originalLeaf),
              isCanonicalTransactionDirectoryName(originalLeaf) else {
            throw PublishedResultPairError.publicationConflict(
                "empty transaction changed during cleanup"
            )
        }
        try quarantineAndRemoveOwnedDirectory(
            parent: output.descriptor,
            name: originalLeaf,
            expected: identity,
            operations: operations,
            operation: "remove empty publication transaction"
        )
        return true
    }

    static func cleanupRetiredReceiptDirectory(
        output: BoundOutput,
        leaf: String,
        operations: PublishedResultPairOperations
    ) throws {
        guard leaf.hasPrefix(Names.receiptRetiredPrefix),
              let transactionID = UUID(uuidString: String(
                leaf.dropFirst(Names.receiptRetiredPrefix.count)
              )), Names.receiptRetiredPrefix
                + transactionID.uuidString.lowercased() == leaf else {
            throw PublishedResultPairError.publicationConflict(
                "malformed retired viewer timing transaction"
            )
        }
        let authorityLeaf = Names.receiptCleanupPrefix
            + transactionID.uuidString.lowercased()
            + ".json"
        let authorityPending = authorityLeaf + ".pending"
        let authorityQuarantine = cleanupQuarantineName(authorityLeaf)
        let authorityNames = [
            authorityLeaf,
            authorityPending,
            authorityQuarantine,
        ].filter { entryPresence(parent: output.descriptor, name: $0) == .present }
        guard authorityNames.count == 1,
              var authorityName = authorityNames.first else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing transaction lacks parent cleanup authority"
            )
        }
        if authorityName == authorityPending {
            guard operations.renameExclusive(
                output.descriptor,
                authorityPending,
                output.descriptor,
                authorityLeaf
            ) == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: "finish viewer timing cleanup authority",
                    code: errno
                )
            }
            try syncDirectory(
                output.descriptor,
                operations: operations,
                operation: "finish viewer timing cleanup authority"
            )
            authorityName = authorityLeaf
        }
        let authorityIdentity = try namedFileIdentity(
            parent: output.descriptor,
            name: authorityName,
            exactMode: 0o600
        )
        let authorityData = try readPrivateFile(
            parent: output.descriptor,
            name: authorityName,
            maximumBytes: 65_536
        )
        let authorization: CleanupJournalDocument
        do {
            authorization = try decodeCleanupJournal(authorityData)
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing parent authority is invalid"
            )
        }
        let descriptor = leaf.withCString {
            Darwin.openat(
                output.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "unsafe retired viewer timing transaction"
            )
        }
        defer { Darwin.close(descriptor) }
        let directoryIdentity = try requireBoundChildDirectory(
            descriptor: descriptor,
            parent: output.descriptor,
            name: leaf,
            exactMode: 0o700
        )
        let internalAllowed = Set([
            Names.receiptCreatedJournal,
            Names.receiptPreparedJournal,
            Names.receiptCandidate,
            Names.cleanupAuthorization,
        ])
        let parentOwnedNames = internalAllowed.union([
            Names.receiptDisplacedIdentity,
        ])
        let names = try directoryNames(descriptor: descriptor, maximumCount: 8)
        guard authorization.schemaVersion == 1,
              authorization.transactionID == transactionID,
              authorization.previousPublicationID == nil,
              authorization.directoryIdentity.identity == directoryIdentity,
              Set(authorization.ownedFiles.keys) == parentOwnedNames,
              try namedFileIdentity(
                parent: output.descriptor,
                name: authorityName,
                exactMode: 0o600
              ) == authorityIdentity else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing parent authority changed"
            )
        }
        for (name, recorded) in authorization.ownedFiles {
            let expected = recorded.identity
            guard parentOwnedNames.contains(name), expected.owner == getuid(),
                  expected.linkCount == 1,
                  expected.mode & S_IFMT == S_IFREG,
                  expected.mode & 0o7777 == 0o600 else {
                throw PublishedResultPairError.publicationConflict(
                    "retired viewer timing cleanup ownership is unsafe"
                )
            }
        }
        var actualByLogicalName: [String: String] = [:]
        for name in names {
            let logicalName = logicalReceiptOwnedName(name)
            guard internalAllowed.contains(logicalName),
                  actualByLogicalName.updateValue(name, forKey: logicalName) == nil,
                  authorization.ownedFiles[logicalName] != nil else {
                throw PublishedResultPairError.publicationConflict(
                    "retired viewer timing transaction contains foreign state"
                )
            }
        }
        guard let createdName = actualByLogicalName[
            Names.receiptCreatedJournal
        ], let preparedName = actualByLogicalName[
            Names.receiptPreparedJournal
        ] else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing journals are incomplete"
            )
        }
        let created = try ReceiptTransactionDirectory.decodeReceiptJournal(
            readPrivateFile(
                parent: descriptor,
                name: createdName,
                maximumBytes: 65_536
            )
        )
        let prepared = try ReceiptTransactionDirectory.decodeReceiptJournal(
            readPrivateFile(
                parent: descriptor,
                name: preparedName,
                maximumBytes: 65_536
            )
        )
        guard created.schemaVersion == 1,
              created.transactionID == transactionID,
              created.publicationID == authorization.publicationID,
              created.phase == .created,
              created.newReceiptIdentity == nil,
              ReceiptTransactionDirectory.validReceiptJournal(created),
              prepared.schemaVersion == 1,
              prepared.transactionID == transactionID,
              prepared.publicationID == created.publicationID,
              prepared.phase == .prepared,
              prepared.plyIdentity == created.plyIdentity,
              prepared.oldReceiptIdentity == created.oldReceiptIdentity,
              prepared.cleanupAuthorizationIdentity
                == created.cleanupAuthorizationIdentity,
              prepared.oldReceiptSHA256 == created.oldReceiptSHA256,
              prepared.newReceiptSHA256 == created.newReceiptSHA256,
              prepared.newReceiptIdentity != nil,
              ReceiptTransactionDirectory.validReceiptJournal(prepared),
              authorization.ownedFiles[Names.receiptDisplacedIdentity]
                == created.oldReceiptIdentity,
              authorization.ownedFiles[Names.cleanupAuthorization]
                == created.cleanupAuthorizationIdentity,
              authorization.ownedFiles[Names.receiptCandidate]
                == prepared.newReceiptIdentity else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing journal linkage is invalid"
            )
        }
        let createdIdentity = try namedFileIdentity(
            parent: descriptor,
            name: createdName,
            exactMode: 0o600
        )
        let preparedIdentity = try namedFileIdentity(
            parent: descriptor,
            name: preparedName,
            exactMode: 0o600
        )
        guard authorization.ownedFiles[Names.receiptCreatedJournal].map({
            createdIdentity.sameUnchangedFile(as: $0.identity)
        }) == true,
              authorization.ownedFiles[Names.receiptPreparedJournal].map({
                preparedIdentity.sameUnchangedFile(as: $0.identity)
              }) == true else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing journals changed"
            )
        }
        var currentIdentities: [String: FileIdentity] = [
            Names.receiptCreatedJournal: createdIdentity,
            Names.receiptPreparedJournal: preparedIdentity,
        ]
        if let candidateName = actualByLogicalName[Names.receiptCandidate] {
            let candidate = try namedFileIdentity(
                parent: descriptor,
                name: candidateName,
                exactMode: 0o600
            )
            guard let newIdentity = prepared.newReceiptIdentity?.identity else {
                throw PublishedResultPairError.publicationConflict(
                    "retired viewer timing candidate linkage is missing"
                )
            }
            let displaced = created.oldReceiptIdentity.identity
            let expectedDigest: String
            if candidate.sameObject(as: newIdentity) {
                expectedDigest = prepared.newReceiptSHA256
            } else if candidate.sameObject(as: displaced) {
                expectedDigest = prepared.oldReceiptSHA256
            } else {
                throw PublishedResultPairError.publicationConflict(
                    "retired viewer timing candidate ownership changed"
                )
            }
            guard try digestNamedFile(
                parent: descriptor,
                name: candidateName
            ) == expectedDigest else {
                throw PublishedResultPairError.publicationConflict(
                    "retired viewer timing candidate bytes changed"
                )
            }
            currentIdentities[Names.receiptCandidate] = candidate
        }
        if let cleanupName = actualByLogicalName[Names.cleanupAuthorization] {
            let cleanupIdentity = try namedFileIdentity(
                parent: descriptor,
                name: cleanupName,
                exactMode: 0o600
            )
            guard cleanupIdentity.sameInode(
                as: created.cleanupAuthorizationIdentity.identity
            ) else {
                throw PublishedResultPairError.publicationConflict(
                    "retired viewer timing cleanup ownership changed"
                )
            }
            let cleanup = try decodeCleanupJournal(readPrivateFile(
                parent: descriptor,
                name: cleanupName,
                maximumBytes: 65_536
            ))
            let internalOwnedNames = Set([
                Names.receiptCreatedJournal,
                Names.receiptPreparedJournal,
                Names.receiptCandidate,
                Names.receiptCleanupStaged,
            ])
            guard cleanup.schemaVersion == 1,
                  cleanup.transactionID == transactionID,
                  cleanup.publicationID == created.publicationID,
                  cleanup.previousPublicationID == nil,
                  cleanup.directoryIdentity.identity == directoryIdentity,
                  Set(cleanup.ownedFiles.keys) == internalOwnedNames,
                  cleanup.ownedFiles[Names.receiptCreatedJournal]
                    == authorization.ownedFiles[Names.receiptCreatedJournal],
                  cleanup.ownedFiles[Names.receiptPreparedJournal]
                    == authorization.ownedFiles[Names.receiptPreparedJournal],
                  cleanup.ownedFiles[Names.receiptCandidate]
                    == authorization.ownedFiles[Names.receiptCandidate],
                  cleanup.ownedFiles[Names.receiptCleanupStaged].map({
                    authorityIdentity.sameObject(as: $0.identity)
                  }) == true else {
                throw PublishedResultPairError.publicationConflict(
                    "retired viewer timing authorities are not cross-linked"
                )
            }
            currentIdentities[Names.cleanupAuthorization] = cleanupIdentity
        }
        guard try namedFileIdentity(
            parent: output.descriptor,
            name: authorityName,
            exactMode: 0o600
        ) == authorityIdentity else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing authority changed during validation"
            )
        }
        for logicalName in [
            Names.cleanupAuthorization,
            Names.receiptCandidate,
        ] {
            guard let actual = actualByLogicalName[logicalName],
                  let expected = currentIdentities[logicalName] else { continue }
            try quarantineAndRemoveOwnedEntry(
                parent: descriptor,
                name: cleanupOriginalEntryName(actual),
                expected: expected,
                operations: operations,
                operation: "remove retired viewer timing state"
            )
        }
        let journalNames = Set([createdName, preparedName])
        guard Set(try directoryNames(
            descriptor: descriptor,
            maximumCount: 8
        )) == journalNames,
        try namedFileIdentity(
            parent: descriptor,
            name: createdName,
            exactMode: 0o600
        ).sameUnchangedFile(as: createdIdentity),
        try namedFileIdentity(
            parent: descriptor,
            name: preparedName,
            exactMode: 0o600
        ).sameUnchangedFile(as: preparedIdentity) else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing state changed before authority cleanup"
            )
        }
        try quarantineAndRemoveOwnedEntry(
            parent: output.descriptor,
            name: cleanupOriginalEntryName(authorityName),
            expected: authorityIdentity,
            operations: operations,
            operation: "remove viewer timing parent cleanup authority"
        )
        for logicalName in [
            Names.receiptPreparedJournal,
            Names.receiptCreatedJournal,
        ] {
            guard let actual = actualByLogicalName[logicalName],
                  let expected = currentIdentities[logicalName] else { continue }
            try quarantineAndRemoveOwnedEntry(
                parent: descriptor,
                name: cleanupOriginalEntryName(actual),
                expected: expected,
                operations: operations,
                operation: "remove retired viewer timing journal"
            )
        }
        guard try directoryNames(descriptor: descriptor, maximumCount: 1).isEmpty else {
            throw PublishedResultPairError.publicationConflict(
                "retired viewer timing cleanup left unknown state"
            )
        }
        try quarantineAndRemoveOwnedDirectory(
            parent: output.descriptor,
            name: leaf,
            expected: directoryIdentity,
            operations: operations,
            operation: "remove retired viewer timing transaction"
        )
    }

    static func digestNamedFile(parent: Int32, name: String) throws -> String {
        let descriptor = openReadOnly(parent: parent, name: name)
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "could not open \(name)"
            )
        }
        defer { Darwin.close(descriptor) }
        let identity = try requireBoundFile(
            descriptor: descriptor,
            parent: parent,
            name: name,
            exactMode: 0o600
        )
        let data = try readBoundFile(
            descriptor: descriptor,
            identity: identity,
            maximumBytes: PublishedSplatReceiptStore.maximumBytes
        )
        return sha256(data)
    }

    static func resolveCanonicalPair(
        output: BoundOutput,
        operations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> PairResolution {
        try resolvePair(
            plyDirectory: output.descriptor,
            plyName: Names.canonicalPly,
            receiptDirectory: output.descriptor,
            receiptName: Names.canonicalReceipt,
            outputURL: output.projectPaths.outputSplatURL,
            operations: operations,
            shouldCancel: shouldCancel
        )
    }

    static func resolveCanonicalPair(
        output: BoundOutput,
        expectedGeneration: PublishedResultGeneration,
        allowingFirstViewerReadySeconds: Double? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> PairResolution {
        try checkCancellation(shouldCancel)
        let plyPresence = entryPresence(
            parent: output.descriptor,
            name: Names.canonicalPly
        )
        let receiptPresence = entryPresence(
            parent: output.descriptor,
            name: Names.canonicalReceipt
        )
        switch (plyPresence, receiptPresence) {
        case (.missing, .missing):
            return .missing
        case (.missing, _), (_, .missing):
            return .unavailable(.incompletePair)
        case (.unsafe, _), (_, .unsafe):
            return .unavailable(.unsafePair)
        case (.present, .present):
            break
        }

        let receiptDescriptor = openReadOnly(
            parent: output.descriptor,
            name: Names.canonicalReceipt
        )
        guard receiptDescriptor >= 0 else { return .unavailable(.unsafePair) }
        defer { Darwin.close(receiptDescriptor) }
        let plyDescriptor = openReadOnly(
            parent: output.descriptor,
            name: Names.canonicalPly
        )
        guard plyDescriptor >= 0 else { return .unavailable(.unsafePair) }
        defer { Darwin.close(plyDescriptor) }

        do {
            let receiptIdentity = try requireBoundFile(
                descriptor: receiptDescriptor,
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            let plyIdentity = try requireBoundFile(
                descriptor: plyDescriptor,
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            let receiptData = try readBoundFile(
                descriptor: receiptDescriptor,
                identity: receiptIdentity,
                maximumBytes: PublishedSplatReceiptStore.maximumBytes
            )
            let receipt: PublishedSplatReceipt
            do {
                receipt = try PublishedSplatReceiptStore.decode(receiptData)
            } catch {
                return .unavailable(.invalidReceipt)
            }
            try checkCancellation(shouldCancel)
            let finalReceipt = try requireBoundFile(
                descriptor: receiptDescriptor,
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            let finalPly = try requireBoundFile(
                descriptor: plyDescriptor,
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            guard finalReceipt == receiptIdentity,
                  finalPly == plyIdentity else {
                return .unavailable(.unsafePair)
            }
            let currentGeneration = generation(
                receipt: receipt,
                outputEvidence: receipt.outputEvidence,
                plyIdentity: plyIdentity,
                receiptIdentity: receiptIdentity,
                receiptData: receiptData
            )
            let current = BoundPair(
                result: ValidatedPublishedResult(
                    receipt: receipt,
                    outputURL: output.projectPaths.outputSplatURL,
                    outputEvidence: expectedGeneration.outputEvidence,
                    generation: currentGeneration
                ),
                plyIdentity: plyIdentity,
                receiptIdentity: receiptIdentity,
                receiptData: receiptData
            )
            guard generation(
                current,
                matches: expectedGeneration,
                allowingFirstViewerReadySeconds:
                    allowingFirstViewerReadySeconds
            ) else {
                return .unavailable(.unsafePair)
            }
            return .available(current)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(.unsafePair)
        }
    }

    static func rebindCanonicalPairAfterTimingSwap(
        previous: BoundPair,
        output: BoundOutput,
        expectedPly: FileIdentity,
        expectedReceipt: FileIdentity,
        publicationID: UUID,
        receiptSHA256: String
    ) throws -> BoundPair {
        try output.revalidate()
        let plyDescriptor = openReadOnly(
            parent: output.descriptor,
            name: Names.canonicalPly
        )
        guard plyDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing PLY became inaccessible"
            )
        }
        defer { Darwin.close(plyDescriptor) }
        let receiptDescriptor = openReadOnly(
            parent: output.descriptor,
            name: Names.canonicalReceipt
        )
        guard receiptDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing receipt became inaccessible"
            )
        }
        defer { Darwin.close(receiptDescriptor) }

        let initialPly = try requireBoundFile(
            descriptor: plyDescriptor,
            parent: output.descriptor,
            name: Names.canonicalPly,
            exactMode: 0o600
        )
        let initialReceipt = try requireBoundFile(
            descriptor: receiptDescriptor,
            parent: output.descriptor,
            name: Names.canonicalReceipt,
            exactMode: 0o600
        )
        guard initialPly.sameUnchangedFile(as: previous.plyIdentity),
              initialPly.sameUnchangedFile(as: expectedPly),
              initialReceipt.sameUnchangedFile(as: expectedReceipt) else {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing canonical pair changed"
            )
        }
        let receiptData = try readBoundFile(
            descriptor: receiptDescriptor,
            identity: initialReceipt,
            maximumBytes: PublishedSplatReceiptStore.maximumBytes
        )
        let receipt: PublishedSplatReceipt
        do {
            receipt = try PublishedSplatReceiptStore.decode(receiptData)
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing receipt is invalid"
            )
        }
        let finalPly = try requireBoundFile(
            descriptor: plyDescriptor,
            parent: output.descriptor,
            name: Names.canonicalPly,
            exactMode: 0o600
        )
        let finalReceipt = try requireBoundFile(
            descriptor: receiptDescriptor,
            parent: output.descriptor,
            name: Names.canonicalReceipt,
            exactMode: 0o600
        )
        guard finalPly.sameUnchangedFile(as: initialPly),
              finalReceipt.sameUnchangedFile(as: initialReceipt),
              receipt.publicationID == publicationID,
              receipt.outputEvidence == previous.result.outputEvidence,
              sha256(receiptData) == receiptSHA256 else {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing receipt did not rebind to the validated PLY"
            )
        }
        let committedGeneration = generation(
            receipt: receipt,
            outputEvidence: previous.result.outputEvidence,
            plyIdentity: finalPly,
            receiptIdentity: finalReceipt,
            receiptData: receiptData
        )
        return BoundPair(
            result: ValidatedPublishedResult(
                receipt: receipt,
                outputURL: output.projectPaths.outputSplatURL,
                outputEvidence: previous.result.outputEvidence,
                generation: committedGeneration
            ),
            plyIdentity: finalPly,
            receiptIdentity: finalReceipt,
            receiptData: receiptData
        )
    }

    static func canonicalReceiptData(
        for receipt: PublishedSplatReceipt
    ) -> Data? {
        try? PublishedSplatReceiptStore.encode(receipt)
    }

    static func generation(
        receipt: PublishedSplatReceipt,
        outputEvidence: ValidatedPlyArtifactEvidence,
        plyIdentity: FileIdentity,
        receiptIdentity: FileIdentity,
        receiptData: Data
    ) -> PublishedResultGeneration {
        PublishedResultGeneration(
            receipt: receipt,
            outputEvidence: outputEvidence,
            plyIdentity: PublishedResultGenerationFileIdentity(plyIdentity),
            receiptIdentity: PublishedResultGenerationFileIdentity(receiptIdentity),
            receiptSHA256: sha256(receiptData)
        )
    }

    static func generation(
        _ current: BoundPair,
        matches expected: PublishedResultGeneration,
        allowingFirstViewerReadySeconds seconds: Double?
    ) -> Bool {
        guard let currentGeneration = current.result.generation else {
            return false
        }
        if currentGeneration == expected { return true }
        guard let seconds,
              seconds.isFinite,
              seconds >= 0,
              expected.receipt.presentation.createToViewerReadySeconds == nil,
              PublishedResultGenerationFileIdentity(current.plyIdentity)
                == expected.plyIdentity,
              current.result.outputEvidence == expected.outputEvidence,
              current.result.receipt.outputEvidence == expected.outputEvidence else {
            return false
        }
        let successor = receipt(
            expected.receipt,
            recordingFirstViewerReadySeconds: seconds
        )
        guard current.result.receipt == successor,
              let successorData = canonicalReceiptData(for: successor) else {
            return false
        }
        return current.receiptData == successorData
    }

    static func requireCanonicalPairUnchanged(
        pair: BoundPair,
        output: BoundOutput
    ) throws {
        try output.revalidate()
        let currentPly = try namedFileIdentity(
            parent: output.descriptor,
            name: Names.canonicalPly,
            exactMode: 0o600
        )
        let currentReceipt = try namedFileIdentity(
            parent: output.descriptor,
            name: Names.canonicalReceipt,
            exactMode: 0o600
        )
        guard currentPly == pair.plyIdentity,
              currentReceipt == pair.receiptIdentity else {
            throw PublishedResultPairError.publicationConflict(
                "the canonical pair changed after validation"
            )
        }
    }

    static func reconciledCommittedPairWithoutResidue(
        expected: BoundPair,
        output: BoundOutput,
        operations: PublishedResultPairOperations
    ) throws -> BoundPair? {
        try output.revalidate()
        guard case .available(let current) = try resolveCanonicalPair(
            output: output,
            operations: operations
        ), current.result == expected.result,
        current.plyIdentity == expected.plyIdentity,
        current.receiptIdentity == expected.receiptIdentity,
        current.receiptData == expected.receiptData else {
            return nil
        }
        let names = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 50_000
        )
        guard !names.contains(where: {
            hasAnyReservedPublicationNamespace($0, output: output)
        }) else {
            return nil
        }
        try requireCanonicalPairUnchanged(pair: current, output: output)
        return current
    }

    static func receipt(
        _ current: PublishedSplatReceipt,
        recordingFirstViewerReadySeconds seconds: Double
    ) -> PublishedSplatReceipt {
        let old = current.presentation
        let presentation = PublishedResultPresentation(
            requestedRunOptions: old.requestedRunOptions,
            resolvedRunPlan: old.resolvedRunPlan,
            reconstruction: old.reconstruction,
            orientation: old.orientation,
            stageTimings: old.stageTimings,
            autoTunerSnapshot: old.autoTunerSnapshot,
            trainerVersion: old.trainerVersion,
            runtimeVersion: old.runtimeVersion,
            completedIteration: old.completedIteration,
            trainingDurationSeconds: old.trainingDurationSeconds,
            createToViewerReadySeconds: seconds
        )
        return PublishedSplatReceipt(
            schemaVersion: current.schemaVersion,
            publicationID: current.publicationID,
            projectID: current.projectID,
            publishedAt: current.publishedAt,
            outputPath: current.outputPath,
            outputEvidence: current.outputEvidence,
            lineage: current.lineage,
            presentation: presentation
        )
    }

    static func receipt(
        _ current: PublishedSplatReceipt,
        recordingStageTimings stageTimings: [StageTimingRecord]
    ) -> PublishedSplatReceipt {
        let publicationCompletedAt = stageTimings.reduce(
            current.publishedAt
        ) { latest, timing in
            let completed = timing.startedAt.addingTimeInterval(
                timing.durationSeconds
            )
            return completed > latest ? completed : latest
        }
        let old = current.presentation
        let presentation = PublishedResultPresentation(
            requestedRunOptions: old.requestedRunOptions,
            resolvedRunPlan: old.resolvedRunPlan,
            reconstruction: old.reconstruction,
            orientation: old.orientation,
            stageTimings: stageTimings,
            autoTunerSnapshot: old.autoTunerSnapshot,
            trainerVersion: old.trainerVersion,
            runtimeVersion: old.runtimeVersion,
            completedIteration: old.completedIteration,
            trainingDurationSeconds: old.trainingDurationSeconds,
            createToViewerReadySeconds: old.createToViewerReadySeconds
        )
        return PublishedSplatReceipt(
            schemaVersion: current.schemaVersion,
            publicationID: current.publicationID,
            projectID: current.projectID,
            publishedAt: publicationCompletedAt,
            outputPath: current.outputPath,
            outputEvidence: current.outputEvidence,
            lineage: current.lineage,
            presentation: presentation
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resolvePair(
        plyDirectory: Int32,
        plyName: String,
        receiptDirectory: Int32,
        receiptName: String,
        outputURL: URL,
        operations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> PairResolution {
        let plyPresence = entryPresence(parent: plyDirectory, name: plyName)
        let receiptPresence = entryPresence(parent: receiptDirectory, name: receiptName)
        switch (plyPresence, receiptPresence) {
        case (.missing, .missing):
            return .missing
        case (.missing, _), (_, .missing):
            return .unavailable(.incompletePair)
        case (.unsafe, _), (_, .unsafe):
            return .unavailable(.unsafePair)
        case (.present, .present):
            break
        }

        let receiptDescriptor = openReadOnly(parent: receiptDirectory, name: receiptName)
        guard receiptDescriptor >= 0 else { return .unavailable(.unsafePair) }
        defer { Darwin.close(receiptDescriptor) }
        let plyDescriptor = openReadOnly(parent: plyDirectory, name: plyName)
        guard plyDescriptor >= 0 else { return .unavailable(.unsafePair) }
        defer { Darwin.close(plyDescriptor) }

        do {
            let receiptIdentity = try requireBoundFile(
                descriptor: receiptDescriptor,
                parent: receiptDirectory,
                name: receiptName,
                exactMode: 0o600
            )
            let plyIdentity = try requireBoundFile(
                descriptor: plyDescriptor,
                parent: plyDirectory,
                name: plyName,
                exactMode: 0o600
            )
            let receiptData = try readBoundFile(
                descriptor: receiptDescriptor,
                identity: receiptIdentity,
                maximumBytes: PublishedSplatReceiptStore.maximumBytes
            )
            let receipt: PublishedSplatReceipt
            do {
                receipt = try PublishedSplatReceiptStore.decode(receiptData)
            } catch {
                return .unavailable(.invalidReceipt)
            }
            let evidence: ValidatedPlyArtifactEvidence
            do {
                operations.willValidatePly(plyName)
                evidence = try ProjectArtifactValidator.validatedPlyEvidence(
                    descriptor: plyDescriptor,
                    label: plyName,
                    shouldCancel: shouldCancel
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .unavailable(.invalidPly)
            }
            let finalReceipt = try requireBoundFile(
                descriptor: receiptDescriptor,
                parent: receiptDirectory,
                name: receiptName,
                exactMode: 0o600
            )
            let finalPly = try requireBoundFile(
                descriptor: plyDescriptor,
                parent: plyDirectory,
                name: plyName,
                exactMode: 0o600
            )
            guard finalReceipt == receiptIdentity,
                  finalPly == plyIdentity else {
                return .unavailable(.unsafePair)
            }
            guard evidence == receipt.outputEvidence else {
                return .unavailable(.evidenceMismatch)
            }
            let validatedGeneration = generation(
                receipt: receipt,
                outputEvidence: evidence,
                plyIdentity: plyIdentity,
                receiptIdentity: receiptIdentity,
                receiptData: receiptData
            )
            return .available(BoundPair(
                result: ValidatedPublishedResult(
                    receipt: receipt,
                    outputURL: outputURL,
                    outputEvidence: evidence,
                    generation: validatedGeneration
                ),
                plyIdentity: plyIdentity,
                receiptIdentity: receiptIdentity,
                receiptData: receiptData
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(.unsafePair)
        }
    }

    static func rollbackLivePublication(
        output: BoundOutput,
        transaction: TransactionDirectory,
        previous: BoundPair?,
        previousPlyMoved: Bool,
        previousReceiptMoved: Bool,
        newPlyInstalled: Bool,
        newReceiptInstalled: Bool,
        stagedPlyIdentity: FileIdentity?,
        stagedReceiptIdentity: FileIdentity?,
        operations: PublishedResultPairOperations
    ) throws {
        var cleanupPlyIdentity = stagedPlyIdentity
        var cleanupReceiptIdentity = stagedReceiptIdentity
        if newReceiptInstalled, let stagedReceiptIdentity {
            cleanupReceiptIdentity = try moveOwnedInode(
                from: output.descriptor,
                name: Names.canonicalReceipt,
                expected: stagedReceiptIdentity,
                to: transaction.descriptor,
                destinationName: Names.newReceipt,
                operations: operations,
                operation: "roll back new receipt"
            )
        }
        if newPlyInstalled, let stagedPlyIdentity {
            cleanupPlyIdentity = try moveOwnedInode(
                from: output.descriptor,
                name: Names.canonicalPly,
                expected: stagedPlyIdentity,
                to: transaction.descriptor,
                destinationName: Names.newPly,
                operations: operations,
                operation: "roll back new PLY"
            )
        }
        if previousPlyMoved, let previous {
            try moveExpected(
                from: transaction.descriptor,
                name: Names.oldPly,
                expected: previous.plyIdentity,
                to: output.descriptor,
                destinationName: Names.canonicalPly,
                operations: operations,
                operation: "restore previous PLY"
            )
        }
        if previousReceiptMoved, let previous {
            try moveExpected(
                from: transaction.descriptor,
                name: Names.oldReceipt,
                expected: previous.receiptIdentity,
                to: output.descriptor,
                destinationName: Names.canonicalReceipt,
                operations: operations,
                operation: "restore previous receipt"
            )
        }
        try synchronizeDirectories(
            [transaction.descriptor, output.descriptor],
            operations: operations,
            operation: "restore previous result"
        )
        if let previous {
            guard case .available(let restored) = try resolveCanonicalPair(
                output: output,
                operations: operations
            ), restored.result == previous.result else {
                throw PublishedResultPairError.publicationConflict(
                    "previous pair did not revalidate after rollback"
                )
            }
        }
        var stagedFiles: [String: FileIdentity] = [:]
        if let cleanupPlyIdentity {
            stagedFiles[Names.newPly] = cleanupPlyIdentity
        }
        if let cleanupReceiptIdentity {
            stagedFiles[Names.newReceipt] = cleanupReceiptIdentity
        }
        try transaction.retire(
            output: output,
            operations: operations,
            additionalOwnedFiles: stagedFiles
        )
    }

    static func reconcileAuthorizedInactiveBuild(
        output: BoundOutput,
        buildLeaf: String,
        authorityName: String,
        operations: PublishedResultPairOperations
    ) throws {
        let buildSuffix = String(buildLeaf.dropFirst(
            Names.transactionBuildPrefix.count
        ))
        guard buildLeaf.hasPrefix(Names.transactionBuildPrefix),
              let transactionID = UUID(uuidString: buildSuffix),
              transactionID.uuidString.lowercased() == buildSuffix else {
            throw PublishedResultPairError.publicationConflict(
                "malformed inactive publication build"
            )
        }
        let expectedAuthority = Names.transactionBuildAuthorityPrefix
            + transactionID.uuidString.lowercased()
            + ".json"
        let originalAuthority = cleanupOriginalEntryName(authorityName)
        let authorityBase = originalAuthority.hasSuffix(".pending")
            ? String(originalAuthority.dropLast(".pending".count))
            : originalAuthority
        guard authorityBase == expectedAuthority else {
            throw PublishedResultPairError.publicationConflict(
                "publication build authority identity mismatch"
            )
        }
        let initialAuthorityIdentity = try namedFileIdentity(
            parent: output.descriptor,
            name: authorityName,
            exactMode: 0o600
        )
        let authorization = try decodeBuildAuthorization(readPrivateFile(
            parent: output.descriptor,
            name: authorityName,
            maximumBytes: 65_536
        ))
        let validAuthorityVersion = authorization.schemaVersion == 1
            ? !authorization.directoryIdentity.isUnboundIntent
            : authorization.isPrecreationIntent
        guard validAuthorityVersion,
              authorization.transactionID == transactionID,
              (authorization.previousPublicationID == nil)
                == (authorization.previousPairIdentities == nil),
              try namedFileIdentity(
                parent: output.descriptor,
                name: authorityName,
                exactMode: 0o600
              ) == initialAuthorityIdentity else {
            throw PublishedResultPairError.publicationConflict(
                "publication build authority changed"
            )
        }
        let descriptor = buildLeaf.withCString {
            Darwin.openat(
                output.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "authorized publication build is unsafe"
            )
        }
        defer { Darwin.close(descriptor) }
        let directoryIdentity = try requireBoundChildDirectory(
            descriptor: descriptor,
            parent: output.descriptor,
            name: buildLeaf,
            exactMode: 0o700
        )
        guard authorization.isPrecreationIntent
                || authorization.directoryIdentity.identity == directoryIdentity else {
            throw PublishedResultPairError.publicationConflict(
                "authorized publication build changed"
            )
        }
        let expectedJournal = JournalDocument(
            schemaVersion: 3,
            transactionID: transactionID,
            publicationID: authorization.publicationID,
            previousPublicationID: authorization.previousPublicationID,
            previousPairIdentities: authorization.previousPairIdentities,
            canonicalPlyIdentity: nil,
            canonicalReceiptIdentity: nil,
            phase: .created,
            ownedFiles: [:]
        )
        let names = try directoryNames(descriptor: descriptor, maximumCount: 2)
        if names.isEmpty {
            _ = try writeOutputPrivateFile(
                parent: descriptor,
                pendingName: PublishedResultPairJournalPhase.created.pendingLeaf,
                finalName: PublishedResultPairJournalPhase.created.leaf,
                data: try encodeJournal(expectedJournal),
                operations: operations,
                operation: "complete authorized publication build"
            )
        } else {
            guard names.count == 1,
                  let onlyName = names.first,
                  onlyName == PublishedResultPairJournalPhase.created.leaf
                    || onlyName == PublishedResultPairJournalPhase.created.pendingLeaf,
                  try decodeJournal(readPrivateFile(
                    parent: descriptor,
                    name: onlyName,
                    maximumBytes: 65_536
                  )) == expectedJournal else {
                throw PublishedResultPairError.publicationConflict(
                    "authorized publication build contains foreign state"
                )
            }
            if onlyName == PublishedResultPairJournalPhase.created.pendingLeaf {
                guard operations.renameExclusive(
                    descriptor,
                    onlyName,
                    descriptor,
                    PublishedResultPairJournalPhase.created.leaf
                ) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "complete authorized publication build",
                        code: errno
                    )
                }
                try syncDirectory(
                    descriptor,
                    operations: operations,
                    operation: "complete authorized publication build"
                )
            }
        }
        try quarantineAndRemoveOwnedEntry(
            parent: output.descriptor,
            name: authorityName,
            expected: initialAuthorityIdentity,
            operations: operations,
            operation: "retire publication build authority"
        )
        let transaction = try TransactionDirectory.openRecovered(
            output: output,
            leaf: buildLeaf,
            prefix: Names.transactionBuildPrefix
        )
        guard transaction.lastJournal?.phase == .created else {
            throw PublishedResultPairError.publicationConflict(
                "authorized publication build advanced unexpectedly"
            )
        }
        try transaction.discardUncommitted(
            output: output,
            operations: operations,
            transactionLeaf: buildLeaf
        )
    }

    static func reconcileLocked(
        output: BoundOutput,
        operations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> PairResolution? {
        try checkCancellation(shouldCancel)
        try reconcileRetiredTransactionsLocked(
            output: output,
            operations: operations
        )
        try checkCancellation(shouldCancel)
        if let receiptResolution = try reconcileReceiptTransactionLocked(
            output: output,
            operations: operations,
            shouldCancel: shouldCancel
        ) {
            return receiptResolution
        }
        let transactionEntries = try directoryNames(
            descriptor: output.descriptor,
            maximumCount: 50_000
        )
        let active = transactionEntries.filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionPrefix,
                output: output
            )
        }
        let inactiveBuilds = transactionEntries.filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionBuildPrefix,
                output: output
            ) && !hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionBuildAuthorityPrefix,
                output: output
            )
        }
        let buildAuthorities = transactionEntries.filter {
            hasReservedNamespacePrefix(
                $0,
                prefix: Names.transactionBuildAuthorityPrefix,
                output: output
            )
        }
        guard active.count + inactiveBuilds.count <= 1,
              buildAuthorities.count <= 1 else {
            throw PublishedResultPairError.publicationConflict(
                "multiple publication transactions are pending"
            )
        }
        if let authorityName = buildAuthorities.first {
            let originalAuthority = cleanupOriginalEntryName(authorityName)
            let authorityBase = originalAuthority.hasSuffix(".pending")
                ? String(originalAuthority.dropLast(".pending".count))
                : originalAuthority
            guard authorityBase.hasPrefix(Names.transactionBuildAuthorityPrefix),
                  authorityBase.hasSuffix(".json") else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed publication build authority"
                )
            }
            let uuidText = String(authorityBase.dropFirst(
                Names.transactionBuildAuthorityPrefix.count
            ).dropLast(".json".count))
            guard let transactionID = UUID(uuidString: uuidText),
                  transactionID.uuidString.lowercased() == uuidText else {
                throw PublishedResultPairError.publicationConflict(
                    "malformed publication build authority identity"
                )
            }
            let expectedBuild = Names.transactionBuildPrefix + uuidText
            let expectedActive = Names.transactionPrefix + uuidText
            if let buildLeaf = inactiveBuilds.first {
                guard buildLeaf == expectedBuild, active.isEmpty else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication build authority lost its transaction"
                    )
                }
                try reconcileAuthorizedInactiveBuild(
                    output: output,
                    buildLeaf: buildLeaf,
                    authorityName: authorityName,
                    operations: operations
                )
                return nil
            }
            if let activeLeaf = active.first {
                guard activeLeaf == expectedActive else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication build authority lost its transaction"
                    )
                }
                let authorityIdentity = try namedFileIdentity(
                    parent: output.descriptor,
                    name: authorityName,
                    exactMode: 0o600
                )
                let authorization = try decodeBuildAuthorization(readPrivateFile(
                    parent: output.descriptor,
                    name: authorityName,
                    maximumBytes: 65_536
                ))
                let transaction = try TransactionDirectory.openRecovered(
                    output: output,
                    leaf: activeLeaf
                )
                guard authorization.transactionID == transactionID,
                      (authorization.schemaVersion == 1
                        || authorization.isPrecreationIntent),
                      authorization.publicationID == transaction.publicationID,
                      authorization.previousPublicationID
                        == transaction.previousPublicationID,
                      authorization.previousPairIdentities
                        == transaction.previousPairIdentities,
                      (authorization.isPrecreationIntent
                        || authorization.directoryIdentity.identity
                            == transaction.identity),
                      try namedFileIdentity(
                        parent: output.descriptor,
                        name: authorityName,
                        exactMode: 0o600
                      ) == authorityIdentity else {
                    throw PublishedResultPairError.publicationConflict(
                        "activated publication build authority changed"
                    )
                }
                try quarantineAndRemoveOwnedEntry(
                    parent: output.descriptor,
                    name: authorityName,
                    expected: authorityIdentity,
                    operations: operations,
                    operation: "retire activated publication build authority"
                )
            } else {
                let authorityIdentity = try namedFileIdentity(
                    parent: output.descriptor,
                    name: authorityName,
                    exactMode: 0o600
                )
                let authorization = try decodeBuildAuthorization(readPrivateFile(
                    parent: output.descriptor,
                    name: authorityName,
                    maximumBytes: 65_536
                ))
                guard authorization.transactionID == transactionID,
                      authorization.isPrecreationIntent,
                      try namedFileIdentity(
                        parent: output.descriptor,
                        name: authorityName,
                        exactMode: 0o600
                      ) == authorityIdentity else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication build authority lost its transaction"
                    )
                }
                if let previous = authorization.previousPairIdentities {
                    let currentPly = try namedFileIdentity(
                        parent: output.descriptor,
                        name: Names.canonicalPly,
                        exactMode: 0o600
                    )
                    let currentReceipt = try namedFileIdentity(
                        parent: output.descriptor,
                        name: Names.canonicalReceipt,
                        exactMode: 0o600
                    )
                    guard currentPly.sameUnchangedFile(as: previous.ply.identity),
                          currentReceipt.sameUnchangedFile(
                            as: previous.receipt.identity
                          ) else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication build authority belongs to another result"
                        )
                    }
                } else {
                    guard entryPresence(
                        parent: output.descriptor,
                        name: Names.canonicalPly
                    ) == .missing,
                    entryPresence(
                        parent: output.descriptor,
                        name: Names.canonicalReceipt
                    ) == .missing else {
                        throw PublishedResultPairError.publicationConflict(
                            "publication build authority belongs to another result"
                        )
                    }
                }
                try quarantineAndRemoveOwnedEntry(
                    parent: output.descriptor,
                    name: authorityName,
                    expected: authorityIdentity,
                    operations: operations,
                    operation: "retire unused publication build authority"
                )
                return nil
            }
        }
        if let buildLeaf = inactiveBuilds.first {
            if buildLeaf.hasPrefix(".cleanup-"),
               try removeEmptyTransactionDirectory(
                output: output,
                leaf: buildLeaf,
                operations: operations
               ) {
                return nil
            }
            throw PublishedResultPairError.publicationConflict(
                "inactive publication transaction has no durable authority: \(buildLeaf)"
            )
        }
        guard let leaf = active.first else { return nil }
        let transaction = try TransactionDirectory.openRecovered(
            output: output,
            leaf: leaf
        )
        let canonicalPly = try requirePresence(
            parent: output.descriptor,
            name: Names.canonicalPly
        )
        let canonicalReceipt = try requirePresence(
            parent: output.descriptor,
            name: Names.canonicalReceipt
        )
        let newPly = try requirePresence(
            parent: transaction.descriptor,
            name: Names.newPly
        )
        let newReceipt = try requirePresence(
            parent: transaction.descriptor,
            name: Names.newReceipt
        )
        let oldPly = try requirePresence(
            parent: transaction.descriptor,
            name: Names.oldPly
        )
        let oldReceipt = try requirePresence(
            parent: transaction.descriptor,
            name: Names.oldReceipt
        )

        if transaction.previousPublicationID == nil {
            guard !oldPly, !oldReceipt else {
                throw PublishedResultPairError.publicationConflict(
                    "a first publication contains unexpected previous files"
                )
            }
            if !canonicalPly, !canonicalReceipt {
                try transaction.retire(output: output, operations: operations)
                return .missing
            }

            if canonicalPly, canonicalReceipt,
               try canonicalPairMatchesJournaledNew(
                output: output,
                transaction: transaction
               ) {
                let canonical = try resolveCanonicalPair(
                    output: output,
                    operations: operations
                )
                if case .available(let pair) = canonical,
                   pair.result.receipt.publicationID == transaction.publicationID {
                    try transaction.retire(output: output, operations: operations)
                    return .available(pair)
                }
            }

            var additionalOwned: [String: FileIdentity] = [:]
            if canonicalReceipt {
                guard !newReceipt,
                      let expected = transaction.historicalIdentity(
                          named: Names.newReceipt
                      ) else {
                    throw PublishedResultPairError.publicationConflict(
                        "the committed receipt cannot be attributed to the transaction"
                    )
                }
                additionalOwned[Names.newReceipt] = try moveOwnedInode(
                    from: output.descriptor,
                    name: Names.canonicalReceipt,
                    expected: expected,
                    to: transaction.descriptor,
                    destinationName: Names.newReceipt,
                    operations: operations,
                    operation: "quarantine incomplete first receipt"
                )
            }
            if canonicalPly {
                guard !newPly else {
                    throw PublishedResultPairError.publicationConflict(
                        "both canonical and staged PLY files exist"
                    )
                }
                guard let expected = transaction.historicalIdentity(
                    named: Names.newPly
                ) else {
                    throw PublishedResultPairError.publicationConflict(
                        "the canonical PLY has no durable transaction identity"
                    )
                }
                additionalOwned[Names.newPly] = try moveOwnedInode(
                    from: output.descriptor,
                    name: Names.canonicalPly,
                    expected: expected,
                    to: transaction.descriptor,
                    destinationName: Names.newPly,
                    operations: operations,
                    operation: "quarantine incomplete first PLY"
                )
            }
            try synchronizeDirectories(
                [output.descriptor, transaction.descriptor],
                operations: operations,
                operation: "reconcile first publication"
            )
            try transaction.retire(
                output: output,
                operations: operations,
                additionalOwnedFiles: additionalOwned
            )
            return .missing
        }

        guard let previousPublicationID = transaction.previousPublicationID else {
            throw PublishedResultPairError.publicationConflict(
                "previous publication identity is missing"
            )
        }
        guard let previousPairIdentities = transaction.previousPairIdentities else {
            throw PublishedResultPairError.publicationConflict(
                "previous publication file identities are missing"
            )
        }
        let intendedPreviousPly = previousPairIdentities.ply.identity
        let intendedPreviousReceipt = previousPairIdentities.receipt.identity
        if !oldPly, !oldReceipt {
            guard canonicalPly, canonicalReceipt else {
                throw PublishedResultPairError.publicationConflict(
                    "the previous pair disappeared before preservation"
                )
            }
            let currentPly = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            let currentReceipt = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            guard currentPly.sameUnchangedFile(as: intendedPreviousPly),
                  currentReceipt.sameUnchangedFile(as: intendedPreviousReceipt) else {
                throw PublishedResultPairError.publicationConflict(
                    "the untouched previous pair changed identity"
                )
            }
            let canonical = try requireAvailablePair(
                try resolveCanonicalPair(output: output, operations: operations),
                publicationID: previousPublicationID,
                detail: "the untouched previous pair is invalid"
            )
            try transaction.retire(output: output, operations: operations)
            return .available(canonical)
        }

        if oldPly, !oldReceipt {
            guard !canonicalPly, canonicalReceipt else {
                throw PublishedResultPairError.publicationConflict(
                    "the partially preserved previous pair is inconsistent"
                )
            }
            let heldPly = try namedFileIdentity(
                parent: transaction.descriptor,
                name: Names.oldPly,
                exactMode: 0o600
            )
            let untouchedReceipt = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalReceipt,
                exactMode: 0o600
            )
            guard heldPly.sameObject(as: intendedPreviousPly),
                  untouchedReceipt.sameUnchangedFile(
                    as: intendedPreviousReceipt
                  ) else {
                throw PublishedResultPairError.publicationConflict(
                    "the partially preserved previous pair changed identity"
                )
            }
            try moveExpected(
                from: transaction.descriptor,
                name: Names.oldPly,
                expected: intendedPreviousPly,
                to: output.descriptor,
                destinationName: Names.canonicalPly,
                operations: operations,
                operation: "restore partially preserved previous PLY"
            )
            try synchronizeDirectories(
                [transaction.descriptor, output.descriptor],
                operations: operations,
                operation: "restore partially preserved previous PLY"
            )
            let rebound = try requireCanonicalPair(
                output: output,
                operations: operations,
                publicationID: previousPublicationID,
                detail: "the restored previous pair did not revalidate"
            )
            try transaction.retire(output: output, operations: operations)
            return .available(rebound)
        }

        if !oldPly, oldReceipt {
            guard canonicalPly, !canonicalReceipt else {
                throw PublishedResultPairError.publicationConflict(
                    "the partially restored previous pair is inconsistent"
                )
            }
            let restoredPly = try namedFileIdentity(
                parent: output.descriptor,
                name: Names.canonicalPly,
                exactMode: 0o600
            )
            let heldReceipt = try namedFileIdentity(
                parent: transaction.descriptor,
                name: Names.oldReceipt,
                exactMode: 0o600
            )
            guard restoredPly.sameObject(as: intendedPreviousPly),
                  heldReceipt.sameObject(as: intendedPreviousReceipt) else {
                throw PublishedResultPairError.publicationConflict(
                    "the partially restored previous pair changed identity"
                )
            }
            try moveExpected(
                from: transaction.descriptor,
                name: Names.oldReceipt,
                expected: intendedPreviousReceipt,
                to: output.descriptor,
                destinationName: Names.canonicalReceipt,
                operations: operations,
                operation: "finish restoring previous receipt"
            )
            try synchronizeDirectories(
                [transaction.descriptor, output.descriptor],
                operations: operations,
                operation: "finish restoring previous receipt"
            )
            let rebound = try requireCanonicalPair(
                output: output,
                operations: operations,
                publicationID: previousPublicationID,
                detail: "the restored previous pair did not revalidate"
            )
            try transaction.retire(output: output, operations: operations)
            return .available(rebound)
        }

        guard oldPly, oldReceipt else {
            throw PublishedResultPairError.publicationConflict(
                "the previous pair has an impossible preservation state"
            )
        }

        if canonicalPly, canonicalReceipt,
           try canonicalPairMatchesJournaledNew(
            output: output,
            transaction: transaction
           ) {
            let canonical = try resolveCanonicalPair(
                output: output,
                operations: operations
            )
            if case .available(let pair) = canonical,
               pair.result.receipt.publicationID == transaction.publicationID {
                try transaction.retire(output: output, operations: operations)
                return .available(pair)
            }
        }

        let heldPly = try namedFileIdentity(
            parent: transaction.descriptor,
            name: Names.oldPly,
            exactMode: 0o600
        )
        let heldReceipt = try namedFileIdentity(
            parent: transaction.descriptor,
            name: Names.oldReceipt,
            exactMode: 0o600
        )
        guard heldPly.sameObject(as: intendedPreviousPly),
              heldReceipt.sameObject(as: intendedPreviousReceipt) else {
            throw PublishedResultPairError.publicationConflict(
                "the preserved previous pair changed identity"
            )
        }
        var additionalOwned: [String: FileIdentity] = [:]
        if canonicalReceipt {
            guard !newReceipt,
                  let expected = transaction.historicalIdentity(
                      named: Names.newReceipt
                  ) else {
                throw PublishedResultPairError.publicationConflict(
                    "the canonical receipt is not transaction-owned"
                )
            }
            additionalOwned[Names.newReceipt] = try moveOwnedInode(
                from: output.descriptor,
                name: Names.canonicalReceipt,
                expected: expected,
                to: transaction.descriptor,
                destinationName: Names.newReceipt,
                operations: operations,
                operation: "quarantine failed new receipt"
            )
        }
        if canonicalPly {
            guard !newPly else {
                throw PublishedResultPairError.publicationConflict(
                    "both canonical and staged PLY files exist"
                )
            }
            guard let expected = transaction.historicalIdentity(
                named: Names.newPly
            ) else {
                throw PublishedResultPairError.publicationConflict(
                    "the canonical PLY has no durable transaction identity"
                )
            }
            additionalOwned[Names.newPly] = try moveOwnedInode(
                from: output.descriptor,
                name: Names.canonicalPly,
                expected: expected,
                to: transaction.descriptor,
                destinationName: Names.newPly,
                operations: operations,
                operation: "quarantine failed new PLY"
            )
        }
        try moveExpected(
            from: transaction.descriptor,
            name: Names.oldPly,
            expected: intendedPreviousPly,
            to: output.descriptor,
            destinationName: Names.canonicalPly,
            operations: operations,
            operation: "restore previous PLY"
        )
        try moveExpected(
            from: transaction.descriptor,
            name: Names.oldReceipt,
            expected: intendedPreviousReceipt,
            to: output.descriptor,
            destinationName: Names.canonicalReceipt,
            operations: operations,
            operation: "restore previous receipt"
        )
        try synchronizeDirectories(
            [transaction.descriptor, output.descriptor],
            operations: operations,
            operation: "restore previous published result"
        )
        let rebound = try requireCanonicalPair(
            output: output,
            operations: operations,
            publicationID: previousPublicationID,
            detail: "the restored previous pair did not revalidate"
        )
        try transaction.retire(
            output: output,
            operations: operations,
            additionalOwnedFiles: additionalOwned
        )
        return .available(rebound)
    }

    static func requirePresence(parent: Int32, name: String) throws -> Bool {
        switch entryPresence(parent: parent, name: name) {
        case .missing: false
        case .present: true
        case .unsafe:
            throw PublishedResultPairError.publicationConflict(
                "could not inspect \(name)"
            )
        }
    }

    static func requireAvailablePair(
        _ resolution: PairResolution,
        publicationID: UUID,
        detail: String
    ) throws -> BoundPair {
        guard case .available(let pair) = resolution,
              pair.result.receipt.publicationID == publicationID else {
            throw PublishedResultPairError.publicationConflict(detail)
        }
        return pair
    }

    static func canonicalPairMatchesJournaledNew(
        output: BoundOutput,
        transaction: TransactionDirectory
    ) throws -> Bool {
        guard let journal = transaction.lastJournal,
              journal.phase.rawValue
                >= PublishedResultPairJournalPhase.receiptCommitted.rawValue,
              let expectedPly = journal.canonicalPlyIdentity?.identity,
              let expectedReceipt = journal.canonicalReceiptIdentity?.identity else {
            return false
        }
        let currentPly = try namedFileIdentity(
            parent: output.descriptor,
            name: Names.canonicalPly,
            exactMode: 0o600
        )
        let currentReceipt = try namedFileIdentity(
            parent: output.descriptor,
            name: Names.canonicalReceipt,
            exactMode: 0o600
        )
        return currentPly.sameUnchangedFile(as: expectedPly)
            && currentReceipt.sameUnchangedFile(as: expectedReceipt)
    }

    static func requireCanonicalPair(
        output: BoundOutput,
        operations: PublishedResultPairOperations,
        publicationID: UUID,
        detail: String
    ) throws -> BoundPair {
        try requireAvailablePair(
            resolveCanonicalPair(
                output: output,
                operations: operations
            ),
            publicationID: publicationID,
            detail: detail
        )
    }

    static func projectRelativeSourcePath(
        _ sourceURL: URL,
        projectPaths: ProjectPaths
    ) throws -> String {
        guard sourceURL.isFileURL, projectPaths.root.isFileURL else {
            throw PublishedResultPairError.invalidSource
        }
        let rootPath = projectPaths.root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let sourcePath = sourceURL.path
        guard sourcePath.hasPrefix(prefix) else {
            throw PublishedResultPairError.invalidSource
        }
        let relativePath = String(sourcePath.dropFirst(prefix.count))
        _ = try projectRelativeSourceComponents(relativePath)
        return relativePath
    }

    static func projectRelativeSourceComponents(
        _ relativePath: String
    ) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            throw PublishedResultPairError.invalidSource
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
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
            throw PublishedResultPairError.invalidSource
        }
        return components
    }

    enum EntryPresence: Equatable {
        case missing
        case present
        case unsafe
    }

    static func entryPresence(parent: Int32, name: String) -> EntryPresence {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return .present }
        return errno == ENOENT ? .missing : .unsafe
    }

    static func openReadOnly(parent: Int32, name: String) -> Int32 {
        name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
    }

    struct ProjectRootDescriptorBinding {
        let descriptor: Int32
        let identity: DirectoryIdentity
    }

    static func acquireProjectRootDescriptor(
        projectPaths: ProjectPaths,
        suppliedDescriptor: Int32?,
        operations: PublishedResultPairOperations
    ) throws -> ProjectRootDescriptorBinding {
        try operations.willOpenProjectRoot()
        let descriptor: Int32
        if let suppliedDescriptor {
            descriptor = Darwin.fcntl(
                suppliedDescriptor,
                F_DUPFD_CLOEXEC,
                0
            )
        } else {
            descriptor = Darwin.open(
                projectPaths.root.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PublishedResultPairError.unsafeOutput
        }
        var transferred = false
        defer {
            if !transferred { Darwin.close(descriptor) }
        }
        let identity = try requireBoundAbsoluteDirectory(
            descriptor: descriptor,
            path: projectPaths.root.path
        )
        transferred = true
        return ProjectRootDescriptorBinding(
            descriptor: descriptor,
            identity: identity
        )
    }

    static func openLock(
        output: Int32,
        operations: PublishedResultPairOperations
    ) throws -> (descriptor: Int32, identity: FileIdentity) {
        var created = false
        var descriptor = Names.lock.withCString {
            Darwin.openat(
                output,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = Names.lock.withCString {
                Darwin.openat(
                    output,
                    $0,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else { throw PublishedResultPairError.unsafeOutput }
        do {
            if created {
                guard Darwin.fchmod(descriptor, 0o600) == 0 else {
                    throw PublishedResultPairError.persistence(
                        operation: "secure publication lock",
                        code: errno
                    )
                }
                try syncFile(
                    descriptor,
                    operations: operations,
                    operation: "create publication lock"
                )
                try syncDirectory(
                    output,
                    operations: operations,
                    operation: "create publication lock"
                )
            }
            let identity = try requireBoundFile(
                descriptor: descriptor,
                parent: output,
                name: Names.lock,
                exactMode: 0o600
            )
            return (descriptor, identity)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func requireBoundAbsoluteDirectory(
        descriptor: Int32,
        path: String
    ) throws -> DirectoryIdentity {
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              Darwin.lstat(path, &named) == 0,
              safeDirectory(opened, exactMode: nil),
              DirectoryIdentity(opened) == DirectoryIdentity(named) else {
            throw PublishedResultPairError.unsafeOutput
        }
        return DirectoryIdentity(opened)
    }

    static func requireBoundChildDirectory(
        descriptor: Int32,
        parent: Int32,
        name: String,
        exactMode: mode_t?
    ) throws -> DirectoryIdentity {
        var opened = stat()
        var named = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &opened) == 0,
              result == 0,
              safeDirectory(opened, exactMode: exactMode),
              DirectoryIdentity(opened) == DirectoryIdentity(named) else {
            throw PublishedResultPairError.unsafeOutput
        }
        return DirectoryIdentity(opened)
    }

    static func optionalChildDirectoryIdentity(
        parent: Int32,
        name: String,
        exactMode: mode_t?
    ) throws -> DirectoryIdentity? {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw PublishedResultPairError.publicationConflict(
                "could not inspect \(name)"
            )
        }
        defer { Darwin.close(descriptor) }
        return try requireBoundChildDirectory(
            descriptor: descriptor,
            parent: parent,
            name: name,
            exactMode: exactMode
        )
    }

    static func requireBoundFile(
        descriptor: Int32,
        parent: Int32,
        name: String,
        exactMode: mode_t?
    ) throws -> FileIdentity {
        var opened = stat()
        var named = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &opened) == 0,
              result == 0,
              safeRegular(opened, exactMode: exactMode),
              FileIdentity(opened) == FileIdentity(named) else {
            throw PublishedResultPairError.unsafeOutput
        }
        return FileIdentity(opened)
    }

    static func namedFileIdentity(
        parent: Int32,
        name: String,
        exactMode: mode_t?
    ) throws -> FileIdentity {
        let descriptor = openReadOnly(parent: parent, name: name)
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "could not open \(name)"
            )
        }
        defer { Darwin.close(descriptor) }
        return try requireBoundFile(
            descriptor: descriptor,
            parent: parent,
            name: name,
            exactMode: exactMode
        )
    }

    static func safeDirectory(_ status: stat, exactMode: mode_t?) -> Bool {
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              (status.st_mode & 0o022) == 0 else { return false }
        return exactMode.map { status.st_mode & 0o7777 == $0 } ?? true
    }

    static func safeRegular(_ status: stat, exactMode: mode_t?) -> Bool {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              (status.st_mode & 0o022) == 0 else { return false }
        return exactMode.map { status.st_mode & 0o7777 == $0 } ?? true
    }

    static func readBoundFile(
        descriptor: Int32,
        identity: FileIdentity,
        maximumBytes: Int
    ) throws -> Data {
        guard identity.byteCount > 0,
              identity.byteCount <= Int64(maximumBytes) else {
            throw PublishedResultPairError.unsafeOutput
        }
        var data = Data(count: Int(identity.byteCount))
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
                guard count > 0 else { throw PublishedResultPairError.unsafeOutput }
                offset += count
            }
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
              FileIdentity(final) == identity else {
            throw PublishedResultPairError.unsafeOutput
        }
        return data
    }

    static func readPrivateFile(
        parent: Int32,
        name: String,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = openReadOnly(parent: parent, name: name)
        guard descriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(
                "unsafe transaction file \(name)"
            )
        }
        defer { Darwin.close(descriptor) }
        let identity = try requireBoundFile(
            descriptor: descriptor,
            parent: parent,
            name: name,
            exactMode: 0o600
        )
        return try readBoundFile(
            descriptor: descriptor,
            identity: identity,
            maximumBytes: maximumBytes
        )
    }

    static func writeOutputPrivateFile(
        parent: Int32,
        pendingName: String,
        finalName: String,
        data: Data,
        operations: PublishedResultPairOperations,
        operation: String
    ) throws -> FileIdentity {
        let descriptor = pendingName.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw PublishedResultPairError.persistence(operation: operation, code: errno)
        }
        var createdIdentity: FileIdentity?
        var ownedIdentity: FileIdentity?
        defer { Darwin.close(descriptor) }
        do {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: operation,
                    code: errno
                )
            }
            createdIdentity = try requireBoundFile(
                descriptor: descriptor,
                parent: parent,
                name: pendingName,
                exactMode: 0o600
            )
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = operations.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0, written <= bytes.count - offset else {
                        throw PublishedResultPairError.persistence(
                            operation: operation,
                            code: written < 0 ? errno : EIO
                        )
                    }
                    offset += written
                }
            }
            try syncFile(descriptor, operations: operations, operation: operation)
            let pendingIdentity = try requireBoundFile(
                descriptor: descriptor,
                parent: parent,
                name: pendingName,
                exactMode: 0o600
            )
            ownedIdentity = pendingIdentity
            guard operations.renameExclusive(
                parent,
                pendingName,
                parent,
                finalName
            ) == 0 else {
                throw PublishedResultPairError.persistence(
                    operation: operation,
                    code: errno
                )
            }
            try syncDirectory(parent, operations: operations, operation: operation)
            let finalIdentity = try namedFileIdentity(
                parent: parent,
                name: finalName,
                exactMode: 0o600
            )
            guard finalIdentity.sameObject(as: pendingIdentity) else {
                throw PublishedResultPairError.publicationConflict(operation)
            }
            return finalIdentity
        } catch {
            var cleanupIdentity = ownedIdentity
            if cleanupIdentity == nil,
               let createdIdentity,
               let currentIdentity = try? requireBoundFile(
                   descriptor: descriptor,
                   parent: parent,
                   name: pendingName,
                   exactMode: 0o600
               ),
               currentIdentity.sameInode(as: createdIdentity) {
                cleanupIdentity = currentIdentity
            }
            if let cleanupIdentity {
                for name in [pendingName, finalName] {
                    try? quarantineAndRemoveOwnedEntry(
                        parent: parent,
                        name: name,
                        expected: cleanupIdentity,
                        operations: operations,
                        operation: operation
                    )
                }
            }
            throw error
        }
    }

    static func encodeBuildAuthorization(
        _ document: BuildAuthorizationDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func decodeBuildAuthorization(
        _ data: Data
    ) throws -> BuildAuthorizationDocument {
        do {
            try StrictJSONDocument.validate(data, maximumBytes: 65_536)
            let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] ?? [:]
            let required = Set([
                "schemaVersion", "transactionID", "publicationID",
                "directoryIdentity",
            ])
            let optional = Set([
                "previousPublicationID", "previousPairIdentities",
            ])
            let directoryKeys = Set(["device", "inode", "owner", "mode"])
            let identityKeys = Set([
                "device", "inode", "byteCount", "owner", "mode", "linkCount",
                "modifiedSeconds", "modifiedNanoseconds", "changedSeconds",
                "changedNanoseconds",
            ])
            guard required.isSubset(of: object.keys),
                  Set(object.keys).isSubset(of: required.union(optional)),
                  let directory = object["directoryIdentity"] as? [String: Any],
                  Set(directory.keys) == directoryKeys else {
                throw PublishedResultPairError.publicationConflict(
                    "publication build authority has an unexpected shape"
                )
            }
            if let previous = object["previousPairIdentities"] {
                guard let pair = previous as? [String: Any],
                      Set(pair.keys) == Set(["ply", "receipt"]),
                      let ply = pair["ply"] as? [String: Any],
                      Set(ply.keys) == identityKeys,
                      let receipt = pair["receipt"] as? [String: Any],
                      Set(receipt.keys) == identityKeys else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication build authority has unsafe pair identity"
                    )
                }
            }
            return try JSONDecoder().decode(
                BuildAuthorizationDocument.self,
                from: data
            )
        } catch let error as PublishedResultPairError {
            throw error
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "publication build authority is invalid"
            )
        }
    }

    static func encodeReceiptBuildAuthorization(
        _ document: ReceiptBuildAuthorizationDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func decodeReceiptBuildAuthorization(
        _ data: Data
    ) throws -> ReceiptBuildAuthorizationDocument {
        do {
            try StrictJSONDocument.validate(data, maximumBytes: 65_536)
            let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] ?? [:]
            let required = Set([
                "schemaVersion", "transactionID", "publicationID",
                "directoryIdentity", "plyIdentity", "oldReceiptIdentity",
                "oldReceiptSHA256", "newReceiptSHA256", "ownedFiles",
            ])
            let directoryKeys = Set(["device", "inode", "owner", "mode"])
            let identityKeys = Set([
                "device", "inode", "byteCount", "owner", "mode", "linkCount",
                "modifiedSeconds", "modifiedNanoseconds", "changedSeconds",
                "changedNanoseconds",
            ])
            guard Set(object.keys) == required,
                  let directory = object["directoryIdentity"] as? [String: Any],
                  Set(directory.keys) == directoryKeys,
                  let ply = object["plyIdentity"] as? [String: Any],
                  Set(ply.keys) == identityKeys,
                  let receipt = object["oldReceiptIdentity"] as? [String: Any],
                  Set(receipt.keys) == identityKeys,
                  let ownedFiles = object["ownedFiles"] as? [String: Any] else {
                throw PublishedResultPairError.publicationConflict(
                    "viewer timing build authority has an unexpected shape"
                )
            }
            for value in ownedFiles.values {
                guard let identity = value as? [String: Any],
                      Set(identity.keys) == identityKeys else {
                    throw PublishedResultPairError.publicationConflict(
                        "viewer timing build authority has unsafe ownership"
                    )
                }
            }
            return try JSONDecoder().decode(
                ReceiptBuildAuthorizationDocument.self,
                from: data
            )
        } catch let error as PublishedResultPairError {
            throw error
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "viewer timing build authority is invalid"
            )
        }
    }

    static func decodeCleanupJournal(
        _ data: Data
    ) throws -> CleanupJournalDocument {
        do {
            try StrictJSONDocument.validate(data, maximumBytes: 65_536)
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "malformed publication cleanup journal"
            )
        }
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                ?? [:]
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "malformed publication cleanup journal"
            )
        }
        let required = Set([
            "schemaVersion", "transactionID", "publicationID",
            "directoryIdentity", "ownedFiles",
        ])
        let optional = Set(["previousPublicationID"])
        let directoryIdentityKeys = Set(["device", "inode", "owner", "mode"])
        let fileIdentityKeys = Set([
            "device", "inode", "byteCount", "owner", "mode", "linkCount",
            "modifiedSeconds", "modifiedNanoseconds", "changedSeconds",
            "changedNanoseconds",
        ])
        guard required.isSubset(of: object.keys),
              Set(object.keys).isSubset(of: required.union(optional)),
              let directoryIdentity = object["directoryIdentity"]
                as? [String: Any],
              Set(directoryIdentity.keys) == directoryIdentityKeys,
              let ownedFiles = object["ownedFiles"] as? [String: Any] else {
            throw PublishedResultPairError.publicationConflict(
                "publication cleanup journal has an unexpected shape"
            )
        }
        for value in ownedFiles.values {
            guard let identity = value as? [String: Any],
                  Set(identity.keys) == fileIdentityKeys else {
                throw PublishedResultPairError.publicationConflict(
                    "publication cleanup journal has an unexpected file identity"
                )
            }
        }
        do {
            return try JSONDecoder().decode(CleanupJournalDocument.self, from: data)
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "malformed publication cleanup journal"
            )
        }
    }

    static func decodeJournal(_ data: Data) throws -> JournalDocument {
        do {
            try StrictJSONDocument.validate(data, maximumBytes: 65_536)
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "malformed publication journal"
            )
        }
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                ?? [:]
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "malformed publication journal"
            )
        }
        let required = Set([
            "schemaVersion", "transactionID", "publicationID", "phase", "ownedFiles",
        ])
        let optional = Set([
            "previousPublicationID", "previousPairIdentities",
            "canonicalPlyIdentity", "canonicalReceiptIdentity",
        ])
        let keys = Set(object.keys)
        guard required.isSubset(of: keys),
              keys.isSubset(of: required.union(optional)),
              let owned = object["ownedFiles"] as? [String: Any] else {
            throw PublishedResultPairError.publicationConflict(
                "publication journal has an unexpected shape"
            )
        }
        let identityKeys = Set([
            "device", "inode", "byteCount", "owner", "mode", "linkCount",
            "modifiedSeconds", "modifiedNanoseconds", "changedSeconds",
            "changedNanoseconds",
        ])
        for value in owned.values {
            guard let identity = value as? [String: Any],
                  Set(identity.keys) == identityKeys else {
                throw PublishedResultPairError.publicationConflict(
                    "publication journal has an unexpected file identity"
                )
            }
        }
        if let value = object["previousPairIdentities"] {
            guard let previous = value as? [String: Any],
                  Set(previous.keys) == Set(["ply", "receipt"]),
                  let ply = previous["ply"] as? [String: Any],
                  Set(ply.keys) == identityKeys,
                  let receipt = previous["receipt"] as? [String: Any],
                  Set(receipt.keys) == identityKeys else {
                throw PublishedResultPairError.publicationConflict(
                    "publication journal has an unexpected previous-pair identity"
                )
            }
        }
        for key in ["canonicalPlyIdentity", "canonicalReceiptIdentity"] {
            if let value = object[key] {
                guard let identity = value as? [String: Any],
                      Set(identity.keys) == identityKeys else {
                    throw PublishedResultPairError.publicationConflict(
                        "publication journal has an unexpected canonical identity"
                    )
                }
            }
        }
        do {
            return try JSONDecoder().decode(JournalDocument.self, from: data)
        } catch {
            throw PublishedResultPairError.publicationConflict(
                "malformed publication journal"
            )
        }
    }

    static func encodeJournal(_ document: JournalDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func journalTrajectory(
        hasPrevious: Bool
    ) -> [PublishedResultPairJournalPhase] {
        if hasPrevious { return PublishedResultPairJournalPhase.allCases }
        return [
            .created,
            .newPlyDurable,
            .newReceiptDurable,
            .prepared,
            .newPlyInstalled,
            .receiptCommitted,
            .validated,
        ]
    }

    static func logicalTransactionOwnedName(_ name: String) -> String {
        if name == Names.cleanupAuthorizationPending {
            return Names.cleanupAuthorization
        }
        for phase in PublishedResultPairJournalPhase.allCases
        where name == phase.pendingLeaf {
            return phase.leaf
        }
        return name
    }

    static func cleanupQuarantineName(_ name: String) -> String {
        ".cleanup-" + name
    }

    static func normalizedNamespaceName(
        _ name: String,
        output: BoundOutput
    ) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard !output.caseSensitiveNames else { return normalized }
        return normalized.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).precomposedStringWithCanonicalMapping
    }

    static func hasReservedNamespacePrefix(
        _ name: String,
        prefix: String,
        output: BoundOutput
    ) -> Bool {
        var comparedName = normalizedNamespaceName(name, output: output)
        let comparedPrefix = normalizedNamespaceName(prefix, output: output)
        let cleanupPrefix = normalizedNamespaceName(
            ".cleanup-",
            output: output
        )
        while comparedName.hasPrefix(cleanupPrefix) {
            comparedName.removeFirst(cleanupPrefix.count)
        }
        return comparedName.hasPrefix(comparedPrefix)
    }

    static func hasAnyReservedPublicationNamespace(
        _ name: String,
        output: BoundOutput
    ) -> Bool {
        [
            Names.transactionPrefix,
            Names.transactionBuildPrefix,
            Names.transactionBuildAuthorityPrefix,
            Names.retiredPrefix,
            Names.receiptTransactionPrefix,
            Names.receiptTransactionBuildPrefix,
            Names.receiptTransactionBuildAuthorityPrefix,
            Names.receiptRetiredPrefix,
            Names.receiptCleanupPrefix,
        ].contains {
            hasReservedNamespacePrefix(name, prefix: $0, output: output)
        }
    }

    static func isCanonicalTransactionDirectoryName(_ name: String) -> Bool {
        for prefix in [
            Names.transactionPrefix,
            Names.transactionBuildPrefix,
            Names.retiredPrefix,
            Names.receiptTransactionPrefix,
            Names.receiptTransactionBuildPrefix,
            Names.receiptRetiredPrefix,
        ] where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            guard let identifier = UUID(uuidString: suffix) else { return false }
            return prefix + identifier.uuidString.lowercased() == name
        }
        return false
    }

    static func logicalCleanupOwnedName(_ name: String) -> String {
        logicalTransactionOwnedName(cleanupOriginalEntryName(name))
    }

    static func cleanupOriginalEntryName(_ name: String) -> String {
        let prefix = ".cleanup-"
        var original = name
        while original.hasPrefix(prefix) {
            original.removeFirst(prefix.count)
        }
        return original
    }

    static func logicalReceiptOwnedName(_ name: String) -> String {
        let original = cleanupOriginalEntryName(name)
        if original == Names.receiptCreatedJournal + ".pending" {
            return Names.receiptCreatedJournal
        }
        if original == Names.receiptPreparedJournal + ".pending" {
            return Names.receiptPreparedJournal
        }
        if original == Names.cleanupAuthorization + ".pending" {
            return Names.cleanupAuthorization
        }
        return original
    }

    static func moveExpected(
        from sourceDirectory: Int32,
        name: String,
        expected: FileIdentity,
        to destinationDirectory: Int32,
        destinationName: String,
        operations: PublishedResultPairOperations,
        operation: String,
        didRename: () -> Void = {}
    ) throws {
        var source = stat()
        let sourceResult = name.withCString {
            Darwin.fstatat(sourceDirectory, $0, &source, AT_SYMLINK_NOFOLLOW)
        }
        var destination = stat()
        let destinationResult = destinationName.withCString {
            Darwin.fstatat(destinationDirectory, $0, &destination, AT_SYMLINK_NOFOLLOW)
        }
        let destinationError = destinationResult == 0 ? 0 : errno
        guard sourceResult == 0,
              FileIdentity(source).sameObject(as: expected),
              destinationResult != 0,
              destinationError == ENOENT else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        guard operations.renameExclusive(
            sourceDirectory,
            name,
            destinationDirectory,
            destinationName
        ) == 0 else {
            let code = errno
            if code == EEXIST || code == ENOENT {
                throw PublishedResultPairError.publicationConflict(operation)
            }
            throw PublishedResultPairError.persistence(operation: operation, code: code)
        }
        didRename()
        var moved = stat()
        let movedResult = destinationName.withCString {
            Darwin.fstatat(destinationDirectory, $0, &moved, AT_SYMLINK_NOFOLLOW)
        }
        guard movedResult == 0,
              FileIdentity(moved).sameObject(as: expected) else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
    }

    /// Moves only the inode recorded by an earlier durable phase. Content may
    /// have been corrupted since that phase; inode ownership is sufficient to
    /// quarantine it, but never to grant result authority.
    static func moveOwnedInode(
        from sourceDirectory: Int32,
        name: String,
        expected: FileIdentity,
        to destinationDirectory: Int32,
        destinationName: String,
        operations: PublishedResultPairOperations,
        operation: String
    ) throws -> FileIdentity {
        let current = try namedFileIdentity(
            parent: sourceDirectory,
            name: name,
            exactMode: 0o600
        )
        var destination = stat()
        let destinationResult = destinationName.withCString {
            Darwin.fstatat(destinationDirectory, $0, &destination, AT_SYMLINK_NOFOLLOW)
        }
        let destinationError = destinationResult == 0 ? 0 : errno
        guard current.sameInode(as: expected),
              destinationResult != 0,
              destinationError == ENOENT else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        guard operations.renameExclusive(
            sourceDirectory,
            name,
            destinationDirectory,
            destinationName
        ) == 0 else {
            let code = errno
            if code == EEXIST || code == ENOENT {
                throw PublishedResultPairError.publicationConflict(operation)
            }
            throw PublishedResultPairError.persistence(operation: operation, code: code)
        }
        let moved = try namedFileIdentity(
            parent: destinationDirectory,
            name: destinationName,
            exactMode: 0o600
        )
        guard moved.sameInode(as: current) else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        return moved
    }

    static func quarantineAndRemoveOwnedEntry(
        parent: Int32,
        name: String,
        expected: FileIdentity,
        operations: PublishedResultPairOperations,
        operation: String
    ) throws {
        let originalName = cleanupOriginalEntryName(name)
        let quarantine = cleanupQuarantineName(originalName)
        let sourcePresence = entryPresence(parent: parent, name: originalName)
        let quarantinePresence = entryPresence(parent: parent, name: quarantine)
        guard sourcePresence != .unsafe, quarantinePresence != .unsafe,
              !(sourcePresence == .present && quarantinePresence == .present) else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        if sourcePresence == .present {
            try operations.willQuarantineOwnedEntry(originalName)
            _ = try moveOwnedInode(
                from: parent,
                name: originalName,
                expected: expected,
                to: parent,
                destinationName: quarantine,
                operations: operations,
                operation: operation
            )
            try syncDirectory(parent, operations: operations, operation: operation)
        } else if quarantinePresence == .missing {
            return
        }

        try operations.willUnlinkQuarantinedEntry(originalName)
        let quarantined = try namedFileIdentity(
            parent: parent,
            name: quarantine,
            exactMode: 0o600
        )
        guard quarantined.sameInode(as: expected) else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        operations.didValidateOwnedEntryForRemoval(parent, quarantine, false)
        let removalIdentity = try namedFileIdentity(
            parent: parent,
            name: quarantine,
            exactMode: 0o600
        )
        guard removalIdentity.sameUnchangedFile(as: quarantined),
              removalIdentity.sameInode(as: expected),
              quarantine.withCString({ Darwin.unlinkat(parent, $0, 0) }) == 0 else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        try syncDirectory(parent, operations: operations, operation: operation)
    }

    static func quarantineAndRemoveOwnedDirectory(
        parent: Int32,
        name: String,
        expected: DirectoryIdentity,
        operations: PublishedResultPairOperations,
        operation: String,
        didRemoveCheckpoint: PublishedResultPairCheckpoint? = nil
    ) throws {
        let originalName = cleanupOriginalEntryName(name)
        let quarantine = cleanupQuarantineName(originalName)
        let sourcePresence = entryPresence(parent: parent, name: originalName)
        let quarantinePresence = entryPresence(parent: parent, name: quarantine)
        guard sourcePresence != .unsafe,
              quarantinePresence != .unsafe,
              !(sourcePresence == .present && quarantinePresence == .present) else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        if sourcePresence == .present {
            let sourceDescriptor = originalName.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard sourceDescriptor >= 0 else {
                throw PublishedResultPairError.publicationConflict(operation)
            }
            defer { Darwin.close(sourceDescriptor) }
            guard try requireBoundChildDirectory(
                descriptor: sourceDescriptor,
                parent: parent,
                name: originalName,
                exactMode: 0o700
            ) == expected,
            try directoryNames(
                descriptor: sourceDescriptor,
                maximumCount: 1
            ).isEmpty else {
                throw PublishedResultPairError.publicationConflict(operation)
            }
            try operations.willQuarantineOwnedEntry(originalName)
            guard operations.renameExclusive(
                parent,
                originalName,
                parent,
                quarantine
            ) == 0 else {
                let code = errno
                if code == EEXIST || code == ENOENT {
                    throw PublishedResultPairError.publicationConflict(operation)
                }
                throw PublishedResultPairError.persistence(
                    operation: operation,
                    code: code
                )
            }
            guard try requireBoundChildDirectory(
                descriptor: sourceDescriptor,
                parent: parent,
                name: quarantine,
                exactMode: 0o700
            ) == expected else {
                throw PublishedResultPairError.publicationConflict(operation)
            }
            try syncDirectory(parent, operations: operations, operation: operation)
        } else if quarantinePresence == .missing {
            return
        }

        try operations.willUnlinkQuarantinedEntry(originalName)
        let validatedDescriptor = quarantine.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard validatedDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        let validatedIdentity: DirectoryIdentity
        do {
            validatedIdentity = try requireBoundChildDirectory(
                descriptor: validatedDescriptor,
                parent: parent,
                name: quarantine,
                exactMode: 0o700
            )
            guard validatedIdentity == expected,
                  try directoryNames(
                    descriptor: validatedDescriptor,
                    maximumCount: 1
                  ).isEmpty else {
                throw PublishedResultPairError.publicationConflict(operation)
            }
        } catch {
            Darwin.close(validatedDescriptor)
            throw error
        }
        Darwin.close(validatedDescriptor)

        operations.didValidateOwnedEntryForRemoval(parent, quarantine, true)
        let removalDescriptor = quarantine.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard removalDescriptor >= 0 else {
            throw PublishedResultPairError.publicationConflict(operation)
        }
        do {
            guard try requireBoundChildDirectory(
                descriptor: removalDescriptor,
                parent: parent,
                name: quarantine,
                exactMode: 0o700
            ) == validatedIdentity,
            try directoryNames(
                descriptor: removalDescriptor,
                maximumCount: 1
            ).isEmpty else {
                throw PublishedResultPairError.publicationConflict(operation)
            }
        } catch {
            Darwin.close(removalDescriptor)
            throw error
        }
        Darwin.close(removalDescriptor)
        guard quarantine.withCString({
            Darwin.unlinkat(parent, $0, AT_REMOVEDIR)
        }) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTEMPTY || code == EEXIST {
                throw PublishedResultPairError.publicationConflict(operation)
            }
            throw PublishedResultPairError.persistence(
                operation: operation,
                code: code
            )
        }
        if let didRemoveCheckpoint {
            operations.didReachCheckpoint(didRemoveCheckpoint)
        }
        try syncDirectory(parent, operations: operations, operation: operation)
    }

    static func writeAll(
        descriptor: Int32,
        bytes: [UInt8],
        count: Int,
        operations: PublishedResultPairOperations,
        operation: String
    ) throws {
        var offset = 0
        while offset < count {
            let written = bytes.withUnsafeBytes {
                operations.write(
                    descriptor,
                    $0.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0, written <= count - offset else {
                throw PublishedResultPairError.persistence(
                    operation: operation,
                    code: written < 0 ? errno : EIO
                )
            }
            offset += written
        }
    }

    static func syncFile(
        _ descriptor: Int32,
        operations: PublishedResultPairOperations,
        operation: String
    ) throws {
        guard operations.synchronizeFile(descriptor) == 0 else {
            throw PublishedResultPairError.persistence(operation: operation, code: errno)
        }
    }

    static func syncDirectory(
        _ descriptor: Int32,
        operations: PublishedResultPairOperations,
        operation: String
    ) throws {
        guard operations.synchronizeDirectory(descriptor) == 0 else {
            throw PublishedResultPairError.persistence(operation: operation, code: errno)
        }
    }

    static func synchronizeDirectories(
        _ descriptors: [Int32],
        operations: PublishedResultPairOperations,
        operation: String
    ) throws {
        for descriptor in descriptors {
            try syncDirectory(descriptor, operations: operations, operation: operation)
        }
    }

    static func checkCancellation(
        _ shouldCancel: @Sendable () -> Bool
    ) throws {
        if shouldCancel() { throw CancellationError() }
    }

    static func directoryNames(
        descriptor: Int32,
        maximumCount: Int
    ) throws -> [String] {
        // dup(2) shares a directory stream offset with the original open file
        // description. Re-open "." to obtain an independent descriptor so every
        // inventory starts at the beginning and concurrent callers cannot hide
        // entries by advancing one another's stream.
        let enumerationDescriptor = ".".withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        var boundStatus = stat()
        var enumerationStatus = stat()
        guard enumerationDescriptor >= 0,
              Darwin.fstat(descriptor, &boundStatus) == 0,
              Darwin.fstat(enumerationDescriptor, &enumerationStatus) == 0,
              DirectoryIdentity(boundStatus) == DirectoryIdentity(enumerationStatus),
              let directory = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
            throw PublishedResultPairError.unsafeOutput
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else {
                    throw PublishedResultPairError.unsafeOutput
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= maximumCount else {
                throw PublishedResultPairError.publicationConflict(
                    "too many Output entries"
                )
            }
        }
        return names.sorted()
    }

    static func lockOpenFileDescription(
        _ descriptor: Int32,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while true {
            try checkCancellation(shouldCancel)
            let result = withUnsafeMutablePointer(to: &lock) {
                Darwin.fcntl(descriptor, F_OFD_SETLK, $0)
            }
            if result == 0 { return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EACCES {
                Darwin.usleep(10_000)
                continue
            }
            throw PublishedResultPairError.persistence(
                operation: "acquire publication lock",
                code: errno
            )
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
}
