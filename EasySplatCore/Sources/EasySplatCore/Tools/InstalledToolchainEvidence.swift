import CryptoKit
import Darwin
import Foundation

extension ToolchainInstallationEvidence {
    /// Attests one installed toolchain tree from the tree itself.
    ///
    /// The trust anchor is the code signature over the enclosing bundle, so the
    /// evidence records what is on disk rather than what a signed manifest
    /// promised. Fields that only ever carried manifest authority are empty.
    public static func fromInstalledTree(
        root: URL,
        dataRoot: URL? = nil,
        toolchainIdentity: String,
        using manager: ToolchainManager = ToolchainManager()
    ) throws -> ToolchainInstallationEvidence {
        try manager.installedTreeEvidence(
            root: root,
            dataRoot: dataRoot,
            toolchainIdentity: toolchainIdentity
        )
    }
}

extension ToolchainManager {
    /// Component name for the one closure an installed tree contains.
    static let installedTreeComponentName = "bundled-helpers"

    private static let installedTreeCapabilities = [
        ToolchainCapability.core.rawValue,
        ToolchainCapability.colmap.rawValue,
        ToolchainCapability.msplat.rawValue,
    ].sorted()

    public func installedTreeEvidence(
        root: URL,
        dataRoot: URL? = nil,
        toolchainIdentity: String
    ) throws -> ToolchainInstallationEvidence {
        var sources = [(root: root, paths: try installedTreeRelativePaths(root: root))]
        if let dataRoot, dataRoot.standardizedFileURL.path != root.standardizedFileURL.path {
            sources.append((dataRoot, try installedTreeRelativePaths(root: dataRoot)))
        }
        let closure = try installedClosureEvidence(sources: sources)
        let paths = closure.fileHashes.keys.sorted()
        let component = ToolchainInstallationEvidence.SignedComponent(
            name: Self.installedTreeComponentName,
            archiveSHA256: "",
            expandedClosureSHA256: closure.contentSHA256,
            capabilities: Self.installedTreeCapabilities,
            declaredContents: paths
        )
        return ToolchainInstallationEvidence(
            toolchainVersion: toolchainIdentity,
            keyID: "",
            canonicalManifestSHA256: "",
            signatureSHA256: "",
            closureSHA256: closure.contentSHA256,
            installationIdentitySHA256: closure.identitySHA256,
            installedArtifacts: [Self.installedTreeComponentName: closure.contentSHA256],
            installedCapabilities: Self.installedTreeCapabilities,
            installedCriticalFileSHA256: closure.fileHashes,
            nativeTrainerBuildDigest: try nativeTrainerBuildDigest(
                root: root,
                metallib: sources.count == 1
                    ? root.appendingPathComponent("bin/default.metallib")
                    : sources[1].root.appendingPathComponent("default.metallib"),
                signedFileHashes: closure.fileHashes
            ),
            signedComponents: [component],
            provenanceRecords: try parsedProvenanceRecords(
                fileURLs: closure.fileURLs,
                files: Set(paths),
                signedHashes: closure.fileHashes
            )
        )
    }

