import CryptoKit
import Darwin
import Foundation

package enum ProjectRunLeaseError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case unsafeProject
    case system(operation: String, code: Int32)

    package var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "This project is already being processed."
        case .unsafeProject:
            return "The selected project directory is not safe to process."
        case .system(let operation, let code):
            return "Could not \(operation) (POSIX \(code))."
        }
    }
}

/// Holds complementary nonblocking locks for one complete pipeline attempt:
/// locks for every stable logical/physical project location and a lock on the
/// exact project-directory inode. Each location lock is duplicated beneath the
/// registry parent, so replacing the registry or an inner lock file cannot split
/// cooperative EasySplat processes onto different lock inodes.
///
/// A process with the same user ID can unlink and replace the registry parent,
/// every anchor, and the registry as one hostile operation. No pathname-based
/// advisory-lock protocol can exclude that actor without a privileged broker.
/// EasySplat instead validates every retained binding before and after work and
/// fails the original lease closed if any part of that hierarchy changes.
package final class ProjectRunLease: @unchecked Sendable {
    private static let registryDirectoryName = ".easysplat-run-leases"
    private static let registryMode = mode_t(0o700)
    private static let leaseMode = mode_t(0o600)
    private static let permissionMask = mode_t(0o7777)

    private let stateLock = NSLock()
    private var registryParentDescriptor: Int32
    private var registryDescriptor: Int32
    private var anchorDescriptors: [Int32]
    private var leaseDescriptors: [Int32]
    private var projectDescriptor: Int32
    private var invalidated = false
    private var releaseRequested = false
    private var activeDescriptorLoans = 0
    private var processClaimsHeld = true
    private let registryLeaf: String
    private let anchorLeafs: [String]
    private let leaseLeafs: [String]
    private let suppliedProjectPath: String
    private let canonicalProjectPath: String
    private let suppliedRegistryParentPath: String
    private let canonicalRegistryParentPath: String
    private let processClaimKeys: [String]

    private static let processClaims = ProcessClaimRegistry()

    private init(
        registryParentDescriptor: Int32,
        registryDescriptor: Int32,
        anchorDescriptors: [Int32],
        leaseDescriptors: [Int32],
        projectDescriptor: Int32,
        registryLeaf: String,
        anchorLeafs: [String],
        leaseLeafs: [String],
        suppliedProjectPath: String,
        canonicalProjectPath: String,
        suppliedRegistryParentPath: String,
        canonicalRegistryParentPath: String,
        processClaimKeys: [String]
    ) {
        self.registryParentDescriptor = registryParentDescriptor
        self.registryDescriptor = registryDescriptor
        self.anchorDescriptors = anchorDescriptors
        self.leaseDescriptors = leaseDescriptors
        self.projectDescriptor = projectDescriptor
        self.registryLeaf = registryLeaf
        self.anchorLeafs = anchorLeafs
        self.leaseLeafs = leaseLeafs
        self.suppliedProjectPath = suppliedProjectPath
        self.canonicalProjectPath = canonicalProjectPath
        self.suppliedRegistryParentPath = suppliedRegistryParentPath
        self.canonicalRegistryParentPath = canonicalRegistryParentPath
        self.processClaimKeys = processClaimKeys
    }

    deinit {
        release()
    }

    package static func acquire(projectURL: URL) throws -> ProjectRunLease {
        try acquire(
            projectURL: projectURL,
            registryURL: defaultRegistryURL()
        )
    }

    package static func acquire(
        projectURL: URL,
        registryURL: URL
    ) throws -> ProjectRunLease {
        try validateAbsoluteFileURL(projectURL)
        try validateAbsoluteFileURL(registryURL)

        let suppliedProjectPath = projectURL.path
        let projectDescriptor = Darwin.open(
            suppliedProjectPath,
            O_RDONLY
                | O_DIRECTORY
                | O_NOFOLLOW
                | O_CLOEXEC
                | O_EXLOCK
                | O_NONBLOCK
        )
        guard projectDescriptor >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ProjectRunLeaseError.alreadyRunning
            }
            throw mappedSystemError(
                operation: "lock the project for processing",
                code: errno
            )
        }
        var keepProject = false
        defer {
            if !keepProject {
                Darwin.close(projectDescriptor)
            }
        }

        try validateProjectBinding(
            descriptor: projectDescriptor,
            path: suppliedProjectPath
        )
        let canonicalProjectPath = try kernelCanonicalPath(
            descriptor: projectDescriptor
        )
        try validateProjectBinding(
            descriptor: projectDescriptor,
            path: canonicalProjectPath
        )
        let projectLocationKeys = try locationKeys(
            suppliedPath: suppliedProjectPath,
            canonicalPath: canonicalProjectPath,
            descriptor: projectDescriptor
        )

        let registryLeaf = registryURL.lastPathComponent
        guard isSafeLeaf(registryLeaf) else {
            throw ProjectRunLeaseError.unsafeProject
        }
        let registryParentURL = registryURL.deletingLastPathComponent()
        let suppliedRegistryParentPath = registryParentURL.path
        let registryParentDescriptor = Darwin.open(
            suppliedRegistryParentPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard registryParentDescriptor >= 0 else {
            throw mappedSystemError(
                operation: "open the processing-lock registry",
                code: errno
            )
        }
        var keepRegistryParent = false
        defer {
            if !keepRegistryParent {
                Darwin.close(registryParentDescriptor)
            }
        }

        try validateDirectoryBinding(
            descriptor: registryParentDescriptor,
            path: suppliedRegistryParentPath,
            operation: "inspect the processing-lock registry parent"
        )
        let canonicalRegistryParentPath = try kernelCanonicalPath(
            descriptor: registryParentDescriptor
        )
        try validateDirectoryBinding(
            descriptor: registryParentDescriptor,
            path: canonicalRegistryParentPath,
            operation: "inspect the processing-lock registry parent"
        )
        let registryLocationKeys = try locationKeys(
            suppliedPath: registryURL.path,
            canonicalPath: URL(
                fileURLWithPath: canonicalRegistryParentPath,
                isDirectory: true
            ).appendingPathComponent(registryLeaf, isDirectory: true).path,
            descriptor: registryParentDescriptor
        )
        // This process-local layer is deliberately independent of the registry
        // pathname. It continues to exclude the logical project location even
        // if a same-process caller supplies or creates a replacement registry.
        let processClaimKeys = projectLocationKeys.map { "project\0\($0)" }
        try processClaims.claim(processClaimKeys)
        var keepProcessClaims = false
        defer {
            if !keepProcessClaims {
                processClaims.release(processClaimKeys)
            }
        }

        let leaseLeafs = Array(Set(projectLocationKeys.map {
            leaseFileName(forLocationKey: $0)
        })).sorted()
        let anchorLeafs = Array(Set(registryLocationKeys.flatMap { registryLocationKey in
            leaseLeafs.map { leaseLeaf in
                anchorFileName(
                    registryLocationKey: registryLocationKey,
                    leaseLeaf: leaseLeaf
                )
            }
        })).sorted()
        let anchorDescriptors = try openLockFiles(
            directoryDescriptor: registryParentDescriptor,
            leafs: anchorLeafs
        )
        var keepAnchors = false
        defer {
            if !keepAnchors {
                closeDescriptors(anchorDescriptors)
            }
        }

        let registryDescriptor = try openRegistryDirectory(
            parentDescriptor: registryParentDescriptor,
            leaf: registryLeaf
        )
        var keepRegistry = false
        defer {
            if !keepRegistry {
                Darwin.close(registryDescriptor)
            }
        }

        let leaseDescriptors = try openLockFiles(
            directoryDescriptor: registryDescriptor,
            leafs: leaseLeafs
        )
        var keepLeases = false
        defer {
            if !keepLeases {
                closeDescriptors(leaseDescriptors)
            }
        }

        try validateProjectBinding(
            descriptor: projectDescriptor,
            path: suppliedProjectPath
        )
        try validateProjectBinding(
            descriptor: projectDescriptor,
            path: canonicalProjectPath
        )
        try validateRegistryBinding(
            parentDescriptor: registryParentDescriptor,
            registryDescriptor: registryDescriptor,
            registryLeaf: registryLeaf
        )
        try validateLockBindings(
            directoryDescriptor: registryParentDescriptor,
            descriptors: anchorDescriptors,
            leafs: anchorLeafs
        )
        try validateLockBindings(
            directoryDescriptor: registryDescriptor,
            descriptors: leaseDescriptors,
            leafs: leaseLeafs
        )
        try validateCloseOnExec([
            registryParentDescriptor,
            registryDescriptor,
            projectDescriptor,
        ] + anchorDescriptors + leaseDescriptors)

        keepRegistryParent = true
        keepRegistry = true
        keepAnchors = true
        keepLeases = true
        keepProject = true
        keepProcessClaims = true
        return ProjectRunLease(
            registryParentDescriptor: registryParentDescriptor,
            registryDescriptor: registryDescriptor,
            anchorDescriptors: anchorDescriptors,
            leaseDescriptors: leaseDescriptors,
            projectDescriptor: projectDescriptor,
            registryLeaf: registryLeaf,
            anchorLeafs: anchorLeafs,
            leaseLeafs: leaseLeafs,
            suppliedProjectPath: suppliedProjectPath,
            canonicalProjectPath: canonicalProjectPath,
            suppliedRegistryParentPath: suppliedRegistryParentPath,
            canonicalRegistryParentPath: canonicalRegistryParentPath,
            processClaimKeys: processClaimKeys
        )
    }

    /// Rebinds every descriptor to its current name before path-based pipeline work.
    /// A renamed/replaced project or lock artifact is unsafe even though the original
    /// descriptor and its advisory lock remain valid.
    package func revalidateProjectRoot() throws {
        try stateLock.withLock {
            guard !invalidated,
                  !releaseRequested,
                  registryParentDescriptor >= 0,
                  registryDescriptor >= 0,
                  !anchorDescriptors.isEmpty,
                  !leaseDescriptors.isEmpty,
                  projectDescriptor >= 0 else {
                throw ProjectRunLeaseError.unsafeProject
            }
            do {
                try validateBindingsWhileLocked()
            } catch {
                invalidated = true
                throw error
            }
        }
    }

    /// Runs synchronous descriptor-relative work while this lease cannot be
    /// released. The closure receives a duplicated, close-on-exec descriptor for
    /// the locked project root. It is valid only for the duration of the closure;
    /// the closure must not close or retain it and must not re-enter this lease.
    /// Every lease binding is checked immediately before and after the operation.
    package func withLockedProjectRootDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        try stateLock.withLock {
            guard !invalidated,
                  !releaseRequested,
                  registryParentDescriptor >= 0,
                  registryDescriptor >= 0,
                  !anchorDescriptors.isEmpty,
                  !leaseDescriptors.isEmpty,
                  projectDescriptor >= 0 else {
                throw ProjectRunLeaseError.unsafeProject
            }

            do {
                try validateBindingsWhileLocked()
            } catch {
                invalidated = true
                throw error
            }

            let duplicate = Darwin.fcntl(
                projectDescriptor,
                F_DUPFD_CLOEXEC,
                0
            )
            guard duplicate >= 0 else {
                throw ProjectRunLeaseError.system(
                    operation: "duplicate the locked project root",
                    code: errno
                )
            }
            defer { Darwin.close(duplicate) }

            do {
                let result = try operation(duplicate)
                do {
                    try validateBindingsWhileLocked()
                } catch {
                    invalidated = true
                    throw error
                }
                return result
            } catch {
                let operationError = error
                do {
                    try validateBindingsWhileLocked()
                } catch {
                    invalidated = true
                    throw error
                }
                throw operationError
            }
        }
    }

    /// Loans a duplicated project-root descriptor to work that may wait on
    /// publication or subject locks. Unlike `withLockedProjectRootDescriptor`,
    /// this method does not hold `stateLock` while the operation runs.
    ///
    /// `release()` becomes a nonblocking deferred close while a loan is active:
    /// every original descriptor and process-local claim remains held until the
    /// operation finishes and all bindings have been checked again. The caller
    /// must not close or retain the supplied descriptor.
    package func withValidatedProjectRootDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        let duplicate = try stateLock.withLock { () throws -> Int32 in
            guard !invalidated,
                  !releaseRequested,
                  registryParentDescriptor >= 0,
                  registryDescriptor >= 0,
                  !anchorDescriptors.isEmpty,
                  !leaseDescriptors.isEmpty,
                  projectDescriptor >= 0 else {
                throw ProjectRunLeaseError.unsafeProject
            }
            do {
                try validateBindingsWhileLocked()
            } catch {
                invalidated = true
                throw error
            }
            let descriptor = Darwin.fcntl(
                projectDescriptor,
                F_DUPFD_CLOEXEC,
                0
            )
            guard descriptor >= 0 else {
                throw ProjectRunLeaseError.system(
                    operation: "duplicate the locked project root",
                    code: errno
                )
            }
            activeDescriptorLoans += 1
            return descriptor
        }

        let operationResult: Swift.Result<Result, Error> = Swift.Result {
            try operation(duplicate)
        }
        let finalization = finishDescriptorLoan(duplicate: duplicate)
        if let validationError = finalization.validationError {
            throw validationError
        }
        return try operationResult.get()
    }

    package func release() {
        let detached = stateLock.withLock { () -> DetachedDescriptors? in
            releaseRequested = true
            return detachDescriptorsIfPossibleWhileLocked()
        }
        finishRelease(detached)
    }

    private func validateBindingsWhileLocked() throws {
        try Self.validateDirectoryBinding(
            descriptor: registryParentDescriptor,
            path: suppliedRegistryParentPath,
            operation: "inspect the processing-lock registry parent"
        )
        try Self.validateDirectoryBinding(
            descriptor: registryParentDescriptor,
            path: canonicalRegistryParentPath,
            operation: "inspect the processing-lock registry parent"
        )
        try Self.validateRegistryBinding(
            parentDescriptor: registryParentDescriptor,
            registryDescriptor: registryDescriptor,
            registryLeaf: registryLeaf
        )
        try Self.validateLockBindings(
            directoryDescriptor: registryParentDescriptor,
            descriptors: anchorDescriptors,
            leafs: anchorLeafs
        )
        try Self.validateLockBindings(
            directoryDescriptor: registryDescriptor,
            descriptors: leaseDescriptors,
            leafs: leaseLeafs
        )
        try Self.validateProjectBinding(
            descriptor: projectDescriptor,
            path: canonicalProjectPath
        )
        try Self.validateProjectBinding(
            descriptor: projectDescriptor,
            path: suppliedProjectPath
        )
        try Self.validateCloseOnExec([
            registryParentDescriptor,
            registryDescriptor,
            projectDescriptor,
        ] + anchorDescriptors + leaseDescriptors)
    }

    private func finishDescriptorLoan(
        duplicate: Int32
    ) -> (validationError: Error?, detached: DetachedDescriptors?) {
        let outcome = stateLock.withLock {
            precondition(activeDescriptorLoans > 0)
            precondition(processClaimsHeld)
            precondition(registryParentDescriptor >= 0)
            precondition(registryDescriptor >= 0)
            precondition(projectDescriptor >= 0)
            var validationError: Error?
            if invalidated {
                validationError = ProjectRunLeaseError.unsafeProject
            } else {
                do {
                    try validateBindingsWhileLocked()
                } catch {
                    invalidated = true
                    validationError = error
                }
            }
            activeDescriptorLoans -= 1
            precondition(activeDescriptorLoans >= 0)
            return (
                validationError,
                detachDescriptorsIfPossibleWhileLocked()
            )
        }
        Darwin.close(duplicate)
        finishRelease(outcome.1)
        return outcome
    }

    private func detachDescriptorsIfPossibleWhileLocked() -> DetachedDescriptors? {
        guard releaseRequested,
              activeDescriptorLoans == 0,
              processClaimsHeld else {
            return nil
        }
        let detached = DetachedDescriptors(
            registryParent: registryParentDescriptor,
            registry: registryDescriptor,
            anchors: anchorDescriptors,
            leases: leaseDescriptors,
            project: projectDescriptor
        )
        registryParentDescriptor = -1
        registryDescriptor = -1
        anchorDescriptors = []
        leaseDescriptors = []
        projectDescriptor = -1
        processClaimsHeld = false
        return detached
    }

    private func finishRelease(_ detached: DetachedDescriptors?) {
        guard let detached else { return }
        Self.processClaims.release(processClaimKeys)
        detached.close()
    }

