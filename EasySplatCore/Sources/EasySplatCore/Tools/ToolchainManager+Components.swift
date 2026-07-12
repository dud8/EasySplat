import Foundation

extension ToolchainManager {
    static let maximumReleaseComponentDownloadBytes: UInt64 = 2_147_483_648
    static let maximumNormalPhotoToolchainDownloadBytes: UInt64 = 2_500_000_000

    static let schema2ComponentNames = Set([
        "macos-arm64-core",
        "geometry-da3-base",
        "geometry-da3-small",
    ])

    static let coreCapabilities = Set([
        ToolchainCapability.core.rawValue,
        ToolchainCapability.colmap.rawValue,
        ToolchainCapability.da3Runtime.rawValue,
        ToolchainCapability.msplat.rawValue,
    ])

    static let criticalCoreAnchors = Set([
        "bin/colmap",
        "bin/easysplat-train",
        "bin/default.metallib",
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/build_info.json",
        "msplat/build_info.json",
    ])

    static func criticalCoreFiles(in contents: [String]) -> Set<String> {
        var required = criticalCoreAnchors
        for path in contents {
            let lowercased = path.lowercased()
            let pathExtension = URL(fileURLWithPath: lowercased).pathExtension
            let isPythonCode = ["py", "pyc", "pth"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("da3_mps/app/")
                        || lowercased.hasPrefix("da3_mps/vendor/")
                        || lowercased.hasPrefix("da3_mps/python/")
                )
            let isRuntimeConfiguration = ["yaml", "yml", "json", "toml"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("da3_mps/app/")
                        || lowercased.hasPrefix("da3_mps/vendor/")
                        || lowercased.hasPrefix("da3_mps/python/")
                )
            let isLoadedLibrary = ["dylib", "so"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("lib/")
                        || lowercased.hasPrefix("da3_mps/")
                )
            let isMetalLibrary = pathExtension == "metallib"
            let pathComponents = lowercased.split(separator: "/")
            let isNestedExecutablePayload = lowercased.hasPrefix("da3_mps/")
                && pathComponents.dropLast().contains(where: { $0 == "bin" || $0 == "libexec" })
            let isExecutablePayload = lowercased.hasPrefix("bin/")
                || lowercased.hasPrefix("da3_mps/bin/")
                || lowercased.hasPrefix("da3_mps/python/bin/")
                || isNestedExecutablePayload
            if isPythonCode || isRuntimeConfiguration || isLoadedLibrary || isMetalLibrary || isExecutablePayload {
                required.insert(path)
            }
        }
        return required
    }

    static let criticalBaseModelFiles = Set([
        "da3_mps/models/DA3-BASE/config.json",
        "da3_mps/models/DA3-BASE/easysplat_model_info.json",
        "da3_mps/models/DA3-BASE/model.safetensors",
    ])

    static let criticalSmallModelFiles = Set([
        "da3_mps/models/DA3-SMALL/config.json",
        "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
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
            "geometry-da3-base": ([ToolchainCapability.da3Base.rawValue], ["macos-arm64-core"], .required, Self.criticalBaseModelFiles),
            "geometry-da3-small": ([ToolchainCapability.da3Small.rawValue], ["macos-arm64-core"], .optional, Self.criticalSmallModelFiles),
        ]

        for component in manifest.components {
            let requiredCriticalFiles = component.name == "macos-arm64-core"
                ? Self.criticalCoreFiles(in: component.contents)
                : expected[component.name]?.criticalFiles ?? []
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
                  component.sha256 == component.sha256.lowercased(),
                  isLowercaseSHA256(component.sha256),
                  !component.contents.isEmpty,
                  Set(component.contents).count == component.contents.count,
                  requiredCriticalFiles.isSubset(of: declaredCriticalFiles),
                  declaredCriticalFiles.isSubset(of: declaredContents),
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
        var totalDownloadBytes: UInt64 = 0
        for component in manifest.components {
            let sum = totalDownloadBytes.addingReportingOverflow(component.sizeBytes)
            guard !sum.overflow else { throw ToolchainError.invalidManifest }
            totalDownloadBytes = sum.partialValue
        }
        guard totalDownloadBytes <= Self.maximumNormalPhotoToolchainDownloadBytes else {
            throw ToolchainError.invalidManifest
        }
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
        if let expectedManifest,
           receipt.signatureEd25519 != expectedManifest.signatureEd25519 {
            throw ToolchainError.invalidToolchain("Cached toolchain receipt does not match the current manifest.")
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
            installedComponents.append(component)
        }
        guard installedComponents.contains(where: { $0.name == "macos-arm64-core" }) else {
            throw ToolchainError.invalidToolchain("Cached toolchain is missing its core component.")
        }

        state.installedCapabilities = Set(installedComponents.flatMap(\.capabilities)).sorted()
        return state
    }

    func requiredDiskBytes(
        for components: [ToolchainManifest.Component],
        at root: URL,
        seedFromExistingRoot: URL? = nil
    ) throws -> UInt64 {
        let headroom: UInt64 = 64 * 1_024 * 1_024
        var required = headroom
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
        guard availableSigned > 0 else { return }
        let available = UInt64(availableSigned)
        guard available >= required else {
            throw ToolchainError.insufficientDiskSpace(required: required, available: available)
        }
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
        let files = Set(entries.filter { !$0.hasSuffix("/") })
        guard files == Set(component.contents), files.count == component.contents.count else {
            throw ToolchainError.invalidToolchain(
                "Component '\(component.name)' archive contents do not match its signed manifest."
            )
        }
    }
}
