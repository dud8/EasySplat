import Foundation

#if DEBUG
extension ToolchainManager {
    func test_validateToolchain(root: URL) throws -> ToolchainPaths {
        try validateToolchain(root: root)
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

    func test_ensureArtifact(
        _ artifact: ToolchainManifest.Artifact,
        root: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        var state = ToolchainInstallState()
        try await ensureArtifact(artifact, root: root, state: &state, onProgress: onProgress)
    }
}
#endif
