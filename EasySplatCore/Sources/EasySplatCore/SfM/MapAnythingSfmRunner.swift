import Foundation

public enum MapAnythingRunMode: String, Sendable {
    case direct
    case seedRefine = "seed_refine"
}

public struct MapAnythingSfmConfig: Sendable {
    public var device: String
    public var mode: MapAnythingRunMode
    public var checkpointSubdirectory: String
    public var resolution: Int
    public var memoryEfficientInference: Bool
    public var minibatchSize: Int
    public var useAMP: Bool
    public var maxPoints: Int
    public var cameraType: String
    public var sharedCamera: Bool
    public var anchorMaxViews: Int
    public var windowSize: Int
    public var windowOverlap: Int
    public var coverageManifestPath: URL?

    public init(
        device: String = "mps",
        mode: MapAnythingRunMode = .direct,
        checkpointSubdirectory: String = "map-anything-apache",
        resolution: Int = 518,
        memoryEfficientInference: Bool = true,
        minibatchSize: Int = 1,
        useAMP: Bool = false,
        maxPoints: Int = 120_000,
        cameraType: String = "SIMPLE_RADIAL",
        sharedCamera: Bool = false,
        anchorMaxViews: Int = 64,
        windowSize: Int = 6,
        windowOverlap: Int = 2,
        coverageManifestPath: URL? = nil
    ) {
        self.device = device
        self.mode = mode
        self.checkpointSubdirectory = checkpointSubdirectory
        self.resolution = resolution
        self.memoryEfficientInference = memoryEfficientInference
        self.minibatchSize = minibatchSize
        self.useAMP = useAMP
        self.maxPoints = maxPoints
        self.cameraType = cameraType
        self.sharedCamera = sharedCamera
        self.anchorMaxViews = anchorMaxViews
        self.windowSize = windowSize
        self.windowOverlap = windowOverlap
        self.coverageManifestPath = coverageManifestPath
    }
}

public protocol MapAnythingSfmRunning: Sendable {
    func run(
        toolchain: MapAnythingToolchain,
        images: URL,
        outSparse: URL,
        config: MapAnythingSfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws
}

public enum MapAnythingSfmError: Error {
    case missingTool
    case missingModels
    case commandFailed(String)
}

public final class MapAnythingSfmRunner: @unchecked Sendable, MapAnythingSfmRunning {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func run(
        toolchain: MapAnythingToolchain,
        images: URL,
        outSparse: URL,
        config: MapAnythingSfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: toolchain.sfmTool.path) else {
            throw MapAnythingSfmError.missingTool
        }
        guard fm.fileExists(atPath: toolchain.models.path) else {
            throw MapAnythingSfmError.missingModels
        }

        var args: [String] = [
            "--images", images.path,
            "--out-sparse", outSparse.path,
            "--models-dir", toolchain.models.path,
            "--device", config.device,
            "--mode", config.mode.rawValue,
            "--checkpoint-subdir", config.checkpointSubdirectory,
            "--resolution", "\(config.resolution)",
            "--minibatch-size", "\(config.minibatchSize)",
            "--max-points", "\(config.maxPoints)",
            "--camera-type", config.cameraType,
            "--anchor-max-views", "\(config.anchorMaxViews)",
            "--window-size", "\(config.windowSize)",
            "--window-overlap", "\(config.windowOverlap)"
        ]

        args.append(config.memoryEfficientInference ? "--memory-efficient-inference" : "--no-memory-efficient-inference")
        if config.useAMP {
            args.append("--use-amp")
        }
        if config.sharedCamera {
            args.append("--shared-camera")
        }
        if let coverageManifestPath = config.coverageManifestPath {
            args.append(contentsOf: ["--manifest-out", coverageManifestPath.path])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["EASYSPLAT_MAPANYTHING_MODELS_DIR"] = toolchain.models.path
        environment["TORCH_HOME"] = toolchain.models.path
        environment["HF_HOME"] = toolchain.models.appendingPathComponent("huggingface", isDirectory: true).path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        environment["KMP_DUPLICATE_LIB_OK"] = "TRUE"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        if environment["PYTORCH_ENABLE_MPS_FALLBACK"] == nil {
            environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        }

        let pythonBin = toolchain.python.deletingLastPathComponent().path
        if let existingPath = environment["PATH"] {
            environment["PATH"] = "\(pythonBin):\(existingPath)"
        } else {
            environment["PATH"] = pythonBin
        }

        onLog("EasySplat: running mapanything-mps (cwd=\(toolchain.root.path))", false)
        onLog("EasySplat: mapanything argv: \(toolchain.sfmTool.path) \(args.joined(separator: " "))", false)

        let result = try await runner.runAsync(
            toolchain.sfmTool.path,
            args,
            currentDirectory: toolchain.root,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        guard result.exitCode == 0 else {
            throw MapAnythingSfmError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