    /// Enumerates the ordinary files in an installed tree. The enumerator does
    /// not descend through symbolic links, and every reported path is reopened
    /// with `O_NOFOLLOW` before it is hashed.
    private func installedTreeRelativePaths(root: URL) throws -> [String] {
        let base = root.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ToolchainError.invalidToolchain("Installed toolchain could not be enumerated.")
        }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else {
                throw ToolchainError.invalidToolchain(
                    "Installed toolchain contains a file outside its root."
                )
            }
            paths.append(String(path.dropFirst(prefix.count)))
        }
        guard !paths.isEmpty else {
            throw ToolchainError.invalidToolchain("Installed toolchain contains no files.")
        }
        return paths.sorted()
    }

    private func installedClosureEvidence(
        sources: [(root: URL, paths: [String])]
    ) throws -> (
        contentSHA256: String,
        identitySHA256: String,
        fileHashes: [String: String],
        fileURLs: [String: URL]
    ) {
        var fileHashes: [String: String] = [:]
        var identities: [String: String] = [:]
        var fileURLs: [String: URL] = [:]
        for source in sources {
            for path in source.paths {
                let evidence = try regularFileEvidence(root: source.root, relativePath: path)
                let key = Self.toolchainRelativeKey(for: path)
                guard fileHashes[key] == nil else {
                    throw ToolchainError.invalidToolchain(
                        "Installed toolchain declares \(key) twice."
                    )
                }
                fileHashes[key] = evidence.sha256
                identities[key] = evidence.identity
                // A split layout resolves each key against the root it came from,
                // not against the executable root.
                fileURLs[key] = source.root.appendingPathComponent(path, isDirectory: false)
            }
        }
        var closureHasher = SHA256()
        var identityHasher = SHA256()
        for key in fileHashes.keys.sorted() {
            closureHasher.update(data: Data(key.utf8))
            closureHasher.update(data: Data([0]))
            closureHasher.update(data: Data((fileHashes[key] ?? "").utf8))
            closureHasher.update(data: Data([10]))
            identityHasher.update(data: Data(key.utf8))
            identityHasher.update(data: Data([0]))
            identityHasher.update(data: Data((identities[key] ?? "").utf8))
            identityHasher.update(data: Data([10]))
        }
        return (
            closureHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            identityHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            fileHashes,
            fileURLs
        )
    }

    /// A split layout keeps `default.metallib` beside the payload it belongs to,
    /// but every persisted artifact names it by its executable-root path.
    private static func toolchainRelativeKey(for path: String) -> String {
        path == "default.metallib" ? "bin/default.metallib" : path
    }

    private func parsedProvenanceRecords(
        fileURLs: [String: URL],
        files: Set<String>,
        signedHashes: [String: String]
    ) throws -> [ToolchainInstallationEvidence.ProvenanceRecord] {
        let paths = files.filter { path in
            path.hasSuffix("/build_info.json")
                || path.hasSuffix("/easysplat_model_info.json")
                || (path.hasPrefix("provenance/") && path.hasSuffix(".json"))
                || path == "supply-chain/components.json"
        }.sorted()
        return try paths.map { path in
            guard let expectedHash = signedHashes[path], let url = fileURLs[path] else {
                throw ToolchainError.invalidToolchain(
                    "Installed toolchain provenance was not attested: \(path)."
                )
            }
            let maximumBytes = path == "supply-chain/components.json"
                ? 16 * 1_024 * 1_024
                : 1_048_576
            let data = try BoundedFileReader.readRegularFile(
                at: url,
                maximumBytes: maximumBytes
            )
            guard sha256Hex(data: data) == expectedHash,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(object),
                  let dictionary = object as? [String: Any] else {
                throw ToolchainError.invalidToolchain(
                    "Installed toolchain provenance is invalid: \(path)."
                )
            }
            let canonical = try JSONSerialization.data(
                withJSONObject: dictionary,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            var stringFields: [String: String] = [:]
            for (key, value) in dictionary {
                if let string = value as? String {
                    stringFields[key] = string
                } else if let number = value as? NSNumber {
                    stringFields[key] = number.stringValue
                }
            }
            return ToolchainInstallationEvidence.ProvenanceRecord(
                path: path,
                fileSHA256: expectedHash,
                canonicalJSONSHA256: sha256Hex(data: canonical),
                stringFields: stringFields
            )
        }
    }

    /// Digest domain and entry labels are load-bearing: a persisted trainer
    /// digest from any earlier build must stay comparable.
    func nativeTrainerBuildDigest(
        root: URL,
        metallib: URL,
        signedFileHashes: [String: String]
    ) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat file digest v1".utf8))
        let entries: [(url: URL, key: String, name: String)] = [
            (root.appendingPathComponent("bin/easysplat-train"), "bin/easysplat-train", "easysplat-train"),
            (metallib, "bin/default.metallib", "default.metallib"),
        ]
        for entry in entries {
            guard let expectedSHA256 = signedFileHashes[entry.key] else {
                throw ToolchainError.invalidToolchain(
                    "Installed toolchain has no attested \(entry.key)."
                )
            }
            try appendStableRegularFile(
                at: entry.url,
                relativeName: entry.name,
                expectedSHA256: expectedSHA256,
                to: &hasher
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func appendStableRegularFile(
        at url: URL,
        relativeName: String,
        expectedSHA256: String,
        to hasher: inout SHA256
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file could not be opened safely: \(url.lastPathComponent)."
            )
        }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_nlink == 1,
              initial.st_size >= 0 else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file is not an ordinary single-link file: \(url.lastPathComponent)."
            )
        }
        var nameLength = UInt64(relativeName.utf8.count).bigEndian
        withUnsafeBytes(of: &nameLength) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(relativeName.utf8))
        var byteCount = UInt64(initial.st_size).bigEndian
        withUnsafeBytes(of: &byteCount) { hasher.update(bufferPointer: $0) }
        var fileHasher = SHA256()
        var bytesRead: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw ToolchainError.invalidToolchain(
                    "Toolchain file could not be read safely: \(url.lastPathComponent)."
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            fileHasher.update(data: Data(buffer[0..<count]))
            bytesRead += Int64(count)
        }
        var final = stat()
        var finalPath = stat()
        let actualSHA256 = fileHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard fstat(descriptor, &final) == 0,
              bytesRead == Int64(initial.st_size),
              sameFileIdentity(initial, final),
              lstat(url.path, &finalPath) == 0,
              sameFileIdentity(initial, finalPath),
              actualSHA256 == expectedSHA256 else {
            throw ToolchainError.invalidToolchain(
                "Native trainer file changed or did not match its attested hash: \(relativeName)."
            )
        }
    }

    func regularFileEvidence(
        root: URL,
        relativePath: String,
        maximumBytes: UInt64 = UInt64.max
    ) throws -> (sha256: String, size: Int64, mode: UInt16, identity: String) {
        try validateToolchainRelativePath(relativePath)
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ToolchainError.invalidToolchain(
                "Toolchain path is not a relative file path: \(relativePath)."
            )
        }
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw ToolchainError.invalidToolchain("Toolchain root could not be opened safely.")
        }
        var descriptors = [rootDescriptor]
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        var parent = rootDescriptor
        for part in parts.dropLast() {
            let descriptor = String(part).withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw ToolchainError.invalidToolchain(
                    "Toolchain path contains an unsafe intermediate directory: \(relativePath)."
                )
            }
            descriptors.append(descriptor)
            parent = descriptor
        }
        let leaf = String(parts.last!)
        let descriptor = leaf.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file could not be opened safely: \(relativePath)."
            )
        }
        descriptors.append(descriptor)
        return try regularFileEvidence(
            descriptor: descriptor,
            finalPath: root.appendingPathComponent(relativePath, isDirectory: false),
            maximumBytes: maximumBytes
        )
    }

    func regularFileEvidence(
        at url: URL,
        maximumBytes: UInt64 = UInt64.max
    ) throws -> (sha256: String, size: Int64, mode: UInt16, identity: String) {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file could not be opened safely: \(url.lastPathComponent)."
            )
        }
        defer { Darwin.close(descriptor) }
        return try regularFileEvidence(
            descriptor: descriptor,
            finalPath: url,
            maximumBytes: maximumBytes
        )
    }

    private func regularFileEvidence(
        descriptor: Int32,
        finalPath url: URL,
        maximumBytes: UInt64
    ) throws -> (sha256: String, size: Int64, mode: UInt16, identity: String) {
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_nlink == 1,
              initial.st_size >= 0,
              UInt64(initial.st_size) <= maximumBytes else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file is not an ordinary single-link file: \(url.lastPathComponent)."
            )
        }

        var hasher = SHA256()
        var bytesRead: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw ToolchainError.invalidToolchain(
                    "Toolchain file could not be read safely: \(url.lastPathComponent)."
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            bytesRead += Int64(count)
            guard bytesRead >= 0, UInt64(bytesRead) <= maximumBytes else {
                throw ToolchainError.invalidToolchain(
                    "Toolchain file exceeds its attested size bound: \(url.lastPathComponent)."
                )
            }
        }

        var final = stat()
        var finalPath = stat()
        guard fstat(descriptor, &final) == 0,
              sameFileIdentity(initial, final),
              bytesRead == Int64(initial.st_size),
              lstat(url.path, &finalPath) == 0,
              sameFileIdentity(initial, finalPath) else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file changed while it was being attested: \(url.lastPathComponent)."
            )
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            Int64(initial.st_size),
            UInt16(initial.st_mode & 0o7777),
            [
                String(initial.st_dev), String(initial.st_ino), String(initial.st_nlink),
                String(initial.st_mode), String(initial.st_size),
                String(initial.st_mtimespec.tv_sec), String(initial.st_mtimespec.tv_nsec),
                String(initial.st_ctimespec.tv_sec), String(initial.st_ctimespec.tv_nsec),
            ].joined(separator: ":")
        )
    }

    private func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Shares the archive extractor's entry-path rules; a toolchain-relative
    /// path has the same escape and normalization hazards as an archive entry.
    private func validateToolchainRelativePath(_ relativePath: String) throws {
        do {
            try SafeArchiveExtractor.validateEntryPaths([relativePath])
        } catch {
            throw ToolchainError.invalidToolchain(
                "Toolchain path is unsafe: \(relativePath)."
            )
        }
    }
}
