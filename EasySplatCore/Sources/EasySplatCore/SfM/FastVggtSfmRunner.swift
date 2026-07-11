import Foundation

/// Coverage-planning options for strict FastVGGT runs.
public struct FastVggtCoverageConfig: Sendable {
    public var requireFullCoverage: Bool
    public var coveragePlanner: String
    public var coverageWindowTokens: Int
    public var coverageOverlap: Double
    public var coverageMaxRounds: Int
    public var coverageManifestPath: URL?
    public var gpuOnly: Bool
    public var postprocessMode: String

    public init(
        requireFullCoverage: Bool = false,
        coveragePlanner: String = "auto",
        coverageWindowTokens: Int = 25_000,
        coverageOverlap: Double = 0.35,
        coverageMaxRounds: Int = 4,
        coverageManifestPath: URL? = nil,
        gpuOnly: Bool = false,
        postprocessMode: String = "gpu_ba_lite"
    ) {
        self.requireFullCoverage = requireFullCoverage
        self.coveragePlanner = coveragePlanner
        self.coverageWindowTokens = coverageWindowTokens
        self.coverageOverlap = coverageOverlap
        self.coverageMaxRounds = coverageMaxRounds
        self.coverageManifestPath = coverageManifestPath
        self.gpuOnly = gpuOnly
        self.postprocessMode = postprocessMode
    }
}

/// Runtime options for invoking the FastVGGT SfM bridge.
public struct FastVggtSfmConfig: Sendable {
    public var device: String
    public var dtype: String
    public var vggtFixedResolution: Int
    public var confidenceThreshold: Double
    public var maxPoints: Int
    public var merging: Int
    public var mergeRatio: Double
    public var sharedCamera: Bool
    public var cameraType: String
    public var coverage: FastVggtCoverageConfig?

    public init(
        device: String = "mps",
        dtype: String = "auto",
        vggtFixedResolution: Int = 518,
        confidenceThreshold: Double = 3.0,
        maxPoints: Int = 100_000,
        merging: Int = 0,
        mergeRatio: Double = 0.9,
        sharedCamera: Bool = false,
        cameraType: String = "SIMPLE_PINHOLE",
        coverage: FastVggtCoverageConfig? = nil
    ) {
        self.device = device
        self.dtype = dtype
        self.vggtFixedResolution = vggtFixedResolution
        self.confidenceThreshold = confidenceThreshold
        self.maxPoints = maxPoints
        self.merging = merging
        self.mergeRatio = mergeRatio
        self.sharedCamera = sharedCamera
        self.cameraType = cameraType
        self.coverage = coverage
    }
}

/// Interface for running the FastVGGT SfM bridge.
public protocol FastVggtSfmRunning: Sendable {
    func run(
        toolchain: FastVggtToolchain,
        images: URL,
        outSparse: URL,
        config: FastVggtSfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws
}

public enum FastVggtSfmError: Error {
    case missingTool
    case missingModels
    case commandFailed(String)
}

/// Default subprocess-backed runner for the FastVGGT SfM bridge.
public final class FastVggtSfmRunner: @unchecked Sendable, FastVggtSfmRunning {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func run(
        toolchain: FastVggtToolchain,
        images: URL,
        outSparse: URL,
        config: FastVggtSfmConfig,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: toolchain.sfmTool.path) else {
            throw FastVggtSfmError.missingTool
        }
        guard fm.fileExists(atPath: toolchain.models.path) else {
            throw FastVggtSfmError.missingModels
        }

        let args: [String] = [
            "--images", images.path,
            "--out-sparse", outSparse.path,
            "--device", config.device,
            "--dtype", config.dtype,
            "--vggt-resolution", "\(config.vggtFixedResolution)",
            "--conf-thres", "\(config.confidenceThreshold)",
            "--max-points", "\(config.maxPoints)",
            "--models-dir", toolchain.models.path,
            "--merging", "\(config.merging)",
            "--merge-ratio", "\(config.mergeRatio)",
            "--camera-type", config.cameraType
        ]

        var resolvedArgs = args
        if config.sharedCamera {
            resolvedArgs.append("--shared-camera")
        }
        if let coverage = config.coverage {
            if coverage.requireFullCoverage {
                resolvedArgs.append("--require-full-coverage")
            }
            resolvedArgs.append(contentsOf: ["--coverage-planner", coverage.coveragePlanner])
            resolvedArgs.append(contentsOf: ["--coverage-window-tokens", "\(coverage.coverageWindowTokens)"])
            resolvedArgs.append(contentsOf: ["--coverage-overlap", "\(coverage.coverageOverlap)"])
            resolvedArgs.append(contentsOf: ["--coverage-max-rounds", "\(coverage.coverageMaxRounds)"])
            if let manifestPath = coverage.coverageManifestPath {
                resolvedArgs.append(contentsOf: ["--coverage-manifest", manifestPath.path])
            }
            if coverage.gpuOnly {
                resolvedArgs.append("--gpu-only")
            }
            resolvedArgs.append(contentsOf: ["--postprocess", coverage.postprocessMode])
        }

        var environment = RuntimeEnvironment.current
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TORCH_HOME"] = toolchain.models.path
        environment["EASYSPLAT_FASTVGGT_MODELS_DIR"] = toolchain.models.path
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

        onLog("EasySplat: running fastvggt-mps (cwd=\(toolchain.root.path))", false)
        onLog("EasySplat: fastvggt argv: \(toolchain.sfmTool.path) \(resolvedArgs.joined(separator: " "))", false)

        let result = try await runner.runAsync(
            toolchain.sfmTool.path,
            resolvedArgs,
            currentDirectory: toolchain.root,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        guard result.exitCode == 0 else {
            throw FastVggtSfmError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
