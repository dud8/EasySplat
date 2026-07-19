import CryptoKit
import Darwin
import EasySplatCore
import Foundation

enum MeasurementInputTopology: String, Sendable {
    case continuous
    case unordered
    case segmentedMixed = "segmented_mixed"

    var requestedInputOrdering: InputOrdering {
        switch self {
        case .continuous:
            .continuous
        case .unordered:
            .unordered
        case .segmentedMixed:
            .automatic
        }
    }
}

public struct MeasurementInvalidInputRejectionReceipt: Sendable, Equatable {
    public enum Error: Swift.Error, Equatable {
        case invalidFields
        case destinationExists
        case publicationFailed
    }

    public let variant: String
    public let requestSHA256: String
    public let failureType: String

    public init(
        variant: String,
        requestSHA256: String,
        failureType: String
    ) throws {
        guard variant == "candidate",
              requestSHA256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
              ) != nil,
              failureType.range(
                of: #"^[a-z0-9][a-z0-9_.-]{0,63}$"#,
                options: .regularExpression
              ) != nil else {
            throw Error.invalidFields
        }
        self.variant = variant
        self.requestSHA256 = requestSHA256
        self.failureType = failureType
    }

    public func write(to destination: URL) throws {
        guard destination.isFileURL,
              !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".",
              destination.lastPathComponent != ".." else {
            throw Error.publicationFailed
        }
        var status = stat()
        if Darwin.lstat(destination.path, &status) == 0 {
            throw Error.destinationExists
        }
        guard errno == ENOENT else { throw Error.publicationFailed }
        var data = try JSONSerialization.data(
            withJSONObject: [
                "schema_version": 1,
                "kind": "invalid_input_rejection",
                "variant": variant,
                "request_sha256": requestSHA256,
                "failure_type": failureType,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        do {
            try data.write(to: destination, options: .withoutOverwriting)
        } catch {
            if Darwin.lstat(destination.path, &status) == 0 {
                throw Error.destinationExists
            }
            throw Error.publicationFailed
        }
    }
}

public enum MeasurementMapperFixedOptionsValidationError: Error, LocalizedError, Equatable {
    case nonPositiveValue(String)
    case invalidTolerance(String)
    case randomSeedOutOfRange
    case invalidMinimumPairInlierCount

    public var errorDescription: String? {
        switch self {
        case .nonPositiveValue(let name):
            "\(name) must be positive."
        case .invalidTolerance(let name):
            "\(name) must be finite and nonnegative."
        case .randomSeedOutOfRange:
            "The mapper random seed exceeds the signed 32-bit range."
        case .invalidMinimumPairInlierCount:
            "The minimum pair inlier count must be positive."
        }
    }
}

public struct MeasurementMapperFixedOptions: Encodable, Sendable, Equatable {
    public let localMaxRefinements: Int
    public let globalMaxRefinements: Int
    public let globalMaxNumIterations: Int
    public let localMaxNumIterations: Int
    public let localFunctionTolerance: Double
    public let globalFunctionTolerance: Double
    public let localImageCount: Int
    public let randomSeed: Int32
    public let refineFocalLength: Bool

    enum CodingKeys: String, CodingKey {
        case localMaxRefinements = "local_max_refinements"
        case globalMaxRefinements = "global_max_refinements"
        case globalMaxNumIterations = "global_max_num_iterations"
        case localMaxNumIterations = "local_max_num_iterations"
        case localFunctionTolerance = "local_function_tolerance"
        case globalFunctionTolerance = "global_function_tolerance"
        case localImageCount = "local_image_count"
        case randomSeed = "random_seed"
        case refineFocalLength = "refine_focal_length"
    }

    public init(
        localMaxRefinements: Int,
        globalMaxRefinements: Int,
        globalMaxNumIterations: Int,
        localMaxNumIterations: Int,
        localFunctionTolerance: Double,
        globalFunctionTolerance: Double,
        localImageCount: Int,
        randomSeed: UInt64,
        refineFocalLength: Bool
    ) throws {
        guard localMaxRefinements > 0 else {
            throw MeasurementMapperFixedOptionsValidationError.nonPositiveValue(
                "Local refinement limit"
            )
        }
        guard globalMaxRefinements > 0 else {
            throw MeasurementMapperFixedOptionsValidationError.nonPositiveValue(
                "Global refinement limit"
            )
        }
        guard globalMaxNumIterations > 0 else {
            throw MeasurementMapperFixedOptionsValidationError.nonPositiveValue(
                "Global iteration limit"
            )
        }
        guard localMaxNumIterations > 0 else {
            throw MeasurementMapperFixedOptionsValidationError.nonPositiveValue(
                "Local iteration limit"
            )
        }
        guard localFunctionTolerance.isFinite, localFunctionTolerance >= 0 else {
            throw MeasurementMapperFixedOptionsValidationError.invalidTolerance(
                "Local function tolerance"
            )
        }
        guard globalFunctionTolerance.isFinite, globalFunctionTolerance >= 0 else {
            throw MeasurementMapperFixedOptionsValidationError.invalidTolerance(
                "Global function tolerance"
            )
        }
        guard localImageCount > 0 else {
            throw MeasurementMapperFixedOptionsValidationError.nonPositiveValue(
                "Local image count"
            )
        }
        guard let randomSeed = Int32(exactly: randomSeed) else {
            throw MeasurementMapperFixedOptionsValidationError.randomSeedOutOfRange
        }
        self.localMaxRefinements = localMaxRefinements
        self.globalMaxRefinements = globalMaxRefinements
        self.globalMaxNumIterations = globalMaxNumIterations
        self.localMaxNumIterations = localMaxNumIterations
        self.localFunctionTolerance = localFunctionTolerance
        self.globalFunctionTolerance = globalFunctionTolerance
        self.localImageCount = localImageCount
        self.randomSeed = randomSeed
        self.refineFocalLength = refineFocalLength
    }

    public func bindingSHA256(minimumPairInlierCount: Int) throws -> String {
        guard minimumPairInlierCount > 0 else {
            throw MeasurementMapperFixedOptionsValidationError.invalidMinimumPairInlierCount
        }
        let domain = Data("easysplat-mapper-fixed-options-v1".utf8)
        var bytes = Data()
        Self.append(UInt64(domain.count).bigEndian, to: &bytes)
        bytes.append(domain)
        Self.append(Int64(localMaxRefinements).bigEndian, to: &bytes)
        Self.append(Int64(globalMaxRefinements).bigEndian, to: &bytes)
        Self.append(Int64(globalMaxNumIterations).bigEndian, to: &bytes)
        Self.append(Int64(localMaxNumIterations).bigEndian, to: &bytes)
        Self.append(localFunctionTolerance.bitPattern.bigEndian, to: &bytes)
        Self.append(globalFunctionTolerance.bitPattern.bigEndian, to: &bytes)
        Self.append(Int64(localImageCount).bigEndian, to: &bytes)
        Self.append(randomSeed.bigEndian, to: &bytes)
        bytes.append(refineFocalLength ? 1 : 0)
        Self.append(Int64(minimumPairInlierCount).bigEndian, to: &bytes)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func append<T>(_ value: T, to data: inout Data) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    #if !BASELINE_ADAPTER
    fileprivate func mapperOptions(ratio: Double) throws -> ColmapMapperOptions {
        try ColmapMapperOptions(
            globalFramesRatio: ratio,
            globalPointsRatio: ratio,
            localMaxRefinements: localMaxRefinements,
            globalMaxRefinements: globalMaxRefinements,
            globalMaxNumIterations: globalMaxNumIterations,
            localMaxNumIterations: localMaxNumIterations,
            localFunctionTolerance: localFunctionTolerance,
            globalFunctionTolerance: globalFunctionTolerance,
            localImageCount: localImageCount,
            randomSeed: UInt64(randomSeed),
            refineFocalLength: refineFocalLength
        )
    }
    #endif
}

public struct MeasurementMapperCadenceTrial: Encodable, Sendable, Equatable {
    public static let warmup = MeasurementMapperCadenceTrial(
        ordinal: 0,
        name: "mapper-cadence-warmup-1p4",
        ratio: 1.4
    )

    public let ordinal: Int
    public let name: String
    public let ratio: Double

    fileprivate init(ordinal: Int, name: String, ratio: Double) {
        self.ordinal = ordinal
        self.name = name
        self.ratio = ratio
    }
}

public struct MeasurementMapperCadenceSchedule: Encodable, Sendable, Equatable {
    public let fixedOptions: MeasurementMapperFixedOptions
    public let trials: [MeasurementMapperCadenceTrial]

    enum CodingKeys: String, CodingKey {
        case fixedOptions = "fixed_options"
        case trials
    }

    public init(fixedOptions: MeasurementMapperFixedOptions) {
        self.fixedOptions = fixedOptions
        trials = [
            MeasurementMapperCadenceTrial(
                ordinal: 1, name: "mapper-cadence-01-1p1", ratio: 1.1),
            MeasurementMapperCadenceTrial(
                ordinal: 2, name: "mapper-cadence-02-1p4", ratio: 1.4),
            MeasurementMapperCadenceTrial(
                ordinal: 3, name: "mapper-cadence-03-1p4", ratio: 1.4),
            MeasurementMapperCadenceTrial(
                ordinal: 4, name: "mapper-cadence-04-1p1", ratio: 1.1),
            MeasurementMapperCadenceTrial(
                ordinal: 5, name: "mapper-cadence-05-1p1", ratio: 1.1),
            MeasurementMapperCadenceTrial(
                ordinal: 6, name: "mapper-cadence-06-1p4", ratio: 1.4),
            MeasurementMapperCadenceTrial(
                ordinal: 7, name: "mapper-cadence-07-1p4", ratio: 1.4),
            MeasurementMapperCadenceTrial(
                ordinal: 8, name: "mapper-cadence-08-1p1", ratio: 1.1),
        ]
    }

    #if !BASELINE_ADAPTER
    public func mapperOptions(
        for trial: MeasurementMapperCadenceTrial
    ) throws -> ColmapMapperOptions {
        try fixedOptions.mapperOptions(ratio: trial.ratio)
    }
    #endif
}

public enum MeasurementFrozenDatabaseCloneStrategy: String, Codable, Sendable {
    case apfsClone = "apfs_clone"
    case descriptorCopy = "descriptor_copy"
}

public struct MeasurementFrozenDatabaseSourceEvidence: Codable, Sendable, Equatable {
    public let sourceName: String
    public let parentDeviceID: UInt64
    public let parentInode: UInt64
    public let deviceID: UInt64
    public let inode: UInt64
    public let linkCount: UInt64
    public let byteCount: Int64
    public let mode: UInt32
    public let ownerUID: UInt32
    public let ownerGID: UInt32
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let companionNames: [String]
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case sourceName = "source_name"
        case parentDeviceID = "parent_device_id"
        case parentInode = "parent_inode"
        case deviceID = "device_id"
        case inode
        case linkCount = "link_count"
        case byteCount = "byte_count"
        case mode
        case ownerUID = "owner_uid"
        case ownerGID = "owner_gid"
        case modifiedSeconds = "modified_seconds"
        case modifiedNanoseconds = "modified_nanoseconds"
        case changedSeconds = "changed_seconds"
        case changedNanoseconds = "changed_nanoseconds"
        case companionNames = "companion_names"
        case sha256
    }
}

public struct MeasurementFrozenDatabaseCloneEvidence: Codable, Sendable, Equatable {
    public let trialOrdinal: Int
    public let trialName: String
    public let destinationName: String
    public let destinationParentDeviceID: UInt64
    public let destinationParentInode: UInt64
    public let strategy: MeasurementFrozenDatabaseCloneStrategy
    public let destinationDeviceID: UInt64
    public let destinationInode: UInt64
    public let destinationLinkCount: UInt64
    public let destinationByteCount: Int64
    public let destinationMode: UInt32
    public let destinationOwnerUID: UInt32
    public let destinationOwnerGID: UInt32
    public let destinationModifiedSeconds: Int64
    public let destinationModifiedNanoseconds: Int64
    public let destinationChangedSeconds: Int64
    public let destinationChangedNanoseconds: Int64
    public let destinationSHA256: String

    enum CodingKeys: String, CodingKey {
        case trialOrdinal = "trial_ordinal"
        case trialName = "trial_name"
        case destinationName = "destination_name"
        case destinationParentDeviceID = "destination_parent_device_id"
        case destinationParentInode = "destination_parent_inode"
        case strategy = "clone_strategy"
        case destinationDeviceID = "destination_device_id"
        case destinationInode = "destination_inode"
        case destinationLinkCount = "destination_link_count"
        case destinationByteCount = "destination_byte_count"
        case destinationMode = "destination_mode"
        case destinationOwnerUID = "destination_owner_uid"
        case destinationOwnerGID = "destination_owner_gid"
        case destinationModifiedSeconds = "destination_modified_seconds"
        case destinationModifiedNanoseconds = "destination_modified_nanoseconds"
        case destinationChangedSeconds = "destination_changed_seconds"
        case destinationChangedNanoseconds = "destination_changed_nanoseconds"
        case destinationSHA256 = "destination_sha256"
    }
}

public struct MeasurementFrozenDatabasePostRunEvidence: Codable, Sendable, Equatable {
    public let destinationName: String
    public let destinationParentDeviceID: UInt64
    public let destinationParentInode: UInt64
    public let destinationDeviceID: UInt64
    public let destinationInode: UInt64
    public let destinationLinkCount: UInt64
    public let destinationByteCount: Int64
    public let destinationMode: UInt32
    public let destinationOwnerUID: UInt32
    public let destinationOwnerGID: UInt32
    public let destinationModifiedSeconds: Int64
    public let destinationModifiedNanoseconds: Int64
    public let destinationChangedSeconds: Int64
    public let destinationChangedNanoseconds: Int64
    public let destinationSHA256: String

    enum CodingKeys: String, CodingKey {
        case destinationName = "destination_name"
        case destinationParentDeviceID = "destination_parent_device_id"
        case destinationParentInode = "destination_parent_inode"
        case destinationDeviceID = "destination_device_id"
        case destinationInode = "destination_inode"
        case destinationLinkCount = "destination_link_count"
        case destinationByteCount = "destination_byte_count"
        case destinationMode = "destination_mode"
        case destinationOwnerUID = "destination_owner_uid"
        case destinationOwnerGID = "destination_owner_gid"
        case destinationModifiedSeconds = "destination_modified_seconds"
        case destinationModifiedNanoseconds = "destination_modified_nanoseconds"
        case destinationChangedSeconds = "destination_changed_seconds"
        case destinationChangedNanoseconds = "destination_changed_nanoseconds"
        case destinationSHA256 = "destination_sha256"
    }
}

public final class MeasurementFrozenDatabaseTrialLease: @unchecked Sendable {
    typealias WatcherOperation = (Int32) throws -> Int32

    public let evidence: MeasurementFrozenDatabaseCloneEvidence
    public let databaseURL: URL

    private let destinationParentURL: URL
    private let destinationName: String
    private let destinationParentDescriptor: Int32
    private let databaseDescriptor: Int32
    private let watcherDescriptor: Int32
    private let parentStatus: DirectoryStatus
    private let databaseStatus: FileStatus
    private var observedPathMutationFlags: UInt32 = 0
    private let lock = NSLock()

    private init(
        evidence: MeasurementFrozenDatabaseCloneEvidence,
        databaseURL: URL,
        destinationParentURL: URL,
        destinationName: String,
        destinationParentDescriptor: Int32,
        databaseDescriptor: Int32,
        watcherDescriptor: Int32,
        parentStatus: DirectoryStatus,
        databaseStatus: FileStatus
    ) {
        self.evidence = evidence
        self.databaseURL = databaseURL
        self.destinationParentURL = destinationParentURL
        self.destinationName = destinationName
        self.destinationParentDescriptor = destinationParentDescriptor
        self.databaseDescriptor = databaseDescriptor
        self.watcherDescriptor = watcherDescriptor
        self.parentStatus = parentStatus
        self.databaseStatus = databaseStatus
    }

    deinit {
        Darwin.close(watcherDescriptor)
        Darwin.close(databaseDescriptor)
        Darwin.close(destinationParentDescriptor)
    }

    @discardableResult
    public func revalidatePreRunUnchanged() throws -> MeasurementFrozenDatabaseCloneEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireNoObservedPathMutation()
        let status = try revalidateBoundIdentity()
        try requireNoObservedPathMutation()
        guard status == databaseStatus, status.matches(evidence) else {
            throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                "trial changed before mapper launch"
            )
        }
        return evidence
    }

    @discardableResult
    public func finalizePostRun() throws -> MeasurementFrozenDatabasePostRunEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireNoObservedPathMutation()
        let statusBeforeHash = try revalidateBoundIdentity()
        let digest = try Self.sha256(
            descriptor: databaseDescriptor,
            expectedByteCount: statusBeforeHash.byteCount
        )
        let statusAfterHash = try revalidateBoundIdentity()
        try requireNoObservedPathMutation()
        guard statusAfterHash == statusBeforeHash else {
            throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                "trial changed while final evidence was measured"
            )
        }
        return MeasurementFrozenDatabasePostRunEvidence(
            destinationName: destinationName,
            destinationParentDeviceID: parentStatus.deviceID,
            destinationParentInode: parentStatus.inode,
            destinationDeviceID: statusAfterHash.deviceID,
            destinationInode: statusAfterHash.inode,
            destinationLinkCount: statusAfterHash.linkCount,
            destinationByteCount: statusAfterHash.byteCount,
            destinationMode: statusAfterHash.mode,
            destinationOwnerUID: statusAfterHash.ownerUID,
            destinationOwnerGID: statusAfterHash.ownerGID,
            destinationModifiedSeconds: statusAfterHash.modifiedSeconds,
            destinationModifiedNanoseconds: statusAfterHash.modifiedNanoseconds,
            destinationChangedSeconds: statusAfterHash.changedSeconds,
            destinationChangedNanoseconds: statusAfterHash.changedNanoseconds,
            destinationSHA256: digest
        )
    }

    fileprivate static func capture(
        evidence: MeasurementFrozenDatabaseCloneEvidence,
        destinationParentURL: URL,
        destinationParentDescriptor: Int32,
        destinationName: String,
        watcherOperation: WatcherOperation
    ) throws -> MeasurementFrozenDatabaseTrialLease {
        let normalizedParent = destinationParentURL.standardizedFileURL
        let databaseURL = normalizedParent.appendingPathComponent(
            destinationName,
            isDirectory: false
        )
        guard databaseURL.isFileURL,
              databaseURL.path.hasPrefix("/"),
              databaseURL.deletingLastPathComponent().standardizedFileURL == normalizedParent,
              databaseURL.lastPathComponent == destinationName,
              evidence.destinationName == destinationName else {
            throw MeasurementFrozenDatabaseError.invalidLeafName(destinationName)
        }
        let parent = try openAt(
            parentDescriptor: destinationParentDescriptor,
            leaf: ".",
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            operation: "retain trial parent"
        )
        do {
            let database = try openAt(
                parentDescriptor: parent,
                leaf: destinationName,
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                operation: "retain trial database"
            )
            do {
                let parentStatus = try directoryStatus(
                    descriptor: parent,
                    operation: "stat retained trial parent"
                )
                let databaseStatus = try fileStatus(
                    descriptor: database,
                    operation: "stat retained trial database"
                )
                let pathStatus = try fileStatusAt(
                    parentDescriptor: parent,
                    leaf: destinationName,
                    operation: "stat retained trial database leaf"
                )
                guard parentStatus.deviceID == evidence.destinationParentDeviceID,
                      parentStatus.inode == evidence.destinationParentInode,
                      parentStatus.isPrivateWritableDirectory,
                      databaseStatus == pathStatus,
                      databaseStatus.matches(evidence) else {
                    throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                        "trial lease capture"
                    )
                }
                try revalidateParentPath(
                    url: normalizedParent,
                    expected: parentStatus
                )
                if let companion = try firstCompanion(
                    parentDescriptor: parent,
                    destinationName: destinationName
                ) {
                    throw MeasurementFrozenDatabaseError.sourceCompanion(companion)
                }
                let digest = try sha256(
                    descriptor: database,
                    expectedByteCount: databaseStatus.byteCount
                )
                let finalDatabaseStatus = try fileStatus(
                    descriptor: database,
                    operation: "restat retained trial database"
                )
                let finalPathStatus = try fileStatusAt(
                    parentDescriptor: parent,
                    leaf: destinationName,
                    operation: "restat retained trial database leaf"
                )
                guard digest == evidence.destinationSHA256,
                      finalDatabaseStatus == databaseStatus,
                      finalPathStatus == databaseStatus else {
                    throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                        "trial lease digest"
                    )
                }
                let watcher = try watcherOperation(database)
                do {
                    let watchedDatabaseStatus = try fileStatus(
                        descriptor: database,
                        operation: "stat watched trial database"
                    )
                    let watchedPathStatus = try fileStatusAt(
                        parentDescriptor: parent,
                        leaf: destinationName,
                        operation: "stat watched trial database leaf"
                    )
                    let watchedFlags = try pollPathMutationFlags(watcherDescriptor: watcher)
                    guard watchedFlags == 0 else {
                        throw MeasurementFrozenDatabaseError.trialPathMutation(watchedFlags)
                    }
                    guard watchedDatabaseStatus == databaseStatus,
                          watchedPathStatus == databaseStatus else {
                        throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                            "watched trial lease identity"
                        )
                    }
                    return MeasurementFrozenDatabaseTrialLease(
                        evidence: evidence,
                        databaseURL: databaseURL,
                        destinationParentURL: normalizedParent,
                        destinationName: destinationName,
                        destinationParentDescriptor: parent,
                        databaseDescriptor: database,
                        watcherDescriptor: watcher,
                        parentStatus: parentStatus,
                        databaseStatus: databaseStatus
                    )
                } catch {
                    Darwin.close(watcher)
                    throw error
                }
            } catch {
                Darwin.close(database)
                throw error
            }
        } catch {
            Darwin.close(parent)
            throw error
        }
    }

    private func revalidateBoundIdentity() throws -> FileStatus {
        try Task.checkCancellation()
        let currentParent = try Self.directoryStatus(
            descriptor: destinationParentDescriptor,
            operation: "restat trial parent"
        )
        guard currentParent == parentStatus,
              currentParent.isPrivateWritableDirectory else {
            throw MeasurementFrozenDatabaseError.unsafeParent(
                destinationParentURL.lastPathComponent
            )
        }
        try Self.revalidateParentPath(
            url: destinationParentURL,
            expected: parentStatus
        )
        if let companion = try Self.firstCompanion(
            parentDescriptor: destinationParentDescriptor,
            destinationName: destinationName
        ) {
            throw MeasurementFrozenDatabaseError.sourceCompanion(companion)
        }
        let descriptorStatus = try Self.fileStatus(
            descriptor: databaseDescriptor,
            operation: "restat trial database"
        )
        let pathStatus = try Self.fileStatusAt(
            parentDescriptor: destinationParentDescriptor,
            leaf: destinationName,
            operation: "restat trial database leaf"
        )
        guard descriptorStatus == pathStatus,
              descriptorStatus.matchesBoundIdentity(initial: databaseStatus) else {
            throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                "trial lease changed"
            )
        }
        return descriptorStatus
    }

    private func requireNoObservedPathMutation() throws {
        observedPathMutationFlags |= try Self.pollPathMutationFlags(
            watcherDescriptor: watcherDescriptor
        )
        guard observedPathMutationFlags == 0 else {
            throw MeasurementFrozenDatabaseError.trialPathMutation(
                observedPathMutationFlags
            )
        }
    }

    private static let monitoredPathMutationFlags = UInt32(
        NOTE_RENAME | NOTE_DELETE | NOTE_LINK | NOTE_REVOKE
    )

    private static func pollPathMutationFlags(watcherDescriptor: Int32) throws -> UInt32 {
        var observedFlags: UInt32 = 0
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            var event = kevent64_s()
            let count = Darwin.kevent64(
                watcherDescriptor,
                nil,
                0,
                &event,
                1,
                0,
                &timeout
            )
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw MeasurementFrozenDatabaseError.trialWatcherUnavailable(
                    "poll trial database",
                    errno
                )
            }
            if count == 0 { return observedFlags }
            observedFlags |= event.fflags & monitoredPathMutationFlags
        }
    }

    static func makePathMutationWatcher(databaseDescriptor: Int32) throws -> Int32 {
        let watcher = Darwin.kqueue()
        guard watcher >= 0 else {
            throw MeasurementFrozenDatabaseError.trialWatcherUnavailable(
                "create trial database watcher",
                errno
            )
        }
        do {
            let descriptorFlags = Darwin.fcntl(watcher, F_GETFD)
            guard descriptorFlags >= 0,
                  Darwin.fcntl(watcher, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                throw MeasurementFrozenDatabaseError.trialWatcherUnavailable(
                    "protect trial database watcher",
                    errno
                )
            }
            var change = kevent64_s()
            change.ident = UInt64(databaseDescriptor)
            change.filter = Int16(EVFILT_VNODE)
            change.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
            change.fflags = monitoredPathMutationFlags
            guard Darwin.kevent64(watcher, &change, 1, nil, 0, 0, nil) == 0 else {
                throw MeasurementFrozenDatabaseError.trialWatcherUnavailable(
                    "register trial database watcher",
                    errno
                )
            }
            return watcher
        } catch {
            Darwin.close(watcher)
            throw error
        }
    }

    private static func revalidateParentPath(
        url: URL,
        expected: DirectoryStatus
    ) throws {
        var raw = stat()
        let result = retryingEINTR { Darwin.lstat(url.path, &raw) }
        guard result == 0,
              DirectoryStatus(raw) == expected,
              expected.isPrivateWritableDirectory else {
            throw MeasurementFrozenDatabaseError.unsafeParent(url.lastPathComponent)
        }
    }

    private static func firstCompanion(
        parentDescriptor: Int32,
        destinationName: String
    ) throws -> String? {
        try Task.checkCancellation()
        let enumerationDescriptor = try openAt(
            parentDescriptor: parentDescriptor,
            leaf: ".",
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            operation: "scan trial companions"
        )
        guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
            let code = errno
            Darwin.close(enumerationDescriptor)
            throw MeasurementFrozenDatabaseError.ioFailure(
                "scan trial companions", code
            )
        }
        defer { Darwin.closedir(stream) }
        var companions: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno == EINTR { continue }
                guard errno == 0 else {
                    throw MeasurementFrozenDatabaseError.ioFailure(
                        "scan trial companions", errno
                    )
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name.hasPrefix(destinationName + "-") {
                companions.append(name)
            }
        }
        return companions.sorted().first
    }

    private static func sha256(
        descriptor: Int32,
        expectedByteCount: Int64
    ) throws -> String {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count: Int
            while true {
                let result = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(descriptor, bytes.baseAddress, bytes.count, offset)
                }
                if result >= 0 {
                    count = result
                    break
                }
                if errno != EINTR {
                    throw MeasurementFrozenDatabaseError.ioFailure(
                        "read retained trial database", errno
                    )
                }
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            offset += off_t(count)
        }
        guard offset == off_t(expectedByteCount) else {
            throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                "trial byte count"
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func openAt(
        parentDescriptor: Int32,
        leaf: String,
        flags: Int32,
        operation: String
    ) throws -> Int32 {
        while true {
            let descriptor = leaf.withCString {
                Darwin.openat(parentDescriptor, $0, flags)
            }
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
    }

    private static func fileStatus(
        descriptor: Int32,
        operation: String
    ) throws -> FileStatus {
        var raw = stat()
        let result = retryingEINTR { Darwin.fstat(descriptor, &raw) }
        guard result == 0 else {
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
        return FileStatus(raw)
    }

    private static func fileStatusAt(
        parentDescriptor: Int32,
        leaf: String,
        operation: String
    ) throws -> FileStatus {
        var raw = stat()
        let result = retryingEINTR {
            leaf.withCString {
                Darwin.fstatat(parentDescriptor, $0, &raw, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard result == 0 else {
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
        return FileStatus(raw)
    }

    private static func directoryStatus(
        descriptor: Int32,
        operation: String
    ) throws -> DirectoryStatus {
        var raw = stat()
        let result = retryingEINTR { Darwin.fstat(descriptor, &raw) }
        guard result == 0 else {
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
        return DirectoryStatus(raw)
    }

    private static func retryingEINTR(_ operation: () -> Int32) -> Int32 {
        while true {
            let result = operation()
            if result >= 0 || errno != EINTR { return result }
        }
    }

    private struct DirectoryStatus: Equatable {
        let deviceID: UInt64
        let inode: UInt64
        let mode: UInt32
        let ownerUID: UInt32
        let ownerGID: UInt32

        var isPrivateWritableDirectory: Bool {
            mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
                && ownerUID == UInt32(geteuid())
                && mode & UInt32(0o7777) == UInt32(0o700)
        }

        init(_ status: stat) {
            deviceID = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            mode = UInt32(status.st_mode)
            ownerUID = UInt32(status.st_uid)
            ownerGID = UInt32(status.st_gid)
        }
    }

    private struct FileStatus: Equatable {
        let deviceID: UInt64
        let inode: UInt64
        let linkCount: UInt64
        let byteCount: Int64
        let mode: UInt32
        let ownerUID: UInt32
        let ownerGID: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            deviceID = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            linkCount = UInt64(status.st_nlink)
            byteCount = Int64(status.st_size)
            mode = UInt32(status.st_mode)
            ownerUID = UInt32(status.st_uid)
            ownerGID = UInt32(status.st_gid)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }

        func matches(_ evidence: MeasurementFrozenDatabaseCloneEvidence) -> Bool {
            deviceID == evidence.destinationDeviceID
                && inode == evidence.destinationInode
                && linkCount == 1
                && linkCount == evidence.destinationLinkCount
                && byteCount == evidence.destinationByteCount
                && mode == UInt32(S_IFREG | S_IRUSR | S_IWUSR)
                && mode == evidence.destinationMode
                && ownerUID == UInt32(geteuid())
                && ownerUID == evidence.destinationOwnerUID
                && ownerGID == evidence.destinationOwnerGID
                && modifiedSeconds == evidence.destinationModifiedSeconds
                && modifiedNanoseconds == evidence.destinationModifiedNanoseconds
                && changedSeconds == evidence.destinationChangedSeconds
                && changedNanoseconds == evidence.destinationChangedNanoseconds
        }

        func matchesBoundIdentity(initial: FileStatus) -> Bool {
            deviceID == initial.deviceID
                && inode == initial.inode
                && linkCount == 1
                && byteCount > 0
                && mode == UInt32(S_IFREG | S_IRUSR | S_IWUSR)
                && ownerUID == UInt32(geteuid())
                && ownerGID == initial.ownerGID
        }
    }
}

public enum MeasurementFrozenDatabaseError: Error, LocalizedError, Equatable {
    case invalidLeafName(String)
    case unsafeParent(String)
    case unsafeSource(String)
    case sourceCompanion(String)
    case destinationExists(String)
    case sourceChanged
    case cloneFailed(Int32)
    case cloneValidationFailed(String)
    case trialWatcherUnavailable(String, Int32)
    case trialPathMutation(UInt32)
    case ioFailure(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidLeafName(let name):
            "The frozen-database leaf name is invalid: \(name)."
        case .unsafeParent(let name):
            "The frozen-database parent is not a private stable directory: \(name)."
        case .unsafeSource(let name):
            "The frozen database is not an ordinary private source file: \(name)."
        case .sourceCompanion(let name):
            "The frozen database has a live SQLite companion: \(name)."
        case .destinationExists(let name):
            "The frozen-database destination already exists: \(name)."
        case .sourceChanged:
            "The frozen database changed after its evidence was captured."
        case .cloneFailed(let code):
            "The frozen database could not be cloned (errno \(code))."
        case .cloneValidationFailed(let detail):
            "The frozen-database clone failed validation: \(detail)."
        case .trialWatcherUnavailable(let operation, let code):
            "The frozen-database \(operation) operation failed (errno \(code))."
        case .trialPathMutation(let flags):
            "The frozen-database trial pathname changed during execution (flags \(flags))."
        case .ioFailure(let operation, let code):
            "The frozen-database \(operation) operation failed (errno \(code))."
        }
    }
}

public final class MeasurementFrozenCOLMAPDatabase: @unchecked Sendable {
    typealias CloneOperation = (
        _ sourceDescriptor: Int32,
        _ destinationParentDescriptor: Int32,
        _ destinationLeaf: String,
        _ flags: UInt32
    ) -> Int32
    typealias Checkpoint = () throws -> Void

    public let sourceEvidence: MeasurementFrozenDatabaseSourceEvidence

    private let sourceParentURL: URL
    private let destinationParentURL: URL
    private let sourceParentDescriptor: Int32
    private let destinationParentDescriptor: Int32
    private let sourceDescriptor: Int32
    private let sourceParentStatus: DirectoryStatus
    private let destinationParentStatus: DirectoryStatus
    private let sourceStatus: FileStatus
    private let sourceName: String
    private let cloneOperation: CloneOperation
    private let postPublicationCheckpoint: Checkpoint
    private let trialWatcherOperation: MeasurementFrozenDatabaseTrialLease.WatcherOperation
    private let lock = NSLock()

    public convenience init(
        sourceParent: URL,
        sourceName: String,
        destinationParent: URL
    ) throws {
        try self.init(
            sourceParent: sourceParent,
            sourceName: sourceName,
            destinationParent: destinationParent,
            cloneOperation: Self.performClone,
            captureCheckpoint: {},
            postPublicationCheckpoint: {}
        )
    }

    init(
        sourceParent: URL,
        sourceName: String,
        destinationParent: URL,
        cloneOperation: @escaping CloneOperation,
        captureCheckpoint: @escaping Checkpoint = {},
        postPublicationCheckpoint: @escaping Checkpoint = {},
        trialWatcherOperation: @escaping MeasurementFrozenDatabaseTrialLease.WatcherOperation =
            MeasurementFrozenDatabaseTrialLease.makePathMutationWatcher
    ) throws {
        try Self.requireLeafName(sourceName)
        try Task.checkCancellation()
        let captured = try Self.capture(
            sourceParent: sourceParent,
            sourceName: sourceName,
            destinationParent: destinationParent,
            captureCheckpoint: captureCheckpoint
        )
        self.sourceParentURL = sourceParent
        self.destinationParentURL = destinationParent
        sourceParentDescriptor = captured.sourceParentDescriptor
        destinationParentDescriptor = captured.destinationParentDescriptor
        sourceDescriptor = captured.sourceDescriptor
        sourceParentStatus = captured.sourceParentStatus
        destinationParentStatus = captured.destinationParentStatus
        sourceStatus = captured.sourceStatus
        self.sourceName = sourceName
        self.cloneOperation = cloneOperation
        self.postPublicationCheckpoint = postPublicationCheckpoint
        self.trialWatcherOperation = trialWatcherOperation
        sourceEvidence = MeasurementFrozenDatabaseSourceEvidence(
            sourceName: sourceName,
            parentDeviceID: sourceParentStatus.deviceID,
            parentInode: sourceParentStatus.inode,
            deviceID: sourceStatus.deviceID,
            inode: sourceStatus.inode,
            linkCount: sourceStatus.linkCount,
            byteCount: sourceStatus.byteCount,
            mode: sourceStatus.mode,
            ownerUID: sourceStatus.ownerUID,
            ownerGID: sourceStatus.ownerGID,
            modifiedSeconds: sourceStatus.modifiedSeconds,
            modifiedNanoseconds: sourceStatus.modifiedNanoseconds,
            changedSeconds: sourceStatus.changedSeconds,
            changedNanoseconds: sourceStatus.changedNanoseconds,
            companionNames: [],
            sha256: captured.sha256
        )
    }

    deinit {
        Darwin.close(sourceDescriptor)
        Darwin.close(destinationParentDescriptor)
        Darwin.close(sourceParentDescriptor)
    }

    public func makeTrialClone(
        for trial: MeasurementMapperCadenceTrial,
        destinationName: String
    ) throws -> MeasurementFrozenDatabaseCloneEvidence {
        try makeTrialCloneLease(
            for: trial,
            destinationName: destinationName
        ).evidence
    }

    public func makeTrialCloneLease(
        for trial: MeasurementMapperCadenceTrial,
        destinationName: String
    ) throws -> MeasurementFrozenDatabaseTrialLease {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        try Self.requireLeafName(destinationName)
        try revalidateSourceStatOnlyLocked()
        try requireAbsent(destinationName)

        let stagingName = ".\(UUID().uuidString.lowercased()).frozen-db"
        try requireAbsent(stagingName)
        var cloneDescriptor: Int32 = -1
        defer {
            if cloneDescriptor >= 0 { Darwin.close(cloneDescriptor) }
        }

            let strategy = try createStagingClone(named: stagingName)
            try Task.checkCancellation()
            cloneDescriptor = try Self.openFile(
                parentDescriptor: destinationParentDescriptor,
                leaf: stagingName,
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                operation: "open clone"
            )
            try Self.setPermissions(
                descriptor: cloneDescriptor,
                permissions: S_IRUSR | S_IWUSR,
                operation: "make trial clone writable"
            )
            try Self.sync(descriptor: cloneDescriptor, operation: "sync writable clone")
            let rawCloneStatus = try Self.fileStatus(
                descriptor: cloneDescriptor,
                operation: "stat clone"
            )
            let rawClonePathStatus = try statusAt(
                parentDescriptor: destinationParentDescriptor,
                leaf: stagingName,
                operation: "stat clone leaf"
            )
            guard rawClonePathStatus == rawCloneStatus else {
                throw MeasurementFrozenDatabaseError.cloneValidationFailed("clone binding")
            }
            try validateCloneStatus(rawCloneStatus, strategy: strategy)
            let cloneSHA256 = try Self.sha256(
                descriptor: cloneDescriptor,
                expectedByteCount: sourceStatus.byteCount
            )
            guard cloneSHA256 == sourceEvidence.sha256 else {
                throw MeasurementFrozenDatabaseError.cloneValidationFailed("byte digest")
            }
            try Self.sync(descriptor: cloneDescriptor, operation: "sync clone")
            try revalidateSourceStatOnlyLocked()
            try requireAbsent(destinationName)
            try Self.renameExclusive(
                parentDescriptor: destinationParentDescriptor,
                sourceName: stagingName,
                destinationName: destinationName
            )
            try postPublicationCheckpoint()
            let publishedStatus = try statusAt(
                parentDescriptor: destinationParentDescriptor,
                leaf: destinationName,
                operation: "stat published clone"
            )
            guard publishedStatus.sameObjectAndContents(as: rawCloneStatus) else {
                throw MeasurementFrozenDatabaseError.cloneValidationFailed("published identity")
            }
            try Self.sync(
                descriptor: destinationParentDescriptor,
                operation: "sync destination directory"
            )
            try revalidateSourceStatOnlyLocked()
            try revalidateDestinationParent()
            let finalDescriptorStatus = try Self.fileStatus(
                descriptor: cloneDescriptor,
                operation: "restat published clone"
            )
            let finalPathStatus = try statusAt(
                parentDescriptor: destinationParentDescriptor,
                leaf: destinationName,
                operation: "restat published clone leaf"
            )
            guard finalDescriptorStatus == publishedStatus,
                  finalPathStatus == publishedStatus else {
                throw MeasurementFrozenDatabaseError.cloneValidationFailed(
                    "final published identity"
                )
            }
            let evidence = MeasurementFrozenDatabaseCloneEvidence(
                trialOrdinal: trial.ordinal,
                trialName: trial.name,
                destinationName: destinationName,
                destinationParentDeviceID: destinationParentStatus.deviceID,
                destinationParentInode: destinationParentStatus.inode,
                strategy: strategy,
                destinationDeviceID: finalDescriptorStatus.deviceID,
                destinationInode: finalDescriptorStatus.inode,
                destinationLinkCount: finalDescriptorStatus.linkCount,
                destinationByteCount: finalDescriptorStatus.byteCount,
                destinationMode: finalDescriptorStatus.mode,
                destinationOwnerUID: finalDescriptorStatus.ownerUID,
                destinationOwnerGID: finalDescriptorStatus.ownerGID,
                destinationModifiedSeconds: finalDescriptorStatus.modifiedSeconds,
                destinationModifiedNanoseconds: finalDescriptorStatus.modifiedNanoseconds,
                destinationChangedSeconds: finalDescriptorStatus.changedSeconds,
                destinationChangedNanoseconds: finalDescriptorStatus.changedNanoseconds,
                destinationSHA256: cloneSHA256
            )
            return try MeasurementFrozenDatabaseTrialLease.capture(
                evidence: evidence,
                destinationParentURL: destinationParentURL,
                destinationParentDescriptor: destinationParentDescriptor,
                destinationName: destinationName,
                watcherOperation: trialWatcherOperation
            )
    }

    @discardableResult
    public func revalidateSourceStatOnly() throws -> MeasurementFrozenDatabaseSourceEvidence {
        lock.lock()
        defer { lock.unlock() }
        try revalidateSourceStatOnlyLocked()
        return sourceEvidence
    }

    @discardableResult
    public func finalizeSourceRehash() throws -> MeasurementFrozenDatabaseSourceEvidence {
        lock.lock()
        defer { lock.unlock() }
        try revalidateSourceStatOnlyLocked()
        let finalSHA256 = try Self.sha256(
            descriptor: sourceDescriptor,
            expectedByteCount: sourceStatus.byteCount
        )
        try revalidateSourceStatOnlyLocked()
        guard finalSHA256 == sourceEvidence.sha256 else {
            throw MeasurementFrozenDatabaseError.sourceChanged
        }
        return sourceEvidence
    }

    private func createStagingClone(
        named stagingName: String
    ) throws -> MeasurementFrozenDatabaseCloneStrategy {
        let flags = UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
        while true {
            try Task.checkCancellation()
            let code = cloneOperation(
                sourceDescriptor,
                destinationParentDescriptor,
                stagingName,
                flags
            )
            switch code {
            case 0:
                return .apfsClone
            case EINTR:
                continue
            case EXDEV, ENOTSUP, ENOSYS:
                try descriptorCopy(to: stagingName)
                return .descriptorCopy
            default:
                throw MeasurementFrozenDatabaseError.cloneFailed(code)
            }
        }
    }

    private func descriptorCopy(to stagingName: String) throws {
        let output = try Self.openFile(
            parentDescriptor: destinationParentDescriptor,
            leaf: stagingName,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode: S_IRUSR | S_IWUSR,
            operation: "create copy fallback"
        )
        defer {
            Darwin.close(output)
        }
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = try Self.read(
                descriptor: sourceDescriptor,
                buffer: &buffer,
                offset: offset
            )
            if count == 0 { break }
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        output,
                        bytes.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw MeasurementFrozenDatabaseError.ioFailure("write copy fallback", errno)
                }
                written += result
            }
            offset += off_t(count)
        }
        guard offset == off_t(sourceStatus.byteCount) else {
            throw MeasurementFrozenDatabaseError.sourceChanged
        }
        try Self.setPermissions(
            descriptor: output,
            permissions: S_IRUSR | S_IWUSR,
            operation: "set copy mode"
        )
        try Self.sync(descriptor: output, operation: "sync copy fallback")
    }

    private func validateCloneStatus(
        _ clone: FileStatus,
        strategy: MeasurementFrozenDatabaseCloneStrategy
    ) throws {
        let expectedMode = UInt32(S_IFREG | S_IRUSR | S_IWUSR)
        guard clone.isRegular,
              clone.linkCount == 1,
              clone.inode != sourceStatus.inode,
              clone.byteCount == sourceStatus.byteCount,
              clone.mode == expectedMode,
              clone.ownerUID == sourceStatus.ownerUID,
              clone.ownerGID == sourceStatus.ownerGID else {
            throw MeasurementFrozenDatabaseError.cloneValidationFailed("file identity")
        }
        if strategy == .apfsClone, clone.deviceID != sourceStatus.deviceID {
            throw MeasurementFrozenDatabaseError.cloneValidationFailed("clone device")
        }
    }

    private func revalidateSourceStatOnlyLocked() throws {
        try Task.checkCancellation()
        try Self.revalidateDirectory(
            url: sourceParentURL,
            descriptor: sourceParentDescriptor,
            expected: sourceParentStatus,
            requiresWrite: false
        )
        try revalidateDestinationParent()
        if let companion = try Self.firstCompanion(
            parentDescriptor: sourceParentDescriptor,
            sourceName: sourceName
        ) {
            throw MeasurementFrozenDatabaseError.sourceCompanion(companion)
        }
        let descriptorStatus = try Self.fileStatus(
            descriptor: sourceDescriptor,
            operation: "stat source"
        )
        let pathStatus = try statusAt(
            parentDescriptor: sourceParentDescriptor,
            leaf: sourceName,
            operation: "stat source leaf"
        )
        guard descriptorStatus == sourceStatus, pathStatus == sourceStatus else {
            throw MeasurementFrozenDatabaseError.sourceChanged
        }
    }

    private func revalidateDestinationParent() throws {
        try Self.revalidateDirectory(
            url: destinationParentURL,
            descriptor: destinationParentDescriptor,
            expected: destinationParentStatus,
            requiresWrite: true
        )
    }

    private func requireAbsent(_ leaf: String) throws {
        var status = stat()
        while true {
            errno = 0
            let result = leaf.withCString {
                Darwin.fstatat(destinationParentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 {
                throw MeasurementFrozenDatabaseError.destinationExists(leaf)
            }
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return }
            throw MeasurementFrozenDatabaseError.ioFailure("check destination", code)
        }
    }

    private func statusAt(
        parentDescriptor: Int32,
        leaf: String,
        operation: String
    ) throws -> FileStatus {
        var status = stat()
        while true {
            let result = leaf.withCString {
                Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 { return FileStatus(status) }
            if errno == EINTR { continue }
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
    }

    private struct Capture {
        let sourceParentDescriptor: Int32
        let destinationParentDescriptor: Int32
        let sourceDescriptor: Int32
        let sourceParentStatus: DirectoryStatus
        let destinationParentStatus: DirectoryStatus
        let sourceStatus: FileStatus
        let sha256: String
    }

    private static func capture(
        sourceParent: URL,
        sourceName: String,
        destinationParent: URL,
        captureCheckpoint: Checkpoint
    ) throws -> Capture {
        let sourceDirectory = try openPrivateDirectory(
            sourceParent,
            requiresWrite: false
        )
        do {
            let destinationDirectory = try openPrivateDirectory(
                destinationParent,
                requiresWrite: true
            )
            do {
                let source = try openFile(
                    parentDescriptor: sourceDirectory.descriptor,
                    leaf: sourceName,
                    flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    operation: "open source"
                )
                do {
                    let status = try fileStatus(descriptor: source, operation: "stat source")
                    guard status.isRegular,
                          status.linkCount == 1,
                          status.byteCount > 0,
                          status.ownerUID == UInt32(geteuid()),
                          (status.mode & UInt32(0o7000)) == 0 else {
                        throw MeasurementFrozenDatabaseError.unsafeSource(sourceName)
                    }
                    let pathStatus = try fileStatusAt(
                        parentDescriptor: sourceDirectory.descriptor,
                        leaf: sourceName,
                        operation: "stat source leaf"
                    )
                    guard pathStatus == status else {
                        throw MeasurementFrozenDatabaseError.unsafeSource(sourceName)
                    }
                    if let companion = try firstCompanion(
                        parentDescriptor: sourceDirectory.descriptor,
                        sourceName: sourceName
                    ) {
                        throw MeasurementFrozenDatabaseError.sourceCompanion(companion)
                    }
                    try captureCheckpoint()
                    let digest = try sha256(
                        descriptor: source,
                        expectedByteCount: status.byteCount
                    )
                    let finalStatus = try fileStatus(
                        descriptor: source,
                        operation: "restat source"
                    )
                    let finalPathStatus = try fileStatusAt(
                        parentDescriptor: sourceDirectory.descriptor,
                        leaf: sourceName,
                        operation: "restat source leaf"
                    )
                    guard finalStatus == status, finalPathStatus == status else {
                        throw MeasurementFrozenDatabaseError.sourceChanged
                    }
                    try revalidateDirectory(
                        url: sourceParent,
                        descriptor: sourceDirectory.descriptor,
                        expected: sourceDirectory.status,
                        requiresWrite: false
                    )
                    try revalidateDirectory(
                        url: destinationParent,
                        descriptor: destinationDirectory.descriptor,
                        expected: destinationDirectory.status,
                        requiresWrite: true
                    )
                    let frozenStatus: FileStatus
                    if status.mode == UInt32(S_IFREG | S_IRUSR) {
                        frozenStatus = status
                    } else {
                        try setPermissions(
                            descriptor: source,
                            permissions: S_IRUSR,
                            operation: "freeze source"
                        )
                        let changedStatus = try fileStatus(
                            descriptor: source,
                            operation: "stat frozen source"
                        )
                        guard changedStatus.isModeChange(of: status, permissions: S_IRUSR) else {
                            throw MeasurementFrozenDatabaseError.sourceChanged
                        }
                        frozenStatus = changedStatus
                    }
                    try sync(descriptor: source, operation: "sync frozen source")
                    let frozenPathStatus = try fileStatusAt(
                        parentDescriptor: sourceDirectory.descriptor,
                        leaf: sourceName,
                        operation: "stat frozen source leaf"
                    )
                    guard frozenPathStatus == frozenStatus else {
                        throw MeasurementFrozenDatabaseError.sourceChanged
                    }
                    let frozenDigest = try sha256(
                        descriptor: source,
                        expectedByteCount: frozenStatus.byteCount
                    )
                    let finalFrozenStatus = try fileStatus(
                        descriptor: source,
                        operation: "restat frozen source"
                    )
                    let finalFrozenPathStatus = try fileStatusAt(
                        parentDescriptor: sourceDirectory.descriptor,
                        leaf: sourceName,
                        operation: "restat frozen source leaf"
                    )
                    guard frozenDigest == digest,
                          finalFrozenStatus == frozenStatus,
                          finalFrozenPathStatus == frozenStatus else {
                        throw MeasurementFrozenDatabaseError.sourceChanged
                    }
                    if let companion = try firstCompanion(
                        parentDescriptor: sourceDirectory.descriptor,
                        sourceName: sourceName
                    ) {
                        throw MeasurementFrozenDatabaseError.sourceCompanion(companion)
                    }
                    let postScanStatus = try fileStatus(
                        descriptor: source,
                        operation: "restat frozen source after companion scan"
                    )
                    let postScanPathStatus = try fileStatusAt(
                        parentDescriptor: sourceDirectory.descriptor,
                        leaf: sourceName,
                        operation: "restat frozen source leaf after companion scan"
                    )
                    guard postScanStatus == frozenStatus,
                          postScanPathStatus == frozenStatus else {
                        throw MeasurementFrozenDatabaseError.sourceChanged
                    }
                    return Capture(
                        sourceParentDescriptor: sourceDirectory.descriptor,
                        destinationParentDescriptor: destinationDirectory.descriptor,
                        sourceDescriptor: source,
                        sourceParentStatus: sourceDirectory.status,
                        destinationParentStatus: destinationDirectory.status,
                        sourceStatus: frozenStatus,
                        sha256: digest
                    )
                } catch {
                    Darwin.close(source)
                    throw error
                }
            } catch {
                Darwin.close(destinationDirectory.descriptor)
                throw error
            }
        } catch {
            Darwin.close(sourceDirectory.descriptor)
            throw error
        }
    }

    private static func requireLeafName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf8.count <= Int(NAME_MAX),
              !name.contains("/"),
              !name.contains("\\"),
              Array(name.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8),
              name.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && !CharacterSet.illegalCharacters.contains(scalar)
                      && !CharacterSet.newlines.contains(scalar)
              }) else {
            throw MeasurementFrozenDatabaseError.invalidLeafName(name)
        }
    }

    private struct OpenDirectory {
        let descriptor: Int32
        let status: DirectoryStatus
    }

    private static func openPrivateDirectory(
        _ url: URL,
        requiresWrite: Bool
    ) throws -> OpenDirectory {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw MeasurementFrozenDatabaseError.unsafeParent(url.lastPathComponent)
        }
        var pathStatus = stat()
        let pathResult = retryingEINTR {
            Darwin.lstat(url.path, &pathStatus)
        }
        guard pathResult == 0 else {
            throw MeasurementFrozenDatabaseError.unsafeParent(url.lastPathComponent)
        }
        let descriptor = try openPath(
            url.path,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            operation: "open parent"
        )
        do {
            let descriptorStatus = try directoryStatus(
                descriptor: descriptor,
                operation: "stat parent"
            )
            let ownerPermissions = descriptorStatus.mode & UInt32(0o700)
            let requiredPermissions = requiresWrite ? UInt32(0o700) : UInt32(0o500)
            guard descriptorStatus.isDirectory,
                  descriptorStatus.deviceID == UInt64(pathStatus.st_dev),
                  descriptorStatus.inode == UInt64(pathStatus.st_ino),
                  descriptorStatus.ownerUID == UInt32(geteuid()),
                  (descriptorStatus.mode & UInt32(0o077)) == 0,
                  (descriptorStatus.mode & UInt32(0o7000)) == 0,
                  ownerPermissions & requiredPermissions == requiredPermissions else {
                throw MeasurementFrozenDatabaseError.unsafeParent(url.lastPathComponent)
            }
            return OpenDirectory(descriptor: descriptor, status: descriptorStatus)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func revalidateDirectory(
        url: URL,
        descriptor: Int32,
        expected: DirectoryStatus,
        requiresWrite: Bool
    ) throws {
        let descriptorStatus = try directoryStatus(
            descriptor: descriptor,
            operation: "restat parent"
        )
        var pathStatus = stat()
        let result = retryingEINTR { Darwin.lstat(url.path, &pathStatus) }
        let ownerPermissions = descriptorStatus.mode & UInt32(0o700)
        let requiredPermissions = requiresWrite ? UInt32(0o700) : UInt32(0o500)
        guard result == 0,
              descriptorStatus == expected,
              descriptorStatus.deviceID == UInt64(pathStatus.st_dev),
              descriptorStatus.inode == UInt64(pathStatus.st_ino),
              descriptorStatus.ownerUID == UInt32(geteuid()),
              (descriptorStatus.mode & UInt32(0o077)) == 0,
              ownerPermissions & requiredPermissions == requiredPermissions else {
            throw MeasurementFrozenDatabaseError.unsafeParent(url.lastPathComponent)
        }
    }

    private static func firstCompanion(
        parentDescriptor: Int32,
        sourceName: String
    ) throws -> String? {
        try Task.checkCancellation()
        let enumerationDescriptor = try openFile(
            parentDescriptor: parentDescriptor,
            leaf: ".",
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            operation: "open source directory for companion scan"
        )
        guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
            let code = errno
            Darwin.close(enumerationDescriptor)
            throw MeasurementFrozenDatabaseError.ioFailure("scan source companions", code)
        }
        defer { Darwin.closedir(stream) }
        var companions: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno == EINTR { continue }
                guard errno == 0 else {
                    throw MeasurementFrozenDatabaseError.ioFailure(
                        "scan source companions", errno
                    )
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name.hasPrefix(sourceName + "-") {
                companions.append(name)
            }
        }
        return companions.sorted().first
    }

    static func performClone(
        sourceDescriptor: Int32,
        destinationParentDescriptor: Int32,
        destinationLeaf: String,
        flags: UInt32
    ) -> Int32 {
        let result = destinationLeaf.withCString {
            Darwin.fclonefileat(
                sourceDescriptor,
                destinationParentDescriptor,
                $0,
                flags
            )
        }
        return result == 0 ? 0 : errno
    }

    private static func renameExclusive(
        parentDescriptor: Int32,
        sourceName: String,
        destinationName: String
    ) throws {
        while true {
            let result = sourceName.withCString { source in
                destinationName.withCString { destination in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 { return }
            let code = errno
            if code == EINTR { continue }
            if code == EEXIST {
                throw MeasurementFrozenDatabaseError.destinationExists(destinationName)
            }
            throw MeasurementFrozenDatabaseError.ioFailure("publish clone", code)
        }
    }

    private static func sha256(
        descriptor: Int32,
        expectedByteCount: Int64
    ) throws -> String {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = try read(descriptor: descriptor, buffer: &buffer, offset: offset)
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            offset += off_t(count)
        }
        guard offset == off_t(expectedByteCount) else {
            throw MeasurementFrozenDatabaseError.sourceChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func read(
        descriptor: Int32,
        buffer: inout [UInt8],
        offset: off_t
    ) throws -> Int {
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, bytes.count, offset)
            }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw MeasurementFrozenDatabaseError.ioFailure("read database", errno)
        }
    }

    private static func sync(descriptor: Int32, operation: String) throws {
        while true {
            if Darwin.fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
    }

    private static func setPermissions(
        descriptor: Int32,
        permissions: mode_t,
        operation: String
    ) throws {
        let result = retryingEINTR {
            Darwin.fchmod(descriptor, permissions)
        }
        guard result == 0 else {
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
    }

    private static func openPath(
        _ path: String,
        flags: Int32,
        operation: String
    ) throws -> Int32 {
        while true {
            let descriptor = Darwin.open(path, flags)
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
    }

    private static func openFile(
        parentDescriptor: Int32,
        leaf: String,
        flags: Int32,
        mode: mode_t? = nil,
        operation: String
    ) throws -> Int32 {
        while true {
            let descriptor: Int32
            if let mode {
                descriptor = leaf.withCString {
                    Darwin.openat(parentDescriptor, $0, flags, mode)
                }
            } else {
                descriptor = leaf.withCString {
                    Darwin.openat(parentDescriptor, $0, flags)
                }
            }
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
    }

    private static func fileStatus(
        descriptor: Int32,
        operation: String
    ) throws -> FileStatus {
        var status = stat()
        let result = retryingEINTR { Darwin.fstat(descriptor, &status) }
        guard result == 0 else {
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
        return FileStatus(status)
    }

    private static func fileStatusAt(
        parentDescriptor: Int32,
        leaf: String,
        operation: String
    ) throws -> FileStatus {
        var status = stat()
        let result = retryingEINTR {
            leaf.withCString {
                Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard result == 0 else {
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
        return FileStatus(status)
    }

    private static func directoryStatus(
        descriptor: Int32,
        operation: String
    ) throws -> DirectoryStatus {
        var status = stat()
        let result = retryingEINTR { Darwin.fstat(descriptor, &status) }
        guard result == 0 else {
            throw MeasurementFrozenDatabaseError.ioFailure(operation, errno)
        }
        return DirectoryStatus(status)
    }

    private static func retryingEINTR(_ operation: () -> Int32) -> Int32 {
        while true {
            let result = operation()
            if result >= 0 || errno != EINTR { return result }
        }
    }

    private struct DirectoryStatus: Equatable {
        let deviceID: UInt64
        let inode: UInt64
        let mode: UInt32
        let ownerUID: UInt32
        let ownerGID: UInt32

        var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }

        init(_ status: stat) {
            deviceID = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            mode = UInt32(status.st_mode)
            ownerUID = UInt32(status.st_uid)
            ownerGID = UInt32(status.st_gid)
        }
    }

    private struct FileStatus: Equatable {
        let deviceID: UInt64
        let inode: UInt64
        let linkCount: UInt64
        let byteCount: Int64
        let mode: UInt32
        let ownerUID: UInt32
        let ownerGID: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        var isRegular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }

        func sameObjectAndContents(as other: FileStatus) -> Bool {
            deviceID == other.deviceID
                && inode == other.inode
                && linkCount == other.linkCount
                && byteCount == other.byteCount
                && mode == other.mode
                && ownerUID == other.ownerUID
                && ownerGID == other.ownerGID
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }

        func isModeChange(of source: FileStatus, permissions: mode_t) -> Bool {
            deviceID == source.deviceID
                && inode == source.inode
                && linkCount == source.linkCount
                && byteCount == source.byteCount
                && mode == UInt32(S_IFREG | permissions)
                && ownerUID == source.ownerUID
                && ownerGID == source.ownerGID
                && modifiedSeconds == source.modifiedSeconds
                && modifiedNanoseconds == source.modifiedNanoseconds
        }

        init(_ status: stat) {
            deviceID = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            linkCount = UInt64(status.st_nlink)
            byteCount = Int64(status.st_size)
            mode = UInt32(status.st_mode)
            ownerUID = UInt32(status.st_uid)
            ownerGID = UInt32(status.st_gid)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }
}

public struct MeasurementSparseModelCandidate: Sendable, Equatable {
    public let order: Int
    public let registeredViewCount: Int

    public init(order: Int, registeredViewCount: Int) {
        self.order = order
        self.registeredViewCount = registeredViewCount
    }
}

public enum MeasurementSparseModelSelector {
    public static func select(
        _ candidates: [MeasurementSparseModelCandidate]
    ) -> MeasurementSparseModelCandidate? {
        candidates.min { lhs, rhs in
            if lhs.registeredViewCount != rhs.registeredViewCount {
                return lhs.registeredViewCount > rhs.registeredViewCount
            }
            return lhs.order < rhs.order
        }
    }
}

public enum MeasurementAdapterSupportError: Error, LocalizedError, Equatable {
    case invalidSplit
    case unsafeFile(String)
    case invalidModel(String)
    case missingImage(String)
    case unexpectedImage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSplit:
            "The benchmark training split is invalid."
        case .unsafeFile(let name):
            "The benchmark artifact is not a stable regular file: \(name)."
        case .invalidModel(let detail):
            "The COLMAP text model is invalid: \(detail)."
        case .missingImage(let name):
            "The benchmark training image is missing: \(name)."
        case .unexpectedImage(let name):
            "The benchmark dataset contains an unexpected image: \(name)."
        }
    }
}

public struct MeasurementTrainingSplit: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let selectedImageNames: [String]
    public let trainingViewIndices: [Int]
    public let holdoutViewIndices: [Int]
    public let trainingImageNames: [String]
    public let holdoutImageNames: [String]
    public let datasetImageNames: [String]
    public let trainingImageDigest: String
    public let closureDigest: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case selectedImageNames = "selected_image_names"
        case trainingViewIndices = "training_view_indices"
        case holdoutViewIndices = "holdout_view_indices"
        case trainingImageNames = "training_image_names"
        case holdoutImageNames = "holdout_image_names"
        case datasetImageNames = "dataset_image_names"
        case trainingImageDigest = "training_image_digest"
        case closureDigest = "closure_digest"
    }

    public static func make(
        selectedImageNames: [String],
        holdoutViewIndices: [Int],
        imagesDirectory: URL,
        datasetImageNames requestedDatasetImageNames: [String]? = nil
    ) throws -> Self {
        guard !selectedImageNames.isEmpty,
              selectedImageNames.count <= 3_000,
              Set(selectedImageNames).count == selectedImageNames.count,
              holdoutViewIndices == holdoutViewIndices.sorted(),
              Set(holdoutViewIndices).count == holdoutViewIndices.count,
              holdoutViewIndices.allSatisfy({ selectedImageNames.indices.contains($0) }) else {
            throw MeasurementAdapterSupportError.invalidSplit
        }
        let holdouts = Set(holdoutViewIndices)
        let trainingViewIndices = selectedImageNames.indices.filter { !holdouts.contains($0) }
        guard !trainingViewIndices.isEmpty else {
            throw MeasurementAdapterSupportError.invalidSplit
        }
        let trainingImageNames = trainingViewIndices.map { selectedImageNames[$0] }
        let holdoutImageNames = holdoutViewIndices.map { selectedImageNames[$0] }
        let datasetImageNames = requestedDatasetImageNames ?? trainingImageNames
        let trainingSet = Set(trainingImageNames)
        guard !datasetImageNames.isEmpty,
              Set(datasetImageNames).count == datasetImageNames.count,
              datasetImageNames.allSatisfy(trainingSet.contains) else {
            throw MeasurementAdapterSupportError.invalidSplit
        }
        let trainingImageDigest = try MeasurementDatasetImageIdentity.digest(
            imagesDirectory: imagesDirectory,
            orderedImageNames: datasetImageNames
        )
        struct Unsigned: Encodable {
            let schemaVersion: Int
            let selectedImageNames: [String]
            let trainingViewIndices: [Int]
            let holdoutViewIndices: [Int]
            let trainingImageNames: [String]
            let holdoutImageNames: [String]
            let datasetImageNames: [String]
            let trainingImageDigest: String

            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
                case selectedImageNames = "selected_image_names"
                case trainingViewIndices = "training_view_indices"
                case holdoutViewIndices = "holdout_view_indices"
                case trainingImageNames = "training_image_names"
                case holdoutImageNames = "holdout_image_names"
                case datasetImageNames = "dataset_image_names"
                case trainingImageDigest = "training_image_digest"
            }
        }
        let unsigned = Unsigned(
            schemaVersion: 1,
            selectedImageNames: selectedImageNames,
            trainingViewIndices: trainingViewIndices,
            holdoutViewIndices: holdoutViewIndices,
            trainingImageNames: trainingImageNames,
            holdoutImageNames: holdoutImageNames,
            datasetImageNames: datasetImageNames,
            trainingImageDigest: trainingImageDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let closureDigest = Self.hex(SHA256.hash(data: try encoder.encode(unsigned)))
        return Self(
            schemaVersion: 1,
            selectedImageNames: selectedImageNames,
            trainingViewIndices: trainingViewIndices,
            holdoutViewIndices: holdoutViewIndices,
            trainingImageNames: trainingImageNames,
            holdoutImageNames: holdoutImageNames,
            datasetImageNames: datasetImageNames,
            trainingImageDigest: trainingImageDigest,
            closureDigest: closureDigest
        )
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum MeasurementDatasetImageIdentity {
    public static func digest(
        imagesDirectory: URL,
        orderedImageNames: [String]
    ) throws -> String {
        guard !orderedImageNames.isEmpty,
              orderedImageNames.count <= 3_000,
              Set(orderedImageNames).count == orderedImageNames.count else {
            throw MeasurementAdapterSupportError.invalidSplit
        }
        let fileManager = FileManager.default
        let actual = try fileManager.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let expected = Set(orderedImageNames)
        for url in actual where !expected.contains(url.lastPathComponent) {
            throw MeasurementAdapterSupportError.unexpectedImage(url.lastPathComponent)
        }
        guard actual.count == orderedImageNames.count else {
            let actualNames = Set(actual.map(\.lastPathComponent))
            let missing = orderedImageNames.first { !actualNames.contains($0) } ?? "unknown"
            throw MeasurementAdapterSupportError.missingImage(missing)
        }

        var hasher = SHA256()
        for name in orderedImageNames {
            guard validImageName(name) else {
                throw MeasurementAdapterSupportError.invalidSplit
            }
            let file = imagesDirectory.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0 else {
                throw MeasurementAdapterSupportError.unsafeFile(name)
            }
            let nameData = Data(name.utf8)
            var nameLength = UInt32(nameData.count).bigEndian
            var byteCount = UInt64(fileSize).bigEndian
            withUnsafeBytes(of: &nameLength) { hasher.update(data: Data($0)) }
            hasher.update(data: nameData)
            withUnsafeBytes(of: &byteCount) { hasher.update(data: Data($0)) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validImageName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\\") && name.utf8.count <= 4_096
            && name.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public enum MeasurementFileSetIdentity {
    public static func digest(directory: URL, orderedNames: [String]) throws -> String {
        guard !orderedNames.isEmpty, Set(orderedNames).count == orderedNames.count else {
            throw MeasurementAdapterSupportError.invalidSplit
        }
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat measurement file set v1".utf8))
        for name in orderedNames {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
                throw MeasurementAdapterSupportError.invalidSplit
            }
            let file = directory.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size >= 0 else {
                throw MeasurementAdapterSupportError.unsafeFile(name)
            }
            let nameData = Data(name.utf8)
            var nameLength = UInt32(nameData.count).bigEndian
            var byteCount = UInt64(size).bigEndian
            withUnsafeBytes(of: &nameLength) { hasher.update(data: Data($0)) }
            hasher.update(data: nameData)
            withUnsafeBytes(of: &byteCount) { hasher.update(data: Data($0)) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct MeasurementFilteredCOLMAPModel: Sendable, Equatable {
    public let registeredImageNames: [String]
    public let trainingImageNames: [String]
    public let holdoutImageNames: [String]
    public let retainedPointCount: Int
}

public enum MeasurementCOLMAPTextFilter {
    public static func filter(
        source: URL,
        destination: URL,
        holdoutImageNames: Set<String>
    ) throws -> MeasurementFilteredCOLMAPModel {
        let fileManager = FileManager.default
        guard !holdoutImageNames.isEmpty else {
            throw MeasurementAdapterSupportError.invalidSplit
        }
        let cameras = source.appendingPathComponent("cameras.txt")
        let images = source.appendingPathComponent("images.txt")
        let points = source.appendingPathComponent("points3D.txt")
        for file in [cameras, images, points] {
            try requireRegular(file)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MeasurementAdapterSupportError.unsafeFile(destination.lastPathComponent)
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: staging) }
        }

        let scan = try scanImages(images, holdouts: holdoutImageNames)
        guard scan.holdoutNames.isSubset(of: holdoutImageNames),
              !scan.trainingImageNames.isEmpty else {
            throw MeasurementAdapterSupportError.invalidSplit
        }
        try fileManager.copyItem(
            at: cameras,
            to: staging.appendingPathComponent("cameras.txt")
        )
        let filteredPoints = staging.appendingPathComponent("points3D.txt")
        let pointResult = try filterPoints(
            points,
            output: filteredPoints,
            allImageIDs: scan.allImageIDs,
            retainedImageIDs: scan.retainedImageIDs
        )
        try filterImages(
            images,
            output: staging.appendingPathComponent("images.txt"),
            retainedImageIDs: scan.retainedImageIDs,
            allPointIDs: pointResult.allPointIDs,
            retainedPointIDs: pointResult.retainedPointIDs
        )
        try fileManager.moveItem(at: staging, to: destination)
        published = true
        return MeasurementFilteredCOLMAPModel(
            registeredImageNames: scan.registeredImageNames,
            trainingImageNames: scan.trainingImageNames,
            holdoutImageNames: scan.registeredImageNames.filter(holdoutImageNames.contains),
            retainedPointCount: pointResult.retainedPointIDs.count
        )
    }

    private struct ImageScan {
        let registeredImageNames: [String]
        let trainingImageNames: [String]
        let holdoutNames: Set<String>
        let allImageIDs: Set<UInt32>
        let retainedImageIDs: Set<UInt32>
    }

    private static func scanImages(_ file: URL, holdouts: Set<String>) throws -> ImageScan {
        let reader = try UTF8LineReader(file)
        defer { try? reader.close() }
        var registeredNames: [String] = []
        var trainingNames: [String] = []
        var foundHoldouts: Set<String> = []
        var allIDs: Set<UInt32> = []
        var retainedIDs: Set<UInt32> = []
        var awaitingObservations = false
        while let line = try reader.next() {
            if awaitingObservations {
                try validateObservations(line)
                awaitingObservations = false
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let pose = try parseImagePose(line)
            guard allIDs.insert(pose.id).inserted,
                  !registeredNames.contains(pose.name) else {
                throw MeasurementAdapterSupportError.invalidModel("duplicate registered image")
            }
            registeredNames.append(pose.name)
            if holdouts.contains(pose.name) {
                foundHoldouts.insert(pose.name)
            } else {
                retainedIDs.insert(pose.id)
                trainingNames.append(pose.name)
            }
            awaitingObservations = true
        }
        guard !awaitingObservations, !registeredNames.isEmpty else {
            throw MeasurementAdapterSupportError.invalidModel("incomplete images.txt")
        }
        return ImageScan(
            registeredImageNames: registeredNames,
            trainingImageNames: trainingNames,
            holdoutNames: foundHoldouts,
            allImageIDs: allIDs,
            retainedImageIDs: retainedIDs
        )
    }

    private static func filterPoints(
        _ file: URL,
        output: URL,
        allImageIDs: Set<UInt32>,
        retainedImageIDs: Set<UInt32>
    ) throws -> (allPointIDs: Set<UInt64>, retainedPointIDs: Set<UInt64>) {
        let reader = try UTF8LineReader(file)
        defer { try? reader.close() }
        let writer = try LineWriter(output)
        defer { try? writer.close() }
        try writer.write("# Filtered benchmark training model\n")
        var allPoints: Set<UInt64> = []
        var retainedPoints: Set<UInt64> = []
        while let line = try reader.next() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard tokens.count >= 8, (tokens.count - 8).isMultiple(of: 2),
                  let pointID = UInt64(tokens[0]),
                  allPoints.insert(pointID).inserted,
                  tokens[1...3].allSatisfy({ Double($0)?.isFinite == true }),
                  tokens[4...6].allSatisfy({ UInt8($0) != nil }),
                  Double(tokens[7])?.isFinite == true else {
                throw MeasurementAdapterSupportError.invalidModel("malformed points3D.txt")
            }
            var retainedTrack: [String] = []
            for index in stride(from: 8, to: tokens.count, by: 2) {
                guard let imageID = UInt32(tokens[index]),
                      let point2DIndex = UInt64(tokens[index + 1]),
                      allImageIDs.contains(imageID) else {
                    throw MeasurementAdapterSupportError.invalidModel("invalid point track")
                }
                _ = point2DIndex
                if retainedImageIDs.contains(imageID) {
                    retainedTrack.append(tokens[index])
                    retainedTrack.append(tokens[index + 1])
                }
            }
            if retainedTrack.count >= 4 {
                retainedPoints.insert(pointID)
                try writer.write((Array(tokens[0..<8]) + retainedTrack).joined(separator: " ") + "\n")
            }
        }
        return (allPoints, retainedPoints)
    }

    private static func filterImages(
        _ file: URL,
        output: URL,
        retainedImageIDs: Set<UInt32>,
        allPointIDs: Set<UInt64>,
        retainedPointIDs: Set<UInt64>
    ) throws {
        let reader = try UTF8LineReader(file)
        defer { try? reader.close() }
        let writer = try LineWriter(output)
        defer { try? writer.close() }
        try writer.write("# Filtered benchmark training model\n")
        var pending: (line: String, id: UInt32)?
        while let line = try reader.next() {
            if let pose = pending {
                let tokens = try observationTokens(line, allPointIDs: allPointIDs)
                if retainedImageIDs.contains(pose.id) {
                    var filtered = tokens
                    for index in stride(from: 2, to: filtered.count, by: 3) {
                        if filtered[index] != "-1",
                           let pointID = UInt64(filtered[index]),
                           !retainedPointIDs.contains(pointID) {
                            filtered[index] = "-1"
                        }
                    }
                    try writer.write(pose.line + "\n")
                    try writer.write(filtered.joined(separator: " ") + "\n")
                }
                pending = nil
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let pose = try parseImagePose(line)
            pending = (line, pose.id)
        }
        guard pending == nil else {
            throw MeasurementAdapterSupportError.invalidModel("incomplete images.txt")
        }
    }

    private static func validateObservations(_ line: String) throws {
        _ = try observationTokens(line, allPointIDs: nil)
    }

    private static func observationTokens(
        _ line: String,
        allPointIDs: Set<UInt64>?
    ) throws -> [String] {
        let tokens = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard tokens.count.isMultiple(of: 3) else {
            throw MeasurementAdapterSupportError.invalidModel("malformed image observations")
        }
        for index in stride(from: 0, to: tokens.count, by: 3) {
            guard Double(tokens[index])?.isFinite == true,
                  Double(tokens[index + 1])?.isFinite == true else {
                throw MeasurementAdapterSupportError.invalidModel("invalid image observation")
            }
            if tokens[index + 2] != "-1" {
                guard let pointID = UInt64(tokens[index + 2]),
                      allPointIDs?.contains(pointID) ?? true else {
                    throw MeasurementAdapterSupportError.invalidModel("unknown observation point")
                }
            }
        }
        return tokens
    }

    private static func parseImagePose(_ line: String) throws -> (id: UInt32, name: String) {
        let fields = line.split(
            maxSplits: 9,
            omittingEmptySubsequences: true,
            whereSeparator: \Character.isWhitespace
        )
        guard fields.count == 10,
              let id = UInt32(fields[0]), id > 0,
              fields[1...7].allSatisfy({ Double($0)?.isFinite == true }),
              let cameraID = UInt32(fields[8]), cameraID > 0 else {
            throw MeasurementAdapterSupportError.invalidModel("malformed image pose")
        }
        let name = String(fields[9])
        guard !name.isEmpty, name.utf8.count <= 4_096,
              !name.contains("/"), !name.contains("\\"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw MeasurementAdapterSupportError.invalidModel("invalid image name")
        }
        return (id, name)
    }

    private static func requireRegular(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= 64 * 1_024 * 1_024 * 1_024 else {
            throw MeasurementAdapterSupportError.unsafeFile(file.lastPathComponent)
        }
    }
}

private final class UTF8LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var offset = 0
    private var reachedEnd = false
    private let maximumLineBytes = 16 * 1_024 * 1_024

    init(_ file: URL) throws {
        handle = try FileHandle(forReadingFrom: file)
    }

    func next() throws -> String? {
        while true {
            if let newline = buffer[offset...].firstIndex(of: 0x0A) {
                var line = Data(buffer[offset..<newline])
                offset = newline + 1
                if line.last == 0x0D { line.removeLast() }
                return try decode(line)
            }
            if reachedEnd {
                guard offset < buffer.count else { return nil }
                var line = Data(buffer[offset..<buffer.count])
                offset = buffer.count
                if line.last == 0x0D { line.removeLast() }
                return try decode(line)
            }
            if offset > 0 {
                buffer.removeSubrange(0..<offset)
                offset = 0
            }
            guard buffer.count <= maximumLineBytes else {
                throw MeasurementAdapterSupportError.invalidModel("text line is too long")
            }
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty {
                reachedEnd = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    func close() throws { try handle.close() }

    private func decode(_ data: Data) throws -> String {
        guard data.count <= maximumLineBytes, let value = String(data: data, encoding: .utf8) else {
            throw MeasurementAdapterSupportError.invalidModel("text is not bounded UTF-8")
        }
        return value
    }
}

private final class LineWriter {
    private let handle: FileHandle

    init(_ file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw MeasurementAdapterSupportError.unsafeFile(file.lastPathComponent)
        }
        handle = try FileHandle(forWritingTo: file)
    }

    func write(_ value: String) throws {
        try handle.write(contentsOf: Data(value.utf8))
    }

    func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
