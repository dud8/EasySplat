import Darwin
import Foundation
import SQLite3

enum ColmapSQLiteDatabaseHandleError: Error, Equatable {
    case unsafeDatabaseFile
    case openFailed(code: Int32, message: String)
    case verificationFailed(code: Int32, message: String)
}

final class ColmapSQLiteDatabaseHandle {
    let database: OpaquePointer

    private let sourceParentURL: URL
    private let sourceParentIdentity: FileIdentity
    private let canonicalParentURL: URL
    private let canonicalParentIdentity: FileIdentity
    private let databaseURL: URL
    private let databaseIdentity: FileIdentity
    private let databaseSnapshotIdentity: FileSnapshotIdentity?
    private let requiresAbsentSidecars: Bool

    private init(
        database: OpaquePointer,
        sourceParentURL: URL,
        sourceParentIdentity: FileIdentity,
        canonicalParentURL: URL,
        canonicalParentIdentity: FileIdentity,
        databaseURL: URL,
        databaseIdentity: FileIdentity,
        databaseSnapshotIdentity: FileSnapshotIdentity?,
        requiresAbsentSidecars: Bool
    ) {
        self.database = database
        self.sourceParentURL = sourceParentURL
        self.sourceParentIdentity = sourceParentIdentity
        self.canonicalParentURL = canonicalParentURL
        self.canonicalParentIdentity = canonicalParentIdentity
        self.databaseURL = databaseURL
        self.databaseIdentity = databaseIdentity
        self.databaseSnapshotIdentity = databaseSnapshotIdentity
        self.requiresAbsentSidecars = requiresAbsentSidecars
    }

    deinit {
        sqlite3_close(database)
    }

    static func open(at sourceURL: URL, flags: Int32) throws -> ColmapSQLiteDatabaseHandle {
        guard sourceURL.isFileURL,
              !sourceURL.lastPathComponent.isEmpty else {
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }

        let sourceParentURL = sourceURL
            .standardizedFileURL
            .deletingLastPathComponent()
        let sourceParentMetadata = try metadata(
            at: sourceParentURL,
            expectedType: S_IFDIR,
            requireSingleLink: false
        )
        guard let canonicalValues = try? sourceParentURL.resourceValues(
            forKeys: [.canonicalPathKey]
        ), let canonicalParentPath = canonicalValues.canonicalPath else {
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }
        let canonicalParentURL = URL(
            fileURLWithPath: canonicalParentPath,
            isDirectory: true
        )
        let canonicalParentMetadata = try metadata(
            at: canonicalParentURL,
            expectedType: S_IFDIR,
            requireSingleLink: false
        )
        let sourceParentIdentity = FileIdentity(sourceParentMetadata)
        let canonicalParentIdentity = FileIdentity(canonicalParentMetadata)
        guard sourceParentIdentity == canonicalParentIdentity else {
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }

        let databaseURL = canonicalParentURL.appendingPathComponent(
            sourceURL.lastPathComponent,
            isDirectory: false
        )
        let databaseMetadata = try metadata(
            at: databaseURL,
            expectedType: S_IFREG,
            requireSingleLink: true
        )
        let databaseIdentity = FileIdentity(databaseMetadata)

        let isReadOnlySnapshot = flags & SQLITE_OPEN_READONLY != 0
            && flags & SQLITE_OPEN_READWRITE == 0
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let sharedMemoryURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        let hasWALSidecar = try optionalRegularFileMetadata(at: walURL) != nil
        let hasSharedMemorySidecar = try optionalRegularFileMetadata(at: sharedMemoryURL) != nil
        // A clean WAL database can retain its WAL header after SQLite removes both
        // sidecars. Immutable mode reads that stable main-file snapshot without
        // creating files; verifyUnchanged binds the snapshot before and after use.
        let useImmutableSnapshot = isReadOnlySnapshot
            && !hasWALSidecar
            && !hasSharedMemorySidecar

        let openPath: String
        var openFlags = flags | SQLITE_OPEN_NOFOLLOW
        if useImmutableSnapshot {
            openPath = databaseURL.absoluteString + "?immutable=1"
            openFlags |= SQLITE_OPEN_URI
        } else {
            openPath = databaseURL.path
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            openPath,
            &database,
            openFlags,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw ColmapSQLiteDatabaseHandleError.openFailed(
                code: openResult,
                message: message
            )
        }

        let handle = ColmapSQLiteDatabaseHandle(
            database: database,
            sourceParentURL: sourceParentURL,
            sourceParentIdentity: sourceParentIdentity,
            canonicalParentURL: canonicalParentURL,
            canonicalParentIdentity: canonicalParentIdentity,
            databaseURL: databaseURL,
            databaseIdentity: databaseIdentity,
            databaseSnapshotIdentity: isReadOnlySnapshot
                ? FileSnapshotIdentity(databaseMetadata)
                : nil,
            requiresAbsentSidecars: useImmutableSnapshot
        )
        try handle.verifyUnchanged()
        return handle
    }

    func verifyUnchanged() throws {
        let sourceParent = try Self.metadata(
            at: sourceParentURL,
            expectedType: S_IFDIR,
            requireSingleLink: false
        )
        let canonicalParent = try Self.metadata(
            at: canonicalParentURL,
            expectedType: S_IFDIR,
            requireSingleLink: false
        )
        let databaseMetadata = try Self.metadata(
            at: databaseURL,
            expectedType: S_IFREG,
            requireSingleLink: true
        )
        let matchesSnapshot = databaseSnapshotIdentity.map {
            FileSnapshotIdentity(databaseMetadata) == $0
        } ?? true
        if requiresAbsentSidecars {
            let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
            let sharedMemoryURL = URL(fileURLWithPath: databaseURL.path + "-shm")
            guard try Self.optionalRegularFileMetadata(at: walURL) == nil,
                  try Self.optionalRegularFileMetadata(at: sharedMemoryURL) == nil else {
                throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
            }
        }
        guard FileIdentity(sourceParent) == sourceParentIdentity,
              FileIdentity(canonicalParent) == canonicalParentIdentity,
              FileIdentity(databaseMetadata) == databaseIdentity,
              matchesSnapshot else {
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }

        // Confirm that SQLite's open descriptor still names the inode validated above.
        var hasMoved: Int32 = 0
        let result = sqlite3_file_control(
            database,
            "main",
            SQLITE_FCNTL_HAS_MOVED,
            &hasMoved
        )
        guard result == SQLITE_OK else {
            throw ColmapSQLiteDatabaseHandleError.verificationFailed(
                code: result,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        guard hasMoved == 0 else {
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }
    }

    private static func metadata(
        at url: URL,
        expectedType: mode_t,
        requireSingleLink: Bool
    ) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == expectedType,
              !requireSingleLink || metadata.st_nlink == 1 else {
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }
        return metadata
    }

    private static func optionalRegularFileMetadata(at url: URL) throws -> stat? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw ColmapSQLiteDatabaseHandleError.unsafeDatabaseFile
        }
        return metadata
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
        }
    }

    private struct FileSnapshotIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            size = metadata.st_size
            modificationSeconds = metadata.st_mtimespec.tv_sec
            modificationNanoseconds = metadata.st_mtimespec.tv_nsec
            changeSeconds = metadata.st_ctimespec.tv_sec
            changeNanoseconds = metadata.st_ctimespec.tv_nsec
        }
    }
}
