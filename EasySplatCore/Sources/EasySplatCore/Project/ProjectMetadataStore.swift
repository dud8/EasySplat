import Darwin
import Foundation

package enum ProjectMetadataBoundError: Error, Equatable, LocalizedError {
    case unsafeProjectRoot
    case unsafeMetadata
    case metadataChanged
    case metadataConflict
    case persistence(operation: String, code: Int32)

    package var errorDescription: String? {
        switch self {
        case .unsafeProjectRoot:
            return "The locked project directory is not safe to update."
        case .unsafeMetadata:
            return "project.json is not an ordinary, private project file."
        case .metadataChanged:
            return "project.json changed while it was being read."
        case .metadataConflict:
            return "project.json changed before the metadata update could commit."
        case .persistence(let operation, let code):
            return "Could not durably save project metadata during \(operation) (POSIX \(code))."
        }
    }
}

package enum ProjectMetadataBoundCheckpoint: Sendable, Equatable {
    case rootBound
    case metadataSnapshotRead
    case candidateCreated
    case candidateWritten
    case candidateDurable
    case candidateValidated
    case readyToCommit
    case committed
    case directoryDurable
    case canonicalValidated
}

package struct ProjectMetadataBoundOperations: @unchecked Sendable {
    package var readAt: @Sendable (
        Int32,
        UnsafeMutableRawPointer?,
        Int,
        off_t
    ) -> Int
    package var write: @Sendable (
        Int32,
        UnsafeRawPointer?,
        Int
    ) -> Int
    package var synchronizeFile: @Sendable (Int32) -> Int32
    package var synchronizeDirectory: @Sendable (Int32) -> Int32
    package var renameExclusive: @Sendable (Int32, String, String) -> Int32
    package var exchange: @Sendable (Int32, String, String) -> Int32
    package var makeUUID: @Sendable () -> UUID
    package var didReachCheckpoint: @Sendable (
        ProjectMetadataBoundCheckpoint,
        Int32,
        String?
    ) throws -> Void

    package static func system() -> Self {
        Self(
            readAt: { Darwin.pread($0, $1, $2, $3) },
            write: { Darwin.write($0, $1, $2) },
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
            renameExclusive: { rootDescriptor, source, destination in
                source.withCString { sourcePointer in
                    destination.withCString { destinationPointer in
                        Darwin.renameatx_np(
                            rootDescriptor,
                            sourcePointer,
                            rootDescriptor,
                            destinationPointer,
                            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                        )
                    }
                }
            },
            exchange: { rootDescriptor, source, destination in
                source.withCString { sourcePointer in
                    destination.withCString { destinationPointer in
                        Darwin.renameatx_np(
                            rootDescriptor,
                            sourcePointer,
                            rootDescriptor,
                            destinationPointer,
                            UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
                        )
                    }
                }
            },
            makeUUID: UUID.init,
            didReachCheckpoint: { _, _, _ in }
        )
    }
}

/// JSON loader/saver for persisted project metadata files.
public enum ProjectMetadataStore {
    private static let maximumMetadataBytes = 8 * 1_024 * 1_024
    private static let fileLocks = ProjectMetadataFileLocks()
    /// The project format EasySplat writes. Older formats in
    /// `acceptedFormatVersions` are still read; every save stamps this
    /// version, so projects migrate forward on their next write without a
    /// separate migration pass.
    public static let supportedFormatVersion: Int = 33
    /// Formats this build can decode. Format 31 predates dataset inputs and
    /// decodes with the dataset fields absent.
    public static let acceptedFormatVersions: Set<Int> = [31, 32, 33]
    /// Fields older payloads must not contain. Enforced during decode so an
    /// older format cannot smuggle newer state past the field envelope.
    private static let fieldsIntroducedInFormat32: Set<String> = [
        ProjectMetadata.CodingKeys.datasetPoseSeed.rawValue
    ]
    private static let fieldsIntroducedInFormat33: Set<String> = [
        ProjectMetadata.CodingKeys.pendingPublicationID.rawValue
    ]

