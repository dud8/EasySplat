import Foundation

/// Bundle-adjustment parameters used when refining a sparse model with COLMAP.
public struct ColmapBundleAdjustmentOptions: Sendable {
    public var maxNumIterations: Int
    public var refineFocalLength: Bool
    public var refinePrincipalPoint: Bool
    public var refineExtraParams: Bool

    public init(
        maxNumIterations: Int = 50,
        refineFocalLength: Bool = true,
        refinePrincipalPoint: Bool = false,
        refineExtraParams: Bool = false
    ) {
        self.maxNumIterations = max(1, maxNumIterations)
        self.refineFocalLength = refineFocalLength
        self.refinePrincipalPoint = refinePrincipalPoint
        self.refineExtraParams = refineExtraParams
    }
}

/// Shared COLMAP feature extraction and matching options.
public struct ColmapOptions: Sendable {
    public var useGPU: Bool
    public var extractThreads: Int
    public var matchThreads: Int
    public var sequentialOverlap: Int
    public var maxNumFeatures: Int?
    public var maxNumMatches: Int?
    public var useBruteForceMatcher: Bool
    public var exhaustiveBlockSize: Int?
    public var environment: [String: String]

    public init(
        useGPU: Bool,
        extractThreads: Int,
        matchThreads: Int,
        sequentialOverlap: Int,
        maxNumFeatures: Int? = nil,
        maxNumMatches: Int? = nil,
        useBruteForceMatcher: Bool = false,
        exhaustiveBlockSize: Int? = nil,
        environment: [String: String] = [:]
    ) {
        self.useGPU = useGPU
        self.extractThreads = extractThreads
        self.matchThreads = matchThreads
        self.sequentialOverlap = sequentialOverlap
        self.maxNumFeatures = maxNumFeatures
        self.maxNumMatches = maxNumMatches
        self.useBruteForceMatcher = useBruteForceMatcher
        self.exhaustiveBlockSize = exhaustiveBlockSize
        self.environment = environment
    }

    public static func stabilityDefaults() -> ColmapOptions {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let extractThreads = min(8, max(2, cores / 2))
        return ColmapOptions(
            useGPU: false,
            extractThreads: extractThreads,
            matchThreads: 1,
            sequentialOverlap: 10,
            maxNumFeatures: 8192,
            maxNumMatches: 8192,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 20,
            environment: [:]
        )
    }
}

/// Options for COLMAP's integrated `global_mapper` pipeline.
public struct ColmapGlobalMapperOptions: Sendable {
    public var useGpuForGlobalPositioning: Bool
    public var gpuIndexForGlobalPositioning: String
    public var useGpuForBundleAdjustment: Bool
    public var gpuIndexForBundleAdjustment: String
    public var numThreads: Int
    public var minNumMatches: Int?
    public var baNumIterations: Int?

    public init(
        useGpuForGlobalPositioning: Bool = true,
        gpuIndexForGlobalPositioning: String = "-1",
        useGpuForBundleAdjustment: Bool = true,
        gpuIndexForBundleAdjustment: String = "-1",
        numThreads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minNumMatches: Int? = nil,
        baNumIterations: Int? = nil
    ) {
        self.useGpuForGlobalPositioning = useGpuForGlobalPositioning
        self.gpuIndexForGlobalPositioning = gpuIndexForGlobalPositioning
        self.useGpuForBundleAdjustment = useGpuForBundleAdjustment
        self.gpuIndexForBundleAdjustment = gpuIndexForBundleAdjustment
        self.numThreads = max(1, numThreads)
        self.minNumMatches = minNumMatches.map { max(1, $0) }
        self.baNumIterations = baNumIterations.map { max(1, $0) }
    }
}

public enum ColmapRunnerError: Error, LocalizedError {
    case failed(command: String, exitCode: Int32, terminationReason: Process.TerminationReason, stdoutTail: String, stderrTail: String)

    public var errorDescription: String? {
        switch self {
        case let .failed(command, exitCode, terminationReason, _, _):
            return "Colmap failed: \(command) (exit \(exitCode), reason: \(terminationReason))"
        }
    }
}

