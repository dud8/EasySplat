import Foundation

/// Extracts untrusted ZIP archives (for example Polycam exports) into a destination
/// directory after validating them against a set of size and shape limits.
///
/// The archive is inspected name-only before a single byte is written to disk: entries
/// that are symbolic links, special files, absolute paths, path-traversal attempts, or
/// case-insensitive collisions are rejected, and per-entry, aggregate, and entry-count
/// limits are enforced from the ZIP central directory. After `/usr/bin/unzip` runs, the
/// destination is walked to confirm that only regular files and directories landed.
///
/// The name-only path validation and the archive listing mechanics are shared verbatim
/// with the toolchain download path (`ToolchainManager`), which delegates its own
/// hardened unzip to the same primitives so the two cannot drift apart.
public enum SafeArchiveExtractor {

    /// Ceilings applied to an untrusted archive before and after extraction.
    public struct ExtractionLimits: Sendable, Equatable {
        /// Maximum number of entries the archive may declare.
        public var maxEntryCount: Int
        /// Maximum uncompressed size of any single entry, in bytes.
        public var maxEntryUncompressedBytes: UInt64
        /// Maximum uncompressed size of the whole archive, in bytes.
        public var maxTotalUncompressedBytes: UInt64

        public init(
            maxEntryCount: Int,
            maxEntryUncompressedBytes: UInt64,
            maxTotalUncompressedBytes: UInt64
        ) {
            self.maxEntryCount = maxEntryCount
            self.maxEntryUncompressedBytes = maxEntryUncompressedBytes
            self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
        }

        /// A generous general-purpose profile for photo/dataset archives.
        public static let `default` = ExtractionLimits(
            maxEntryCount: 100_000,
            maxEntryUncompressedBytes: 2 * 1024 * 1024 * 1024,
            maxTotalUncompressedBytes: 16 * 1024 * 1024 * 1024
        )
    }

    /// The regular files that an extraction produced, sorted by relative path.
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

