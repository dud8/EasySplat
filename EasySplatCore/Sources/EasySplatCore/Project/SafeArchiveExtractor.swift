import CryptoKit
import Darwin
import Foundation

/// Validates and extracts untrusted ZIP archives through one descriptor-bound
/// `ZipArchiveReader.Snapshot`.
public enum SafeArchiveExtractor {
    public struct ExtractionLimits: Sendable, Equatable {
        public var maxEntryCount: Int
        public var maxEntryUncompressedBytes: UInt64
        public var maxTotalUncompressedBytes: UInt64
        public var maxEntryCompressedBytes: UInt64
        public var maxTotalCompressedBytes: UInt64

        public init(
            maxEntryCount: Int,
            maxEntryUncompressedBytes: UInt64,
            maxTotalUncompressedBytes: UInt64,
            maxEntryCompressedBytes: UInt64 = 2 * 1024 * 1024 * 1024,
            maxTotalCompressedBytes: UInt64 = 16 * 1024 * 1024 * 1024
        ) {
            self.maxEntryCount = maxEntryCount
            self.maxEntryUncompressedBytes = maxEntryUncompressedBytes
            self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
            self.maxEntryCompressedBytes = maxEntryCompressedBytes
            self.maxTotalCompressedBytes = maxTotalCompressedBytes
        }

        public static let `default` = ExtractionLimits(
            maxEntryCount: 100_000,
            maxEntryUncompressedBytes: 2 * 1024 * 1024 * 1024,
            maxTotalUncompressedBytes: 16 * 1024 * 1024 * 1024,
            maxEntryCompressedBytes: 2 * 1024 * 1024 * 1024,
            maxTotalCompressedBytes: 16 * 1024 * 1024 * 1024
        )
    }

    public struct Inventory: Sendable, Equatable {
        public struct Entry: Sendable, Equatable {
            public let relativePath: String
            public let byteCount: UInt64

            public init(relativePath: String, byteCount: UInt64) {
                self.relativePath = relativePath
                self.byteCount = byteCount
            }
        }

        public let entries: [Entry]

        public init(entries: [Entry]) {
            self.entries = entries
        }

        public var totalBytes: UInt64 {
            entries.reduce(UInt64.zero) { partial, entry in
                let sum = partial.addingReportingOverflow(entry.byteCount)
                return sum.overflow ? UInt64.max : sum.partialValue
            }
        }
    }

    public enum ExtractionError: Swift.Error, LocalizedError, Equatable {
        case listingFailed
        case extractionFailed
        case extractionRootUnavailable
        case symbolicLinkEntry
        case specialFileEntry
        case unsafeEntryPath(String)
        case pathTraversal(String)
        case duplicateEntry(String)
        case caseInsensitiveCollision(String, String)
        case pathTypeCollision(String)
        case entryCountExceeded(limit: Int)
        case archiveListingTooLarge
        case entryTooLarge(path: String, bytes: UInt64, limit: UInt64)
        case totalSizeExceeded(bytes: UInt64, limit: UInt64)
        case compressedEntryTooLarge(path: String, bytes: UInt64, limit: UInt64)
        case compressedTotalSizeExceeded(bytes: UInt64, limit: UInt64)
        case enumerationFailed
        case extractedSymbolicLink(String)
        case foreignFileType(String)

        public var errorDescription: String? {
            switch self {
            case .listingFailed:
                return "The archive could not be inspected before extraction."
            case .extractionFailed:
                return "The archive could not be unpacked."
            case .extractionRootUnavailable:
                return "The extraction destination could not be prepared."
            case .symbolicLinkEntry:
                return "The archive contains a symbolic link entry, which is not allowed."
            case .specialFileEntry:
                return "The archive contains a special file entry, which is not allowed."
            case .unsafeEntryPath(let path):
                return "The archive contains an unsafe entry path: \(path)."
            case .pathTraversal(let path):
                return "The archive contains a path traversal entry: \(path)."
            case .duplicateEntry(let path):
                return "The archive lists the entry \(path) more than once."
            case .caseInsensitiveCollision(let first, let second):
                return "The archive lists entries that collide on a case-insensitive file system: \(first) and \(second)."
            case .pathTypeCollision(let path):
                return "The archive uses \(path) as both a file and a directory."
            case .entryCountExceeded(let limit):
                return "The archive contains more than \(limit) entries."
            case .archiveListingTooLarge:
                return "The archive entry listing is too large to inspect safely."
            case .entryTooLarge(let path, let bytes, let limit):
                return "The archive entry \(path) expands to \(bytes) bytes, exceeding the \(limit)-byte per-entry limit."
            case .totalSizeExceeded(let bytes, let limit):
                return "The archive expands to \(bytes) bytes, exceeding the \(limit)-byte total limit."
            case .compressedEntryTooLarge(let path, let bytes, let limit):
                return "The compressed archive entry \(path) is \(bytes) bytes, exceeding the \(limit)-byte per-entry limit."
            case .compressedTotalSizeExceeded(let bytes, let limit):
                return "The archive contains \(bytes) compressed bytes, exceeding the \(limit)-byte total limit."
            case .enumerationFailed:
                return "The extracted archive could not be enumerated."
            case .extractedSymbolicLink(let path):
                return "The extracted archive produced a symbolic link, which is not allowed: \(path)."
            case .foreignFileType(let path):
                return "The extracted archive produced an entry that is neither a regular file nor a directory: \(path)."
            }
        }
    }

    static let listingByteBudget = 128 * 1024 * 1024
    private static let maximumTraversalDepth = 64

    enum VerificationEvent: Sendable {
        case beforeInventory
        case afterInventory
    }

    enum DirectoryPublicationPhase: Sendable {
        case beforePublish
        case afterPublish
    }

    struct DirectoryPublicationEvent: Sendable {
        let phase: DirectoryPublicationPhase
        let parentDescriptor: Int32
        let intendedName: String
        let privateName: String
    }

    @discardableResult
    public static func extract(
        zipURL: URL,
        to destination: URL,
        limits: ExtractionLimits = .default
    ) throws -> Inventory {
        let shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
        try throwIfCancelled(shouldCancel)
        let snapshot = try openSnapshot(
            at: zipURL,
            limits: limits,
            shouldCancel: shouldCancel
        )
        return try extract(
            snapshot: snapshot,
            to: destination,
            limits: limits,
            shouldCancel: shouldCancel
        )
    }