    public enum LoadError: Error, LocalizedError {
        case unsupportedFormatVersion(Int)
        case invalidArtifactPath(field: String, path: String)
        case invalidArtifactNamespace(field: String, path: String)
        case invalidTrainingMemoryRetryBudget(Int64)
        case invalidGeometryRecovery(String)
        case invalidResolvedRunPlan
        case invalidProjectID
        case invalidPendingPublicationID
        case malformedJSON
        case unexpectedFields

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let version):
                let accepted = ProjectMetadataStore.acceptedFormatVersions.sorted()
                    .map(String.init).joined(separator: " and ")
                return "Project format \(version) is not supported. This version of EasySplat opens format \(accepted) projects only."
            case .invalidArtifactPath(let field, let path):
                return "Project metadata contains an invalid project-relative artifact path for \(field): \(path)"
            case .invalidArtifactNamespace(let field, let path):
                return "Project metadata stores \(field) outside its allowed project directory: \(path)"
            case .invalidTrainingMemoryRetryBudget(let bytes):
                return "Project metadata contains an invalid training memory retry budget: \(bytes) bytes."
            case .invalidGeometryRecovery(let reason):
                return "Project metadata contains invalid geometry recovery state: \(reason)"
            case .invalidResolvedRunPlan:
                return "Project metadata contains an invalid resolved run plan."
            case .invalidProjectID:
                return "Project metadata contains an invalid project identity."
            case .invalidPendingPublicationID:
                return "Project metadata contains an invalid pending publication identity."
            case .malformedJSON:
                return "Project metadata is not valid strict JSON."
            case .unexpectedFields:
                return "Project metadata contains fields outside the current project format."
            }
        }
    }

    public enum SaveError: Error, LocalizedError {
        case invalidFormatVersion(Int)
        case metadataTooLarge(maximumBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidFormatVersion(let version):
                return "Cannot save project format \(version)."
            case .metadataTooLarge(let maximumBytes):
                return "Project metadata exceeds the \(maximumBytes)-byte save limit."
            }
        }
    }

    public static func load(from url: URL) throws -> ProjectMetadata {
        guard url.lastPathComponent == "project.json" else {
            return try fileLocks.withPathLock(for: url) {
                try loadWithoutLock(from: url)
            }
        }
        return try load(from: url, operations: .system())
    }

    package static func load(
        from url: URL,
        operations: ProjectMetadataBoundOperations
    ) throws -> ProjectMetadata {
        try fileLocks.withLock(forProjectMetadataURL: url) {
            projectRootDescriptor,
            expectedRootPath in
            try loadWithoutLock(
                fromProjectRootDescriptor: projectRootDescriptor,
                expectedRootPath: expectedRootPath,
                operations: operations
            )
        }
    }

    /// Loads `project.json` relative to an already authenticated project-root
    /// descriptor. The descriptor remains owned by the caller.
    package static func load(
        fromProjectRootDescriptor projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations = .system()
    ) throws -> ProjectMetadata {
        try fileLocks.withLock(forProjectRootDescriptor: projectRootDescriptor) {
            try loadWithoutLock(
                fromProjectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
        }
    }

    public static func save(_ metadata: ProjectMetadata, to url: URL) throws {
        guard url.lastPathComponent == "project.json" else {
            return try fileLocks.withPathLock(for: url) {
                try saveWithoutLock(metadata, to: url)
            }
        }
        try fileLocks.withLock(forProjectMetadataURL: url) {
            projectRootDescriptor,
            expectedRootPath in
            try saveWithoutLock(
                metadata,
                toProjectRootDescriptor: projectRootDescriptor,
                expectedRootPath: expectedRootPath,
                operations: .system()
            )
        }
    }

    /// Durably replaces `project.json` relative to an already authenticated
    /// project-root descriptor. The descriptor remains owned by the caller.
    package static func save(
        _ metadata: ProjectMetadata,
        toProjectRootDescriptor projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations = .system()
    ) throws {
        try fileLocks.withLock(forProjectRootDescriptor: projectRootDescriptor) {
            try saveWithoutLock(
                metadata,
                toProjectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
        }
    }

    public static func savePreservingUserEditableFields(_ metadata: ProjectMetadata, to url: URL) throws {
        guard url.lastPathComponent == "project.json" else {
            return try fileLocks.withPathLock(for: url) {
                var merged = metadata
                do {
                    let current = try decodeWithoutArtifactValidation(from: url)
                    merged.title = current.title
                    merged.notes = current.notes
                    merged.viewerPreferences = current.viewerPreferences
                } catch {
                    guard BoundedFileReader.isMissingFileError(error) else {
                        throw error
                    }
                }
                try saveWithoutLock(merged, to: url)
            }
        }
        try fileLocks.withLock(forProjectMetadataURL: url) {
            projectRootDescriptor,
            expectedRootPath in
            _ = try commitBoundMetadata(
                projectRootDescriptor: projectRootDescriptor,
                expectedRootPath: expectedRootPath,
                operations: .system()
            ) { current in
                var merged = metadata
                if let current {
                    merged.title = current.title
                    merged.notes = current.notes
                    merged.viewerPreferences = current.viewerPreferences
                }
                return merged
            }
        }
    }

    package static func savePreservingUserEditableFields(
        _ metadata: ProjectMetadata,
        toProjectRootDescriptor projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations = .system()
    ) throws {
        try fileLocks.withLock(forProjectRootDescriptor: projectRootDescriptor) {
            _ = try commitBoundMetadata(
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            ) { current in
                var merged = metadata
                if let current {
                    merged.title = current.title
                    merged.notes = current.notes
                    merged.viewerPreferences = current.viewerPreferences
                }
                return merged
            }
        }
    }

    @discardableResult
    public static func update(
        at url: URL,
        _ mutation: (inout ProjectMetadata) throws -> Void
    ) throws -> ProjectMetadata {
        guard url.lastPathComponent == "project.json" else {
            return try fileLocks.withPathLock(for: url) {
                var metadata = try loadWithoutLock(from: url)
                try mutation(&metadata)
                try saveWithoutLock(metadata, to: url)
                return metadata
            }
        }
        return try update(at: url, operations: .system(), mutation)
    }

    @discardableResult
    package static func update(
        at url: URL,
        operations: ProjectMetadataBoundOperations,
        _ mutation: (inout ProjectMetadata) throws -> Void
    ) throws -> ProjectMetadata {
        try fileLocks.withLock(forProjectMetadataURL: url) {
            projectRootDescriptor,
            expectedRootPath in
            try commitBoundMetadata(
                projectRootDescriptor: projectRootDescriptor,
                expectedRootPath: expectedRootPath,
                operations: operations
            ) { current in
                guard var current else {
                    throw ProjectMetadataBoundError.persistence(
                        operation: "open project.json",
                        code: ENOENT
                    )
                }
                try mutation(&current)
                return current
            }
        }
    }

    @discardableResult
    package static func update(
        atProjectRootDescriptor projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations = .system(),
        _ mutation: (inout ProjectMetadata) throws -> Void
    ) throws -> ProjectMetadata {
        try fileLocks.withLock(forProjectRootDescriptor: projectRootDescriptor) {
            try commitBoundMetadata(
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            ) { current in
                guard var current else {
                    throw ProjectMetadataBoundError.persistence(
                        operation: "open project.json",
                        code: ENOENT
                    )
                }
                try mutation(&current)
                return current
            }
        }
    }

    private static func loadWithoutLock(from url: URL) throws -> ProjectMetadata {
        var metadata = try decodeWithoutArtifactValidation(from: url)
        if let recovery = metadata.geometryRecovery,
           (try? recovery.validate()) == nil {
            // Recovery evidence is disposable internal state. A torn or stale
            // recovery payload must not make the project itself unreadable.
            metadata.geometryRecovery = nil
        }
        try validateArtifactPaths(in: metadata, metadataURL: url)
        try VideoInputReceiptValidator.validateMetadata(
            metadata,
            paths: ProjectPaths(root: url.deletingLastPathComponent())
        )
        try PhotoInputReceiptValidator.validateMetadata(
            metadata,
            paths: ProjectPaths(root: url.deletingLastPathComponent())
        )
        try DatasetPoseSeedReceiptValidator.validateMetadata(metadata)
        return metadata
    }

    private static func loadWithoutLock(
        fromProjectRootDescriptor projectRootDescriptor: Int32,
        expectedRootPath: String? = nil,
        operations: ProjectMetadataBoundOperations
    ) throws -> ProjectMetadata {
        let initialRootPath = try expectedRootPath
            ?? boundProjectRootPath(descriptor: projectRootDescriptor)
        guard try boundProjectRootPath(descriptor: projectRootDescriptor)
            == initialRootPath else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        try operations.didReachCheckpoint(
            .rootBound,
            projectRootDescriptor,
            nil
        )
        let snapshot = try readBoundFile(
            named: "project.json",
            projectRootDescriptor: projectRootDescriptor,
            operations: operations
        )
        try operations.didReachCheckpoint(
            .metadataSnapshotRead,
            projectRootDescriptor,
            nil
        )
        let metadataURL = URL(fileURLWithPath: initialRootPath, isDirectory: true)
            .appendingPathComponent("project.json")
        let metadata = try validateAgainstBoundProjectRoot(
            descriptor: projectRootDescriptor,
            expectedPath: initialRootPath
        ) {
            try decodeValidatedMetadataSnapshot(
                snapshot.data,
                metadataURL: metadataURL
            )
        }
        guard try boundProjectRootPath(descriptor: projectRootDescriptor)
            == initialRootPath else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        return metadata
    }

    fileprivate static func boundProjectRootPath(descriptor: Int32) throws -> String {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw ProjectMetadataBoundError.persistence(
                operation: "inspect the locked project directory",
                code: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid() else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }

        var descriptorInfo = vnode_fdinfowithpath()
        let expectedSize = MemoryLayout<vnode_fdinfowithpath>.size
        let bytesRead = Darwin.proc_pidfdinfo(
            getpid(),
            descriptor,
            PROC_PIDFDVNODEPATHINFO,
            &descriptorInfo,
            Int32(expectedSize)
        )
        guard bytesRead == Int32(expectedSize) else {
            throw ProjectMetadataBoundError.persistence(
                operation: "resolve the locked project directory",
                code: bytesRead < 0 ? errno : EIO
            )
        }
        let buffer = withUnsafeBytes(of: &descriptorInfo.pvip.vip_path) {
            Array($0)
        }
        guard let terminator = buffer.firstIndex(of: 0),
              terminator > 0,
              let path = String(bytes: buffer[..<terminator], encoding: .utf8),
              path.hasPrefix("/"),
              !path.contains("\0") else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        var namedStatus = stat()
        guard path.withCString({ Darwin.lstat($0, &namedStatus) }) == 0,
              namedStatus.st_dev == status.st_dev,
              namedStatus.st_ino == status.st_ino,
              namedStatus.st_mode & S_IFMT == S_IFDIR,
              namedStatus.st_uid == status.st_uid else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        return path
    }

    private static func validateAgainstBoundProjectRoot<Value>(
        descriptor: Int32,
        expectedPath: String,
        _ body: () throws -> Value
    ) throws -> Value {
        guard try boundProjectRootPath(descriptor: descriptor) == expectedPath else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        do {
            let value = try body()
            guard try boundProjectRootPath(descriptor: descriptor) == expectedPath else {
                throw ProjectMetadataBoundError.unsafeProjectRoot
            }
            return value
        } catch {
            guard (try? boundProjectRootPath(descriptor: descriptor)) == expectedPath else {
                throw ProjectMetadataBoundError.unsafeProjectRoot
            }
            throw error
        }
    }

    private static func readBoundFile(
        named leaf: String,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) throws -> BoundMetadataSnapshot {
        let descriptor = leaf.withCString {
            Darwin.openat(
                projectRootDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ProjectMetadataBoundError.persistence(
                operation: "open project.json",
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              leaf.withCString({
                  Darwin.fstatat(
                      projectRootDescriptor,
                      $0,
                      &named,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0 else {
            throw ProjectMetadataBoundError.persistence(
                operation: "inspect project.json",
                code: errno
            )
        }
        guard BoundMetadataIdentity(opened).isSafeMetadataFile,
              BoundMetadataIdentity(opened) == BoundMetadataIdentity(named) else {
            throw ProjectMetadataBoundError.unsafeMetadata
        }
        let initialIdentity = BoundMetadataIdentity(opened)
        guard opened.st_size >= 0,
              opened.st_size <= off_t(maximumMetadataBytes) else {
            throw ProjectMetadataBoundError.unsafeMetadata
        }

        var data = Data(count: Int(opened.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { bytes in
                operations.readAt(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count < 0 {
                    throw ProjectMetadataBoundError.persistence(
                        operation: "read project.json",
                        code: errno
                    )
                }
                throw ProjectMetadataBoundError.metadataChanged
            }
            offset += count
        }

        var finalOpened = stat()
        var finalNamed = stat()
        guard Darwin.fstat(descriptor, &finalOpened) == 0,
              leaf.withCString({
                  Darwin.fstatat(
                      projectRootDescriptor,
                      $0,
                      &finalNamed,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0 else {
            throw ProjectMetadataBoundError.metadataChanged
        }
        guard BoundMetadataIdentity(finalOpened) == initialIdentity,
              BoundMetadataIdentity(finalNamed) == initialIdentity else {
            throw ProjectMetadataBoundError.metadataChanged
        }
        return BoundMetadataSnapshot(data: data, identity: initialIdentity)
    }

    private static func decodeWithoutArtifactValidation(from url: URL) throws -> ProjectMetadata {
        try ProjectPaths(root: url.deletingLastPathComponent()).validateRootDirectory()
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumMetadataBytes
        )
        return try decodePayload(data)
    }

    /// Decodes and validates one already authenticated metadata byte snapshot.
    /// Publication uses this to ensure semantic checks and its file manifest bind
    /// the exact same `project.json` contents.
    static func decodeValidatedMetadataSnapshot(
        _ data: Data,
        metadataURL: URL
    ) throws -> ProjectMetadata {
        guard data.count <= maximumMetadataBytes else {
            throw SaveError.metadataTooLarge(maximumBytes: maximumMetadataBytes)
        }
        try ProjectPaths(root: metadataURL.deletingLastPathComponent()).validateRootDirectory()
        var metadata = try decodePayload(data)
        if let recovery = metadata.geometryRecovery,
           (try? recovery.validate()) == nil {
            metadata.geometryRecovery = nil
        }
        try validateArtifactPaths(in: metadata, metadataURL: metadataURL)
        let paths = ProjectPaths(root: metadataURL.deletingLastPathComponent())
        try VideoInputReceiptValidator.validateMetadata(metadata, paths: paths)
        try PhotoInputReceiptValidator.validateMetadata(metadata, paths: paths)
        try DatasetPoseSeedReceiptValidator.validateMetadata(metadata)
        return metadata
    }

    private static func decodePayload(_ data: Data) throws -> ProjectMetadata {
        do {
            try StrictJSONDocument.validate(data, maximumBytes: maximumMetadataBytes)
        } catch {
            throw LoadError.malformedJSON
        }
        // Read the schema envelope before the strict payload so unsupported projects fail
        // clearly without partially interpreting another format.
        let envelope = try JSONDecoder().decode(FormatVersionEnvelope.self, from: data)
        guard acceptedFormatVersions.contains(envelope.formatVersion) else {
            throw LoadError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let fieldEnvelope = try JSONDecoder().decode(FieldEnvelope.self, from: data)
        var allowedFields = Set(ProjectMetadata.CodingKeys.allCases.map(\.rawValue))
        if envelope.formatVersion < 32 {
            allowedFields.subtract(fieldsIntroducedInFormat32)
        }
        if envelope.formatVersion < 33 {
            allowedFields.subtract(fieldsIntroducedInFormat33)
        }
        guard fieldEnvelope.fields.isSubset(of: allowedFields) else {
            throw LoadError.unexpectedFields
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ProjectMetadata.self, from: data)
        guard metadata.formatVersion == envelope.formatVersion else {
            throw SaveError.invalidFormatVersion(metadata.formatVersion)
        }
        // The field envelope only blocks top-level format-32 keys. Format-32
        // state also lives nested inside the input spec, the resolved run plan,
        // and the recovery payload, so a pre-32 envelope carrying a dataset
        // input or an imported-pose plan must be rejected here too.
        if envelope.formatVersion < 32 {
            let carriesFormat32State = metadata.input.isDataset
                || metadata.resolvedRunPlan?.geometryBackend == .importedPoses
                || metadata.resolvedRunPlan?.datasetGeometryRoute != nil
                || metadata.geometryRecovery?.activeBackend == .importedPoses
            guard !carriesFormat32State else {
                throw LoadError.unexpectedFields
            }
        }
        try validateRequiredIdentities(in: metadata)
        return metadata
    }

    /// Minimal decode that only requires `formatVersion`. Used to recognize future-schema
    /// project files before attempting the strict, schema-bound decode of `ProjectMetadata`.
    private struct FormatVersionEnvelope: Decodable {
        let formatVersion: Int
    }

    private struct FieldEnvelope: Decodable {
        let fields: Set<String>

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FieldKey.self)
            fields = Set(container.allKeys.map(\.stringValue))
        }
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private static func saveWithoutLock(_ metadata: ProjectMetadata, to url: URL) throws {
        let data = try encodedValidatedMetadata(metadata, metadataURL: url)
        try data.write(to: url, options: [.atomic])
    }

    private static func encodedValidatedMetadata(
        _ metadata: ProjectMetadata,
        metadataURL: URL
    ) throws -> Data {
        try ProjectPaths(root: metadataURL.deletingLastPathComponent())
            .validateRootDirectory()
        var persistedMetadata = metadata
        guard acceptedFormatVersions.contains(persistedMetadata.formatVersion) else {
            throw SaveError.invalidFormatVersion(persistedMetadata.formatVersion)
        }
        // Saving is the migration boundary: an accepted older-format project
        // is rewritten as the current format.
        persistedMetadata.formatVersion = supportedFormatVersion
        try validateArtifactPaths(in: persistedMetadata, metadataURL: metadataURL)
        let paths = ProjectPaths(root: metadataURL.deletingLastPathComponent())
        try VideoInputReceiptValidator.validateMetadata(
            persistedMetadata,
            paths: paths
        )
        try PhotoInputReceiptValidator.validateMetadata(
            persistedMetadata,
            paths: paths
        )
        try DatasetPoseSeedReceiptValidator.validateMetadata(persistedMetadata)
        try validateRequiredIdentities(in: persistedMetadata)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(persistedMetadata)
        guard data.count <= maximumMetadataBytes else {
            throw SaveError.metadataTooLarge(maximumBytes: maximumMetadataBytes)
        }
        return data
    }

    private static func saveWithoutLock(
        _ metadata: ProjectMetadata,
        toProjectRootDescriptor projectRootDescriptor: Int32,
        expectedRootPath: String? = nil,
        operations: ProjectMetadataBoundOperations
    ) throws {
        _ = try commitBoundMetadata(
            projectRootDescriptor: projectRootDescriptor,
            expectedRootPath: expectedRootPath,
            operations: operations
        ) { _ in metadata }
    }

    @discardableResult
    private static func commitBoundMetadata(
        projectRootDescriptor: Int32,
        expectedRootPath: String? = nil,
        operations: ProjectMetadataBoundOperations,
        prepare: (ProjectMetadata?) throws -> ProjectMetadata
    ) throws -> ProjectMetadata {
        let initialRootPath = try expectedRootPath
            ?? boundProjectRootPath(descriptor: projectRootDescriptor)
        guard try boundProjectRootPath(descriptor: projectRootDescriptor)
            == initialRootPath else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        try operations.didReachCheckpoint(
            .rootBound,
            projectRootDescriptor,
            nil
        )
        let metadataURL = URL(fileURLWithPath: initialRootPath, isDirectory: true)
            .appendingPathComponent("project.json")

        var priorSnapshot: BoundMetadataSnapshot?
        var priorMetadata: ProjectMetadata?
        do {
            priorSnapshot = try readBoundFile(
                named: "project.json",
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
            priorMetadata = try validateAgainstBoundProjectRoot(
                descriptor: projectRootDescriptor,
                expectedPath: initialRootPath
            ) {
                try decodeValidatedMetadataSnapshot(
                    priorSnapshot!.data,
                    metadataURL: metadataURL
                )
            }
        } catch ProjectMetadataBoundError.persistence(
            operation: "open project.json",
            code: ENOENT
        ) {
            priorSnapshot = nil
        }
        try operations.didReachCheckpoint(
            .metadataSnapshotRead,
            projectRootDescriptor,
            nil
        )
        let preparedMetadata = try prepare(priorMetadata)
        let data = try validateAgainstBoundProjectRoot(
            descriptor: projectRootDescriptor,
            expectedPath: initialRootPath
        ) {
            try encodedValidatedMetadata(
                preparedMetadata,
                metadataURL: metadataURL
            )
        }

        let candidate = try createBoundMetadataCandidate(
            projectRootDescriptor: projectRootDescriptor,
            operations: operations
        )
        defer { Darwin.close(candidate.descriptor) }
        var cleanupSnapshot = BoundMetadataSnapshot(
            data: Data(),
            identity: candidate.identity
        )
        defer {
            removeOwnedCandidate(
                named: candidate.leaf,
                descriptor: candidate.descriptor,
                ownedNode: candidate.identity,
                refreshedSnapshot: cleanupSnapshot,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
        }

        try operations.didReachCheckpoint(
            .candidateCreated,
            projectRootDescriptor,
            candidate.leaf
        )
        do {
            try writeAll(
                data,
                to: candidate.descriptor,
                operations: operations
            )
        } catch {
            cleanupSnapshot = refreshedOwnedCandidateSnapshot(
                named: candidate.leaf,
                descriptor: candidate.descriptor,
                ownedNode: candidate.identity,
                projectRootDescriptor: projectRootDescriptor
            ) ?? cleanupSnapshot
            throw error
        }
        cleanupSnapshot = refreshedOwnedCandidateSnapshot(
            named: candidate.leaf,
            descriptor: candidate.descriptor,
            ownedNode: candidate.identity,
            projectRootDescriptor: projectRootDescriptor
        ) ?? cleanupSnapshot
        try operations.didReachCheckpoint(
            .candidateWritten,
            projectRootDescriptor,
            candidate.leaf
        )
        guard operations.synchronizeFile(candidate.descriptor) == 0 else {
            throw ProjectMetadataBoundError.persistence(
                operation: "synchronize the metadata candidate",
                code: errno
            )
        }
        try operations.didReachCheckpoint(
            .candidateDurable,
            projectRootDescriptor,
            candidate.leaf
        )
        let validatedCandidate = try readBoundFile(
            named: candidate.leaf,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations
        )
        cleanupSnapshot = validatedCandidate
        guard validatedCandidate.data == data else {
            throw ProjectMetadataBoundError.metadataChanged
        }
        _ = try validateAgainstBoundProjectRoot(
            descriptor: projectRootDescriptor,
            expectedPath: initialRootPath
        ) {
            try decodeValidatedMetadataSnapshot(
                validatedCandidate.data,
                metadataURL: metadataURL
            )
        }
        try operations.didReachCheckpoint(
            .candidateValidated,
            projectRootDescriptor,
            candidate.leaf
        )
        try operations.didReachCheckpoint(
            .readyToCommit,
            projectRootDescriptor,
            candidate.leaf
        )

        guard try boundProjectRootPath(descriptor: projectRootDescriptor)
            == initialRootPath else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        try requireCurrentMetadataIdentity(
            priorSnapshot?.identity,
            projectRootDescriptor: projectRootDescriptor
        )
        try requireCurrentCandidateIdentity(
            validatedCandidate.identity,
            descriptor: candidate.descriptor,
            named: candidate.leaf,
            projectRootDescriptor: projectRootDescriptor
        )
        let retiredMetadataSnapshot: BoundMetadataSnapshot?
        if let priorIdentity = priorSnapshot?.identity {
            let exchangeResult = operations.exchange(
                projectRootDescriptor,
                candidate.leaf,
                "project.json"
            )
            let exchangeCode = errno
            let installedIdentity = try namedEntryIdentity(
                "project.json",
                projectRootDescriptor: projectRootDescriptor
            )
            let displacedIdentity = try namedEntryIdentity(
                candidate.leaf,
                projectRootDescriptor: projectRootDescriptor
            )
            if exchangeResult != 0,
               installedIdentity == priorIdentity,
               displacedIdentity == validatedCandidate.identity {
                throw ProjectMetadataBoundError.persistence(
                    operation: "exchange project.json",
                    code: exchangeCode
                )
            }
            guard let installedIdentity,
                  let displacedIdentity,
                  installedIdentity.sameNode(as: validatedCandidate.identity),
                  displacedIdentity.sameNode(as: priorIdentity) else {
                reverseObservedMetadataExchange(
                    candidateLeaf: candidate.leaf,
                    observedCandidate: displacedIdentity,
                    observedCanonical: installedIdentity,
                    validatedCandidate: validatedCandidate,
                    expectedData: data,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations
                )
                throw ProjectMetadataBoundError.metadataConflict
            }
            let retiredSnapshot = try readBoundFile(
                named: candidate.leaf,
                projectRootDescriptor: projectRootDescriptor,
                operations: .system()
            )
            guard retiredSnapshot.identity == displacedIdentity,
                  retiredSnapshot.identity.sameNode(as: priorIdentity),
                  retiredSnapshot.data == priorSnapshot?.data else {
                reverseObservedMetadataExchange(
                    candidateLeaf: candidate.leaf,
                    observedCandidate: displacedIdentity,
                    observedCanonical: installedIdentity,
                    validatedCandidate: validatedCandidate,
                    expectedData: data,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations
                )
                throw ProjectMetadataBoundError.metadataConflict
            }
            retiredMetadataSnapshot = retiredSnapshot
        } else {
            let renameResult = operations.renameExclusive(
                projectRootDescriptor,
                candidate.leaf,
                "project.json"
            )
            let renameCode = errno
            let installedIdentity = try namedEntryIdentity(
                "project.json",
                projectRootDescriptor: projectRootDescriptor
            )
            let candidateIdentity = try namedEntryIdentity(
                candidate.leaf,
                projectRootDescriptor: projectRootDescriptor
            )
            if renameResult != 0,
               installedIdentity == nil,
               candidateIdentity == validatedCandidate.identity {
                if renameCode == EEXIST {
                    throw ProjectMetadataBoundError.metadataConflict
                }
                throw ProjectMetadataBoundError.persistence(
                    operation: "install project.json",
                    code: renameCode
                )
            }
            guard let installedIdentity,
                  installedIdentity.sameNode(as: validatedCandidate.identity),
                  candidateIdentity == nil else {
                reverseObservedInitialMetadataRename(
                    candidateLeaf: candidate.leaf,
                    observedCanonical: installedIdentity,
                    validatedCandidate: validatedCandidate,
                    candidateDescriptor: candidate.descriptor,
                    expectedData: data,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations
                )
                throw ProjectMetadataBoundError.metadataConflict
            }
            retiredMetadataSnapshot = nil
        }
        _ = try? operations.didReachCheckpoint(
            .committed,
            projectRootDescriptor,
            nil
        )
        guard operations.synchronizeDirectory(projectRootDescriptor) == 0 else {
            let code = errno
            restoreMetadataAfterFailedCommit(
                candidateLeaf: candidate.leaf,
                retiredMetadataSnapshot: retiredMetadataSnapshot,
                validatedCandidate: validatedCandidate,
                candidateDescriptor: candidate.descriptor,
                expectedData: data,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
            throw ProjectMetadataBoundError.persistence(
                operation: "synchronize the project directory",
                code: code
            )
        }
        _ = try? operations.didReachCheckpoint(
            .directoryDurable,
            projectRootDescriptor,
            nil
        )

        do {
            try validateCommittedMetadata(
                validatedCandidate: validatedCandidate,
                expectedData: data,
                metadataURL: metadataURL,
                expectedRootPath: initialRootPath,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
        } catch {
            restoreMetadataAfterFailedCommit(
                candidateLeaf: candidate.leaf,
                retiredMetadataSnapshot: retiredMetadataSnapshot,
                validatedCandidate: validatedCandidate,
                candidateDescriptor: candidate.descriptor,
                expectedData: data,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
            if error is ProjectMetadataBoundError {
                throw error
            }
            throw ProjectMetadataBoundError.metadataConflict
        }

        _ = try? operations.didReachCheckpoint(
            .canonicalValidated,
            projectRootDescriptor,
            nil
        )
        do {
            try validateCommittedMetadata(
                validatedCandidate: validatedCandidate,
                expectedData: data,
                metadataURL: metadataURL,
                expectedRootPath: initialRootPath,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
        } catch {
            restoreMetadataAfterFailedCommit(
                candidateLeaf: candidate.leaf,
                retiredMetadataSnapshot: retiredMetadataSnapshot,
                validatedCandidate: validatedCandidate,
                candidateDescriptor: candidate.descriptor,
                expectedData: data,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
            if error is ProjectMetadataBoundError {
                throw error
            }
            throw ProjectMetadataBoundError.metadataConflict
        }

        if let retiredMetadataSnapshot {
            removeOwnedRetiredMetadata(
                named: candidate.leaf,
                expected: retiredMetadataSnapshot,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
            _ = operations.synchronizeDirectory(projectRootDescriptor)
        }
        return preparedMetadata
    }

    private static func validateCommittedMetadata(
        validatedCandidate: BoundMetadataSnapshot,
        expectedData: Data,
        metadataURL: URL,
        expectedRootPath: String,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) throws {
        let canonical = try readBoundFile(
            named: "project.json",
            projectRootDescriptor: projectRootDescriptor,
            operations: operations
        )
        guard canonical.identity.sameNode(as: validatedCandidate.identity),
              canonical.data == expectedData else {
            throw ProjectMetadataBoundError.metadataConflict
        }
        _ = try validateAgainstBoundProjectRoot(
            descriptor: projectRootDescriptor,
            expectedPath: expectedRootPath
        ) {
            try decodeValidatedMetadataSnapshot(
                canonical.data,
                metadataURL: metadataURL
            )
        }
        guard try boundProjectRootPath(descriptor: projectRootDescriptor)
            == expectedRootPath else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
    }

    private static func createBoundMetadataCandidate(
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) throws -> BoundMetadataCandidate {
        for _ in 0..<32 {
            let leaf = ".project-metadata-\(operations.makeUUID().uuidString.lowercased()).tmp"
            let descriptor = leaf.withCString {
                Darwin.openat(
                    projectRootDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            if descriptor < 0 {
                if errno == EINTR || errno == EEXIST { continue }
                throw ProjectMetadataBoundError.persistence(
                    operation: "create the metadata candidate",
                    code: errno
                )
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                let code = errno
                removeCandidateMatchingDescriptor(
                    named: leaf,
                    descriptor: descriptor,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations
                )
                Darwin.close(descriptor)
                throw ProjectMetadataBoundError.persistence(
                    operation: "secure the metadata candidate",
                    code: code
                )
            }
            var opened = stat()
            var named = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  leaf.withCString({
                      Darwin.fstatat(
                          projectRootDescriptor,
                          $0,
                          &named,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  BoundMetadataIdentity(opened).isPrivateMetadataFile,
                  BoundMetadataIdentity(opened) == BoundMetadataIdentity(named) else {
                removeCandidateMatchingDescriptor(
                    named: leaf,
                    descriptor: descriptor,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations
                )
                Darwin.close(descriptor)
                throw ProjectMetadataBoundError.unsafeMetadata
            }
            return BoundMetadataCandidate(
                leaf: leaf,
                descriptor: descriptor,
                identity: BoundMetadataIdentity(opened)
            )
        }
        throw ProjectMetadataBoundError.persistence(
            operation: "create the metadata candidate",
            code: EEXIST
        )
    }

    private static func removeCandidateMatchingDescriptor(
        named leaf: String,
        descriptor: Int32,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            return
        }
        let openedIdentity = BoundMetadataIdentity(opened)
        guard openedIdentity.isPrivateMetadataFile else {
            return
        }
        removeOwnedCandidate(
            named: leaf,
            descriptor: descriptor,
            ownedNode: openedIdentity,
            refreshedSnapshot: BoundMetadataSnapshot(
                data: Data(),
                identity: openedIdentity
            ),
            projectRootDescriptor: projectRootDescriptor,
            operations: operations
        )
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                operations.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0, count <= data.count - offset else {
                throw ProjectMetadataBoundError.persistence(
                    operation: "write the metadata candidate",
                    code: count < 0 ? errno : EIO
                )
            }
            offset += count
        }
    }

    private static func requireCurrentMetadataIdentity(
        _ expected: BoundMetadataIdentity?,
        projectRootDescriptor: Int32
    ) throws {
        var status = stat()
        let result = "project.json".withCString {
            Darwin.fstatat(
                projectRootDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if let expected {
            guard result == 0,
                  BoundMetadataIdentity(status) == expected else {
                throw ProjectMetadataBoundError.metadataConflict
            }
        } else {
            guard result != 0, errno == ENOENT else {
                throw ProjectMetadataBoundError.metadataConflict
            }
        }
    }

    private static func requireCurrentCandidateIdentity(
        _ expected: BoundMetadataIdentity,
        descriptor: Int32,
        named leaf: String,
        projectRootDescriptor: Int32
    ) throws {
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              leaf.withCString({
                  Darwin.fstatat(
                      projectRootDescriptor,
                      $0,
                      &named,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0 else {
            throw ProjectMetadataBoundError.metadataConflict
        }
        let openedIdentity = BoundMetadataIdentity(opened)
        let namedIdentity = BoundMetadataIdentity(named)
        guard openedIdentity == expected,
              namedIdentity == expected,
              openedIdentity.isPrivateMetadataFile else {
            throw ProjectMetadataBoundError.metadataConflict
        }
    }

    private static func namedEntryIdentity(
        _ leaf: String,
        projectRootDescriptor: Int32
    ) throws -> BoundMetadataIdentity? {
        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(
                projectRootDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            return BoundMetadataIdentity(status)
        }
        guard errno == ENOENT else {
            throw ProjectMetadataBoundError.metadataConflict
        }
        return nil
    }

    /// Reverses one just-completed exchange only while both names still bind
    /// the exact entries observed after that exchange. This restores the
    /// namespace that existed immediately before the attempted commit, whether
    /// it held the expected prior metadata or a concurrent foreign replacement.
    private static func reverseObservedMetadataExchange(
        candidateLeaf: String,
        observedCandidate: BoundMetadataIdentity?,
        observedCanonical: BoundMetadataIdentity?,
        validatedCandidate: BoundMetadataSnapshot,
        expectedData: Data,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        guard let observedCandidate,
              let observedCanonical else { return }
        do {
            guard try namedEntryIdentity(
                candidateLeaf,
                projectRootDescriptor: projectRootDescriptor
            ) == observedCandidate,
            try namedEntryIdentity(
                "project.json",
                projectRootDescriptor: projectRootDescriptor
            ) == observedCanonical,
            operations.exchange(
                projectRootDescriptor,
                candidateLeaf,
                "project.json"
            ) == 0,
            let restoredCanonical = try namedEntryIdentity(
                "project.json",
                projectRootDescriptor: projectRootDescriptor
            ),
            let preservedCandidate = try namedEntryIdentity(
                candidateLeaf,
                projectRootDescriptor: projectRootDescriptor
            ),
            restoredCanonical.sameNode(as: observedCandidate),
            preservedCandidate.sameNode(as: observedCanonical) else {
                return
            }
            _ = operations.synchronizeDirectory(projectRootDescriptor)
        } catch {
            return
        }
    }

    /// Moves a failed first publication back to its private candidate name.
    /// The exclusive rename prevents overwriting a concurrent entry created at
    /// that name; an unknown installed file is preserved for conflict handling.
    private static func reverseObservedInitialMetadataRename(
        candidateLeaf: String,
        observedCanonical: BoundMetadataIdentity?,
        validatedCandidate: BoundMetadataSnapshot,
        candidateDescriptor: Int32,
        expectedData: Data,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        guard let observedCanonical else { return }
        do {
            let canonical = try readBoundFile(
                named: "project.json",
                projectRootDescriptor: projectRootDescriptor,
                operations: .system()
            )
            var opened = stat()
            guard Darwin.fstat(candidateDescriptor, &opened) == 0,
                  canonical.identity == BoundMetadataIdentity(opened),
                  canonical.identity == observedCanonical,
                  canonical.identity.sameNode(as: validatedCandidate.identity),
                  canonical.identity.isPrivateMetadataFile,
                  canonical.data == expectedData,
                  try namedEntryIdentity(
                      candidateLeaf,
                      projectRootDescriptor: projectRootDescriptor
                  ) == nil else {
                return
            }

            let renameResult = operations.renameExclusive(
                projectRootDescriptor,
                "project.json",
                candidateLeaf
            )
            let movedCandidate = try? readBoundFile(
                named: candidateLeaf,
                projectRootDescriptor: projectRootDescriptor,
                operations: .system()
            )
            let canonicalAfterRename = try namedEntryIdentity(
                "project.json",
                projectRootDescriptor: projectRootDescriptor
            )
            if let movedCandidate,
               canonicalAfterRename == nil,
               movedCandidate.identity.sameNode(as: validatedCandidate.identity),
               movedCandidate.data == expectedData {
                _ = operations.synchronizeDirectory(projectRootDescriptor)
                return
            }
            if renameResult == 0 || canonicalAfterRename == nil {
                restoreMovedEntryToCanonical(
                    candidateLeaf: candidateLeaf,
                    observedCandidate: movedCandidate,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations
                )
            }
        } catch {
            return
        }
    }

    private static func restoreMovedEntryToCanonical(
        candidateLeaf: String,
        observedCandidate: BoundMetadataSnapshot?,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        guard let observedCandidate else { return }
        do {
            guard try namedEntryIdentity(
                "project.json",
                projectRootDescriptor: projectRootDescriptor
            ) == nil,
            let currentCandidate = try? readBoundFile(
                named: candidateLeaf,
                projectRootDescriptor: projectRootDescriptor,
                operations: .system()
            ),
            currentCandidate.identity == observedCandidate.identity,
            currentCandidate.data == observedCandidate.data else {
                return
            }
            _ = operations.renameExclusive(
                projectRootDescriptor,
                candidateLeaf,
                "project.json"
            )
            guard let restored = try? readBoundFile(
                named: "project.json",
                projectRootDescriptor: projectRootDescriptor,
                operations: .system()
            ),
            restored.identity.sameNode(as: observedCandidate.identity),
            restored.data == observedCandidate.data else {
                return
            }
            _ = operations.synchronizeDirectory(projectRootDescriptor)
        } catch {
            return
        }
    }

    private static func restoreMetadataAfterFailedCommit(
        candidateLeaf: String,
        retiredMetadataSnapshot: BoundMetadataSnapshot?,
        validatedCandidate: BoundMetadataSnapshot,
        candidateDescriptor: Int32,
        expectedData: Data,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        do {
            let canonical = try namedEntryIdentity(
                "project.json",
                projectRootDescriptor: projectRootDescriptor
            )
            if let retiredMetadataSnapshot {
                let retired = try namedEntryIdentity(
                    candidateLeaf,
                    projectRootDescriptor: projectRootDescriptor
                )
                guard retired == retiredMetadataSnapshot.identity else { return }
                reverseObservedMetadataExchange(
                    candidateLeaf: candidateLeaf,
                    observedCandidate: retired,
                    observedCanonical: canonical,
                    validatedCandidate: validatedCandidate,
                    expectedData: expectedData,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations
                )
                return
            }
            reverseObservedInitialMetadataRename(
                candidateLeaf: candidateLeaf,
                observedCanonical: canonical,
                validatedCandidate: validatedCandidate,
                candidateDescriptor: candidateDescriptor,
                expectedData: expectedData,
                projectRootDescriptor: projectRootDescriptor,
                operations: operations
            )
        } catch {
            return
        }
    }

    private static func refreshedOwnedCandidateSnapshot(
        named leaf: String,
        descriptor: Int32,
        ownedNode: BoundMetadataIdentity,
        projectRootDescriptor: Int32
    ) -> BoundMetadataSnapshot? {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              BoundMetadataIdentity(opened).sameNode(as: ownedNode),
              let snapshot = try? readBoundFile(
                  named: leaf,
                  projectRootDescriptor: projectRootDescriptor,
                  operations: .system()
              ),
              snapshot.identity == BoundMetadataIdentity(opened),
              snapshot.identity.sameNode(as: ownedNode),
              snapshot.identity.isPrivateMetadataFile else {
            return nil
        }
        return snapshot
    }

    private static func removeOwnedRetiredMetadata(
        named leaf: String,
        expected: BoundMetadataSnapshot,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        quarantineAndRemoveOwnedEntry(
            named: leaf,
            expected: expected,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations
        )
    }

    private static func removeOwnedCandidate(
        named leaf: String,
        descriptor: Int32,
        ownedNode: BoundMetadataIdentity,
        refreshedSnapshot: BoundMetadataSnapshot,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        guard isMetadataCandidateLeaf(leaf),
              let current = refreshedOwnedCandidateSnapshot(
                  named: leaf,
                  descriptor: descriptor,
                  ownedNode: ownedNode,
                  projectRootDescriptor: projectRootDescriptor
              ),
              current.identity.sameNode(as: refreshedSnapshot.identity) else {
            return
        }
        quarantineAndRemoveOwnedEntry(
            named: leaf,
            expected: current,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations
        )
    }

    private static func quarantineAndRemoveOwnedEntry(
        named leaf: String,
        expected: BoundMetadataSnapshot,
        projectRootDescriptor: Int32,
        operations: ProjectMetadataBoundOperations
    ) {
        guard isMetadataCandidateLeaf(leaf),
              expected.identity.isPrivateMetadataFile,
              let source = try? readBoundFile(
                  named: leaf,
                  projectRootDescriptor: projectRootDescriptor,
                  operations: .system()
              ),
              source.identity == expected.identity,
              source.data == expected.data else {
            return
        }

        for _ in 0..<32 {
            let quarantineLeaf = metadataQuarantineLeaf(
                operations.makeUUID()
            )
            let renameResult = operations.renameExclusive(
                projectRootDescriptor,
                leaf,
                quarantineLeaf
            )
            let renameCode = errno
            let quarantined = try? readBoundFile(
                named: quarantineLeaf,
                projectRootDescriptor: projectRootDescriptor,
                operations: .system()
            )
            if let quarantined,
               quarantined.identity.sameNode(as: source.identity),
               quarantined.data == source.data,
               quarantined.identity.isPrivateMetadataFile {
                removeExactQuarantinedEntry(
                    named: quarantineLeaf,
                    expected: quarantined,
                    projectRootDescriptor: projectRootDescriptor
                )
                return
            }
            if renameResult != 0, renameCode == EEXIST {
                continue
            }
            return
        }
    }

    private static func removeExactQuarantinedEntry(
        named leaf: String,
        expected: BoundMetadataSnapshot,
        projectRootDescriptor: Int32
    ) {
        guard isMetadataQuarantineLeaf(leaf),
              let current = try? readBoundFile(
                  named: leaf,
                  projectRootDescriptor: projectRootDescriptor,
                  operations: .system()
              ),
              current.identity == expected.identity,
              current.data == expected.data else {
            return
        }
        leaf.withCString { _ = Darwin.unlinkat(projectRootDescriptor, $0, 0) }
    }

    private static func metadataQuarantineLeaf(_ id: UUID) -> String {
        ".project-metadata-quarantine-\(id.uuidString.lowercased()).tmp"
    }

    private static func isMetadataCandidateLeaf(_ leaf: String) -> Bool {
        isMetadataPrivateLeaf(
            leaf,
            prefix: ".project-metadata-",
            excludingPrefix: ".project-metadata-quarantine-"
        )
    }

    private static func isMetadataQuarantineLeaf(_ leaf: String) -> Bool {
        isMetadataPrivateLeaf(
            leaf,
            prefix: ".project-metadata-quarantine-",
            excludingPrefix: nil
        )
    }

    private static func isMetadataPrivateLeaf(
        _ leaf: String,
        prefix: String,
        excludingPrefix: String?
    ) -> Bool {
        guard leaf.hasPrefix(prefix),
              !leaf.dropFirst(prefix.count).contains("/"),
              leaf.hasSuffix(".tmp"),
              excludingPrefix.map({ !leaf.hasPrefix($0) }) ?? true else {
            return false
        }
        let idStart = leaf.index(leaf.startIndex, offsetBy: prefix.count)
        let idEnd = leaf.index(leaf.endIndex, offsetBy: -4)
        return UUID(uuidString: String(leaf[idStart..<idEnd])) != nil
    }

    private static func validateRequiredIdentities(in metadata: ProjectMetadata) throws {
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard metadata.id != zeroUUID else {
            throw LoadError.invalidProjectID
        }
        guard metadata.pendingPublicationID != zeroUUID else {
            throw LoadError.invalidPendingPublicationID
        }
        // A retrain persists the prior `.done` boundary until its first stage
        // advances, and a failed final publication can also stop at `.done`.
        // A pending identity on a terminal success with no run marker is instead
        // corrupt authority state and must fail closed.
        if metadata.pendingPublicationID != nil,
           metadata.state.stage == .done,
           metadata.state.lastError == nil,
           metadata.lastRunStartedAt == nil {
            throw LoadError.invalidPendingPublicationID
        }
    }

    private static func validateArtifactPaths(
        in metadata: ProjectMetadata,
        metadataURL: URL
    ) throws {
        let paths = ProjectPaths(root: metadataURL.deletingLastPathComponent())
        if let retryBudget = metadata.trainingMemoryRetryBudgetBytes,
           retryBudget <= 0 {
            throw LoadError.invalidTrainingMemoryRetryBudget(retryBudget)
        }
        if let plan = metadata.resolvedRunPlan {
            do {
                try plan.validate()
            } catch {
                throw LoadError.invalidResolvedRunPlan
            }
            let requiresCrossClipRetrieval = RunPlanResolver.requiresCrossClipRetrieval(
                requestedInputOrdering: metadata.requestedRunOptions.inputOrdering,
                input: metadata.input
            )
            guard plan.requiresCrossClipRetrieval == requiresCrossClipRetrieval else {
                throw LoadError.invalidResolvedRunPlan
            }
        }
        if let recovery = metadata.geometryRecovery {
            do {
                try recovery.validate()
            } catch {
                throw LoadError.invalidGeometryRecovery(error.localizedDescription)
            }
        }
        var artifactPaths: [(field: String, path: String)] = []
        if let details = metadata.checkpoint?.details {
            switch details {
            case .extractFrames:
                break
            case .selectFrames(let checkpoint):
                if let path = checkpoint.manifestPath {
                    artifactPaths.append(("checkpoint.selectFrames.manifestPath", path))
                }
            case .sfmFeatures(let checkpoint):
                artifactPaths.append(("checkpoint.sfmFeatures.databasePath", checkpoint.databasePath))
            case .sfmMatching(let checkpoint):
                artifactPaths.append(("checkpoint.sfmMatching.databasePath", checkpoint.databasePath))
            case .trainSplat:
                break
            case .exportSplat(let checkpoint):
                artifactPaths.append(("checkpoint.exportSplat.outputPath", checkpoint.outputPath))
                artifactPaths.append(("checkpoint.exportSplat.sourcePath", checkpoint.sourcePath))
            }
        }

        for artifactPath in artifactPaths {
            do {
                _ = try paths.resolveProjectRelativePath(artifactPath.path)
            } catch {
                throw LoadError.invalidArtifactPath(
                    field: artifactPath.field,
                    path: artifactPath.path
                )
            }
            guard pathUsesAllowedNamespace(
                field: artifactPath.field,
                path: artifactPath.path
            ) else {
                throw LoadError.invalidArtifactNamespace(
                    field: artifactPath.field,
                    path: artifactPath.path
                )
            }
        }

    }

    private static func pathUsesAllowedNamespace(field: String, path: String) -> Bool {
        switch field {
        case "checkpoint.exportSplat.outputPath":
            return path.hasPrefix("Output/")
        case "checkpoint.selectFrames.manifestPath":
            return path.hasPrefix("Frames/")
        case "checkpoint.sfmFeatures.databasePath", "checkpoint.sfmMatching.databasePath":
            return path == "SfM/colmap/database.db"
        case "checkpoint.exportSplat.sourcePath":
            return path.hasPrefix("Training/")
        default:
            return false
        }
    }
}

private struct BoundMetadataSnapshot {
    let data: Data
    let identity: BoundMetadataIdentity
}

private struct BoundMetadataCandidate {
    let leaf: String
    let descriptor: Int32
    let identity: BoundMetadataIdentity
}

private struct BoundMetadataIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let linkCount: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        mode = UInt32(status.st_mode)
        owner = UInt32(status.st_uid)
        group = UInt32(status.st_gid)
        linkCount = UInt64(status.st_nlink)
        size = Int64(status.st_size)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    var isSafeMetadataFile: Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFREG)
            && owner == UInt32(geteuid())
            && linkCount == 1
    }

    var isPrivateMetadataFile: Bool {
        isSafeMetadataFile && mode & UInt32(0o7777) == UInt32(0o600)
    }

    func sameNode(as other: Self) -> Bool {
        device == other.device
            && inode == other.inode
            && mode & UInt32(S_IFMT) == other.mode & UInt32(S_IFMT)
            && owner == other.owner
    }
}

private final class ProjectMetadataFileLocks: @unchecked Sendable {
    private let registryLock = NSLock()
    private var gates: [String: ProjectMetadataReentrantGate] = [:]

    func withLock<Value>(
        forProjectMetadataURL url: URL,
        _ body: (Int32, String) throws -> Value
    ) throws -> Value {
        let rootURL = url.deletingLastPathComponent()
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProjectMetadataBoundError.persistence(
                operation: "open the project directory",
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        var namedStatus = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              rootURL.path.withCString({ Darwin.lstat($0, &namedStatus) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              namedStatus.st_dev == status.st_dev,
              namedStatus.st_ino == status.st_ino,
              namedStatus.st_mode & S_IFMT == S_IFDIR,
              namedStatus.st_uid == status.st_uid else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        let expectedRootPath = try ProjectMetadataStore.boundProjectRootPath(
            descriptor: descriptor
        )
        let key = descriptorKey(status)
        let gate = gate(for: key)
        return try gate.withReservation {
            try requireURLRootBinding(
                rootURL,
                descriptor: descriptor,
                expected: status,
                expectedRootPath: expectedRootPath
            )
            do {
                let result = try body(descriptor, expectedRootPath)
                try requireURLRootBinding(
                    rootURL,
                    descriptor: descriptor,
                    expected: status,
                    expectedRootPath: expectedRootPath
                )
                return result
            } catch {
                guard (try? requireURLRootBinding(
                    rootURL,
                    descriptor: descriptor,
                    expected: status,
                    expectedRootPath: expectedRootPath
                )) != nil else {
                    throw ProjectMetadataBoundError.unsafeProjectRoot
                }
                throw error
            }
        }
    }

    func withPathLock<Value>(
        for url: URL,
        _ body: () throws -> Value
    ) rethrows -> Value {
        let gate = gate(for: pathKey(url))
        return try gate.withReservation(body)
    }

    func withLock<Value>(
        forProjectRootDescriptor descriptor: Int32,
        _ body: () throws -> Value
    ) throws -> Value {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid() else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
        let key = descriptorKey(status)
        let gate = gate(for: key)
        return try gate.withReservation(body)
    }

    private func gate(for key: String) -> ProjectMetadataReentrantGate {
        registryLock.withLock {
            if let existing = gates[key] {
                return existing
            }
            let created = ProjectMetadataReentrantGate()
            gates[key] = created
            return created
        }
    }

    private func descriptorKey(_ status: stat) -> String {
        "descriptor:\(UInt64(status.st_dev)):\(UInt64(status.st_ino))"
    }

    private func requireURLRootBinding(
        _ rootURL: URL,
        descriptor: Int32,
        expected: stat,
        expectedRootPath: String
    ) throws {
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              rootURL.path.withCString({ Darwin.lstat($0, &named) }) == 0,
              opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_uid == expected.st_uid,
              named.st_dev == expected.st_dev,
              named.st_ino == expected.st_ino,
              named.st_mode & S_IFMT == S_IFDIR,
              named.st_uid == expected.st_uid,
              try ProjectMetadataStore.boundProjectRootPath(
                  descriptor: descriptor
              ) == expectedRootPath else {
            throw ProjectMetadataBoundError.unsafeProjectRoot
        }
    }

    private func pathKey(_ url: URL) -> String {
        "path:\(url.standardizedFileURL.resolvingSymlinksInPath().path)"
    }
}

/// Serializes one project's metadata operations without holding an OS mutex
/// while client mutations or deterministic test callbacks execute. Same-thread
/// reentry is permitted, so a callback may consult another store that resolves
/// back to this project; descriptor/content checks still reject stale outer
/// commits. Other threads wait on the condition and therefore retain the
/// existing URL/descriptor serialization contract.
private final class ProjectMetadataReentrantGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var ownerThread: UInt32?
    private var depth = 0

    func withReservation<Value>(_ body: () throws -> Value) rethrows -> Value {
        let thread = pthread_mach_thread_np(pthread_self())
        condition.lock()
        while let ownerThread, ownerThread != thread {
            condition.wait()
        }
        if ownerThread == nil {
            ownerThread = thread
        }
        depth += 1
        condition.unlock()

        defer {
            condition.lock()
            depth -= 1
            if depth == 0 {
                ownerThread = nil
                condition.broadcast()
            }
            condition.unlock()
        }
        return try body()
    }
}
