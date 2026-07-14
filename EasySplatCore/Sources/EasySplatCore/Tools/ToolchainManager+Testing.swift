import Foundation

#if DEBUG
extension ToolchainManager {
    func test_validateToolchain(root: URL, requiredCapabilities: Set<ToolchainCapability>) throws -> ToolchainPaths {
        try validateToolchain(root: root, requiredCapabilities: requiredCapabilities)
    }

    func test_coreToolchainLooksInstalled(root: URL) -> Bool {
        coreToolchainLooksInstalled(root: root)
    }

    func test_modelsToolchainLooksInstalled(root: URL) -> Bool {
        modelsToolchainLooksInstalled(root: root)
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

    func test_validateSchema2Manifest(_ manifest: ToolchainManifest, publicKeyBase64: String) throws {
        try validateSchema2Manifest(manifest, publicKeyBase64: publicKeyBase64)
    }

    func test_versionedToolchainRoot(for version: String) throws -> URL {
        try versionedToolchainRoot(for: version)
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