    /// Internal entry point used by deterministic race tests. Production opens
    /// a fresh snapshot in the public overload above; selection-time sniffing
    /// never supplies this object.
    @discardableResult
    static func extract(
        snapshot: ZipArchiveReader.Snapshot,
        to destination: URL,
        limits: ExtractionLimits,
        shouldCancel: @escaping @Sendable () -> Bool,
        verificationObserver: @escaping @Sendable (VerificationEvent) -> Void = { _ in },
        directoryPublicationObserver: @escaping @Sendable (
            DirectoryPublicationEvent
        ) -> Void = { _ in }
    ) throws -> Inventory {
        let listing = try listArchive(
            snapshot: snapshot,
            maximumListingBytes: listingByteBudget,
            maximumEntryCount: limits.maxEntryCount
        )
        try validateListing(listing, limits: limits)
        try validateEntryPaths(listing.names, allowingDirectoryEntries: true)
        try validatePathCollisions(snapshot.entries.map {
            CollisionPath(path: $0.path, isDirectory: $0.isDirectory)
        })
        try throwIfCancelled(shouldCancel)

        let root = try DestinationRoot(
            destination: destination,
            publicationObserver: directoryPublicationObserver
        )
        var bindings = ExtractionBindings()

        do {
            let written = try writeEntries(
                snapshot: snapshot,
                rootDescriptor: root.descriptor,
                limits: limits,
                bindings: &bindings,
                shouldCancel: shouldCancel,
                directoryPublicationObserver: directoryPublicationObserver
            )
            try snapshot.requireUnchanged()
            try throwIfCancelled(shouldCancel)
            try root.requireBinding()
            verificationObserver(.beforeInventory)
            let observed = try boundInventory(
                rootDescriptor: root.descriptor,
                bindings: bindings,
                shouldCancel: shouldCancel
            )
            verificationObserver(.afterInventory)
            try root.requireBinding()
            guard observed == written else { throw ExtractionError.extractionFailed }
            try throwIfCancelled(shouldCancel)
            try root.publish()
            return written
        } catch {
            if error is CancellationError { throw CancellationError() }
            if let extractionError = error as? ExtractionError { throw extractionError }
            throw ExtractionError.extractionFailed
        }
    }

    public static func entryNames(inZipAt url: URL) throws -> [String] {
        do {
            return try ZipArchiveReader.boundedEntryNames(
                inArchiveAt: url,
                maximumEntryCount: ZipArchiveReader.sniffingMaximumEntryCount,
                maximumListingBytes: listingByteBudget,
                maximumPathComponents: maximumTraversalDepth
            )
        } catch {
            throw ExtractionError.listingFailed
        }
    }

    // MARK: - Shared validation

