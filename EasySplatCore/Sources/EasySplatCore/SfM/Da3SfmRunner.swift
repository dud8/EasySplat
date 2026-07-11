import Foundation

/// Execution mode for the Depth Anything 3 bridge.
public enum Da3RunMode: String, Sendable {
    case direct
    case seedRefine = "seed_refine"
}

/// Runtime options for invoking the Depth Anything 3 SfM bridge.
public struct Da3SfmConfig: Sendable {
    public var device: String
    public var mode: Da3RunMode
    public var modelSubdirectory: String
    public var fallbackModelSubdirectory: String
    public var processResolution: Int
    public var maxPoints: Int
    public var cameraType: String
    public var sharedCamera: Bool
    public var inputOrdering: InputOrdering
    public var windowSize: Int
    public var windowOverlap: Int
    public var coverageManifestPath: URL?

    public init(
        device: String = "mps",
        mode: Da3RunMode = .direct,
        modelSubdirectory: String = "DA3-BASE",
        fallbackModelSubdirectory: String = "DA3-SMALL",
        processResolution: Int = 504,
        maxPoints: Int = 120_000,
        cameraType: String = "PINHOLE",
        sharedCamera: Bool = false,
        inputOrdering: InputOrdering = .automatic,
        windowSize: Int = 6,
        windowOverlap: Int = 2,
        coverageManifestPath: URL? = nil
    ) {
        self.device = device
        self.mode = mode
        self.modelSubdirectory = modelSubdirectory
        self.fallbackModelSubdirectory = fallbackModelSubdirectory
        self.processResolution = processResolution
        self.maxPoints = maxPoints
        self.cameraType = cameraType
        self.sharedCamera = sharedCamera
        self.inputOrdering = inputOrdering
        self.windowSize = windowSize
        self.windowOverlap = windowOverlap
        self.coverageManifestPath = coverageManifestPath
    }
}

/// Interface for running the Depth Anything 3 SfM bridge.
public protocol Da3SfmRunning: Sendable {
    func run(
        toolchain: Da3Toolchain,
        images: URL,
        outSparse: URL,
        config: Da3SfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws
}

public enum Da3SfmError: Error {
    case missingTool
    case missingModels
    case commandFailed(String)
}

/// Default subprocess-backed runner for the Depth Anything 3 SfM bridge.
public final class Da3SfmRunner: @unchecked Sendable, Da3SfmRunning {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func run(
        toolchain: Da3Toolchain,
        images: URL,
        outSparse: URL,
        config: Da3SfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: toolchain.sfmTool.path) else {
            throw Da3SfmError.missingTool
        }
        guard fm.fileExists(atPath: toolchain.models.path) else {
            throw Da3SfmError.missingModels
        }
        var args: [String] = [
            "--images", images.path,
            "--out-sparse", outSparse.path,
            "--models-dir", toolchain.models.path,
            "--device", config.device,
            "--mode", config.mode.rawValue,
            "--model-subdir", config.modelSubdirectory,
            "--fallback-model-subdir", config.fallbackModelSubdirectory,
            "--process-res", "\(config.processResolution)",
            "--max-points", "\(config.maxPoints)",
            "--camera-type", config.cameraType,
            "--input-ordering", config.inputOrdering.rawValue,
            "--window-size", "\(config.windowSize)",
            "--window-overlap", "\(config.windowOverlap)"
        ]

        if config.sharedCamera {
            args.append("--shared-camera")
        }
        if let coverageManifestPath = config.coverageManifestPath {
            args.append(contentsOf: ["--manifest-out", coverageManifestPath.path])
        }

        var environment = RuntimeEnvironment.current
        environment["PYTHONUNBUFFERED"] = "1"
        environment["EASYSPLAT_DA3_MODELS_DIR"] = toolchain.models.path
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

        onLog("EasySplat: running da3-mps (cwd=\(toolchain.root.path))", false)
        onLog("EasySplat: da3 argv: \(toolchain.sfmTool.path) \(args.joined(separator: " "))", false)

        let result = try await runner.runAsync(
            toolchain.sfmTool.path,
            args,
            currentDirectory: toolchain.root,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        guard result.exitCode == 0 else {
            throw Da3SfmError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
