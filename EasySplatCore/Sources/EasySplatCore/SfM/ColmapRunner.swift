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

public enum ColmapMapperOptionsValidationError: Error, LocalizedError, Equatable {
    case invalidRatio(String)
    case nonPositiveValue(String)
    case randomSeedOutOfRange

    public var errorDescription: String? {
        switch self {
        case .invalidRatio(let name):
            return "\(name) must be finite and greater than one."
        case .nonPositiveValue(let name):
            return "\(name) must be greater than zero."
        case .randomSeedOutOfRange:
            return "Mapper random seed must fit in a signed 32-bit integer."
        }
    }
}

enum ColmapMappingPolicy {
    static let minimumPairInlierCount = 15
    static let maximumAcceptedRecoverableViewLoss = 2
}

/// Fixed incremental-mapper policy passed across the native COLMAP process boundary.
public struct ColmapMapperOptions: Sendable, Equatable {
    public let globalFramesRatio: Double
    public let globalPointsRatio: Double
    public let localMaxRefinements: Int
    public let globalMaxRefinements: Int
    public let globalMaxNumIterations: Int
    public let randomSeed: Int32
    public let refineFocalLength: Bool

    public init(
        globalFramesRatio: Double,
        globalPointsRatio: Double,
        localMaxRefinements: Int,
        globalMaxRefinements: Int,
        globalMaxNumIterations: Int,
        randomSeed: UInt64,
        refineFocalLength: Bool
    ) throws {
        guard globalFramesRatio.isFinite, globalFramesRatio > 1 else {
            throw ColmapMapperOptionsValidationError.invalidRatio("Global frame ratio")
        }
        guard globalPointsRatio.isFinite, globalPointsRatio > 1 else {
            throw ColmapMapperOptionsValidationError.invalidRatio("Global point ratio")
        }
        guard localMaxRefinements > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Local refinement limit")
        }
        guard globalMaxRefinements > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Global refinement limit")
        }
        guard globalMaxNumIterations > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Global iteration limit")
        }
        guard let randomSeed = Int32(exactly: randomSeed) else {
            throw ColmapMapperOptionsValidationError.randomSeedOutOfRange
        }

        self.globalFramesRatio = globalFramesRatio
        self.globalPointsRatio = globalPointsRatio
        self.localMaxRefinements = localMaxRefinements
        self.globalMaxRefinements = globalMaxRefinements
        self.globalMaxNumIterations = globalMaxNumIterations
        self.randomSeed = randomSeed
        self.refineFocalLength = refineFocalLength
    }
}

public enum ColmapVocabularyRetrievalOptionsValidationError: Error, LocalizedError, Equatable {
    case candidateCountOutOfRange
    case neighborCountOutOfRange
    case neighborCountExceedsCandidateCount
    case minimumFrameSeparationOutOfRange
    case threadCountOutOfRange

    public var errorDescription: String? {
        switch self {
        case .candidateCountOutOfRange:
            return "Vocabulary candidate count must be between 1 and 256."
        case .neighborCountOutOfRange:
            return "Vocabulary neighbor count must be between 1 and 64."
        case .neighborCountExceedsCandidateCount:
            return "Vocabulary neighbor count cannot exceed the candidate count."
        case .minimumFrameSeparationOutOfRange:
            return "Vocabulary frame separation must be between 0 and 1,000,000."
        case .threadCountOutOfRange:
            return "Vocabulary retrieval thread count must be between 1 and 64."
        }
    }
}

/// Bounded inputs for EasySplat's project-local SIFT vocabulary process boundary.
public struct ColmapVocabularyRetrievalOptions: Sendable, Equatable {
    public let candidateCount: Int
    public let returnedNeighborCount: Int
    public let minimumFrameSeparation: Int
    public let threadCount: Int

    public init(
        candidateCount: Int,
        returnedNeighborCount: Int,
        minimumFrameSeparation: Int,
        threadCount: Int
    ) throws {
        guard (1...256).contains(candidateCount) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.candidateCountOutOfRange
        }
        guard (1...64).contains(returnedNeighborCount) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.neighborCountOutOfRange
        }
        guard returnedNeighborCount <= candidateCount else {
            throw ColmapVocabularyRetrievalOptionsValidationError.neighborCountExceedsCandidateCount
        }
        guard (0...1_000_000).contains(minimumFrameSeparation) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.minimumFrameSeparationOutOfRange
        }
        guard (1...64).contains(threadCount) else {
            throw ColmapVocabularyRetrievalOptionsValidationError.threadCountOutOfRange
        }
        self.candidateCount = candidateCount
        self.returnedNeighborCount = returnedNeighborCount
        self.minimumFrameSeparation = minimumFrameSeparation
        self.threadCount = threadCount
    }
}

