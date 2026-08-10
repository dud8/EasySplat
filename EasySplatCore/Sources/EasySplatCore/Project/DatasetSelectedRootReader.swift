import Darwin
import Foundation

/// Descriptor-bound reader for a selected dataset folder. It recognizes only
/// the selected directory and, when explicitly supplied, one direct child.
/// Every source component is opened relative to that bound root without
/// following links, and every accepted file is copied into private staging
/// before a parser, ImageIO, or a content digest sees it.
final class DatasetSelectedRootReader {
    struct Limits: Sendable, Equatable {
        let maximumRelativePathComponents: Int
        let maximumVisitedOperations: Int
        let maximumAcceptedEntries: Int
        let maximumTotalCopiedBytes: UInt64

        static let datasetPreflight = Limits(
            maximumRelativePathComponents: DatasetContract.maximumRelativePathComponents,
            maximumVisitedOperations: DatasetContract.maximumEntryCount,
            maximumAcceptedEntries: DatasetContract.maximumEntryCount,
            maximumTotalCopiedBytes: 64 * 1_024 * 1_024 * 1_024
        )
    }

    enum EntryKind: Equatable {
        case directory
        case regularFile
    }

    struct CopiedFile {
        let url: URL
        let byteCount: Int64
    }

    enum ReaderError: Error {
        case missing(String)
        case unreadable
        case unsafeLayout
        case destinationUnavailable
        case resourceLimitExceeded
    }

    struct DirectoryEntry {
        let name: String
        let kind: EntryKind
    }

    private struct Evidence {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let linkCount: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            mode = status.st_mode
            linkCount = status.st_nlink
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }

        func matchesIdentity(_ status: stat) -> Bool {
            status.st_dev == device
                && status.st_ino == inode
                && (status.st_mode & S_IFMT) == (mode & S_IFMT)
        }

        func matchesFile(_ status: stat) -> Bool {
            matchesIdentity(status)
                && (status.st_mode & S_IFMT) == S_IFREG
                && status.st_nlink == linkCount
                && linkCount == 1
                && status.st_size == size
                && status.st_mtimespec.tv_sec == modifiedSeconds
                && status.st_mtimespec.tv_nsec == modifiedNanoseconds
                && status.st_ctimespec.tv_sec == changedSeconds
                && status.st_ctimespec.tv_nsec == changedNanoseconds
        }

