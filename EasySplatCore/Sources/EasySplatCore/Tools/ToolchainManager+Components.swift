import CryptoKit
import Darwin
import Foundation

extension ToolchainManager {
    static let toolchainDiskHeadroomBytes: UInt64 = 64 * 1_024 * 1_024
    static let maximumReleaseComponentDownloadBytes: UInt64 = 2_147_483_648
    static let maximumNormalPhotoToolchainDownloadBytes: UInt64 = 2_500_000_000
    static let maximumFullToolchainDownloadBytes: UInt64 = 6_000_000_000

    static let schema2ComponentNames = Set([
        "macos-arm64-core",
        "geometry-da3-base",
        "geometry-da3-small",
    ])

    static let coreCapabilities = Set([
        ToolchainCapability.core.rawValue,
        ToolchainCapability.colmap.rawValue,
        ToolchainCapability.msplat.rawValue,
    ])

    static let criticalCoreAnchors = Set([
        "bin/colmap",
        "bin/easysplat-train",
        "bin/default.metallib",
        "lib/libomp.dylib",
        "provenance/colmap.json",
        "provenance/colmap-support.json",
        "provenance/ceres.json",
        "provenance/openimageio.json",
        "msplat/build_info.json",
        "msplat/LICENSE",
        "supply-chain/components.json",
    ])

    static func isAllowedCoreFile(_ path: String) -> Bool {
        criticalCoreAnchors.contains(path)
            || (path.hasPrefix("licenses/") && path.count > "licenses/".count)
    }

    static func criticalCoreFiles(in contents: [String]) -> Set<String> {
        var required = criticalCoreAnchors
        for path in contents {
            let lowercased = path.lowercased()
            let pathExtension = URL(fileURLWithPath: lowercased).pathExtension
            let isLoadedLibrary = ["dylib", "so"].contains(pathExtension)
                && lowercased.hasPrefix("lib/")
            let isMetalLibrary = pathExtension == "metallib"
            let isExecutablePayload = lowercased.hasPrefix("bin/")
            let isReceiptOrLicense = lowercased.hasPrefix("provenance/")
                || lowercased.hasPrefix("licenses/")
                || lowercased.hasPrefix("msplat/")
                || lowercased.hasPrefix("supply-chain/")
            if isLoadedLibrary || isMetalLibrary || isExecutablePayload || isReceiptOrLicense {
                required.insert(path)
            }
        }
        return required
    }

    static let criticalDa3RuntimeAnchors = Set([
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/build_info.json",
    ])

    static func criticalDa3BaseFiles(in contents: [String]) -> Set<String> {
        var required = criticalDa3RuntimeAnchors.union(criticalBaseModelFiles)
        for path in contents {
            let lowercased = path.lowercased()
            guard lowercased.hasPrefix("da3_mps/") else { continue }
            let pathExtension = URL(fileURLWithPath: lowercased).pathExtension
            let isPythonCode = ["py", "pyc", "pth"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("da3_mps/app/")
                        || lowercased.hasPrefix("da3_mps/vendor/")
                        || lowercased.hasPrefix("da3_mps/python/")
                )
            let isRuntimeConfiguration = ["yaml", "yml", "json", "toml"].contains(pathExtension)
            let isLoadedLibrary = ["dylib", "so"].contains(pathExtension)
            let pathComponents = lowercased.split(separator: "/")
            let isExecutablePayload = pathComponents.dropLast().contains(where: {
                $0 == "bin" || $0 == "libexec"
            })
            let filename = pathComponents.last.map(String.init) ?? ""
            let isLicenseOrNotice = lowercased.hasPrefix("da3_mps/licenses/")
                || filename.hasPrefix("license")
                || filename.hasPrefix("copying")
                || filename.hasPrefix("notice")
            if isPythonCode || isRuntimeConfiguration || isLoadedLibrary
                || isExecutablePayload || isLicenseOrNotice {
                required.insert(path)
            }
        }
        return required
    }

