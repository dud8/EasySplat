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
    case invalidTolerance(String)
    case nonPositiveValue(String)
    case randomSeedOutOfRange

    public var errorDescription: String? {
        switch self {
        case .invalidRatio(let name):
            return "\(name) must be finite and greater than one."
        case .invalidTolerance(let name):
            return "\(name) must be finite and nonnegative."
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
    public let localMaxNumIterations: Int
    public let localFunctionTolerance: Double
    public let globalFunctionTolerance: Double
    public let localImageCount: Int
    public let randomSeed: Int32
    public let refineFocalLength: Bool

    public init(
        globalFramesRatio: Double,
        globalPointsRatio: Double,
        localMaxRefinements: Int,
        globalMaxRefinements: Int,
        globalMaxNumIterations: Int,
        localMaxNumIterations: Int = 10,
        localFunctionTolerance: Double = 0.001,
        globalFunctionTolerance: Double = 0.000_001,
        localImageCount: Int = 6,
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
        guard localMaxNumIterations > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Local iteration limit")
        }
        guard localFunctionTolerance.isFinite, localFunctionTolerance >= 0 else {
            throw ColmapMapperOptionsValidationError.invalidTolerance("Local function tolerance")
        }
        guard globalFunctionTolerance.isFinite, globalFunctionTolerance >= 0 else {
            throw ColmapMapperOptionsValidationError.invalidTolerance("Global function tolerance")
        }
        guard localImageCount > 0 else {
            throw ColmapMapperOptionsValidationError.nonPositiveValue("Local image count")
        }
        guard let randomSeed = Int32(exactly: randomSeed) else {
            throw ColmapMapperOptionsValidationError.randomSeedOutOfRange
        }

        self.globalFramesRatio = globalFramesRatio
        self.globalPointsRatio = globalPointsRatio
        self.localMaxRefinements = localMaxRefinements
        self.globalMaxRefinements = globalMaxRefinements
        self.globalMaxNumIterations = globalMaxNumIterations
        self.localMaxNumIterations = localMaxNumIterations
        self.localFunctionTolerance = localFunctionTolerance
        self.globalFunctionTolerance = globalFunctionTolerance
        self.localImageCount = localImageCount
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

}

public enum ColmapRunnerError: Error, LocalizedError {
    case failed(command: String, exitCode: Int32, terminationReason: Process.TerminationReason, stdoutTail: String, stderrTail: String)
    case executionEvidenceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .failed(command, exitCode, terminationReason, _, _):
            return "Colmap failed: \(command) (exit \(exitCode), reason: \(terminationReason))"
        case .executionEvidenceUnavailable(let command):
            return "COLMAP did not expose verified launch evidence for \(command)."
        }
    }
}

/// Subprocess-backed wrapper around the COLMAP command-line tools.
public final class ColmapRunner: @unchecked Sendable {
    private static let inheritedThreadEnvironmentKeys = Set(
        GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys
    )

    private let runner: SubprocessRunning
    private let observerLock = NSLock()
    private var workerExecutionObserver: (
        @Sendable (ColmapWorkerInvocationEvidence) throws -> Void
    )?

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func setWorkerExecutionObserver(
        _ observer: (@Sendable (ColmapWorkerInvocationEvidence) throws -> Void)?
    ) {
        observerLock.withLock {
            workerExecutionObserver = observer
        }
    }

    private static func boundedWorkerEnvironment(
        _ environment: [String: String],
        workerCount: Int
    ) -> [String: String] {
        var bounded = sanitizedNativeAutoEnvironment(environment)
        let value = "\(workerCount)"
        bounded["OMP_NUM_THREADS"] = value
        bounded["OPENBLAS_NUM_THREADS"] = value
        bounded["MKL_NUM_THREADS"] = value
        return bounded
    }

