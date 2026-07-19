import Foundation

#if DEBUG
extension ToolchainManager {
    func test_validateToolchain(root: URL, requiredCapabilities: Set<ToolchainCapability>) throws -> ToolchainPaths {
        try validateToolchain(root: root, requiredCapabilities: requiredCapabilities)
    }

    func test_coreToolchainLooksInstalled(root: URL) -> Bool {
        coreToolchainLooksInstalled(root: root)
    }

    func test_artifactLooksInstalled(name: String, root: URL) -> Bool {
        artifactLooksInstalled(name: name, root: root)
    }

    func test_sha256Hex(url: URL) throws -> String {
        try sha256Hex(url: url)
    }

    func test_validatedRemoteURL(_ value: String) throws -> URL {
        try validatedRemoteURL(value)
    }

    func test_validateRedirectTarget(_ url: URL) throws {
        try validateRedirectTarget(url)
    }

    func test_validateArchiveEntries(_ entries: [String]) throws {
        try validateArchiveEntries(entries)
    }

    func test_inspectArchiveEntries(zipURL: URL) throws -> [String] {
        try inspectArchiveEntries(zipURL: zipURL, forceInspection: true)
    }

    func test_validateCriticalFileHashes(_ hashes: [String: String], root: URL) throws {
        try validateCriticalFileHashes(hashes, root: root)
    }

    func test_expandedClosureEvidence(
        paths: [String],
        root: URL,
        maximumBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    ) throws -> (sha256: String, sizeBytes: UInt64, fileHashes: [String: String]) {
        try expandedClosureEvidence(paths: paths, root: root, maximumBytes: maximumBytes)
    }

    func test_nativeTrainerBuildDigest(
        root: URL,
        signedFileHashes: [String: String]
    ) throws -> String {
        try nativeTrainerBuildDigest(root: root, signedFileHashes: signedFileHashes)
    }

    func test_validateSignedReceipt(
        root: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest
    ) throws -> ToolchainManifest {
        try validateSignedReceipt(
            root: root,
            publicKeyBase64: publicKeyBase64,
            request: request
        )
    }

    func test_recoverInterruptedInstalls(at root: URL, publicKeyBase64: String) throws {
        try recoverInterruptedInstalls(at: root, publicKeyBase64: publicKeyBase64)
    }

    func test_recoverInterruptedInstalls(
        at root: URL,
        publicKeyBase64: String,
        beforeCandidatePromotion: @escaping (URL) throws -> Void
    ) throws {
        try recoverInterruptedInstalls(
            at: root,
            publicKeyBase64: publicKeyBase64,
            beforeCandidatePromotion: beforeCandidatePromotion
        )
    }

    func test_withInstallLock(
        for versionedRoot: URL,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withInstallLock(for: versionedRoot, operation: operation)
    }

    func test_installToolchainAtomically(
        versionedRoot: URL,
        requiredCapabilities: Set<ToolchainCapability>,
        authenticatedManifest: ToolchainManifest?,
        seedFromExistingRoot: URL?,
        beforeStagingPromotion: @escaping @Sendable (URL) throws -> Void,
        onProgress: @escaping @Sendable (Double, String) -> Void,
        installInto stagingInstall: @escaping @Sendable (_ stagingRoot: URL) async throws -> Void
    ) async throws -> ToolchainPaths {
        try validateVersionedToolchainRoot(versionedRoot)
        return try await withInstallLock(for: versionedRoot) {
            try await installToolchainAtomicallyLocked(
                versionedRoot: versionedRoot,
                requiredCapabilities: requiredCapabilities,
                authenticatedManifest: authenticatedManifest,
                seedFromExistingRoot: seedFromExistingRoot,
                beforeStagingPromotion: beforeStagingPromotion,
                onProgress: onProgress,
                installInto: stagingInstall
            )
        }
    }

    func test_validateSchema2Manifest(_ manifest: ToolchainManifest, publicKeyBase64: String) throws {
        try validateSchema2Manifest(manifest, publicKeyBase64: publicKeyBase64)
    }

    func test_versionedToolchainRoot(for version: String) throws -> URL {
        try versionedToolchainRoot(for: version)
    }

    func test_validateImmutableVersionFloor(
        _ candidate: ToolchainManifest,
        floor: ToolchainManifest
    ) throws {
        try validateImmutableVersionFloor(candidate, floor: floor)
    }

    func test_ensureArtifact(
        _ artifact: ToolchainManifest.Component,
        root: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        var state = ToolchainInstallState()
        try await ensureArtifact(artifact, root: root, state: &state, onProgress: onProgress)
    }
}
#endif
