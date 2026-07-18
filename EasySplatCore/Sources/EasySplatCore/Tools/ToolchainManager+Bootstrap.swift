import Foundation

extension ToolchainManager {
    struct ValidatedBootstrap {
        let manifest: ToolchainManifest
        let core: ToolchainManifest.Component
        let archiveURL: URL
        let semanticVersion: SemanticVersion
    }

    func validateBundledBootstrap(
        _ bootstrap: ToolchainBootstrap?,
        publicKeyBase64: String
    ) throws -> ValidatedBootstrap? {
        guard let bootstrap else { return nil }

        let data: Data
        do {
            data = try BoundedFileReader.readRegularFile(
                at: bootstrap.manifestURL,
                maximumBytes: Self.maximumManifestDownloadBytes
            )
        } catch {
            throw ToolchainError.invalidManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ToolchainManifest.self, from: data) else {
            throw ToolchainError.invalidManifest
        }
        guard manifest.verifying(publicKeyBase64: publicKeyBase64) else {
            throw ToolchainError.signatureFailed
        }
        try validateSchema2Manifest(manifest, publicKeyBase64: publicKeyBase64)
        guard let semanticVersion = semanticVersionComponents(from: manifest.version),
              let core = manifest.components.first(where: { $0.name == "macos-arm64-core" }) else {
            throw ToolchainError.invalidManifest
        }

        guard try isRegularSingleLinkFile(bootstrap.coreArchiveURL, exactSize: core.sizeBytes),
              try sha256Hex(url: bootstrap.coreArchiveURL).lowercased() == core.sha256.lowercased() else {
            throw ToolchainError.hashMismatch
        }
        let archiveEntries = try inspectArchiveEntries(
            zipURL: bootstrap.coreArchiveURL,
            forceInspection: true
        )
        try validateArchiveEntries(archiveEntries)
        try validateExactArchiveContents(archiveEntries, component: core)

        return ValidatedBootstrap(
            manifest: manifest,
            core: core,
            archiveURL: bootstrap.coreArchiveURL,
            semanticVersion: semanticVersion
        )
    }

    func installBundledBootstrap(
        _ bootstrap: ValidatedBootstrap,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        guard bundledCoreCanSatisfy(request, bootstrap: bootstrap) else {
            throw ToolchainError.artifactNotFound
        }
        let versionedRoot = try versionedToolchainRoot(for: bootstrap.manifest.version)
        try preflightBundledDiskSpace(for: bootstrap.core, at: versionedRoot)
        return try await installToolchainAtomically(
            versionedRoot: versionedRoot,
            requiredCapabilities: request.capabilities,
            onProgress: onProgress
        ) { stagingRoot in
            try installVerifiedArchive(
                bootstrap.core,
                archiveURL: bootstrap.archiveURL,
                root: stagingRoot,
                forceArchiveInspection: true,
                onProgress: onProgress
            )
            let state = ToolchainInstallState(
                schemaVersion: ToolchainManifest.currentSchemaVersion,
                installedArtifacts: [bootstrap.core.name: bootstrap.core.sha256],
                installedCapabilities: bootstrap.core.capabilities.sorted(),
                signedManifest: bootstrap.manifest
            )
            try saveInstallState(state, root: stagingRoot)
        }
    }

    func bundledCoreCanSatisfy(
        _ request: ToolchainCapabilityRequest,
        bootstrap: ValidatedBootstrap
    ) -> Bool {
        request.manifestCapabilities.isSubset(of: Set(bootstrap.core.capabilities))
    }

    func validateRemoteVersionFloor(
        _ manifest: ToolchainManifest,
        bootstrap: ValidatedBootstrap?
    ) throws {
        guard let bootstrap,
              let remoteVersion = semanticVersionComponents(from: manifest.version) else { return }
        guard compareSemanticVersions(remoteVersion, bootstrap.semanticVersion) != .orderedAscending else {
            throw ToolchainError.invalidToolchain(
                "Downloaded toolchain \(manifest.version) is older than the authenticated bundled version \(bootstrap.manifest.version)."
            )
        }
    }
}
