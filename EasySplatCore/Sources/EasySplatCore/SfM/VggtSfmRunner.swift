import Foundation

public struct VggtSfmConfig: Sendable {
    public var device: String
    public var imageLoadResolution: Int
    public var vggtFixedResolution: Int
    public var confidenceThreshold: Double
    public var maxPoints: Int
    public var useBundleAdjustment: Bool
    public var maxReprojectionError: Double
    public var sharedCamera: Bool
    public var cameraType: String
    public var visibilityThreshold: Double
    public var queryFrameCount: Int
    public var maxQueryPoints: Int
    public var fineTracking: Bool
    public var keypointExtractor: String
    public var bundleAdjustmentMaxFrames: Int

    public init(
        device: String = "mps",
        imageLoadResolution: Int = 1024,
        vggtFixedResolution: Int = 518,
        confidenceThreshold: Double = 5.0,
        maxPoints: Int = 100_000,
        useBundleAdjustment: Bool = true,
        maxReprojectionError: Double = 8.0,
        sharedCamera: Bool = false,
        cameraType: String = "SIMPLE_PINHOLE",
        visibilityThreshold: Double = 0.2,
        queryFrameCount: Int = 8,
        maxQueryPoints: Int = 4096,
        fineTracking: Bool = true,
        keypointExtractor: String = "aliked+sp",
        bundleAdjustmentMaxFrames: Int = 0
    ) {
        self.device = device
        self.imageLoadResolution = imageLoadResolution
        self.vggtFixedResolution = vggtFixedResolution
        self.confidenceThreshold = confidenceThreshold
        self.maxPoints = maxPoints
        self.useBundleAdjustment = useBundleAdjustment
        self.maxReprojectionError = maxReprojectionError
        self.sharedCamera = sharedCamera
        self.cameraType = cameraType
        self.visibilityThreshold = visibilityThreshold
        self.queryFrameCount = queryFrameCount
        self.maxQueryPoints = maxQueryPoints
        self.fineTracking = fineTracking
        self.keypointExtractor = keypointExtractor
        self.bundleAdjustmentMaxFrames = bundleAdjustmentMaxFrames
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
            "--models-dir", toolchain.models.path,
            "--max-reproj-error", "\(config.maxReprojectionError)",
            "--camera-type", config.cameraType,
            "--vis-thresh", "\(config.visibilityThreshold)",
            "--query-frame-num", "\(config.queryFrameCount)",
            "--max-query-pts", "\(config.maxQueryPoints)",
            "--keypoint-extractor", config.keypointExtractor
        ]
        var argsWithBA = args
        if config.useBundleAdjustment {
            argsWithBA.append("--use-ba")
        }
        if config.bundleAdjustmentMaxFrames > 0 {
            argsWithBA.append("--ba-max-frames")
            argsWithBA.append("\(config.bundleAdjustmentMaxFrames)")
        }
        if config.sharedCamera {
            argsWithBA.append("--shared-camera")
        }
        if config.fineTracking {
            argsWithBA.append("--fine-tracking")
        } else {
            argsWithBA.append("--no-fine-tracking")
        }

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
        onLog("EasySplat: vggt argv: \(toolchain.sfmTool.path) \(argsWithBA.joined(separator: " "))", false)

        let result = try await runner.runAsync(
            toolchain.sfmTool.path,
            argsWithBA,
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
