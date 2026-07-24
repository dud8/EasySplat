import CryptoKit
import Darwin
import Foundation

private func sameStableColmapStatus(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
        && lhs.st_ino == rhs.st_ino
        && lhs.st_mode == rhs.st_mode
        && lhs.st_nlink == rhs.st_nlink
        && lhs.st_uid == rhs.st_uid
        && lhs.st_gid == rhs.st_gid
        && lhs.st_size == rhs.st_size
        && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
        && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
        && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

private func sameStableColmapIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
        && lhs.st_ino == rhs.st_ino
        && lhs.st_mode == rhs.st_mode
        && lhs.st_uid == rhs.st_uid
        && lhs.st_gid == rhs.st_gid
}

private func stableColmapSHA256(descriptor: Int32, expected: stat) throws -> String {
    var hasher = SHA256()
    var offset: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while offset < Int64(expected.st_size) {
        let requested = min(buffer.count, Int(Int64(expected.st_size) - offset))
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.pread(descriptor, bytes.baseAddress, requested, off_t(offset))
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw CocoaError(.fileReadUnknown) }
        hasher.update(data: Data(buffer[0..<count]))
        offset += Int64(count)
    }
    guard offset == Int64(expected.st_size) else {
        throw CocoaError(.fileReadUnknown)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private final class StableColmapDirectoryBinding {
    private struct Component {
        let name: String
        let descriptor: Int32
        let initialStatus: stat
    }

    let descriptor: Int32
    let canonicalPath: String
    private let components: [Component]
    private let allowsLeafContentChanges: Bool

    init(_ url: URL, allowsLeafContentChanges: Bool) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        let canonicalPath = try url.path.withCString { path in
            guard let resolved = Darwin.realpath(path, nil) else {
                throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
            }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        let pathComponents = URL(fileURLWithPath: canonicalPath).pathComponents
        guard pathComponents.first == "/", pathComponents.count > 1 else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }

        var opened: [Component] = []
        do {
            let rootDescriptor = Darwin.open(
                "/",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootDescriptor >= 0 else {
                throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
            }
            var rootStatus = stat()
            guard fstat(rootDescriptor, &rootStatus) == 0,
                  (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(rootDescriptor)
                throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
            }
            opened.append(Component(
                name: "/",
                descriptor: rootDescriptor,
                initialStatus: rootStatus
            ))

            for name in pathComponents.dropFirst() {
                let parentDescriptor = opened[opened.count - 1].descriptor
                let childDescriptor = name.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard childDescriptor >= 0 else {
                    throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
                }
                var childStatus = stat()
                var pathStatus = stat()
                let pathResult = name.withCString {
                    Darwin.fstatat(
                        parentDescriptor,
                        $0,
                        &pathStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard fstat(childDescriptor, &childStatus) == 0,
                      pathResult == 0,
                      sameStableColmapIdentity(childStatus, pathStatus),
                      (childStatus.st_mode & S_IFMT) == S_IFDIR else {
                    Darwin.close(childDescriptor)
                    throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
                }
                opened.append(Component(
                    name: name,
                    descriptor: childDescriptor,
                    initialStatus: childStatus
                ))
            }
            try Self.validate(
                components: opened,
                allowsLeafContentChanges: allowsLeafContentChanges
            )
        } catch {
            for component in opened.reversed() {
                Darwin.close(component.descriptor)
            }
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }

        components = opened
        descriptor = opened[opened.count - 1].descriptor
        self.canonicalPath = canonicalPath
        self.allowsLeafContentChanges = allowsLeafContentChanges
    }

    deinit {
        for component in components.reversed() {
            Darwin.close(component.descriptor)
        }
    }

    func validate() throws {
        do {
            try Self.validate(
                components: components,
                allowsLeafContentChanges: allowsLeafContentChanges
            )
        } catch {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
    }

    private static func validate(
        components: [Component],
        allowsLeafContentChanges: Bool
    ) throws {
        for index in components.indices {
            let component = components[index]
            var descriptorStatus = stat()
            guard fstat(component.descriptor, &descriptorStatus) == 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            guard sameStableColmapIdentity(component.initialStatus, descriptorStatus) else {
                throw CocoaError(.fileReadUnknown)
            }
            guard index > 0 else { continue }
            var pathStatus = stat()
            let pathResult = component.name.withCString {
                Darwin.fstatat(
                    components[index - 1].descriptor,
                    $0,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard pathResult == 0,
                  sameStableColmapIdentity(descriptorStatus, pathStatus) else {
                throw CocoaError(.fileReadUnknown)
            }
        }
    }
}

private final class StableColmapRelativeDirectoryBinding {
    private struct Component {
        let name: String
        let descriptor: Int32
        let initialStatus: stat
    }

    let descriptor: Int32
    let canonicalPath: String
    private let root: StableColmapDirectoryBinding
    private let components: [Component]
    private let allowsLeafContentChanges: Bool

    init(
        rootURL: URL,
        relativePath: String,
        allowsLeafContentChanges: Bool
    ) throws {
        let names = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 4_096,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        let root = try StableColmapDirectoryBinding(
            rootURL,
            allowsLeafContentChanges: false
        )
        var opened: [Component] = []
        do {
            for name in names {
                let parentDescriptor = opened.last?.descriptor ?? root.descriptor
                let descriptor = name.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
                var file = stat()
                var path = stat()
                let pathResult = name.withCString {
                    Darwin.fstatat(parentDescriptor, $0, &path, AT_SYMLINK_NOFOLLOW)
                }
                guard fstat(descriptor, &file) == 0,
                      pathResult == 0,
                      sameStableColmapIdentity(file, path),
                      (file.st_mode & S_IFMT) == S_IFDIR else {
                    Darwin.close(descriptor)
                    throw CocoaError(.fileReadUnknown)
                }
                opened.append(Component(
                    name: name,
                    descriptor: descriptor,
                    initialStatus: file
                ))
            }
            try Self.validate(
                root: root,
                components: opened,
                allowsLeafContentChanges: allowsLeafContentChanges
            )
        } catch {
            for component in opened.reversed() {
                Darwin.close(component.descriptor)
            }
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        self.root = root
        components = opened
        descriptor = opened[opened.count - 1].descriptor
        canonicalPath = root.canonicalPath + "/" + names.joined(separator: "/")
        self.allowsLeafContentChanges = allowsLeafContentChanges
    }

    deinit {
        for component in components.reversed() {
            Darwin.close(component.descriptor)
        }
    }

    func validate() throws {
        do {
            try Self.validate(
                root: root,
                components: components,
                allowsLeafContentChanges: allowsLeafContentChanges
            )
        } catch {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
    }

    private static func validate(
        root: StableColmapDirectoryBinding,
        components: [Component],
        allowsLeafContentChanges: Bool
    ) throws {
        try root.validate()
        for index in components.indices {
            let component = components[index]
            let parentDescriptor = index == 0
                ? root.descriptor
                : components[index - 1].descriptor
            var file = stat()
            var path = stat()
            let pathResult = component.name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &path, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(component.descriptor, &file) == 0, pathResult == 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            guard sameStableColmapIdentity(component.initialStatus, file),
                  sameStableColmapIdentity(file, path) else {
                throw CocoaError(.fileReadUnknown)
            }
        }
    }
}

private func stableColmapDirectoryEntryNames(_ descriptor: Int32) throws -> [String] {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else { throw CocoaError(.fileReadUnknown) }
    guard let stream = Darwin.fdopendir(duplicate) else {
        Darwin.close(duplicate)
        throw CocoaError(.fileReadUnknown)
    }
    defer { Darwin.closedir(stream) }
    Darwin.rewinddir(stream)

    var names: [String] = []
    errno = 0
    while let entry = Darwin.readdir(stream) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        guard name != ".", name != ".." else { continue }
        names.append(name)
        errno = 0
    }
    guard errno == 0, Set(names).count == names.count else {
        throw CocoaError(.fileReadUnknown)
    }
    return names.sorted()
}

private final class StableColmapRuntimeFileBinding {
    let componentPath: String
    let absolutePath: String
    let sha256: String

    private let parent: StableColmapRelativeDirectoryBinding
    private let leafName: String
    private let descriptor: Int32
    private let initialFile: stat

    init(
        rootURL: URL,
        componentPath: String,
        requiresExecutablePermission: Bool
    ) throws {
        let components = componentPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count == 2,
              ColmapRuntimeClosureEvidence.canonicalToolchainRelativePaths
                .contains(componentPath) else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        let leafName = components[1]
        let parent = try StableColmapRelativeDirectoryBinding(
            rootURL: rootURL,
            relativePath: components[0],
            allowsLeafContentChanges: false
        )
        let descriptor = leafName.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }

        var file = stat()
        var path = stat()
        let pathStatus = leafName.withCString {
            Darwin.fstatat(parent.descriptor, $0, &path, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &file) == 0,
              pathStatus == 0,
              sameStableColmapStatus(file, path),
              (file.st_mode & S_IFMT) == S_IFREG,
              file.st_nlink == 1,
              file.st_size > 0,
              !requiresExecutablePermission || file.st_mode & mode_t(0o111) != 0 else {
            Darwin.close(descriptor)
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        let sha256: String
        do {
            sha256 = try stableColmapSHA256(descriptor: descriptor, expected: file)
            var finalFile = stat()
            var finalPath = stat()
            let finalPathStatus = leafName.withCString {
                Darwin.fstatat(parent.descriptor, $0, &finalPath, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(descriptor, &finalFile) == 0,
                  finalPathStatus == 0,
                  sameStableColmapStatus(file, finalFile),
                  sameStableColmapStatus(file, finalPath) else {
                throw CocoaError(.fileReadUnknown)
            }
            try parent.validate()
        } catch {
            Darwin.close(descriptor)
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        self.parent = parent
        self.leafName = leafName
        self.componentPath = componentPath
        self.absolutePath = parent.canonicalPath + "/" + leafName
        self.descriptor = descriptor
        self.initialFile = file
        self.sha256 = sha256
    }

    deinit {
        Darwin.close(descriptor)
    }

    func validateAfterExecution() throws {
        try parent.validate()
        var file = stat()
        var path = stat()
        let pathStatus = leafName.withCString {
            Darwin.fstatat(parent.descriptor, $0, &path, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &file) == 0,
              pathStatus == 0,
              sameStableColmapStatus(initialFile, file),
              sameStableColmapStatus(initialFile, path),
              try stableColmapSHA256(descriptor: descriptor, expected: initialFile) == sha256 else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
    }
}

private final class StableColmapRuntimeClosureBinding {
    let evidence: ColmapRuntimeClosureEvidence
    let launchPath: String
    var executableSHA256: String {
        executable.sha256
    }

    private let executable: StableColmapRuntimeFileBinding
    private let openMPRuntime: StableColmapRuntimeFileBinding

    init(colmapURL: URL) throws {
        let binURL = colmapURL.deletingLastPathComponent()
        let rootURL = binURL.deletingLastPathComponent()
        guard colmapURL.lastPathComponent == "colmap",
              binURL.lastPathComponent == "bin",
              rootURL.path != binURL.path else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        let executable = try StableColmapRuntimeFileBinding(
            rootURL: rootURL,
            componentPath: "bin/colmap",
            requiresExecutablePermission: true
        )
        let openMPRuntime = try StableColmapRuntimeFileBinding(
            rootURL: rootURL,
            componentPath: "lib/libomp.dylib",
            requiresExecutablePermission: false
        )
        guard let evidence = ColmapRuntimeClosureEvidence.canonical(
            executableSHA256: executable.sha256,
            openMPSHA256: openMPRuntime.sha256
        ) else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        self.executable = executable
        self.openMPRuntime = openMPRuntime
        self.evidence = evidence
        launchPath = executable.absolutePath
    }

    func validateAfterExecution() throws {
        try executable.validateAfterExecution()
        try openMPRuntime.validateAfterExecution()
    }
}

private final class StableColmapModelInputBinding {
    private struct Member {
        let name: String
        let descriptor: Int32
        let initialStatus: stat
        let sha256: String
    }

    let modelDigest: String
    var canonicalPath: String { directory.canonicalPath }
    private let directory: StableColmapRelativeDirectoryBinding
    private let members: [Member]

    init(projectRootURL: URL, projectRelativePath: String) throws {
        let directory = try StableColmapRelativeDirectoryBinding(
            rootURL: projectRootURL,
            relativePath: projectRelativePath,
            allowsLeafContentChanges: false
        )
        let names = ["cameras.bin", "images.bin", "points3D.bin"]
        var members: [Member] = []
        do {
            guard try stableColmapDirectoryEntryNames(directory.descriptor) == names.sorted() else {
                throw CocoaError(.fileReadUnknown)
            }
            for name in names {
                let descriptor = name.withCString {
                    Darwin.openat(
                        directory.descriptor,
                        $0,
                        O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                    )
                }
                guard descriptor >= 0 else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                var file = stat()
                var path = stat()
                let pathStatus = name.withCString {
                    Darwin.fstatat(
                        directory.descriptor,
                        $0,
                        &path,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard fstat(descriptor, &file) == 0,
                      pathStatus == 0,
                      sameStableColmapStatus(file, path),
                      (file.st_mode & S_IFMT) == S_IFREG,
                      file.st_nlink == 1 else {
                    Darwin.close(descriptor)
                    throw CocoaError(.fileReadUnknown)
                }
                let digest: String
                do {
                    digest = try stableColmapSHA256(descriptor: descriptor, expected: file)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
                members.append(Member(
                    name: name,
                    descriptor: descriptor,
                    initialStatus: file,
                    sha256: digest
                ))
            }
            try Self.validate(directory: directory, members: members)
        } catch {
            for member in members.reversed() {
                Darwin.close(member.descriptor)
            }
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        let hashes = Dictionary(uniqueKeysWithValues: members.map { ($0.name, $0.sha256) })
        guard let modelDigest = GeometryArtifactStore.modelClosureDigest(
            hashes,
            expectedNames: names
        ) else {
            for member in members.reversed() {
                Darwin.close(member.descriptor)
            }
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        self.directory = directory
        self.members = members
        self.modelDigest = modelDigest
    }

    deinit {
        for member in members.reversed() {
            Darwin.close(member.descriptor)
        }
    }

    func validateAfterExecution() throws {
        do {
            try Self.validate(directory: directory, members: members)
        } catch {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
    }

    private static func validate(
        directory: StableColmapRelativeDirectoryBinding,
        members: [Member]
    ) throws {
        try directory.validate()
        guard try stableColmapDirectoryEntryNames(directory.descriptor)
            == members.map(\.name).sorted() else {
            throw CocoaError(.fileReadUnknown)
        }
        for member in members {
            var file = stat()
            var path = stat()
            let pathStatus = member.name.withCString {
                Darwin.fstatat(
                    directory.descriptor,
                    $0,
                    &path,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard fstat(member.descriptor, &file) == 0,
                  pathStatus == 0,
                  sameStableColmapStatus(member.initialStatus, file),
                  sameStableColmapStatus(member.initialStatus, path),
                  try stableColmapSHA256(
                      descriptor: member.descriptor,
                      expected: member.initialStatus
                  ) == member.sha256 else {
                throw CocoaError(.fileReadUnknown)
            }
        }
    }
}

private final class StableColmapModelOutputBinding {
    private struct Member {
        let name: String
        let descriptor: Int32
        let initialStatus: stat
        let sha256: String
    }

    private let directory: StableColmapRelativeDirectoryBinding
    var canonicalPath: String { directory.canonicalPath }

    init(projectRootURL: URL, projectRelativePath: String) throws {
        directory = try StableColmapRelativeDirectoryBinding(
            rootURL: projectRootURL,
            relativePath: projectRelativePath,
            allowsLeafContentChanges: true
        )
        guard try stableColmapDirectoryEntryNames(directory.descriptor).isEmpty else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
    }

    func validateAfterExecution() throws {
        try directory.validate()
    }

    func modelDigest() throws -> String {
        let canonicalNames = ["cameras.txt", "images.txt", "points3D.txt"]
        let allowedNames = Set(canonicalNames + ["frames.txt", "rigs.txt"])
        var members: [Member] = []
        try directory.validate()
        let names = try stableColmapDirectoryEntryNames(directory.descriptor)
        let nameSet = Set(names)
        guard Set(canonicalNames).isSubset(of: nameSet),
              nameSet.isSubset(of: allowedNames) else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        do {
            for name in names {
                let descriptor = name.withCString {
                    Darwin.openat(
                        directory.descriptor,
                        $0,
                        O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                    )
                }
                guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
                var file = stat()
                var path = stat()
                let pathResult = name.withCString {
                    Darwin.fstatat(
                        directory.descriptor,
                        $0,
                        &path,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard fstat(descriptor, &file) == 0,
                      pathResult == 0,
                      sameStableColmapStatus(file, path),
                      (file.st_mode & S_IFMT) == S_IFREG,
                      file.st_nlink == 1 else {
                    Darwin.close(descriptor)
                    throw CocoaError(.fileReadUnknown)
                }
                let digest: String
                do {
                    digest = try stableColmapSHA256(descriptor: descriptor, expected: file)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
                members.append(Member(
                    name: name,
                    descriptor: descriptor,
                    initialStatus: file,
                    sha256: digest
                ))
            }
            try validateMembers(members, expectedNames: names)
        } catch {
            for member in members.reversed() { Darwin.close(member.descriptor) }
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        defer {
            for member in members.reversed() { Darwin.close(member.descriptor) }
        }
        let canonicalHashes = Dictionary(uniqueKeysWithValues: members.compactMap { member in
            canonicalNames.contains(member.name) ? (member.name, member.sha256) : nil
        })
        guard let digest = GeometryArtifactStore.modelClosureDigest(
            canonicalHashes,
            expectedNames: canonicalNames
        ) else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        return digest
    }

    private func validateMembers(_ members: [Member], expectedNames: [String]) throws {
        try directory.validate()
        guard try stableColmapDirectoryEntryNames(directory.descriptor)
            == expectedNames.sorted() else {
            throw CocoaError(.fileReadUnknown)
        }
        for member in members {
            var file = stat()
            var path = stat()
            let pathResult = member.name.withCString {
                Darwin.fstatat(
                    directory.descriptor,
                    $0,
                    &path,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard fstat(member.descriptor, &file) == 0,
                  pathResult == 0,
                  sameStableColmapStatus(member.initialStatus, file),
                  sameStableColmapStatus(member.initialStatus, path),
                  try stableColmapSHA256(
                    descriptor: member.descriptor,
                    expected: member.initialStatus
                  ) == member.sha256 else {
                throw CocoaError(.fileReadUnknown)
            }
        }
    }
}

/// Bundle-adjustment parameters used when refining a sparse model with COLMAP.
public struct ColmapBundleAdjustmentOptions: Sendable {
    public var maxNumIterations: Int
    public var refineFocalLength: Bool
    public var refinePrincipalPoint: Bool
    public var refineExtraParams: Bool
    /// When false, camera poses are held constant and only structure (and
    /// any enabled intrinsics) are refined. Imported-pose datasets rely on
    /// this: their extrinsics are the trusted input, not a free variable.
    public var refineExtrinsics: Bool

    public init(
        maxNumIterations: Int = 50,
        refineFocalLength: Bool = true,
        refinePrincipalPoint: Bool = false,
        refineExtraParams: Bool = false,
        refineExtrinsics: Bool = true
    ) {
        self.maxNumIterations = max(1, maxNumIterations)
        self.refineFocalLength = refineFocalLength
        self.refinePrincipalPoint = refinePrincipalPoint
        self.refineExtraParams = refineExtraParams
        self.refineExtrinsics = refineExtrinsics
    }
}

public enum ColmapMapperOptionsValidationError: Error, LocalizedError, Equatable {
    case invalidRatio(String)
    case invalidTolerance(String)
    case nonPositiveValue(String)
    case randomSeedOutOfRange

    public var errorDescription: String? {
        switch self {
        case .invalidRatio(let name):
            return "\(name) must be finite and greater than one."
        case .invalidTolerance(let name):
            return "\(name) must be finite and nonnegative."
        case .nonPositiveValue(let name):
            return "\(name) must be greater than zero."
        case .randomSeedOutOfRange:
            return "Mapper random seed must fit in a signed 32-bit integer."
        }
    }
}

enum ColmapMappingPolicy {
    static let minimumPairInlierCount = 15
    static let maximumAcceptedRecoverableViewLoss = 2
}

/// Fixed incremental-mapper policy passed across the native COLMAP process boundary.
public struct ColmapMapperOptions: Sendable, Equatable {
    public let globalFramesRatio: Double
    public let globalPointsRatio: Double
    public let localMaxRefinements: Int
    public let globalMaxRefinements: Int
    public let globalMaxNumIterations: Int
    public let localMaxNumIterations: Int
    public let localFunctionTolerance: Double
    public let globalFunctionTolerance: Double
    public let localImageCount: Int
    public let randomSeed: Int32
    public let refineFocalLength: Bool

    public init(
        globalFramesRatio: Double,
        globalPointsRatio: Double,
        localMaxRefinements: Int,
        globalMaxRefinements: Int,
        globalMaxNumIterations: Int,
        localMaxNumIterations: Int = 10,
        localFunctionTolerance: Double = 0.001,
        globalFunctionTolerance: Double = 0.000_001,
        localImageCount: Int = 6,
        randomSeed: UInt64,
        refineFocalLength: Bool
    ) throws {
        guard globalFramesRatio.isFinite, globalFramesRatio > 1 else {
            throw ColmapMapperOptionsValidationError.invalidRatio("Global frame ratio")
        }
        guard globalPointsRatio.isFinite, globalPointsRatio > 1 else {
            throw ColmapMapperOptionsValidationError.invalidRatio("Global point ratio")
        }
        guard localMaxRefinements > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Local refinement limit")
        }
        guard globalMaxRefinements > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Global refinement limit")
        }
        guard globalMaxNumIterations > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Global iteration limit")
        }
        guard localMaxNumIterations > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Local iteration limit")
        }
        guard localFunctionTolerance.isFinite, localFunctionTolerance >= 0 else {
            throw ColmapMapperOptionsValidationError.invalidTolerance("Local function tolerance")
        }
        guard globalFunctionTolerance.isFinite, globalFunctionTolerance >= 0 else {
            throw ColmapMapperOptionsValidationError.invalidTolerance("Global function tolerance")
        }
        guard localImageCount > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Local image count")
        }
        guard let randomSeed = Int32(exactly: randomSeed) else {
            throw ColmapMapperOptionsValidationError.randomSeedOutOfRange
        }

        self.globalFramesRatio = globalFramesRatio
        self.globalPointsRatio = globalPointsRatio
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
}

public enum ColmapVocabularyRetrievalOptionsValidationError: Error, LocalizedError, Equatable {
    case candidateCountOutOfRange
    case neighborCountOutOfRange
    case neighborCountExceedsCandidateCount
    case minimumFrameSeparationOutOfRange
    case queryStrideOutOfRange
    case threadCountOutOfRange
    case memoryBudgetOutOfRange

    public var errorDescription: String? {
        switch self {
        case .candidateCountOutOfRange:
            return "Vocabulary candidate count must be between 1 and 256."
        case .neighborCountOutOfRange:
            return "Vocabulary neighbor count must be between 1 and 64."
        case .neighborCountExceedsCandidateCount:
            return "Vocabulary neighbor count cannot exceed the candidate count."
        case .minimumFrameSeparationOutOfRange:
            return "Vocabulary frame separation must be between 0 and 1,000,000."
        case .queryStrideOutOfRange:
            return "Vocabulary query stride must be between 1 and 1,000,000."
        case .threadCountOutOfRange:
            return "Vocabulary retrieval thread count must be between 1 and 64."
        case .memoryBudgetOutOfRange:
            return "Vocabulary retrieval memory budget must be between 64 MiB and 256 GiB."
        }
    }
}

/// Bounded inputs for EasySplat's project-local SIFT vocabulary process boundary.
public struct ColmapVocabularyRetrievalOptions: Sendable, Equatable {
    /// Memory-budget limits mirror the native `local_vocab_retriever`
    /// constants (`kMinimumMemoryBudgetBytes` / `kMaximumMemoryBudgetBytes` /
    /// `kDefaultMemoryBudgetBytes`). The default matches the tool's built-in
    /// value so callers that omit an explicit budget keep the historical size.
    public static let minimumMemoryBudgetBytes: Int64 = 64 * 1_048_576
    public static let maximumMemoryBudgetBytes: Int64 = 256 * 1_024 * 1_048_576
    public static let defaultMemoryBudgetBytes: Int64 = 2 * 1_024 * 1_048_576

    public let candidateCount: Int
    public let returnedNeighborCount: Int
    public let minimumFrameSeparation: Int
    public let queryStride: Int
    public let threadCount: Int
    public let memoryBudgetBytes: Int64

    public init(
        candidateCount: Int,
        returnedNeighborCount: Int,
        minimumFrameSeparation: Int,
        queryStride: Int,
        threadCount: Int,
        memoryBudgetBytes: Int64 = ColmapVocabularyRetrievalOptions.defaultMemoryBudgetBytes
    ) throws {
        guard (1...256).contains(candidateCount) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.candidateCountOutOfRange
        }
        guard (1...64).contains(returnedNeighborCount) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.neighborCountOutOfRange
        }
        guard returnedNeighborCount <= candidateCount else {
            throw ColmapVocabularyRetrievalOptionsValidationError.neighborCountExceedsCandidateCount
        }
        guard (0...1_000_000).contains(minimumFrameSeparation) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.minimumFrameSeparationOutOfRange
        }
        guard (1...1_000_000).contains(queryStride) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.queryStrideOutOfRange
        }
        guard (1...64).contains(threadCount) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.threadCountOutOfRange
        }
        guard (Self.minimumMemoryBudgetBytes...Self.maximumMemoryBudgetBytes)
            .contains(memoryBudgetBytes) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.memoryBudgetOutOfRange
        }
        self.candidateCount = candidateCount
        self.returnedNeighborCount = returnedNeighborCount
        self.minimumFrameSeparation = minimumFrameSeparation
        self.queryStride = queryStride
        self.threadCount = threadCount
        self.memoryBudgetBytes = memoryBudgetBytes
    }
}

/// Shared COLMAP feature extraction and matching options.
public struct ColmapOptions: Sendable {
    public var useGPU: Bool
    public var extractThreads: Int
    public var matchThreads: Int
    public var maxNumFeatures: Int?
    public var maxNumMatches: Int?
    public var descriptorMatcher: DescriptorMatcher
    public var environment: [String: String]

    public init(
        useGPU: Bool,
        extractThreads: Int,
        matchThreads: Int,
        maxNumFeatures: Int? = nil,
        maxNumMatches: Int? = nil,
        descriptorMatcher: DescriptorMatcher = .faiss,
        environment: [String: String] = [:]
    ) {
        self.useGPU = useGPU
        self.extractThreads = extractThreads
        self.matchThreads = matchThreads
        self.maxNumFeatures = maxNumFeatures
        self.maxNumMatches = maxNumMatches
        self.descriptorMatcher = descriptorMatcher
        self.environment = environment
    }

}

public enum ColmapMatchesImporterOptionsValidationError: Error, LocalizedError, Equatable {
    case randomSeedOutOfRange

    public var errorDescription: String? {
        "Two-view geometry random seed must fit in a signed 32-bit integer."
    }
}

public enum ColmapRunnerError: Error, LocalizedError {
    case failed(command: String, exitCode: Int32, terminationReason: Process.TerminationReason, stdoutTail: String, stderrTail: String)
    case executionEvidenceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .failed(command, exitCode, terminationReason, _, _):
            return "Colmap failed: \(command) (exit \(exitCode), reason: \(terminationReason))"
        case .executionEvidenceUnavailable(let command):
            return "COLMAP did not expose verified launch evidence for \(command)."
        }
    }
}

public struct ColmapPairWorkerInvocationContext: Sendable, Equatable {
    public let attemptOrdinal: Int
    public let descriptorMatcher: DescriptorMatcher
    public let scheduledPairCount: Int?
    public let pairListDigest: String?
    public let exactRecoveryReason: DescriptorMatcherRecoveryReason?
    public let retrievalRequestDigest: String?
    public let retrievalOutputDigest: String?
    public let retrievalOutputURL: URL?

    public init(
        attemptOrdinal: Int,
        descriptorMatcher: DescriptorMatcher,
        scheduledPairCount: Int? = nil,
        pairListDigest: String? = nil,
        exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil,
        retrievalRequestDigest: String? = nil,
        retrievalOutputDigest: String? = nil,
        retrievalOutputURL: URL? = nil
    ) {
        self.attemptOrdinal = attemptOrdinal
        self.descriptorMatcher = descriptorMatcher
        self.scheduledPairCount = scheduledPairCount
        self.pairListDigest = pairListDigest
        self.exactRecoveryReason = exactRecoveryReason
        self.retrievalRequestDigest = retrievalRequestDigest
        self.retrievalOutputDigest = retrievalOutputDigest
        self.retrievalOutputURL = retrievalOutputURL
    }
}

public struct ColmapMapperWorkerInvocationContext: Sendable, Equatable {
    public let pairGraphAttemptOrdinal: Int
    public let pairListDigest: String
    public let descriptorMatcher: DescriptorMatcher
    public let matchingDatabaseDigest: String

    public init(
        pairGraphAttemptOrdinal: Int,
        pairListDigest: String,
        descriptorMatcher: DescriptorMatcher,
        matchingDatabaseDigest: String
    ) {
        self.pairGraphAttemptOrdinal = pairGraphAttemptOrdinal
        self.pairListDigest = pairListDigest
        self.descriptorMatcher = descriptorMatcher
        self.matchingDatabaseDigest = matchingDatabaseDigest
    }
}

public struct ColmapModelConversionWorkerInvocationContext: Sendable, Equatable {
    public let mappingAttemptOrdinal: Int
    public let projectRootURL: URL
    public let candidateProjectRelativePath: String
    public let inputProjectRelativePath: String
    public let outputProjectRelativePath: String
    public let inputURL: URL
    public let outputURL: URL

    public init(
        mappingAttemptOrdinal: Int,
        projectRootURL: URL,
        candidateProjectRelativePath: String,
        inputProjectRelativePath: String,
        outputProjectRelativePath: String,
        inputURL: URL,
        outputURL: URL
    ) {
        self.mappingAttemptOrdinal = mappingAttemptOrdinal
        self.projectRootURL = projectRootURL
        self.candidateProjectRelativePath = candidateProjectRelativePath
        self.inputProjectRelativePath = inputProjectRelativePath
        self.outputProjectRelativePath = outputProjectRelativePath
        self.inputURL = inputURL
        self.outputURL = outputURL
    }
}

/// Subprocess-backed wrapper around the COLMAP command-line tools.
public final class ColmapRunner: @unchecked Sendable {
    private static let inheritedThreadEnvironmentKeys = Set(
        GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys
    )
    private static let dynamicLoaderEnvironmentKeys: Set<String> = [
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FORCE_FLAT_NAMESPACE",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_IMAGE_SUFFIX",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_ROOT_PATH",
        "DYLD_SHARED_CACHE_DIR",
        "DYLD_SHARED_CACHE_DONT_VALIDATE",
        "DYLD_SHARED_REGION",
        "DYLD_USE_CLOSURES",
        "DYLD_VERSIONED_FRAMEWORK_PATH",
        "DYLD_VERSIONED_LIBRARY_PATH",
    ]
    private static let inheritedProcessEnvironmentKeys: Set<String> = {
        inheritedThreadEnvironmentKeys
            .union(dynamicLoaderEnvironmentKeys)
            .union(RuntimeEnvironment.current.keys.filter { $0.hasPrefix("DYLD_") })
    }()

    private let runner: SubprocessRunning
    private let observerLock = NSLock()
    private var workerExecutionObserver: (
        @Sendable (ColmapWorkerInvocationEvidence) throws -> Void
    )?

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func captureRuntimeClosure(
        colmapPath: URL
    ) throws -> ColmapRuntimeClosureEvidence {
        let binding = try StableColmapRuntimeClosureBinding(colmapURL: colmapPath)
        try binding.validateAfterExecution()
        return binding.evidence
    }

    public func setWorkerExecutionObserver(
        _ observer: (@Sendable (ColmapWorkerInvocationEvidence) throws -> Void)?
    ) {
        observerLock.withLock {
            workerExecutionObserver = observer
        }
    }

    private static func boundedWorkerEnvironment(
        _ environment: [String: String],
        workerCount: Int
    ) -> [String: String] {
        var bounded = sanitizedNativeAutoEnvironment(environment)
        let value = "\(workerCount)"
        bounded["OMP_NUM_THREADS"] = value
        bounded["OPENBLAS_NUM_THREADS"] = value
        bounded["MKL_NUM_THREADS"] = value
        return bounded
    }

    private static func sanitizedNativeAutoEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.filter {
            !inheritedThreadEnvironmentKeys.contains($0.key)
                && !$0.key.hasPrefix("DYLD_")
        }
    }

    private func recordWorkerExecution(
        command: ColmapWorkerCommandIdentity,
        threadPolicy: GeometryWorkerThreadPolicy,
        argvWorkerCount: Int?,
        pairContext: ColmapPairWorkerInvocationContext?,
        mapperExecution: ColmapMapperWorkerExecutionEvidence? = nil,
        modelConversion: ColmapModelConversionWorkerEvidence? = nil,
        result: SubprocessResult
    ) throws {
        guard let observer = observerLock.withLock({ workerExecutionObserver }) else {
            return
        }
        guard let receipt = result.environmentReceipt,
              receipt.removedKeys.isSuperset(of: Self.inheritedProcessEnvironmentKeys),
              receipt.removedKeys
                  .subtracting(Self.inheritedProcessEnvironmentKeys)
                  .isSubset(of: SubprocessRunner.ambientSensitiveEnvironmentKeys()) else {
            throw ColmapRunnerError.executionEvidenceUnavailable(command.rawValue)
        }
        let threadKeys = Self.inheritedThreadEnvironmentKeys
        let explicitThreadEnvironment = receipt.explicitOverrides.filter {
            threadKeys.contains($0.key)
        }
        let effectiveThreadEnvironment = receipt.effectiveValuesForControlledKeys.filter {
            threadKeys.contains($0.key)
        }
        let succeeded = result.exitCode == 0 && result.terminationReason == .exit
        let pairExecution: ColmapPairWorkerExecutionEvidence?
        if let pairContext {
            let outputDigest: String?
            if succeeded, let outputURL = pairContext.retrievalOutputURL {
                let output = try BoundedFileReader.readRegularFile(
                    at: outputURL,
                    maximumBytes: 64 * 1_024 * 1_024
                )
                guard let text = String(data: output, encoding: .utf8) else {
                    throw ColmapRunnerError.executionEvidenceUnavailable(command.rawValue)
                }
                outputDigest = PairGraphEvidenceStore.retrievalOutputDigest(
                    lines: text.split(whereSeparator: \.isNewline).map(String.init)
                )
            } else {
                outputDigest = pairContext.retrievalOutputDigest
            }
            pairExecution = ColmapPairWorkerExecutionEvidence(
                attemptOrdinal: pairContext.attemptOrdinal,
                descriptorMatcher: pairContext.descriptorMatcher,
                scheduledPairCount: pairContext.scheduledPairCount,
                pairListDigest: pairContext.pairListDigest,
                exactRecoveryReason: pairContext.exactRecoveryReason,
                retrievalRequestDigest: pairContext.retrievalRequestDigest,
                retrievalOutputDigest: outputDigest
            )
        } else {
            pairExecution = nil
        }
        try observer(ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: nil,
            threadPolicy: threadPolicy,
            argvWorkerCount: argvWorkerCount,
            explicitThreadEnvironment: explicitThreadEnvironment,
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: effectiveThreadEnvironment,
            pairExecution: pairExecution,
            mapperExecution: mapperExecution,
            modelConversion: modelConversion,
            exitStatus: result.exitCode,
            succeeded: succeeded
        ))
    }

    private func workerTerminationHandler(
        command: ColmapWorkerCommandIdentity,
        threadPolicy: GeometryWorkerThreadPolicy,
        argvWorkerCount: Int?,
        pairContext: ColmapPairWorkerInvocationContext? = nil,
        mapperExecution: ColmapMapperWorkerExecutionEvidence? = nil
    ) -> @Sendable (SubprocessResult) throws -> Void {
        { [self] result in
            try recordWorkerExecution(
                command: command,
                threadPolicy: threadPolicy,
                argvWorkerCount: argvWorkerCount,
                pairContext: pairContext,
                mapperExecution: mapperExecution,
                modelConversion: nil,
                result: result
            )
        }
    }

    public func runFeatureExtractor(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        maxImageSize: Int,
        cameraInitialization: ColmapCameraInitializationReceipt,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        guard cameraInitialization.isValid else {
            throw ColmapCameraInitializationReceipt.ResolutionError.invalidConfiguration
        }
        let args = [
            "feature_extractor",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--ImageReader.single_camera", cameraInitialization.singleCamera ? "1" : "0",
            "--ImageReader.camera_model", cameraInitialization.cameraModel,
            "--FeatureExtraction.max_image_size", "\(maxImageSize)",
            "--FeatureExtraction.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureExtraction.num_threads", "\(options.extractThreads)"
        ]
        var finalArgs = args
        if let cameraParameters = cameraInitialization.colmapCameraParameterArgument {
            finalArgs.append(contentsOf: [
                "--ImageReader.camera_params", cameraParameters,
            ])
        }
        if let maxNumFeatures = options.maxNumFeatures {
            finalArgs.append(contentsOf: ["--SiftExtraction.max_num_features", "\(maxNumFeatures)"])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(finalArgs.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            finalArgs,
            currentDirectory: nil,
            environment: Self.boundedWorkerEnvironment(
                options.environment,
                workerCount: options.extractThreads
            ),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .featureExtractor,
                threadPolicy: .bounded,
                argvWorkerCount: options.extractThreads
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "feature_extractor")
    }

    public func runFeatureImporter(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        importPath: URL,
        cameraModel: String,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "feature_importer",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--import_path", importPath.path,
            "--ImageReader.single_camera", "1",
            "--ImageReader.camera_model", cameraModel,
            "--FeatureExtraction.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureExtraction.num_threads", "\(options.extractThreads)"
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.boundedWorkerEnvironment(
                options.environment,
                workerCount: options.extractThreads
            ),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .featureImporter,
                threadPolicy: .bounded,
                argvWorkerCount: options.extractThreads
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "feature_importer")
    }

    public func runMatchesImporter(
        colmapPath: URL,
        database: URL,
        matchListPath: URL,
        matchType: String,
        randomSeed: UInt64,
        options: ColmapOptions,
        pairContext: ColmapPairWorkerInvocationContext? = nil,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        guard let randomSeed = Int32(exactly: randomSeed) else {
            throw ColmapMatchesImporterOptionsValidationError.randomSeedOutOfRange
        }
        let args = [
            "matches_importer",
            "--database_path", database.path,
            "--match_list_path", matchListPath.path,
            "--match_type", matchType,
            "--EasySplat.require_empty_matching_results", "1",
            "--TwoViewGeometry.random_seed", "\(randomSeed)",
            "--FeatureMatching.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureMatching.num_threads", "\(options.matchThreads)"
        ]
        var finalArgs = args
        if let maxNumMatches = options.maxNumMatches {
            finalArgs.append(contentsOf: ["--FeatureMatching.max_num_matches", "\(maxNumMatches)"])
        }
        finalArgs.append(contentsOf: [
            "--SiftMatching.cpu_brute_force_matcher",
            options.descriptorMatcher == .exact ? "1" : "0",
        ])
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(finalArgs.joined(separator: " "))", false)
        try ColmapDatabaseMatchStore.requireMatchingResultsEmpty(at: database)
        let result = try await runner.runAsync(
            colmapPath.path,
            finalArgs,
            currentDirectory: nil,
            environment: Self.boundedWorkerEnvironment(
                options.environment,
                workerCount: options.matchThreads
            ),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .matchesImporter,
                threadPolicy: .bounded,
                argvWorkerCount: options.matchThreads,
                pairContext: pairContext
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "matches_importer")
    }

    public func runLocalVocabularyRetriever(
        colmapPath: URL,
        database: URL,
        outputPairListPath: URL,
        queryImageListPath: URL?,
        excludedPairListPath: URL?,
        imageGroupListPath: URL? = nil,
        imageGroupListDigest: String? = nil,
        options: ColmapVocabularyRetrievalOptions,
        pairContext: ColmapPairWorkerInvocationContext? = nil,
        environment: [String: String] = [:],
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        guard let pairContext,
              let requestDigest = pairContext.retrievalRequestDigest,
              requestDigest.count == 64,
              requestDigest.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }),
              pairContext.attemptOrdinal > 0,
              pairContext.retrievalOutputURL == outputPairListPath,
              pairContext.pairListDigest == nil,
              pairContext.retrievalOutputDigest == nil,
              (imageGroupListPath == nil) == (imageGroupListDigest == nil),
              imageGroupListDigest.map({ digest in
                  digest.count == 64
                      && digest.utf8.allSatisfy({ byte in
                          (48...57).contains(byte) || (97...102).contains(byte)
                      })
              }) ?? true else {
            throw ColmapRunnerError.executionEvidenceUnavailable(
                "local_vocab_retriever"
            )
        }
        var args = [
            "local_vocab_retriever",
            "--database_path", database.path,
            "--output_pair_list_path", outputPairListPath.path,
            "--num_images", "\(options.candidateCount)",
            "--returned_neighbor_count", "\(options.returnedNeighborCount)",
            "--minimum_frame_separation", "\(options.minimumFrameSeparation)",
            "--query_stride", "\(options.queryStride)",
            "--request_digest", requestDigest,
            "--num_visual_words", "512",
            "--max_features_per_image", "512",
            "--max_training_descriptors", "65536",
            "--num_iterations", "10",
            "--num_rounds", "1",
            "--num_checks", "64",
            "--num_threads", "\(options.threadCount)",
            "--memory_budget_bytes", "\(options.memoryBudgetBytes)",
        ]
        if let queryImageListPath {
            args.append(contentsOf: ["--query_image_list_path", queryImageListPath.path])
        }
        if let excludedPairListPath {
            args.append(contentsOf: ["--excluded_pair_list_path", excludedPairListPath.path])
        }
        if let imageGroupListPath, let imageGroupListDigest {
            args.append(contentsOf: [
                "--image_group_list_path", imageGroupListPath.path,
                "--image_group_list_digest", imageGroupListDigest,
            ])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.boundedWorkerEnvironment(
                environment,
                workerCount: options.threadCount
            ),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .localVocabularyRetriever,
                threadPolicy: .bounded,
                argvWorkerCount: options.threadCount,
                pairContext: pairContext
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "local_vocab_retriever")
    }

    public func runMapper(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        outputPath: URL,
        environment: [String: String],
        mapperOptions: ColmapMapperOptions,
        mapperContext: ColmapMapperWorkerInvocationContext,
        emitSolverReports: Bool = false,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        var args = [
            "mapper",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--output_path", outputPath.path,
            "--Mapper.ba_global_frames_ratio", "\(mapperOptions.globalFramesRatio)",
            "--Mapper.ba_global_points_ratio", "\(mapperOptions.globalPointsRatio)",
            "--Mapper.ba_local_max_refinements", "\(mapperOptions.localMaxRefinements)",
            "--Mapper.ba_global_max_refinements", "\(mapperOptions.globalMaxRefinements)",
            "--Mapper.ba_global_max_num_iterations", "\(mapperOptions.globalMaxNumIterations)",
            "--Mapper.ba_local_max_num_iterations", "\(mapperOptions.localMaxNumIterations)",
            "--Mapper.ba_local_function_tolerance", "\(mapperOptions.localFunctionTolerance)",
            "--Mapper.ba_global_function_tolerance", "\(mapperOptions.globalFunctionTolerance)",
            "--Mapper.ba_local_num_images", "\(mapperOptions.localImageCount)",
            "--Mapper.random_seed", "\(mapperOptions.randomSeed)",
            "--Mapper.min_num_matches", "\(ColmapMappingPolicy.minimumPairInlierCount)",
            "--Mapper.ba_refine_focal_length", mapperOptions.refineFocalLength ? "1" : "0",
        ]
        if emitSolverReports {
            args.append(contentsOf: ["--log_level", "1"])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .mapper,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil,
                mapperExecution: ColmapMapperWorkerExecutionEvidence(
                    incrementalCadence: IncrementalMappingCadenceArtifact(
                        localMaxRefinements: mapperOptions.localMaxRefinements,
                        globalFramesRatio: mapperOptions.globalFramesRatio,
                        globalPointsRatio: mapperOptions.globalPointsRatio,
                        globalMaxRefinements: mapperOptions.globalMaxRefinements,
                        localMaxNumIterations: mapperOptions.localMaxNumIterations,
                        localFunctionTolerance: mapperOptions.localFunctionTolerance,
                        globalFunctionTolerance: mapperOptions.globalFunctionTolerance,
                        localImageCount: mapperOptions.localImageCount
                    ),
                    globalMaxNumIterations: mapperOptions.globalMaxNumIterations,
                    randomSeed: mapperOptions.randomSeed,
                    refineFocalLength: mapperOptions.refineFocalLength,
                    minimumPairInlierCount: ColmapMappingPolicy.minimumPairInlierCount,
                    pairGraphAttemptOrdinal: mapperContext.pairGraphAttemptOrdinal,
                    pairListDigest: mapperContext.pairListDigest,
                    descriptorMatcher: mapperContext.descriptorMatcher,
                    matchingDatabaseDigest: mapperContext.matchingDatabaseDigest,
                    evaluation: nil
                )
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "mapper")
    }

    public func runPointTriangulator(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        inputPath: URL,
        outputPath: URL,
        environment: [String: String],
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "point_triangulator",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--input_path", inputPath.path,
            "--output_path", outputPath.path
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .pointTriangulator,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "point_triangulator")
    }

    public func runBundleAdjuster(
        colmapPath: URL,
        inputPath: URL,
        outputPath: URL,
        environment: [String: String],
        bundleOptions: ColmapBundleAdjustmentOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: outputPath.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                try fm.removeItem(at: outputPath)
                try fm.createDirectory(at: outputPath, withIntermediateDirectories: true)
            }
        } else {
            try fm.createDirectory(at: outputPath, withIntermediateDirectories: true)
        }

        let args = [
            "bundle_adjuster",
            "--input_path", inputPath.path,
            "--output_path", outputPath.path,
            "--BundleAdjustment.refine_focal_length", bundleOptions.refineFocalLength ? "1" : "0",
            "--BundleAdjustment.refine_principal_point", bundleOptions.refinePrincipalPoint ? "1" : "0",
            "--BundleAdjustment.refine_extra_params", bundleOptions.refineExtraParams ? "1" : "0",
            "--BundleAdjustment.refine_extrinsics", bundleOptions.refineExtrinsics ? "1" : "0",
            "--BundleAdjustmentCeres.max_num_iterations", "\(max(1, bundleOptions.maxNumIterations))"
        ]

        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .bundleAdjuster,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "bundle_adjuster")
    }

    public func runModelAnalyzer(
        colmapPath: URL,
        modelPath: URL,
        environment: [String: String]
    ) async throws -> String {
        let args = ["model_analyzer", "--path", modelPath.path]
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .modelAnalyzer,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil
            ),
            onStdout: { _ in },
            onStderr: { _ in }
        )
        try checkResult(result, command: "model_analyzer")
        // COLMAP tools sometimes print reports to stderr even on success; return combined output.
        return [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public func runImageUndistorter(
        colmapPath: URL,
        imagePath: URL,
        inputPath: URL,
        outputPath: URL,
        maxImageSize: Int,
        environment: [String: String] = [:],
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "image_undistorter",
            "--image_path", imagePath.path,
            "--input_path", inputPath.path,
            "--output_path", outputPath.path,
            "--output_type", "COLMAP",
            "--copy_policy", "COPY",
            "--max_image_size", "\(max(1, maxImageSize))",
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "image_undistorter")
    }

    public func runModelConverter(
        colmapPath: URL,
        inputPath: URL,
        outputPath: URL,
        outputType: String = "TXT",
        environment: [String: String] = [:],
        recordGeometryWorkerExecution: Bool = false,
        modelConversionContext: ColmapModelConversionWorkerInvocationContext? = nil,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) throws {
        guard recordGeometryWorkerExecution == (modelConversionContext != nil) else {
            throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
        }
        let runtimeClosureBinding = recordGeometryWorkerExecution
            ? try StableColmapRuntimeClosureBinding(colmapURL: colmapPath)
            : nil
        let inputBinding: StableColmapModelInputBinding?
        let outputBinding: StableColmapModelOutputBinding?
        let sourceDigest: String?
        let candidateIdentity: String?
        if let context = modelConversionContext {
            let expectedInput = context.projectRootURL.appendingPathComponent(
                context.inputProjectRelativePath,
                isDirectory: true
            )
            let expectedOutput = context.projectRootURL.appendingPathComponent(
                context.outputProjectRelativePath,
                isDirectory: true
            )
            guard inputPath.path == context.inputURL.path,
                  outputPath.path == context.outputURL.path,
                  context.inputURL.path == expectedInput.path,
                  context.outputURL.path == expectedOutput.path,
                  outputType == "TXT" else {
                throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
            }
            let stableInput = try StableColmapModelInputBinding(
                projectRootURL: context.projectRootURL,
                projectRelativePath: context.inputProjectRelativePath
            )
            let stableOutput = try StableColmapModelOutputBinding(
                projectRootURL: context.projectRootURL,
                projectRelativePath: context.outputProjectRelativePath
            )
            inputBinding = stableInput
            outputBinding = stableOutput
            sourceDigest = stableInput.modelDigest
            candidateIdentity = sourceDigest.flatMap {
                GeometryArtifactStore.modelCandidateIdentity(
                    mappingAttemptOrdinal: context.mappingAttemptOrdinal,
                    candidateProjectRelativePath: context.candidateProjectRelativePath,
                    sourceModelDigest: $0
                )
            }
            guard sourceDigest != nil, candidateIdentity != nil else {
                throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
            }
        } else {
            inputBinding = nil
            outputBinding = nil
            sourceDigest = nil
            candidateIdentity = nil
        }
        let launchPath = runtimeClosureBinding?.launchPath ?? colmapPath.path
        let invokedInputPath = inputBinding?.canonicalPath ?? inputPath.path
        let invokedOutputPath = outputBinding?.canonicalPath ?? outputPath.path
        let args = [
            "model_converter",
            "--input_path", invokedInputPath,
            "--output_path", invokedOutputPath,
            "--output_type", outputType
        ]
        onLog("EasySplat: colmap argv: \(launchPath) \(args.joined(separator: " "))", false)
        let result = try runner.run(
            launchPath,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedProcessEnvironmentKeys,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try runtimeClosureBinding?.validateAfterExecution()
        try inputBinding?.validateAfterExecution()
        try outputBinding?.validateAfterExecution()
        if recordGeometryWorkerExecution {
            guard let context = modelConversionContext,
                  let sourceDigest,
                  let candidateIdentity,
                  let runtimeClosureBinding else {
                throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
            }
            let succeeded = result.exitCode == 0 && result.terminationReason == .exit
            let convertedDigest: String?
            if succeeded {
                guard let outputBinding else {
                    throw ColmapRunnerError.executionEvidenceUnavailable("model_converter")
                }
                convertedDigest = try outputBinding.modelDigest()
            } else {
                convertedDigest = nil
            }
            try recordWorkerExecution(
                command: .modelConverter,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil,
                pairContext: nil,
                mapperExecution: nil,
                modelConversion: ColmapModelConversionWorkerEvidence(
                    executableComponentPath: "bin/colmap",
                    executableSHA256: runtimeClosureBinding.executableSHA256,
                    candidateProjectRelativePath: context.candidateProjectRelativePath,
                    inputProjectRelativePath: context.inputProjectRelativePath,
                    outputProjectRelativePath: context.outputProjectRelativePath,
                    sourceModelDigest: sourceDigest,
                    convertedModelDigest: convertedDigest,
                    candidateIdentitySHA256: candidateIdentity
                ),
                result: result
            )
        }
        try checkResult(result, command: "model_converter")
    }

    private func checkResult(_ result: SubprocessResult, command: String) throws {
        guard result.exitCode == 0, result.terminationReason == .exit else {
            throw ColmapRunnerError.failed(
                command: command,
                exitCode: result.exitCode,
                terminationReason: result.terminationReason,
                stdoutTail: tailLines(result.stdout, limit: 40),
                stderrTail: tailLines(result.stderr, limit: 40)
            )
        }
    }

    private func tailLines(_ text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
