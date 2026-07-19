import Darwin
import Foundation

enum PhotoStagingCleanup {
    private static let containerLeaf = ".easysplat-photo-input-staging"
    private static let staleInterval: TimeInterval = 24 * 60 * 60
    private static let maximumRemovals = 4
    private static let maximumRunEntries = 10_002

    static func cleanupStaleRuns(
        in container: URL,
        now: Date = Date(),
        beforeQuarantine: ((URL) throws -> Void)? = nil
    ) throws {
        guard container.isFileURL,
              container.lastPathComponent == containerLeaf else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        var pathStatus = stat()
        guard lstat(container.path, &pathStatus) == 0 else { throw currentPOSIXError() }
        let containerDescriptor = Darwin.open(
            container.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard containerDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(containerDescriptor) }

        var descriptorStatus = stat()
        guard fstat(containerDescriptor, &descriptorStatus) == 0 else {
            throw currentPOSIXError()
        }
        let containerEvidence = Evidence(pathStatus)
        guard containerEvidence.isPrivateDirectory,
              containerEvidence.matchesStableDirectory(descriptorStatus) else {
            throw CocoaError(.fileReadNoPermission)
        }

        let cutoff = now.addingTimeInterval(-staleInterval)
        let leaves = try directoryLeaves(
            descriptor: containerDescriptor,
            maximumCount: maximumRunEntries * 2
        )
        var removed = 0
        for leaf in leaves where removed < maximumRemovals {
            guard isCanonicalRunLeaf(leaf) else { continue }
            do {
                let candidate = container.appendingPathComponent(leaf, isDirectory: true)
                if try removeIfStaleControlledRun(
                    leaf: leaf,
                    candidate: candidate,
                    containerDescriptor: containerDescriptor,
                    containerEvidence: containerEvidence,
                    cutoff: cutoff,
                    beforeQuarantine: beforeQuarantine
                ) {
                    removed += 1
                }
            } catch {
                // Cleanup is opportunistic. Any ambiguity preserves the candidate.
                continue
            }
        }
    }