    static func validateEntryPaths(
        _ entries: [String],
        allowingDirectoryEntries: Bool = false
    ) throws {
        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(entry).inserted else {
                throw ExtractionError.duplicateEntry(entry)
            }
        }
        for entry in entries {
            guard !entry.isEmpty,
                  !entry.hasPrefix("/"),
                  !entry.contains("\\"),
                  !entry.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ExtractionError.unsafeEntryPath(entry)
            }
            var parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            if allowingDirectoryEntries, parts.count > 1, parts.last == "" {
                parts.removeLast()
            }
            guard parts.count <= maximumTraversalDepth,
                  parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else {
                throw ExtractionError.pathTraversal(entry)
            }
        }
    }

    private enum PathKind: Equatable {
        case file
        case directory
    }

    private struct CollisionPath {
        let path: String
        let isDirectory: Bool
    }

    private final class PathCollisionNode {
        struct Child {
            let spelling: String
            let firstEntry: String
            let node: PathCollisionNode
        }

        var children: [String: Child] = [:]
        var declaredKind: PathKind?
        var declaredPath: String?
    }

    @discardableResult
    private static func validatePathCollisions(_ entries: [CollisionPath]) throws -> Int {
        let root = PathCollisionNode()
        var componentVisits = 0

        for entry in entries {
            let normalized = entry.path.hasSuffix("/")
                ? String(entry.path.dropLast())
                : entry.path
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            var node = root

            for (index, componentSubstring) in components.enumerated() {
                componentVisits += 1
                let component = String(componentSubstring)
                let key = component.lowercased()
                let child: PathCollisionNode.Child
                if let existing = node.children[key] {
                    guard existing.spelling == component else {
                        throw ExtractionError.caseInsensitiveCollision(
                            existing.firstEntry,
                            entry.path
                        )
                    }
                    child = existing
                } else {
                    child = PathCollisionNode.Child(
                        spelling: component,
                        firstEntry: entry.path,
                        node: PathCollisionNode()
                    )
                    node.children[key] = child
                }
                node = child.node

                if index < components.count - 1, node.declaredKind == .file {
                    throw ExtractionError.pathTypeCollision(node.declaredPath ?? normalized)
                }
            }

            let kind: PathKind = entry.isDirectory ? .directory : .file
            if let existing = node.declaredKind, existing != kind {
                throw ExtractionError.pathTypeCollision(normalized)
            }
            if kind == .file, !node.children.isEmpty {
                throw ExtractionError.pathTypeCollision(normalized)
            }
            node.declaredKind = kind
            node.declaredPath = normalized
        }
        return componentVisits
    }

    static func collisionValidationComponentCount(
        _ entries: [(path: String, isDirectory: Bool)]
    ) throws -> Int {
        try validatePathCollisions(entries.map {
            CollisionPath(path: $0.path, isDirectory: $0.isDirectory)
        })
    }

    /// Canonicalizes only the fixed macOS system aliases used for temporary
    /// paths. Arbitrary symlinks remain in the path and are rejected by the
    /// descriptor-relative `O_NOFOLLOW` walk below.
    static func destinationPathForBinding(_ destination: URL) throws -> URL {
        guard destination.isFileURL else {
            throw ExtractionError.extractionRootUnavailable
        }
        let standardized = destination.standardizedFileURL
        let path = standardized.path
        for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
            guard let resolvedAlias = alias.withCString({ source -> String? in
                guard let resolved = Darwin.realpath(source, nil) else { return nil }
                defer { Darwin.free(resolved) }
                return String(cString: resolved)
            }) else {
                throw ExtractionError.extractionRootUnavailable
            }
            let suffix = path.dropFirst(alias.count)
            // Do not standardize this URL again. Foundation re-expresses an
            // existing `/private/var/...` path through the `/var` symlink,
            // undoing the no-follow-safe canonicalization we just performed.
            return URL(fileURLWithPath: resolvedAlias + suffix)
        }
        return standardized
    }

    // MARK: - Listing

    enum ListingLimitBreach: Equatable {
        case none
        case entryCount
        case byteBudget
    }

    struct ArchiveListing {
        let names: [String]
        let breach: ListingLimitBreach
        let containsSymbolicLink: Bool
        let containsSpecialFile: Bool
        let totalUncompressedBytes: UInt64
        let totalOverflowed: Bool
        let largestEntryName: String
        let largestEntryBytes: UInt64
        let totalCompressedBytes: UInt64
        let compressedTotalOverflowed: Bool
        let largestCompressedEntryName: String
        let largestCompressedEntryBytes: UInt64
    }

    static func listArchive(
        zipURL: URL,
        maximumListingBytes: Int,
        maximumEntryCount: Int
    ) throws -> ArchiveListing {
        let limits = ExtractionLimits(
            maxEntryCount: maximumEntryCount,
            maxEntryUncompressedBytes: UInt64.max,
            maxTotalUncompressedBytes: UInt64.max
        )
        let snapshot = try openSnapshot(
            at: zipURL,
            limits: limits,
            maximumListingBytes: maximumListingBytes
        )
        return try listArchive(
            snapshot: snapshot,
            maximumListingBytes: maximumListingBytes,
            maximumEntryCount: maximumEntryCount
        )
    }

    private static func listArchive(
        snapshot: ZipArchiveReader.Snapshot,
        maximumListingBytes: Int,
        maximumEntryCount: Int
    ) throws -> ArchiveListing {
        var names: [String] = []
        names.reserveCapacity(snapshot.entries.count)
        var listingBytes = 0
        var breach: ListingLimitBreach = .none
        var totalUncompressed: UInt64 = 0
        var totalOverflowed = false
        var largestName = ""
        var largestBytes: UInt64 = 0
        var totalCompressed: UInt64 = 0
        var compressedTotalOverflowed = false
        var largestCompressedName = ""
        var largestCompressedBytes: UInt64 = 0

        for entry in snapshot.entries {
            if entry.isSymbolicLink { throw ExtractionError.symbolicLinkEntry }
            let mode = entry.unixMode & S_IFMT
            if mode != 0 && mode != S_IFREG && mode != S_IFDIR {
                throw ExtractionError.specialFileEntry
            }
            if mode == S_IFDIR && !entry.isDirectory
                || mode == S_IFREG && entry.isDirectory
                || entry.isDirectory && (entry.compressedSize != 0 || entry.uncompressedSize != 0) {
                throw ExtractionError.specialFileEntry
            }
            guard names.count < maximumEntryCount else {
                breach = .entryCount
                break
            }
            let added = entry.path.utf8.count.addingReportingOverflow(1)
            let next = listingBytes.addingReportingOverflow(added.partialValue)
            guard !added.overflow,
                  !next.overflow,
                  next.partialValue <= maximumListingBytes else {
                breach = .byteBudget
                break
            }
            names.append(entry.path)
            listingBytes = next.partialValue
            if entry.isDirectory { continue }
            let sum = totalUncompressed.addingReportingOverflow(entry.uncompressedSize)
            if sum.overflow {
                totalOverflowed = true
                totalUncompressed = UInt64.max
            } else {
                totalUncompressed = sum.partialValue
            }
            if entry.uncompressedSize > largestBytes {
                largestBytes = entry.uncompressedSize
                largestName = entry.path
            }
            let compressedSum = totalCompressed.addingReportingOverflow(entry.compressedSize)
            if compressedSum.overflow {
                compressedTotalOverflowed = true
                totalCompressed = UInt64.max
            } else {
                totalCompressed = compressedSum.partialValue
            }
            if entry.compressedSize > largestCompressedBytes {
                largestCompressedBytes = entry.compressedSize
                largestCompressedName = entry.path
            }
        }

        return ArchiveListing(
            names: names,
            breach: breach,
            containsSymbolicLink: false,
            containsSpecialFile: false,
            totalUncompressedBytes: totalUncompressed,
            totalOverflowed: totalOverflowed,
            largestEntryName: largestName,
            largestEntryBytes: largestBytes,
            totalCompressedBytes: totalCompressed,
            compressedTotalOverflowed: compressedTotalOverflowed,
            largestCompressedEntryName: largestCompressedName,
            largestCompressedEntryBytes: largestCompressedBytes
        )
    }

    private static func validateListing(
        _ listing: ArchiveListing,
        limits: ExtractionLimits
    ) throws {
        switch listing.breach {
        case .entryCount:
            throw ExtractionError.entryCountExceeded(limit: limits.maxEntryCount)
        case .byteBudget:
            throw ExtractionError.archiveListingTooLarge
        case .none:
            break
        }
        if listing.largestEntryBytes > limits.maxEntryUncompressedBytes {
            throw ExtractionError.entryTooLarge(
                path: listing.largestEntryName,
                bytes: listing.largestEntryBytes,
                limit: limits.maxEntryUncompressedBytes
            )
        }
        if listing.totalOverflowed
            || listing.totalUncompressedBytes > limits.maxTotalUncompressedBytes {
            throw ExtractionError.totalSizeExceeded(
                bytes: listing.totalOverflowed ? UInt64.max : listing.totalUncompressedBytes,
                limit: limits.maxTotalUncompressedBytes
            )
        }
        if listing.largestCompressedEntryBytes > limits.maxEntryCompressedBytes {
            throw ExtractionError.compressedEntryTooLarge(
                path: listing.largestCompressedEntryName,
                bytes: listing.largestCompressedEntryBytes,
                limit: limits.maxEntryCompressedBytes
            )
        }
        if listing.compressedTotalOverflowed
            || listing.totalCompressedBytes > limits.maxTotalCompressedBytes {
            throw ExtractionError.compressedTotalSizeExceeded(
                bytes: listing.compressedTotalOverflowed
                    ? UInt64.max
                    : listing.totalCompressedBytes,
                limit: limits.maxTotalCompressedBytes
            )
        }
    }

    private static func openSnapshot(
        at url: URL,
        limits: ExtractionLimits,
        maximumListingBytes: Int = listingByteBudget,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> ZipArchiveReader.Snapshot {
        do {
            guard limits.maxEntryCount >= 0, maximumListingBytes >= 0 else {
                throw ExtractionError.archiveListingTooLarge
            }
            let entryOverhead = UInt64(limits.maxEntryCount)
                .multipliedReportingOverflow(by: 256)
            let listingOverhead = UInt64(maximumListingBytes)
                .addingReportingOverflow(1024 * 1024)
            guard !entryOverhead.overflow, !listingOverhead.overflow else {
                throw ExtractionError.archiveListingTooLarge
            }
            let structuralOverhead = entryOverhead.partialValue.addingReportingOverflow(
                listingOverhead.partialValue
            )
            let maximumArchiveBytes = limits.maxTotalCompressedBytes.addingReportingOverflow(
                structuralOverhead.partialValue
            )
            guard !structuralOverhead.overflow, !maximumArchiveBytes.overflow else {
                throw ExtractionError.archiveListingTooLarge
            }
            return try ZipArchiveReader.Snapshot(
                opening: url,
                maximumEntryCount: limits.maxEntryCount,
                maximumNameBytes: maximumListingBytes,
                maximumArchiveBytes: maximumArchiveBytes.partialValue,
                maximumPathComponents: maximumTraversalDepth,
                shouldCancel: shouldCancel
            )
        } catch ZipArchiveReader.ReaderError.entryCountExceeded {
            throw ExtractionError.entryCountExceeded(limit: limits.maxEntryCount)
        } catch ZipArchiveReader.ReaderError.listingTooLarge {
            throw ExtractionError.archiveListingTooLarge
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExtractionError.listingFailed
        }
    }

    // MARK: - Descriptor-relative extraction

    private final class DirectoryBindingNode {
        var identity: ZipArchiveReader.FileIdentity?
        var children: [String: DirectoryBindingNode] = [:]
        var files: [String: ZipArchiveReader.ExtractedFile] = [:]
    }

    private struct ExtractionBindings {
        let root = DirectoryBindingNode()
    }

    private struct OpenedDirectory {
        let descriptor: Int32
        let binding: DirectoryBindingNode
    }

    private struct CreatedDirectory {
        let descriptor: Int32
        let identity: ZipArchiveReader.FileIdentity
    }

    private struct PrivateDirectory {
        let descriptor: Int32
        let identity: ZipArchiveReader.FileIdentity
        let name: String
    }

    /// Creates and binds one unpredictable 0700 directory without exposing it
    /// at the caller's requested pathname. On failure the private name is left
    /// untouched: macOS has no unlink-if-inode primitive, so pathname cleanup
    /// cannot safely distinguish an app-owned inode from a same-UID replacement.
    private static func createPrivateDirectory(
        parentDescriptor: Int32,
        prefix: String,
        failure: ExtractionError
    ) throws -> PrivateDirectory {
        var privateName: String?
        for _ in 0..<8 {
            let candidate = ".\(prefix)-\(UUID().uuidString)"
            let result = candidate.withCString {
                Darwin.mkdirat(parentDescriptor, $0, mode_t(S_IRWXU))
            }
            if result == 0 {
                privateName = candidate
                break
            }
            guard errno == EEXIST else { throw failure }
        }
        guard let privateName else { throw failure }

        var namedStatus = stat()
        guard privateName.withCString({
            Darwin.fstatat(parentDescriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              (namedStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw failure
        }
        let identity = ZipArchiveReader.FileIdentity(namedStatus)
        let descriptor = privateName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw failure }

        var openedStatus = stat()
        var securedStatus = stat()
        var reboundStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              identity.matches(openedStatus),
              Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0,
              Darwin.fstat(descriptor, &securedStatus) == 0,
              identity.matches(securedStatus),
              (securedStatus.st_mode & 0o7777) == mode_t(S_IRWXU),
              privateName.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &reboundStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              identity.matches(reboundStatus),
              (reboundStatus.st_mode & 0o7777) == mode_t(S_IRWXU) else {
            Darwin.close(descriptor)
            throw failure
        }
        return PrivateDirectory(
            descriptor: descriptor,
            identity: identity,
            name: privateName
        )
    }

    /// Creates a directory under an unpredictable private name, binds and
    /// secures its descriptor, then publishes it to the requested component
    /// with an exclusive rename. A competing public component is never opened,
    /// chmodded, written into, or removed by this operation.
    private static func createAndPublishDirectory(
        parentDescriptor: Int32,
        intendedName: String,
        failure: ExtractionError,
        publicationObserver: @escaping @Sendable (
            DirectoryPublicationEvent
        ) -> Void
    ) throws -> CreatedDirectory {
        guard !intendedName.isEmpty,
              intendedName != ".",
              intendedName != "..",
              !intendedName.contains("/"),
              !intendedName.contains("\\") else {
            throw failure
        }

        let privateDirectory = try createPrivateDirectory(
            parentDescriptor: parentDescriptor,
            prefix: "easysplat-create",
            failure: failure
        )
        let privateName = privateDirectory.name
        let identity = privateDirectory.identity
        let descriptor = privateDirectory.descriptor

        do {
            var openedStatus = stat()
            var reboundStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                  identity.matches(openedStatus),
                  privateName.withCString({
                      Darwin.fstatat(
                          parentDescriptor,
                          $0,
                          &reboundStatus,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  identity.matches(reboundStatus),
                  Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
                throw failure
            }

            publicationObserver(DirectoryPublicationEvent(
                phase: .beforePublish,
                parentDescriptor: parentDescriptor,
                intendedName: intendedName,
                privateName: privateName
            ))

            var prePublishOpened = stat()
            var prePublishNamed = stat()
            guard Darwin.fstat(descriptor, &prePublishOpened) == 0,
                  identity.matches(prePublishOpened),
                  (prePublishOpened.st_mode & 0o7777) == mode_t(S_IRWXU),
                  privateName.withCString({
                      Darwin.fstatat(
                          parentDescriptor,
                          $0,
                          &prePublishNamed,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  identity.matches(prePublishNamed),
                  (prePublishNamed.st_mode & 0o7777) == mode_t(S_IRWXU) else {
                throw failure
            }

            let renamed = privateName.withCString { source in
                intendedName.withCString { destination in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard renamed == 0 else { throw failure }

            publicationObserver(DirectoryPublicationEvent(
                phase: .afterPublish,
                parentDescriptor: parentDescriptor,
                intendedName: intendedName,
                privateName: privateName
            ))

            var finalOpened = stat()
            var finalNamed = stat()
            guard Darwin.fstat(descriptor, &finalOpened) == 0,
                  identity.matches(finalOpened),
                  (finalOpened.st_mode & 0o7777) == mode_t(S_IRWXU),
                  intendedName.withCString({
                      Darwin.fstatat(
                          parentDescriptor,
                          $0,
                          &finalNamed,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  identity.matches(finalNamed),
                  (finalNamed.st_mode & 0o7777) == mode_t(S_IRWXU) else {
                throw failure
            }
            return CreatedDirectory(descriptor: descriptor, identity: identity)
        } catch {
            Darwin.close(descriptor)
            throw failure
        }
    }

    private static func writeEntries(
        snapshot: ZipArchiveReader.Snapshot,
        rootDescriptor: Int32,
        limits: ExtractionLimits,
        bindings: inout ExtractionBindings,
        shouldCancel: @escaping @Sendable () -> Bool,
        directoryPublicationObserver: @escaping @Sendable (
            DirectoryPublicationEvent
        ) -> Void
    ) throws -> Inventory {
        var inventory: [Inventory.Entry] = []
        inventory.reserveCapacity(snapshot.entries.count)
        var totalWritten: UInt64 = 0

        for entry in snapshot.entries {
            try throwIfCancelled(shouldCancel)
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { throw ExtractionError.extractionFailed }
            let directoryComponents = entry.isDirectory
                ? components
                : Array(components.dropLast())
            let parent = try openDirectoryChain(
                rootDescriptor: rootDescriptor,
                components: directoryComponents,
                bindings: &bindings,
                shouldCancel: shouldCancel,
                directoryPublicationObserver: directoryPublicationObserver
            )
            defer { Darwin.close(parent.descriptor) }
            if entry.isDirectory { continue }

            let remaining = limits.maxTotalUncompressedBytes.subtractingReportingOverflow(totalWritten)
            guard !remaining.overflow else {
                throw ExtractionError.totalSizeExceeded(
                    bytes: totalWritten,
                    limit: limits.maxTotalUncompressedBytes
                )
            }
            let maximum = min(limits.maxEntryUncompressedBytes, remaining.partialValue)
            let leaf = components[components.count - 1]
            let extracted = try snapshot.extract(
                entry: entry,
                into: parent.descriptor,
                leafName: leaf,
                maximumOutputBytes: maximum,
                shouldCancel: shouldCancel
            )
            let sum = totalWritten.addingReportingOverflow(extracted.byteCount)
            guard !sum.overflow, sum.partialValue <= limits.maxTotalUncompressedBytes else {
                throw ExtractionError.totalSizeExceeded(
                    bytes: sum.overflow ? UInt64.max : sum.partialValue,
                    limit: limits.maxTotalUncompressedBytes
                )
            }
            totalWritten = sum.partialValue
            parent.binding.files[leaf] = extracted
            inventory.append(Inventory.Entry(
                relativePath: entry.path,
                byteCount: extracted.byteCount
            ))
        }

        let declaredTotal = snapshot.entries
            .filter { !$0.isDirectory }
            .reduce(UInt64.zero) { partial, entry in
                partial.addingReportingOverflow(entry.uncompressedSize).partialValue
            }
        guard totalWritten == declaredTotal else { throw ExtractionError.extractionFailed }
        inventory.sort { $0.relativePath < $1.relativePath }
        return Inventory(entries: inventory)
    }

    private static func openDirectoryChain(
        rootDescriptor: Int32,
        components: [String],
        bindings: inout ExtractionBindings,
        shouldCancel: @escaping @Sendable () -> Bool,
        directoryPublicationObserver: @escaping @Sendable (
            DirectoryPublicationEvent
        ) -> Void
    ) throws -> OpenedDirectory {
        let initial = Darwin.openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard initial >= 0 else { throw ExtractionError.extractionRootUnavailable }
        var current = initial
        var currentBinding = bindings.root

        do {
            for component in components {
                try throwIfCancelled(shouldCancel)
                let childBinding: DirectoryBindingNode
                if let existing = currentBinding.children[component] {
                    childBinding = existing
                } else {
                    childBinding = DirectoryBindingNode()
                    currentBinding.children[component] = childBinding
                }
                var status = stat()
                let result = component.withCString {
                    Darwin.fstatat(current, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                let child: Int32
                let namedIdentity: ZipArchiveReader.FileIdentity
                if result != 0 {
                    guard errno == ENOENT else { throw ExtractionError.extractionFailed }
                    let createdDirectory = try createAndPublishDirectory(
                        parentDescriptor: current,
                        intendedName: component,
                        failure: .extractionFailed,
                        publicationObserver: directoryPublicationObserver
                    )
                    child = createdDirectory.descriptor
                    namedIdentity = createdDirectory.identity
                } else {
                    guard (status.st_mode & S_IFMT) == S_IFDIR,
                          (status.st_mode & 0o7777) == mode_t(S_IRWXU) else {
                        throw ExtractionError.extractionFailed
                    }
                    namedIdentity = ZipArchiveReader.FileIdentity(status)
                    child = component.withCString {
                        Darwin.openat(
                            current,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard child >= 0 else { throw ExtractionError.extractionFailed }
                    var openedStatus = stat()
                    var reboundStatus = stat()
                    guard Darwin.fstat(child, &openedStatus) == 0,
                          namedIdentity.matches(openedStatus),
                          (openedStatus.st_mode & 0o7777) == mode_t(S_IRWXU),
                          component.withCString({
                              Darwin.fstatat(
                                  current,
                                  $0,
                                  &reboundStatus,
                                  AT_SYMLINK_NOFOLLOW
                              )
                          }) == 0,
                          namedIdentity.matches(reboundStatus),
                          (reboundStatus.st_mode & 0o7777) == mode_t(S_IRWXU) else {
                        Darwin.close(child)
                        throw ExtractionError.extractionFailed
                    }
                }
                if let expected = childBinding.identity,
                   expected != namedIdentity {
                    Darwin.close(child)
                    throw ExtractionError.extractionFailed
                }
                childBinding.identity = namedIdentity
                Darwin.close(current)
                current = child
                currentBinding = childBinding
            }
            return OpenedDirectory(descriptor: current, binding: currentBinding)
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private final class DestinationRoot {
        let descriptor: Int32
        private let parentDescriptor: Int32
        private let leaf: String
        private let privateLeaf: String
        private let identity: ZipArchiveReader.FileIdentity
        private let publicationObserver: @Sendable (DirectoryPublicationEvent) -> Void
        private var isPublished = false

        init(
            destination: URL,
            publicationObserver: @escaping @Sendable (
                DirectoryPublicationEvent
            ) -> Void
        ) throws {
            let openedParent = try Self.openParent(
                of: destination,
                publicationObserver: publicationObserver
            )
            let parentDescriptor = openedParent.descriptor
            let leaf = openedParent.leaf

            var existing = stat()
            let result = leaf.withCString {
                Darwin.fstatat(parentDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 {
                Darwin.close(parentDescriptor)
                throw ExtractionError.extractionRootUnavailable
            }
            guard errno == ENOENT else {
                Darwin.close(parentDescriptor)
                throw ExtractionError.extractionRootUnavailable
            }
            let privateDirectory: PrivateDirectory
            do {
                privateDirectory = try SafeArchiveExtractor.createPrivateDirectory(
                    parentDescriptor: parentDescriptor,
                    prefix: "easysplat-extract",
                    failure: .extractionRootUnavailable
                )
            } catch {
                Darwin.close(parentDescriptor)
                throw error
            }

            descriptor = privateDirectory.descriptor
            self.parentDescriptor = parentDescriptor
            self.leaf = leaf
            privateLeaf = privateDirectory.name
            identity = privateDirectory.identity
            self.publicationObserver = publicationObserver
        }

        deinit {
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
        }

        func requireBinding() throws {
            var opened = stat()
            var named = stat()
            let currentLeaf = isPublished ? leaf : privateLeaf
            guard Darwin.fstat(descriptor, &opened) == 0,
                  identity.matches(opened),
                  (opened.st_mode & 0o7777) == mode_t(S_IRWXU),
                  currentLeaf.withCString({
                      Darwin.fstatat(parentDescriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  identity.matches(named),
                  (named.st_mode & 0o7777) == mode_t(S_IRWXU) else {
                throw ExtractionError.extractionFailed
            }
        }

        func publish() throws {
            guard !isPublished else { return }
            try requireBinding()
            publicationObserver(DirectoryPublicationEvent(
                phase: .beforePublish,
                parentDescriptor: parentDescriptor,
                intendedName: leaf,
                privateName: privateLeaf
            ))
            try requireBinding()
            let renamed = privateLeaf.withCString { source in
                leaf.withCString { destination in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard renamed == 0 else { throw ExtractionError.extractionFailed }
            isPublished = true
            publicationObserver(DirectoryPublicationEvent(
                phase: .afterPublish,
                parentDescriptor: parentDescriptor,
                intendedName: leaf,
                privateName: privateLeaf
            ))
            try requireBinding()
        }

        private static func openParent(
            of destination: URL,
            publicationObserver: @escaping @Sendable (
                DirectoryPublicationEvent
            ) -> Void
        ) throws -> (
            descriptor: Int32,
            leaf: String
        ) {
            let bindingDestination = try SafeArchiveExtractor.destinationPathForBinding(destination)
            let components = bindingDestination.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard let leaf = components.last,
                  !leaf.isEmpty,
                  leaf != ".",
                  leaf != "..",
                  !leaf.contains("/"),
                  !leaf.contains("\\") else {
                throw ExtractionError.extractionRootUnavailable
            }

            var current = Darwin.open(
                "/",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard current >= 0 else { throw ExtractionError.extractionRootUnavailable }

            do {
                for component in components.dropLast() {
                    var named = stat()
                    let result = component.withCString {
                        Darwin.fstatat(current, $0, &named, AT_SYMLINK_NOFOLLOW)
                    }
                    let child: Int32
                    let namedIdentity: ZipArchiveReader.FileIdentity
                    if result != 0 {
                        guard errno == ENOENT else {
                            throw ExtractionError.extractionRootUnavailable
                        }
                        let createdDirectory = try SafeArchiveExtractor
                            .createAndPublishDirectory(
                                parentDescriptor: current,
                                intendedName: component,
                                failure: .extractionRootUnavailable,
                                publicationObserver: publicationObserver
                            )
                        child = createdDirectory.descriptor
                        namedIdentity = createdDirectory.identity
                    } else {
                        guard (named.st_mode & S_IFMT) == S_IFDIR else {
                            throw ExtractionError.extractionRootUnavailable
                        }
                        namedIdentity = ZipArchiveReader.FileIdentity(named)
                        child = component.withCString {
                            Darwin.openat(
                                current,
                                $0,
                                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                            )
                        }
                        guard child >= 0 else {
                            throw ExtractionError.extractionRootUnavailable
                        }
                        var opened = stat()
                        var rebound = stat()
                        let validBinding = Darwin.fstat(child, &opened) == 0
                            && (opened.st_mode & S_IFMT) == S_IFDIR
                            && namedIdentity.matches(opened)
                            && component.withCString({
                                Darwin.fstatat(
                                    current,
                                    $0,
                                    &rebound,
                                    AT_SYMLINK_NOFOLLOW
                                )
                            }) == 0
                            && namedIdentity.matches(rebound)
                        guard validBinding else {
                            Darwin.close(child)
                            throw ExtractionError.extractionRootUnavailable
                        }
                    }
                    Darwin.close(current)
                    current = child
                }
                return (current, leaf)
            } catch {
                Darwin.close(current)
                throw error
            }
        }
    }

    // MARK: - Post-extraction inventory

    private static func boundInventory(
        rootDescriptor: Int32,
        bindings: ExtractionBindings,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> Inventory {
        var entries: [Inventory.Entry] = []
        let root = try makeBoundInventoryFrame(
            descriptor: rootDescriptor,
            binding: bindings.root,
            pathComponents: [],
            closesDescriptor: false,
            parentDescriptor: nil,
            parentLeaf: nil,
            expectedIdentity: nil
        )
        var stack = [root]
        do {
            while let frame = stack.last {
                try throwIfCancelled(shouldCancel)
                if frame.nextNameIndex == frame.names.count {
                    guard frame.remainingFiles.isEmpty,
                          frame.remainingDirectories.isEmpty else {
                        throw ExtractionError.extractionFailed
                    }
                    var finalStatus = stat()
                    guard Darwin.fstat(frame.descriptor, &finalStatus) == 0,
                          stableDirectoryStatus(frame.initialStatus, finalStatus) else {
                        throw ExtractionError.extractionFailed
                    }
                    if let parentDescriptor = frame.parentDescriptor,
                       let parentLeaf = frame.parentLeaf,
                       let expectedIdentity = frame.expectedIdentity {
                        var finalNamed = stat()
                        guard parentLeaf.withCString({
                            Darwin.fstatat(
                                parentDescriptor,
                                $0,
                                &finalNamed,
                                AT_SYMLINK_NOFOLLOW
                            )
                        }) == 0,
                              expectedIdentity.matches(finalStatus),
                              stableDirectoryStatus(finalStatus, finalNamed) else {
                            throw ExtractionError.extractionFailed
                        }
                    }
                    _ = stack.popLast()
                    if frame.closesDescriptor { Darwin.close(frame.descriptor) }
                    continue
                }

                let name = frame.names[frame.nextNameIndex]
                frame.nextNameIndex += 1
                let pathComponents = frame.pathComponents + [name]
                guard pathComponents.count <= maximumTraversalDepth else {
                    throw ExtractionError.extractionFailed
                }
                if let file = frame.binding.files[name] {
                    guard frame.remainingFiles.remove(name) != nil else {
                        throw ExtractionError.extractionFailed
                    }
                    try verifyBoundFile(
                        directoryDescriptor: frame.descriptor,
                        leafName: name,
                        expected: file,
                        shouldCancel: shouldCancel
                    )
                    entries.append(Inventory.Entry(
                        relativePath: pathComponents.joined(separator: "/"),
                        byteCount: file.byteCount
                    ))
                    continue
                }

                guard let childBinding = frame.binding.children[name],
                      frame.remainingDirectories.remove(name) != nil,
                      let expectedIdentity = childBinding.identity else {
                    throw ExtractionError.extractionFailed
                }
                var namedStatus = stat()
                guard name.withCString({
                    Darwin.fstatat(
                        frame.descriptor,
                        $0,
                        &namedStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }) == 0,
                      (namedStatus.st_mode & S_IFMT) == S_IFDIR,
                      (namedStatus.st_mode & 0o7777) == mode_t(S_IRWXU),
                      expectedIdentity.matches(namedStatus) else {
                    throw ExtractionError.extractionFailed
                }
                let child = name.withCString {
                    Darwin.openat(
                        frame.descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else { throw ExtractionError.extractionFailed }
                var openedStatus = stat()
                var reboundStatus = stat()
                guard Darwin.fstat(child, &openedStatus) == 0,
                      expectedIdentity.matches(openedStatus),
                      (openedStatus.st_mode & 0o7777) == mode_t(S_IRWXU),
                      name.withCString({
                          Darwin.fstatat(
                              frame.descriptor,
                              $0,
                              &reboundStatus,
                              AT_SYMLINK_NOFOLLOW
                          )
                      }) == 0,
                      expectedIdentity.matches(reboundStatus),
                      (reboundStatus.st_mode & 0o7777) == mode_t(S_IRWXU) else {
                    Darwin.close(child)
                    throw ExtractionError.extractionFailed
                }
                do {
                    stack.append(try makeBoundInventoryFrame(
                        descriptor: child,
                        binding: childBinding,
                        pathComponents: pathComponents,
                        closesDescriptor: true,
                        parentDescriptor: frame.descriptor,
                        parentLeaf: name,
                        expectedIdentity: expectedIdentity
                    ))
                } catch {
                    Darwin.close(child)
                    throw error
                }
            }
        } catch {
            for frame in stack where frame.closesDescriptor {
                Darwin.close(frame.descriptor)
            }
            throw error
        }
        entries.sort { $0.relativePath < $1.relativePath }
        return Inventory(entries: entries)
    }

    private final class BoundInventoryFrame {
        let descriptor: Int32
        let closesDescriptor: Bool
        let binding: DirectoryBindingNode
        let pathComponents: [String]
        let names: [String]
        let initialStatus: stat
        let parentDescriptor: Int32?
        let parentLeaf: String?
        let expectedIdentity: ZipArchiveReader.FileIdentity?
        var nextNameIndex = 0
        var remainingFiles: Set<String>
        var remainingDirectories: Set<String>

        init(
            descriptor: Int32,
            closesDescriptor: Bool,
            binding: DirectoryBindingNode,
            pathComponents: [String],
            names: [String],
            initialStatus: stat,
            parentDescriptor: Int32?,
            parentLeaf: String?,
            expectedIdentity: ZipArchiveReader.FileIdentity?
        ) {
            self.descriptor = descriptor
            self.closesDescriptor = closesDescriptor
            self.binding = binding
            self.pathComponents = pathComponents
            self.names = names
            self.initialStatus = initialStatus
            self.parentDescriptor = parentDescriptor
            self.parentLeaf = parentLeaf
            self.expectedIdentity = expectedIdentity
            remainingFiles = Set(binding.files.keys)
            remainingDirectories = Set(binding.children.keys)
        }
    }

    private static func makeBoundInventoryFrame(
        descriptor: Int32,
        binding: DirectoryBindingNode,
        pathComponents: [String],
        closesDescriptor: Bool,
        parentDescriptor: Int32?,
        parentLeaf: String?,
        expectedIdentity: ZipArchiveReader.FileIdentity?
    ) throws -> BoundInventoryFrame {
        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFDIR,
              (initialStatus.st_mode & 0o7777) == mode_t(S_IRWXU) else {
            throw ExtractionError.extractionFailed
        }
        let expectedCount = binding.files.count.addingReportingOverflow(binding.children.count)
        guard !expectedCount.overflow else { throw ExtractionError.extractionFailed }
        let names = try directoryEntryNames(
            descriptor: descriptor,
            maximumCount: expectedCount.partialValue
        )
        return BoundInventoryFrame(
            descriptor: descriptor,
            closesDescriptor: closesDescriptor,
            binding: binding,
            pathComponents: pathComponents,
            names: names,
            initialStatus: initialStatus,
            parentDescriptor: parentDescriptor,
            parentLeaf: parentLeaf,
            expectedIdentity: expectedIdentity
        )
    }

    private static func directoryEntryNames(
        descriptor: Int32,
        maximumCount: Int
    ) throws -> [String] {
        let enumerationDescriptor = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else { throw ExtractionError.enumerationFailed }
        guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw ExtractionError.enumerationFailed
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else { throw ExtractionError.enumerationFailed }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < maximumCount else {
                throw ExtractionError.extractionFailed
            }
            names.append(name)
        }
        names.sort()
        return names
    }

    private static func verifyBoundFile(
        directoryDescriptor: Int32,
        leafName: String,
        expected: ZipArchiveReader.ExtractedFile,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        var namedStatus = stat()
        guard leafName.withCString({
            Darwin.fstatat(directoryDescriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              expected.matchesStableStatus(namedStatus) else {
            throw ExtractionError.extractionFailed
        }
        let descriptor = leafName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw ExtractionError.extractionFailed }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              expected.matchesStableStatus(openedStatus) else {
            throw ExtractionError.extractionFailed
        }
        var hasher = SHA256()
        var offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < expected.byteCount {
            try throwIfCancelled(shouldCancel)
            let requested = min(buffer.count, Int(expected.byteCount - offset))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress, requested, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ExtractionError.extractionFailed }
            hasher.update(data: Data(buffer[0..<count]))
            offset += UInt64(count)
        }

        var finalOpenedStatus = stat()
        var finalNamedStatus = stat()
        guard offset == expected.byteCount,
              Data(hasher.finalize()) == expected.sha256,
              Darwin.fstat(descriptor, &finalOpenedStatus) == 0,
              expected.matchesStableStatus(finalOpenedStatus),
              leafName.withCString({
                  Darwin.fstatat(
                      directoryDescriptor,
                      $0,
                      &finalNamedStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              expected.matchesStableStatus(finalNamedStatus) else {
            throw ExtractionError.extractionFailed
        }
    }

    private static func stableDirectoryStatus(_ first: stat, _ second: stat) -> Bool {
        (first.st_mode & S_IFMT) == S_IFDIR
            && (second.st_mode & S_IFMT) == S_IFDIR
            && first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_nlink == second.st_nlink
            && (first.st_mode & 0o7777) == (second.st_mode & 0o7777)
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    static func inventory(of root: URL) throws -> Inventory {
        let bindingRoot = try destinationPathForBinding(root)
        let descriptor = Darwin.open(
            bindingRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ExtractionError.enumerationFailed
        }
        defer { Darwin.close(descriptor) }

        var entries: [Inventory.Entry] = []
        var components: [String] = []
        var remainingNodes = ExtractionLimits.default.maxEntryCount
        try collectDescriptorInventory(
            descriptor: descriptor,
            components: &components,
            entries: &entries,
            remainingNodes: &remainingNodes
        )
        entries.sort { $0.relativePath < $1.relativePath }
        return Inventory(entries: entries)
    }

    private static func collectDescriptorInventory(
        descriptor: Int32,
        components: inout [String],
        entries: inout [Inventory.Entry],
        remainingNodes: inout Int
    ) throws {
        var initialDirectoryStatus = stat()
        guard Darwin.fstat(descriptor, &initialDirectoryStatus) == 0,
              (initialDirectoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw ExtractionError.enumerationFailed
        }
        let names = try directoryEntryNames(
            descriptor: descriptor,
            maximumCount: remainingNodes
        )
        for name in names {
            guard remainingNodes > 0 else { throw ExtractionError.enumerationFailed }
            remainingNodes -= 1
            components.append(name)
            defer { components.removeLast() }
            let relativePath = components.joined(separator: "/")
            var namedStatus = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw ExtractionError.enumerationFailed
            }

            switch namedStatus.st_mode & S_IFMT {
            case S_IFLNK:
                throw ExtractionError.extractedSymbolicLink(relativePath)
            case S_IFDIR:
                let identity = ZipArchiveReader.FileIdentity(namedStatus)
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else { throw ExtractionError.enumerationFailed }
                do {
                    var openedStatus = stat()
                    var reboundStatus = stat()
                    guard Darwin.fstat(child, &openedStatus) == 0,
                          identity.matches(openedStatus),
                          name.withCString({
                              Darwin.fstatat(
                                  descriptor,
                                  $0,
                                  &reboundStatus,
                                  AT_SYMLINK_NOFOLLOW
                              )
                          }) == 0,
                          identity.matches(reboundStatus) else {
                        throw ExtractionError.enumerationFailed
                    }
                    try collectDescriptorInventory(
                        descriptor: child,
                        components: &components,
                        entries: &entries,
                        remainingNodes: &remainingNodes
                    )
                    var finalOpenedStatus = stat()
                    var finalNamedStatus = stat()
                    guard Darwin.fstat(child, &finalOpenedStatus) == 0,
                          stableDirectoryStatus(openedStatus, finalOpenedStatus),
                          name.withCString({
                              Darwin.fstatat(
                                  descriptor,
                                  $0,
                                  &finalNamedStatus,
                                  AT_SYMLINK_NOFOLLOW
                              )
                          }) == 0,
                          stableDirectoryStatus(finalOpenedStatus, finalNamedStatus) else {
                        throw ExtractionError.enumerationFailed
                    }
                } catch {
                    Darwin.close(child)
                    throw error
                }
                Darwin.close(child)
            case S_IFREG:
                let identity = ZipArchiveReader.FileIdentity(namedStatus)
                let file = name.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard file >= 0 else { throw ExtractionError.enumerationFailed }
                defer { Darwin.close(file) }
                var openedStatus = stat()
                var reboundStatus = stat()
                guard namedStatus.st_size >= 0,
                      Darwin.fstat(file, &openedStatus) == 0,
                      stableRegularStatus(namedStatus, openedStatus),
                      identity.matches(openedStatus),
                      name.withCString({
                          Darwin.fstatat(
                              descriptor,
                              $0,
                              &reboundStatus,
                              AT_SYMLINK_NOFOLLOW
                          )
                      }) == 0,
                      stableRegularStatus(openedStatus, reboundStatus) else {
                    throw ExtractionError.enumerationFailed
                }
                entries.append(Inventory.Entry(
                    relativePath: relativePath,
                    byteCount: UInt64(namedStatus.st_size)
                ))
            default:
                throw ExtractionError.foreignFileType(relativePath)
            }
        }
        var finalDirectoryStatus = stat()
        guard Darwin.fstat(descriptor, &finalDirectoryStatus) == 0,
              stableDirectoryStatus(initialDirectoryStatus, finalDirectoryStatus) else {
            throw ExtractionError.enumerationFailed
        }
    }

    private static func stableRegularStatus(_ first: stat, _ second: stat) -> Bool {
        (first.st_mode & S_IFMT) == S_IFREG
            && (second.st_mode & S_IFMT) == S_IFREG
            && first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_size == second.st_size
            && first.st_nlink == second.st_nlink
            && (first.st_mode & 0o7777) == (second.st_mode & 0o7777)
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func throwIfCancelled(
        _ shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        if shouldCancel() { throw CancellationError() }
    }
}