/// Shared COLMAP feature extraction and matching options.
public struct ColmapOptions: Sendable {
    public var useGPU: Bool
    public var extractThreads: Int
    public var matchThreads: Int
    public var maxNumFeatures: Int?
    public var maxNumMatches: Int?
    public var descriptorMatcher: DescriptorMatcher
    public var environment: [String: String]

    public init(
        useGPU: Bool,
        extractThreads: Int,
        matchThreads: Int,
        maxNumFeatures: Int? = nil,
        maxNumMatches: Int? = nil,
        descriptorMatcher: DescriptorMatcher = .faiss,
        environment: [String: String] = [:]
    ) {
        self.useGPU = useGPU
        self.extractThreads = extractThreads
        self.matchThreads = matchThreads
        self.maxNumFeatures = maxNumFeatures
        self.maxNumMatches = maxNumMatches
        self.descriptorMatcher = descriptorMatcher
        self.environment = environment
    }

    public static func stabilityDefaults() -> ColmapOptions {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let extractThreads = min(8, max(2, cores / 2))
        return ColmapOptions(
            useGPU: false,
            extractThreads: extractThreads,
            matchThreads: 1,
            maxNumFeatures: 8192,
            maxNumMatches: 8192,
            descriptorMatcher: .faiss,
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
        finalArgs.append(contentsOf: [
            "--SiftMatching.cpu_brute_force_matcher",
            options.descriptorMatcher == .exact ? "1" : "0",
        ])
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

    public func runLocalVocabularyRetriever(
        colmapPath: URL,
        database: URL,
        outputPairListPath: URL,
        queryImageListPath: URL?,
        excludedPairListPath: URL?,
        options: ColmapVocabularyRetrievalOptions,
        environment: [String: String] = [:],
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        var args = [
            "local_vocab_retriever",
            "--database_path", database.path,
            "--output_pair_list_path", outputPairListPath.path,
            "--num_images", "\(options.candidateCount)",
            "--returned_neighbor_count", "\(options.returnedNeighborCount)",
            "--minimum_frame_separation", "\(options.minimumFrameSeparation)",
            "--num_visual_words", "512",
            "--max_features_per_image", "512",
            "--max_training_descriptors", "65536",
            "--num_iterations", "10",
            "--num_rounds", "1",
            "--num_checks", "64",
            "--num_threads", "\(options.threadCount)",
        ]
        if let queryImageListPath {
            args.append(contentsOf: ["--query_image_list_path", queryImageListPath.path])
        }
        if let excludedPairListPath {
            args.append(contentsOf: ["--excluded_pair_list_path", excludedPairListPath.path])
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
        try checkResult(result, command: "local_vocab_retriever")
    }

    public func runMapper(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        outputPath: URL,
        options: ColmapOptions,
        mapperOptions: ColmapMapperOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "mapper",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--output_path", outputPath.path,
            "--Mapper.ba_global_frames_ratio", "\(mapperOptions.globalFramesRatio)",
            "--Mapper.ba_global_points_ratio", "\(mapperOptions.globalPointsRatio)",
            "--Mapper.ba_local_max_refinements", "\(mapperOptions.localMaxRefinements)",
            "--Mapper.ba_global_max_refinements", "\(mapperOptions.globalMaxRefinements)",
            "--Mapper.ba_global_max_num_iterations", "\(mapperOptions.globalMaxNumIterations)",
            "--Mapper.random_seed", "\(mapperOptions.randomSeed)",
            "--Mapper.min_num_matches", "\(ColmapMappingPolicy.minimumPairInlierCount)",
            "--Mapper.ba_refine_focal_length", mapperOptions.refineFocalLength ? "1" : "0",
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

    public func runImageUndistorter(
        colmapPath: URL,
        imagePath: URL,
        inputPath: URL,
        outputPath: URL,
        maxImageSize: Int,
        environment: [String: String] = [:],
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "image_undistorter",
            "--image_path", imagePath.path,
            "--input_path", inputPath.path,
            "--output_path", outputPath.path,
            "--output_type", "COLMAP",
            "--copy_policy", "COPY",
            "--max_image_size", "\(max(1, maxImageSize))",
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: environment,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "image_undistorter")
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