        /// The summed logical size of every extracted regular file.
        public var totalBytes: UInt64 {
            entries.reduce(UInt64.zero) { partial, entry in
                let sum = partial.addingReportingOverflow(entry.byteCount)
                return sum.overflow ? UInt64.max : sum.partialValue
            }
        }
    }

    /// Failures raised while validating or extracting an untrusted archive.
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
        case entryCountExceeded(limit: Int)
        case archiveListingTooLarge
        case entryTooLarge(path: String, bytes: UInt64, limit: UInt64)
        case totalSizeExceeded(bytes: UInt64, limit: UInt64)
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
            case .entryCountExceeded(let limit):
                return "The archive contains more than \(limit) entries."
            case .archiveListingTooLarge:
                return "The archive entry listing is too large to inspect safely."
            case .entryTooLarge(let path, let bytes, let limit):
                return "The archive entry \(path) expands to \(bytes) bytes, exceeding the \(limit)-byte per-entry limit."
            case .totalSizeExceeded(let bytes, let limit):
                return "The archive expands to \(bytes) bytes, exceeding the \(limit)-byte total limit."
            case .enumerationFailed:
                return "The extracted archive could not be enumerated."
            case .extractedSymbolicLink(let path):
                return "The extracted archive produced a symbolic link, which is not allowed: \(path)."
            case .foreignFileType(let path):
                return "The extracted archive produced an entry that is neither a regular file nor a directory: \(path)."
            }
        }
    }

    /// Upper bound on the raw `unzip -Z1` name listing text, guarding the inspector
    /// against archives whose entry names alone would exhaust memory.
    static let listingByteBudget = 128 * 1024 * 1024

    /// Validate and extract `zipURL` into `destination`, returning the regular files that landed.
    ///
    /// Nothing is written to disk until the archive has passed every name-only and size check.
    @discardableResult
    public static func extract(
        zipURL: URL,
        to destination: URL,
        limits: ExtractionLimits = .default,
        runner: SubprocessRunning
    ) throws -> Inventory {
        let listing = try listArchive(
            zipURL: zipURL,
            runner: runner,
            maximumListingBytes: listingByteBudget,
            maximumEntryCount: limits.maxEntryCount
        )

        switch listing.breach {
        case .entryCount:
            throw ExtractionError.entryCountExceeded(limit: limits.maxEntryCount)
        case .byteBudget:
            throw ExtractionError.archiveListingTooLarge
        case .none:
            break
        }

        try validateEntryPaths(listing.names, allowingDirectoryEntries: true)
        try rejectCaseInsensitiveCollisions(listing.names)

        if listing.largestEntryBytes > limits.maxEntryUncompressedBytes {
            throw ExtractionError.entryTooLarge(
                path: listing.largestEntryName,
                bytes: listing.largestEntryBytes,
                limit: limits.maxEntryUncompressedBytes
            )
        }

        if listing.totalOverflowed || listing.totalUncompressedBytes > limits.maxTotalUncompressedBytes {
            throw ExtractionError.totalSizeExceeded(
                bytes: listing.totalOverflowed ? UInt64.max : listing.totalUncompressedBytes,
                limit: limits.maxTotalUncompressedBytes
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } catch {
            throw ExtractionError.extractionRootUnavailable
        }

        let result = try runner.run("/usr/bin/unzip", ["-o", zipURL.path, "-d", destination.path])
        guard result.exitCode == 0 else {
            throw ExtractionError.extractionFailed
        }

        return try inventory(of: destination)
    }

    // MARK: - Shared name-only validation

    /// Reject entry paths that are empty, absolute, contain backslashes or NUL bytes, or use
    /// `.`/`..`/empty path components, and reject exact duplicates.
    ///
    /// Shared verbatim with `ToolchainManager.validateArchiveEntries`; the toolchain maps the
    /// thrown `ExtractionError` back onto its own `ToolchainError` messages.
    /// `allowingDirectoryEntries` tolerates the trailing-slash directory
    /// markers real zip listings contain (user-supplied dataset archives).
    /// The toolchain's release archives are built flat, so its path keeps
    /// the strict default and continues to treat directory entries as
    /// malformed.
    static func validateEntryPaths(_ entries: [String], allowingDirectoryEntries: Bool = false) throws {
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
            guard parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else {
                throw ExtractionError.pathTraversal(entry)
            }
        }
    }

    /// Reject entries whose paths differ only by case, which a case-insensitive file system
    /// (such as APFS) would otherwise silently merge.
    static func rejectCaseInsensitiveCollisions(_ entries: [String]) throws {
        var folded: [String: String] = [:]
        folded.reserveCapacity(entries.count)
        for entry in entries {
            let key = entry.lowercased()
            if let existing = folded[key], existing != entry {
                throw ExtractionError.caseInsensitiveCollision(existing, entry)
            }
            folded[key] = entry
        }
    }

    // MARK: - Shared archive listing

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
    }

    /// List an archive name-only via `zipinfo -l` (types and uncompressed sizes) and
    /// `unzip -Z1` (entry names), rejecting symbolic links and special files before names
    /// are even collected.
    ///
    /// Shared with `ToolchainManager.inspectArchiveEntries`.
    static func listArchive(
        zipURL: URL,
        runner: SubprocessRunning,
        maximumListingBytes: Int,
        maximumEntryCount: Int
    ) throws -> ArchiveListing {
        let accumulator = ArchiveListingAccumulator(
            maximumListingBytes: maximumListingBytes,
            maximumEntryCount: maximumEntryCount
        )

        let metadata = try runner.run(
            "/usr/bin/zipinfo",
            ["-l", zipURL.path],
            onStdout: accumulator.inspectMetadataLine
        )
        guard metadata.exitCode == 0 else {
            throw ExtractionError.listingFailed
        }
        if accumulator.foundSymbolicLink() {
            throw ExtractionError.symbolicLinkEntry
        }
        if accumulator.foundSpecialFile() {
            throw ExtractionError.specialFileEntry
        }

        let names = try runner.run(
            "/usr/bin/unzip",
            ["-Z1", zipURL.path],
            onStdout: accumulator.appendEntry
        )
        guard names.exitCode == 0 else {
            throw ExtractionError.listingFailed
        }

        return accumulator.snapshot()
    }

    // MARK: - Post-extraction inventory

    /// Walk the extraction destination, rejecting any symbolic link or special file, and
    /// return the regular files that landed with their logical byte counts.
    static func inventory(of root: URL) throws -> Inventory {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileResourceTypeKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ExtractionError.enumerationFailed
        }

        var entries: [Inventory.Entry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isSymbolicLinkKey, .fileResourceTypeKey, .fileSizeKey]
            )
            if values?.isSymbolicLink == true {
                throw ExtractionError.extractedSymbolicLink(relativePath(of: url, under: root))
            }
            switch values?.fileResourceType {
            case .some(.directory):
                continue
            case .some(.regular):
                let bytes = UInt64(max(0, values?.fileSize ?? 0))
                entries.append(
                    Inventory.Entry(relativePath: relativePath(of: url, under: root), byteCount: bytes)
                )
            default:
                throw ExtractionError.foreignFileType(relativePath(of: url, under: root))
            }
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return Inventory(entries: entries)
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

