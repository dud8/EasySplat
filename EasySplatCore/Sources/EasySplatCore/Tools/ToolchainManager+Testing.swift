import Foundation

#if DEBUG
private final class ToolchainTestingResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        precondition(result != nil, "toolchain validation completed without a result")
        return result!
    }
}

extension ToolchainManager {
    /// Keeps the existing synchronous fixture surface while routing all real
    /// validation work through the asynchronous implementation.
    func test_validateToolchain(
        root: URL,
        dataRoot: URL? = nil,
        metallib: URL? = nil,
        requiredCapabilities: Set<ToolchainCapability>,
        toolchainIdentity: String = "test-toolchain"
    ) throws -> ToolchainPaths {
        let result = ToolchainTestingResultBox<ToolchainPaths>()
        let finished = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            do {
                result.store(.success(try await validateToolchain(
                    root: root,
                    dataRoot: dataRoot,
                    metallib: metallib,
                    requiredCapabilities: requiredCapabilities,
                    toolchainIdentity: toolchainIdentity
                )))
            } catch {
                result.store(.failure(error))
            }
            finished.signal()
        }
        finished.wait()
        return try result.load().get()
    }

    func test_validateToolchain(
        root: URL,
        dataRoot: URL? = nil,
        metallib: URL? = nil,
        requiredCapabilities: Set<ToolchainCapability>,
        toolchainIdentity: String = "test-toolchain"
    ) async throws -> ToolchainPaths {
        try await validateToolchain(
            root: root,
            dataRoot: dataRoot,
            metallib: metallib,
            requiredCapabilities: requiredCapabilities,
            toolchainIdentity: toolchainIdentity
        )
    }

    func test_sha256Hex(url: URL) async throws -> String {
        try await sha256Hex(url: url)
    }
}
#endif
