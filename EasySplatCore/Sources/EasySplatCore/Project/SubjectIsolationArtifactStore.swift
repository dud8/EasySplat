import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IsolationArtifactStaleReason: String, Sendable, Equatable {
    case sourceOutput
    case trainingManifest
    case datasetIdentity
}

public enum IsolationArtifactLoadResult: Sendable, Equatable {
    case noArtifact
    case valid(IsolationArtifact, ValidatedSplatOutput)
    case stale(IsolationArtifactStaleReason)
    case invalid
}

public enum SubjectIsolationArtifactStoreError: Error, LocalizedError, Equatable {
    case invalidArtifact
    case publicationConflict
    case canonicalPublicationUnchanged

    public var errorDescription: String? {
        switch self {
        case .invalidArtifact:
            "The subject-isolation artifact is invalid."
        case .publicationConflict:
            "The subject-isolation artifact changed during publication."
        case .canonicalPublicationUnchanged:
            "The canonical splat publication has not changed since subject isolation."
        }
    }
}

public enum SubjectIsolationArtifactStore {
    enum SubjectPairPublicationCheckpoint: String, CaseIterable, Sendable {
        case newPairStaged
        case journalActivated
        case previousOutputMoved
        case previousManifestMoved
        case newOutputInstalled
        case newManifestInstalled
    }

    enum SubjectPairRetirementCheckpoint: String, CaseIterable, Sendable {
        case journalActivated
        case manifestRemoved
        case outputRemoved
        case masksRemoved
    }

    private final class ProcessIsolationLock: @unchecked Sendable {
        let value = NSRecursiveLock()
    }

    private struct ProcessIsolationLockKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private final class WeakProcessIsolationLock {
        weak var value: ProcessIsolationLock?

        init(_ value: ProcessIsolationLock) {
            self.value = value
        }
    }

