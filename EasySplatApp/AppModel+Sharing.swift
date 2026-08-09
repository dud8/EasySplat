import AppKit
import CryptoKit
import Darwin
import EasySplatCore
import Foundation

struct ShareFileSnapshot: Equatable, Sendable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
    let mode: UInt16
    let linkCount: UInt64
    let byteCount: Int64
    let modificationDate: Date
    let modificationNanoseconds: Int64
    let statusChangeDate: Date
    let statusChangeNanoseconds: Int64
    let creationDate: Date
    let creationNanoseconds: Int64
    let sha256: String

    private struct StableIdentity: Equatable {
        let deviceNumber: dev_t
        let fileNumber: ino_t
        let mode: mode_t
        let linkCount: nlink_t
        let byteCount: off_t
        let modificationSeconds: time_t
        let modificationNanoseconds: Int64
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int64
        let creationSeconds: time_t
        let creationNanoseconds: Int64

        init(_ status: stat) {
            deviceNumber = status.st_dev
            fileNumber = status.st_ino
            mode = status.st_mode
            linkCount = status.st_nlink
            byteCount = status.st_size
            modificationSeconds = status.st_mtimespec.tv_sec
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            statusChangeSeconds = status.st_ctimespec.tv_sec
            statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            creationSeconds = status.st_birthtimespec.tv_sec
            creationNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        }

        var isShareableRegularFile: Bool {
            (mode & S_IFMT) == S_IFREG && linkCount == 1 && byteCount > 0
        }
    }

    static func capture(at url: URL) -> ShareFileSnapshot? {
        try? capture(at: url, shouldCancel: { false })
    }

    static func capture(
        at url: URL,
        shouldCancel: @escaping @Sendable () -> Bool,
        read: @escaping @Sendable (
            Int32,
            UnsafeMutableRawPointer?,
            Int
        ) -> Int = { descriptor, bytes, count in
            Darwin.read(descriptor, bytes, count)
        }
    ) throws -> ShareFileSnapshot? {
        try checkCancellation(shouldCancel)
        var pathBeforeOpen = stat()
        guard lstat(url.path, &pathBeforeOpen) == 0 else {
            return nil
        }
        let expectedIdentity = StableIdentity(pathBeforeOpen)
        guard expectedIdentity.isShareableRegularFile else { return nil }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              StableIdentity(initial) == expectedIdentity else {
            return nil
        }

        var hasher = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try checkCancellation(shouldCancel)
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= buffer.count else { return nil }
            if count == 0 { break }
            consumed += Int64(count)
            buffer.withUnsafeBytes { bytes in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count])
                )
            }
        }

        try checkCancellation(shouldCancel)
        var final = stat()
        var pathAfterRead = stat()
        guard fstat(descriptor, &final) == 0,
              lstat(url.path, &pathAfterRead) == 0,
              consumed == Int64(initial.st_size),
              StableIdentity(final) == expectedIdentity,
              StableIdentity(pathAfterRead) == expectedIdentity else {
            return nil
        }

        return makeSnapshot(
            status: initial,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func checkCancellation(
        _ shouldCancel: @Sendable () -> Bool
    ) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    static func captureIdentity(at url: URL, verifiedSHA256: String) -> ShareFileSnapshot? {
        guard verifiedSHA256.count == 64,
              verifiedSHA256.allSatisfy({ $0.isHexDigit }),
              verifiedSHA256 == verifiedSHA256.lowercased() else {
            return nil
        }
        var pathBeforeOpen = stat()
        guard lstat(url.path, &pathBeforeOpen) == 0 else { return nil }
        let expectedIdentity = StableIdentity(pathBeforeOpen)
        guard expectedIdentity.isShareableRegularFile else { return nil }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var pathAfterOpen = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(url.path, &pathAfterOpen) == 0,
              StableIdentity(opened) == expectedIdentity,
              StableIdentity(pathAfterOpen) == expectedIdentity else {
            return nil
        }
        return makeSnapshot(status: opened, sha256: verifiedSHA256)
    }

    private static func makeSnapshot(status: stat, sha256: String) -> ShareFileSnapshot {
        ShareFileSnapshot(
            deviceNumber: UInt64(status.st_dev),
            fileNumber: UInt64(status.st_ino),
            mode: UInt16(status.st_mode),
            linkCount: UInt64(status.st_nlink),
            byteCount: Int64(status.st_size),
            modificationDate: Self.date(from: status.st_mtimespec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            statusChangeDate: Self.date(from: status.st_ctimespec),
            statusChangeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            creationDate: Self.date(from: status.st_birthtimespec),
            creationNanoseconds: Int64(status.st_birthtimespec.tv_nsec),
            sha256: sha256
        )
    }

    private static func date(from value: timespec) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(value.tv_sec)
                + TimeInterval(value.tv_nsec) / 1_000_000_000
        )
    }
}

struct ShareSnapshotDirectoryIdentity: Equatable, Sendable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
    let ownerID: UInt32
    let mode: UInt16

    fileprivate init(status: stat) {
        deviceNumber = UInt64(status.st_dev)
        fileNumber = UInt64(status.st_ino)
        ownerID = UInt32(status.st_uid)
        mode = UInt16(status.st_mode)
    }

    fileprivate init(
        deviceNumber: UInt64,
        fileNumber: UInt64,
        ownerID: UInt32,
        mode: UInt16
    ) {
        self.deviceNumber = deviceNumber
        self.fileNumber = fileNumber
        self.ownerID = ownerID
        self.mode = mode
    }

    fileprivate func matches(_ status: stat) -> Bool {
        deviceNumber == UInt64(status.st_dev)
            && fileNumber == UInt64(status.st_ino)
            && ownerID == UInt32(status.st_uid)
            && mode == UInt16(status.st_mode)
    }
}

struct ShareSnapshotDirectory: Equatable, Sendable {
    let url: URL
    let identity: ShareSnapshotDirectoryIdentity
    let leaseID: UUID
    let launchID: UUID
    let registryURL: URL
}

private enum ShareSnapshotStorageError: Error {
    case unavailable
}

enum ShareSnapshotRemovalOutcome: Equatable, Sendable {
    case removed
    case alreadyAbsent
    case refused
}

struct ShareSnapshotReclamationReport: Equatable, Sendable {
    var removed = 0
    var alreadyAbsent = 0
    var refused = 0
}

