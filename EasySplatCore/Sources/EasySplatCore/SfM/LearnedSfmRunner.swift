import Foundation

@available(*, deprecated, message: "learned_sfm / MASt3R is deprecated; use vggt-mps instead.")
public struct LearnedMatchingConfig: Sendable {
    public var device: String
    public var maxImageSize: Int
    public var sequentialOverlap: Int
    public var stride: Int
    public var loopK: Int
    public var pairing: String
    public var cameraModel: String
    public var requireDevice: Bool
    public var offline: Bool
    public var pairsFile: URL?

    public init(
        device: String,
        maxImageSize: Int,
        sequentialOverlap: Int,
        stride: Int,
        loopK: Int,
        pairing: String,
        cameraModel: String,
        requireDevice: Bool = false,
        offline: Bool = true,
        pairsFile: URL? = nil
    ) {
        self.device = device
        self.maxImageSize = maxImageSize
        self.sequentialOverlap = sequentialOverlap
        self.stride = stride
        self.loopK = loopK
        self.pairing = pairing
        self.cameraModel = cameraModel
        self.requireDevice = requireDevice
        self.offline = offline
        self.pairsFile = pairsFile
    }
}

@available(*, deprecated, message: "learned_sfm / MASt3R is deprecated; use vggt-mps instead.")
public protocol LearnedMatchingRunning: Sendable {
    func run(
        toolchain: LearnedSfmToolchain,
        images: URL,
        outDatabase: URL,
        outFeatures: URL,
        outMatchList: URL,
        config: LearnedMatchingConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws
}

@available(*, deprecated, message: "learned_sfm / MASt3R is deprecated; use vggt-mps instead.")
public enum LearnedMatchingError: Error {
    case missingTool
    case missingModels
    case commandFailed(String)
}

@available(*, deprecated, message: "learned_sfm / MASt3R is deprecated; use vggt-mps instead.")
public final class LearnedMatchingRunner: @unchecked Sendable, LearnedMatchingRunning {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func run(
        toolchain: LearnedSfmToolchain,
        images: URL,
        outDatabase: URL,
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
            "--out-database", outDatabase.path,
            "--out-features", outFeatures.path,
            "--out-match-list", outMatchList.path,
            "--device", config.device,
            "--max-image-size", "\(config.maxImageSize)",
            "--pairing", config.pairing,
            "--sequential-overlap", "\(config.sequentialOverlap)",
            "--stride", "\(config.stride)",
            "--loop-k", "\(config.loopK)",
            "--models-dir", toolchain.models.path,
            "--camera-model", config.cameraModel
        ]
        var finalArgs = args
        if config.requireDevice {
            finalArgs.append("--require-device")
        }
        if config.offline {
            finalArgs.append("--offline")
        }
        if let pairsFile = config.pairsFile {
            finalArgs.append(contentsOf: ["--pairs", pairsFile.path])
        }

        var environment = [
            "PYTORCH_ENABLE_MPS_FALLBACK": "1",
            "PYTHONUNBUFFERED": "1",
            "TORCH_HOME": toolchain.models.path
        ]
        let pythonBin = toolchain.python.deletingLastPathComponent().path
        if let existingPath = ProcessInfo.processInfo.environment["PATH"] {
            environment["PATH"] = "\(pythonBin):\(existingPath)"
        } else {
            environment["PATH"] = pythonBin
        }

        let result = try await runner.runAsync(
            toolchain.matchTool.path,
            finalArgs,
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