    private final class ProcessIsolationLockRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ProcessIsolationLockKey: WeakProcessIsolationLock] = [:]

        func value(for key: ProcessIsolationLockKey) -> ProcessIsolationLock {
            lock.lock()
            defer { lock.unlock() }
            if let existing = values[key]?.value {
                return existing
            }
            values = values.filter { $0.value.value != nil }
            let created = ProcessIsolationLock()
            values[key] = WeakProcessIsolationLock(created)
            return created
        }
    }

    private struct SimulatedSubjectPairProcessExit: Error {}

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct OwnedFile {
        let url: URL
        let identity: FileIdentity
    }

    private struct SubjectPairJournalFileIdentity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        let byteCount: Int64
        let owner: UInt32
        let mode: UInt32
        let linkCount: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init(_ status: stat) {
            device = Int64(status.st_dev)
            inode = UInt64(status.st_ino)
            byteCount = Int64(status.st_size)
            owner = UInt32(status.st_uid)
            mode = UInt32(status.st_mode)
            linkCount = UInt64(status.st_nlink)
            birthSeconds = Int64(status.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        }

        func matches(_ status: stat) -> Bool {
            device == Int64(status.st_dev)
                && inode == UInt64(status.st_ino)
                && byteCount == Int64(status.st_size)
                && owner == UInt32(status.st_uid)
                && mode == UInt32(status.st_mode)
                && linkCount == UInt64(status.st_nlink)
                && birthSeconds == Int64(status.st_birthtimespec.tv_sec)
                && birthNanoseconds == Int64(status.st_birthtimespec.tv_nsec)
                && modifiedSeconds == Int64(status.st_mtimespec.tv_sec)
                && modifiedNanoseconds == Int64(status.st_mtimespec.tv_nsec)
        }

        func sameObject(as other: SubjectPairJournalFileIdentity) -> Bool {
            device == other.device
                && inode == other.inode
                && owner == other.owner
                && mode == other.mode
                && linkCount == other.linkCount
                && birthSeconds == other.birthSeconds
                && birthNanoseconds == other.birthNanoseconds
        }

        func hasPrivateRegularFileShape() -> Bool {
            device >= 0
                && inode > 0
                && owner == UInt32(geteuid())
                && (mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
                && (mode & 0o777) == 0o600
                && linkCount == 1
                && (0..<1_000_000_000).contains(birthNanoseconds)
                && (0..<1_000_000_000).contains(modifiedNanoseconds)
        }

        func isValid(maximumBytes: Int64) -> Bool {
            hasPrivateRegularFileShape()
                && byteCount > 0
                && byteCount <= maximumBytes
        }
    }

    private struct SubjectPairJournalPair: Codable, Equatable {
        let output: SubjectPairJournalFileIdentity
        let manifest: SubjectPairJournalFileIdentity
    }

    private struct SubjectPairJournalMask: Codable, Equatable {
        let relativePath: String
        let identity: SubjectPairJournalFileIdentity
    }

    private struct SubjectPairRetirementJournalPaths: Codable, Equatable {
        let canonicalOutput: String
        let canonicalManifest: String
    }

    private struct SubjectPairRetirementJournalDocument: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let paths: SubjectPairRetirementJournalPaths
        let output: SubjectPairJournalFileIdentity
        let manifest: SubjectPairJournalFileIdentity
        let masks: [SubjectPairJournalMask]
    }

    private struct SubjectPairRetirementPaths {
        let transactionID: UUID
        let journalURL: URL
        let pendingJournalURL: URL

        init(paths: ProjectPaths, transactionID: UUID) {
            self.transactionID = transactionID
            let token = transactionID.uuidString.lowercased()
            journalURL = paths.isolationURL.appendingPathComponent(
                ".subject-retirement-tx-\(token).json"
            )
            pendingJournalURL = paths.isolationURL.appendingPathComponent(
                ".subject-retirement-tx-\(token).pending"
            )
        }

        var journalPaths: SubjectPairRetirementJournalPaths {
            SubjectPairRetirementJournalPaths(
                canonicalOutput: "Output/isolated.ply",
                canonicalManifest: "Isolation/isolation_manifest.json"
            )
        }
    }

    private struct LoadedSubjectPairRetirement {
        let document: SubjectPairRetirementJournalDocument
        let paths: SubjectPairRetirementPaths
        let journalIdentity: SubjectPairJournalFileIdentity
    }

    private struct SubjectPairJournalRetiredMask: Codable, Equatable {
        let mask: IsolationArtifact.Mask
        let identity: SubjectPairJournalFileIdentity
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct SubjectPairJournalPaths: Codable, Equatable {
        let canonicalOutput: String
        let canonicalManifest: String
        let newOutput: String
        let newManifest: String
        let previousOutput: String
        let previousManifest: String
    }

    private struct SubjectPairJournalDocument: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: UUID
        let paths: SubjectPairJournalPaths
        let previousPair: SubjectPairJournalPair?
        let newPair: SubjectPairJournalPair
        let newMasks: [SubjectPairJournalMask]
        let retiredMasks: [SubjectPairJournalRetiredMask]
    }

    private struct SubjectPairTransactionPaths {
        let transactionID: UUID
        let token: String
        let journalURL: URL
        let pendingJournalURL: URL
        let previousOutputURL: URL
        let previousManifestURL: URL
        let newOutputURL: URL
        let newManifestURL: URL

        init(paths: ProjectPaths, transactionID: UUID) {
            self.transactionID = transactionID
            token = transactionID.uuidString.lowercased()
            journalURL = paths.isolationURL.appendingPathComponent(
                ".subject-pair-tx-\(token).json"
            )
            pendingJournalURL = paths.isolationURL.appendingPathComponent(
                ".subject-pair-tx-\(token).pending"
            )
            previousOutputURL = paths.outputURL.appendingPathComponent(
                ".subject-pair-\(token).previous.ply"
            )
            previousManifestURL = paths.isolationURL.appendingPathComponent(
                ".subject-pair-\(token).previous-manifest.json"
            )
            newOutputURL = paths.outputURL.appendingPathComponent(
                ".subject-pair-\(token).new.ply"
            )
            newManifestURL = paths.isolationURL.appendingPathComponent(
                ".subject-pair-\(token).new-manifest.json"
            )
        }

        var journalPaths: SubjectPairJournalPaths {
            SubjectPairJournalPaths(
                canonicalOutput: "Output/isolated.ply",
                canonicalManifest: "Isolation/isolation_manifest.json",
                newOutput: "Output/\(newOutputURL.lastPathComponent)",
                newManifest: "Isolation/\(newManifestURL.lastPathComponent)",
                previousOutput: "Output/\(previousOutputURL.lastPathComponent)",
                previousManifest: "Isolation/\(previousManifestURL.lastPathComponent)"
            )
        }

        var reservedOutputNames: Set<String> {
            [newOutputURL.lastPathComponent, previousOutputURL.lastPathComponent]
        }

        var reservedIsolationNames: Set<String> {
            [
                journalURL.lastPathComponent,
                newManifestURL.lastPathComponent,
                previousManifestURL.lastPathComponent,
            ]
        }
    }

    private struct LoadedSubjectPairTransaction {
        let document: SubjectPairJournalDocument
        let paths: SubjectPairTransactionPaths
        let journalIdentity: SubjectPairJournalFileIdentity
    }

    private struct PreviousSubjectPair {
        let identities: SubjectPairJournalPair
    }

    private enum ObservedSubjectPairFile {
        case missing
        case privateFile(SubjectPairJournalFileIdentity)
        case unsafe

        func owns(_ expected: SubjectPairJournalFileIdentity) -> Bool {
            guard case .privateFile(let observed) = self else { return false }
            return observed == expected
        }

        func isSameObject(as expected: SubjectPairJournalFileIdentity) -> Bool {
            guard case .privateFile(let observed) = self else { return false }
            return observed.sameObject(as: expected)
        }

        var isMissing: Bool {
            if case .missing = self { return true }
            return false
        }
    }

    private enum SubjectPairReconciliationOutcome {
        case restored
        case committed(
            IsolationArtifact,
            ValidatedSplatOutput,
            retiredMaskConflict: Bool
        )
    }

    private enum SubjectPairCanonicalFileState: Equatable {
        case missing
        case previous
        case replacement
        case damagedReplacement
        case foreign
    }

    private struct ValidatedSubjectFiles {
        let manifest: OwnedFile
        let output: OwnedFile
        let masks: [OwnedFile]
    }

    private struct RetiredMaskCleanupAuthority {
        let mask: IsolationArtifact.Mask
        let url: URL
        let state: StableFileState
    }

    private struct StableFileState: Equatable {
        let identity: FileIdentity
        let byteCount: off_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct CanonicalAuthoritySnapshot {
        let projectID: UUID
        let publication: CanonicalSplatPublication
        let publishedResult: ValidatedPublishedResult
        let outputState: StableFileState
        let receiptState: StableFileState
        let trainingManifestState: StableFileState
        let metadataState: StableFileState
    }

    private static let maximumManifestBytes = 1_048_576
    private static let maximumMaskBytes = 64 * 1_048_576
    private static let maximumIdentityBytes = 1_024
    private static let maximumSubjectPairJournalBytes = 2 * maximumManifestBytes
    private static let maximumSubjectRetirementJournalBytes = 262_144
    private static let maximumSubjectOutputBytes = Int64.max
    private static let subjectPairPrefix = ".subject-pair-"
    private static let subjectPairJournalPrefix = ".subject-pair-tx-"
    private static let subjectRetirementJournalPrefix = ".subject-retirement-tx-"
    private static let isolationLockName = ".subject-artifact.lock"
    private static let isolationLockDepthKey =
        "EasySplat.SubjectIsolationArtifactStore.lockDepth"
    private static let processIsolationLocks = ProcessIsolationLockRegistry()
    private static let lockRetryMicroseconds: useconds_t = 5_000
    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    public static func load(paths: ProjectPaths) -> IsolationArtifactLoadResult {
        load(
            paths: paths,
            projectRootDescriptor: nil,
            beforeFinalCanonicalRevalidation: {}
        )
    }

    package static func load(
        paths: ProjectPaths,
        projectRootDescriptor: Int32
    ) -> IsolationArtifactLoadResult {
        load(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            beforeFinalCanonicalRevalidation: {}
        )
    }

    private static func load(
        paths: ProjectPaths,
        projectRootDescriptor: Int32?,
        beforeFinalCanonicalRevalidation: () throws -> Void
    ) -> IsolationArtifactLoadResult {
        if projectRootDescriptor == nil {
            var isolationStatus = stat()
            if lstat(paths.isolationURL.path, &isolationStatus) != 0 {
                let outputExists = FileManager.default.fileExists(
                    atPath: paths.isolatedOutputURL.path
                ) || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: paths.isolatedOutputURL.path
                )) != nil
                return outputExists ? .invalid : .noArtifact
            }
            guard (isolationStatus.st_mode & S_IFMT) == S_IFDIR else {
                return .invalid
            }
        }
        do {
            return try withIsolationLock(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor,
                createDirectories: false
            ) { boundRootDescriptor in
                let boundPaths = try projectPaths(
                    boundTo: boundRootDescriptor,
                    expected: paths
                )
                return loadLocked(
                    paths: boundPaths,
                    projectRootDescriptor: boundRootDescriptor,
                    beforeFinalCanonicalRevalidation:
                        beforeFinalCanonicalRevalidation
                )
            }
        } catch {
            return .invalid
        }
    }

    private static func loadLocked(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        beforeFinalCanonicalRevalidation: () throws -> Void
    ) -> IsolationArtifactLoadResult {
        do {
            _ = try reconcileSubjectPairRetirementIfPresent(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
            _ = try reconcileSubjectPairTransactionIfPresent(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        } catch {
            return .invalid
        }
        let fileManager = FileManager.default
        let manifestExists = fileManager.fileExists(atPath: paths.isolationManifestURL.path)
            || (try? fileManager.destinationOfSymbolicLink(
                atPath: paths.isolationManifestURL.path
            )) != nil
        if !manifestExists {
            let outputExists = fileManager.fileExists(atPath: paths.isolatedOutputURL.path)
                || (try? fileManager.destinationOfSymbolicLink(
                    atPath: paths.isolatedOutputURL.path
                )) != nil
            return outputExists ? .invalid : .noArtifact
        }

        do {
            let artifact = try loadManifest(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
            let authority: CanonicalAuthoritySnapshot
            do {
                authority = try captureCanonicalAuthority(
                    paths: paths,
                    projectRootDescriptor: projectRootDescriptor
                )
            } catch {
                return .stale(.sourceOutput)
            }
            if let stale = try staleReason(
                for: artifact,
                paths: paths,
                publishedResult: authority.publishedResult,
                projectRootDescriptor: projectRootDescriptor
            ) {
                return .stale(stale)
            }
            let outputState = try stableFileState(
                relativePath: "Output/isolated.ply",
                projectRootDescriptor: projectRootDescriptor
            )
            let output = try validatePublishedFiles(
                artifact,
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
            guard try stableFileState(
                relativePath: "Output/isolated.ply",
                projectRootDescriptor: projectRootDescriptor
            ) == outputState else {
                return .invalid
            }
            guard try loadManifest(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            ) == artifact else {
                return .invalid
            }
            try beforeFinalCanonicalRevalidation()
            try requireCanonicalAuthority(
                authority,
                paths: try projectPaths(
                    boundTo: projectRootDescriptor,
                    expected: paths
                ),
                projectRootDescriptor: projectRootDescriptor
            )
            if let stale = try staleReason(
                for: artifact,
                paths: paths,
                publishedResult: authority.publishedResult,
                projectRootDescriptor: projectRootDescriptor
            ) {
                return .stale(stale)
            }
            guard try loadManifest(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            ) == artifact else {
                return .invalid
            }
            guard try stableFileState(
                relativePath: "Output/isolated.ply",
                projectRootDescriptor: projectRootDescriptor
            ) == outputState else {
                return .invalid
            }
            let revalidatedOutput = try validateSubjectOutput(
                artifact,
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
            guard revalidatedOutput == output,
                  try stableFileState(
                    relativePath: "Output/isolated.ply",
                    projectRootDescriptor: projectRootDescriptor
                  ) == outputState,
                  try loadManifest(
                    paths: paths,
                    projectRootDescriptor: projectRootDescriptor
                  ) == artifact else {
                return .invalid
            }
            try requireCanonicalAuthority(
                authority,
                paths: try projectPaths(
                    boundTo: projectRootDescriptor,
                    expected: paths
                ),
                projectRootDescriptor: projectRootDescriptor
            )
            return .valid(artifact, revalidatedOutput)
        } catch {
            return .invalid
        }
    }

    @discardableResult
    public static func publish(
        _ proposedArtifact: IsolationArtifact,
        stagedOutputURL: URL,
        stagedMasksURL: URL,
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ValidatedSplatOutput {
        try throwIfCancelled(shouldCancel)
        if projectRootDescriptor == nil {
            try paths.ensureIsolationDirectories()
        }
        return try withIsolationLock(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            createDirectories: true,
            shouldCancel: shouldCancel
        ) { boundRootDescriptor in
            let boundPaths = try projectPaths(
                boundTo: boundRootDescriptor,
                expected: paths
            )
            return try publishLocked(
                proposedArtifact,
                stagedOutputURL: stagedOutputURL,
                stagedMasksURL: stagedMasksURL,
                paths: boundPaths,
                projectRootDescriptor: boundRootDescriptor,
                shouldCancel: shouldCancel
            )
        }
    }

    private static func publishLocked(
        _ proposedArtifact: IsolationArtifact,
        stagedOutputURL: URL,
        stagedMasksURL: URL,
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        shouldCancel: @escaping @Sendable () -> Bool,
        transactionID: UUID = UUID(),
        crashAfter: SubjectPairPublicationCheckpoint? = nil,
        beforeRetiredMaskCleanup: () throws -> Void = {}
    ) throws -> ValidatedSplatOutput {
        _ = try reconcileSubjectPairRetirementIfPresent(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        _ = try reconcileSubjectPairTransactionIfPresent(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        let canonicalAuthority = try captureCanonicalAuthority(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        let canonicalPublication = canonicalAuthority.publication
        let artifact = proposedArtifact
        guard artifact.sourcePublicationID == canonicalPublication.publicationID else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try validateManifest(artifact, paths: paths)
        let retiredMaskCleanupAuthorities = captureRetiredMaskCleanupAuthorities(
            paths: paths
        )
        guard try staleReason(
            for: artifact,
            paths: paths,
            publishedResult: canonicalAuthority.publishedResult,
            projectRootDescriptor: projectRootDescriptor,
            shouldCancel: shouldCancel
        ) == nil else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try validateStagingLocation(
            output: stagedOutputURL,
            masks: stagedMasksURL,
            paths: paths
        )

        let stagedOutput = try ProjectArtifactValidator.validatedPlyEvidence(
            at: stagedOutputURL,
            shouldCancel: shouldCancel
        )
        try requireOutput(stagedOutput, matches: artifact.output)
        let stagedMaskURLs = try stagedMaskFiles(at: stagedMasksURL)
        guard stagedMaskURLs.count == artifact.masks.count else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        for (mask, url) in zip(artifact.masks, stagedMaskURLs) {
            try validateMask(mask, at: url, shouldCancel: shouldCancel)
        }

        let previousSubjectPair = try capturePreviousSubjectPairIfPresent(
            paths: paths
        )
        let retiredMaskRecords = try subjectPairRetiredMaskRecords(
            retiredMaskCleanupAuthorities
        )
        let manifestData = try encodedManifest(artifact)
        let transactionPaths = SubjectPairTransactionPaths(
            paths: paths,
            transactionID: transactionID
        )
        try requireSubjectPairTransactionPathsAvailable(transactionPaths)
        var publishedMasks: [OwnedFile] = []
        var journalMasks: [SubjectPairJournalMask] = []
        var stagedOutputFile: OwnedFile?
        var stagedManifestFile: OwnedFile?
        var journalActivated = false
        var preservePreJournalCrashState = false

        defer {
            if !journalActivated, !preservePreJournalCrashState {
                for file in publishedMasks {
                    try? removeOwnedFileIfPresent(file)
                }
                try? synchronizeDirectory(paths.isolationMasksURL)
                if let stagedOutputFile {
                    try? removeOwnedFileIfPresent(stagedOutputFile)
                }
                if let stagedManifestFile {
                    try? removeOwnedFileIfPresent(stagedManifestFile)
                }
            }
        }

        for (mask, source) in zip(artifact.masks, stagedMaskURLs) {
            try throwIfCancelled(shouldCancel)
            let destination = try paths.resolveProjectRelativePath(mask.relativePath)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: destination.path
                  )) == nil else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let identity = try copyPrivateRegularFile(
                from: source,
                to: destination,
                maximumBytes: maximumMaskBytes,
                shouldCancel: shouldCancel
            )
            publishedMasks.append(OwnedFile(url: destination, identity: identity))
            try validateMask(mask, at: destination, shouldCancel: shouldCancel)
            journalMasks.append(SubjectPairJournalMask(
                relativePath: mask.relativePath,
                identity: try subjectPairJournalIdentity(
                    at: destination,
                    maximumBytes: Int64(maximumMaskBytes)
                )
            ))
        }
        try throwIfCancelled(shouldCancel)
        try synchronizeDirectory(paths.isolationMasksURL)
        try requireCanonicalAuthority(
            canonicalAuthority,
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )

        _ = try ProjectArtifactValidator.publishValidatedPly(
            from: stagedOutputURL,
            to: transactionPaths.newOutputURL,
            expected: Optional(ExpectedPlyArtifactIdentity(
                byteCount: artifact.output.byteCount,
                vertexCount: artifact.output.gaussianCount,
                sha256: artifact.output.sha256
            )),
            systemCalls: .system(),
            shouldCancel: shouldCancel
        )
        stagedOutputFile = OwnedFile(
            url: transactionPaths.newOutputURL,
            identity: try privateRegularFileIdentity(
                at: transactionPaths.newOutputURL
            )
        )
        let manifestTemporaryIdentity = try writePrivateFile(
            manifestData,
            to: transactionPaths.newManifestURL,
            shouldCancel: shouldCancel
        )
        stagedManifestFile = OwnedFile(
            url: transactionPaths.newManifestURL,
            identity: manifestTemporaryIdentity
        )
        try throwIfCancelled(shouldCancel)
        try requireCanonicalAuthority(
            canonicalAuthority,
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        try synchronizeDirectory(paths.outputURL)
        try synchronizeDirectory(paths.isolationURL)
        if crashAfter == .newPairStaged {
            preservePreJournalCrashState = true
            throw SimulatedSubjectPairProcessExit()
        }

        let newPair = SubjectPairJournalPair(
            output: try subjectPairJournalIdentity(
                at: transactionPaths.newOutputURL,
                maximumBytes: maximumSubjectOutputBytes
            ),
            manifest: try subjectPairJournalIdentity(
                at: transactionPaths.newManifestURL,
                maximumBytes: Int64(maximumManifestBytes)
            )
        )
        let journal = SubjectPairJournalDocument(
            schemaVersion: 1,
            transactionID: transactionID,
            paths: transactionPaths.journalPaths,
            previousPair: previousSubjectPair?.identities,
            newPair: newPair,
            newMasks: journalMasks,
            retiredMasks: retiredMaskRecords
        )
        _ = try writeSubjectPairJournal(journal, transaction: transactionPaths)
        journalActivated = true
        try reachSubjectPairCheckpoint(.journalActivated, crashAfter: crashAfter)

        do {
            if let previous = previousSubjectPair {
                try moveSubjectPairFile(
                    from: paths.isolatedOutputURL,
                    expected: previous.identities.output,
                    to: transactionPaths.previousOutputURL
                )
                try synchronizeDirectory(paths.outputURL)
                try reachSubjectPairCheckpoint(
                    .previousOutputMoved,
                    crashAfter: crashAfter
                )
                try throwIfCancelled(shouldCancel)
                try requireCanonicalAuthority(
                    canonicalAuthority,
                    paths: paths,
                    projectRootDescriptor: projectRootDescriptor
                )

                try moveSubjectPairFile(
                    from: paths.isolationManifestURL,
                    expected: previous.identities.manifest,
                    to: transactionPaths.previousManifestURL
                )
                try synchronizeDirectory(paths.isolationURL)
                try reachSubjectPairCheckpoint(
                    .previousManifestMoved,
                    crashAfter: crashAfter
                )
                try throwIfCancelled(shouldCancel)
                try requireCanonicalAuthority(
                    canonicalAuthority,
                    paths: paths,
                    projectRootDescriptor: projectRootDescriptor
                )
            }

            try moveSubjectPairFile(
                from: transactionPaths.newOutputURL,
                expected: newPair.output,
                to: paths.isolatedOutputURL
            )
            stagedOutputFile = nil
            try synchronizeDirectory(paths.outputURL)
            try reachSubjectPairCheckpoint(
                .newOutputInstalled,
                crashAfter: crashAfter
            )
            try throwIfCancelled(shouldCancel)
            try requireCanonicalAuthority(
                canonicalAuthority,
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )

            try moveSubjectPairFile(
                from: transactionPaths.newManifestURL,
                expected: newPair.manifest,
                to: paths.isolationManifestURL
            )
            stagedManifestFile = nil
            try synchronizeDirectory(paths.isolationURL)
            try reachSubjectPairCheckpoint(
                .newManifestInstalled,
                crashAfter: crashAfter
            )

            guard case .committed(
                    let committedArtifact,
                    let validated,
                    let retiredMaskConflict
                  ) =
                    try reconcileSubjectPairTransactionIfPresent(
                        paths: paths,
                        projectRootDescriptor: projectRootDescriptor,
                        beforeRetiredMaskCleanup: beforeRetiredMaskCleanup
                    ),
                  committedArtifact == artifact else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            try requireCanonicalAuthority(
                canonicalAuthority,
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
            if retiredMaskConflict {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            return validated
        } catch is SimulatedSubjectPairProcessExit {
            throw SimulatedSubjectPairProcessExit()
        } catch {
            do {
                _ = try reconcileSubjectPairTransactionIfPresent(
                    paths: paths,
                    projectRootDescriptor: projectRootDescriptor
                )
            } catch {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            throw error
        }
    }

    @discardableResult
    public static func removeValidatedSubject(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil
    ) throws -> Bool {
        if projectRootDescriptor == nil {
            var status = stat()
            guard lstat(paths.isolationURL.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR else {
                return false
            }
        }
        return try withIsolationLock(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        ) { boundRootDescriptor in
            let boundPaths = try projectPaths(
                boundTo: boundRootDescriptor,
                expected: paths
            )
            guard case .valid(let artifact, _) = loadLocked(
                paths: boundPaths,
                projectRootDescriptor: boundRootDescriptor,
                beforeFinalCanonicalRevalidation: {}
            ) else {
                return false
            }
            try removeValidated(
                artifact,
                paths: boundPaths,
                projectRootDescriptor: boundRootDescriptor
            )
            return true
        }
    }

    static func captureCanonicalPublication(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        expectedPublicationID: UUID? = nil
    ) throws -> CanonicalSplatPublication {
        try withIsolationLock(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            createDirectories: true
        ) { boundRootDescriptor in
            let boundPaths = try projectPaths(
                boundTo: boundRootDescriptor,
                expected: paths
            )
            return try makeCanonicalPublication(
                paths: boundPaths,
                projectRootDescriptor: boundRootDescriptor,
                publishedResult: validatedPublishedResult(
                    paths: boundPaths,
                    projectRootDescriptor: boundRootDescriptor
                ),
                expectedPublicationID: expectedPublicationID
            )
        }
    }

    static func captureCanonicalPublication(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        publishedResult: ValidatedPublishedResult,
        expectedPublicationID: UUID? = nil
    ) throws -> CanonicalSplatPublication {
        try withIsolationLock(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            createDirectories: true
        ) { boundRootDescriptor in
            try makeCanonicalPublication(
                paths: try projectPaths(
                    boundTo: boundRootDescriptor,
                    expected: paths
                ),
                projectRootDescriptor: boundRootDescriptor,
                publishedResult: publishedResult,
                expectedPublicationID: expectedPublicationID
            )
        }
    }

    private static func makeCanonicalPublication(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        publishedResult: ValidatedPublishedResult,
        expectedPublicationID: UUID? = nil
    ) throws -> CanonicalSplatPublication {
        let metadata = try ProjectMetadataStore.load(
            fromProjectRootDescriptor: projectRootDescriptor
        )
        let trainingManifest = try readBoundProjectFile(
            relativePath: "Training/training_manifest.json",
            projectRootDescriptor: projectRootDescriptor,
            maximumBytes: maximumManifestBytes
        )
        let training = try JSONDecoder().decode(
            TrainingArtifact.self,
            from: trainingManifest
        )
        let manifestSHA256 = sha256(trainingManifest)
        guard expectedPublicationID.map({
                  $0 == publishedResult.receipt.publicationID
              }) ?? true,
              publishedResult.receipt.projectID == metadata.id,
              training.completionStatus == .completed,
              training.outputPath == PublishedSplatReceipt.canonicalOutputPath,
              publishedResult.receipt.lineage.trainingManifestSHA256 == manifestSHA256,
              publishedResult.receipt.lineage.trainingInputDigest == training.inputDigest,
              publishedResult.receipt.lineage.trainingGeometryDigest == training.geometryDigest,
              training.outputSHA256 == publishedResult.outputEvidence.sha256,
              training.outputBytes == Int64(exactly: publishedResult.outputEvidence.byteCount),
              training.gaussianCount == publishedResult.outputEvidence.vertexCount,
              training.sceneBounds.map({
                  SplatSceneBoundsCalculator.matches(
                      $0,
                      publishedResult.outputEvidence.sceneBounds
                  )
              }) == true else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return CanonicalSplatPublication(
            publicationID: publishedResult.receipt.publicationID,
            outputEvidence: publishedResult.outputEvidence,
            trainingManifestSHA256: manifestSHA256,
            trainingInputDigest: training.inputDigest,
            trainingGeometryDigest: training.geometryDigest,
            selectedFramesDigest: training.datasetDerivation.sourceSelectedFramesDigest,
            selectedImageOrder: training.datasetDerivation.registeredImageNames
        )
    }

    private static func captureCanonicalAuthority(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        beforeCanonicalPlyValidation: @escaping @Sendable () -> Void = {}
    ) throws -> CanonicalAuthoritySnapshot {
        let outputState = try stableFileState(
            relativePath: "Output/splat.ply",
            projectRootDescriptor: projectRootDescriptor
        )
        let receiptState = try stableFileState(
            relativePath: "Output/splat_receipt.json",
            projectRootDescriptor: projectRootDescriptor
        )
        let trainingManifestState = try stableFileState(
            relativePath: "Training/training_manifest.json",
            projectRootDescriptor: projectRootDescriptor
        )
        let metadataState = try stableFileState(
            relativePath: "project.json",
            projectRootDescriptor: projectRootDescriptor
        )
        let result = try validatedPublishedResult(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            beforeCanonicalPlyValidation: beforeCanonicalPlyValidation
        )
        let publication = try makeCanonicalPublication(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            publishedResult: result
        )
        let metadata = try ProjectMetadataStore.load(
            fromProjectRootDescriptor: projectRootDescriptor
        )
        guard try stableFileState(
                relativePath: "Output/splat.ply",
                projectRootDescriptor: projectRootDescriptor
              ) == outputState,
              try stableFileState(
                relativePath: "Output/splat_receipt.json",
                projectRootDescriptor: projectRootDescriptor
              ) == receiptState,
              try stableFileState(
                relativePath: "Training/training_manifest.json",
                projectRootDescriptor: projectRootDescriptor
              ) == trainingManifestState,
              try stableFileState(
                relativePath: "project.json",
                projectRootDescriptor: projectRootDescriptor
              ) == metadataState else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let snapshot = CanonicalAuthoritySnapshot(
            projectID: metadata.id,
            publication: publication,
            publishedResult: result,
            outputState: outputState,
            receiptState: receiptState,
            trainingManifestState: trainingManifestState,
            metadataState: metadataState
        )
        try requireCanonicalAuthority(
            snapshot,
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        return snapshot
    }

    private static func requireCanonicalAuthority(
        _ expected: CanonicalAuthoritySnapshot,
        paths: ProjectPaths,
        projectRootDescriptor: Int32
    ) throws {
        let currentReceiptState = try stableFileState(
            relativePath: "Output/splat_receipt.json",
            projectRootDescriptor: projectRootDescriptor
        )
        guard try stableFileState(
                relativePath: "Output/splat.ply",
                projectRootDescriptor: projectRootDescriptor
              )
                == expected.outputState,
              try stableFileState(
                relativePath: "Training/training_manifest.json",
                projectRootDescriptor: projectRootDescriptor
              )
                == expected.trainingManifestState,
              try stableFileState(
                relativePath: "project.json",
                projectRootDescriptor: projectRootDescriptor
              )
                == expected.metadataState else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let resolved = try validatedPublishedResult(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        let receipt = resolved.receipt
        let metadata = try ProjectMetadataStore.load(
            fromProjectRootDescriptor: projectRootDescriptor
        )
        let trainingData = try readBoundProjectFile(
            relativePath: "Training/training_manifest.json",
            projectRootDescriptor: projectRootDescriptor,
            maximumBytes: maximumManifestBytes
        )
        guard metadata.id == expected.projectID,
              receiptMatchesCanonicalAuthority(
                receipt,
                expected: expected.publishedResult.receipt
              ),
              sha256(trainingData)
                == expected.publication.trainingManifestSHA256,
              try stableFileState(
                relativePath: "Output/splat.ply",
                projectRootDescriptor: projectRootDescriptor
              )
                == expected.outputState,
              try stableFileState(
                relativePath: "Output/splat_receipt.json",
                projectRootDescriptor: projectRootDescriptor
              )
                == currentReceiptState,
              try stableFileState(
                relativePath: "Training/training_manifest.json",
                projectRootDescriptor: projectRootDescriptor
              )
                == expected.trainingManifestState,
              try stableFileState(
                relativePath: "project.json",
                projectRootDescriptor: projectRootDescriptor
              )
                == expected.metadataState else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    /// Call only with a publication receipt captured after the replacement
    /// canonical PLY and its completed training receipt are durably persisted.
    @discardableResult
    public static func invalidateAfterCanonicalRetraining(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        publication: CanonicalSplatPublication
    ) throws -> Bool {
        try invalidateAfterCanonicalRetraining(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            publication: publication,
            beforeRemoval: {},
            afterRemoval: {}
        )
    }

    private static func invalidateAfterCanonicalRetraining(
        paths: ProjectPaths,
        projectRootDescriptor: Int32?,
        publication: CanonicalSplatPublication,
        beforeCanonicalPlyValidation: @escaping @Sendable () -> Void = {},
        beforeRemoval: () throws -> Void,
        afterRemoval: () throws -> Void
    ) throws -> Bool {
        if projectRootDescriptor == nil {
            try paths.ensureIsolationDirectories()
        }
        return try withIsolationLock(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            createDirectories: true
        ) { boundRootDescriptor in
            try invalidateLocked(
                paths: try projectPaths(
                    boundTo: boundRootDescriptor,
                    expected: paths
                ),
                expectedPaths: paths,
                projectRootDescriptor: boundRootDescriptor,
                publication: publication,
                beforeCanonicalPlyValidation: beforeCanonicalPlyValidation,
                beforeRemoval: beforeRemoval,
                afterRemoval: afterRemoval
            )
        }
    }

    private static func invalidateLocked(
        paths: ProjectPaths,
        expectedPaths: ProjectPaths,
        projectRootDescriptor: Int32,
        publication: CanonicalSplatPublication,
        beforeCanonicalPlyValidation: @escaping @Sendable () -> Void,
        beforeRemoval: () throws -> Void,
        afterRemoval: () throws -> Void
    ) throws -> Bool {
        _ = try reconcileSubjectPairRetirementIfPresent(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        _ = try reconcileSubjectPairTransactionIfPresent(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        guard FileManager.default.fileExists(atPath: paths.isolationManifestURL.path) else {
            return false
        }
        let canonicalAuthority = try captureCanonicalAuthority(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            beforeCanonicalPlyValidation: beforeCanonicalPlyValidation
        )
        guard canonicalAuthority.publication == publication else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let artifact: IsolationArtifact
        do {
            artifact = try loadManifest(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        } catch SubjectIsolationArtifactStoreError.invalidArtifact {
            // A legacy or malformed artifact has no publication authority. Leave
            // its untrusted files untouched; all readers already fail closed.
            return false
        }
        do {
            guard artifact.sourcePublicationID != publication.publicationID
                    || artifact.sourcePlySHA256 != publication.outputEvidence.sha256
                    || artifact.trainingManifestSHA256 != publication.trainingManifestSHA256
                    || artifact.dataset.inputDigest != publication.trainingInputDigest
                    || artifact.dataset.geometryDigest != publication.trainingGeometryDigest
                    || artifact.dataset.selectedFramesDigest != publication.selectedFramesDigest
                    || artifact.dataset.selectedImageOrder != publication.selectedImageOrder else {
                throw SubjectIsolationArtifactStoreError.canonicalPublicationUnchanged
            }
            _ = try validatePublishedFiles(
                artifact,
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        } catch SubjectIsolationArtifactStoreError.invalidArtifact {
            // The optional subject pair has no authority and must not poison a
            // completed canonical publication. Leave untrusted files untouched.
            return false
        }
        try beforeRemoval()
        let removalPaths = try projectPaths(
            boundTo: projectRootDescriptor,
            expected: expectedPaths,
            requireExpectedPathIdentity: false
        )
        try requireCanonicalAuthority(
            canonicalAuthority,
            paths: removalPaths,
            projectRootDescriptor: projectRootDescriptor
        )
        guard try loadManifest(
            paths: removalPaths,
            projectRootDescriptor: projectRootDescriptor
        ) == artifact else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try removeValidated(
            artifact,
            paths: removalPaths,
            projectRootDescriptor: projectRootDescriptor
        )
        try afterRemoval()
        let finalPaths = try projectPaths(
            boundTo: projectRootDescriptor,
            expected: expectedPaths
        )
        try requireCanonicalAuthority(
            canonicalAuthority,
            paths: finalPaths,
            projectRootDescriptor: projectRootDescriptor
        )
        return true
    }

#if DEBUG
    @discardableResult
    static func test_publish(
        _ artifact: IsolationArtifact,
        stagedOutputURL: URL,
        stagedMasksURL: URL,
        paths: ProjectPaths,
        beforeRetiredMaskCleanup: @escaping () throws -> Void
    ) throws -> ValidatedSplatOutput {
        try paths.ensureIsolationDirectories()
        return try withIsolationLock(paths: paths) { boundRootDescriptor in
            let boundPaths = try projectPaths(
                boundTo: boundRootDescriptor,
                expected: paths
            )
            return try publishLocked(
                artifact,
                stagedOutputURL: stagedOutputURL,
                stagedMasksURL: stagedMasksURL,
                paths: boundPaths,
                projectRootDescriptor: boundRootDescriptor,
                shouldCancel: { false },
                beforeRetiredMaskCleanup: beforeRetiredMaskCleanup
            )
        }
    }

    static func test_publishInterrupted(
        _ artifact: IsolationArtifact,
        stagedOutputURL: URL,
        stagedMasksURL: URL,
        paths: ProjectPaths,
        transactionID: UUID,
        after checkpoint: SubjectPairPublicationCheckpoint
    ) throws {
        try paths.ensureIsolationDirectories()
        do {
            _ = try withIsolationLock(paths: paths) { boundRootDescriptor in
                try publishLocked(
                    artifact,
                    stagedOutputURL: stagedOutputURL,
                    stagedMasksURL: stagedMasksURL,
                    paths: try projectPaths(
                        boundTo: boundRootDescriptor,
                        expected: paths
                    ),
                    projectRootDescriptor: boundRootDescriptor,
                    shouldCancel: { false },
                    transactionID: transactionID,
                    crashAfter: checkpoint
                )
            }
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        } catch is SimulatedSubjectPairProcessExit {
            return
        }
    }

    static func test_removeValidatedSubjectInterrupted(
        paths: ProjectPaths,
        transactionID: UUID,
        after checkpoint: SubjectPairRetirementCheckpoint
    ) throws {
        try paths.ensureIsolationDirectories()
        do {
            try withIsolationLock(paths: paths) { boundRootDescriptor in
                let boundPaths = try projectPaths(
                    boundTo: boundRootDescriptor,
                    expected: paths
                )
                guard case .valid(let artifact, _) = loadLocked(
                    paths: boundPaths,
                    projectRootDescriptor: boundRootDescriptor,
                    beforeFinalCanonicalRevalidation: {}
                ) else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                try removeValidated(
                    artifact,
                    paths: boundPaths,
                    projectRootDescriptor: boundRootDescriptor,
                    transactionID: transactionID,
                    crashAfter: checkpoint
                )
            }
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        } catch is SimulatedSubjectPairProcessExit {
            return
        }
    }

    static func test_load(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        beforeFinalCanonicalRevalidation: () throws -> Void
    ) -> IsolationArtifactLoadResult {
        load(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            beforeFinalCanonicalRevalidation:
                beforeFinalCanonicalRevalidation
        )
    }

    static func test_invalidateAfterCanonicalRetraining(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        publication: CanonicalSplatPublication,
        beforeCanonicalPlyValidation: @escaping @Sendable () -> Void = {},
        beforeRemoval: () throws -> Void,
        afterRemoval: () throws -> Void = {}
    ) throws -> Bool {
        try invalidateAfterCanonicalRetraining(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            publication: publication,
            beforeCanonicalPlyValidation: beforeCanonicalPlyValidation,
            beforeRemoval: beforeRemoval,
            afterRemoval: afterRemoval
        )
    }

    static func test_removeValidatedSubject(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        willQuarantineOwnedEntry: (String, String) throws -> Void = { _, _ in },
        willUnlinkQuarantinedEntry: (String, String) throws -> Void = { _, _ in }
    ) throws -> Bool {
        try withIsolationLock(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        ) { boundRootDescriptor in
            let boundPaths = try projectPaths(
                boundTo: boundRootDescriptor,
                expected: paths
            )
            guard case .valid(let artifact, _) = loadLocked(
                paths: boundPaths,
                projectRootDescriptor: boundRootDescriptor,
                beforeFinalCanonicalRevalidation: {}
            ) else {
                return false
            }
            try removeValidated(
                artifact,
                paths: boundPaths,
                projectRootDescriptor: boundRootDescriptor,
                willQuarantineOwnedEntry: willQuarantineOwnedEntry,
                willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
            )
            return true
        }
    }
#endif

    @discardableResult
    private static func reconcileSubjectPairRetirementIfPresent(
        paths: ProjectPaths,
        projectRootDescriptor: Int32
    ) throws -> Bool {
        _ = try projectPaths(
            boundTo: projectRootDescriptor,
            expected: paths
        )
        guard let retirement = try loadSubjectPairRetirementIfPresent(
            paths: paths
        ) else {
            return false
        }
        try completeSubjectPairRetirement(retirement, paths: paths)
        return true
    }

    private static func loadSubjectPairRetirementIfPresent(
        paths: ProjectPaths
    ) throws -> LoadedSubjectPairRetirement? {
        do {
            let names = try FileManager.default.contentsOfDirectory(
                atPath: paths.isolationURL.path
            )
            let journalNames = names.filter {
                $0.hasPrefix(subjectRetirementJournalPrefix)
                    && $0.hasSuffix(".json")
            }
            if journalNames.isEmpty {
                return nil
            }
            let publicationJournalNames = names.filter {
                $0.hasPrefix(subjectPairJournalPrefix) && $0.hasSuffix(".json")
            }
            guard publicationJournalNames.isEmpty,
                  journalNames.count == 1,
                  let journalName = journalNames.first else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let token = String(
                journalName.dropFirst(subjectRetirementJournalPrefix.count)
                    .dropLast(5)
            )
            guard let transactionID = UUID(uuidString: token),
                  transactionID.uuidString.lowercased() == token else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let retirementPaths = SubjectPairRetirementPaths(
                paths: paths,
                transactionID: transactionID
            )
            let transactionNames = names.filter { $0.contains(token) }
            guard Set(transactionNames).isSubset(of: Set([
                retirementPaths.journalURL.lastPathComponent,
                retirementPaths.pendingJournalURL.lastPathComponent,
            ])) else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            try requireSubjectPairFileAbsent(retirementPaths.pendingJournalURL)
            let journalIdentity = try subjectPairJournalIdentity(
                at: retirementPaths.journalURL,
                maximumBytes: Int64(maximumSubjectRetirementJournalBytes)
            )
            let data = try readSubjectPairFile(
                at: retirementPaths.journalURL,
                expected: journalIdentity,
                maximumBytes: maximumSubjectRetirementJournalBytes
            )
            try StrictJSONDocument.validate(
                data,
                maximumBytes: maximumSubjectRetirementJournalBytes
            )
            try requireStrictSubjectPairRetirementSchema(data)
            let document = try JSONDecoder().decode(
                SubjectPairRetirementJournalDocument.self,
                from: data
            )
            try validateSubjectPairRetirementJournal(
                document,
                retirement: retirementPaths,
                paths: paths
            )
            return LoadedSubjectPairRetirement(
                document: document,
                paths: retirementPaths,
                journalIdentity: journalIdentity
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func validateSubjectPairRetirementJournal(
        _ document: SubjectPairRetirementJournalDocument,
        retirement: SubjectPairRetirementPaths,
        paths: ProjectPaths
    ) throws {
        guard document.schemaVersion == 1,
              document.transactionID == retirement.transactionID,
              document.paths == retirement.journalPaths,
              document.output.isValid(maximumBytes: maximumSubjectOutputBytes),
              document.manifest.isValid(
                maximumBytes: Int64(maximumManifestBytes)
              ),
              !document.masks.isEmpty,
              document.masks.count <= IsolationArtifact.maximumMaskCount else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var maskPaths = Set<String>()
        for mask in document.masks {
            guard maskPaths.insert(mask.relativePath).inserted,
                  mask.identity.isValid(
                    maximumBytes: Int64(maximumMaskBytes)
                  ) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            let resolved = try paths.resolveProjectRelativePath(mask.relativePath)
            guard isCanonicalMaskRelativePath(
                mask.relativePath,
                resolved: resolved
            ) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
    }

    private static func requireStrictSubjectPairRetirementSchema(
        _ data: Data
    ) throws {
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireKeys(
            root,
            required: [
                "schemaVersion", "transactionID", "paths", "output",
                "manifest", "masks",
            ]
        )
        try requireObject(
            root["paths"],
            keys: ["canonicalOutput", "canonicalManifest"]
        )
        try requireSubjectPairJournalIdentityObject(root["output"])
        try requireSubjectPairJournalIdentityObject(root["manifest"])
        guard let masks = root["masks"] as? [[String: Any]] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        for mask in masks {
            try requireKeys(mask, required: ["relativePath", "identity"])
            try requireSubjectPairJournalIdentityObject(mask["identity"])
        }
    }

    private static func writeSubjectPairRetirementJournal(
        _ document: SubjectPairRetirementJournalDocument,
        retirement: SubjectPairRetirementPaths
    ) throws -> SubjectPairJournalFileIdentity {
        try requireSubjectPairFileAbsent(retirement.journalURL)
        try requireSubjectPairFileAbsent(retirement.pendingJournalURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard !data.isEmpty,
              data.count <= maximumSubjectRetirementJournalBytes else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try StrictJSONDocument.validate(
            data,
            maximumBytes: maximumSubjectRetirementJournalBytes
        )
        try requireStrictSubjectPairRetirementSchema(data)

        var pending: OwnedFile?
        var installed: OwnedFile?
        defer {
            if let pending {
                try? removeOwnedFileIfPresent(pending)
            }
            if let installed {
                try? removeOwnedFileIfPresent(installed)
            }
        }
        let pendingIdentity = try writePrivateFile(
            data,
            to: retirement.pendingJournalURL
        )
        pending = OwnedFile(
            url: retirement.pendingJournalURL,
            identity: pendingIdentity
        )
        try renameExclusive(
            retirement.pendingJournalURL,
            to: retirement.journalURL
        )
        installed = OwnedFile(
            url: retirement.journalURL,
            identity: pendingIdentity
        )
        pending = nil
        try synchronizeDirectory(
            retirement.journalURL.deletingLastPathComponent()
        )
        let journalIdentity = try subjectPairJournalIdentity(
            at: retirement.journalURL,
            maximumBytes: Int64(maximumSubjectRetirementJournalBytes)
        )
        guard journalIdentity.device == Int64(pendingIdentity.device),
              journalIdentity.inode == UInt64(pendingIdentity.inode) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        installed = nil
        return journalIdentity
    }

    private static func completeSubjectPairRetirement(
        _ retirement: LoadedSubjectPairRetirement,
        paths: ProjectPaths,
        crashAfter: SubjectPairRetirementCheckpoint? = nil,
        willQuarantineOwnedEntry: (String, String) throws -> Void = { _, _ in },
        willUnlinkQuarantinedEntry: (String, String) throws -> Void = { _, _ in }
    ) throws {
        let document = retirement.document
        try removeRetiringSubjectFileIfOwned(
            paths.isolationManifestURL,
            expected: document.manifest,
            maximumBytes: Int64(maximumManifestBytes),
            paths: paths,
            willQuarantineOwnedEntry: willQuarantineOwnedEntry,
            willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
        )
        try reachSubjectPairRetirementCheckpoint(
            .manifestRemoved,
            crashAfter: crashAfter
        )
        try removeRetiringSubjectFileIfOwned(
            paths.isolatedOutputURL,
            expected: document.output,
            maximumBytes: maximumSubjectOutputBytes,
            paths: paths,
            willQuarantineOwnedEntry: willQuarantineOwnedEntry,
            willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
        )
        try reachSubjectPairRetirementCheckpoint(
            .outputRemoved,
            crashAfter: crashAfter
        )
        for mask in document.masks.sorted(by: {
            $0.relativePath < $1.relativePath
        }) {
            try removeRetiringSubjectFileIfOwned(
                try paths.resolveProjectRelativePath(mask.relativePath),
                expected: mask.identity,
                maximumBytes: Int64(maximumMaskBytes),
                paths: paths,
                willQuarantineOwnedEntry: willQuarantineOwnedEntry,
                willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
            )
        }
        try reachSubjectPairRetirementCheckpoint(
            .masksRemoved,
            crashAfter: crashAfter
        )
        try removeRetiringSubjectFileIfOwned(
            retirement.paths.journalURL,
            expected: retirement.journalIdentity,
            maximumBytes: Int64(maximumSubjectRetirementJournalBytes),
            paths: paths,
            willQuarantineOwnedEntry: willQuarantineOwnedEntry,
            willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
        )
    }

    private static func removeRetiringSubjectFileIfOwned(
        _ url: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int64,
        paths: ProjectPaths,
        willQuarantineOwnedEntry: (String, String) throws -> Void,
        willUnlinkQuarantinedEntry: (String, String) throws -> Void
    ) throws {
        let observed = try observeSubjectPairFile(
            at: url,
            maximumBytes: maximumBytes
        )
        if observed.isMissing {
            return
        }
        if observed.owns(expected) {
            try quarantineAndUnlinkSubjectPairFile(
                url,
                expected: expected,
                maximumBytes: maximumBytes,
                requireExactBytes: true,
                paths: paths,
                willQuarantineOwnedEntry: willQuarantineOwnedEntry,
                willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
            )
            return
        }
        if observed.isSameObject(as: expected) {
            try quarantineAndUnlinkSubjectPairFile(
                url,
                expected: expected,
                maximumBytes: maximumBytes,
                requireExactBytes: false,
                paths: paths,
                willQuarantineOwnedEntry: willQuarantineOwnedEntry,
                willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
            )
            return
        }
        throw SubjectIsolationArtifactStoreError.publicationConflict
    }

    private static func reachSubjectPairRetirementCheckpoint(
        _ checkpoint: SubjectPairRetirementCheckpoint,
        crashAfter: SubjectPairRetirementCheckpoint?
    ) throws {
        if crashAfter == checkpoint {
            throw SimulatedSubjectPairProcessExit()
        }
    }

    private static func capturePreviousSubjectPairIfPresent(
        paths: ProjectPaths
    ) throws -> PreviousSubjectPair? {
        let output = try observeSubjectPairFile(
            at: paths.isolatedOutputURL,
            maximumBytes: maximumSubjectOutputBytes
        )
        let manifest = try observeSubjectPairFile(
            at: paths.isolationManifestURL,
            maximumBytes: Int64(maximumManifestBytes)
        )
        if output.isMissing, manifest.isMissing {
            return nil
        }
        guard case .privateFile(let outputIdentity) = output,
              case .privateFile(let manifestIdentity) = manifest else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let pair = SubjectPairJournalPair(
            output: outputIdentity,
            manifest: manifestIdentity
        )
        _ = try validateSubjectPair(
            pair,
            manifestURL: paths.isolationManifestURL,
            outputURL: paths.isolatedOutputURL,
            expectedMasks: nil,
            validateUnboundMasks: false,
            paths: paths
        )
        return PreviousSubjectPair(
            identities: pair
        )
    }

    private static func subjectPairRetiredMaskRecords(
        _ authorities: [String: RetiredMaskCleanupAuthority]
    ) throws -> [SubjectPairJournalRetiredMask] {
        try authorities.keys.sorted().map { relativePath in
            guard let authority = authorities[relativePath] else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let identity = try subjectPairJournalIdentity(
                at: authority.url,
                maximumBytes: Int64(maximumMaskBytes)
            )
            let state = authority.state
            guard identity.device == Int64(state.identity.device),
                  identity.inode == UInt64(state.identity.inode),
                  identity.byteCount == Int64(state.byteCount),
                  identity.modifiedSeconds == state.modifiedSeconds,
                  identity.modifiedNanoseconds == state.modifiedNanoseconds else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            return SubjectPairJournalRetiredMask(
                mask: authority.mask,
                identity: identity,
                changedSeconds: state.changedSeconds,
                changedNanoseconds: state.changedNanoseconds
            )
        }
    }

    private static func reconcileSubjectPairTransactionIfPresent(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        beforeRetiredMaskCleanup: () throws -> Void = {}
    ) throws -> SubjectPairReconciliationOutcome? {
        _ = try projectPaths(
            boundTo: projectRootDescriptor,
            expected: paths
        )
        guard let transaction = try loadSubjectPairTransactionIfPresent(
            paths: paths
        ) else {
            return nil
        }
        let document = transaction.document
        let transactionPaths = transaction.paths

        if let previous = document.previousPair {
            try requireTransactionFileAbsentOrOwned(
                transactionPaths.previousOutputURL,
                expected: previous.output,
                maximumBytes: maximumSubjectOutputBytes
            )
            try requireTransactionFileAbsentOrOwned(
                transactionPaths.previousManifestURL,
                expected: previous.manifest,
                maximumBytes: Int64(maximumManifestBytes)
            )
        } else {
            try requireSubjectPairFileAbsent(transactionPaths.previousOutputURL)
            try requireSubjectPairFileAbsent(transactionPaths.previousManifestURL)
        }

        let canonicalOutput = try canonicalSubjectPairFileState(
            at: paths.isolatedOutputURL,
            replacement: document.newPair.output,
            previous: document.previousPair?.output,
            maximumBytes: maximumSubjectOutputBytes
        )
        let canonicalManifest = try canonicalSubjectPairFileState(
            at: paths.isolationManifestURL,
            replacement: document.newPair.manifest,
            previous: document.previousPair?.manifest,
            maximumBytes: Int64(maximumManifestBytes)
        )
        guard canonicalOutput != .foreign,
              canonicalManifest != .foreign else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }

        if canonicalManifest == .replacement
            || canonicalManifest == .damagedReplacement {
            let validated: (artifact: IsolationArtifact, output: ValidatedSplatOutput)
            do {
                guard canonicalOutput == .replacement else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                validated = try validateSubjectPair(
                    document.newPair,
                    manifestURL: paths.isolationManifestURL,
                    outputURL: paths.isolatedOutputURL,
                    expectedMasks: document.newMasks,
                    paths: paths
                )
            } catch {
                return try restorePreviousSubjectPairTransaction(
                    transaction,
                    paths: paths
                )
            }
            try beforeRetiredMaskCleanup()
            let retiredMaskConflict = try finalizeCommittedSubjectPairTransaction(
                transaction,
                committedArtifact: validated.artifact,
                paths: paths
            )
            return .committed(
                validated.artifact,
                validated.output,
                retiredMaskConflict: retiredMaskConflict
            )
        }

        return try restorePreviousSubjectPairTransaction(
            transaction,
            paths: paths
        )
    }

    private static func finalizeCommittedSubjectPairTransaction(
        _ transaction: LoadedSubjectPairTransaction,
        committedArtifact: IsolationArtifact,
        paths: ProjectPaths
    ) throws -> Bool {
        let document = transaction.document
        let transactionPaths = transaction.paths
        guard try canonicalSubjectPairFileState(
            at: paths.isolatedOutputURL,
            replacement: document.newPair.output,
            previous: document.previousPair?.output,
            maximumBytes: maximumSubjectOutputBytes
        ) == .replacement,
        try canonicalSubjectPairFileState(
            at: paths.isolationManifestURL,
            replacement: document.newPair.manifest,
            previous: document.previousPair?.manifest,
            maximumBytes: Int64(maximumManifestBytes)
        ) == .replacement else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try requireSubjectPairFileAbsent(transactionPaths.newOutputURL)
        try requireSubjectPairFileAbsent(transactionPaths.newManifestURL)
        let committedMaskPaths = Set(committedArtifact.masks.map(\.relativePath))
        let retiredToRemove = document.retiredMasks.filter {
            !committedMaskPaths.contains($0.mask.relativePath)
        }
        var hasRemainingRetiredMask = false
        for retired in retiredToRemove {
            let url = try paths.resolveProjectRelativePath(retired.mask.relativePath)
            let observed = try observeSubjectPairFile(
                at: url,
                maximumBytes: Int64(maximumMaskBytes)
            )
            if !observed.isMissing {
                hasRemainingRetiredMask = true
                break
            }
        }
        if hasRemainingRetiredMask {
            guard let previous = document.previousPair else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let previousManifestData = try readSubjectPairFile(
                at: transactionPaths.previousManifestURL,
                expected: previous.manifest,
                maximumBytes: maximumManifestBytes
            )
            try requireStrictSchema(previousManifestData)
            let previousArtifact = try JSONDecoder().decode(
                IsolationArtifact.self,
                from: previousManifestData
            )
            try validateManifest(previousArtifact, paths: paths)
            guard retiredToRemove.allSatisfy({ previousArtifact.masks.contains($0.mask) }) else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
        }
        var retiredMaskConflict = false
        for retired in retiredToRemove {
            if try !removeJournalRetiredMaskIfOwned(retired, paths: paths) {
                retiredMaskConflict = true
            }
        }
        try synchronizeDirectory(paths.isolationMasksURL)
        if let previous = document.previousPair {
            try unlinkSubjectPairFileIfOwned(
                transactionPaths.previousOutputURL,
                expected: previous.output,
                maximumBytes: maximumSubjectOutputBytes
            )
            try unlinkSubjectPairFileIfOwned(
                transactionPaths.previousManifestURL,
                expected: previous.manifest,
                maximumBytes: Int64(maximumManifestBytes)
            )
        }
        try unlinkSubjectPairFileIfOwned(
            transactionPaths.journalURL,
            expected: transaction.journalIdentity,
            maximumBytes: Int64(maximumSubjectPairJournalBytes)
        )
        return retiredMaskConflict
    }

    private static func restorePreviousSubjectPairTransaction(
        _ transaction: LoadedSubjectPairTransaction,
        paths: ProjectPaths
    ) throws -> SubjectPairReconciliationOutcome {
        let document = transaction.document
        let transactionPaths = transaction.paths

        if let previous = document.previousPair {
            let previousOutputURL = try previousSubjectPairFileLocation(
                canonical: paths.isolatedOutputURL,
                backup: transactionPaths.previousOutputURL,
                expected: previous.output,
                maximumBytes: maximumSubjectOutputBytes
            )
            let previousManifestURL = try previousSubjectPairFileLocation(
                canonical: paths.isolationManifestURL,
                backup: transactionPaths.previousManifestURL,
                expected: previous.manifest,
                maximumBytes: Int64(maximumManifestBytes)
            )
            _ = try validateSubjectPair(
                previous,
                manifestURL: previousManifestURL,
                outputURL: previousOutputURL,
                expectedMasks: nil,
                validateUnboundMasks: false,
                paths: paths
            )
        }

        let canonicalManifest = try canonicalSubjectPairFileState(
            at: paths.isolationManifestURL,
            replacement: document.newPair.manifest,
            previous: document.previousPair?.manifest,
            maximumBytes: Int64(maximumManifestBytes)
        )
        switch canonicalManifest {
        case .replacement:
            try unlinkSubjectPairFileIfOwned(
                paths.isolationManifestURL,
                expected: document.newPair.manifest,
                maximumBytes: Int64(maximumManifestBytes)
            )
        case .damagedReplacement:
            try unlinkSubjectPairFileIfSameObject(
                paths.isolationManifestURL,
                expected: document.newPair.manifest,
                maximumBytes: Int64(maximumManifestBytes)
            )
        case .previous, .missing:
            break
        case .foreign:
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }

        let canonicalOutput = try canonicalSubjectPairFileState(
            at: paths.isolatedOutputURL,
            replacement: document.newPair.output,
            previous: document.previousPair?.output,
            maximumBytes: maximumSubjectOutputBytes
        )
        switch canonicalOutput {
        case .replacement:
            try unlinkSubjectPairFileIfOwned(
                paths.isolatedOutputURL,
                expected: document.newPair.output,
                maximumBytes: maximumSubjectOutputBytes
            )
        case .damagedReplacement:
            try unlinkSubjectPairFileIfSameObject(
                paths.isolatedOutputURL,
                expected: document.newPair.output,
                maximumBytes: maximumSubjectOutputBytes
            )
        case .previous, .missing:
            break
        case .foreign:
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }

        if let previous = document.previousPair {
            let currentOutput = try canonicalSubjectPairFileState(
                at: paths.isolatedOutputURL,
                replacement: document.newPair.output,
                previous: previous.output,
                maximumBytes: maximumSubjectOutputBytes
            )
            if currentOutput == .missing {
                try moveSubjectPairFile(
                    from: transactionPaths.previousOutputURL,
                    expected: previous.output,
                    to: paths.isolatedOutputURL
                )
                try synchronizeDirectory(paths.outputURL)
            } else if currentOutput != .previous {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }

            let currentManifest = try canonicalSubjectPairFileState(
                at: paths.isolationManifestURL,
                replacement: document.newPair.manifest,
                previous: previous.manifest,
                maximumBytes: Int64(maximumManifestBytes)
            )
            if currentManifest == .missing {
                try moveSubjectPairFile(
                    from: transactionPaths.previousManifestURL,
                    expected: previous.manifest,
                    to: paths.isolationManifestURL
                )
                try synchronizeDirectory(paths.isolationURL)
            } else if currentManifest != .previous {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            _ = try validateSubjectPair(
                previous,
                manifestURL: paths.isolationManifestURL,
                outputURL: paths.isolatedOutputURL,
                expectedMasks: nil,
                validateUnboundMasks: false,
                paths: paths
            )
        } else {
            try requireSubjectPairFileAbsent(paths.isolatedOutputURL)
            try requireSubjectPairFileAbsent(paths.isolationManifestURL)
        }

        try unlinkSubjectPairFileIfOwned(
            transactionPaths.newOutputURL,
            expected: document.newPair.output,
            maximumBytes: maximumSubjectOutputBytes
        )
        try unlinkSubjectPairFileIfOwned(
            transactionPaths.newManifestURL,
            expected: document.newPair.manifest,
            maximumBytes: Int64(maximumManifestBytes)
        )
        for mask in document.newMasks {
            let url = try paths.resolveProjectRelativePath(mask.relativePath)
            try unlinkSubjectPairFileIfOwned(
                url,
                expected: mask.identity,
                maximumBytes: Int64(maximumMaskBytes)
            )
        }
        try synchronizeDirectory(paths.isolationMasksURL)
        try unlinkSubjectPairFileIfOwned(
            transactionPaths.journalURL,
            expected: transaction.journalIdentity,
            maximumBytes: Int64(maximumSubjectPairJournalBytes)
        )
        return .restored
    }

    private static func validateSubjectPair(
        _ pair: SubjectPairJournalPair,
        manifestURL: URL,
        outputURL: URL,
        expectedMasks: [SubjectPairJournalMask]?,
        validateUnboundMasks: Bool = true,
        paths: ProjectPaths
    ) throws -> (artifact: IsolationArtifact, output: ValidatedSplatOutput) {
        let manifestData = try readSubjectPairFile(
            at: manifestURL,
            expected: pair.manifest,
            maximumBytes: maximumManifestBytes
        )
        try requireStrictSchema(manifestData)
        let artifact = try JSONDecoder().decode(
            IsolationArtifact.self,
            from: manifestData
        )
        try validateManifest(artifact, paths: paths)

        if let expectedMasks {
            let expectedPaths = expectedMasks.map(\.relativePath)
            guard expectedMasks.count == artifact.masks.count,
                  Set(expectedPaths).count == expectedMasks.count else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            let expectedByPath = Dictionary(
                uniqueKeysWithValues: expectedMasks.map {
                    ($0.relativePath, $0.identity)
                }
            )
            for mask in artifact.masks {
                guard let expected = expectedByPath[mask.relativePath] else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                let maskURL = try paths.resolveProjectRelativePath(mask.relativePath)
                guard try observeSubjectPairFile(
                    at: maskURL,
                    maximumBytes: Int64(maximumMaskBytes)
                ).owns(expected) else {
                    throw SubjectIsolationArtifactStoreError.publicationConflict
                }
                try validateMask(mask, at: maskURL)
                guard try observeSubjectPairFile(
                    at: maskURL,
                    maximumBytes: Int64(maximumMaskBytes)
                ).owns(expected) else {
                    throw SubjectIsolationArtifactStoreError.publicationConflict
                }
            }
        } else if validateUnboundMasks {
            for mask in artifact.masks {
                try validateMask(
                    mask,
                    at: try paths.resolveProjectRelativePath(mask.relativePath)
                )
            }
        }

        let evidence = try withExpectedSubjectPairFileDescriptor(
            at: outputURL,
            expected: pair.output,
            maximumBytes: maximumSubjectOutputBytes
        ) { descriptor in
            try ProjectArtifactValidator.validatedPlyEvidence(
                descriptor: descriptor,
                label: outputURL.lastPathComponent
            )
        }
        try requireOutput(evidence, matches: artifact.output)
        guard try readSubjectPairFile(
            at: manifestURL,
            expected: pair.manifest,
            maximumBytes: maximumManifestBytes
        ) == manifestData else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return (
            artifact,
            ValidatedSplatOutput(
                variant: .subject,
                url: paths.isolatedOutputURL,
                sha256: evidence.sha256,
                byteCount: evidence.byteCount,
                gaussianCount: evidence.vertexCount,
                sceneBounds: evidence.sceneBounds
            )
        )
    }

    private static func loadSubjectPairTransactionIfPresent(
        paths: ProjectPaths
    ) throws -> LoadedSubjectPairTransaction? {
        do {
            let outputNames = try subjectPairReservedNames(in: paths.outputURL)
            let isolationNames = try subjectPairReservedNames(in: paths.isolationURL)
            if outputNames.isEmpty, isolationNames.isEmpty {
                return nil
            }
            let journalNames = isolationNames.filter {
                $0.hasPrefix(subjectPairJournalPrefix) && $0.hasSuffix(".json")
            }
            if journalNames.isEmpty {
                // Canonical files are never moved before the final journal is
                // durable. Preserve pre-activation build residue as untrusted,
                // but do not let it hide an otherwise valid canonical pair.
                return nil
            }
            guard journalNames.count == 1, let journalName = journalNames.first else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let token = String(
                journalName.dropFirst(subjectPairJournalPrefix.count).dropLast(5)
            )
            guard let transactionID = UUID(uuidString: token),
                  transactionID.uuidString.lowercased() == token else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let transactionPaths = SubjectPairTransactionPaths(
                paths: paths,
                transactionID: transactionID
            )
            let transactionOutputNames = outputNames.filter { $0.contains(token) }
            let transactionIsolationNames = isolationNames.filter { $0.contains(token) }
            guard transactionOutputNames.isSubset(
                    of: transactionPaths.reservedOutputNames
                  ),
                  transactionIsolationNames.isSubset(
                    of: transactionPaths.reservedIsolationNames
                  ) else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let journalIdentity = try subjectPairJournalIdentity(
                at: transactionPaths.journalURL,
                maximumBytes: Int64(maximumSubjectPairJournalBytes)
            )
            let data = try readSubjectPairFile(
                at: transactionPaths.journalURL,
                expected: journalIdentity,
                maximumBytes: maximumSubjectPairJournalBytes
            )
            try StrictJSONDocument.validate(
                data,
                maximumBytes: maximumSubjectPairJournalBytes
            )
            try requireStrictSubjectPairJournalSchema(data)
            let document = try JSONDecoder().decode(
                SubjectPairJournalDocument.self,
                from: data
            )
            try validateSubjectPairJournal(
                document,
                transaction: transactionPaths,
                paths: paths
            )
            return LoadedSubjectPairTransaction(
                document: document,
                paths: transactionPaths,
                journalIdentity: journalIdentity
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func validateSubjectPairJournal(
        _ document: SubjectPairJournalDocument,
        transaction: SubjectPairTransactionPaths,
        paths: ProjectPaths
    ) throws {
        guard document.schemaVersion == 1,
              document.transactionID == transaction.transactionID,
              document.paths == transaction.journalPaths,
              document.newPair.output.isValid(
                maximumBytes: maximumSubjectOutputBytes
              ),
              document.newPair.manifest.isValid(
                maximumBytes: Int64(maximumManifestBytes)
              ),
              !document.newMasks.isEmpty,
              document.newMasks.count <= IsolationArtifact.maximumMaskCount,
              document.retiredMasks.count <= IsolationArtifact.maximumMaskCount else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        if let previous = document.previousPair {
            guard previous.output.isValid(
                    maximumBytes: maximumSubjectOutputBytes
                  ),
                  previous.manifest.isValid(
                    maximumBytes: Int64(maximumManifestBytes)
                  ) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
        var maskPaths = Set<String>()
        for mask in document.newMasks {
            guard maskPaths.insert(mask.relativePath).inserted,
                  mask.identity.isValid(maximumBytes: Int64(maximumMaskBytes)) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            let resolved = try paths.resolveProjectRelativePath(mask.relativePath)
            guard isCanonicalMaskRelativePath(
                mask.relativePath,
                resolved: resolved
            ) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
        var retiredPaths = Set<String>()
        for retired in document.retiredMasks {
            guard retiredPaths.insert(retired.mask.relativePath).inserted,
                  retired.identity.isValid(
                    maximumBytes: Int64(maximumMaskBytes)
                  ),
                  (0..<1_000_000_000).contains(retired.changedNanoseconds) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            let resolved = try paths.resolveProjectRelativePath(
                retired.mask.relativePath
            )
            guard isCanonicalMaskRelativePath(
                retired.mask.relativePath,
                resolved: resolved
            ) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
        if document.previousPair == nil, !document.retiredMasks.isEmpty {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    @discardableResult
    private static func writeSubjectPairJournal(
        _ document: SubjectPairJournalDocument,
        transaction: SubjectPairTransactionPaths
    ) throws -> SubjectPairJournalFileIdentity {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard !data.isEmpty, data.count <= maximumSubjectPairJournalBytes else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try StrictJSONDocument.validate(
            data,
            maximumBytes: maximumSubjectPairJournalBytes
        )
        try requireStrictSubjectPairJournalSchema(data)

        var pending: OwnedFile?
        var installed: OwnedFile?
        defer {
            if let pending {
                try? removeOwnedFileIfPresent(pending)
            }
            if let installed {
                try? removeOwnedFileIfPresent(installed)
            }
        }
        let pendingIdentity = try writePrivateFile(
            data,
            to: transaction.pendingJournalURL
        )
        pending = OwnedFile(
            url: transaction.pendingJournalURL,
            identity: pendingIdentity
        )
        try renameExclusive(
            transaction.pendingJournalURL,
            to: transaction.journalURL
        )
        installed = OwnedFile(
            url: transaction.journalURL,
            identity: pendingIdentity
        )
        pending = nil
        try synchronizeDirectory(transaction.journalURL.deletingLastPathComponent())
        let journalIdentity = try subjectPairJournalIdentity(
            at: transaction.journalURL,
            maximumBytes: Int64(maximumSubjectPairJournalBytes)
        )
        guard journalIdentity.device == Int64(pendingIdentity.device),
              journalIdentity.inode == UInt64(pendingIdentity.inode) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        installed = nil
        return journalIdentity
    }

    private static func requireStrictSubjectPairJournalSchema(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireKeys(
            root,
            required: [
                "schemaVersion", "transactionID", "paths", "newPair", "newMasks",
                "retiredMasks",
            ],
            optional: ["previousPair"]
        )
        try requireObject(
            root["paths"],
            keys: [
                "canonicalOutput", "canonicalManifest", "newOutput", "newManifest",
                "previousOutput", "previousManifest",
            ]
        )
        try requireSubjectPairJournalPairObject(root["newPair"])
        if let previous = root["previousPair"] {
            try requireSubjectPairJournalPairObject(previous)
        }
        guard let masks = root["newMasks"] as? [[String: Any]] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        for mask in masks {
            try requireKeys(mask, required: ["relativePath", "identity"])
            try requireSubjectPairJournalIdentityObject(mask["identity"])
        }
        guard let retiredMasks = root["retiredMasks"] as? [[String: Any]] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        for retired in retiredMasks {
            try requireKeys(
                retired,
                required: [
                    "mask", "identity", "changedSeconds", "changedNanoseconds",
                ]
            )
            try requireSubjectPairJournalIdentityObject(retired["identity"])
            try requireObject(
                retired["mask"],
                keys: [
                    "relativePath", "imageIdentity", "imageSHA256", "maskSHA256",
                    "pixelWidth", "pixelHeight", "instanceLabels",
                ]
            )
        }
    }

    private static func requireSubjectPairJournalPairObject(_ value: Any?) throws {
        try requireObject(value, keys: ["output", "manifest"])
        guard let object = value as? [String: Any] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireSubjectPairJournalIdentityObject(object["output"])
        try requireSubjectPairJournalIdentityObject(object["manifest"])
    }

    private static func requireSubjectPairJournalIdentityObject(_ value: Any?) throws {
        try requireObject(
            value,
            keys: [
                "device", "inode", "byteCount", "owner", "mode", "linkCount",
                "birthSeconds", "birthNanoseconds", "modifiedSeconds",
                "modifiedNanoseconds",
            ]
        )
    }

    private static func reachSubjectPairCheckpoint(
        _ checkpoint: SubjectPairPublicationCheckpoint,
        crashAfter: SubjectPairPublicationCheckpoint?
    ) throws {
        if crashAfter == checkpoint {
            throw SimulatedSubjectPairProcessExit()
        }
    }

    private static func loadManifest(paths: ProjectPaths) throws -> IsolationArtifact {
        try loadManifest(from: paths.isolationManifestURL, paths: paths)
    }

    private static func loadManifest(
        paths: ProjectPaths,
        projectRootDescriptor: Int32
    ) throws -> IsolationArtifact {
        let data = try readBoundProjectFile(
            relativePath: "Isolation/isolation_manifest.json",
            projectRootDescriptor: projectRootDescriptor,
            maximumBytes: maximumManifestBytes
        )
        guard !data.isEmpty else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireStrictSchema(data)
        let artifact = try JSONDecoder().decode(IsolationArtifact.self, from: data)
        try validateManifest(artifact, paths: paths)
        return artifact
    }

    private static func loadManifest(
        from url: URL,
        paths: ProjectPaths
    ) throws -> IsolationArtifact {
        if url == paths.isolationManifestURL {
            _ = try paths.validateReservedProjectPath(
                url,
                relativePath: "Isolation/isolation_manifest.json"
            )
        } else {
            let relative = try paths.projectRelativePath(for: url)
            guard relative.hasPrefix("Isolation/.isolation_manifest."),
                  relative.hasSuffix(".pending")
                    || relative.contains(".previous.") else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        guard !data.isEmpty else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireStrictSchema(data)
        let artifact = try JSONDecoder().decode(IsolationArtifact.self, from: data)
        try validateManifest(artifact, paths: paths)
        guard try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        ) == data else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return artifact
    }

    private static func validateManifest(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths
    ) throws {
        let dataset = artifact.dataset
        let selected = artifact.selectedViewIdentities
        let heldOut = artifact.heldOutViewIdentities
        let knownViews = Set(dataset.selectedImageOrder)
        guard artifact.schemaVersion == IsolationArtifact.currentSchemaVersion,
              let sourcePublicationID = artifact.sourcePublicationID,
              sourcePublicationID != zeroUUID,
              isSHA256(artifact.sourcePlySHA256),
              isSHA256(artifact.trainingManifestSHA256),
              isSHA256(dataset.inputDigest),
              isSHA256(dataset.geometryDigest),
              isSHA256(dataset.selectedFramesDigest),
              !dataset.selectedImageOrder.isEmpty,
              Set(dataset.selectedImageOrder).count == dataset.selectedImageOrder.count,
              dataset.selectedImageOrder.allSatisfy(isSafeIdentity),
              !artifact.masks.isEmpty,
              artifact.masks.count <= IsolationArtifact.maximumMaskCount,
              !artifact.toolchainBuildIdentity.isEmpty,
              artifact.toolchainBuildIdentity.utf8.count <= maximumIdentityBytes,
              isSHA256(artifact.nativeExecutableSHA256),
              artifact.visionRequestRevision > 0,
              !selected.isEmpty,
              Set(selected).count == selected.count,
              Set(heldOut).count == heldOut.count,
              Set(selected).isDisjoint(with: Set(heldOut)),
              selected.allSatisfy(knownViews.contains),
              heldOut.allSatisfy(knownViews.contains),
              validPolicy(artifact.policy),
              validMetrics(artifact.metrics, policy: artifact.policy),
              artifact.output.identity != zeroUUID,
              artifact.output.relativePath == "Output/isolated.ply",
              isSHA256(artifact.output.sha256),
              artifact.output.byteCount > 0,
              artifact.output.gaussianCount > 0,
              artifact.output.sceneBounds.isValid else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        _ = try paths.resolveProjectRelativePath(artifact.output.relativePath)

        if let anchor = artifact.subjectAnchor {
            guard knownViews.contains(anchor.imageIdentity),
                  anchor.instanceLabel > 0,
                  anchor.normalizedX.isFinite,
                  anchor.normalizedY.isFinite,
                  (0...1).contains(anchor.normalizedX),
                  (0...1).contains(anchor.normalizedY) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }

        var maskPaths = Set<String>()
        var maskViews = Set<String>()
        for mask in artifact.masks {
            guard maskPaths.insert(mask.relativePath).inserted,
                  maskViews.insert(mask.imageIdentity).inserted,
                  knownViews.contains(mask.imageIdentity),
                  isSHA256(mask.imageSHA256),
                  isSHA256(mask.maskSHA256),
                  mask.pixelWidth > 0,
                  mask.pixelWidth <= IsolationArtifact.maximumMaskDimension,
                  mask.pixelHeight > 0,
                  mask.pixelHeight <= IsolationArtifact.maximumMaskDimension,
                  mask.pixelWidth.multipliedReportingOverflow(
                    by: mask.pixelHeight
                  ).overflow == false,
                  mask.pixelWidth * mask.pixelHeight
                    <= IsolationArtifact.maximumDecodedMaskPixelCount,
                  mask.instanceLabels.allSatisfy({ $0 > 0 }),
                  mask.instanceLabels == mask.instanceLabels.sorted(),
                  Set(mask.instanceLabels).count == mask.instanceLabels.count else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            let resolved = try paths.resolveProjectRelativePath(mask.relativePath)
            guard isCanonicalMaskRelativePath(
                mask.relativePath,
                resolved: resolved
            ) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
    }

    private static func isCanonicalMaskRelativePath(
        _ relativePath: String,
        resolved: URL
    ) -> Bool {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.count == 3
            && components[0] == "Isolation"
            && components[1] == "masks"
            && !components[2].isEmpty
            && resolved.pathExtension.lowercased() == "png"
    }

    private static func staleReason(
        for artifact: IsolationArtifact,
        paths: ProjectPaths,
        publishedResult: ValidatedPublishedResult,
        projectRootDescriptor: Int32? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> IsolationArtifactStaleReason? {
        try throwIfCancelled(shouldCancel)
        let source = publishedResult.outputEvidence
        guard source.sha256 == artifact.sourcePlySHA256 else {
            return .sourceOutput
        }
        let trainingData: Data
        if let projectRootDescriptor {
            trainingData = try readBoundProjectFile(
                relativePath: "Training/training_manifest.json",
                projectRootDescriptor: projectRootDescriptor,
                maximumBytes: maximumManifestBytes,
                shouldCancel: shouldCancel
            )
        } else {
            trainingData = try BoundedFileReader.readRegularFile(
                at: paths.trainingManifestURL,
                maximumBytes: maximumManifestBytes,
                shouldCancel: shouldCancel
            )
        }
        guard sha256(trainingData) == artifact.trainingManifestSHA256 else {
            return .trainingManifest
        }
        let training: TrainingArtifact
        if projectRootDescriptor != nil {
            training = try JSONDecoder().decode(TrainingArtifact.self, from: trainingData)
        } else {
            training = try TrainingArtifactStore.loadManifest(
                from: paths.trainingManifestURL,
                projectPaths: paths
            )
        }
        guard publishedResult.receipt.lineage.trainingManifestSHA256 == sha256(trainingData),
              publishedResult.receipt.lineage.trainingInputDigest == training.inputDigest,
              publishedResult.receipt.lineage.trainingGeometryDigest == training.geometryDigest,
              training.outputSHA256 == source.sha256,
              training.outputBytes == Int64(exactly: source.byteCount),
              training.gaussianCount == source.vertexCount,
              training.sceneBounds.map({
                  SplatSceneBoundsCalculator.matches($0, source.sceneBounds)
              }) == true else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        guard artifact.sourcePublicationID == publishedResult.receipt.publicationID else {
            return .sourceOutput
        }
        guard artifact.dataset.inputDigest == training.inputDigest,
              artifact.dataset.geometryDigest == training.geometryDigest,
              artifact.dataset.selectedFramesDigest
                == training.datasetDerivation.sourceSelectedFramesDigest,
              artifact.dataset.selectedImageOrder
                == training.datasetDerivation.registeredImageNames else {
            return .datasetIdentity
        }
        let imageDirectory = try paths.resolveProjectRelativePath(
            "Training/msplat_dataset/images"
        )
        for mask in artifact.masks {
            try throwIfCancelled(shouldCancel)
            let imageSHA256: String
            if let projectRootDescriptor {
                imageSHA256 = try sha256BoundProjectFile(
                    relativePath: "Training/msplat_dataset/images/\(mask.imageIdentity)",
                    projectRootDescriptor: projectRootDescriptor,
                    maximumBytes: 512 * 1_048_576,
                    shouldCancel: shouldCancel
                )
            } else {
                let imageURL = imageDirectory.appendingPathComponent(mask.imageIdentity)
                imageSHA256 = try GeometryArtifactStore.sha256(
                    of: imageURL,
                    maximumBytes: 512 * 1_048_576,
                    shouldCancel: shouldCancel
                )
            }
            guard imageSHA256 == mask.imageSHA256 else {
                return .datasetIdentity
            }
        }
        return nil
    }

    private static func validatedPublishedResult(
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        beforeCanonicalPlyValidation: @escaping @Sendable () -> Void = {}
    ) throws -> ValidatedPublishedResult {
        let metadata: ProjectMetadata
        if let projectRootDescriptor {
            metadata = try ProjectMetadataStore.load(
                fromProjectRootDescriptor: projectRootDescriptor
            )
        } else {
            metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        }
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in
            beforeCanonicalPlyValidation()
        }
        switch try PublishedResultPairStore.resolve(
            projectPaths: paths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: { false }
        ) {
        case .available(let result):
            guard result.receipt.projectID == metadata.id else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            return result
        case .unavailable, .conflict:
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func receiptMatchesCanonicalAuthority(
        _ receipt: PublishedSplatReceipt,
        expected: PublishedSplatReceipt
    ) -> Bool {
        let presentation = receipt.presentation
        let expectedPresentation = expected.presentation
        return receipt.schemaVersion == expected.schemaVersion
            && receipt.publicationID == expected.publicationID
            && receipt.projectID == expected.projectID
            && receipt.publishedAt == expected.publishedAt
            && receipt.outputPath == expected.outputPath
            && receipt.outputEvidence == expected.outputEvidence
            && receipt.lineage == expected.lineage
            && presentation.requestedRunOptions
                == expectedPresentation.requestedRunOptions
            && presentation.resolvedRunPlan
                == expectedPresentation.resolvedRunPlan
            && presentation.reconstruction == expectedPresentation.reconstruction
            && presentation.orientation == expectedPresentation.orientation
            && presentation.stageTimings == expectedPresentation.stageTimings
            && presentation.autoTunerSnapshot
                == expectedPresentation.autoTunerSnapshot
            && presentation.trainerVersion == expectedPresentation.trainerVersion
            && presentation.runtimeVersion == expectedPresentation.runtimeVersion
            && presentation.completedIteration
                == expectedPresentation.completedIteration
            && presentation.trainingDurationSeconds
                == expectedPresentation.trainingDurationSeconds
    }

    private static func validatePublishedFiles(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> ValidatedSplatOutput {
        for mask in artifact.masks {
            if let projectRootDescriptor {
                let data = try readBoundProjectFile(
                    relativePath: mask.relativePath,
                    projectRootDescriptor: projectRootDescriptor,
                    maximumBytes: maximumMaskBytes,
                    shouldCancel: shouldCancel
                )
                try validateMaskData(
                    mask,
                    data: data,
                    shouldCancel: shouldCancel
                )
            } else {
                try validateMask(
                    mask,
                    at: try paths.resolveProjectRelativePath(mask.relativePath),
                    shouldCancel: shouldCancel
                )
            }
        }
        return try validateSubjectOutput(
            artifact,
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            shouldCancel: shouldCancel
        )
    }

    private static func validateSubjectOutput(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> ValidatedSplatOutput {
        let evidence: ValidatedPlyArtifactEvidence
        if let projectRootDescriptor {
            evidence = try withBoundProjectFileDescriptor(
                relativePath: "Output/isolated.ply",
                projectRootDescriptor: projectRootDescriptor,
                maximumBytes: Int.max
            ) { descriptor, _ in
                try ProjectArtifactValidator.validatedPlyEvidence(
                    descriptor: descriptor,
                    label: "isolated.ply",
                    shouldCancel: shouldCancel
                )
            }
        } else {
            evidence = try ProjectArtifactValidator.validatedPlyEvidence(
                at: paths.isolatedOutputURL,
                shouldCancel: shouldCancel
            )
        }
        try requireOutput(evidence, matches: artifact.output)
        return ValidatedSplatOutput(
            variant: .subject,
            url: paths.isolatedOutputURL,
            sha256: evidence.sha256,
            byteCount: evidence.byteCount,
            gaussianCount: evidence.vertexCount,
            sceneBounds: evidence.sceneBounds
        )
    }

    private static func validateMask(
        _ mask: IsolationArtifact.Mask,
        at url: URL,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        beforeDecode: () -> Void = {}
    ) throws {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumMaskBytes,
            shouldCancel: shouldCancel
        )
        try validateMaskData(
            mask,
            data: data,
            shouldCancel: shouldCancel,
            beforeDecode: beforeDecode
        )
    }

    private static func validateMaskData(
        _ mask: IsolationArtifact.Mask,
        data: Data,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        beforeDecode: () -> Void = {}
    ) throws {
        try throwIfCancelled(shouldCancel)
        guard try sha256(data, shouldCancel: shouldCancel) == mask.maskSHA256,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue == mask.pixelWidth,
              height.intValue == mask.pixelHeight,
              width.intValue > 0,
              width.intValue <= IsolationArtifact.maximumMaskDimension,
              height.intValue > 0,
              height.intValue <= IsolationArtifact.maximumMaskDimension,
              width.intValue.multipliedReportingOverflow(by: height.intValue).overflow == false,
              width.intValue * height.intValue
                <= IsolationArtifact.maximumDecodedMaskPixelCount else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try throwIfCancelled(shouldCancel)
        beforeDecode()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == mask.pixelWidth,
              image.height == mask.pixelHeight,
              image.bitsPerComponent == 8,
              image.colorSpace?.model == .monochrome,
              try hasExactlyDeclaredInstanceLabels(
                image,
                declared: mask.instanceLabels,
                shouldCancel: shouldCancel
              ) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func hasExactlyDeclaredInstanceLabels(
        _ image: CGImage,
        declared: [UInt8],
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        guard image.bitsPerPixel == 8,
              image.bytesPerRow >= image.width,
              let data = image.dataProvider?.data else {
            return false
        }
        let bytes = CFDataGetBytePtr(data)
        guard let bytes else { return false }
        var observed = Set<UInt8>()
        for row in 0..<image.height {
            try throwIfCancelled(shouldCancel)
            let rowStart = row * image.bytesPerRow
            for column in 0..<image.width {
                let value = bytes[rowStart + column]
                if value != 0 {
                    observed.insert(value)
                }
            }
        }
        return observed == Set(declared)
    }

#if DEBUG
    static func test_withIsolationLock(
        paths: ProjectPaths,
        shouldCancel: @escaping @Sendable () -> Bool,
        onProcessLockContention: @escaping @Sendable () -> Void = {},
        onFileLockContention: @escaping @Sendable () -> Void = {},
        _ body: () throws -> Void = {}
    ) throws {
        try withIsolationLock(
            paths: paths,
            shouldCancel: shouldCancel,
            onProcessLockContention: onProcessLockContention,
            onFileLockContention: onFileLockContention
        ) { _ in try body() }
    }

    static func test_withIsolationLock(
        paths: ProjectPaths,
        projectRootDescriptor: Int32,
        shouldCancel: @escaping @Sendable () -> Bool,
        didBindProjectRoot: @escaping (Int32) throws -> Void
    ) throws {
        try withIsolationLock(
            paths: paths,
            projectRootDescriptor: projectRootDescriptor,
            shouldCancel: shouldCancel,
            didBindProjectRoot: didBindProjectRoot
        ) { _ in }
    }

    static func test_validateMask(
        _ mask: IsolationArtifact.Mask,
        at url: URL,
        shouldCancel: @escaping @Sendable () -> Bool,
        beforeDecode: () -> Void = {}
    ) throws {
        try validateMask(
            mask,
            at: url,
            shouldCancel: shouldCancel,
            beforeDecode: beforeDecode
        )
    }
#endif

    private static func requireOutput(
        _ evidence: ValidatedPlyArtifactEvidence,
        matches identity: IsolationArtifact.OutputIdentity
    ) throws {
        guard evidence.sha256 == identity.sha256,
              evidence.byteCount == identity.byteCount,
              evidence.vertexCount == identity.gaussianCount,
              SplatSceneBoundsCalculator.matches(
                evidence.sceneBounds,
                identity.sceneBounds
              ) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func removeValidated(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        transactionID: UUID = UUID(),
        crashAfter: SubjectPairRetirementCheckpoint? = nil,
        willQuarantineOwnedEntry: (String, String) throws -> Void = { _, _ in },
        willUnlinkQuarantinedEntry: (String, String) throws -> Void = { _, _ in }
    ) throws {
        let files = try validatedSubjectFiles(
            artifact,
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        let currentManifest = if let projectRootDescriptor {
            try loadManifest(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        } else {
            try loadManifest(paths: paths)
        }
        guard currentManifest == artifact else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try requireOwnedFile(files.manifest)
        try requireOwnedFile(files.output)
        for mask in files.masks {
            try requireOwnedFile(mask)
        }
        let retirementPaths = SubjectPairRetirementPaths(
            paths: paths,
            transactionID: transactionID
        )
        try requireSubjectPairFileAbsent(retirementPaths.journalURL)
        try requireSubjectPairFileAbsent(retirementPaths.pendingJournalURL)
        let outputIdentity = try subjectPairJournalIdentity(
            at: paths.isolatedOutputURL,
            maximumBytes: maximumSubjectOutputBytes
        )
        let manifestIdentity = try subjectPairJournalIdentity(
            at: paths.isolationManifestURL,
            maximumBytes: Int64(maximumManifestBytes)
        )
        guard outputIdentity.device == Int64(files.output.identity.device),
              outputIdentity.inode == UInt64(files.output.identity.inode),
              manifestIdentity.device == Int64(files.manifest.identity.device),
              manifestIdentity.inode == UInt64(files.manifest.identity.inode) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let masks = try zip(artifact.masks, files.masks).map { pair in
            let (mask, file) = pair
            let identity = try subjectPairJournalIdentity(
                at: file.url,
                maximumBytes: Int64(maximumMaskBytes)
            )
            guard identity.device == Int64(file.identity.device),
                  identity.inode == UInt64(file.identity.inode) else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            return SubjectPairJournalMask(
                relativePath: mask.relativePath,
                identity: identity
            )
        }.sorted { $0.relativePath < $1.relativePath }
        let finalManifest = if let projectRootDescriptor {
            try loadManifest(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        } else {
            try loadManifest(paths: paths)
        }
        guard finalManifest == artifact else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let document = SubjectPairRetirementJournalDocument(
            schemaVersion: 1,
            transactionID: transactionID,
            paths: retirementPaths.journalPaths,
            output: outputIdentity,
            manifest: manifestIdentity,
            masks: masks
        )
        _ = try writeSubjectPairRetirementJournal(
            document,
            retirement: retirementPaths
        )
        try reachSubjectPairRetirementCheckpoint(
            .journalActivated,
            crashAfter: crashAfter
        )
        guard let retirement = try loadSubjectPairRetirementIfPresent(
            paths: paths
        ), retirement.document == document else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try completeSubjectPairRetirement(
            retirement,
            paths: paths,
            crashAfter: crashAfter,
            willQuarantineOwnedEntry: willQuarantineOwnedEntry,
            willUnlinkQuarantinedEntry: willUnlinkQuarantinedEntry
        )
    }

    private static func validatedSubjectFiles(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths,
        projectRootDescriptor: Int32? = nil
    ) throws -> ValidatedSubjectFiles {
        _ = try validatePublishedFiles(
            artifact,
            paths: paths,
            projectRootDescriptor: projectRootDescriptor
        )
        let manifest = OwnedFile(
            url: paths.isolationManifestURL,
            identity: try privateRegularFileIdentity(
                at: paths.isolationManifestURL,
                relativePath: "Isolation/isolation_manifest.json",
                projectRootDescriptor: projectRootDescriptor
            )
        )
        let output = OwnedFile(
            url: paths.isolatedOutputURL,
            identity: try privateRegularFileIdentity(
                at: paths.isolatedOutputURL,
                relativePath: "Output/isolated.ply",
                projectRootDescriptor: projectRootDescriptor
            )
        )
        let masks = try artifact.masks.map { mask in
            let url = try paths.resolveProjectRelativePath(mask.relativePath)
            return OwnedFile(
                url: url,
                identity: try privateRegularFileIdentity(
                    at: url,
                    relativePath: mask.relativePath,
                    projectRootDescriptor: projectRootDescriptor
                )
            )
        }
        let currentManifest = if let projectRootDescriptor {
            try loadManifest(
                paths: paths,
                projectRootDescriptor: projectRootDescriptor
            )
        } else {
            try loadManifest(paths: paths)
        }
        guard currentManifest == artifact else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return ValidatedSubjectFiles(
            manifest: manifest,
            output: output,
            masks: masks
        )
    }

    private static func removeJournalRetiredMaskIfOwned(
        _ retired: SubjectPairJournalRetiredMask,
        paths: ProjectPaths
    ) throws -> Bool {
        let url = try paths.resolveProjectRelativePath(retired.mask.relativePath)
        let observed = try observeSubjectPairFile(
            at: url,
            maximumBytes: Int64(maximumMaskBytes)
        )
        if observed.isMissing { return true }
        guard observed.owns(retired.identity) else {
            return false
        }
        let before = try stableFileState(at: url)
        guard subjectPairStableState(before, matches: retired) else {
            return false
        }
        do {
            try validateMask(retired.mask, at: url)
        } catch {
            return false
        }
        let after = try stableFileState(at: url)
        guard before == after,
              subjectPairStableState(after, matches: retired),
              try observeSubjectPairFile(
                at: url,
                maximumBytes: Int64(maximumMaskBytes)
              ).owns(retired.identity) else {
            return false
        }
        try unlinkSubjectPairFileIfOwned(
            url,
            expected: retired.identity,
            maximumBytes: Int64(maximumMaskBytes)
        )
        return true
    }

    private static func subjectPairStableState(
        _ state: StableFileState,
        matches retired: SubjectPairJournalRetiredMask
    ) -> Bool {
        retired.identity.device == Int64(state.identity.device)
            && retired.identity.inode == UInt64(state.identity.inode)
            && retired.identity.byteCount == Int64(state.byteCount)
            && retired.identity.modifiedSeconds == state.modifiedSeconds
            && retired.identity.modifiedNanoseconds == state.modifiedNanoseconds
            && retired.changedSeconds == state.changedSeconds
            && retired.changedNanoseconds == state.changedNanoseconds
    }

    private static func captureRetiredMaskCleanupAuthorities(
        paths: ProjectPaths
    ) -> [String: RetiredMaskCleanupAuthority] {
        do {
            let artifact = try loadManifest(paths: paths)
            try validateManifest(artifact, paths: paths)
            var authorities: [String: RetiredMaskCleanupAuthority] = [:]
            authorities.reserveCapacity(artifact.masks.count)
            for mask in artifact.masks {
                let url = try paths.resolveProjectRelativePath(mask.relativePath)
                let before = try stableFileState(at: url)
                try validateMask(mask, at: url)
                guard try stableFileState(at: url) == before else {
                    throw SubjectIsolationArtifactStoreError.publicationConflict
                }
                authorities[mask.relativePath] = RetiredMaskCleanupAuthority(
                    mask: mask,
                    url: url,
                    state: before
                )
            }
            guard try loadManifest(paths: paths) == artifact else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            return authorities
        } catch {
            return [:]
        }
    }

    private static func validateStagingLocation(
        output: URL,
        masks: URL,
        paths: ProjectPaths
    ) throws {
        let outputRelative = try paths.projectRelativePath(for: output)
        let masksRelative = try paths.projectRelativePath(for: masks)
        let outputParts = outputRelative.split(separator: "/")
        let maskParts = masksRelative.split(separator: "/")
        guard outputParts.count == 4,
              outputParts[0] == "Isolation",
              outputParts[1] == "staging",
              UUID(uuidString: String(outputParts[2])) != nil,
              outputParts[3] == "isolated.ply",
              maskParts.count == 4,
              maskParts[0] == "Isolation",
              maskParts[1] == "staging",
              maskParts[2] == outputParts[2],
              maskParts[3] == "masks" else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func stagedMaskFiles(at directory: URL) throws -> [URL] {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func encodedManifest(_ artifact: IsolationArtifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireStrictSchema(data)
        return data
    }

    private static func requireStrictSchema(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireKeys(
            root,
            required: [
                "schemaVersion", "sourcePublicationID", "sourcePlySHA256",
                "trainingManifestSHA256",
                "dataset", "masks", "toolchainBuildIdentity",
                "nativeExecutableSHA256", "visionRequestRevision",
                "selectedViewIdentities", "heldOutViewIdentities", "policy",
                "metrics", "output",
            ],
            optional: ["subjectAnchor"]
        )
        try requireObject(
            root["dataset"],
            keys: [
                "inputDigest", "geometryDigest", "selectedFramesDigest",
                "selectedImageOrder",
            ]
        )
        guard let masks = root["masks"] as? [[String: Any]] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        for mask in masks {
            try requireKeys(
                mask,
                required: [
                    "relativePath", "imageIdentity", "imageSHA256", "maskSHA256",
                    "pixelWidth", "pixelHeight", "instanceLabels",
                ]
            )
        }
        try requireObject(
            root["policy"],
            keys: [
                "version", "minimumMaskConfidence", "minimumHeldOutMedianIoU",
                "minimumHeldOutFirstQuartileIoU",
                "minimumRetainedGaussianFraction", "maximumRetainedGaussianFraction",
            ]
        )
        try requireObject(
            root["metrics"],
            required: ["meanMaskConfidence", "retainedGaussianFraction"],
            optional: [
                "heldOutMeanIoU", "heldOutMedianIoU", "heldOutFirstQuartileIoU",
            ]
        )
        try requireObject(
            root["output"],
            keys: [
                "identity", "relativePath", "sha256", "byteCount",
                "gaussianCount", "sceneBounds",
            ]
        )
        if let output = root["output"] as? [String: Any] {
            try requireObject(output["sceneBounds"], keys: ["center", "radius"])
            if let bounds = output["sceneBounds"] as? [String: Any] {
                try requireObject(bounds["center"], keys: ["x", "y", "z"])
            }
        }
        if let anchor = root["subjectAnchor"] {
            if !(anchor is NSNull) {
                try requireObject(
                    anchor,
                    keys: ["imageIdentity", "instanceLabel", "normalizedX", "normalizedY"]
                )
            }
        }
    }

    private static func requireObject(_ value: Any?, keys: Set<String>) throws {
        try requireObject(value, required: keys, optional: [])
    }

    private static func requireObject(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String>
    ) throws {
        guard let object = value as? [String: Any] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireKeys(object, required: required, optional: optional)
    }

    private static func requireKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual),
              actual.isSubset(of: required.union(optional)) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func validPolicy(_ policy: IsolationArtifact.Policy) -> Bool {
        policy.version > 0
            && validUnitInterval(policy.minimumMaskConfidence)
            && validUnitInterval(policy.minimumHeldOutMedianIoU)
            && validUnitInterval(policy.minimumHeldOutFirstQuartileIoU)
            && policy.minimumRetainedGaussianFraction.isFinite
            && policy.maximumRetainedGaussianFraction.isFinite
            && policy.minimumRetainedGaussianFraction > 0
            && policy.minimumRetainedGaussianFraction
                < policy.maximumRetainedGaussianFraction
            && policy.maximumRetainedGaussianFraction <= 1
    }

    private static func validMetrics(
        _ metrics: IsolationArtifact.ValidationMetrics,
        policy: IsolationArtifact.Policy
    ) -> Bool {
        let heldOutMetrics = [
            metrics.heldOutMeanIoU,
            metrics.heldOutMedianIoU,
            metrics.heldOutFirstQuartileIoU,
        ]
        let hasNoHeldOutMetrics = heldOutMetrics.allSatisfy { $0 == nil }
        let hasAllHeldOutMetrics = heldOutMetrics.allSatisfy { $0 != nil }
        return validUnitInterval(metrics.meanMaskConfidence)
            && (hasNoHeldOutMetrics || hasAllHeldOutMetrics)
            && heldOutMetrics.allSatisfy { $0.map(validUnitInterval) ?? true }
            && validUnitInterval(metrics.retainedGaussianFraction)
            && metrics.meanMaskConfidence >= policy.minimumMaskConfidence
            && (metrics.heldOutMedianIoU.map {
                $0 >= policy.minimumHeldOutMedianIoU
            } ?? true)
            && (metrics.heldOutFirstQuartileIoU.map {
                $0 >= policy.minimumHeldOutFirstQuartileIoU
            } ?? true)
            && metrics.retainedGaussianFraction
                >= policy.minimumRetainedGaussianFraction
            && metrics.retainedGaussianFraction
                <= policy.maximumRetainedGaussianFraction
    }

    private static func validUnitInterval(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isSafeIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumIdentityBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && URL(fileURLWithPath: value).lastPathComponent == value
            && value != "."
            && value != ".."
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(
        _ data: Data,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> String {
        var hasher = SHA256()
        let chunkSize = 1_048_576
        var offset = 0
        while offset < data.count {
            try throwIfCancelled(shouldCancel)
            let end = min(offset + chunkSize, data.count)
            hasher.update(data: data[offset..<end])
            offset = end
        }
        try throwIfCancelled(shouldCancel)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func throwIfCancelled(
        _ shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    private static func copyPrivateRegularFile(
        from source: URL,
        to destination: URL,
        maximumBytes: Int,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> FileIdentity {
        let data = try BoundedFileReader.readRegularFile(
            at: source,
            maximumBytes: maximumBytes,
            shouldCancel: shouldCancel
        )
        return try writePrivateFile(
            data,
            to: destination,
            shouldCancel: shouldCancel
        )
    }

    private static func writePrivateFile(
        _ data: Data,
        to destination: URL,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> FileIdentity {
        try throwIfCancelled(shouldCancel)
        let parent = destination.deletingLastPathComponent()
        let directory = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(directory) }
        let descriptor = destination.lastPathComponent.withCString {
            Darwin.openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        var createdStatus = stat()
        guard fstat(descriptor, &createdStatus) == 0,
              (createdStatus.st_mode & S_IFMT) == S_IFREG,
              createdStatus.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let createdFile = OwnedFile(
            url: destination,
            identity: FileIdentity(
                device: createdStatus.st_dev,
                inode: createdStatus.st_ino
            )
        )
        var keep = false
        defer {
            Darwin.close(descriptor)
            if !keep {
                try? removeOwnedFileIfPresent(createdFile)
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try throwIfCancelled(shouldCancel)
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                offset += count
            }
        }
        try throwIfCancelled(shouldCancel)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size == data.count else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        keep = true
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private static func requireSubjectPairTransactionPathsAvailable(
        _ transaction: SubjectPairTransactionPaths
    ) throws {
        for url in [
            transaction.journalURL,
            transaction.pendingJournalURL,
            transaction.previousOutputURL,
            transaction.previousManifestURL,
            transaction.newOutputURL,
            transaction.newManifestURL,
        ] {
            try requireSubjectPairFileAbsent(url)
        }
    }

    private static func subjectPairReservedNames(in directory: URL) throws -> Set<String> {
        do {
            return Set(try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).filter { $0.hasPrefix(subjectPairPrefix) })
        } catch {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func observeSubjectPairFile(
        at url: URL,
        maximumBytes: Int64
    ) throws -> ObservedSubjectPairFile {
        guard maximumBytes > 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var status = stat()
        while lstat(url.path, &status) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return .missing }
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        do {
            return .privateFile(try subjectPairObservedIdentity(at: url))
        } catch {
            return .unsafe
        }
    }

    private static func subjectPairObservedIdentity(
        at url: URL
    ) throws -> SubjectPairJournalFileIdentity {
        let parentURL = url.deletingLastPathComponent()
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        defer { Darwin.close(parent) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        defer { Darwin.close(descriptor) }
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &descriptorStatus) == 0,
              pathResult == 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let identity = SubjectPairJournalFileIdentity(descriptorStatus)
        guard identity.matches(pathStatus),
              identity.hasPrivateRegularFileShape() else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return identity
    }

    private static func subjectPairJournalIdentity(
        at url: URL,
        maximumBytes: Int64
    ) throws -> SubjectPairJournalFileIdentity {
        guard maximumBytes > 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let identity = try subjectPairObservedIdentity(at: url)
        guard identity.isValid(maximumBytes: maximumBytes) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return identity
    }

    private static func readSubjectPairFile(
        at url: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int
    ) throws -> Data {
        guard expected.byteCount <= Int64(maximumBytes) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return try withExpectedSubjectPairFileDescriptor(
            at: url,
            expected: expected,
            maximumBytes: Int64(maximumBytes)
        ) { descriptor in
            var data = Data(count: Int(expected.byteCount))
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
                guard count > 0 else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                offset += count
            }
            return data
        }
    }

    private static func withExpectedSubjectPairFileDescriptor<T>(
        at url: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int64,
        _ body: (Int32) throws -> T
    ) throws -> T {
        guard expected.isValid(maximumBytes: maximumBytes) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let parentURL = url.deletingLastPathComponent()
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        defer { Darwin.close(parent) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var named = stat()
        let namedResult = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &opened) == 0,
              namedResult == 0,
              expected.matches(opened),
              expected.matches(named) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let result = try body(descriptor)
        var finalDescriptor = stat()
        var finalNamed = stat()
        let finalNamedResult = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &finalNamed, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &finalDescriptor) == 0,
              finalNamedResult == 0,
              expected.matches(finalDescriptor),
              expected.matches(finalNamed) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return result
    }

    private static func requireTransactionFileAbsentOrOwned(
        _ url: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int64
    ) throws {
        let observed = try observeSubjectPairFile(
            at: url,
            maximumBytes: maximumBytes
        )
        guard observed.isMissing || observed.owns(expected) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func canonicalSubjectPairFileState(
        at url: URL,
        replacement: SubjectPairJournalFileIdentity,
        previous: SubjectPairJournalFileIdentity?,
        maximumBytes: Int64
    ) throws -> SubjectPairCanonicalFileState {
        let observed = try observeSubjectPairFile(
            at: url,
            maximumBytes: maximumBytes
        )
        if observed.isMissing { return .missing }
        if observed.owns(replacement) { return .replacement }
        if observed.isSameObject(as: replacement) { return .damagedReplacement }
        if let previous, observed.owns(previous) { return .previous }
        return .foreign
    }

    private static func previousSubjectPairFileLocation(
        canonical: URL,
        backup: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int64
    ) throws -> URL {
        let canonicalState = try observeSubjectPairFile(
            at: canonical,
            maximumBytes: maximumBytes
        )
        let backupState = try observeSubjectPairFile(
            at: backup,
            maximumBytes: maximumBytes
        )
        if canonicalState.owns(expected), backupState.isMissing {
            return canonical
        }
        if backupState.owns(expected), !canonicalState.owns(expected) {
            return backup
        }
        throw SubjectIsolationArtifactStoreError.publicationConflict
    }

    private static func requireSubjectPairFileAbsent(_ url: URL) throws {
        var status = stat()
        while lstat(url.path, &status) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return }
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        throw SubjectIsolationArtifactStoreError.publicationConflict
    }

    private static func moveSubjectPairFile(
        from source: URL,
        expected: SubjectPairJournalFileIdentity,
        to destination: URL
    ) throws {
        let maximumBytes = expected.byteCount
        guard try observeSubjectPairFile(
            at: source,
            maximumBytes: maximumBytes
        ).owns(expected) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try requireSubjectPairFileAbsent(destination)
        try renameExclusive(source, to: destination)
        guard try observeSubjectPairFile(
            at: destination,
            maximumBytes: maximumBytes
        ).owns(expected) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try requireSubjectPairFileAbsent(source)
    }

    private static func unlinkSubjectPairFileIfOwned(
        _ url: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int64
    ) throws {
        let observed = try observeSubjectPairFile(
            at: url,
            maximumBytes: maximumBytes
        )
        if observed.isMissing { return }
        guard observed.owns(expected) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try quarantineAndUnlinkSubjectPairFile(
            url,
            expected: expected,
            maximumBytes: maximumBytes,
            requireExactBytes: true,
            paths: nil
        )
    }

    private static func unlinkSubjectPairFileIfSameObject(
        _ url: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int64
    ) throws {
        let observed = try observeSubjectPairFile(
            at: url,
            maximumBytes: maximumBytes
        )
        guard observed.isSameObject(as: expected) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try quarantineAndUnlinkSubjectPairFile(
            url,
            expected: expected,
            maximumBytes: maximumBytes,
            requireExactBytes: false,
            paths: nil
        )
    }

    private static func quarantineAndUnlinkSubjectPairFile(
        _ url: URL,
        expected: SubjectPairJournalFileIdentity,
        maximumBytes: Int64,
        requireExactBytes: Bool,
        paths: ProjectPaths?,
        willQuarantineOwnedEntry: (String, String) throws -> Void = { _, _ in },
        willUnlinkQuarantinedEntry: (String, String) throws -> Void = { _, _ in }
    ) throws {
        let parentURL = url.deletingLastPathComponent()
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        defer { Darwin.close(parent) }
        let originalLeaf = url.lastPathComponent
        let quarantineLeaf = ".subject-retired.\(UUID().uuidString.lowercased())"
        let originalRelative = try paths?.projectRelativePath(for: url) ?? url.path
        let quarantineURL = parentURL.appendingPathComponent(quarantineLeaf)
        let quarantineRelative = try paths?.projectRelativePath(for: quarantineURL)
            ?? quarantineURL.path
        try willQuarantineOwnedEntry(originalRelative, quarantineRelative)

        var current = stat()
        let currentResult = originalLeaf.withCString {
            Darwin.fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        let currentIdentity = SubjectPairJournalFileIdentity(current)
        let currentHasAllowedShape = requireExactBytes
            ? currentIdentity.isValid(maximumBytes: maximumBytes)
            : currentIdentity.hasPrivateRegularFileShape()
                && currentIdentity.byteCount >= 0
                && currentIdentity.byteCount <= maximumBytes
        guard currentResult == 0,
              currentHasAllowedShape,
              (requireExactBytes
                ? expected.matches(current)
                : currentIdentity.sameObject(as: expected)) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let renameResult = originalLeaf.withCString { sourceName in
            quarantineLeaf.withCString { destinationName in
                Darwin.renameatx_np(
                    parent,
                    sourceName,
                    parent,
                    destinationName,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard renameResult == 0, Darwin.fsync(parent) == 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }

        do {
            try willUnlinkQuarantinedEntry(originalRelative, quarantineRelative)
        } catch {
            try? restoreQuarantinedSubjectPairFile(
                parent: parent,
                originalLeaf: originalLeaf,
                quarantineLeaf: quarantineLeaf
            )
            throw error
        }
        var quarantined = stat()
        let quarantineResult = quarantineLeaf.withCString {
            Darwin.fstatat(parent, $0, &quarantined, AT_SYMLINK_NOFOLLOW)
        }
        let quarantinedIdentity = SubjectPairJournalFileIdentity(quarantined)
        let quarantinedHasAllowedShape = requireExactBytes
            ? quarantinedIdentity.isValid(maximumBytes: maximumBytes)
            : quarantinedIdentity.hasPrivateRegularFileShape()
                && quarantinedIdentity.byteCount >= 0
                && quarantinedIdentity.byteCount <= maximumBytes
        guard quarantineResult == 0,
              quarantinedHasAllowedShape,
              (requireExactBytes
                ? expected.matches(quarantined)
                : quarantinedIdentity.sameObject(as: expected)) else {
            try? restoreQuarantinedSubjectPairFile(
                parent: parent,
                originalLeaf: originalLeaf,
                quarantineLeaf: quarantineLeaf
            )
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let unlinkResult = quarantineLeaf.withCString {
            Darwin.unlinkat(parent, $0, 0)
        }
        guard unlinkResult == 0, Darwin.fsync(parent) == 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func restoreQuarantinedSubjectPairFile(
        parent: Int32,
        originalLeaf: String,
        quarantineLeaf: String
    ) throws {
        var originalStatus = stat()
        let originalResult = originalLeaf.withCString {
            Darwin.fstatat(parent, $0, &originalStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard originalResult != 0, errno == ENOENT else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let result = quarantineLeaf.withCString { sourceName in
            originalLeaf.withCString { destinationName in
                Darwin.renameatx_np(
                    parent,
                    sourceName,
                    parent,
                    destinationName,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard result == 0, Darwin.fsync(parent) == 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func renameExclusive(_ source: URL, to destination: URL) throws {
        guard source.deletingLastPathComponent().path
                == destination.deletingLastPathComponent().path else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let directoryURL = source.deletingLastPathComponent()
        let directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(directory) }
        let result = source.lastPathComponent.withCString { sourceName in
            destination.lastPathComponent.withCString { destinationName in
                Darwin.renameatx_np(
                    directory,
                    sourceName,
                    directory,
                    destinationName,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard result == 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private enum FileOwnership {
        case missing
        case owned
        case different
    }

    private static func ownership(of file: OwnedFile) throws -> FileOwnership {
        guard let current = try fileIdentityIfPresent(at: file.url) else {
            return .missing
        }
        return current == file.identity ? .owned : .different
    }

    private static func requireOwnedFile(_ file: OwnedFile) throws {
        guard try ownership(of: file) == .owned else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func removeOwnedFileIfPresent(_ file: OwnedFile) throws {
        switch try ownership(of: file) {
        case .missing:
            return
        case .different:
            throw SubjectIsolationArtifactStoreError.publicationConflict
        case .owned:
            break
        }

        let parent = file.url.deletingLastPathComponent()
        let quarantine = parent.appendingPathComponent(
            ".subject-remove.\(UUID().uuidString)"
        )
        try renameExclusive(file.url, to: quarantine)
        let quarantined = OwnedFile(url: quarantine, identity: file.identity)
        guard try ownership(of: quarantined) == .owned else {
            if try fileIdentityIfPresent(at: file.url) == nil {
                try? renameExclusive(quarantine, to: file.url)
            }
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        try unlinkOwnedQuarantine(quarantined)
    }

    private static func unlinkOwnedQuarantine(_ file: OwnedFile) throws {
        let directoryURL = file.url.deletingLastPathComponent()
        let directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(directory) }
        var status = stat()
        let statusResult = file.url.lastPathComponent.withCString {
            Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0,
              FileIdentity(device: status.st_dev, inode: status.st_ino)
                == file.identity,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let removeResult = file.url.lastPathComponent.withCString {
            Darwin.unlinkat(directory, $0, 0)
        }
        guard removeResult == 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func privateRegularFileIdentity(at url: URL) throws -> FileIdentity {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(url.path, &pathStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              pathStatus.st_nlink == 1 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return FileIdentity(
            device: descriptorStatus.st_dev,
            inode: descriptorStatus.st_ino
        )
    }

    private static func privateRegularFileIdentity(
        at url: URL,
        relativePath: String,
        projectRootDescriptor: Int32?
    ) throws -> FileIdentity {
        guard let projectRootDescriptor else {
            return try privateRegularFileIdentity(at: url)
        }
        return try withBoundProjectFileDescriptor(
            relativePath: relativePath,
            projectRootDescriptor: projectRootDescriptor,
            maximumBytes: Int.max
        ) { _, status in
            FileIdentity(device: status.st_dev, inode: status.st_ino)
        }
    }

    private static func stableFileState(at url: URL) throws -> StableFileState {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(url.path, &pathStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              pathStatus.st_nlink == 1 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return StableFileState(
            identity: FileIdentity(
                device: descriptorStatus.st_dev,
                inode: descriptorStatus.st_ino
            ),
            byteCount: descriptorStatus.st_size,
            modifiedSeconds: Int64(descriptorStatus.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(descriptorStatus.st_mtimespec.tv_nsec),
            changedSeconds: Int64(descriptorStatus.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(descriptorStatus.st_ctimespec.tv_nsec)
        )
    }

    private static func stableFileState(
        relativePath: String,
        projectRootDescriptor: Int32
    ) throws -> StableFileState {
        try withBoundProjectFileDescriptor(
            relativePath: relativePath,
            projectRootDescriptor: projectRootDescriptor,
            maximumBytes: Int.max
        ) { _, status in
            StableFileState(
                identity: FileIdentity(
                    device: status.st_dev,
                    inode: status.st_ino
                ),
                byteCount: status.st_size,
                modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                changedSeconds: Int64(status.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
            )
        }
    }

    private static func readBoundProjectFile(
        relativePath: String,
        projectRootDescriptor: Int32,
        maximumBytes: Int,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> Data {
        try withBoundProjectFileDescriptor(
            relativePath: relativePath,
            projectRootDescriptor: projectRootDescriptor,
            maximumBytes: maximumBytes
        ) { descriptor, status in
            var data = Data(count: Int(status.st_size))
            var offset = 0
            while offset < data.count {
                try throwIfCancelled(shouldCancel)
                let count = data.withUnsafeMutableBytes { bytes in
                    Darwin.pread(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset,
                        off_t(offset)
                    )
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                offset += count
            }
            try throwIfCancelled(shouldCancel)
            return data
        }
    }

    private static func sha256BoundProjectFile(
        relativePath: String,
        projectRootDescriptor: Int32,
        maximumBytes: Int,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> String {
        try withBoundProjectFileDescriptor(
            relativePath: relativePath,
            projectRootDescriptor: projectRootDescriptor,
            maximumBytes: maximumBytes
        ) { descriptor, status in
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            var offset: off_t = 0
            while offset < status.st_size {
                try throwIfCancelled(shouldCancel)
                let remaining = Int(min(off_t(buffer.count), status.st_size - offset))
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(descriptor, bytes.baseAddress, remaining, offset)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                hasher.update(data: Data(buffer[0..<count]))
                offset += off_t(count)
            }
            try throwIfCancelled(shouldCancel)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func withBoundProjectFileDescriptor<T>(
        relativePath: String,
        projectRootDescriptor: Int32,
        maximumBytes: Int,
        _ body: (Int32, stat) throws -> T
    ) throws -> T {
        try withBoundProjectParentDescriptor(
            relativePath: relativePath,
            projectRootDescriptor: projectRootDescriptor
        ) { parent, leaf in
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            var named = stat()
            let namedResult = leaf.withCString {
                Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
            }
            guard Darwin.fstat(descriptor, &opened) == 0,
                  namedResult == 0,
                  (opened.st_mode & S_IFMT) == S_IFREG,
                  opened.st_nlink == 1,
                  opened.st_uid == geteuid(),
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino,
                  opened.st_size >= 0,
                  opened.st_size <= off_t(maximumBytes) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            let initial = StableFileState(
                identity: FileIdentity(device: opened.st_dev, inode: opened.st_ino),
                byteCount: opened.st_size,
                modifiedSeconds: Int64(opened.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(opened.st_mtimespec.tv_nsec),
                changedSeconds: Int64(opened.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(opened.st_ctimespec.tv_nsec)
            )
            let result = try body(descriptor, opened)
            var finalOpened = stat()
            var finalNamed = stat()
            let finalNamedResult = leaf.withCString {
                Darwin.fstatat(parent, $0, &finalNamed, AT_SYMLINK_NOFOLLOW)
            }
            guard Darwin.fstat(descriptor, &finalOpened) == 0,
                  finalNamedResult == 0,
                  finalOpened.st_dev == finalNamed.st_dev,
                  finalOpened.st_ino == finalNamed.st_ino else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            let finalState = StableFileState(
                identity: FileIdentity(
                    device: finalOpened.st_dev,
                    inode: finalOpened.st_ino
                ),
                byteCount: finalOpened.st_size,
                modifiedSeconds: Int64(finalOpened.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(finalOpened.st_mtimespec.tv_nsec),
                changedSeconds: Int64(finalOpened.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(finalOpened.st_ctimespec.tv_nsec)
            )
            guard finalState == initial else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            return result
        }
    }

    private static func safeRelativeComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return components
    }

    private static func withBoundProjectParentDescriptor<T>(
        relativePath: String,
        projectRootDescriptor: Int32,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        let components = try safeRelativeComponents(relativePath)
        guard let leaf = components.last else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var parent = Darwin.fcntl(projectRootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard parent >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(parent) }
        for component in components.dropLast() {
            var named = stat()
            let namedResult = component.withCString {
                Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
            }
            let child = component.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard namedResult == 0, child >= 0 else {
                if child >= 0 { Darwin.close(child) }
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            var opened = stat()
            guard Darwin.fstat(child, &opened) == 0,
                  (opened.st_mode & S_IFMT) == S_IFDIR,
                  opened.st_uid == geteuid(),
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino else {
                Darwin.close(child)
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            Darwin.close(parent)
            parent = child
        }
        return try body(parent, leaf)
    }

    private static func withBoundProjectDirectoryDescriptor<T>(
        relativePath: String,
        projectRootDescriptor: Int32,
        _ body: (Int32) throws -> T
    ) throws -> T {
        try withBoundProjectParentDescriptor(
            relativePath: relativePath,
            projectRootDescriptor: projectRootDescriptor
        ) { parent, leaf in
            var named = stat()
            let namedResult = leaf.withCString {
                Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
            }
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard namedResult == 0, descriptor >= 0 else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  (opened.st_mode & S_IFMT) == S_IFDIR,
                  opened.st_uid == geteuid(),
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            return try body(descriptor)
        }
    }

    private static func projectPaths(
        boundTo projectRootDescriptor: Int32,
        expected: ProjectPaths,
        requireExpectedPathIdentity: Bool = true
    ) throws -> ProjectPaths {
        var descriptorStatus = stat()
        guard Darwin.fstat(projectRootDescriptor, &descriptorStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
              descriptorStatus.st_uid == geteuid() else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        if requireExpectedPathIdentity {
            var expectedStatus = stat()
            guard Darwin.lstat(expected.root.path, &expectedStatus) == 0,
                  (expectedStatus.st_mode & S_IFMT) == S_IFDIR,
                  expectedStatus.st_dev == descriptorStatus.st_dev,
                  expectedStatus.st_ino == descriptorStatus.st_ino else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
        }
        let storageCount = (
            Int(MAXPATHLEN) + MemoryLayout<Darwin.flock>.stride - 1
        ) / MemoryLayout<Darwin.flock>.stride
        var pathStorage = [Darwin.flock](
            repeating: Darwin.flock(),
            count: storageCount
        )
        _ = pathStorage.withUnsafeMutableBytes { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
        let pathResult = pathStorage.withUnsafeMutableBufferPointer { buffer in
            Darwin.fcntl(projectRootDescriptor, F_GETPATH, buffer.baseAddress!)
        }
        guard pathResult == 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let pathBytes = pathStorage.withUnsafeBytes { bytes in
            Array(bytes.prefix(Int(MAXPATHLEN)))
        }
        guard let terminator = pathBytes.firstIndex(of: 0),
              terminator > 0,
              let boundPath = String(
                bytes: pathBytes[..<terminator],
                encoding: .utf8
              ) else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        let boundURL = URL(
            fileURLWithPath: boundPath,
            isDirectory: true
        )
        var boundStatus = stat()
        guard Darwin.lstat(boundURL.path, &boundStatus) == 0,
              (boundStatus.st_mode & S_IFMT) == S_IFDIR,
              boundStatus.st_dev == descriptorStatus.st_dev,
              boundStatus.st_ino == descriptorStatus.st_ino else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return ProjectPaths(root: boundURL)
    }

    private static func fileIdentityIfPresent(at url: URL) throws -> FileIdentity? {
        var status = stat()
        while lstat(url.path, &status) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return nil }
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            return FileIdentity(device: status.st_dev, inode: status.st_ino)
        }
        return try privateRegularFileIdentity(at: url)
    }

    private static func ensureBoundProjectDirectory(
        parent: Int32,
        name: String
    ) throws -> Int32 {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var named = stat()
        var status = name.withCString {
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0, errno == ENOENT {
            let createResult = name.withCString {
                Darwin.mkdirat(parent, $0, S_IRWXU)
            }
            guard createResult == 0, Darwin.fsync(parent) == 0 else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            status = name.withCString {
                Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard status == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              named.st_uid == geteuid() else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == geteuid() else {
            Darwin.close(descriptor)
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return descriptor
    }

    private static func withIsolationLock<T>(
        paths: ProjectPaths,
        projectRootDescriptor suppliedProjectRootDescriptor: Int32? = nil,
        createDirectories: Bool = false,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onProcessLockContention: @escaping @Sendable () -> Void = {},
        onFileLockContention: @escaping @Sendable () -> Void = {},
        didBindProjectRoot: @escaping (Int32) throws -> Void = { _ in },
        _ body: (Int32) throws -> T
    ) throws -> T {
        try throwIfCancelled(shouldCancel)
        let rootDescriptor: Int32
        if let suppliedProjectRootDescriptor {
            rootDescriptor = Darwin.fcntl(
                suppliedProjectRootDescriptor,
                F_DUPFD_CLOEXEC,
                0
            )
        } else {
            rootDescriptor = Darwin.open(
                paths.root.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        var rootPathStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              lstat(paths.root.path, &rootPathStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              rootStatus.st_dev == rootPathStatus.st_dev,
              rootStatus.st_ino == rootPathStatus.st_ino else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try didBindProjectRoot(rootDescriptor)
        let processLockKey = ProcessIsolationLockKey(
            device: UInt64(rootStatus.st_dev),
            inode: UInt64(rootStatus.st_ino)
        )
        let processIsolationLock = processIsolationLocks.value(for: processLockKey)
        while true {
            try throwIfCancelled(shouldCancel)
            if processIsolationLock.value.try() {
                break
            }
            onProcessLockContention()
            waitBeforeLockRetry()
        }
        defer { processIsolationLock.value.unlock() }
        try throwIfCancelled(shouldCancel)
        guard lstat(paths.root.path, &rootPathStatus) == 0,
              rootStatus.st_dev == rootPathStatus.st_dev,
              rootStatus.st_ino == rootPathStatus.st_ino else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }

        let threadState = Thread.current.threadDictionary
        let depthKey = isolationLockDepthKey
            + ":\(processLockKey.device):\(processLockKey.inode)"
        let depth = (threadState[depthKey] as? NSNumber)?.intValue ?? 0
        threadState[depthKey] = NSNumber(value: depth + 1)
        defer {
            if depth == 0 {
                threadState.removeObject(forKey: depthKey)
            } else {
                threadState[depthKey] = NSNumber(value: depth)
            }
        }
        if depth > 0 {
            return try body(rootDescriptor)
        }

        if createDirectories {
            let output = try ensureBoundProjectDirectory(
                parent: rootDescriptor,
                name: "Output"
            )
            Darwin.close(output)
            let isolation = try ensureBoundProjectDirectory(
                parent: rootDescriptor,
                name: "Isolation"
            )
            defer { Darwin.close(isolation) }
            let masks = try ensureBoundProjectDirectory(
                parent: isolation,
                name: "masks"
            )
            Darwin.close(masks)
            let staging = try ensureBoundProjectDirectory(
                parent: isolation,
                name: "staging"
            )
            Darwin.close(staging)
        }

        let isolationDescriptor = "Isolation".withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard isolationDescriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(isolationDescriptor) }
        var directoryStatus = stat()
        var directoryPathStatus = stat()
        guard fstat(isolationDescriptor, &directoryStatus) == 0,
              "Isolation".withCString({
                  Darwin.fstatat(
                      rootDescriptor,
                      $0,
                      &directoryPathStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_dev == directoryPathStatus.st_dev,
              directoryStatus.st_ino == directoryPathStatus.st_ino else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }

        let lockDescriptor = isolationLockName.withCString {
            Darwin.openat(
                isolationDescriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard lockDescriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(lockDescriptor) }
        guard fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var lockStatus = stat()
        var lockPathStatus = stat()
        guard fstat(lockDescriptor, &lockStatus) == 0,
              isolationLockName.withCString({
                  Darwin.fstatat(
                      isolationDescriptor,
                      $0,
                      &lockPathStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              (lockStatus.st_mode & S_IFMT) == S_IFREG,
              lockStatus.st_nlink == 1,
              lockStatus.st_dev == lockPathStatus.st_dev,
              lockStatus.st_ino == lockPathStatus.st_ino,
              lockPathStatus.st_nlink == 1 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try lockOpenFileDescription(
            lockDescriptor,
            shouldCancel: shouldCancel,
            onContention: onFileLockContention
        )
        defer { unlockOpenFileDescription(lockDescriptor) }
        try throwIfCancelled(shouldCancel)

        let outcome: Result<T, Error>
        do {
            outcome = .success(try body(rootDescriptor))
        } catch {
            outcome = .failure(error)
        }
        var finalDirectoryStatus = stat()
        var finalBoundDirectoryStatus = stat()
        var finalLockStatus = stat()
        var finalRootStatus = stat()
        var finalBoundRootStatus = stat()
        guard lstat(paths.root.path, &finalRootStatus) == 0,
              fstat(rootDescriptor, &finalBoundRootStatus) == 0,
              finalRootStatus.st_dev == rootStatus.st_dev,
              finalRootStatus.st_ino == rootStatus.st_ino,
              finalBoundRootStatus.st_dev == rootStatus.st_dev,
              finalBoundRootStatus.st_ino == rootStatus.st_ino,
              "Isolation".withCString({
                  Darwin.fstatat(
                      rootDescriptor,
                      $0,
                      &finalDirectoryStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              fstat(isolationDescriptor, &finalBoundDirectoryStatus) == 0,
              finalDirectoryStatus.st_dev == directoryStatus.st_dev,
              finalDirectoryStatus.st_ino == directoryStatus.st_ino,
              finalBoundDirectoryStatus.st_dev == directoryStatus.st_dev,
              finalBoundDirectoryStatus.st_ino == directoryStatus.st_ino,
              isolationLockName.withCString({
                  Darwin.fstatat(
                      isolationDescriptor,
                      $0,
                      &finalLockStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
        }) == 0,
              finalLockStatus.st_dev == lockStatus.st_dev,
              finalLockStatus.st_ino == lockStatus.st_ino else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        return try outcome.get()
    }

    private static func waitBeforeLockRetry() {
        _ = Darwin.usleep(lockRetryMicroseconds)
    }

    private static func lockOpenFileDescription(
        _ descriptor: Int32,
        shouldCancel: @escaping @Sendable () -> Bool,
        onContention: @escaping @Sendable () -> Void
    ) throws {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while true {
            try throwIfCancelled(shouldCancel)
            let result = withUnsafeMutablePointer(to: &lock) {
                Darwin.fcntl(descriptor, F_OFD_SETLK, $0)
            }
            if result == 0 { return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EACCES {
                onContention()
                waitBeforeLockRetry()
                continue
            }
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func unlockOpenFileDescription(_ descriptor: Int32) {
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

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }
}