private struct ShareSnapshotRegisteredFile: Codable, Equatable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
    let mode: UInt16
    let linkCount: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
    let creationSeconds: Int64
    let creationNanoseconds: Int64
    let sha256: String

    init(_ snapshot: ShareFileSnapshot) {
        deviceNumber = snapshot.deviceNumber
        fileNumber = snapshot.fileNumber
        mode = snapshot.mode
        linkCount = snapshot.linkCount
        byteCount = snapshot.byteCount
        modificationSeconds = Int64(snapshot.modificationDate.timeIntervalSince1970.rounded(.down))
        modificationNanoseconds = snapshot.modificationNanoseconds
        statusChangeSeconds = Int64(snapshot.statusChangeDate.timeIntervalSince1970.rounded(.down))
        statusChangeNanoseconds = snapshot.statusChangeNanoseconds
        creationSeconds = Int64(snapshot.creationDate.timeIntervalSince1970.rounded(.down))
        creationNanoseconds = snapshot.creationNanoseconds
        sha256 = snapshot.sha256
    }

    func matches(_ status: stat) -> Bool {
        deviceNumber == UInt64(status.st_dev)
            && fileNumber == UInt64(status.st_ino)
            && mode == UInt16(status.st_mode)
            && linkCount == UInt64(status.st_nlink)
            && byteCount == Int64(status.st_size)
            && modificationSeconds == Int64(status.st_mtimespec.tv_sec)
            && modificationNanoseconds == Int64(status.st_mtimespec.tv_nsec)
            && statusChangeSeconds == Int64(status.st_ctimespec.tv_sec)
            && statusChangeNanoseconds == Int64(status.st_ctimespec.tv_nsec)
            && creationSeconds == Int64(status.st_birthtimespec.tv_sec)
            && creationNanoseconds == Int64(status.st_birthtimespec.tv_nsec)
    }
}

private struct ShareSnapshotLeaseRecord: Codable, Equatable {
    let leaseID: UUID
    let launchID: UUID
    let ownerProcessID: Int32
    var directoryPath: String
    let directoryDeviceNumber: UInt64
    let directoryFileNumber: UInt64
    let directoryOwnerID: UInt32
    let directoryMode: UInt16
    var expectedFileLeaf: String?
    var publishedFile: ShareSnapshotRegisteredFile?
    let createdAt: TimeInterval
    var lastActivityAt: TimeInterval

    func matches(_ directory: ShareSnapshotDirectory) -> Bool {
        leaseID == directory.leaseID
            && launchID == directory.launchID
            && URL(fileURLWithPath: directoryPath, isDirectory: true)
                .standardizedFileURL.path
                == directory.url.standardizedFileURL.path
            && directoryDeviceNumber == directory.identity.deviceNumber
            && directoryFileNumber == directory.identity.fileNumber
            && directoryOwnerID == directory.identity.ownerID
            && directoryMode == directory.identity.mode
    }

    func directory(registryURL: URL) -> ShareSnapshotDirectory {
        ShareSnapshotDirectory(
            url: URL(fileURLWithPath: directoryPath, isDirectory: true),
            identity: ShareSnapshotDirectoryIdentity(
                deviceNumber: directoryDeviceNumber,
                fileNumber: directoryFileNumber,
                ownerID: directoryOwnerID,
                mode: directoryMode
            ),
            leaseID: leaseID,
            launchID: launchID,
            registryURL: registryURL.standardizedFileURL
        )
    }
}

private struct ShareSnapshotLeaseRegistryDocument: Codable {
    let schemaVersion: Int
    var records: [ShareSnapshotLeaseRecord]
}

enum ShareSnapshotStorage {
    private static let directoryPrefix = "EasySplatShare."
    private static let cleanupPrefix = ".EasySplatShareCleanup."
    private static let registrySchemaVersion = 2
    private static let maximumRegistryBytes = 4 * 1_024 * 1_024
    private static let processLaunchID = UUID()