    static func isAllowedDa3BaseFile(_ path: String) -> Bool {
        path == "da3_mps/build_info.json"
            || path.hasPrefix("da3_mps/bin/")
            || path.hasPrefix("da3_mps/python/")
            || path.hasPrefix("da3_mps/app/")
            || path.hasPrefix("da3_mps/vendor/")
            || path.hasPrefix("da3_mps/licenses/")
            || path.hasPrefix("da3_mps/models/DA3-BASE/")
    }

    static let criticalBaseModelFiles = Set([
        "da3_mps/models/DA3-BASE/config.json",
        "da3_mps/models/DA3-BASE/easysplat_model_info.json",
        "da3_mps/models/DA3-BASE/LICENSE",
        "da3_mps/models/DA3-BASE/model.safetensors",
    ])

    static let criticalSmallModelFiles = Set([
        "da3_mps/models/DA3-SMALL/config.json",
        "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
        "da3_mps/models/DA3-SMALL/LICENSE",
        "da3_mps/models/DA3-SMALL/model.safetensors",
    ])

    func validateSchema2Manifest(_ manifest: ToolchainManifest, publicKeyBase64: String) throws {
        guard manifest.schemaVersion == ToolchainManifest.currentSchemaVersion,
              manifest.toolchainAPI == ToolchainManifest.currentToolchainAPI,
              manifest.hasMatchingKeyID(publicKeyBase64: publicKeyBase64),
              semanticVersionComponents(from: manifest.version) != nil,
              Set(manifest.components.map(\.name)) == Self.schema2ComponentNames,
              manifest.components.count == Self.schema2ComponentNames.count else {
            throw ToolchainError.invalidManifest
        }
        guard isAppVersionCompatible(with: manifest) else {
            throw ToolchainError.invalidToolchain(
                "Toolchain \(manifest.version) does not support EasySplat \(appVersion)."
            )
        }

        let expected: [String: (
            capabilities: Set<String>,
            dependencies: Set<String>,
            requirement: ToolchainManifest.ComponentRequirement,
            criticalFiles: Set<String>
        )] = [
            "macos-arm64-core": (Self.coreCapabilities, [], .required, []),
            "geometry-da3-base": (
                [ToolchainCapability.da3Runtime.rawValue, ToolchainCapability.da3Base.rawValue],
                ["macos-arm64-core"],
                .optional,
                []
            ),
            "geometry-da3-small": (
                [ToolchainCapability.da3Small.rawValue],
                ["geometry-da3-base"],
                .optional,
                Self.criticalSmallModelFiles
            ),
        ]

        let allContents = manifest.components.flatMap(\.contents)
        let ownershipKeys = allContents.map(Self.toolchainPathCollisionKey)
        let installStateKey = Self.toolchainPathCollisionKey(Self.installStateFilename)
        guard Set(ownershipKeys).count == ownershipKeys.count,
              !ownershipKeys.contains(where: {
                  $0 == installStateKey || $0.hasPrefix(installStateKey + "/")
              }) else {
            throw ToolchainError.invalidManifest
        }

        for component in manifest.components {
            let requiredCriticalFiles: Set<String>
            switch component.name {
            case "macos-arm64-core":
                requiredCriticalFiles = Self.criticalCoreFiles(in: component.contents)
            case "geometry-da3-base":
                requiredCriticalFiles = Self.criticalDa3BaseFiles(in: component.contents)
            default:
                requiredCriticalFiles = expected[component.name]?.criticalFiles ?? []
            }
            let declaredCriticalFiles = Set(component.criticalFileHashes.keys)
            let declaredContents = Set(component.contents)
            guard let contract = expected[component.name],
                  Set(component.capabilities) == contract.capabilities,
                  component.capabilities.count == contract.capabilities.count,
                  Set(component.dependencies) == contract.dependencies,
                  component.dependencies.count == contract.dependencies.count,
                  component.requirement == contract.requirement,
                  component.sizeBytes > 0,
                  component.sizeBytes < Self.maximumReleaseComponentDownloadBytes,
                  component.expandedSizeBytes > 0,
                  component.expandedSizeBytes <= 16 * 1_024 * 1_024 * 1_024,
                  component.expandedClosureSHA256 == component.expandedClosureSHA256.lowercased(),
                  isLowercaseSHA256(component.expandedClosureSHA256),
                  component.sha256 == component.sha256.lowercased(),
                  isLowercaseSHA256(component.sha256),
                  !component.contents.isEmpty,
                  Set(component.contents).count == component.contents.count,
                  requiredCriticalFiles.isSubset(of: declaredCriticalFiles),
                  declaredCriticalFiles == declaredContents,
                  requiredCriticalFiles.isSubset(of: declaredContents) else {
                throw ToolchainError.invalidManifest
            }
            try validateArchiveEntries(component.contents)
            _ = try validatedArtifactURL(component.url)
            for (path, hash) in component.criticalFileHashes {
                try validateArchiveEntries([path])
                guard hash == hash.lowercased(), isLowercaseSHA256(hash) else {
                    throw ToolchainError.invalidManifest
                }
            }
        }

        guard manifest.components.allSatisfy({ !$0.criticalFileHashes.isEmpty }) else {
            throw ToolchainError.invalidManifest
        }

        guard let core = manifest.components.first(where: { $0.name == "macos-arm64-core" }),
              let base = manifest.components.first(where: { $0.name == "geometry-da3-base" }),
              let small = manifest.components.first(where: { $0.name == "geometry-da3-small" }),
              core.sizeBytes <= Self.maximumNormalPhotoToolchainDownloadBytes,
              core.contents.allSatisfy(Self.isAllowedCoreFile),
              Set(core.contents.filter { $0.hasPrefix("lib/") }) == ["lib/libomp.dylib"],
              base.contents.allSatisfy(Self.isAllowedDa3BaseFile),
              Set(small.contents) == Self.criticalSmallModelFiles else {
            throw ToolchainError.invalidManifest
        }

        var totalDownloadBytes: UInt64 = 0
        for component in manifest.components {
            let sum = totalDownloadBytes.addingReportingOverflow(component.sizeBytes)
            guard !sum.overflow else { throw ToolchainError.invalidManifest }
            totalDownloadBytes = sum.partialValue
        }
        guard totalDownloadBytes <= Self.maximumFullToolchainDownloadBytes else {
            throw ToolchainError.invalidManifest
        }
    }

