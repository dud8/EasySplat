import Foundation

public struct LearnedMatchingConfig: Sendable {
    public var device: String
    public var maxImageSize: Int
    public var sequentialOverlap: Int
    public var stride: Int
    public var loopK: Int
    public var pairing: String

    public init(
        device: String,
        maxImageSize: Int,
        sequentialOverlap: Int,
        stride: Int,
        loopK: Int,
        pairing: String
    ) {
        self.device = device
        self.maxImageSize = maxImageSize
        self.sequentialOverlap = sequentialOverlap
        self.stride = stride
        self.loopK = loopK
        self.pairing = pairing
    }
}

public protocol LearnedMatchingRunning: Sendable {
    func run(
        toolchain: LearnedSfmToolchain,
        images: URL,
        outFeatures: URL,
        outMatchList: URL,
        config: LearnedMatchingConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws
}

public enum LearnedMatchingError: Error {
    case missingTool
    case missingModels
    case commandFailed(String)
}

public final class LearnedMatchingRunner: @unchecked Sendable, LearnedMatchingRunning {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func run(
        toolchain: LearnedSfmToolchain,
        images: URL,
        outFeatures: URL,
        outMatchList: URL,
        config: LearnedMatchingConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: toolchain.matchTool.path) else {
            throw LearnedMatchingError.missingTool
        }
        guard fm.fileExists(atPath: toolchain.models.path) else {
            throw LearnedMatchingError.missingModels
        }

        let args: [String] = [
            "--images", images.path,
            "--out-features", outFeatures.path,
            "--out-match-list", outMatchList.path,
            "--device", config.device,
            "--max-image-size", "\(config.maxImageSize)",
            "--pairing", config.pairing,
            "--sequential-overlap", "\(config.sequentialOverlap)",
            "--stride", "\(config.stride)",
            "--loop-k", "\(config.loopK)",
            "--models-dir", toolchain.models.path
        ]

        var environment = [
            "PYTORCH_ENABLE_MPS_FALLBACK": "1",
            "TORCH_HOME": toolchain.models.appendingPathComponent("torch").path
        ]
        let pythonBin = toolchain.python.deletingLastPathComponent().path
        if let existingPath = ProcessInfo.processInfo.environment["PATH"] {
            environment["PATH"] = "\(pythonBin):\(existingPath)"
        } else {
            environment["PATH"] = pythonBin
        }

        let result = try await runner.runAsync(
            toolchain.matchTool.path,
            args,
            currentDirectory: toolchain.root,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        guard result.exitCode == 0 else {
            throw LearnedMatchingError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