/// Streaming accumulator for the two subprocess passes an archive listing performs.
///
/// `inspectMetadataLine` consumes `zipinfo -l` output to detect symbolic links and special
/// files and to sum uncompressed sizes; `appendEntry` consumes `unzip -Z1` output to collect
/// entry names under a memory budget.
final class ArchiveListingAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumListingBytes: Int
    private let maximumEntryCount: Int

    private var names: [String] = []
    private var listingBytes = 0
    private var breach: SafeArchiveExtractor.ListingLimitBreach = .none

    private var containsSymbolicLink = false
    private var containsSpecialFile = false
    private var totalUncompressedBytes: UInt64 = 0
    private var totalOverflowed = false
    private var largestEntryName = ""
    private var largestEntryBytes: UInt64 = 0

    init(maximumListingBytes: Int, maximumEntryCount: Int) {
        self.maximumListingBytes = maximumListingBytes
        self.maximumEntryCount = maximumEntryCount
    }

    func inspectMetadataLine(_ line: String) {
        guard let type = line.first else { return }
        lock.lock()
        defer { lock.unlock() }
        if type == "l" {
            containsSymbolicLink = true
        } else if type == "b" || type == "c" || type == "p" || type == "s" {
            containsSpecialFile = true
        }

        // Only long-format entry rows carry an uncompressed size. Header and footer lines
        // ("Archive:", "Zip file size:", "N files, ...") never begin with a mode character.
        guard "-dlbcps".contains(type) else { return }
        let fields = line.split(separator: " ")
        guard fields.count >= 10,
              fields[0].count == 10,
              let bytes = UInt64(fields[3]) else {
            return
        }

        let sum = totalUncompressedBytes.addingReportingOverflow(bytes)
        if sum.overflow {
            totalOverflowed = true
        } else {
            totalUncompressedBytes = sum.partialValue
        }
        if bytes > largestEntryBytes {
            largestEntryBytes = bytes
            largestEntryName = fields[9...].joined(separator: " ")
        }
    }

    func appendEntry(_ entry: String) {
        guard !entry.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard breach == .none else { return }
        guard names.count < maximumEntryCount else {
            breach = .entryCount
            return
        }
        let addedBytes = entry.utf8.count.addingReportingOverflow(1)
        let nextBytes = listingBytes.addingReportingOverflow(addedBytes.partialValue)
        guard !addedBytes.overflow,
              !nextBytes.overflow,
              nextBytes.partialValue <= maximumListingBytes else {
            breach = .byteBudget
            return
        }
        names.append(entry)
        listingBytes = nextBytes.partialValue
    }

    func foundSymbolicLink() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return containsSymbolicLink
    }

    func foundSpecialFile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return containsSpecialFile
    }

    func snapshot() -> SafeArchiveExtractor.ArchiveListing {
        lock.lock()
        defer { lock.unlock() }
        return SafeArchiveExtractor.ArchiveListing(
            names: names,
            breach: breach,
            containsSymbolicLink: containsSymbolicLink,
            containsSpecialFile: containsSpecialFile,
            totalUncompressedBytes: totalUncompressedBytes,
            totalOverflowed: totalOverflowed,
            largestEntryName: largestEntryName,
            largestEntryBytes: largestEntryBytes
        )
    }
}
