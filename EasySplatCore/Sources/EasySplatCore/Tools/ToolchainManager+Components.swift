import Foundation

extension ToolchainManager {
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

    static let criticalCoreExecutables = Set([
        "bin/colmap",
        "bin/easysplat-train",
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
    ])

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
              !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
            "macos-arm64-core": (Self.coreCapabilities, [], .required, Self.criticalCoreExecutables),
            "geometry-da3-base": ([ToolchainCapability.da3Base.rawValue], ["macos-arm64-core"], .required, Self.criticalBaseModelFiles),
            "geometry-da3-small": ([ToolchainCapability.da3Small.rawValue], ["macos-arm64-core"], .optional, Self.criticalSmallModelFiles),
        ]

        for component in manifest.components {
            guard let contract = expected[component.name],
                  Set(component.capabilities) == contract.capabilities,
                  component.capabilities.count == contract.capabilities.count,
                  Set(component.dependencies) == contract.dependencies,
                  component.dependencies.count == contract.dependencies.count,
                  component.requirement == contract.requirement,
                  component.sizeBytes > 0,
                  component.sha256 == component.sha256.lowercased(),
                  isLowercaseSHA256(component.sha256),
                  !component.contents.isEmpty,
                  Set(component.contents).count == component.contents.count,
                  Set(component.criticalFileHashes.keys) == contract.criticalFiles,
                  contract.criticalFiles.isSubset(of: Set(component.contents)) else {
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
    ) throws -> ToolchainManifest? {
        let persistedState = loadInstallState(root: root)
        guard persistedState.signedManifest != nil else {
            // Schema-1 installs had no receipt. They remain usable for the default compatibility path.
            guard request == .default else { throw ToolchainError.invalidToolchain("Cached toolchain has no signed component receipt.") }
            return nil
        }
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

    func preflightDiskSpace(for components: [ToolchainManifest.Component], at root: URL) throws {
        let archiveBytes = components.reduce(UInt64(0)) { partial, component in
            let (sum, overflow) = partial.addingReportingOverflow(component.sizeBytes)
            return overflow ? UInt64.max : sum
        }
        let doubled = archiveBytes.multipliedReportingOverflow(by: 2)
        let extractionBytes = doubled.overflow ? UInt64.max : doubled.partialValue
        let headroom: UInt64 = 64 * 1_024 * 1_024
        let sum = extractionBytes.addingReportingOverflow(headroom)
        let required = sum.overflow ? UInt64.max : sum.partialValue

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
