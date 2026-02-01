import Foundation

public struct VggtSfmConfig: Sendable {
    public var device: String
    public var imageLoadResolution: Int
    public var vggtFixedResolution: Int
    public var confidenceThreshold: Double
    public var maxPoints: Int

    public init(
        device: String = "mps",
        imageLoadResolution: Int = 1024,
        vggtFixedResolution: Int = 518,
        confidenceThreshold: Double = 5.0,
        maxPoints: Int = 100_000
    ) {
        self.device = device
        self.imageLoadResolution = imageLoadResolution
        self.vggtFixedResolution = vggtFixedResolution
        self.confidenceThreshold = confidenceThreshold
        self.maxPoints = maxPoints
    }
}

public protocol VggtSfmRunning: Sendable {
    func run(
        toolchain: VggtToolchain,
        images: URL,
        outSparse: URL,
        config: VggtSfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws
}

public enum VggtSfmError: Error {
    case missingTool
    case missingModels
    case commandFailed(String)
}

public final class VggtSfmRunner: @unchecked Sendable, VggtSfmRunning {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func run(
        toolchain: VggtToolchain,
        images: URL,
        outSparse: URL,
        config: VggtSfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: toolchain.sfmTool.path) else {
            throw VggtSfmError.missingTool
        }
        guard fm.fileExists(atPath: toolchain.models.path) else {
            throw VggtSfmError.missingModels
        }

        let args: [String] = [
            "--images", images.path,
            "--out-sparse", outSparse.path,
            "--device", config.device,
            "--img-load-resolution", "\(config.imageLoadResolution)",
            "--vggt-resolution", "\(config.vggtFixedResolution)",
            "--conf-thres", "\(config.confidenceThreshold)",
            "--max-points", "\(config.maxPoints)",
            "--models-dir", toolchain.models.path
        ]

        var environment = [
            "PYTHONUNBUFFERED": "1",
            "TORCH_HOME": toolchain.models.path,
            "EASYSPLAT_VGGT_MODELS_DIR": toolchain.models.path
        ]

        // Ensure our toolchain python is preferred when the wrapper launches subprocesses.
        let pythonBin = toolchain.python.deletingLastPathComponent().path
        if let existingPath = ProcessInfo.processInfo.environment["PATH"] {
            environment["PATH"] = "\(pythonBin):\(existingPath)"
        } else {
            environment["PATH"] = pythonBin
        }

        onLog("EasySplat: running vggt-mps (cwd=\(toolchain.root.path))", false)
        onLog("EasySplat: vggt argv: \(toolchain.sfmTool.path) \(args.joined(separator: " "))", false)

        let result = try await runner.runAsync(
            toolchain.sfmTool.path,
            args,
            currentDirectory: toolchain.root,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        guard result.exitCode == 0 else {
            throw VggtSfmError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