    private static func removeIfStaleControlledRun(
        leaf: String,
        candidate: URL,
        containerDescriptor: Int32,
        containerEvidence: Evidence,
        cutoff: Date,
        beforeQuarantine: ((URL) throws -> Void)?
    ) throws -> Bool {
        var namedStatus = stat()
        guard leaf.withCString({
            fstatat(containerDescriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0 else { throw currentPOSIXError() }
        let rootEvidence = Evidence(namedStatus)
        guard rootEvidence.isPrivateDirectory,
              rootEvidence.device == containerEvidence.device,
              rootEvidence.modifiedAt < cutoff else {
            return false
        }

        let rootDescriptor = leaf.withCString {
            openat(
                containerDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard rootDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(rootDescriptor) }
        var openedStatus = stat()
        guard fstat(rootDescriptor, &openedStatus) == 0,
              rootEvidence.matchesStableDirectory(openedStatus) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let childLeaves = try directoryLeaves(
            descriptor: rootDescriptor,
            maximumCount: maximumRunEntries
        )
        var childEvidence: [String: Evidence] = [:]
        childEvidence.reserveCapacity(childLeaves.count)
        for childLeaf in childLeaves {
            guard isControlledPhotoLeaf(childLeaf) else { return false }
            var childStatus = stat()
            guard childLeaf.withCString({
                fstatat(rootDescriptor, $0, &childStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0 else { throw currentPOSIXError() }
            let evidence = Evidence(childStatus)
            guard evidence.isPrivateRegularFile,
                  evidence.device == rootEvidence.device,
                  evidence.modifiedAt < cutoff else {
                return false
            }
            childEvidence[childLeaf] = evidence
        }

        try beforeQuarantine?(candidate)
        guard let quarantineLeaf = try quarantine(
            leaf: leaf,
            containerDescriptor: containerDescriptor,
            rootEvidence: rootEvidence
        ) else {
            return false
        }

        for childLeaf in childLeaves {
            guard let expected = childEvidence[childLeaf] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var current = stat()
            guard childLeaf.withCString({
                fstatat(rootDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  expected.matchesRegularFile(current) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard childLeaf.withCString({ unlinkat(rootDescriptor, $0, 0) }) == 0 else {
                throw currentPOSIXError()
            }
        }

        guard try directoryLeaves(descriptor: rootDescriptor, maximumCount: 1).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var reboundRoot = stat()
        guard quarantineLeaf.withCString({
            fstatat(containerDescriptor, $0, &reboundRoot, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              rootEvidence.matchesDirectoryIdentity(reboundRoot),
              fstat(rootDescriptor, &openedStatus) == 0,
              rootEvidence.matchesDirectoryIdentity(openedStatus),
              reboundRoot.st_nlink == openedStatus.st_nlink,
              quarantineLeaf.withCString({
                  unlinkat(containerDescriptor, $0, AT_REMOVEDIR)
              }) == 0,
              fsync(containerDescriptor) == 0 else {
            throw currentPOSIXError()
        }
        return true
    }

    private static func quarantine(
        leaf: String,
        containerDescriptor: Int32,
        rootEvidence: Evidence
    ) throws -> String? {
        for _ in 0..<8 {
            let quarantineLeaf = "run-\(UUID().uuidString)"
            let result = leaf.withCString { source in
                quarantineLeaf.withCString { destination in
                    renameatx_np(
                        containerDescriptor,
                        source,
                        containerDescriptor,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            if result != 0 {
                if errno == EEXIST { continue }
                throw currentPOSIXError()
            }

            var rebound = stat()
            let matches = quarantineLeaf.withCString {
                fstatat(containerDescriptor, $0, &rebound, AT_SYMLINK_NOFOLLOW)
            } == 0 && rootEvidence.matchesStableDirectory(rebound)
            if matches { return quarantineLeaf }

            _ = quarantineLeaf.withCString { source in
                leaf.withCString { destination in
                    renameatx_np(
                        containerDescriptor,
                        source,
                        containerDescriptor,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            return nil
        }
        return nil
    }

    private static func directoryLeaves(
        descriptor: Int32,
        maximumCount: Int
    ) throws -> [String] {
        let enumerationDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard enumerationDescriptor >= 0,
              let stream = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
            throw currentPOSIXError()
        }
        defer { closedir(stream) }
        var leaves: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                guard leaves.count < maximumCount else {
                    throw CocoaError(.fileReadTooLarge)
                }
                leaves.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw currentPOSIXError() }
        return leaves.sorted()
    }

    private static func isCanonicalRunLeaf(_ leaf: String) -> Bool {
        guard leaf.utf8.count == 40,
              leaf.hasPrefix("run-"),
              leaf.unicodeScalars.allSatisfy({ $0.isASCII }),
              let uuid = UUID(uuidString: String(leaf.dropFirst(4))) else {
            return false
        }
        return leaf == "run-\(uuid.uuidString)"
    }

    private static func isControlledPhotoLeaf(_ leaf: String) -> Bool {
        if leaf.hasPrefix("photo-"), leaf.utf8.count == 14 {
            let bytes = Array(leaf.utf8)
            guard bytes[10] == 46,
                  bytes[6..<10].allSatisfy({ (48...57).contains($0) }) else {
                return false
            }
            return ["jpg", "png"].contains(String(decoding: bytes[11...], as: UTF8.self))
        }
        if leaf.hasPrefix("photo-"), leaf.utf8.count == 15 {
            let bytes = Array(leaf.utf8)
            guard bytes[10] == 46,
                  bytes[6..<10].allSatisfy({ (48...57).contains($0) }) else {
                return false
            }
            return ["heic", "heif"].contains(String(decoding: bytes[11...], as: UTF8.self))
        }
        for prefix in [".raw-analysis-", ".raw-development-"] where leaf.hasPrefix(prefix) {
            let suffix = String(leaf.dropFirst(prefix.count))
            guard suffix.utf8.count == 36,
                  suffix.unicodeScalars.allSatisfy({ $0.isASCII }),
                  let uuid = UUID(uuidString: suffix) else {
                return false
            }
            return suffix == uuid.uuidString.lowercased()
        }
        return false
    }

    private struct Evidence {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t
        let linkCount: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            owner = status.st_uid
            mode = status.st_mode
            linkCount = status.st_nlink
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
        }

        var modifiedAt: Date {
            Date(timeIntervalSince1970:
                TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1_000_000_000
            )
        }

        var isPrivateDirectory: Bool {
            (mode & S_IFMT) == S_IFDIR
                && owner == getuid()
                && linkCount >= 1
                && mode & mode_t(0o7777) == mode_t(0o700)
        }

        var isPrivateRegularFile: Bool {
            (mode & S_IFMT) == S_IFREG
                && owner == getuid()
                && linkCount == 1
                && mode & mode_t(0o7777) == mode_t(0o600)
        }

        func matchesStableDirectory(_ status: stat) -> Bool {
            isPrivateDirectory
                && (status.st_mode & S_IFMT) == S_IFDIR
                && status.st_dev == device
                && status.st_ino == inode
                && status.st_uid == owner
                && status.st_nlink == linkCount
                && status.st_mode & mode_t(0o7777) == mode_t(0o700)
        }

        func matchesDirectoryIdentity(_ status: stat) -> Bool {
            isPrivateDirectory
                && (status.st_mode & S_IFMT) == S_IFDIR
                && status.st_dev == device
                && status.st_ino == inode
                && status.st_uid == owner
                && status.st_nlink >= 1
                && status.st_mode & mode_t(0o7777) == mode_t(0o700)
        }

        func matchesRegularFile(_ status: stat) -> Bool {
            isPrivateRegularFile
                && (status.st_mode & S_IFMT) == S_IFREG
                && status.st_dev == device
                && status.st_ino == inode
                && status.st_uid == owner
                && status.st_nlink == linkCount
                && status.st_size == size
                && status.st_mode & mode_t(0o7777) == mode_t(0o600)
                && status.st_mtimespec.tv_sec == modifiedSeconds
                && status.st_mtimespec.tv_nsec == modifiedNanoseconds
        }
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
