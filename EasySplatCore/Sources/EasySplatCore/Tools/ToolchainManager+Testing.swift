import Foundation

#if DEBUG
extension ToolchainManager {
    func test_validateToolchain(
        root: URL,
        dataRoot: URL? = nil,
        metallib: URL? = nil,
        requiredCapabilities: Set<ToolchainCapability>,
        toolchainIdentity: String = "test-toolchain"
    ) throws -> ToolchainPaths {
        try validateToolchain(
            root: root,
            dataRoot: dataRoot,
            metallib: metallib,
            requiredCapabilities: requiredCapabilities,
            toolchainIdentity: toolchainIdentity
        )
    }

    func test_sha256Hex(url: URL) throws -> String {
        try sha256Hex(url: url)
    }
}
#endif