        func matchesDirectory(_ status: stat) -> Bool {
            matchesIdentity(status)
                && (status.st_mode & S_IFMT) == S_IFDIR
                && status.st_nlink == linkCount
                && status.st_size == size
                && status.st_mtimespec.tv_sec == modifiedSeconds
                && status.st_mtimespec.tv_nsec == modifiedNanoseconds
                && status.st_ctimespec.tv_sec == changedSeconds
                && status.st_ctimespec.tv_nsec == changedNanoseconds
        }
    }

    private struct ComponentBinding {
        let name: String
        let evidence: Evidence
    }

    private struct OpenedParent {
        let descriptor: Int32
        let leaf: String
        let normalizedPath: String
        let componentBindings: [ComponentBinding]
    }

    private struct OpenedDirectory {
        let descriptor: Int32
        let componentBindings: [ComponentBinding]
    }

    private struct OpenedDestinationParent {
        let descriptor: Int32
        let leaf: String
        let rootDescriptor: Int32
        let rootPath: String
        let rootEvidence: Evidence
        let componentBindings: [ComponentBinding]
    }

    private let selectedURL: URL
    private let selectedDescriptor: Int32
    private let selectedEvidence: Evidence
    private let resolvedChildName: String?
    private let rootDescriptor: Int32
    private let rootEvidence: Evidence
    private let sourceReadObserver: @Sendable (String) -> Void
    private let destinationSync: @Sendable (Int32) -> Bool
    private let limits: Limits
    private var visitedOperations = 0
    private var acceptedEvidenceByPath: [String: Evidence] = [:]
    private var totalCopiedBytes: UInt64 = 0

    init(
        selectedURL: URL,
        resolvedRoot: URL,
        sourceReadObserver: @escaping @Sendable (String) -> Void,
        limits: Limits = .datasetPreflight,
        destinationSync: @escaping @Sendable (Int32) -> Bool = { fsync($0) == 0 }
    ) throws {
        guard selectedURL.isFileURL, resolvedRoot.isFileURL else {
            throw ReaderError.unreadable
        }
        guard limits.maximumRelativePathComponents > 0,
              limits.maximumVisitedOperations > 0,
              limits.maximumAcceptedEntries > 0 else {
            throw ReaderError.resourceLimitExceeded
        }

        var selectedNamedStatus = stat()
        guard lstat(selectedURL.path, &selectedNamedStatus) == 0 else {
            throw ReaderError.unreadable
        }
        guard (selectedNamedStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw ReaderError.unsafeLayout
        }
        let selected = Darwin.open(
            selectedURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard selected >= 0 else {
            throw errno == ELOOP ? ReaderError.unsafeLayout : ReaderError.unreadable
        }
        var selectedOpenedStatus = stat()
        guard fstat(selected, &selectedOpenedStatus) == 0,
              Evidence(selectedNamedStatus).matchesIdentity(selectedOpenedStatus) else {
            Darwin.close(selected)
            throw ReaderError.unsafeLayout
        }

        let selectedPath = selectedURL.path
        let resolvedPath = resolvedRoot.path
        let childName: String?
        let root: Int32
        let rootStatus: stat
        if selectedPath == resolvedPath {
            childName = nil
            root = dup(selected)
            rootStatus = selectedOpenedStatus
        } else {
            let proposedChild = resolvedRoot.lastPathComponent
            guard resolvedRoot.deletingLastPathComponent().path == selectedPath,
                  DatasetDeclaredPath.normalized(proposedChild) == proposedChild,
                  !proposedChild.contains("/") else {
                Darwin.close(selected)
                throw ReaderError.unsafeLayout
            }
            var childNamedStatus = stat()
            guard proposedChild.withCString({
                fstatat(selected, $0, &childNamedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                Darwin.close(selected)
                throw ReaderError.unsafeLayout
            }
            guard (childNamedStatus.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(selected)
                throw ReaderError.unsafeLayout
            }
            root = proposedChild.withCString {
                openat(selected, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard root >= 0 else {
                Darwin.close(selected)
                throw ReaderError.unsafeLayout
            }
            var childOpenedStatus = stat()
            guard fstat(root, &childOpenedStatus) == 0,
                  Evidence(childNamedStatus).matchesIdentity(childOpenedStatus) else {
                Darwin.close(root)
                Darwin.close(selected)
                throw ReaderError.unsafeLayout
            }
            childName = proposedChild
            rootStatus = childOpenedStatus
        }
        guard root >= 0 else {
            Darwin.close(selected)
            throw ReaderError.unreadable
        }

        self.selectedURL = selectedURL
        selectedDescriptor = selected
        selectedEvidence = Evidence(selectedOpenedStatus)
        resolvedChildName = childName
        rootDescriptor = root
        rootEvidence = Evidence(rootStatus)
        self.sourceReadObserver = sourceReadObserver
        self.destinationSync = destinationSync
        self.limits = limits
        do {
            try verifyRootBindings()
        } catch {
            Darwin.close(root)
            Darwin.close(selected)
            throw error
        }
    }

    deinit {
        Darwin.close(rootDescriptor)
        Darwin.close(selectedDescriptor)
    }

    func entryKind(at relativePath: String) throws -> EntryKind? {
        let opened: OpenedParent
        do {
            opened = try openParent(of: relativePath)
        } catch ReaderError.missing {
            return nil
        }
        defer { Darwin.close(opened.descriptor) }
        var status = stat()
        try recordOperation()
        let result = opened.leaf.withCString {
            fstatat(opened.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw ReaderError.unreadable
        }
        let kind = try acceptedKind(status)
        try recordAcceptedEntry(path: opened.normalizedPath, status: status)
        try verifyComponentBindings(opened.componentBindings)
        try verifyRootBindings()
        return kind
    }

    func directoryEntries(at relativePath: String) throws -> [DirectoryEntry] {
        let opened = try openDirectory(at: relativePath)
        defer { Darwin.close(opened.descriptor) }
        let duplicate = dup(opened.descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw ReaderError.unreadable
        }
        defer { closedir(directory) }

        var output: [DirectoryEntry] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else {
                errno = 0
                continue
            }
            guard DatasetDeclaredPath.normalized(name) == name, !name.contains("/") else {
                throw ReaderError.unsafeLayout
            }
            try recordOperation()
            var status = stat()
            guard name.withCString({
                fstatat(opened.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw ReaderError.unreadable
            }
            let kind = try acceptedKind(status)
            let relativeEntryPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            guard let normalizedEntryPath = DatasetDeclaredPath.normalized(relativeEntryPath),
                  normalizedEntryPath.split(separator: "/").count
                    <= limits.maximumRelativePathComponents else {
                throw ReaderError.resourceLimitExceeded
            }
            try recordAcceptedEntry(path: normalizedEntryPath, status: status)
            output.append(DirectoryEntry(name: name, kind: kind))
            errno = 0
        }
        guard errno == 0 else { throw ReaderError.unreadable }
        try verifyComponentBindings(opened.componentBindings)
        try verifyRootBindings()
        return output.sorted { $0.name < $1.name }
    }

    func copyRegularFile(
        at relativePath: String,
        to destinationRoot: URL,
        maximumBytes: Int64
    ) throws -> CopiedFile {
        guard maximumBytes >= 0 else { throw ReaderError.unreadable }
        let opened = try openParent(of: relativePath)
        defer { Darwin.close(opened.descriptor) }

        var namedStatus = stat()
        try recordOperation()
        let namedResult = opened.leaf.withCString {
            fstatat(opened.descriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }
        if namedResult != 0 {
            if errno == ENOENT { throw ReaderError.missing(opened.normalizedPath) }
            throw ReaderError.unreadable
        }
        guard try acceptedKind(namedStatus) == .regularFile,
              namedStatus.st_size >= 0 else {
            throw ReaderError.unsafeLayout
        }
        guard namedStatus.st_size <= off_t(maximumBytes) else {
            throw ReaderError.resourceLimitExceeded
        }
        let evidence = Evidence(namedStatus)
        try recordAcceptedEntry(path: opened.normalizedPath, status: namedStatus)
        let byteCount = UInt64(namedStatus.st_size)
        let nextTotal = totalCopiedBytes.addingReportingOverflow(byteCount)
        guard !nextTotal.overflow,
              nextTotal.partialValue <= limits.maximumTotalCopiedBytes else {
            throw ReaderError.resourceLimitExceeded
        }

        sourceReadObserver(opened.normalizedPath)
        try recordOperation()
        let input = opened.leaf.withCString {
            openat(opened.descriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard input >= 0 else { throw ReaderError.unsafeLayout }
        defer { Darwin.close(input) }
        var openedStatus = stat()
        guard fstat(input, &openedStatus) == 0, evidence.matchesFile(openedStatus) else {
            throw ReaderError.unsafeLayout
        }

        let destination = destinationRoot.appendingPathComponent(opened.normalizedPath)
        let destinationParent = try openDestinationParent(
            root: destinationRoot,
            relativePath: opened.normalizedPath
        )
        defer {
            Darwin.close(destinationParent.descriptor)
            Darwin.close(destinationParent.rootDescriptor)
        }
        try verifyDestinationBindings(destinationParent)

        var privateLeaf: String?
        var output: Int32 = -1
        for _ in 0..<8 {
            let candidate = ".easysplat-dataset-\(UUID().uuidString)"
            output = candidate.withCString {
                openat(
                    destinationParent.descriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if output >= 0 {
                privateLeaf = candidate
                break
            }
            guard errno == EEXIST else { break }
        }
        guard output >= 0, let privateLeaf else {
            throw ReaderError.destinationUnavailable
        }
        defer { Darwin.close(output) }
        guard fchmod(output, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw ReaderError.destinationUnavailable
        }

        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(input, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ReaderError.unreadable }
            if count == 0 { break }
            copied += Int64(count)
            guard copied <= Int64(namedStatus.st_size) else {
                throw ReaderError.unsafeLayout
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(output, $0.baseAddress?.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ReaderError.destinationUnavailable }
                offset += written
            }
        }

        var finalStatus = stat()
        var reboundStatus = stat()
        try recordOperation(2)
        guard copied == Int64(namedStatus.st_size),
              fstat(input, &finalStatus) == 0,
              opened.leaf.withCString({
                  fstatat(opened.descriptor, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              evidence.matchesFile(finalStatus),
              evidence.matchesFile(reboundStatus) else {
            throw ReaderError.unsafeLayout
        }
        try verifyComponentBindings(opened.componentBindings)
        try verifyRootBindings()
        guard destinationSync(output) else {
            throw ReaderError.destinationUnavailable
        }
        try verifyDestinationBindings(destinationParent)
        var privateNamedStatus = stat()
        var outputStatus = stat()
        guard fstat(output, &outputStatus) == 0,
              (outputStatus.st_mode & S_IFMT) == S_IFREG,
              outputStatus.st_size == copied,
              outputStatus.st_nlink == 1,
              (outputStatus.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              privateLeaf.withCString({
                  fstatat(
                      destinationParent.descriptor,
                      $0,
                      &privateNamedStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              Evidence(outputStatus).matchesFile(privateNamedStatus) else {
            throw ReaderError.destinationUnavailable
        }
        try Task.checkCancellation()
        let published = privateLeaf.withCString { source in
            destinationParent.leaf.withCString { target in
                renameatx_np(
                    destinationParent.descriptor,
                    source,
                    destinationParent.descriptor,
                    target,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard published == 0 else { throw ReaderError.destinationUnavailable }

        try verifyDestinationBindings(destinationParent)
        var finalOutputStatus = stat()
        var finalNamedStatus = stat()
        guard fstat(output, &finalOutputStatus) == 0,
              (finalOutputStatus.st_mode & S_IFMT) == S_IFREG,
              finalOutputStatus.st_size == copied,
              finalOutputStatus.st_nlink == 1,
              (finalOutputStatus.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              destinationParent.leaf.withCString({
                  fstatat(
                      destinationParent.descriptor,
                      $0,
                      &finalNamedStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              Evidence(finalOutputStatus).matchesFile(finalNamedStatus) else {
            throw ReaderError.destinationUnavailable
        }
        totalCopiedBytes = nextTotal.partialValue
        return CopiedFile(url: destination, byteCount: copied)
    }

    /// Opens an app-private staging root once, creates each missing relative
    /// directory as a single component, and refuses links at every boundary.
    /// The returned descriptors remain open through publication so a pathname
    /// replacement cannot redirect the copy outside the staging root.
    private func openDestinationParent(
        root: URL,
        relativePath: String
    ) throws -> OpenedDestinationParent {
        guard let normalized = DatasetDeclaredPath.normalized(relativePath) else {
            throw ReaderError.destinationUnavailable
        }
        let components = normalized.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw ReaderError.destinationUnavailable }
        let boundRoot: URL
        do {
            boundRoot = try SafeArchiveExtractor.destinationPathForBinding(root)
        } catch {
            throw ReaderError.destinationUnavailable
        }

        var namedRootStatus = stat()
        guard lstat(boundRoot.path, &namedRootStatus) == 0,
              (namedRootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw ReaderError.destinationUnavailable
        }
        let rootDescriptor = Darwin.open(
            boundRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw ReaderError.destinationUnavailable
        }
        let rootEvidence = Evidence(namedRootStatus)
        var openedRootStatus = stat()
        guard fstat(rootDescriptor, &openedRootStatus) == 0,
              rootEvidence.matchesIdentity(openedRootStatus) else {
            Darwin.close(rootDescriptor)
            throw ReaderError.destinationUnavailable
        }

        var current = dup(rootDescriptor)
        guard current >= 0 else {
            Darwin.close(rootDescriptor)
            throw ReaderError.destinationUnavailable
        }
        var bindings: [ComponentBinding] = []
        do {
            for component in components.dropLast() {
                var namedStatus = stat()
                var statusResult = component.withCString {
                    fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
                }
                var created = false
                if statusResult != 0 {
                    guard errno == ENOENT else { throw ReaderError.destinationUnavailable }
                    let made = component.withCString {
                        mkdirat(current, $0, mode_t(S_IRWXU))
                    }
                    if made == 0 {
                        created = true
                    } else if errno != EEXIST {
                        throw ReaderError.destinationUnavailable
                    }
                    statusResult = component.withCString {
                        fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
                    }
                }
                guard statusResult == 0,
                      (namedStatus.st_mode & S_IFMT) == S_IFDIR else {
                    throw ReaderError.destinationUnavailable
                }
                let evidence = Evidence(namedStatus)
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    throw ReaderError.destinationUnavailable
                }
                var openedStatus = stat()
                var reboundStatus = stat()
                let secured = !created || fchmod(next, mode_t(S_IRWXU)) == 0
                guard secured,
                      fstat(next, &openedStatus) == 0,
                      evidence.matchesIdentity(openedStatus),
                      component.withCString({
                          fstatat(current, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
                      }) == 0,
                      evidence.matchesIdentity(reboundStatus),
                      !created || (openedStatus.st_mode & 0o7777) == mode_t(S_IRWXU) else {
                    Darwin.close(next)
                    throw ReaderError.destinationUnavailable
                }
                bindings.append(ComponentBinding(name: component, evidence: Evidence(openedStatus)))
                Darwin.close(current)
                current = next
            }
            return OpenedDestinationParent(
                descriptor: current,
                leaf: leaf,
                rootDescriptor: rootDescriptor,
                rootPath: boundRoot.path,
                rootEvidence: rootEvidence,
                componentBindings: bindings
            )
        } catch {
            Darwin.close(current)
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    private func verifyDestinationBindings(
        _ destination: OpenedDestinationParent
    ) throws {
        var namedRootStatus = stat()
        var openedRootStatus = stat()
        guard lstat(destination.rootPath, &namedRootStatus) == 0,
              fstat(destination.rootDescriptor, &openedRootStatus) == 0,
              destination.rootEvidence.matchesIdentity(namedRootStatus),
              destination.rootEvidence.matchesIdentity(openedRootStatus) else {
            throw ReaderError.destinationUnavailable
        }

        var current = dup(destination.rootDescriptor)
        guard current >= 0 else { throw ReaderError.destinationUnavailable }
        defer { Darwin.close(current) }
        for binding in destination.componentBindings {
            var namedStatus = stat()
            guard binding.name.withCString({
                fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  binding.evidence.matchesIdentity(namedStatus) else {
                throw ReaderError.destinationUnavailable
            }
            let next = binding.name.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw ReaderError.destinationUnavailable }
            var openedStatus = stat()
            guard fstat(next, &openedStatus) == 0,
                  binding.evidence.matchesIdentity(openedStatus) else {
                Darwin.close(next)
                throw ReaderError.destinationUnavailable
            }
            Darwin.close(current)
            current = next
        }
        var finalParentStatus = stat()
        guard fstat(current, &finalParentStatus) == 0 else {
            throw ReaderError.destinationUnavailable
        }
        if let expectedParent = destination.componentBindings.last?.evidence {
            guard expectedParent.matchesIdentity(finalParentStatus) else {
                throw ReaderError.destinationUnavailable
            }
        } else {
            guard destination.rootEvidence.matchesIdentity(finalParentStatus) else {
                throw ReaderError.destinationUnavailable
            }
        }
    }

    private func openParent(
        of relativePath: String
    ) throws -> OpenedParent {
        guard let normalized = DatasetDeclaredPath.normalized(relativePath) else {
            throw ReaderError.unsafeLayout
        }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.count <= limits.maximumRelativePathComponents,
              let leaf = components.last else {
            throw ReaderError.resourceLimitExceeded
        }
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw ReaderError.unreadable }
        var bindings: [ComponentBinding] = []
        bindings.reserveCapacity(max(0, components.count - 1))
        var traversed: [String] = []
        traversed.reserveCapacity(max(0, components.count - 1))
        do {
            for component in components.dropLast() {
                try recordOperation(2)
                var namedStatus = stat()
                let statusResult = component.withCString {
                    fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
                }
                if statusResult != 0 {
                    if errno == ENOENT { throw ReaderError.missing(normalized) }
                    throw ReaderError.unreadable
                }
                guard (namedStatus.st_mode & S_IFMT) == S_IFDIR else {
                    throw ReaderError.unsafeLayout
                }
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw ReaderError.unsafeLayout }
                var openedStatus = stat()
                guard fstat(next, &openedStatus) == 0,
                      Evidence(namedStatus).matchesDirectory(openedStatus) else {
                    Darwin.close(next)
                    throw ReaderError.unsafeLayout
                }
                traversed.append(component)
                let relativeDirectoryPath = traversed.joined(separator: "/")
                try recordAcceptedEntry(path: relativeDirectoryPath, status: openedStatus)
                bindings.append(
                    ComponentBinding(name: component, evidence: Evidence(openedStatus))
                )
                Darwin.close(current)
                current = next
            }
            return OpenedParent(
                descriptor: current,
                leaf: leaf,
                normalizedPath: normalized,
                componentBindings: bindings
            )
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func openDirectory(at relativePath: String) throws -> OpenedDirectory {
        if relativePath.isEmpty {
            let descriptor = dup(rootDescriptor)
            guard descriptor >= 0 else { throw ReaderError.unreadable }
            return OpenedDirectory(descriptor: descriptor, componentBindings: [])
        }
        let opened = try openParent(of: relativePath)
        defer { Darwin.close(opened.descriptor) }
        var namedStatus = stat()
        try recordOperation(2)
        let statusResult = opened.leaf.withCString {
            fstatat(opened.descriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 {
            if errno == ENOENT { throw ReaderError.missing(opened.normalizedPath) }
            throw ReaderError.unreadable
        }
        guard (namedStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw ReaderError.unsafeLayout
        }
        let descriptor = opened.leaf.withCString {
            openat(opened.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ReaderError.unsafeLayout }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              Evidence(namedStatus).matchesDirectory(openedStatus) else {
            Darwin.close(descriptor)
            throw ReaderError.unsafeLayout
        }
        try recordAcceptedEntry(path: opened.normalizedPath, status: openedStatus)
        let bindings = opened.componentBindings + [
            ComponentBinding(name: opened.leaf, evidence: Evidence(openedStatus)),
        ]
        return OpenedDirectory(descriptor: descriptor, componentBindings: bindings)
    }

    private func acceptedKind(_ status: stat) throws -> EntryKind {
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFREG where status.st_nlink == 1:
            return .regularFile
        default:
            throw ReaderError.unsafeLayout
        }
    }

    private func recordOperation(_ count: Int = 1) throws {
        let next = visitedOperations.addingReportingOverflow(count)
        guard !next.overflow, next.partialValue <= limits.maximumVisitedOperations else {
            throw ReaderError.resourceLimitExceeded
        }
        visitedOperations = next.partialValue
    }

    private func recordAcceptedEntry(path: String, status: stat) throws {
        if let existing = acceptedEvidenceByPath[path] {
            let kind = status.st_mode & S_IFMT
            let unchanged = kind == S_IFDIR
                ? existing.matchesDirectory(status)
                : existing.matchesFile(status)
            guard unchanged else { throw ReaderError.unsafeLayout }
            return
        }
        guard acceptedEvidenceByPath.count < limits.maximumAcceptedEntries else {
            throw ReaderError.resourceLimitExceeded
        }
        acceptedEvidenceByPath[path] = Evidence(status)
    }

    /// Re-opens every retained intermediate directory from the bound root and
    /// compares both identity and mutation evidence. A directory moved away,
    /// replaced, changed, or moved back while its old descriptor remains open
    /// therefore cannot make a detached path look contained.
    private func verifyComponentBindings(_ bindings: [ComponentBinding]) throws {
        guard !bindings.isEmpty else { return }
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw ReaderError.unreadable }
        defer { Darwin.close(current) }

        for binding in bindings {
            try recordOperation(2)
            var namedStatus = stat()
            guard binding.name.withCString({
                fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  binding.evidence.matchesDirectory(namedStatus) else {
                throw ReaderError.unsafeLayout
            }
            let next = binding.name.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw ReaderError.unsafeLayout }
            var openedStatus = stat()
            guard fstat(next, &openedStatus) == 0,
                  binding.evidence.matchesDirectory(openedStatus) else {
                Darwin.close(next)
                throw ReaderError.unsafeLayout
            }
            Darwin.close(current)
            current = next
        }
    }

    private func verifyRootBindings() throws {
        try recordOperation(2)
        var selectedNamedStatus = stat()
        var selectedOpenedStatus = stat()
        guard lstat(selectedURL.path, &selectedNamedStatus) == 0,
              fstat(selectedDescriptor, &selectedOpenedStatus) == 0,
              selectedEvidence.matchesDirectory(selectedNamedStatus),
              selectedEvidence.matchesDirectory(selectedOpenedStatus) else {
            throw ReaderError.unsafeLayout
        }
        if let resolvedChildName {
            try recordOperation()
            var childNamedStatus = stat()
            guard resolvedChildName.withCString({
                fstatat(selectedDescriptor, $0, &childNamedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  rootEvidence.matchesDirectory(childNamedStatus) else {
                throw ReaderError.unsafeLayout
            }
        }
        try recordOperation()
        var rootOpenedStatus = stat()
        guard fstat(rootDescriptor, &rootOpenedStatus) == 0,
              rootEvidence.matchesDirectory(rootOpenedStatus) else {
            throw ReaderError.unsafeLayout
        }
    }
}
