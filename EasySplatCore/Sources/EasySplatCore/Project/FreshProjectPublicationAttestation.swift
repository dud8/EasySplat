import CryptoKit
import Darwin
import Foundation

public enum FreshProjectPublicationAttestationError: Error, Equatable, Sendable {
    case alreadyConsumed
    case discarded
    case projectURLMismatch
    case projectIdentityChanged
    case metadataChanged
    case receiptChanged
    case filesystemChanged
}

public struct FreshProjectPublication {
    public let projectURL: URL
    public let attestation: FreshProjectPublicationAttestation
}

/// A process-local, one-shot capability proving that a newly published project is
/// still the exact bundle whose input receipts were authenticated while hidden.
///
/// This type deliberately has no public initializer, Codable conformance, or
/// Sendable conformance. Only `ProjectPublicationTransaction` can mint one.
public final class FreshProjectPublicationAttestation {
    struct BundleIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let permissions: UInt16

        func matches(_ status: stat) -> Bool {
            status.st_mode & S_IFMT == S_IFDIR
                && UInt64(status.st_dev) == device
                && UInt64(status.st_ino) == inode
                && status.st_uid == owner
                && UInt16(status.st_mode & mode_t(0o7777)) == permissions
        }
    }

    struct ManifestEntry {
        let relativePath: String
        let isDirectory: Bool
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

        func matches(_ status: stat) -> Bool {
            let expectedType: mode_t = isDirectory ? S_IFDIR : S_IFREG
            let identityMatches = status.st_mode & S_IFMT == expectedType
                && UInt64(status.st_dev) == device
                && UInt64(status.st_ino) == inode
                && status.st_uid == owner
                && UInt16(status.st_mode & mode_t(0o7777)) == permissions
                && UInt16(clamping: status.st_nlink) == linkCount
            guard identityMatches else { return false }
            if isDirectory { return true }
            return Int64(status.st_size) == byteCount
                && Int64(status.st_mtimespec.tv_sec) == modifiedSeconds
                && Int64(status.st_mtimespec.tv_nsec) == modifiedNanoseconds
                && Int64(status.st_ctimespec.tv_sec) == changedSeconds
                && Int64(status.st_ctimespec.tv_nsec) == changedNanoseconds
        }
    }

    private enum State: Equatable {
        case prepared
        case published
        case consuming
        case consumed
        case discarded
    }

    private let lock = NSLock()
    private var expectedProjectURL: URL?
    private var expectedProjectPath: String?
    private let expectedBundle: BundleIdentity
    private let expectedMetadataSHA256: String
    private let expectedReceiptDigest: String
    private let expectedManifest: [ManifestEntry]
    private var baseDescriptor: Int32
    private var bundleDescriptor: Int32
    private var prePublicationMonitor: VnodeMutationMonitor?
    private var prePublicationRootMonitor: VnodeMutationMonitor?
    private var publishedMonitor: VnodeMutationMonitor?
    private var preConsumptionRootMonitor: VnodeMutationMonitor?
    private var state: State = .prepared

    init(
        baseDescriptor: Int32,
        bundleDescriptor: Int32,
        expectedBundle: BundleIdentity,
        metadataSHA256: String,
        receiptDigest: String,
        manifest: [ManifestEntry],
        consumeVideoIntegrityHandoff: (() throws -> Void)?
    ) throws {
        let heldBase = try Self.duplicate(baseDescriptor)
        var heldBundle: Int32 = -1
        var armedPrePublicationMonitor: VnodeMutationMonitor?
        var armedPrePublicationRootMonitor: VnodeMutationMonitor?
        do {
            heldBundle = try Self.duplicate(bundleDescriptor)
            let fileWatches = try Self.makeWatches(
                rootDescriptor: heldBundle,
                entries: manifest.filter { !$0.isDirectory }
            )
            defer { fileWatches.forEach { Darwin.close($0.descriptor) } }
            armedPrePublicationMonitor = try VnodeMutationMonitor(watches: fileWatches.map {
                .init(descriptor: $0.descriptor, label: $0.label, ownership: .duplicated)
            })
            armedPrePublicationRootMonitor = try VnodeMutationMonitor(watches: [
                .init(
                    descriptor: heldBundle,
                    label: "project-root-before-publication",
                    ownership: .duplicated
                ),
            ])
            try consumeVideoIntegrityHandoff?()
            guard armedPrePublicationMonitor?.poll().isTrustworthy == true,
                  armedPrePublicationRootMonitor?.poll().isTrustworthy == true else {
                throw FreshProjectPublicationAttestationError.filesystemChanged
            }
        } catch {
            armedPrePublicationMonitor?.close()
            armedPrePublicationRootMonitor?.close()
            Darwin.close(heldBase)
            if heldBundle >= 0 { Darwin.close(heldBundle) }
            throw error
        }
        expectedProjectURL = nil
        expectedProjectPath = nil
        self.expectedBundle = expectedBundle
        expectedMetadataSHA256 = metadataSHA256
        expectedReceiptDigest = receiptDigest
        expectedManifest = manifest
        self.baseDescriptor = heldBase
        self.bundleDescriptor = heldBundle
        prePublicationMonitor = armedPrePublicationMonitor
        prePublicationRootMonitor = armedPrePublicationRootMonitor
    }

    deinit {
        closeEvidence()
    }

    func publicationDidComplete(projectURL: URL) throws {
        try lock.withLock {
            guard state == .prepared else {
                throw FreshProjectPublicationAttestationError.discarded
            }
            do {
                expectedProjectURL = projectURL.standardizedFileURL
                expectedProjectPath = projectURL.path
                let publishedWatches = try Self.makeWatches(
                    rootDescriptor: bundleDescriptor,
                    entries: expectedManifest.filter {
                        $0.relativePath != "." && $0.relativePath != "project.json"
                    }
                )
                defer { publishedWatches.forEach { Darwin.close($0.descriptor) } }
                var watches = publishedWatches.map {
                    VnodeMutationMonitor.Watch(
                        descriptor: $0.descriptor,
                        label: $0.label,
                        ownership: .duplicated
                    )
                }
                watches.append(.init(
                    descriptor: baseDescriptor,
                    label: "project-library",
                    ownership: .duplicated
                ))
                publishedMonitor = try VnodeMutationMonitor(watches: watches)
                preConsumptionRootMonitor = try VnodeMutationMonitor(watches: [
                    .init(
                        descriptor: bundleDescriptor,
                        label: "project-root-before-consumption",
                        ownership: .duplicated
                    ),
                ])

                // Successor monitors are armed before the predecessor is polled or
                // closed. The old generation still covers every manifest file while
                // the new generation gains stable-path root and library coverage.
                // There is therefore no interval represented only by a later stat or
                // hash comparison.
                for watch in publishedWatches {
                    if fsync(watch.descriptor) != 0, errno != EINVAL, errno != EBADF {
                        throw FreshProjectPublicationAttestationError.filesystemChanged
                    }
                }
                let prePublicationSnapshot = prePublicationMonitor?.poll()
                let prePublicationRootSnapshot = prePublicationRootMonitor?.poll()
                guard prePublicationSnapshot?.failure == nil,
                      prePublicationSnapshot?.mutations.allSatisfy({
                        $0.flags == [.rename]
                      }) == true,
                      prePublicationRootSnapshot?.failure == nil,
                      prePublicationRootSnapshot?.mutations.count == 1,
                      prePublicationRootSnapshot?.mutations.first?.flags == [.rename] else {
                    throw FreshProjectPublicationAttestationError.filesystemChanged
                }
                // The authenticated transaction rename reports NOTE_RENAME on the
                // predecessor's descendant descriptors. Once the successor is live,
                // only that expected event may cross the generation boundary.
                prePublicationMonitor?.close()
                prePublicationMonitor = nil
                prePublicationRootMonitor?.close()
                prePublicationRootMonitor = nil
                try validatePublishedPathAndManifest(requiresExactTree: true)
                state = .published
            } catch {
                state = .discarded
                closeEvidence()
                throw error
            }
        }
    }

    /// Burns the one-shot capability before checking any caller-controlled value.
    /// Pipeline startup must call `completeConsumption()` after the runtime input
    /// lease has sealed its own content-hashed copy.
    func consume(projectURL: URL, metadata: ProjectMetadata) throws {
        try lock.withLock {
            switch state {
            case .consuming, .consumed:
                throw FreshProjectPublicationAttestationError.alreadyConsumed
            case .discarded:
                throw FreshProjectPublicationAttestationError.discarded
            case .prepared:
                state = .discarded
                closeEvidence()
                throw FreshProjectPublicationAttestationError.discarded
            case .published:
                state = .consuming
            }
            do {
                guard let expectedProjectPath,
                      projectURL.path == expectedProjectPath else {
                    throw FreshProjectPublicationAttestationError.projectURLMismatch
                }
                guard ProjectPublicationTransaction.receiptDigestForFreshAttestation(metadata)
                        == expectedReceiptDigest else {
                    throw FreshProjectPublicationAttestationError.receiptChanged
                }
                try validatePublishedPathAndManifest(requiresExactTree: true)
                try validateMetadataBytes()
                let publishedSnapshot = publishedMonitor?.poll()
                let rootSnapshot = preConsumptionRootMonitor?.poll()
                guard prePublicationMonitor == nil,
                      publishedSnapshot.map(publishedSnapshotIsTrustworthy) == true,
                      rootSnapshot?.isTrustworthy == true else {
                    throw FreshProjectPublicationAttestationError.filesystemChanged
                }
                preConsumptionRootMonitor?.close()
                preConsumptionRootMonitor = nil
            } catch {
                state = .consumed
                closeEvidence()
                throw error
            }
        }
    }

    func completeConsumption() throws {
        try lock.withLock {
            guard state == .consuming else {
                throw state == .discarded
                    ? FreshProjectPublicationAttestationError.discarded
                    : FreshProjectPublicationAttestationError.alreadyConsumed
            }
            defer {
                state = .consumed
                closeEvidence()
            }
            try validatePublishedPathAndManifest(requiresExactTree: false)
            try validateMetadataBytes()
            try requireTrustworthyMonitors()
        }
    }

    public func discard() {
        lock.withLock {
            guard state != .consumed, state != .discarded else { return }
            state = .discarded
            closeEvidence()
        }
    }

    private func validateMetadataBytes() throws {
        guard let expectedProjectURL else {
            throw FreshProjectPublicationAttestationError.projectIdentityChanged
        }
        let metadataURL = expectedProjectURL.appendingPathComponent("project.json")
        let bytes: Data
        do {
            bytes = try Data(contentsOf: metadataURL, options: .mappedIfSafe)
        } catch {
            throw FreshProjectPublicationAttestationError.metadataChanged
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedMetadataSHA256 else {
            throw FreshProjectPublicationAttestationError.metadataChanged
        }
    }

    private func validatePublishedPathAndManifest(requiresExactTree: Bool) throws {
        guard let expectedProjectURL else {
            throw FreshProjectPublicationAttestationError.projectIdentityChanged
        }
        var namedRoot = stat()
        guard fstat(bundleDescriptor, &namedRoot) == 0,
              expectedBundle.matches(namedRoot) else {
            throw FreshProjectPublicationAttestationError.projectIdentityChanged
        }
        var reboundRoot = stat()
        guard lstat(expectedProjectURL.path, &reboundRoot) == 0,
              expectedBundle.matches(reboundRoot) else {
            throw FreshProjectPublicationAttestationError.projectIdentityChanged
        }
        for entry in expectedManifest {
            if !requiresExactTree, entry.relativePath == "." { continue }
            var status = stat()
            let result: Int32
            if entry.relativePath == "." {
                result = fstat(bundleDescriptor, &status)
            } else {
                result = entry.relativePath.withCString {
                    fstatat(bundleDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
            }
            guard result == 0, entry.matches(status) else {
                throw entry.relativePath == "project.json"
                    ? FreshProjectPublicationAttestationError.metadataChanged
                    : FreshProjectPublicationAttestationError.filesystemChanged
            }
        }
        if requiresExactTree {
            let expectedPaths = Set(expectedManifest.map(\.relativePath))
            let observedPaths = try Self.relativeTreePaths(root: expectedProjectURL)
            guard observedPaths == expectedPaths else {
                throw FreshProjectPublicationAttestationError.filesystemChanged
            }
        }
    }

    private func requireTrustworthyMonitors() throws {
        guard prePublicationMonitor == nil,
              let snapshot = publishedMonitor?.poll(),
              publishedSnapshotIsTrustworthy(snapshot) else {
            throw FreshProjectPublicationAttestationError.filesystemChanged
        }
    }

    private func publishedSnapshotIsTrustworthy(
        _ snapshot: VnodeMutationMonitor.Snapshot
    ) -> Bool {
        guard snapshot.failure == nil else { return false }
        return snapshot.mutations.allSatisfy { mutation in
            guard mutation.flags == [.attribute],
                  let entry = expectedManifest.first(where: {
                    $0.relativePath == mutation.label && !$0.isDirectory
                  }) else {
                return false
            }
            var status = stat()
            let result = entry.relativePath.withCString {
                fstatat(bundleDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            // APFS may report NOTE_ATTRIB when a read advances access-time state.
            // Publication evidence intentionally excludes atime. Attribute churn is
            // accepted only for a file whose identity, mode, link count, size, mtime,
            // and ctime still exactly match the durable publication manifest.
            return result == 0 && entry.matches(status)
        }
    }

    private func closeEvidence() {
        prePublicationMonitor?.close()
        prePublicationMonitor = nil
        prePublicationRootMonitor?.close()
        prePublicationRootMonitor = nil
        publishedMonitor?.close()
        publishedMonitor = nil
        preConsumptionRootMonitor?.close()
        preConsumptionRootMonitor = nil
        if baseDescriptor >= 0 {
            Darwin.close(baseDescriptor)
            baseDescriptor = -1
        }
        if bundleDescriptor >= 0 {
            Darwin.close(bundleDescriptor)
            bundleDescriptor = -1
        }
    }

    private static func duplicate(_ descriptor: Int32) throws -> Int32 {
        let duplicated = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicated >= 0 else {
            throw FreshProjectPublicationAttestationError.filesystemChanged
        }
        return duplicated
    }

    private static func makeWatches(
        rootDescriptor: Int32,
        entries: [ManifestEntry]
    ) throws -> [(descriptor: Int32, label: String)] {
        var result: [(Int32, String)] = []
        do {
            for entry in entries {
                let descriptor = entry.relativePath.withCString {
                    openat(rootDescriptor, $0, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else {
                    throw FreshProjectPublicationAttestationError.filesystemChanged
                }
                var status = stat()
                guard fstat(descriptor, &status) == 0, entry.matches(status) else {
                    Darwin.close(descriptor)
                    throw FreshProjectPublicationAttestationError.filesystemChanged
                }
                result.append((descriptor, entry.relativePath))
            }
            return result
        } catch {
            result.forEach { Darwin.close($0.0) }
            throw error
        }
    }

    private static func relativeTreePaths(root: URL) throws -> Set<String> {
        let canonicalRootPath = try canonicalExistingPath(root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw FreshProjectPublicationAttestationError.filesystemChanged
        }
        var paths: Set<String> = ["."]
        for case let url as URL in enumerator {
            let canonicalURLPath = try canonicalExistingPath(url)
            let prefix = canonicalRootPath.hasSuffix("/")
                ? canonicalRootPath
                : canonicalRootPath + "/"
            guard canonicalURLPath.hasPrefix(prefix) else {
                throw FreshProjectPublicationAttestationError.filesystemChanged
            }
            paths.insert(String(canonicalURLPath.dropFirst(prefix.count)))
        }
        return paths
    }

    private static func canonicalExistingPath(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.path.withCString { path in
            realpath(path, &buffer)
        }
        guard resolved != nil else {
            throw FreshProjectPublicationAttestationError.filesystemChanged
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