    static var defaultRegistryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("EasySplat", isDirectory: true)
            .appendingPathComponent("ShareSnapshots", isDirectory: true)
            .appendingPathComponent("leases.json", isDirectory: false)
    }

    static func create(
        in temporaryRoot: URL = FileManager.default.temporaryDirectory,
        registryURL requestedRegistryURL: URL? = nil,
        launchID: UUID = processLaunchID,
        now: Date = Date()
    ) throws -> ShareSnapshotDirectory {
        let root = temporaryRoot.standardizedFileURL
        let registryURL = (requestedRegistryURL ?? defaultRegistryURL).standardizedFileURL
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw ShareSnapshotStorageError.unavailable }
        defer { Darwin.close(rootDescriptor) }

        var rootStatus = stat()
        var rootPathStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              lstat(root.path, &rootPathStatus) == 0,
              sameDirectory(rootStatus, rootPathStatus),
              rootStatus.st_uid == getuid(),
              rootStatus.st_mode & mode_t(0o077) == 0 else {
            throw ShareSnapshotStorageError.unavailable
        }

        // mkdirat binds creation to the directory we verified above. A same-user
        // process cannot redirect this operation through a planted child symlink.
        for _ in 0..<8 {
            let leaf = directoryPrefix + UUID().uuidString
            let creationResult = leaf.withCString {
                Darwin.mkdirat(rootDescriptor, $0, mode_t(0o700))
            }
            if creationResult != 0 {
                if errno == EEXIST { continue }
                throw ShareSnapshotStorageError.unavailable
            }
            var removeOnFailure = true
            defer {
                if removeOnFailure {
                    leaf.withCString {
                        _ = Darwin.unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
                    }
                }
            }

            let directoryDescriptor = leaf.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard directoryDescriptor >= 0 else {
                throw ShareSnapshotStorageError.unavailable
            }
            defer { Darwin.close(directoryDescriptor) }
            guard fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
                throw ShareSnapshotStorageError.unavailable
            }

            var directoryStatus = stat()
            var pathStatus = stat()
            var finalRootPathStatus = stat()
            var absolutePathStatus = stat()
            let directoryURL = root.appendingPathComponent(leaf, isDirectory: true)
            guard fstat(directoryDescriptor, &directoryStatus) == 0,
                  leaf.withCString({
                      Darwin.fstatat(rootDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  sameDirectory(directoryStatus, pathStatus),
                  lstat(root.path, &finalRootPathStatus) == 0,
                  sameDirectory(rootStatus, finalRootPathStatus),
                  lstat(directoryURL.path, &absolutePathStatus) == 0,
                  sameDirectory(directoryStatus, absolutePathStatus),
                  directoryStatus.st_uid == getuid(),
                  directoryStatus.st_mode & mode_t(0o7777) == mode_t(0o700) else {
                throw ShareSnapshotStorageError.unavailable
            }
            let directory = ShareSnapshotDirectory(
                url: directoryURL,
                identity: ShareSnapshotDirectoryIdentity(status: directoryStatus),
                leaseID: UUID(),
                launchID: launchID,
                registryURL: registryURL
            )
            let record = ShareSnapshotLeaseRecord(
                leaseID: directory.leaseID,
                launchID: launchID,
                ownerProcessID: getpid(),
                directoryPath: directoryURL.path,
                directoryDeviceNumber: directory.identity.deviceNumber,
                directoryFileNumber: directory.identity.fileNumber,
                directoryOwnerID: directory.identity.ownerID,
                directoryMode: directory.identity.mode,
                expectedFileLeaf: nil,
                publishedFile: nil,
                createdAt: now.timeIntervalSince1970,
                lastActivityAt: now.timeIntervalSince1970
            )
            try mutateRegistry(at: registryURL) { records in
                guard !records.contains(where: {
                    $0.leaseID == record.leaseID || $0.directoryPath == record.directoryPath
                }) else {
                    throw ShareSnapshotStorageError.unavailable
                }
                records.append(record)
            }
            removeOnFailure = false
            return directory
        }
        throw ShareSnapshotStorageError.unavailable
    }

    static func prepareForPublication(
        _ directory: ShareSnapshotDirectory,
        expectedFileLeaf: String,
        now: Date = Date()
    ) throws {
        guard isSafeLeaf(expectedFileLeaf) else {
            throw ShareSnapshotStorageError.unavailable
        }
        try mutateRegistry(at: directory.registryURL) { records in
            guard let index = records.firstIndex(where: { $0.leaseID == directory.leaseID }),
                  records[index].matches(directory),
                  records[index].expectedFileLeaf == nil
                    || records[index].expectedFileLeaf == expectedFileLeaf else {
                throw ShareSnapshotStorageError.unavailable
            }
            records[index].expectedFileLeaf = expectedFileLeaf
            records[index].publishedFile = nil
            records[index].lastActivityAt = now.timeIntervalSince1970
        }
    }

    static func recordPublishedFile(
        _ directory: ShareSnapshotDirectory,
        snapshot: ShareFileSnapshot,
        now: Date = Date()
    ) throws {
        guard snapshot.linkCount == 1,
              snapshot.byteCount > 0,
              snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFREG),
              snapshot.mode & UInt16(0o7777) == UInt16(0o600) else {
            throw ShareSnapshotStorageError.unavailable
        }
        try mutateRegistry(at: directory.registryURL) { records in
            guard let index = records.firstIndex(where: { $0.leaseID == directory.leaseID }),
                  records[index].matches(directory),
                  records[index].expectedFileLeaf != nil else {
                throw ShareSnapshotStorageError.unavailable
            }
            records[index].publishedFile = ShareSnapshotRegisteredFile(snapshot)
            records[index].lastActivityAt = now.timeIntervalSince1970
        }
    }

    @discardableResult
    static func remove(
        _ directory: ShareSnapshotDirectory,
        expectedFileLeaf: String?
    ) -> ShareSnapshotRemovalOutcome {
        let directoryURL = directory.url.standardizedFileURL
        let leaf = directoryURL.lastPathComponent
        guard leaf.hasPrefix(directoryPrefix),
              UUID(uuidString: String(leaf.dropFirst(directoryPrefix.count))) != nil,
              expectedFileLeaf == nil || isSafeLeaf(expectedFileLeaf!) else {
            return .refused
        }
        guard let record = registryRecord(for: directory) else {
            return .refused
        }
        if let registeredLeaf = record.expectedFileLeaf,
           let expectedFileLeaf,
           registeredLeaf != expectedFileLeaf {
            return .refused
        }
        let removalLeaf = record.expectedFileLeaf ?? expectedFileLeaf
        let root = directoryURL.deletingLastPathComponent().standardizedFileURL
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            if errno == ENOENT {
                pruneRegistryRecord(for: directory)
                return .alreadyAbsent
            }
            return .refused
        }
        defer { Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        var rootPathStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              lstat(root.path, &rootPathStatus) == 0,
              sameDirectory(rootStatus, rootPathStatus),
              rootStatus.st_uid == getuid(),
              rootStatus.st_mode & mode_t(0o077) == 0 else {
            return .refused
        }

        let sourceDescriptor = leaf.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard sourceDescriptor >= 0 else {
            if errno == ENOENT {
                pruneRegistryRecord(for: directory)
                return .alreadyAbsent
            }
            return .refused
        }
        defer { Darwin.close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              directory.identity.matches(sourceStatus),
              sourceStatus.st_uid == getuid(),
              sourceStatus.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            return .refused
        }

        guard let entries = directoryEntries(descriptor: sourceDescriptor) else {
            return .refused
        }
        let expectedEntries = removalLeaf.map { Set([$0]) } ?? []
        guard Set(entries) == expectedEntries || entries.isEmpty else {
            return .refused
        }
        if record.expectedFileLeaf == nil, !entries.isEmpty {
            return .refused
        }
        if let removalLeaf, entries.contains(removalLeaf) {
            var fileStatus = stat()
            guard removalLeaf.withCString({
                Darwin.fstatat(sourceDescriptor, $0, &fileStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  isOwnedSnapshotFile(fileStatus, directoryStatus: sourceStatus),
                  record.publishedFile?.matches(fileStatus) == true else {
                return .refused
            }
        }

        // Quarantine the identity-bound directory before unlinking its file. If
        // the public leaf was swapped, the post-rename identity check preserves it.
        let cleanupLeaf = cleanupPrefix + UUID().uuidString
        let renamed = leaf.withCString { sourcePointer in
            cleanupLeaf.withCString { cleanupPointer in
                Darwin.renameatx_np(
                    rootDescriptor,
                    sourcePointer,
                    rootDescriptor,
                    cleanupPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renamed == 0 else { return .refused }

        var quarantineNeedsResolution = true
        defer {
            if quarantineNeedsResolution {
                let restored = cleanupLeaf.withCString { cleanupPointer in
                    leaf.withCString { sourcePointer in
                        Darwin.renameatx_np(
                            rootDescriptor,
                            cleanupPointer,
                            rootDescriptor,
                            sourcePointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if restored != 0 {
                    persistQuarantinedPath(
                        for: directory,
                        quarantinedURL: root.appendingPathComponent(
                            cleanupLeaf,
                            isDirectory: true
                        )
                    )
                }
            }
        }

        var quarantinedStatus = stat()
        guard cleanupLeaf.withCString({
            Darwin.fstatat(rootDescriptor, $0, &quarantinedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              directory.identity.matches(quarantinedStatus) else {
            return .refused
        }

        if let removalLeaf {
            var fileStatus = stat()
            let fileStatusResult = removalLeaf.withCString {
                Darwin.fstatat(sourceDescriptor, $0, &fileStatus, AT_SYMLINK_NOFOLLOW)
            }
            if fileStatusResult == 0 {
                guard isOwnedSnapshotFile(fileStatus, directoryStatus: sourceStatus),
                      record.publishedFile?.matches(fileStatus) == true,
                      removalLeaf.withCString({
                          Darwin.unlinkat(sourceDescriptor, $0, 0)
                      }) == 0 else {
                    return .refused
                }
            } else if errno != ENOENT {
                return .refused
            }
        }

        var finalStatus = stat()
        guard cleanupLeaf.withCString({
            Darwin.fstatat(rootDescriptor, $0, &finalStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              directory.identity.matches(finalStatus) else {
            return .refused
        }
        guard cleanupLeaf.withCString({
            Darwin.unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
        }) == 0 else {
            return .refused
        }
        quarantineNeedsResolution = false
        _ = Darwin.fsync(rootDescriptor)
        pruneRegistryRecord(for: directory)
        return .removed
    }

    static func reclaimStaleSnapshots(
        registryURL: URL = defaultRegistryURL,
        currentLaunchID: UUID = processLaunchID,
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        isProcessAlive: (Int32) -> Bool = { processID in
            guard processID > 0 else { return false }
            if Darwin.kill(processID, 0) == 0 { return true }
            return errno == EPERM
        }
    ) -> ShareSnapshotReclamationReport {
        guard minimumAge >= 0,
              let records = try? readRegistry(at: registryURL) else {
            return ShareSnapshotReclamationReport()
        }
        var report = ShareSnapshotReclamationReport()
        for record in records where record.launchID != currentLaunchID {
            let age = now.timeIntervalSince1970 - record.lastActivityAt
            guard age >= minimumAge,
                  !isProcessAlive(record.ownerProcessID) else {
                continue
            }
            let directory = record.directory(registryURL: registryURL)
            switch remove(directory, expectedFileLeaf: record.expectedFileLeaf) {
            case .removed:
                report.removed += 1
            case .alreadyAbsent:
                report.alreadyAbsent += 1
            case .refused:
                report.refused += 1
            }
        }
        return report
    }

    private static func sameDirectory(_ first: stat, _ second: stat) -> Bool {
        (first.st_mode & S_IFMT) == S_IFDIR
            && (second.st_mode & S_IFMT) == S_IFDIR
            && first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_uid == second.st_uid
    }

    private static func isSafeLeaf(_ leaf: String) -> Bool {
        !leaf.isEmpty && leaf != "." && leaf != ".." && !leaf.contains("/")
    }

    private static func isOwnedSnapshotFile(
        _ fileStatus: stat,
        directoryStatus: stat
    ) -> Bool {
        (fileStatus.st_mode & S_IFMT) == S_IFREG
            && fileStatus.st_uid == getuid()
            && fileStatus.st_dev == directoryStatus.st_dev
            && fileStatus.st_nlink == 1
            && fileStatus.st_mode & mode_t(0o7777) == mode_t(0o600)
    }

    private static func directoryEntries(descriptor: Int32) -> [String]? {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return nil
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            var storage = entry.pointee.d_name
            let name = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    private static func registryRecord(
        for directory: ShareSnapshotDirectory
    ) -> ShareSnapshotLeaseRecord? {
        guard let records = try? readRegistry(at: directory.registryURL) else { return nil }
        return records.first(where: {
            $0.leaseID == directory.leaseID && $0.matches(directory)
        })
    }

    private static func pruneRegistryRecord(for directory: ShareSnapshotDirectory) {
        try? mutateRegistry(at: directory.registryURL) { records in
            // The exact record/directory binding was authenticated before any
            // filesystem mutation. Once the directory is gone, its identity
            // cannot be re-read; the unguessable lease ID is the stable journal
            // key that must be retired.
            records.removeAll(where: { $0.leaseID == directory.leaseID })
        }
    }

    private static func persistQuarantinedPath(
        for directory: ShareSnapshotDirectory,
        quarantinedURL: URL
    ) {
        try? mutateRegistry(at: directory.registryURL) { records in
            guard let index = records.firstIndex(where: {
                $0.leaseID == directory.leaseID && $0.matches(directory)
            }) else {
                return
            }
            records[index].directoryPath = quarantinedURL.standardizedFileURL.path
        }
    }

    private static func readRegistry(at registryURL: URL) throws -> [ShareSnapshotLeaseRecord] {
        try mutateRegistry(at: registryURL) { $0 }
    }

    private static func mutateRegistry<Result>(
        at requestedRegistryURL: URL,
        _ body: (inout [ShareSnapshotLeaseRecord]) throws -> Result
    ) throws -> Result {
        let registryURL = requestedRegistryURL.standardizedFileURL
        let parentURL = registryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        var parentPathStatus = stat()
        guard lstat(parentURL.path, &parentPathStatus) == 0,
              (parentPathStatus.st_mode & S_IFMT) == S_IFDIR,
              parentPathStatus.st_uid == getuid() else {
            throw ShareSnapshotStorageError.unavailable
        }
        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw ShareSnapshotStorageError.unavailable }
        defer { Darwin.close(parentDescriptor) }
        var parentDescriptorStatus = stat()
        var finalParentPathStatus = stat()
        guard fstat(parentDescriptor, &parentDescriptorStatus) == 0,
              lstat(parentURL.path, &finalParentPathStatus) == 0,
              sameDirectory(parentDescriptorStatus, finalParentPathStatus),
              parentDescriptorStatus.st_uid == getuid(),
              Darwin.fchmod(parentDescriptor, mode_t(0o700)) == 0,
              fstat(parentDescriptor, &parentDescriptorStatus) == 0,
              lstat(parentURL.path, &finalParentPathStatus) == 0,
              sameDirectory(parentDescriptorStatus, finalParentPathStatus),
              parentDescriptorStatus.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ShareSnapshotStorageError.unavailable
        }

        let registryLeaf = registryURL.lastPathComponent
        guard isSafeLeaf(registryLeaf) else { throw ShareSnapshotStorageError.unavailable }
        let lockLeaf = ".\(registryLeaf).lock"
        let lockDescriptor = lockLeaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard lockDescriptor >= 0 else { throw ShareSnapshotStorageError.unavailable }
        defer { Darwin.close(lockDescriptor) }
        guard validatePrivateRegistryFile(lockDescriptor),
              lockRegistryFile(lockDescriptor) else {
            throw ShareSnapshotStorageError.unavailable
        }
        defer { unlockRegistryFile(lockDescriptor) }

        let registryDescriptor = registryLeaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard registryDescriptor >= 0 else { throw ShareSnapshotStorageError.unavailable }
        defer { Darwin.close(registryDescriptor) }
        guard validatePrivateRegistryFile(registryDescriptor) else {
            throw ShareSnapshotStorageError.unavailable
        }

        var registryStatus = stat()
        guard fstat(registryDescriptor, &registryStatus) == 0,
              registryStatus.st_size >= 0,
              registryStatus.st_size <= maximumRegistryBytes else {
            throw ShareSnapshotStorageError.unavailable
        }
        let bytes = try readAll(
            descriptor: registryDescriptor,
            byteCount: Int(registryStatus.st_size)
        )
        var document: ShareSnapshotLeaseRegistryDocument
        if bytes.isEmpty {
            document = ShareSnapshotLeaseRegistryDocument(
                schemaVersion: registrySchemaVersion,
                records: []
            )
        } else {
            let decoder = JSONDecoder()
            guard let decoded = try? decoder.decode(
                ShareSnapshotLeaseRegistryDocument.self,
                from: bytes
            ), decoded.schemaVersion == registrySchemaVersion else {
                throw ShareSnapshotStorageError.unavailable
            }
            document = decoded
        }

        let result = try body(&document.records)
        document.records.sort { $0.leaseID.uuidString < $1.leaseID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(document)
        guard encoded.count <= maximumRegistryBytes else {
            throw ShareSnapshotStorageError.unavailable
        }
        try replaceRegistryDocument(
            encoded,
            registryLeaf: registryLeaf,
            registryDescriptor: registryDescriptor,
            parentDescriptor: parentDescriptor
        )
        return result
    }

    private static func replaceRegistryDocument(
        _ data: Data,
        registryLeaf: String,
        registryDescriptor: Int32,
        parentDescriptor: Int32
    ) throws {
        let temporaryLeaf = ".\(registryLeaf).\(UUID().uuidString).tmp"
        let temporaryDescriptor = temporaryLeaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw ShareSnapshotStorageError.unavailable
        }
        var removeTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if removeTemporary {
                temporaryLeaf.withCString {
                    _ = Darwin.unlinkat(parentDescriptor, $0, 0)
                }
            }
        }
        guard validatePrivateRegistryFile(temporaryDescriptor) else {
            throw ShareSnapshotStorageError.unavailable
        }
        try writeAll(data, descriptor: temporaryDescriptor)
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw ShareSnapshotStorageError.unavailable
        }

        var openedRegistry = stat()
        var namedRegistry = stat()
        guard fstat(registryDescriptor, &openedRegistry) == 0,
              registryLeaf.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &namedRegistry,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameRegularFile(openedRegistry, namedRegistry) else {
            throw ShareSnapshotStorageError.unavailable
        }
        let replacementResult = temporaryLeaf.withCString { temporaryPointer in
            registryLeaf.withCString { registryPointer in
                Darwin.renameat(
                    parentDescriptor,
                    temporaryPointer,
                    parentDescriptor,
                    registryPointer
                )
            }
        }
        guard replacementResult == 0 else {
            throw ShareSnapshotStorageError.unavailable
        }
        removeTemporary = false
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw ShareSnapshotStorageError.unavailable
        }
    }

    private static func validatePrivateRegistryFile(_ descriptor: Int32) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              fstat(descriptor, &status) == 0 else {
            return false
        }
        return (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == getuid()
            && status.st_nlink == 1
            && status.st_mode & mode_t(0o7777) == mode_t(0o600)
    }

    private static func sameRegularFile(_ first: stat, _ second: stat) -> Bool {
        (first.st_mode & S_IFMT) == S_IFREG
            && (second.st_mode & S_IFMT) == S_IFREG
            && first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_uid == second.st_uid
            && first.st_nlink == second.st_nlink
            && first.st_mode == second.st_mode
    }

    private static func lockRegistryFile(_ descriptor: Int32) -> Bool {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while true {
            let result = withUnsafeMutablePointer(to: &lock) {
                Darwin.fcntl(descriptor, F_OFD_SETLKW, $0)
            }
            if result == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    private static func unlockRegistryFile(_ descriptor: Int32) {
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

    private static func readAll(descriptor: Int32, byteCount: Int) throws -> Data {
        guard byteCount > 0 else { return Data() }
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ShareSnapshotStorageError.unavailable }
            offset += count
        }
        return data
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ShareSnapshotStorageError.unavailable }
            offset += count
        }
    }
}

struct PreparedShareItem: Equatable, Sendable {
    let source: AppModel.CurrentSplatPublicationSource
    let shareURL: URL
    let shareDirectory: ShareSnapshotDirectory
    let byteCount: Int64
    let outputSnapshot: ShareFileSnapshot
    let shareSnapshot: ShareFileSnapshot

    var projectURL: URL { source.projectURL }
    var outputURL: URL { source.outputURL }
    var validatedSHA256: String? { source.expectedIdentity.sha256 }
    var shareDirectoryURL: URL { shareDirectory.url }
}

private struct SharePreparationFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

extension AppModel {
    typealias ShareSnapshotPublisher = @Sendable (
        _ source: URL,
        _ destination: URL,
        _ expected: ExpectedPlyArtifactIdentity?
    ) throws -> ValidatedPlyArtifactEvidence

    func prepareCurrentSplatForSharing() async {
        await prepareCurrentSplatForSharing(
            publisher: { source, destination, expected in
                if let expected {
                    return try ProjectArtifactValidator.publishValidatedPly(
                        from: source,
                        to: destination,
                        expected: expected
                    )
                }
                return try ProjectArtifactValidator.publishValidatedPly(
                    from: source,
                    to: destination
                )
            }
        )
    }

    func prepareCurrentSplatForSharing(
        publisher: @escaping ShareSnapshotPublisher
    ) async {
        guard activeShareSession == nil else { return }
        let requestedVariant = selectedSplatOutputVariant
        let token = UUID()
        latestShareOperationID = nil
        sharePreparationToken = token
        cleanupPreparedShareItem()
        isShareReady = false
        isPreparingShare = true

        let source: CurrentSplatPublicationSource
        do {
            source = try await validatedCurrentSplatForPublication()
        } catch is CancellationError {
            clearSharePreparation(token: token)
            return
        } catch {
            let message: String
            if requestedVariant == .subject {
                message = "Subject isn’t available to share."
            } else if let projectURL = currentProjectURL {
                message = unavailableOutputMessage(
                    for: ProjectPaths(root: projectURL).outputSplatURL
                )
            } else {
                message = "Finish a project before sharing."
            }
            finishSharePreparationFailure(
                token: token,
                message: message
            )
            return
        }
        guard sharePreparationToken == token,
              selectedSplatOutputVariant == source.variant,
              ProjectSummary.hasSameLocation(
                  currentProjectURL,
                  source.projectURL
              ) else {
            clearSharePreparation(token: token)
            return
        }
        let worker = Task.detached(priority: .userInitiated) {
            try Self.makePreparedShareItem(
                source: source,
                publisher: publisher
            )
        }
        do {
            let item = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            if Task.isCancelled {
                ShareSnapshotStorage.remove(
                    item.shareDirectory,
                    expectedFileLeaf: item.shareURL.lastPathComponent
                )
                clearSharePreparation(token: token)
                return
            }
            guard sharePreparationToken == token,
                  selectedSplatOutputVariant == source.variant,
                  ProjectSummary.hasSameLocation(
                      currentProjectURL,
                      source.projectURL
                  ),
                  ProjectSummary.hasSameLocation(
                      displayedOutputURL,
                      source.outputURL
                  ) else {
                ShareSnapshotStorage.remove(
                    item.shareDirectory,
                    expectedFileLeaf: item.shareURL.lastPathComponent
                )
                clearSharePreparation(token: token)
                return
            }
            preparedShareItem = item
            sharePreparationToken = nil
            isPreparingShare = false
            isShareReady = true
            shareStatusMessage = nil
            shareStatusIsError = false
        } catch is CancellationError {
            clearSharePreparation(token: token)
            return
        } catch let failure as SharePreparationFailure {
            finishSharePreparationFailure(token: token, message: failure.message)
            return
        } catch {
            finishSharePreparationFailure(
                token: token,
                message: "Couldn’t prepare the splat for sharing. Try again."
            )
            return
        }
    }

    func requestCurrentSplatShare(
        from sourceView: NSView,
        presenter: ShareSession.Presenter? = nil
    ) {
        guard activeShareSession == nil else {
            shareStatusMessage = "Share is already open."
            shareStatusIsError = false
            return
        }
        guard !isShareSheetActive,
              !isPreparingShare,
              sharePreparationTask == nil else {
            return
        }
        // Disable Share before yielding to the task. Without this synchronous
        // transition, two quick presses can start competing validations.
        isPreparingShare = true
        let requestTask = Task { [weak self, sourceView] in
            guard let self else { return }
            guard !Task.isCancelled else {
                if self.sharePreparationTask == nil {
                    self.isPreparingShare = false
                }
                return
            }
            if self.isShareReady, self.preparedShareItem != nil {
                await self.presentPreparedShare(
                    from: sourceView,
                    presenter: presenter,
                    permitsRequestedPreparation: true
                )
            } else {
                await self.prepareCurrentSplatForSharing()
                guard !Task.isCancelled,
                      self.isShareReady,
                      self.preparedShareItem != nil else {
                    if !self.isPreparingShare {
                        self.sharePreparationTask = nil
                    }
                    return
                }
                self.presentNewlyPreparedShare(from: sourceView, presenter: presenter)
            }
            guard !Task.isCancelled else {
                if !self.isPreparingShare {
                    self.sharePreparationTask = nil
                }
                return
            }
            self.sharePreparationTask = nil
        }
        sharePreparationTask = requestTask
    }

    private func presentNewlyPreparedShare(
        from sourceView: NSView,
        presenter: ShareSession.Presenter?
    ) {
        guard activeShareSession == nil,
              !isShareSheetActive,
              let preparedShareItem,
              let projectURL = currentProjectURL,
              selectedSplatOutputVariant == preparedShareItem.source.variant,
              ProjectSummary.hasSameLocation(projectURL, preparedShareItem.projectURL),
              ProjectSummary.hasSameLocation(
                  displayedOutputURL,
                  preparedShareItem.outputURL
              ) else {
            invalidatePreparedShareItem(
                message: sharePresentationFailureMessage(
                    for: preparedShareItem?.source.variant
                )
            )
            return
        }

        let session = makeShareSession(
            preparedItem: preparedShareItem,
            presenter: presenter
        )
        activeShareSession = session
        isShareSheetActive = true
        shareStatusMessage = nil
        shareStatusIsError = false
        session.present(items: [preparedShareItem.shareURL], from: sourceView)
    }

    func presentPreparedShare(
        from sourceView: NSView,
        presenter: ShareSession.Presenter? = nil
    ) async {
        await presentPreparedShare(
            from: sourceView,
            presenter: presenter,
            permitsRequestedPreparation: false
        )
    }

    private func presentPreparedShare(
        from sourceView: NSView,
        presenter: ShareSession.Presenter?,
        permitsRequestedPreparation: Bool
    ) async {
        guard activeShareSession == nil else {
            shareStatusMessage = "Share is already open."
            shareStatusIsError = false
            return
        }
        guard !isShareSheetActive,
              permitsRequestedPreparation || !isPreparingShare,
              let preparedItem = preparedShareItem,
              let projectURL = currentProjectURL,
              let displayedOutputURL,
              selectedSplatOutputVariant == preparedItem.source.variant,
              ProjectSummary.hasSameLocation(projectURL, preparedItem.projectURL),
              ProjectSummary.hasSameLocation(displayedOutputURL, preparedItem.outputURL) else {
            invalidatePreparedShareItem(
                message: sharePresentationFailureMessage(
                    for: preparedShareItem?.source.variant
                )
            )
            return
        }
        let token = UUID()
        sharePreparationToken = token
        isPreparingShare = true
        let resolver = publishedResultResolver
        let subjectLoader = subjectIsolationArtifactLoader
        let validation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.isPreparedShareItemCurrent(
                preparedItem,
                resolver: resolver,
                subjectLoader: subjectLoader
            )
        }
        let isCurrent: Bool
        do {
            isCurrent = try await withTaskCancellationHandler {
                try await validation.value
            } onCancel: {
                validation.cancel()
            }
        } catch {
            clearSharePreparation(token: token)
            return
        }
        guard !Task.isCancelled else {
            clearSharePreparation(token: token)
            return
        }
        guard sharePreparationToken == token else { return }
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL),
              selectedSplatOutputVariant == preparedItem.source.variant,
              ProjectSummary.hasSameLocation(
                  self.displayedOutputURL,
                  displayedOutputURL
              ),
              preparedShareItem == preparedItem,
              isCurrent else {
            invalidatePreparedShareItem(
                message: sharePresentationFailureMessage(
                    for: preparedItem.source.variant
                )
            )
            return
        }
        sharePreparationToken = nil
        isPreparingShare = false

        let session = makeShareSession(
            preparedItem: preparedItem,
            presenter: presenter
        )
        activeShareSession = session
        isShareSheetActive = true
        shareStatusMessage = nil
        shareStatusIsError = false
        session.present(items: [preparedItem.shareURL], from: sourceView)
    }

    private func makeShareSession(
        preparedItem: PreparedShareItem,
        presenter: ShareSession.Presenter?
    ) -> ShareSession {
        if let presenter {
            return ShareSession(
                model: self,
                preparedItem: preparedItem,
                presenter: presenter
            )
        }
        return ShareSession(model: self, preparedItem: preparedItem)
    }

    @discardableResult
    func shareDidStart(from session: ShareSession) -> Bool {
        guard activeShareSession === session,
              let selectedItem = session.preparedItem,
              preparedShareItem == selectedItem else {
            return false
        }
        self.preparedShareItem = nil
        activeShareSession = nil
        inFlightShareSessions[session.id] = session
        latestShareOperationID = session.id
        isShareSheetActive = false
        isShareReady = false
        shareStatusMessage = "Sharing…"
        shareStatusIsError = false
        return true
    }

    func shareDidComplete(from session: ShareSession) {
        guard let registered = inFlightShareSessions[session.id],
              registered === session else {
            return
        }
        inFlightShareSessions[session.id] = nil
        session.releasePreparedSnapshot()
        guard latestShareOperationID == session.id else { return }
        latestShareOperationID = nil
        guard let preparedItem = session.preparedItem,
              ProjectSummary.hasSameLocation(
                  currentProjectURL,
                  preparedItem.projectURL
              ) else {
            return
        }
        shareStatusMessage = "Shared."
        shareStatusIsError = false
    }

    func shareDidFail(from session: ShareSession) {
        guard let registered = inFlightShareSessions[session.id],
              registered === session else {
            return
        }
        inFlightShareSessions[session.id] = nil
        session.releasePreparedSnapshot()
        guard latestShareOperationID == session.id else { return }
        latestShareOperationID = nil
        guard let preparedItem = session.preparedItem,
              ProjectSummary.hasSameLocation(
                  currentProjectURL,
                  preparedItem.projectURL
              ) else {
            return
        }
        shareStatusMessage = "Couldn’t share the file. Try again."
        shareStatusIsError = true
    }

    func shareDidCancel(from session: ShareSession) {
        guard activeShareSession === session else { return }
        shareStatusMessage = nil
        shareStatusIsError = false
    }

    func clearShareSession(_ session: ShareSession) {
        guard activeShareSession === session else { return }
        session.finish()
        activeShareSession = nil
        isShareSheetActive = false
        // Keep the validated snapshot reusable. Reset and cancelSharing own its cleanup.
    }

    func cancelSharing() {
        sharePreparationTask?.cancel()
        sharePreparationTask = nil
        sharePreparationToken = nil
        isPreparingShare = false
        let session = activeShareSession
        _ = session?.close()
        activeShareSession = nil
        latestShareOperationID = nil
        isShareSheetActive = false
        cleanupPreparedShareItem()
        isShareReady = false
    }

    private nonisolated static func isPreparedShareItemCurrent(
        _ preparedItem: PreparedShareItem,
        resolver: PublishedResultResolverOperation,
        subjectLoader: SubjectIsolationArtifactLoader
    ) throws -> Bool {
        let resolvedResult = try resolver(preparedItem.projectURL)
        let currentOutputURL: URL
        let verifiedOutputSHA256: String
        switch preparedItem.source.variant {
        case .original:
            let resolvedOutputURL: URL
            let identity: ExpectedPlyArtifactIdentity
            let publicationID: UUID?
            switch resolvedResult {
            case .current(.receiptBound(let current)):
                resolvedOutputURL = current.publishedResult.outputURL
                identity = expectedPlyIdentity(
                    from: current.publishedResult.outputEvidence
                )
                publicationID = current.publishedResult.receipt.publicationID
            case .current(.legacy(let legacy)):
                guard let legacyIdentity = expectedPlyIdentity(
                    from: legacy.snapshot.trainingArtifact
                ) else {
                    return false
                }
                resolvedOutputURL = legacy.outputURL
                identity = legacyIdentity
                publicationID = nil
            case .previous(let previous):
                resolvedOutputURL = previous.publishedResult.outputURL
                identity = expectedPlyIdentity(
                    from: previous.publishedResult.outputEvidence
                )
                publicationID = previous.publishedResult.receipt.publicationID
            case .unavailable:
                return false
            }
            guard publicationID == preparedItem.source.publicationID,
                  identity == preparedItem.source.expectedIdentity,
                  ProjectSummary.hasSameLocation(
                    resolvedOutputURL,
                    preparedItem.outputURL
                  ) else {
                return false
            }
            currentOutputURL = resolvedOutputURL
            verifiedOutputSHA256 = identity.sha256

        case .subject:
            let currentPublicationID: UUID?
            switch resolvedResult {
            case .current(.receiptBound(let current)):
                currentPublicationID = current.publishedResult.receipt.publicationID
            case .current(.legacy):
                currentPublicationID = nil
            case .previous(let previous):
                currentPublicationID = previous.publishedResult.receipt.publicationID
            case .unavailable:
                return false
            }
            guard currentPublicationID == preparedItem.source.publicationID,
                  case .valid(let artifact, let output) = subjectLoader(
                ProjectPaths(root: preparedItem.projectURL)
            ),
            currentPublicationID == nil
                || artifact.sourcePublicationID == currentPublicationID,
            output.variant == .subject,
            ProjectSummary.hasSameLocation(
                output.url,
                preparedItem.outputURL
            ),
            expectedPlyIdentity(from: output)
                == preparedItem.source.expectedIdentity else {
                return false
            }
            currentOutputURL = output.url
            verifiedOutputSHA256 = output.sha256
        }

        guard ShareFileSnapshot.captureIdentity(
            at: currentOutputURL,
            verifiedSHA256: verifiedOutputSHA256
        ) == preparedItem.outputSnapshot,
        try ShareFileSnapshot.capture(
            at: preparedItem.shareURL,
            shouldCancel: { Task.isCancelled }
        ) == preparedItem.shareSnapshot else {
            return false
        }
        return true
    }

    private func unavailableOutputMessage(for expectedURL: URL) -> String {
        let outputState = outputFileState(at: expectedURL)
        if outputState.exists {
            return "Could not open \(expectedURL.lastPathComponent). Rebuild or reopen the project."
        }
        return "Could not find \(expectedURL.lastPathComponent). Rebuild or reopen the project."
    }

    private func invalidatePreparedShareItem(message: String) {
        cleanupPreparedShareItem()
        sharePreparationToken = nil
        isPreparingShare = false
        isShareReady = false
        shareStatusMessage = message
        shareStatusIsError = true
    }

    private func finishSharePreparationFailure(token: UUID, message: String) {
        guard sharePreparationToken == token else { return }
        invalidatePreparedShareItem(message: message)
    }

    private func clearSharePreparation(token: UUID) {
        guard sharePreparationToken == token else { return }
        sharePreparationToken = nil
        isPreparingShare = false
        cleanupPreparedShareItem()
        isShareReady = false
    }

    private func cleanupPreparedShareItem() {
        if let preparedShareItem {
            ShareSnapshotStorage.remove(
                preparedShareItem.shareDirectory,
                expectedFileLeaf: preparedShareItem.shareURL.lastPathComponent
            )
        }
        preparedShareItem = nil
        isShareReady = false
    }

    private nonisolated static func makePreparedShareItem(
        source: CurrentSplatPublicationSource,
        publisher: ShareSnapshotPublisher
    ) throws -> PreparedShareItem {
        try Task.checkCancellation()
        var createdShareDirectory: ShareSnapshotDirectory?
        var expectedShareLeaf: String?
        do {
            let shareDirectory = try ShareSnapshotStorage.create()
            createdShareDirectory = shareDirectory
            let shareURL = shareDirectory.url.appendingPathComponent(
                source.defaultFilename,
                isDirectory: false
            )
            expectedShareLeaf = shareURL.lastPathComponent
            try ShareSnapshotStorage.prepareForPublication(
                shareDirectory,
                expectedFileLeaf: shareURL.lastPathComponent
            )
            let evidence = try publisher(
                source.outputURL,
                shareURL,
                source.expectedIdentity
            )
            guard evidence.byteCount <= UInt64(Int64.max),
                  let outputSnapshot = ShareFileSnapshot.captureIdentity(
                      at: source.outputURL,
                      verifiedSHA256: evidence.sha256
                  ),
                  let capturedShareSnapshot = ShareFileSnapshot.captureIdentity(
                      at: shareURL,
                      verifiedSHA256: evidence.sha256
                  ),
                  outputSnapshot.byteCount == Int64(evidence.byteCount),
                  capturedShareSnapshot.byteCount == Int64(evidence.byteCount) else {
                throw CurrentSplatExportError.noFinishedOutput
            }
            try ShareSnapshotStorage.recordPublishedFile(
                shareDirectory,
                snapshot: capturedShareSnapshot
            )
            try Task.checkCancellation()
            return PreparedShareItem(
                source: source,
                shareURL: shareURL.standardizedFileURL,
                shareDirectory: shareDirectory,
                byteCount: Int64(evidence.byteCount),
                outputSnapshot: outputSnapshot,
                shareSnapshot: capturedShareSnapshot
            )
        } catch is CancellationError {
            if let createdShareDirectory {
                ShareSnapshotStorage.remove(
                    createdShareDirectory,
                    expectedFileLeaf: expectedShareLeaf
                )
            }
            throw CancellationError()
        } catch {
            if let createdShareDirectory {
                ShareSnapshotStorage.remove(
                    createdShareDirectory,
                    expectedFileLeaf: expectedShareLeaf
                )
            }
            throw SharePreparationFailure(
                message: "Couldn’t prepare the splat for sharing. Try again."
            )
        }
    }

    private nonisolated static func shareUnavailableOutputMessage(for expectedURL: URL) -> String {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: expectedURL.path,
            isDirectory: &isDirectory
        )
        if exists {
            return "Could not open \(expectedURL.lastPathComponent). Rebuild or reopen the project."
        }
        return "Could not find \(expectedURL.lastPathComponent). Rebuild or reopen the project."
    }

    private func sharePresentationFailureMessage(
        for variant: SplatOutputVariant?
    ) -> String {
        if variant == .subject {
            return "Could not open the validated Subject splat. Try again."
        }
        return "Could not open the validated splat. Reopen the project and try again."
    }

}

@MainActor
final class ShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private enum ServiceState: Equatable {
        case awaitingSelection
        case serviceInFlight
        case terminal
    }

    typealias Presenter = (
        NSSharingServicePicker,
        NSRect,
        NSView,
        NSRectEdge
    ) -> Void
    typealias SnapshotRemover = (PreparedShareItem) -> Void

    private weak var model: AppModel?
    private weak var anchorView: NSView?
    private var picker: NSSharingServicePicker?
    private var isPickerClosed = false
    private var serviceState: ServiceState = .awaitingSelection
    private var selectedService: NSSharingService?
    private let presenter: Presenter
    private let snapshotRemover: SnapshotRemover
    private var didReleasePreparedSnapshot = false

    let id: UUID
    let preparedItem: PreparedShareItem?

    var isServiceInFlight: Bool {
        serviceState == .serviceInFlight
    }

    init(
        model: AppModel,
        preparedItem: PreparedShareItem? = nil,
        id: UUID = UUID(),
        presenter: @escaping Presenter = { picker, rect, view, edge in
            picker.show(relativeTo: rect, of: view, preferredEdge: edge)
        },
        snapshotRemover: @escaping SnapshotRemover = { preparedItem in
            ShareSnapshotStorage.remove(
                preparedItem.shareDirectory,
                expectedFileLeaf: preparedItem.shareURL.lastPathComponent
            )
        }
    ) {
        self.model = model
        self.preparedItem = preparedItem
        self.id = id
        self.presenter = presenter
        self.snapshotRemover = snapshotRemover
    }

    func present(items: [Any], from sourceView: NSView) {
        guard !isPickerClosed,
              serviceState == .awaitingSelection,
              picker == nil else {
            return
        }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        anchorView = sourceView
        presenter(picker, sourceView.bounds, sourceView, .minY)
    }

    @discardableResult
    func close() -> Bool {
        guard !isPickerClosed else { return false }
        isPickerClosed = true
        picker?.delegate = nil
        picker?.close()
        picker = nil
        if serviceState == .awaitingSelection {
            serviceState = .terminal
            anchorView = nil
        }
        return true
    }

    func finish() {
        guard serviceState != .serviceInFlight else { return }
        serviceState = .terminal
        isPickerClosed = true
        picker?.delegate = nil
        picker = nil
        anchorView = nil
        selectedService?.delegate = nil
        selectedService = nil
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        guard serviceState == .awaitingSelection,
              preparedItem != nil else {
            return nil
        }
        return self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        guard serviceState == .awaitingSelection else { return }
        guard let service else {
            serviceState = .terminal
            model?.shareDidCancel(from: self)
            model?.clearShareSession(self)
            return
        }
        guard preparedItem != nil else {
            serviceState = .terminal
            model?.shareDidCancel(from: self)
            model?.clearShareSession(self)
            return
        }
        serviceState = .serviceInFlight
        selectedService = service
        service.delegate = self
        guard model?.shareDidStart(from: self) == true else {
            service.delegate = nil
            selectedService = nil
            serviceState = .terminal
            model?.clearShareSession(self)
            return
        }
        isPickerClosed = true
        picker?.delegate = nil
        picker = nil
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard beginTerminalCallback(from: sharingService) else { return }
        model?.shareDidComplete(from: self)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        guard beginTerminalCallback(from: sharingService) else { return }
        model?.shareDidFail(from: self)
    }

    private func beginTerminalCallback(from sharingService: NSSharingService) -> Bool {
        guard serviceState == .serviceInFlight,
              selectedService === sharingService else {
            return false
        }
        serviceState = .terminal
        selectedService?.delegate = nil
        selectedService = nil
        picker?.delegate = nil
        picker = nil
        anchorView = nil
        return true
    }

    func releasePreparedSnapshot() {
        guard serviceState == .terminal,
              !didReleasePreparedSnapshot,
              let preparedItem else {
            return
        }
        didReleasePreparedSnapshot = true
        snapshotRemover(preparedItem)
    }

    func anchoringView(
        for sharingService: NSSharingService,
        showRelativeTo positioningRect: UnsafeMutablePointer<NSRect>,
        preferredEdge: UnsafeMutablePointer<NSRectEdge>
    ) -> NSView? {
        guard let anchorView else { return nil }
        positioningRect.pointee = anchorView.bounds
        preferredEdge.pointee = .minY
        return anchorView
    }
}