    private static func sanitizedNativeAutoEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.filter { !inheritedThreadEnvironmentKeys.contains($0.key) }
    }

    private func recordWorkerExecution(
        command: ColmapWorkerCommandIdentity,
        threadPolicy: GeometryWorkerThreadPolicy,
        argvWorkerCount: Int?,
        result: SubprocessResult
    ) throws {
        guard let observer = observerLock.withLock({ workerExecutionObserver }) else {
            return
        }
        guard let receipt = result.environmentReceipt,
              receipt.removedKeys == Self.inheritedThreadEnvironmentKeys else {
            throw ColmapRunnerError.executionEvidenceUnavailable(command.rawValue)
        }
        let threadKeys = Self.inheritedThreadEnvironmentKeys
        let explicitThreadEnvironment = receipt.explicitOverrides.filter {
            threadKeys.contains($0.key)
        }
        let effectiveThreadEnvironment = receipt.effectiveValuesForControlledKeys.filter {
            threadKeys.contains($0.key)
        }
        try observer(ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: nil,
            threadPolicy: threadPolicy,
            argvWorkerCount: argvWorkerCount,
            explicitThreadEnvironment: explicitThreadEnvironment,
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: effectiveThreadEnvironment,
            exitStatus: result.exitCode,
            succeeded: result.exitCode == 0 && result.terminationReason == .exit
        ))
    }

    private func workerTerminationHandler(
        command: ColmapWorkerCommandIdentity,
        threadPolicy: GeometryWorkerThreadPolicy,
        argvWorkerCount: Int?
    ) -> @Sendable (SubprocessResult) throws -> Void {
        { [self] result in
            try recordWorkerExecution(
                command: command,
                threadPolicy: threadPolicy,
                argvWorkerCount: argvWorkerCount,
                result: result
            )
        }
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
            "--FeatureExtraction.max_image_size", "\(maxImageSize)",
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
            environment: Self.boundedWorkerEnvironment(
                options.environment,
                workerCount: options.extractThreads
            ),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .featureExtractor,
                threadPolicy: .bounded,
                argvWorkerCount: options.extractThreads
            ),
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
            environment: Self.boundedWorkerEnvironment(
                options.environment,
                workerCount: options.extractThreads
            ),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .featureImporter,
                threadPolicy: .bounded,
                argvWorkerCount: options.extractThreads
            ),
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
            environment: Self.boundedWorkerEnvironment(
                options.environment,
                workerCount: options.matchThreads
            ),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .matchesImporter,
                threadPolicy: .bounded,
                argvWorkerCount: options.matchThreads
            ),
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
            environment: Self.boundedWorkerEnvironment(
                environment,
                workerCount: options.threadCount
            ),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .localVocabularyRetriever,
                threadPolicy: .bounded,
                argvWorkerCount: options.threadCount
            ),
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
        environment: [String: String],
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
            "--Mapper.ba_local_max_num_iterations", "\(mapperOptions.localMaxNumIterations)",
            "--Mapper.ba_local_function_tolerance", "\(mapperOptions.localFunctionTolerance)",
            "--Mapper.ba_global_function_tolerance", "\(mapperOptions.globalFunctionTolerance)",
            "--Mapper.ba_local_num_images", "\(mapperOptions.localImageCount)",
            "--Mapper.random_seed", "\(mapperOptions.randomSeed)",
            "--Mapper.min_num_matches", "\(ColmapMappingPolicy.minimumPairInlierCount)",
            "--Mapper.ba_refine_focal_length", mapperOptions.refineFocalLength ? "1" : "0",
        ]
        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .mapper,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "mapper")
    }

    public func runPointTriangulator(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        inputPath: URL,
        outputPath: URL,
        environment: [String: String],
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
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .pointTriangulator,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "point_triangulator")
    }

    public func runBundleAdjuster(
        colmapPath: URL,
        inputPath: URL,
        outputPath: URL,
        environment: [String: String],
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

        let args = [
            "bundle_adjuster",
            "--input_path", inputPath.path,
            "--output_path", outputPath.path,
            "--BundleAdjustment.refine_focal_length", bundleOptions.refineFocalLength ? "1" : "0",
            "--BundleAdjustment.refine_principal_point", bundleOptions.refinePrincipalPoint ? "1" : "0",
            "--BundleAdjustment.refine_extra_params", bundleOptions.refineExtraParams ? "1" : "0",
            "--BundleAdjustmentCeres.max_num_iterations", "\(max(1, bundleOptions.maxNumIterations))"
        ]

        onLog("EasySplat: colmap argv: \(colmapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .bundleAdjuster,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil
            ),
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        try checkResult(result, command: "bundle_adjuster")
    }

    public func runModelAnalyzer(
        colmapPath: URL,
        modelPath: URL,
        environment: [String: String]
    ) async throws -> String {
        let args = ["model_analyzer", "--path", modelPath.path]
        let result = try await runner.runAsync(
            colmapPath.path,
            args,
            currentDirectory: nil,
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onTermination: workerTerminationHandler(
                command: .modelAnalyzer,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil
            ),
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
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
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
        recordGeometryWorkerExecution: Bool = false,
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
            environment: Self.sanitizedNativeAutoEnvironment(environment),
            removingEnvironmentKeys: Self.inheritedThreadEnvironmentKeys,
            onStdout: { onLog($0, false) },
            onStderr: { onLog($0, true) }
        )
        if recordGeometryWorkerExecution {
            try recordWorkerExecution(
                command: .modelConverter,
                threadPolicy: .nativeAuto,
                argvWorkerCount: nil,
                result: result
            )
        }
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

    private func tailLines(_ text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