/// Subprocess-backed wrapper around the COLMAP command-line tools.
public final class ColmapRunner {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func runFeatureExtractor(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        maxImageSize: Int,
        cameraModel: String,
        singleCamera: Bool = true,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "feature_extractor",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--ImageReader.single_camera", singleCamera ? "1" : "0",
            "--ImageReader.camera_model", cameraModel,
            "--SiftExtraction.max_image_size", "\(maxImageSize)",
            "--FeatureExtraction.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureExtraction.num_threads", "\(options.extractThreads)"
        ]
        var finalArgs = args
        if let maxNumFeatures = options.maxNumFeatures {
            finalArgs.append(contentsOf: ["--SiftExtraction.max_num_features", "\(maxNumFeatures)"])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(finalArgs.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            finalArgs,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "feature_extractor")
    }

    public func runFeatureImporter(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        importPath: URL,
        cameraModel: String,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "feature_importer",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--import_path", importPath.path,
            "--ImageReader.single_camera", "1",
            "--ImageReader.camera_model", cameraModel,
            "--FeatureExtraction.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureExtraction.num_threads", "\(options.extractThreads)"
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "feature_importer")
    }

    public func runMatchesImporter(
        colmapPath: URL,
        database: URL,
        matchListPath: URL,
        matchType: String,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "matches_importer",
            "--database_path", database.path,
            "--match_list_path", matchListPath.path,
            "--match_type", matchType,
            "--FeatureMatching.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureMatching.num_threads", "\(options.matchThreads)"
        ]
        var finalArgs = args
        if let maxNumMatches = options.maxNumMatches {
            finalArgs.append(contentsOf: ["--FeatureMatching.max_num_matches", "\(maxNumMatches)"])
        }
        // matches_importer runs SIFT matching per listed pair, so on this toolchain's
        // FLANN-segfaulting COLMAP build it needs the brute-force flag just like the
        // sequential/exhaustive matchers, or it would crash the same way.
        if options.useBruteForceMatcher {
            finalArgs.append(contentsOf: ["--SiftMatching.cpu_brute_force_matcher", "1"])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(finalArgs.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            finalArgs,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "matches_importer")
    }

    public func runMatcherSequential(
        colmapPath: URL,
        database: URL,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "sequential_matcher",
            "--database_path", database.path,
            "--FeatureMatching.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureMatching.num_threads", "\(options.matchThreads)",
            "--SequentialMatching.overlap", "\(options.sequentialOverlap)"
        ]
        var finalArgs = args
        if let maxNumMatches = options.maxNumMatches {
            finalArgs.append(contentsOf: ["--FeatureMatching.max_num_matches", "\(maxNumMatches)"])
        }
        if options.useBruteForceMatcher {
            finalArgs.append(contentsOf: ["--SiftMatching.cpu_brute_force_matcher", "1"])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(finalArgs.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            finalArgs,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "sequential_matcher")
    }

    public func runMatcherExhaustive(
        colmapPath: URL,
        database: URL,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "exhaustive_matcher",
            "--database_path", database.path,
            "--FeatureMatching.use_gpu", options.useGPU ? "1" : "0",
            "--FeatureMatching.num_threads", "\(options.matchThreads)"
        ]
        var finalArgs = args
        if let maxNumMatches = options.maxNumMatches {
            finalArgs.append(contentsOf: ["--FeatureMatching.max_num_matches", "\(maxNumMatches)"])
        }
        if options.useBruteForceMatcher {
            finalArgs.append(contentsOf: ["--SiftMatching.cpu_brute_force_matcher", "1"])
        }
        if let blockSize = options.exhaustiveBlockSize {
            finalArgs.append(contentsOf: ["--ExhaustiveMatching.block_size", "\(blockSize)"])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(finalArgs.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            finalArgs,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "exhaustive_matcher")
    }

    public func runMapper(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        outputPath: URL,
        options: ColmapOptions,
        bundleAdjustmentIterationLimit: Int? = nil,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        var args = [
            "mapper",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--output_path", outputPath.path
        ]
        if let bundleAdjustmentIterationLimit {
            args.append(contentsOf: [
                "--Mapper.ba_global_max_num_iterations",
                "\(max(1, bundleAdjustmentIterationLimit))",
            ])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "mapper")
    }

    public func runGlobalMapper(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        outputPath: URL,
        options: ColmapGlobalMapperOptions,
        environment: [String: String] = [:],
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        var args = [
            "global_mapper",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--output_path", outputPath.path,
            "--GlobalMapper.num_threads", "\(options.numThreads)",
            "--GlobalMapper.gp_use_gpu", options.useGpuForGlobalPositioning ? "1" : "0",
            "--GlobalMapper.gp_gpu_index", options.gpuIndexForGlobalPositioning,
            "--GlobalMapper.ba_ceres_use_gpu", options.useGpuForBundleAdjustment ? "1" : "0",
            "--GlobalMapper.ba_ceres_gpu_index", options.gpuIndexForBundleAdjustment
        ]
        if let minNumMatches = options.minNumMatches {
            args.append(contentsOf: ["--GlobalMapper.min_num_matches", "\(minNumMatches)"])
        }
        if let baNumIterations = options.baNumIterations {
            args.append(contentsOf: ["--GlobalMapper.ba_num_iterations", "\(baNumIterations)"])
        }
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "global_mapper")
    }

    public func runPointTriangulator(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        inputPath: URL,
        outputPath: URL,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "point_triangulator",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--input_path", inputPath.path,
            "--output_path", outputPath.path
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "point_triangulator")
    }

    public func runBundleAdjuster(
        colmapPath: URL,
        inputPath: URL,
        outputPath: URL,
        options: ColmapOptions,
        bundleOptions: ColmapBundleAdjustmentOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: outputPath.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                try fm.removeItem(at: outputPath)
                try fm.createDirectory(at: outputPath, withIntermediateDirectories: true)
            }
        } else {
            try fm.createDirectory(at: outputPath, withIntermediateDirectories: true)
        }

        let baseArgs = [
            "bundle_adjuster",
            "--input_path", inputPath.path,
            "--output_path", outputPath.path,
            "--BundleAdjustment.refine_focal_length", bundleOptions.refineFocalLength ? "1" : "0",
            "--BundleAdjustment.refine_principal_point", bundleOptions.refinePrincipalPoint ? "1" : "0",
            "--BundleAdjustment.refine_extra_params", bundleOptions.refineExtraParams ? "1" : "0"
        ]
        let maxIterations = "\(max(1, bundleOptions.maxNumIterations))"
        let ceresArgs = baseArgs + ["--BundleAdjustmentCeres.max_num_iterations", maxIterations]

        onLog("EasySplat: colmap argv: \(colmapPath.path) \(ceresArgs.joined(separator: " "))", false)
        var result = try await runner.runAsync(
            colmapPath.path,
            ceresArgs,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )

        if shouldRetryBundleAdjusterWithLegacyIterationFlag(result: result) {
            let legacyArgs = baseArgs + ["--BundleAdjustment.max_num_iterations", maxIterations]
            onLog(
                "EasySplat: bundle_adjuster rejected BundleAdjustmentCeres.max_num_iterations; retrying with BundleAdjustment.max_num_iterations.",
                true
            )
            onLog("EasySplat: colmap argv: \(colmapPath.path) \(legacyArgs.joined(separator: " "))", false)
            result = try await runner.runAsync(
                colmapPath.path,
                legacyArgs,
                currentDirectory: nil,
                environment: options.environment,
                onStdout: { onLog($0, false) },
                onStderr: { onLog($0, true) }
            )
        }

        try checkResult(result, command: "bundle_adjuster")
    }

    public func runModelAnalyzer(
        colmapPath: URL,
        modelPath: URL,
        options: ColmapOptions
    ) async throws -> String {
        let args = ["model_analyzer", "--path", modelPath.path]
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: options.environment,
            onStdout: { _ in },
            onStderr: { _ in }
        )
        try checkResult(result, command: "model_analyzer")
        // COLMAP tools sometimes print reports to stderr even on success; return combined output.
        return [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public func runModelConverter(
        colmapPath: URL,
        inputPath: URL,
        outputPath: URL,
        outputType: String = "TXT",
        environment: [String: String] = [:],
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) throws {
        let args = [
            "model_converter",
            "--input_path", inputPath.path,
            "--output_path", outputPath.path,
            "--output_type", outputType
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try runner.run(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "model_converter")
    }

    private func checkResult(_ result: SubprocessResult, command: String) throws {
        guard result.exitCode == 0 else {
            throw ColmapRunnerError.failed(
                command: command,
                exitCode: result.exitCode,
                terminationReason: result.terminationReason,
                stdoutTail: tailLines(result.stdout, limit: 40),
                stderrTail: tailLines(result.stderr, limit: 40)
            )
        }
    }

    private func shouldRetryBundleAdjusterWithLegacyIterationFlag(result: SubprocessResult) -> Bool {
        guard result.exitCode != 0 else { return false }
        let text = "\(result.stdout)\n\(result.stderr)".lowercased()
        if text.contains("bundleadjustmentceres.max_num_iterations"),
           (text.contains("unrecognised option") || text.contains("unrecognized option")) {
            return true
        }
        return false
    }

    private func tailLines(_ text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