    static func toolchainPathCollisionKey(_ path: String) -> String {
        path
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    func isAppVersionCompatible(with manifest: ToolchainManifest) -> Bool {
        guard let app = semanticVersionComponents(from: appVersion),
              let minimum = semanticVersionComponents(from: manifest.appVersionRange.minimum),
              compareSemanticVersions(app, minimum) != .orderedAscending else {
            return false
        }
        if let maximumValue = manifest.appVersionRange.maximumExclusive {
            guard let maximum = semanticVersionComponents(from: maximumValue),
                  compareSemanticVersions(app, maximum) == .orderedAscending else {
                return false
            }
        }
        return true
    }

    func validateSignedReceipt(
        root: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest
    ) throws -> ToolchainManifest {
        let state = try validatedReusableInstallState(
            root: root,
            publicKeyBase64: publicKeyBase64,
            matching: nil
        )
        guard let receipt = state.signedManifest else {
            throw ToolchainError.invalidToolchain("Cached toolchain has no signed component receipt.")
        }
        let components = try receipt.resolvedComponents(requesting: request.manifestCapabilities)
        guard components.allSatisfy({ state.installedArtifacts[$0.name]?.lowercased() == $0.sha256.lowercased() }),
              request.manifestCapabilities.isSubset(of: Set(state.installedCapabilities)) else {
            throw ToolchainError.invalidToolchain("Cached toolchain receipt is incomplete.")
        }
        return receipt
    }

    /// Revalidates an exact installed root and returns provenance derived only
    /// from its authenticated manifest and on-disk closure.
    public func validatedInstallationEvidence(
        root: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        matching expectedManifest: ToolchainManifest? = nil
    ) throws -> ToolchainInstallationEvidence {
        try validateVersionedToolchainRoot(root)
        let state = try validatedReusableInstallState(
            root: root,
            publicKeyBase64: publicKeyBase64,
            matching: expectedManifest
        )
        guard let manifest = state.signedManifest else {
            throw ToolchainError.invalidToolchain("Cached toolchain has no signed component receipt.")
        }
        try validateVersionedToolchainRoot(root, expectedVersion: manifest.version)
        let requestedComponents = try manifest.resolvedComponents(
            requesting: request.manifestCapabilities
        )
        guard requestedComponents.allSatisfy({
            state.installedArtifacts[$0.name]?.lowercased() == $0.sha256.lowercased()
        }) else {
            throw ToolchainError.invalidToolchain("Cached toolchain receipt is incomplete.")
        }

        let installedNames = Set(state.installedArtifacts.keys)
        let installedComponents = manifest.components.filter { installedNames.contains($0.name) }
        guard installedComponents.count == installedNames.count else {
            throw ToolchainError.invalidToolchain("Cached toolchain receipt contains unknown components.")
        }
        let expectedFiles = try validateInstalledTree(
            root: root,
            installedComponents: installedComponents
        )
        var signedCriticalHashes: [String: String] = [:]
        for component in installedComponents {
            for (path, digest) in component.criticalFileHashes {
                if let existing = signedCriticalHashes[path], existing != digest {
                    throw ToolchainError.invalidManifest
                }
                signedCriticalHashes[path] = digest
            }
        }
        let closure = try installedClosureEvidence(
            root: root,
            files: expectedFiles,
            signedCriticalHashes: signedCriticalHashes
        )
        guard let signature = Data(base64Encoded: manifest.signatureEd25519) else {
            throw ToolchainError.signatureFailed
        }

        let signedArtifacts = Dictionary(
            uniqueKeysWithValues: installedComponents.map { ($0.name, $0.sha256.lowercased()) }
        )
        let signedCapabilities = Set(installedComponents.flatMap(\.capabilities)).sorted()
        let signedComponents = installedComponents.map {
            ToolchainInstallationEvidence.SignedComponent(
                name: $0.name,
                archiveSHA256: $0.sha256.lowercased(),
                expandedClosureSHA256: $0.expandedClosureSHA256.lowercased(),
                capabilities: $0.capabilities.sorted(),
                declaredContents: $0.contents.sorted()
            )
        }
        return ToolchainInstallationEvidence(
            toolchainVersion: manifest.version,
            keyID: manifest.keyID.lowercased(),
            canonicalManifestSHA256: sha256Hex(data: try manifest.canonicalData()),
            signatureSHA256: sha256Hex(data: signature),
            closureSHA256: closure.contentSHA256,
            installationIdentitySHA256: closure.identitySHA256,
            installedArtifacts: signedArtifacts,
            installedCapabilities: signedCapabilities,
            installedCriticalFileSHA256: signedCriticalHashes,
            nativeTrainerBuildDigest: try nativeTrainerBuildDigest(
                root: root,
                signedFileHashes: signedCriticalHashes
            ),
            signedComponents: signedComponents,
            provenanceRecords: try parsedProvenanceRecords(
                root: root,
                files: expectedFiles,
                signedHashes: signedCriticalHashes
            )
        )
    }

    private func parsedProvenanceRecords(
        root: URL,
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
            guard let signedHash = signedHashes[path] else {
                throw ToolchainError.invalidManifest
            }
            let maximumBytes = path == "supply-chain/components.json"
                ? ToolchainManifest.maximumInstallStateEnvelopeBytes
                : 1_048_576
            let data = try BoundedFileReader.readRegularFile(
                at: root.appendingPathComponent(path, isDirectory: false),
                maximumBytes: maximumBytes
            )
            guard sha256Hex(data: data) == signedHash,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(object),
                  let dictionary = object as? [String: Any] else {
                throw ToolchainError.invalidToolchain(
                    "Signed toolchain provenance is invalid: \(path)."
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
                fileSHA256: signedHash,
                canonicalJSONSHA256: sha256Hex(data: canonical),
                stringFields: stringFields
            )
        }
    }

    func nativeTrainerBuildDigest(
        root: URL,
        signedFileHashes: [String: String]
    ) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat file digest v1".utf8))
        for name in ["easysplat-train", "default.metallib"] {
            let relativePath = "bin/\(name)"
            guard let expectedSHA256 = signedFileHashes[relativePath] else {
                throw ToolchainError.invalidManifest
            }
            try appendStableRegularFile(
                root: root,
                relativePath: relativePath,
                relativeName: name,
                expectedSHA256: expectedSHA256,
                to: &hasher
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func appendStableRegularFile(
        root: URL,
        relativePath: String,
        relativeName: String,
        expectedSHA256: String,
        to hasher: inout SHA256
    ) throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ToolchainError.invalidManifest
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
            let next = String(part).withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                throw ToolchainError.invalidToolchain(
                    "Toolchain path contains an unsafe intermediate directory: \(relativePath)."
                )
            }
            descriptors.append(next)
            parent = next
        }
        let descriptor = String(parts.last!).withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file could not be opened safely: \(relativePath)."
            )
        }
        descriptors.append(descriptor)
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
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
                "Native trainer file changed or did not match its signed hash: \(relativePath)."
            )
        }
    }

    func regularFileEvidence(
        root: URL,
        relativePath: String,
        maximumBytes: UInt64 = UInt64.max
    ) throws -> (sha256: String, size: Int64, mode: UInt16, identity: String) {
        try validateArchiveEntries([relativePath])
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ToolchainError.invalidManifest
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
                    "Toolchain file exceeds its signed expanded-size bound: \(url.lastPathComponent)."
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

    private func installedClosureEvidence(
        root: URL,
        files: Set<String>,
        signedCriticalHashes: [String: String]
    ) throws -> (contentSHA256: String, identitySHA256: String) {
        guard Set(signedCriticalHashes.keys).isSubset(of: files) else {
            throw ToolchainError.invalidManifest
        }
        var closureHasher = SHA256()
        var identityHasher = SHA256()
        for path in files.sorted() {
            let evidence = try regularFileEvidence(root: root, relativePath: path)
            if let expectedDigest = signedCriticalHashes[path],
               evidence.sha256 != expectedDigest {
                throw ToolchainError.invalidToolchain(
                    "Critical toolchain hash mismatch: \(path)."
                )
            }
            closureHasher.update(data: Data(path.utf8))
            closureHasher.update(data: Data([0]))
            closureHasher.update(data: Data(String(evidence.mode).utf8))
            closureHasher.update(data: Data([0]))
            closureHasher.update(data: Data(String(evidence.size).utf8))
            closureHasher.update(data: Data([0]))
            closureHasher.update(data: Data(evidence.sha256.utf8))
            closureHasher.update(data: Data([10]))
            identityHasher.update(data: Data(path.utf8))
            identityHasher.update(data: Data([0]))
            identityHasher.update(data: Data(evidence.identity.utf8))
            identityHasher.update(data: Data([10]))
        }
        return (
            closureHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            identityHasher.finalize().map { String(format: "%02x", $0) }.joined()
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
                    "Toolchain file exceeds its signed expanded-size bound: \(url.lastPathComponent)."
                )
            }
        }

        var final = stat()
        var finalPath = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_nlink == initial.st_nlink,
              final.st_mode == initial.st_mode,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              bytesRead == Int64(initial.st_size),
              lstat(url.path, &finalPath) == 0,
              finalPath.st_dev == initial.st_dev,
              finalPath.st_ino == initial.st_ino,
              finalPath.st_nlink == initial.st_nlink,
              finalPath.st_mode == initial.st_mode,
              finalPath.st_size == initial.st_size,
              finalPath.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              finalPath.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              finalPath.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              finalPath.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
            throw ToolchainError.invalidToolchain(
                "Toolchain file changed while it was being attested: \(url.lastPathComponent)."
            )
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            Int64(initial.st_size),
            UInt16(initial.st_mode & 0o7777),
            [
                String(initial.st_dev),
                String(initial.st_ino),
                String(initial.st_nlink),
                String(initial.st_mode),
                String(initial.st_size),
                String(initial.st_mtimespec.tv_sec),
                String(initial.st_mtimespec.tv_nsec),
                String(initial.st_ctimespec.tv_sec),
                String(initial.st_ctimespec.tv_nsec),
            ].joined(separator: ":")
        )
    }

    private func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func validateExpandedClosure(
        _ component: ToolchainManifest.Component,
        root: URL
    ) throws -> String {
        guard Set(component.criticalFileHashes.keys) == Set(component.contents) else {
            throw ToolchainError.invalidManifest
        }
        let closure = try expandedClosureEvidence(
            paths: component.contents,
            root: root,
            maximumBytes: component.expandedSizeBytes
        )
        guard closure.sizeBytes == component.expandedSizeBytes,
              closure.fileHashes == component.criticalFileHashes,
              closure.sha256 == component.expandedClosureSHA256 else {
            throw ToolchainError.invalidToolchain(
                "Expanded toolchain closure digest mismatch: \(component.name)."
            )
        }
        return closure.sha256
    }

    func expandedClosureEvidence(
        paths: [String],
        root: URL,
        maximumBytes: UInt64
    ) throws -> (sha256: String, sizeBytes: UInt64, fileHashes: [String: String]) {
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat expanded component closure v1\n".utf8))
        var totalBytes: UInt64 = 0
        var fileHashes: [String: String] = [:]
        for path in paths.sorted() {
            let evidence = try regularFileEvidence(
                root: root,
                relativePath: path,
                maximumBytes: maximumBytes - totalBytes
            )
            let size = UInt64(evidence.size)
            let sum = totalBytes.addingReportingOverflow(size)
            guard !sum.overflow, sum.partialValue <= maximumBytes,
                  evidence.mode == 0o644 || evidence.mode == 0o755 else {
                throw ToolchainError.invalidToolchain(
                    "Expanded toolchain closure mismatch: \(path)."
                )
            }
            totalBytes = sum.partialValue
            fileHashes[path] = evidence.sha256
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(evidence.mode).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(size).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(evidence.sha256.utf8))
            hasher.update(data: Data([10]))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, totalBytes, fileHashes)
    }

    func validatedReusableInstallState(
        root: URL,
        publicKeyBase64: String,
        matching expectedManifest: ToolchainManifest?
    ) throws -> ToolchainInstallState {
        var state = loadInstallState(root: root)
        guard state.schemaVersion == ToolchainManifest.currentSchemaVersion else {
            throw ToolchainError.invalidToolchain("Cached toolchain receipt uses an unsupported schema.")
        }
        guard let receipt = state.signedManifest else {
            throw ToolchainError.invalidToolchain("Cached toolchain has no signed component receipt.")
        }
        guard receipt.verifying(publicKeyBase64: publicKeyBase64) else {
            throw ToolchainError.signatureFailed
        }
        try validateSchema2Manifest(receipt, publicKeyBase64: publicKeyBase64)
        if let expectedManifest {
            guard receipt.signatureEd25519 == expectedManifest.signatureEd25519,
                  try receipt.canonicalData() == expectedManifest.canonicalData() else {
                throw ToolchainError.invalidToolchain(
                    "Cached toolchain receipt does not match the current manifest."
                )
            }
        }

        let byName = Dictionary(uniqueKeysWithValues: receipt.components.map { ($0.name, $0) })
        guard !state.installedArtifacts.isEmpty,
              state.installedArtifacts.keys.allSatisfy({ byName[$0] != nil }) else {
            throw ToolchainError.invalidToolchain("Cached toolchain receipt contains unknown components.")
        }

        var installedComponents: [ToolchainManifest.Component] = []
        for component in receipt.components {
            guard let installedHash = state.installedArtifacts[component.name] else { continue }
            guard installedHash.lowercased() == component.sha256.lowercased(),
                  artifactLooksInstalled(name: component.name, root: root) else {
                throw ToolchainError.invalidToolchain("Cached toolchain component is incomplete: \(component.name).")
            }
            try validateCriticalFileHashes(component.criticalFileHashes, root: root)
            try validateExpandedClosure(component, root: root)
            installedComponents.append(component)
        }
        guard installedComponents.contains(where: { $0.name == "macos-arm64-core" }) else {
            throw ToolchainError.invalidToolchain("Cached toolchain is missing its core component.")
        }
        try validateInstalledTree(root: root, installedComponents: installedComponents)

        state.installedCapabilities = Set(installedComponents.flatMap(\.capabilities)).sorted()
        return state
    }

    @discardableResult
    func validateInstalledTree(root: URL, state: ToolchainInstallState) throws -> Set<String> {
        guard let receipt = state.signedManifest,
              !state.installedArtifacts.isEmpty else {
            throw ToolchainError.invalidToolchain("Toolchain has no installed component receipt.")
        }
        let byName = Dictionary(uniqueKeysWithValues: receipt.components.map { ($0.name, $0) })
        let installedComponents = try state.installedArtifacts.keys.map { name in
            guard let component = byName[name],
                  state.installedArtifacts[name]?.lowercased() == component.sha256.lowercased() else {
                throw ToolchainError.invalidToolchain("Toolchain component receipt is invalid: \(name).")
            }
            return component
        }
        return try validateInstalledTree(root: root, installedComponents: installedComponents)
    }

    @discardableResult
    func validateInstalledTree(
        root: URL,
        installedComponents: [ToolchainManifest.Component]
    ) throws -> Set<String> {
        var expectedFiles = Set(installedComponents.flatMap(\.contents))
        expectedFiles.insert(Self.installStateFilename)

        var expectedDirectories = Set<String>()
        for path in expectedFiles {
            try validateArchiveEntries([path])
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasSuffix("/"), parts.allSatisfy({ !$0.isEmpty }) else {
                throw ToolchainError.invalidToolchain("Toolchain receipt contains a non-canonical file path: \(path).")
            }
            guard parts.count > 1 else { continue }
            var current = ""
            for part in parts.dropLast() {
                current = current.isEmpty ? String(part) : "\(current)/\(part)"
                expectedDirectories.insert(current)
            }
        }

        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try fileManager.attributesOfItem(atPath: root.path)
        } catch {
            throw ToolchainError.invalidToolchain("Toolchain root could not be inspected.")
        }
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ToolchainError.invalidToolchain("Toolchain root is not a directory.")
        }

        var foundFiles = Set<String>()
        func inspectDirectory(_ directory: URL, relativePath: String) throws {
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw ToolchainError.invalidToolchain("Toolchain directory could not be inspected: \(relativePath).")
            }

            for entry in entries {
                let path = relativePath.isEmpty
                    ? entry.lastPathComponent
                    : "\(relativePath)/\(entry.lastPathComponent)"
                let attributes: [FileAttributeKey: Any]
                do {
                    attributes = try fileManager.attributesOfItem(atPath: entry.path)
                } catch {
                    throw ToolchainError.invalidToolchain("Toolchain entry could not be inspected: \(path).")
                }

                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory:
                    guard expectedDirectories.contains(path) else {
                        throw ToolchainError.invalidToolchain("Toolchain contains an undeclared directory: \(path).")
                    }
                    try inspectDirectory(entry, relativePath: path)
                case .typeRegular:
                    guard expectedFiles.contains(path) else {
                        throw ToolchainError.invalidToolchain("Toolchain contains an undeclared file: \(path).")
                    }
                    if let references = attributes[.referenceCount] as? NSNumber,
                       references.intValue != 1 {
                        throw ToolchainError.invalidToolchain("Toolchain contains a multiply linked file: \(path).")
                    }
                    foundFiles.insert(path)
                case .typeSymbolicLink:
                    throw ToolchainError.invalidToolchain("Toolchain contains a symbolic link: \(path).")
                default:
                    throw ToolchainError.invalidToolchain("Toolchain contains a special file: \(path).")
                }
            }
        }

        try inspectDirectory(root, relativePath: "")
        guard foundFiles == expectedFiles else {
            let missing = expectedFiles.subtracting(foundFiles).sorted()
            throw ToolchainError.invalidToolchain(
                "Toolchain is missing signed files: \(missing.prefix(5).joined(separator: ", "))."
            )
        }
        return expectedFiles
    }

    func requiredDiskBytes(
        for components: [ToolchainManifest.Component],
        at root: URL,
        seedFromExistingRoot: URL? = nil
    ) throws -> UInt64 {
        var required = Self.toolchainDiskHeadroomBytes
        if let seedFromExistingRoot {
            let seedBytes = try installTreeSize(at: seedFromExistingRoot)
            let sum = required.addingReportingOverflow(seedBytes)
            required = sum.overflow ? UInt64.max : sum.partialValue
        }
        for component in components {
            let url = try validatedArtifactURL(component.url)
            let partialURL = try preparePartialDownload(
                artifact: component,
                url: url,
                installationRoot: root
            )
            let partialSize = try fileSize(at: partialURL)
            let reusableBytes: UInt64
            if partialSize == component.sizeBytes {
                reusableBytes = try reusablePartial(
                    partialURL,
                    expectedSize: component.sizeBytes,
                    expectedSHA256: component.sha256
                ) ? component.sizeBytes : 0
            } else {
                reusableBytes = min(partialSize, component.sizeBytes)
            }
            let remainingDownload = component.sizeBytes - reusableBytes
            for amount in [component.expandedSizeBytes, remainingDownload] {
                let sum = required.addingReportingOverflow(amount)
                required = sum.overflow ? UInt64.max : sum.partialValue
            }
        }
        return required
    }

    func preflightDiskSpace(
        for components: [ToolchainManifest.Component],
        at root: URL,
        seedFromExistingRoot: URL? = nil
    ) throws {
        let required = try requiredDiskBytes(
            for: components,
            at: root,
            seedFromExistingRoot: seedFromExistingRoot
        )

        guard let available = availableDiskSpace(at: root) else { return }
        try validateAvailableDiskSpace(required: required, available: available)
    }

    func requiredBundledDiskBytes(
        for component: ToolchainManifest.Component,
        seedFromExistingRoot: URL? = nil
    ) throws -> UInt64 {
        var required = Self.toolchainDiskHeadroomBytes
        if let seedFromExistingRoot {
            let addition = required.addingReportingOverflow(try installTreeSize(at: seedFromExistingRoot))
            required = addition.overflow ? UInt64.max : addition.partialValue
        }
        let expanded = required.addingReportingOverflow(component.expandedSizeBytes)
        return expanded.overflow ? UInt64.max : expanded.partialValue
    }

    func preflightBundledDiskSpace(
        for component: ToolchainManifest.Component,
        at root: URL,
        seedFromExistingRoot: URL? = nil
    ) throws {
        let required = try requiredBundledDiskBytes(
            for: component,
            seedFromExistingRoot: seedFromExistingRoot
        )
        guard let available = availableDiskSpace(at: root) else { return }
        try validateAvailableDiskSpace(required: required, available: available)
    }

    func validateAvailableDiskSpace(required: UInt64, available: UInt64) throws {
        guard available >= required else {
            throw ToolchainError.insufficientDiskSpace(required: required, available: available)
        }
    }

    private func availableDiskSpace(at root: URL) -> UInt64? {
        var probe = root.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let fileSystemAttributes = try? fileManager.attributesOfFileSystem(forPath: probe.path)
        let fallback = (fileSystemAttributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let regularCapacity = values?.volumeAvailableCapacity.map(Int64.init)
        let availableSigned = values?.volumeAvailableCapacityForImportantUsage
            ?? regularCapacity
            ?? fallback
        guard availableSigned > 0 else { return nil }
        return UInt64(availableSigned)
    }

    func installTreeSize(at root: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ToolchainError.fileIOFailed("Could not inspect the existing toolchain size.")
        }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            if values.isSymbolicLink == true {
                throw ToolchainError.invalidToolchain("Cached toolchain contains a symbolic link.")
            }
            guard values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let sum = total.addingReportingOverflow(size)
            total = sum.overflow ? UInt64.max : sum.partialValue
        }
        return total
    }

    func validateExactArchiveContents(_ entries: [String], component: ToolchainManifest.Component) throws {
        guard !entries.isEmpty else { return }
        let files = Set(entries)
        guard files == Set(component.contents),
              files.count == component.contents.count,
              entries.count == files.count else {
            throw ToolchainError.invalidToolchain(
                "Component '\(component.name)' archive contents do not match its signed manifest."
            )
        }
    }
}