#if DEBUG
    package func retainedDescriptorSnapshotsForTesting() throws -> [
        (descriptor: Int32, device: UInt64, inode: UInt64)
    ] {
        try stateLock.withLock {
            guard !invalidated,
                  !releaseRequested else {
                throw ProjectRunLeaseError.unsafeProject
            }
            try validateBindingsWhileLocked()
            return try ([
                registryParentDescriptor,
                registryDescriptor,
                projectDescriptor,
            ] + anchorDescriptors + leaseDescriptors).map { descriptor in
                var opened = stat()
                guard Darwin.fstat(descriptor, &opened) == 0 else {
                    throw ProjectRunLeaseError.system(
                        operation: "inspect a retained processing descriptor",
                        code: errno
                    )
                }
                return (
                    descriptor,
                    UInt64(opened.st_dev),
                    UInt64(opened.st_ino)
                )
            }
        }
    }
#endif

    package static func defaultRegistryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ProjectRunLeaseError.system(
                operation: "locate the processing-lock registry",
                code: ENOENT
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProjectRunLeaseError.system(
                operation: "prepare the processing-lock registry",
                code: posixCode(from: error)
            )
        }
        return applicationSupportURL.appendingPathComponent(
            registryDirectoryName,
            isDirectory: true
        )
    }

    private static func validateAbsoluteFileURL(_ url: URL) throws {
        let path = url.path
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard url.isFileURL,
              path.hasPrefix("/"),
              !path.contains("\0"),
              components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
              }) else {
            throw ProjectRunLeaseError.unsafeProject
        }
    }

    private static func kernelCanonicalPath(
        descriptor: Int32
    ) throws -> String {
        // Swift exposes fcntl's pointer form through its typed flock overload.
        // F_GETPATH treats that same argument as a MAXPATHLEN byte buffer, so
        // flock storage provides the required alignment without a proc-info API.
        let storageCount = (
            Int(MAXPATHLEN) + MemoryLayout<Darwin.flock>.stride - 1
        ) / MemoryLayout<Darwin.flock>.stride
        var storage = [Darwin.flock](
            repeating: Darwin.flock(),
            count: storageCount
        )
        _ = storage.withUnsafeMutableBytes { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
        let status = storage.withUnsafeMutableBufferPointer { buffer in
            Darwin.fcntl(descriptor, F_GETPATH, buffer.baseAddress!)
        }
        guard status == 0 else {
            throw mappedSystemError(
                operation: "resolve the locked project location",
                code: errno
            )
        }
        let buffer = storage.withUnsafeBytes { bytes in
            Array(bytes.prefix(Int(MAXPATHLEN)))
        }
        guard let terminator = buffer.firstIndex(of: 0),
              terminator > 0,
              let path = String(
                  bytes: buffer[..<terminator],
                  encoding: .utf8
              ),
              path.hasPrefix("/"),
              !path.contains("\0") else {
            throw ProjectRunLeaseError.unsafeProject
        }
        return path
    }

    private static func openRegistryDirectory(
        parentDescriptor: Int32,
        leaf: String
    ) throws -> Int32 {
        let created: Bool
        if Darwin.mkdirat(parentDescriptor, leaf, registryMode) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw mappedSystemError(
                operation: "create the processing-lock registry",
                code: errno
            )
        }

        let descriptor = Darwin.openat(
            parentDescriptor,
            leaf,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw mappedSystemError(
                operation: "open the processing-lock registry",
                code: errno
            )
        }
        do {
            if created, Darwin.fchmod(descriptor, registryMode) != 0 {
                throw ProjectRunLeaseError.system(
                    operation: "secure the processing-lock registry",
                    code: errno
                )
            }
            try validateRegistryBinding(
                parentDescriptor: parentDescriptor,
                registryDescriptor: descriptor,
                registryLeaf: leaf
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openLeaseFile(
        registryDescriptor: Int32,
        leaf: String
    ) throws -> Int32 {
        for attempt in 0..<32 {
            var created = false
            var descriptor = Darwin.openat(
                registryDescriptor,
                leaf,
                O_RDWR
                    | O_CREAT
                    | O_EXCL
                    | O_NONBLOCK
                    | O_NOFOLLOW
                    | O_CLOEXEC
                    | O_EXLOCK,
                leaseMode
            )
            if descriptor >= 0 {
                created = true
            } else {
                let createError = errno
                if createError == EINTR { continue }
                guard createError == EEXIST else {
                    throw mappedLeaseOpenError(createError)
                }
                descriptor = Darwin.openat(
                    registryDescriptor,
                    leaf,
                    O_RDWR
                        | O_NONBLOCK
                        | O_NOFOLLOW
                        | O_CLOEXEC
                        | O_EXLOCK
                )
                if descriptor < 0 {
                    let openError = errno
                    if openError == EINTR { continue }
                    if openError == ENOENT, attempt < 31 {
                        _ = sched_yield()
                        continue
                    }
                    throw mappedLeaseOpenError(openError)
                }
            }

            do {
                if created, Darwin.fchmod(descriptor, leaseMode) != 0 {
                    throw ProjectRunLeaseError.system(
                        operation: "secure the project processing lock",
                        code: errno
                    )
                }
                try validateLeaseBinding(
                    registryDescriptor: registryDescriptor,
                    leaseDescriptor: descriptor,
                    leaseLeaf: leaf
                )
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        throw ProjectRunLeaseError.system(
            operation: "open the project processing lock",
            code: ENOENT
        )
    }

    private static func openLockFiles(
        directoryDescriptor: Int32,
        leafs: [String]
    ) throws -> [Int32] {
        var descriptors: [Int32] = []
        descriptors.reserveCapacity(leafs.count)
        do {
            for leaf in leafs {
                descriptors.append(try openLeaseFile(
                    registryDescriptor: directoryDescriptor,
                    leaf: leaf
                ))
            }
            return descriptors
        } catch {
            closeDescriptors(descriptors)
            throw error
        }
    }

    private static func validateRegistryBinding(
        parentDescriptor: Int32,
        registryDescriptor: Int32,
        registryLeaf: String
    ) throws {
        var opened = stat()
        guard Darwin.fstat(registryDescriptor, &opened) == 0 else {
            throw ProjectRunLeaseError.system(
                operation: "inspect the processing-lock registry",
                code: errno
            )
        }
        var named = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            registryLeaf,
            &named,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw unsafeBindingError(errno)
        }
        guard sameNode(opened, named, type: S_IFDIR),
              opened.st_uid == geteuid(),
              opened.st_mode & permissionMask == registryMode else {
            throw ProjectRunLeaseError.unsafeProject
        }
    }

    private static func validateLeaseBinding(
        registryDescriptor: Int32,
        leaseDescriptor: Int32,
        leaseLeaf: String
    ) throws {
        var opened = stat()
        guard Darwin.fstat(leaseDescriptor, &opened) == 0 else {
            throw ProjectRunLeaseError.system(
                operation: "inspect the project processing lock",
                code: errno
            )
        }
        var named = stat()
        guard Darwin.fstatat(
            registryDescriptor,
            leaseLeaf,
            &named,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw unsafeBindingError(errno)
        }
        guard sameNode(opened, named, type: S_IFREG),
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              opened.st_mode & permissionMask == leaseMode,
              opened.st_size == 0 else {
            throw ProjectRunLeaseError.unsafeProject
        }
    }

    private static func validateLockBindings(
        directoryDescriptor: Int32,
        descriptors: [Int32],
        leafs: [String]
    ) throws {
        guard !descriptors.isEmpty,
              descriptors.count == leafs.count else {
            throw ProjectRunLeaseError.unsafeProject
        }
        for (descriptor, leaf) in zip(descriptors, leafs) {
            try validateLeaseBinding(
                registryDescriptor: directoryDescriptor,
                leaseDescriptor: descriptor,
                leaseLeaf: leaf
            )
        }
    }

    private static func validateDirectoryBinding(
        descriptor: Int32,
        path: String,
        operation: String
    ) throws {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            throw ProjectRunLeaseError.system(
                operation: operation,
                code: errno
            )
        }
        var named = stat()
        guard Darwin.lstat(path, &named) == 0 else {
            throw unsafeBindingError(errno)
        }
        guard sameNode(opened, named, type: S_IFDIR),
              opened.st_uid == geteuid() else {
            throw ProjectRunLeaseError.unsafeProject
        }
    }

    private static func validateProjectBinding(
        descriptor: Int32,
        path: String
    ) throws {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            throw ProjectRunLeaseError.system(
                operation: "inspect the locked project",
                code: errno
            )
        }
        var named = stat()
        guard Darwin.lstat(path, &named) == 0 else {
            throw unsafeBindingError(errno)
        }
        guard sameNode(opened, named, type: S_IFDIR),
              opened.st_uid == geteuid() else {
            throw ProjectRunLeaseError.unsafeProject
        }
    }

    private static func sameNode(
        _ lhs: stat,
        _ rhs: stat,
        type: mode_t
    ) -> Bool {
        lhs.st_mode & S_IFMT == type
            && rhs.st_mode & S_IFMT == type
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
    }

    private static func locationKeys(
        suppliedPath: String,
        canonicalPath: String,
        descriptor: Int32
    ) throws -> [String] {
        errno = 0
        let caseSensitiveValue = Darwin.fpathconf(
            descriptor,
            _PC_CASE_SENSITIVE
        )
        if caseSensitiveValue < 0 {
            throw ProjectRunLeaseError.system(
                operation: "inspect project volume behavior",
                code: errno == 0 ? EIO : errno
            )
        }
        let caseSensitive = caseSensitiveValue != 0
        let legacyCanonical = canonicalPath
            .precomposedStringWithCanonicalMapping
        return Array(Set([
            legacyCanonical,
            stableLocationPath(canonicalPath, caseSensitive: caseSensitive),
            stableLocationPath(suppliedPath, caseSensitive: caseSensitive),
        ])).sorted()
    }

    private static func stableLocationPath(
        _ path: String,
        caseSensitive: Bool
    ) -> String {
        var normalized = URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
        if !caseSensitive {
            normalized = normalized
                .folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .precomposedStringWithCanonicalMapping
        }
        return normalized
    }

    private static func leaseFileName(
        forLocationKey locationKey: String
    ) -> String {
        var bytes = Data("EasySplat project run lease v1\0".utf8)
        bytes.append(contentsOf: locationKey.utf8)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).lock"
    }

    private static func anchorFileName(
        registryLocationKey: String,
        leaseLeaf: String
    ) -> String {
        var bytes = Data("EasySplat project run lease anchor v1\0".utf8)
        bytes.append(contentsOf: registryLocationKey.utf8)
        bytes.append(0)
        bytes.append(contentsOf: leaseLeaf.utf8)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return ".easysplat-run-\(digest).lock"
    }

    private static func validateCloseOnExec(_ descriptors: [Int32]) throws {
        for descriptor in descriptors {
            let flags = Darwin.fcntl(descriptor, F_GETFD)
            guard flags >= 0 else {
                throw ProjectRunLeaseError.system(
                    operation: "inspect a processing descriptor",
                    code: errno
                )
            }
            guard flags & FD_CLOEXEC != 0 else {
                throw ProjectRunLeaseError.unsafeProject
            }
        }
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors.reversed() where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private static func isSafeLeaf(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private static func mappedLeaseOpenError(_ code: Int32) -> Error {
        if code == EAGAIN || code == EWOULDBLOCK {
            return ProjectRunLeaseError.alreadyRunning
        }
        return mappedSystemError(
            operation: "open the project processing lock",
            code: code
        )
    }

    private static func mappedSystemError(
        operation: String,
        code: Int32
    ) -> Error {
        switch code {
        case ELOOP, ENOTDIR, EISDIR, EACCES, EPERM, ENOTSUP, EOPNOTSUPP:
            return ProjectRunLeaseError.unsafeProject
        default:
            return ProjectRunLeaseError.system(operation: operation, code: code)
        }
    }

    private static func unsafeBindingError(_ code: Int32) -> Error {
        switch code {
        case ENOENT, ELOOP, ENOTDIR, EISDIR, EACCES, EPERM:
            return ProjectRunLeaseError.unsafeProject
        default:
            return ProjectRunLeaseError.system(
                operation: "revalidate the processing lease",
                code: code
            )
        }
    }

    private static func posixCode(from error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(clamping: nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(clamping: underlying.code)
        }
        return EIO
    }
}

private struct DetachedDescriptors {
    let registryParent: Int32
    let registry: Int32
    let anchors: [Int32]
    let leases: [Int32]
    let project: Int32

    func close() {
        if project >= 0 { Darwin.close(project) }
        for descriptor in leases.reversed() where descriptor >= 0 {
            Darwin.close(descriptor)
        }
        if registry >= 0 { Darwin.close(registry) }
        for descriptor in anchors.reversed() where descriptor >= 0 {
            Darwin.close(descriptor)
        }
        if registryParent >= 0 { Darwin.close(registryParent) }
    }
}

private final class ProcessClaimRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var claims: Set<String> = []

    func claim(_ requested: [String]) throws {
        try lock.withLock {
            guard claims.isDisjoint(with: requested) else {
                throw ProjectRunLeaseError.alreadyRunning
            }
            claims.formUnion(requested)
        }
    }

    func release(_ released: [String]) {
        lock.withLock {
            claims.subtract(released)
        }
    }
}
