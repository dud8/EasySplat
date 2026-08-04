import Foundation

public enum MsplatStopReason: String, Sendable, Equatable {
    case iterationLimit = "iteration_limit"
    case plateau
}

public enum MsplatResumeRejectionReason: String, CaseIterable, Sendable, Equatable {
    case trainerChanged = "trainer_changed"
    case inputChanged = "input_changed"
    case geometryChanged = "geometry_changed"
    case runContractChanged = "run_contract_changed"
}

public struct MsplatResumeRejected: Error, LocalizedError, Sendable, Equatable {
    public let reason: MsplatResumeRejectionReason

    public init(reason: MsplatResumeRejectionReason) {
        self.reason = reason
    }

    public var errorDescription: String? {
        "The saved training checkpoint no longer matches this training run."
    }
}

public struct MsplatTrainingProgress: Sendable, Equatable {
    public let iteration: Int
    public let iterationLimit: Int
    public let gaussianCount: Int
    public let elapsedSeconds: Double
    public let iterationsPerSecond: Double
    public let etaSeconds: Double
    public let loss: Double?
    public let lossIteration: Int?
}

/// A published training preview. The preview is a display cache, never an artifact:
/// nothing durable is derived from it, and losing one costs a redraw.
public struct MsplatPreviewReceipt: Sendable, Equatable {
    public let iteration: Int
    public let publication: Int
    public let previewGaussianCount: Int
    public let sourceGaussianCount: Int
    public let bytes: Int64
    public let sha256: String
    /// Extent of the published gaussians, in published coordinates. The viewer
    /// rejects a scene that cannot name its own bounds, so this travels with the
    /// preview rather than being recomputed from the file.
    public let sceneBounds: SplatSceneBounds

    public init(
        iteration: Int,
        publication: Int,
        previewGaussianCount: Int,
        sourceGaussianCount: Int,
        bytes: Int64,
        sha256: String,
        sceneBounds: SplatSceneBounds
    ) {
        self.iteration = iteration
        self.publication = publication
        self.previewGaussianCount = previewGaussianCount
        self.sourceGaussianCount = sourceGaussianCount
        self.bytes = bytes
        self.sha256 = sha256
        self.sceneBounds = sceneBounds
    }
}

public struct MsplatRasterFallback: Sendable, Equatable {
    public let iteration: Int
    public let fallbackCount: Int
    public let intersectionCount: Int64
    public let allocationBytes: Int64

    public init(
        iteration: Int,
        fallbackCount: Int,
        intersectionCount: Int64,
        allocationBytes: Int64
    ) {
        self.iteration = iteration
        self.fallbackCount = fallbackCount
        self.intersectionCount = intersectionCount
        self.allocationBytes = allocationBytes
    }
}

public struct MsplatRasterMemoryBudgetExceeded: Error, LocalizedError, Sendable, Equatable {
    public let iteration: Int
    public let requiredBytes: Int64
    public let budgetBytes: Int64
    public let intersectionCount: Int64?

    public init(
        iteration: Int,
        requiredBytes: Int64,
        budgetBytes: Int64,
        intersectionCount: Int64? = nil
    ) {
        self.iteration = iteration
        self.requiredBytes = requiredBytes
        self.budgetBytes = budgetBytes
        self.intersectionCount = intersectionCount
    }

    public var errorDescription: String? {
        "Training needed more unified memory than this run allowed."
    }
}

public struct MsplatRasterResourceLimitExceeded: Error, LocalizedError, Sendable, Equatable {
    public let iteration: Int
    public let requiredBytes: Int64
    public let maximumBufferBytes: Int64
    public let intersectionCount: Int64?

    public init(
        iteration: Int,
        requiredBytes: Int64,
        maximumBufferBytes: Int64,
        intersectionCount: Int64? = nil
    ) {
        self.iteration = iteration
        self.requiredBytes = requiredBytes
        self.maximumBufferBytes = maximumBufferBytes
        self.intersectionCount = intersectionCount
    }

    public var errorDescription: String? {
        "This scene exceeded Metal's maximum size for one training buffer."
    }
}

public struct MsplatMetalAllocationUnavailable: Error, LocalizedError, Sendable, Equatable {
    public let iteration: Int
    public let requestedBytes: Int64
    public let currentAllocatedBytes: Int64
    public let requiredBytes: Int64
    public let budgetBytes: Int64
    public let recommendedWorkingSetBytes: Int64
    public let maximumBufferBytes: Int64
    public let intersectionCount: Int64?

    public init(
        iteration: Int,
        requestedBytes: Int64,
        currentAllocatedBytes: Int64,
        requiredBytes: Int64,
        budgetBytes: Int64,
        recommendedWorkingSetBytes: Int64,
        maximumBufferBytes: Int64,
        intersectionCount: Int64? = nil
    ) {
        self.iteration = iteration
        self.requestedBytes = requestedBytes
        self.currentAllocatedBytes = currentAllocatedBytes
        self.requiredBytes = requiredBytes
        self.budgetBytes = budgetBytes
        self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
        self.maximumBufferBytes = maximumBufferBytes
        self.intersectionCount = intersectionCount
    }

    public var errorDescription: String? {
        "Training could not reserve unified memory. Close other demanding apps, then try again."
    }
}

public struct MsplatTrainingResult: Sendable, Equatable {
    public let profile: DetailProfile
    public let iterationLimit: Int
    public let plateauWindow: Int
    public let completedIteration: Int
    public let stopReason: MsplatStopReason
    public let gaussianCount: Int
    public let elapsedSeconds: Double
    public let peakMemoryBytes: Int64
    public let memoryBudgetBytes: Int64
    public let rasterFallbackCount: Int
    public let rasterExactFallbackElapsedSeconds: Double
    public let rasterExactBufferGrowthCount: Int
    public let rasterExactBufferBytesAdded: Int64
    public let rasterReplayElapsedSeconds: Double
    public let rasterPeakExactIntersectionCapacity: Int64
    public let droppedIntersectionCount: Int
    public let sceneBounds: SplatSceneBounds
    public let outputBytes: Int64
    public let inputDigest: String
    public let geometryDigest: String
    public let trainerBuildDigest: String
    public let latestCheckpoint: MsplatCheckpointReceipt?
}

public final class MsplatRunner: Sendable {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func runTrain(
        msplatPath: URL,
        metallibPath: URL,
        datasetPath: URL,
        outputPath: URL,
        expectedIdentity: MsplatDatasetIdentity,
        checkpointPath requestedCheckpointPath: URL? = nil,
        resumeFrom: URL? = nil,
        profile: DetailProfile,
        seed: UInt64,
        iterationLimit: Int? = nil,
        plateauWindow: Int? = nil,
        memoryBudgetBytes: Int64,
        previewPath: URL? = nil,
        previewIntervalSeconds: Int? = nil,
        onProgress: @escaping @Sendable (MsplatTrainingProgress) -> Void = { _ in },
        onCheckpoint: @escaping @Sendable (MsplatCheckpointReceipt) -> Void = { _ in },
        onRasterFallback: @escaping @Sendable (MsplatRasterFallback) -> Void = { _ in },
        onPreview: @escaping @Sendable (MsplatPreviewReceipt) -> Void = { _ in },
        onPreviewDisabled: @escaping @Sendable (String) -> Void = { _ in },
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> MsplatTrainingResult {
        let fileManager = FileManager.default
        guard memoryBudgetBytes > 0 else {
            throw MsplatEventProtocolError("training memory budget must be positive")
        }
        let checkpointPath = requestedCheckpointPath
            ?? outputPath.deletingLastPathComponent().appendingPathComponent("checkpoint")
        let stagingOutputPath = outputPath.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputPath.lastPathComponent).\(UUID().uuidString).training.tmp.ply"
            )
        guard fileManager.isExecutableFile(atPath: msplatPath.path) else {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "easysplat-train is not executable: \(msplatPath.path)"
            )
        }
        guard fileManager.fileExists(atPath: datasetPath.path) else {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "Dataset path does not exist: \(datasetPath.path)"
            )
        }

        try fileManager.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: checkpointPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: stagingOutputPath.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: stagingOutputPath.path)) != nil {
            try fileManager.removeItem(at: stagingOutputPath)
        }
        defer {
            if fileManager.fileExists(atPath: stagingOutputPath.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: stagingOutputPath.path)) != nil {
                try? fileManager.removeItem(at: stagingOutputPath)
            }
        }
        if let resumeFrom {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resumeFrom.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MsplatEventProtocolError("requested resume checkpoint does not exist")
            }
        }

        let contract = try MsplatProfileContract(
            profile: profile,
            iterationLimit: iterationLimit,
            plateauWindow: plateauWindow
        )
        var arguments = [
            "--dataset", datasetPath.path,
            "--output", stagingOutputPath.path,
            "--profile", contract.argument,
            "--iteration-limit", String(contract.iterationLimit),
            "--plateau-window", String(contract.plateauWindow),
            "--checkpoint", checkpointPath.path,
            "--seed", String(seed),
            "--expected-input-digest", expectedIdentity.inputDigest,
            "--expected-geometry-digest", expectedIdentity.geometryDigest,
            "--memory-budget-bytes", String(memoryBudgetBytes),
            "--events-fd", "1",
            "--metallib", metallibPath.path,
        ]
        if let resumeFrom {
            arguments.append(contentsOf: ["--resume", resumeFrom.path])
        }
        if let previewPath {
            // The trainer only ever sees the staging output, so its own collision
            // check cannot see the durable one. Catch the alias here or a preview
            // publication could replace a finished splat from an earlier run.
            let previewStandard = previewPath.standardizedFileURL.resolvingSymlinksInPath()
            if previewStandard
                == outputPath.standardizedFileURL.resolvingSymlinksInPath() {
                throw MsplatEventProtocolError("preview path collides with the final output")
            }
            // Containment, not equality: a preview written to dataset/sparse/0/x.ply
            // would be renamed over retained input the run is required to preserve.
            for (tree, name) in [
                (checkpointPath, "the checkpoint directory"),
                (datasetPath, "the dataset"),
            ] {
                let root = tree.standardizedFileURL.resolvingSymlinksInPath()
                if previewStandard == root
                    || previewStandard.pathComponents.starts(with: root.pathComponents) {
                    throw MsplatEventProtocolError("preview path collides with \(name)")
                }
            }
            try fileManager.createDirectory(
                at: previewPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            arguments.append(contentsOf: ["--preview-output", previewPath.path])
            if let previewIntervalSeconds {
                arguments.append(contentsOf: [
                    "--preview-interval-seconds", String(previewIntervalSeconds),
                ])
            }
        } else if previewIntervalSeconds != nil {
            throw MsplatEventProtocolError("preview interval requires a preview path")
        }
        let events = MsplatEventStream(
            contract: contract,
            seed: seed,
            memoryBudgetBytes: memoryBudgetBytes,
            expectedIdentity: expectedIdentity,
            checkpointURL: checkpointPath,
            resumeRequested: resumeFrom != nil,
            onProgress: onProgress,
            onCheckpoint: onCheckpoint,
            onRasterFallback: onRasterFallback,
            onPreview: onPreview,
            onPreviewDisabled: onPreviewDisabled
        )

        onLog("EasySplat: running native splat training", false)
        let result: SubprocessResult
        do {
            result = try await runner.runAsync(
                msplatPath.path,
                arguments,
                currentDirectory: datasetPath.deletingLastPathComponent(),
                environment: [:],
                onStdout: { line in
                    events.consume(line)
                    onLog(line, false)
                },
                onStderr: { onLog($0, true) }
            )
        } catch is CancellationError {
            if let interruption = try events.finishInterruption() {
                throw interruption
            }
            throw CancellationError()
        } catch {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "Failed to launch easysplat-train: \(error)"
            )
        }

        if events.consumedLineCount == 0 {
            for line in result.stdout.split(whereSeparator: \.isNewline) {
                events.consume(String(line))
            }
        }
        if let rejection = try events.finishResumeRejection() {
            guard result.exitCode == 78, result.terminationReason == .exit else {
                throw MsplatEventProtocolError(
                    "resume_rejected must terminate with configuration status 78"
                )
            }
            throw rejection
        }
        if let memoryFailure = try events.finishMemoryBudgetFailure() {
            guard result.exitCode == 75, result.terminationReason == .exit else {
                throw MsplatEventProtocolError(
                    "raster_memory_budget_exceeded must terminate with temporary-failure status 75"
                )
            }
            throw memoryFailure
        }
        if let resourceFailure = try events.finishResourceLimitFailure() {
            guard result.exitCode == 75, result.terminationReason == .exit else {
                throw MsplatEventProtocolError(
                    "raster_resource_limit_exceeded must terminate with temporary-failure status 75"
                )
            }
            throw resourceFailure
        }
        if let allocationFailure = try events.finishMetalAllocationFailure() {
            guard result.exitCode == 71, result.terminationReason == .exit else {
                throw MsplatEventProtocolError(
                    "metal_allocation_unavailable must terminate with operating-system status 71"
                )
            }
            throw allocationFailure
        }
        guard result.exitCode == 0 else {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: result.exitCode,
                terminationReason: result.terminationReason,
                stdoutTail: TextTails.tailLines(result.stdout, limit: 40),
                stderrTail: TextTails.tailLines(result.stderr, limit: 40)
            )
        }

        let completion = try events.finish()
        guard let stagedValuesBeforeValidation = try? stagingOutputPath.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            throw MsplatEventProtocolError("event stream completed without a published output")
        }
        guard stagedValuesBeforeValidation.isRegularFile == true,
              stagedValuesBeforeValidation.isSymbolicLink != true else {
            throw MsplatEventProtocolError("published output is not a regular file")
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: stagingOutputPath.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw MsplatEventProtocolError("event stream completed without a published output")
        }
        guard size.int64Value == completion.outputBytes else {
            throw MsplatEventProtocolError(
                "event output size \(completion.outputBytes) does not match file size \(size.int64Value)"
            )
        }
        switch ProjectArtifactValidator.validatePlyFile(at: stagingOutputPath) {
        case .valid:
            break
        case .missing:
            throw MsplatEventProtocolError("event stream completed without a published output")
        case .corrupt(let reason):
            throw MsplatEventProtocolError("published output is invalid: \(reason)")
        }
        guard let header = ProjectArtifactValidator.readPlyHeader(at: stagingOutputPath) else {
            throw MsplatEventProtocolError("published output has an invalid PLY header")
        }
        guard header.vertexCount == completion.gaussianCount else {
            throw MsplatEventProtocolError(
                "published output does not match the completed Gaussian count"
            )
        }
        let stagedValuesBeforeReplacement = try stagingOutputPath.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard stagedValuesBeforeReplacement.isRegularFile == true,
              stagedValuesBeforeReplacement.isSymbolicLink != true else {
            throw MsplatEventProtocolError("published output is not a regular file")
        }
        let outputAlreadyExists = fileManager.fileExists(atPath: outputPath.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: outputPath.path)) != nil
        if outputAlreadyExists {
            guard let existingValues = try? outputPath.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else {
                throw MsplatEventProtocolError("existing output is not a regular file")
            }
            guard existingValues.isRegularFile == true, existingValues.isSymbolicLink != true else {
                throw MsplatEventProtocolError("existing output is not a regular file")
            }
            _ = try fileManager.replaceItemAt(
                outputPath,
                withItemAt: stagingOutputPath,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingOutputPath, to: outputPath)
        }
        return completion
    }
}

private struct MsplatProfileContract: Sendable {
    let profile: DetailProfile
    let argument: String
    let iterationLimit: Int
    let plateauWindow: Int

    init(
        profile: DetailProfile,
        iterationLimit requestedIterationLimit: Int? = nil,
        plateauWindow requestedPlateauWindow: Int? = nil
    ) throws {
        self.profile = profile
        let defaults: (argument: String, iterationLimit: Int, plateauWindow: Int)
        switch profile {
        case .fast:
            defaults = ("fast", 3_000, 400)
        case .balanced:
            defaults = ("balanced", 7_000, 800)
        case .highDetail:
            defaults = ("high-detail", 15_000, 1_500)
        }
        argument = defaults.argument
        iterationLimit = requestedIterationLimit ?? defaults.iterationLimit
        plateauWindow = requestedPlateauWindow ?? defaults.plateauWindow
        guard iterationLimit > 0,
              plateauWindow > 0,
              plateauWindow <= iterationLimit else {
            throw MsplatEventProtocolError("training budget is invalid")
        }
    }
}

private struct MsplatNativeEvent: Decodable {
    let event: String
    let schemaVersion: Int
    let sequence: UInt64
    let version: String?
    let trainerBuildDigest: String?
    let inputDigest: String?
    let geometryDigest: String?
    let profile: String?
    let seed: UInt64?
    let iteration: Int?
    let iterationLimit: Int?
    let plateauWindow: Int?
    let cameraCount: Int?
    let initialGaussianCount: Int?
    let gaussianCount: Int?
    let peakMemoryBytes: Int64?
    let memoryBudgetBytes: Int64?
    let elapsedSeconds: Double?
    let iterationsPerSecond: Double?
    let etaSeconds: Double?
    let loss: Double?
    let lossIteration: Int?
    let lastImprovementIteration: Int?
    let outputBytes: Int64?
    let stopReason: String?
    let reason: String?
    let resumed: Bool?
    let checkpointSchema: Int?
    let payloadSchema: Int?
    let checkpointGeneration: String?
    let checkpointPayloadSHA256: String?
    let checkpointPayloadBytes: Int64?
    let checkpointIteration: Int?
    let signal: Int?
    let cameraIndex: Int?
    let firstOverflowIteration: Int?
    let fallbackCount: Int?
    let rasterFallbackCount: Int?
    let rasterExactFallbackElapsedSeconds: Double?
    let rasterExactBufferGrowthCount: Int?
    let rasterExactBufferBytesAdded: Int64?
    let rasterReplayElapsedSeconds: Double?
    let rasterPeakExactIntersectionCapacity: Int64?
    let droppedIntersectionCount: Int?
    let intersectionCount: Int64?
    let allocationBytes: Int64?
    let currentAllocatedBytes: Int64?
    let requestedBytes: Int64?
    let requiredBytes: Int64?
    let budgetBytes: Int64?
    let maximumBufferBytes: Int64?
    let recommendedWorkingSetBytes: Int64?
    let sceneCenter: [Double]?
    let sceneRadius: Double?
    let previewSchema: Int?
    let previewPublication: Int?
    let previewGaussianCount: Int?
    let sourceGaussianCount: Int?
    let previewBytes: Int64?
    let previewSHA256: String?

    enum CodingKeys: String, CodingKey {
        case event
        case schemaVersion = "schema_version"
        case sequence
        case version
        case trainerBuildDigest = "trainer_build_digest"
        case inputDigest = "input_digest"
        case geometryDigest = "geometry_digest"
        case profile
        case seed
        case iteration
        case iterationLimit = "iteration_limit"
        case plateauWindow = "plateau_window"
        case cameraCount = "camera_count"
        case initialGaussianCount = "initial_gaussian_count"
        case gaussianCount = "gaussian_count"
        case peakMemoryBytes = "peak_memory_bytes"
        case memoryBudgetBytes = "memory_budget_bytes"
        case elapsedSeconds = "elapsed_seconds"
        case iterationsPerSecond = "iterations_per_second"
        case etaSeconds = "eta_seconds"
        case loss
        case lossIteration = "loss_iteration"
        case lastImprovementIteration = "last_improvement_iteration"
        case outputBytes = "output_bytes"
        case stopReason = "stop_reason"
        case reason
        case resumed
        case checkpointSchema = "checkpoint_schema"
        case payloadSchema = "payload_schema"
        case checkpointGeneration = "checkpoint_generation"
        case checkpointPayloadSHA256 = "checkpoint_payload_sha256"
        case checkpointPayloadBytes = "checkpoint_payload_bytes"
        case checkpointIteration = "checkpoint_iteration"
        case signal
        case cameraIndex = "camera_index"
        case firstOverflowIteration = "first_overflow_iteration"
        case fallbackCount = "fallback_count"
        case rasterFallbackCount = "raster_fallback_count"
        case rasterExactFallbackElapsedSeconds = "raster_exact_fallback_elapsed_seconds"
        case rasterExactBufferGrowthCount = "raster_exact_buffer_growth_count"
        case rasterExactBufferBytesAdded = "raster_exact_buffer_bytes_added"
        case rasterReplayElapsedSeconds = "raster_replay_elapsed_seconds"
        case rasterPeakExactIntersectionCapacity = "raster_peak_exact_intersection_capacity"
        case droppedIntersectionCount = "dropped_intersection_count"
        case intersectionCount = "intersection_count"
        case allocationBytes = "allocation_bytes"
        case currentAllocatedBytes = "current_allocated_bytes"
        case requestedBytes = "requested_bytes"
        case requiredBytes = "required_bytes"
        case budgetBytes = "budget_bytes"
        case maximumBufferBytes = "max_buffer_bytes"
        case recommendedWorkingSetBytes = "recommended_working_set_bytes"
        case sceneCenter = "scene_center"
        case sceneRadius = "scene_radius"
        case previewSchema = "preview_schema"
        case previewPublication = "preview_publication"
        case previewGaussianCount = "preview_gaussian_count"
        case sourceGaussianCount = "source_gaussian_count"
        case previewBytes = "preview_bytes"
        case previewSHA256 = "preview_sha256"
    }

    private enum Field: String, Hashable {
        case event
        case schemaVersion = "schema_version"
        case sequence
        case version
        case trainerBuildDigest = "trainer_build_digest"
        case inputDigest = "input_digest"
        case geometryDigest = "geometry_digest"
        case profile
        case seed
        case iteration
        case iterationLimit = "iteration_limit"
        case plateauWindow = "plateau_window"
        case cameraCount = "camera_count"
        case initialGaussianCount = "initial_gaussian_count"
        case gaussianCount = "gaussian_count"
        case peakMemoryBytes = "peak_memory_bytes"
        case memoryBudgetBytes = "memory_budget_bytes"
        case elapsedSeconds = "elapsed_seconds"
        case iterationsPerSecond = "iterations_per_second"
        case etaSeconds = "eta_seconds"
        case loss
        case lossIteration = "loss_iteration"
        case outputBytes = "output_bytes"
        case stopReason = "stop_reason"
        case reason
        case resumed
        case checkpointSchema = "checkpoint_schema"
        case payloadSchema = "payload_schema"
        case checkpointGeneration = "checkpoint_generation"
        case checkpointPayloadSHA256 = "checkpoint_payload_sha256"
        case checkpointPayloadBytes = "checkpoint_payload_bytes"
        case checkpointIteration = "checkpoint_iteration"
        case signal
        case cameraIndex = "camera_index"
        case firstOverflowIteration = "first_overflow_iteration"
        case fallbackCount = "fallback_count"
        case rasterFallbackCount = "raster_fallback_count"
        case rasterExactFallbackElapsedSeconds = "raster_exact_fallback_elapsed_seconds"
        case rasterExactBufferGrowthCount = "raster_exact_buffer_growth_count"
        case rasterExactBufferBytesAdded = "raster_exact_buffer_bytes_added"
        case rasterReplayElapsedSeconds = "raster_replay_elapsed_seconds"
        case rasterPeakExactIntersectionCapacity = "raster_peak_exact_intersection_capacity"
        case droppedIntersectionCount = "dropped_intersection_count"
        case intersectionCount = "intersection_count"
        case allocationBytes = "allocation_bytes"
        case currentAllocatedBytes = "current_allocated_bytes"
        case requestedBytes = "requested_bytes"
        case requiredBytes = "required_bytes"
        case budgetBytes = "budget_bytes"
        case maximumBufferBytes = "max_buffer_bytes"
        case recommendedWorkingSetBytes = "recommended_working_set_bytes"
        case sceneCenter = "scene_center"
        case sceneRadius = "scene_radius"
        case lastImprovementIteration = "last_improvement_iteration"
        case previewSchema = "preview_schema"
        case previewPublication = "preview_publication"
        case previewGaussianCount = "preview_gaussian_count"
        case sourceGaussianCount = "source_gaussian_count"
        case previewBytes = "preview_bytes"
        case previewSHA256 = "preview_sha256"
    }

    private static let envelopeFields: Set<Field> = [
        .event, .schemaVersion, .sequence,
    ]
    private static let resumeRejectedFields: Set<Field> = [
        .reason,
    ]
    private static let startedFields: Set<Field> = [
        .cameraCount, .checkpointSchema, .droppedIntersectionCount, .geometryDigest,
        .initialGaussianCount, .inputDigest, .iteration, .iterationLimit,
        .memoryBudgetBytes, .payloadSchema, .plateauWindow, .profile,
        .rasterExactBufferBytesAdded, .rasterExactBufferGrowthCount,
        .rasterExactFallbackElapsedSeconds, .rasterFallbackCount,
        .rasterPeakExactIntersectionCapacity, .rasterReplayElapsedSeconds,
        .resumed, .seed, .trainerBuildDigest, .version,
    ]
    private static let checkpointFields: Set<Field> = [
        .checkpointGeneration, .checkpointPayloadBytes, .checkpointPayloadSHA256,
        .droppedIntersectionCount, .gaussianCount, .geometryDigest, .inputDigest,
        .iteration, .memoryBudgetBytes, .peakMemoryBytes, .profile,
        .rasterExactBufferBytesAdded, .rasterExactBufferGrowthCount,
        .rasterExactFallbackElapsedSeconds, .rasterFallbackCount,
        .rasterPeakExactIntersectionCapacity, .rasterReplayElapsedSeconds,
        .seed, .trainerBuildDigest, .version,
    ]
    private static let progressFields: Set<Field> = [
        .elapsedSeconds, .etaSeconds, .gaussianCount, .iteration, .iterationLimit,
        .iterationsPerSecond, .loss, .lossIteration,
    ]
    private static let previewPublishedFields: Set<Field> = [
        .iteration, .previewBytes, .previewGaussianCount, .previewPublication,
        .previewSchema, .previewSHA256, .sceneCenter, .sceneRadius,
        .sourceGaussianCount,
    ]
    private static let previewDisabledFields: Set<Field> = [
        .iteration, .reason,
    ]
    private static let earlyStopFields: Set<Field> = [
        .iteration, .lastImprovementIteration, .loss, .lossIteration, .plateauWindow,
        .reason,
    ]
    private static let rasterReplayFields: Set<Field> = [
        .budgetBytes, .cameraIndex, .firstOverflowIteration, .intersectionCount,
        .iteration, .requiredBytes,
    ]
    private static let rasterFallbackFields: Set<Field> = [
        .allocationBytes, .fallbackCount, .intersectionCount, .iteration,
        .rasterExactBufferBytesAdded, .rasterExactBufferGrowthCount,
        .rasterExactFallbackElapsedSeconds, .rasterPeakExactIntersectionCapacity,
        .rasterReplayElapsedSeconds,
    ]
    private static let rasterMemoryBudgetExceededFields: Set<Field> = [
        .allocationBytes, .budgetBytes, .intersectionCount, .iteration, .requiredBytes,
    ]
    private static let rasterResourceLimitExceededFields: Set<Field> = [
        .allocationBytes, .intersectionCount, .iteration, .maximumBufferBytes,
        .requiredBytes,
    ]
    private static let metalAllocationUnavailableFields: Set<Field> = [
        .budgetBytes, .currentAllocatedBytes, .intersectionCount, .iteration,
        .maximumBufferBytes, .recommendedWorkingSetBytes, .requestedBytes, .requiredBytes,
    ]
    private static let cancellationRequestedFields: Set<Field> = [
        .iteration, .signal,
    ]
    private static let cancelledFields: Set<Field> = [
        .checkpointGeneration, .checkpointIteration, .checkpointPayloadSHA256,
        .droppedIntersectionCount, .geometryDigest, .inputDigest, .iteration,
        .memoryBudgetBytes, .rasterExactBufferBytesAdded, .rasterExactBufferGrowthCount,
        .rasterExactFallbackElapsedSeconds, .rasterFallbackCount,
        .rasterPeakExactIntersectionCapacity, .rasterReplayElapsedSeconds,
    ]
    private static let completedFields: Set<Field> = [
        .droppedIntersectionCount, .elapsedSeconds, .gaussianCount, .geometryDigest,
        .inputDigest, .iteration, .iterationLimit, .memoryBudgetBytes, .outputBytes,
        .peakMemoryBytes, .plateauWindow, .profile, .rasterExactBufferBytesAdded,
        .rasterExactBufferGrowthCount, .rasterExactFallbackElapsedSeconds,
        .rasterFallbackCount, .rasterPeakExactIntersectionCapacity,
        .rasterReplayElapsedSeconds,
        .sceneCenter, .sceneRadius, .seed, .stopReason, .trainerBuildDigest, .version,
    ]

    static func decodeClosedSchema(from data: Data) throws -> Self {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any],
              let eventName = object[Field.event.rawValue] as? String else {
            throw MsplatEventProtocolError("event record must be a JSON object with an event type")
        }
        let unknownFields = object.keys.filter { Field(rawValue: $0) == nil }.sorted()
        guard unknownFields.isEmpty else {
            throw MsplatEventProtocolError(
                "event \(eventName) contains unknown fields: \(unknownFields.joined(separator: ", "))"
            )
        }

        let eventFields: Set<Field>
        switch eventName {
        case "resume_rejected":
            eventFields = resumeRejectedFields
        case "started":
            eventFields = startedFields
        case "checkpoint_loaded", "checkpoint_completed":
            eventFields = checkpointFields
        case "progress":
            eventFields = progressFields
        case "preview_published":
            eventFields = previewPublishedFields
        case "preview_disabled":
            eventFields = previewDisabledFields
        case "early_stop":
            eventFields = earlyStopFields
        case "raster_replay":
            eventFields = rasterReplayFields
        case "raster_fallback":
            eventFields = rasterFallbackFields
        case "raster_memory_budget_exceeded":
            eventFields = rasterMemoryBudgetExceededFields
        case "raster_resource_limit_exceeded":
            eventFields = rasterResourceLimitExceededFields
        case "metal_allocation_unavailable":
            eventFields = metalAllocationUnavailableFields
        case "cancellation_requested":
            eventFields = cancellationRequestedFields
        case "cancelled":
            eventFields = cancelledFields
        case "completed":
            eventFields = completedFields
        default:
            throw MsplatEventProtocolError("event type \(eventName) is not valid during training")
        }

        let presentFields = Set(object.keys.compactMap(Field.init(rawValue:)))
        let misplacedFields = presentFields
            .subtracting(envelopeFields.union(eventFields))
            .map(\.rawValue)
            .sorted()
        guard misplacedFields.isEmpty else {
            throw MsplatEventProtocolError(
                "event \(eventName) contains fields from another event: "
                    + misplacedFields.joined(separator: ", ")
            )
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

private final class MsplatEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private let contract: MsplatProfileContract
    private let seed: UInt64
    private let memoryBudgetBytes: Int64
    private let expectedIdentity: MsplatDatasetIdentity
    private let checkpointURL: URL
    private let resumeRequested: Bool
    private let onProgress: @Sendable (MsplatTrainingProgress) -> Void
    private let onCheckpoint: @Sendable (MsplatCheckpointReceipt) -> Void
    private let onRasterFallback: @Sendable (MsplatRasterFallback) -> Void
    private let onPreview: @Sendable (MsplatPreviewReceipt) -> Void
    private let onPreviewDisabled: @Sendable (String) -> Void
    private var nextSequence: UInt64 = 1
    private var started = false
    private var completed = false
    private var cancelled = false
    private var cancellationIteration: Int?
    private var startIteration = 0
    private var lastIteration = 0
    private var earlyStopIteration: Int?
    private var cameraCount = 0
    private var inputDigest = ""
    private var geometryDigest = ""
    private var trainerBuildDigest = ""
    private var lastPeakMemoryBytes: Int64 = 0
    private var latestCheckpoint: MsplatCheckpointReceipt?
    private var lineCount = 0
    private var failure: Error?
    private var result: MsplatTrainingResult?
    private var resumeRejection: MsplatResumeRejected?
    private var memoryBudgetFailure: MsplatRasterMemoryBudgetExceeded?
    private var resourceLimitFailure: MsplatRasterResourceLimitExceeded?
    private var metalAllocationFailure: MsplatMetalAllocationUnavailable?
    private var rasterFallbackCount = 0
    private var rasterExactFallbackElapsedSeconds = 0.0
    private var rasterExactBufferGrowthCount = 0
    private var rasterExactBufferBytesAdded: Int64 = 0
    private var rasterReplayElapsedSeconds = 0.0
    private var rasterPeakExactIntersectionCapacity: Int64 = 0
    private var lastPreviewPublication = 0

    init(
        contract: MsplatProfileContract,
        seed: UInt64,
        memoryBudgetBytes: Int64,
        expectedIdentity: MsplatDatasetIdentity,
        checkpointURL: URL,
        resumeRequested: Bool,
        onProgress: @escaping @Sendable (MsplatTrainingProgress) -> Void,
        onCheckpoint: @escaping @Sendable (MsplatCheckpointReceipt) -> Void,
        onRasterFallback: @escaping @Sendable (MsplatRasterFallback) -> Void,
        onPreview: @escaping @Sendable (MsplatPreviewReceipt) -> Void,
        onPreviewDisabled: @escaping @Sendable (String) -> Void
    ) {
        self.contract = contract
        self.seed = seed
        self.memoryBudgetBytes = memoryBudgetBytes
        self.expectedIdentity = expectedIdentity
        self.checkpointURL = checkpointURL
        self.resumeRequested = resumeRequested
        self.onProgress = onProgress
        self.onCheckpoint = onCheckpoint
        self.onRasterFallback = onRasterFallback
        self.onPreview = onPreview
        self.onPreviewDisabled = onPreviewDisabled
    }

    var consumedLineCount: Int {
        lock.withLock { lineCount }
    }

    func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock {
            lineCount += 1
            guard failure == nil else { return }
            do {
                let event = try MsplatNativeEvent.decodeClosedSchema(
                    from: Data(trimmed.utf8)
                )
                let effect = try accept(event)
                if let progress = effect?.progress {
                    onProgress(progress)
                }
                if let checkpoint = effect?.checkpoint {
                    onCheckpoint(checkpoint)
                }
                if let rasterFallback = effect?.rasterFallback {
                    onRasterFallback(rasterFallback)
                }
                if let preview = effect?.preview {
                    onPreview(preview)
                }
                if let previewDisabled = effect?.previewDisabled {
                    onPreviewDisabled(previewDisabled)
                }
            } catch {
                failure = error is MsplatEventProtocolError
                    ? error
                    : MsplatEventProtocolError("event record is invalid: \(error.localizedDescription)")
            }
        }
    }

    func finish() throws -> MsplatTrainingResult {
        try lock.withLock {
            if let failure { throw failure }
            guard started else {
                throw MsplatEventProtocolError("event stream is missing started")
            }
            guard completed, let result else {
                throw MsplatEventProtocolError("event stream is missing completed")
            }
            return result
        }
    }

    func finishResumeRejection() throws -> MsplatResumeRejected? {
        try lock.withLock {
            if let failure { throw failure }
            return resumeRejection
        }
    }

    func finishMemoryBudgetFailure() throws -> MsplatRasterMemoryBudgetExceeded? {
        try lock.withLock {
            if let failure { throw failure }
            return memoryBudgetFailure
        }
    }

    func finishResourceLimitFailure() throws -> MsplatRasterResourceLimitExceeded? {
        try lock.withLock {
            if let failure { throw failure }
            return resourceLimitFailure
        }
    }

    func finishMetalAllocationFailure() throws -> MsplatMetalAllocationUnavailable? {
        try lock.withLock {
            if let failure { throw failure }
            return metalAllocationFailure
        }
    }

    func finishInterruption() throws -> MsplatTrainingInterrupted? {
        let evidence: (Int, MsplatCheckpointReceipt, MsplatCheckpointExpectation)? = try lock.withLock {
            if let failure { throw failure }
            guard lineCount > 0 else { return nil }
            if completed || resumeRejection != nil || memoryBudgetFailure != nil
                || resourceLimitFailure != nil || metalAllocationFailure != nil { return nil }
            guard started else {
                throw MsplatEventProtocolError("cancelled event stream is missing started")
            }
            guard cancelled,
                  cancellationIteration != nil,
                  let latestCheckpoint else {
                throw MsplatEventProtocolError("cancelled training has no terminal checkpoint evidence")
            }
            return (
                latestCheckpoint.iteration,
                latestCheckpoint,
                MsplatCheckpointExpectation(
                    trainerVersion: "1.1.3 (git 106499b)",
                    trainerBuildDigest: trainerBuildDigest,
                    profile: contract.argument,
                    iterationLimit: contract.iterationLimit,
                    plateauWindow: contract.plateauWindow,
                    seed: seed,
                    cameraCount: cameraCount,
                    inputDigest: inputDigest,
                    geometryDigest: geometryDigest,
                    memoryBudgetBytes: memoryBudgetBytes
                )
            )
        }
        guard let evidence else { return nil }
        try MsplatCheckpointValidator.validate(
            checkpointURL: checkpointURL,
            receipt: evidence.1,
            expectation: evidence.2
        )
        return MsplatTrainingInterrupted(
            completedIteration: evidence.0,
            checkpoint: evidence.1
        )
    }

    private func accept(_ event: MsplatNativeEvent) throws -> AcceptedEffect? {
        guard event.schemaVersion == 2 else {
            throw MsplatEventProtocolError("event schema must be 2")
        }
        guard event.sequence == nextSequence else {
            throw MsplatEventProtocolError(
                "event sequence \(event.sequence) does not match expected \(nextSequence)"
            )
        }
        nextSequence += 1
        guard !completed, !cancelled, resumeRejection == nil,
              memoryBudgetFailure == nil, resourceLimitFailure == nil,
              metalAllocationFailure == nil else {
            throw MsplatEventProtocolError("event arrived after a terminal event")
        }

        switch event.event {
        case "resume_rejected":
            guard resumeRequested,
                  !started,
                  event.sequence == 1,
                  let rawReason = event.reason,
                  let reason = MsplatResumeRejectionReason(rawValue: rawReason) else {
                throw MsplatEventProtocolError("resume_rejected is invalid or unsolicited")
            }
            resumeRejection = MsplatResumeRejected(reason: reason)
            return nil
        case "started":
            guard !started, event.sequence == 1,
                  event.version == "1.1.3 (git 106499b)",
                  let iteration = event.iteration,
                  iteration >= 0,
                  iteration < contract.iterationLimit,
                  let eventCameraCount = event.cameraCount,
                  eventCameraCount > 0,
                  event.initialGaussianCount.map({ $0 > 0 }) == true,
                  event.resumed == resumeRequested,
                  event.memoryBudgetBytes == memoryBudgetBytes,
                  event.checkpointSchema == 3,
                  event.payloadSchema == 2,
                  let eventInputDigest = event.inputDigest,
                  let eventGeometryDigest = event.geometryDigest,
                  let eventTrainerBuildDigest = event.trainerBuildDigest,
                  isSHA256(eventInputDigest),
                  isSHA256(eventGeometryDigest),
                  isSHA256(eventTrainerBuildDigest),
                  eventInputDigest == expectedIdentity.inputDigest,
                  eventGeometryDigest == expectedIdentity.geometryDigest,
                  let startedRasterFallbackCount = event.rasterFallbackCount,
                  validRasterFallbackCount(startedRasterFallbackCount, through: iteration),
                  resumeRequested || iteration == 0 else {
                throw MsplatEventProtocolError(
                    "event started identity or run contract does not match the prepared dataset"
                )
            }
            try validateContract(event)
            startIteration = iteration
            lastIteration = iteration
            cameraCount = eventCameraCount
            inputDigest = eventInputDigest
            geometryDigest = eventGeometryDigest
            trainerBuildDigest = eventTrainerBuildDigest
            let startedMetrics = try recoveryMetrics(
                from: event,
                fallbackCount: startedRasterFallbackCount
            )
            if !resumeRequested, startedMetrics != RasterRecoveryMetrics(
                fallbackCount: 0,
                exactFallbackElapsedSeconds: 0,
                exactBufferGrowthCount: 0,
                exactBufferBytesAdded: 0,
                replayElapsedSeconds: 0,
                peakExactIntersectionCapacity: 0
            ) {
                throw MsplatEventProtocolError("fresh training started with raster recovery history")
            }
            applyRecoveryMetrics(startedMetrics)
            started = true
            return nil
        case "raster_replay":
            guard started,
                  let successfulPrefix = event.iteration,
                  successfulPrefix >= lastIteration,
                  successfulPrefix < contract.iterationLimit,
                  event.firstOverflowIteration == successfulPrefix + 1,
                  let cameraIndex = event.cameraIndex,
                  cameraIndex >= 0,
                  cameraIndex < cameraCount,
                  let intersectionCount = event.intersectionCount,
                  intersectionCount > 2_048,
                  event.budgetBytes == memoryBudgetBytes,
                  let requiredBytes = event.requiredBytes,
                  requiredBytes > 0,
                  requiredBytes <= memoryBudgetBytes else {
                throw MsplatEventProtocolError("event raster_replay record is invalid")
            }
            return nil
        case "raster_fallback":
            guard started,
                  let iteration = event.iteration,
                  iteration >= lastIteration,
                  iteration <= contract.iterationLimit,
                  let fallbackCount = event.fallbackCount,
                  fallbackCount > rasterFallbackCount,
                  validRasterFallbackCount(fallbackCount, through: iteration),
                  let intersectionCount = event.intersectionCount,
                  intersectionCount > 2_048,
                  let allocationBytes = event.allocationBytes,
                  allocationBytes > 0,
                  allocationBytes <= memoryBudgetBytes else {
                throw MsplatEventProtocolError("event raster_fallback record is invalid")
            }
            let fallbackMetrics = try recoveryMetrics(
                from: event,
                fallbackCount: fallbackCount
            )
            guard fallbackMetrics.isAtLeast(currentRecoveryMetrics) else {
                throw MsplatEventProtocolError("event raster_fallback metrics decreased")
            }
            applyRecoveryMetrics(fallbackMetrics)
            return AcceptedEffect(
                rasterFallback: MsplatRasterFallback(
                    iteration: iteration,
                    fallbackCount: fallbackCount,
                    intersectionCount: intersectionCount,
                    allocationBytes: allocationBytes
                )
            )
        case "raster_memory_budget_exceeded":
            guard let iteration = event.iteration,
                  (started
                    ? iteration >= lastIteration && iteration <= contract.iterationLimit
                    : event.sequence == 1 && iteration == 0),
                  let requiredBytes = event.requiredBytes,
                  requiredBytes > memoryBudgetBytes,
                  event.budgetBytes == memoryBudgetBytes,
                  event.intersectionCount.map({ $0 > 0 }) ?? true else {
                throw MsplatEventProtocolError(
                    "event raster_memory_budget_exceeded record is invalid"
                )
            }
            memoryBudgetFailure = MsplatRasterMemoryBudgetExceeded(
                iteration: iteration,
                requiredBytes: requiredBytes,
                budgetBytes: memoryBudgetBytes,
                intersectionCount: event.intersectionCount
            )
            return nil
        case "raster_resource_limit_exceeded":
            guard let iteration = event.iteration,
                  (started
                    ? iteration >= lastIteration && iteration <= contract.iterationLimit
                    : event.sequence == 1 && iteration == 0),
                  let requiredBytes = event.requiredBytes,
                  let maximumBufferBytes = event.maximumBufferBytes,
                  maximumBufferBytes > 0,
                  requiredBytes > maximumBufferBytes,
                  event.intersectionCount.map({ $0 > 0 }) ?? true else {
                throw MsplatEventProtocolError(
                    "event raster_resource_limit_exceeded record is invalid"
                )
            }
            resourceLimitFailure = MsplatRasterResourceLimitExceeded(
                iteration: iteration,
                requiredBytes: requiredBytes,
                maximumBufferBytes: maximumBufferBytes,
                intersectionCount: event.intersectionCount
            )
            return nil
        case "metal_allocation_unavailable":
            guard let iteration = event.iteration,
                  (started
                    ? iteration >= lastIteration && iteration <= contract.iterationLimit
                    : event.sequence == 1 && iteration == 0),
                  let requestedBytes = event.requestedBytes,
                  requestedBytes > 0,
                  let currentAllocatedBytes = event.currentAllocatedBytes,
                  currentAllocatedBytes >= 0,
                  let requiredBytes = event.requiredBytes,
                  requiredBytes == currentAllocatedBytes.addingReportingOverflow(requestedBytes).partialValue,
                  !currentAllocatedBytes.addingReportingOverflow(requestedBytes).overflow,
                  event.budgetBytes == memoryBudgetBytes,
                  let recommendedWorkingSetBytes = event.recommendedWorkingSetBytes,
                  recommendedWorkingSetBytes > 0,
                  let maximumBufferBytes = event.maximumBufferBytes,
                  maximumBufferBytes > 0,
                  requestedBytes <= maximumBufferBytes,
                  event.intersectionCount.map({ $0 > 0 }) ?? true else {
                throw MsplatEventProtocolError(
                    "event metal_allocation_unavailable record is invalid"
                )
            }
            metalAllocationFailure = MsplatMetalAllocationUnavailable(
                iteration: iteration,
                requestedBytes: requestedBytes,
                currentAllocatedBytes: currentAllocatedBytes,
                requiredBytes: requiredBytes,
                budgetBytes: memoryBudgetBytes,
                recommendedWorkingSetBytes: recommendedWorkingSetBytes,
                maximumBufferBytes: maximumBufferBytes,
                intersectionCount: event.intersectionCount
            )
            return nil
        case "checkpoint_loaded", "checkpoint_completed":
            guard started else {
                throw MsplatEventProtocolError("checkpoint event arrived before started")
            }
            let receipt = try checkpointReceipt(from: event)
            let receiptMetrics = RasterRecoveryMetrics(
                fallbackCount: receipt.rasterFallbackCount,
                exactFallbackElapsedSeconds: receipt.rasterExactFallbackElapsedSeconds,
                exactBufferGrowthCount: receipt.rasterExactBufferGrowthCount,
                exactBufferBytesAdded: receipt.rasterExactBufferBytesAdded,
                replayElapsedSeconds: receipt.rasterReplayElapsedSeconds,
                peakExactIntersectionCapacity: receipt.rasterPeakExactIntersectionCapacity
            )
            if event.event == "checkpoint_loaded" {
                guard resumeRequested,
                      latestCheckpoint == nil,
                      receipt.iteration == startIteration,
                      receiptMetrics == currentRecoveryMetrics else {
                    throw MsplatEventProtocolError("checkpoint_loaded does not match requested resume")
                }
            } else if latestCheckpoint == nil {
                guard !resumeRequested,
                      receipt.iteration == 0,
                      receiptMetrics == currentRecoveryMetrics else {
                    throw MsplatEventProtocolError("initial checkpoint_completed is invalid")
                }
            } else {
                guard receipt.iteration > latestCheckpoint!.iteration,
                      receipt.iteration < contract.iterationLimit,
                      receiptMetrics.isAtLeast(RasterRecoveryMetrics(
                          fallbackCount: latestCheckpoint!.rasterFallbackCount,
                          exactFallbackElapsedSeconds:
                              latestCheckpoint!.rasterExactFallbackElapsedSeconds,
                          exactBufferGrowthCount:
                              latestCheckpoint!.rasterExactBufferGrowthCount,
                          exactBufferBytesAdded: latestCheckpoint!.rasterExactBufferBytesAdded,
                          replayElapsedSeconds: latestCheckpoint!.rasterReplayElapsedSeconds,
                          peakExactIntersectionCapacity:
                              latestCheckpoint!.rasterPeakExactIntersectionCapacity
                      )),
                      receiptMetrics == currentRecoveryMetrics else {
                    throw MsplatEventProtocolError("checkpoint iterations are not strictly increasing")
                }
            }
            guard receipt.peakMemoryBytes >= lastPeakMemoryBytes else {
                throw MsplatEventProtocolError("checkpoint peak memory decreased")
            }
            lastPeakMemoryBytes = receipt.peakMemoryBytes
            latestCheckpoint = receipt
            return AcceptedEffect(checkpoint: receipt)
        case "progress":
            guard started,
                  let iteration = event.iteration,
                  let limit = event.iterationLimit,
                  let gaussianCount = event.gaussianCount,
                  let elapsed = event.elapsedSeconds,
                  let rate = event.iterationsPerSecond,
                  let eta = event.etaSeconds,
                  iteration > lastIteration,
                  iteration <= contract.iterationLimit,
                  limit == contract.iterationLimit,
                  gaussianCount > 0,
                  finiteNonNegative(elapsed),
                  finiteNonNegative(rate),
                  finiteNonNegative(eta) else {
                throw MsplatEventProtocolError("event progress record is invalid")
            }
            switch (event.loss, event.lossIteration) {
            case (nil, nil):
                break
            case let (loss?, lossIteration?)
                where loss.isFinite && lossIteration > 0 && lossIteration <= iteration:
                break
            default:
                throw MsplatEventProtocolError("event progress loss evidence is invalid")
            }
            lastIteration = iteration
            return AcceptedEffect(
                progress: MsplatTrainingProgress(
                    iteration: iteration,
                    iterationLimit: limit,
                    gaussianCount: gaussianCount,
                    elapsedSeconds: elapsed,
                    iterationsPerSecond: rate,
                    etaSeconds: eta,
                    loss: event.loss,
                    lossIteration: event.lossIteration
                )
            )
        case "preview_published":
            // Deliberately does not advance lastIteration: previews are published
            // between progress records and must not perturb the training sequence.
            guard started,
                  event.previewSchema == 1,
                  let iteration = event.iteration,
                  let publication = event.previewPublication,
                  let previewGaussianCount = event.previewGaussianCount,
                  let sourceGaussianCount = event.sourceGaussianCount,
                  let bytes = event.previewBytes,
                  let sha256 = event.previewSHA256,
                  iteration > 0,
                  iteration <= contract.iterationLimit,
                  publication > lastPreviewPublication,
                  previewGaussianCount > 0,
                  sourceGaussianCount > 0,
                  previewGaussianCount <= sourceGaussianCount,
                  bytes > 0,
                  isSHA256(sha256),
                  // The viewer refuses a scene without authenticated bounds, so a
                  // preview that cannot describe its own extent is not renderable.
                  let sceneCenter = event.sceneCenter,
                  sceneCenter.count == 3,
                  sceneCenter.allSatisfy(\.isFinite),
                  let sceneRadius = event.sceneRadius,
                  sceneRadius.isFinite,
                  sceneRadius > 0 else {
                throw MsplatEventProtocolError("event preview_published record is invalid")
            }
            lastPreviewPublication = publication
            return AcceptedEffect(
                preview: MsplatPreviewReceipt(
                    iteration: iteration,
                    publication: publication,
                    previewGaussianCount: previewGaussianCount,
                    sourceGaussianCount: sourceGaussianCount,
                    bytes: bytes,
                    sha256: sha256,
                    sceneBounds: SplatSceneBounds(
                        center: .init(x: sceneCenter[0], y: sceneCenter[1], z: sceneCenter[2]),
                        radius: sceneRadius
                    )
                )
            )
        case "preview_disabled":
            // The trainer gave up on previews for the rest of this run. Training is
            // unaffected, so this carries no effect beyond validation.
            guard started,
                  let iteration = event.iteration,
                  iteration > 0,
                  iteration <= contract.iterationLimit,
                  let reason = event.reason,
                  !reason.isEmpty else {
                throw MsplatEventProtocolError("event preview_disabled record is invalid")
            }
            // Training is unaffected, but any preview already on screen is now
            // frozen. Propagated so the app can stop presenting a stale model as
            // the live one.
            return AcceptedEffect(previewDisabled: reason)
        case "early_stop":
            guard started,
                  earlyStopIteration == nil,
                  event.reason == MsplatStopReason.plateau.rawValue,
                  event.plateauWindow == contract.plateauWindow,
                  let iteration = event.iteration,
                  iteration >= lastIteration,
                  iteration <= contract.iterationLimit,
                  let lastImprovementIteration = event.lastImprovementIteration,
                  lastImprovementIteration >= 0,
                  lastImprovementIteration <= iteration,
                  iteration - lastImprovementIteration >= contract.plateauWindow,
                  let loss = event.loss,
                  loss.isFinite,
                  loss >= 0,
                  event.lossIteration == iteration else {
                throw MsplatEventProtocolError("event early_stop record is invalid")
            }
            lastIteration = iteration
            earlyStopIteration = iteration
            return nil
        case "cancellation_requested":
            guard started,
                  cancellationIteration == nil,
                  let iteration = event.iteration,
                  iteration >= lastIteration,
                  iteration <= contract.iterationLimit,
                  event.signal.map({ $0 > 0 }) == true else {
                throw MsplatEventProtocolError("event cancellation_requested record is invalid")
            }
            cancellationIteration = iteration
            return nil
        case "cancelled":
            guard started,
                  let requestedAt = cancellationIteration,
                  let iteration = event.iteration,
                  iteration >= requestedAt,
                  let checkpoint = latestCheckpoint,
                  event.checkpointIteration == checkpoint.iteration,
                  event.checkpointGeneration == checkpoint.generation,
                  event.checkpointPayloadSHA256 == checkpoint.payloadSHA256,
                  event.inputDigest == inputDigest,
                  event.geometryDigest == geometryDigest,
                  event.memoryBudgetBytes == memoryBudgetBytes,
                  event.rasterFallbackCount == checkpoint.rasterFallbackCount,
                  event.droppedIntersectionCount == 0 else {
                throw MsplatEventProtocolError("event cancelled record has no matching checkpoint")
            }
            let cancelledMetrics = try recoveryMetrics(
                from: event,
                fallbackCount: checkpoint.rasterFallbackCount
            )
            guard cancelledMetrics == RasterRecoveryMetrics(
                fallbackCount: checkpoint.rasterFallbackCount,
                exactFallbackElapsedSeconds: checkpoint.rasterExactFallbackElapsedSeconds,
                exactBufferGrowthCount: checkpoint.rasterExactBufferGrowthCount,
                exactBufferBytesAdded: checkpoint.rasterExactBufferBytesAdded,
                replayElapsedSeconds: checkpoint.rasterReplayElapsedSeconds,
                peakExactIntersectionCapacity: checkpoint.rasterPeakExactIntersectionCapacity
            ) else {
                throw MsplatEventProtocolError("event cancelled raster metrics are not durable")
            }
            cancellationIteration = iteration
            cancelled = true
            return nil
        case "completed":
            guard started,
                  let iteration = event.iteration,
                  let gaussianCount = event.gaussianCount,
                  let elapsed = event.elapsedSeconds,
                  let peakMemoryBytes = event.peakMemoryBytes,
                  let outputBytes = event.outputBytes,
                  let sceneCenter = event.sceneCenter,
                  sceneCenter.count == 3,
                  sceneCenter.allSatisfy(\.isFinite),
                  let sceneRadius = event.sceneRadius,
                  sceneRadius.isFinite,
                  sceneRadius > 0,
                  let rawStopReason = event.stopReason,
                  let stopReason = MsplatStopReason(rawValue: rawStopReason),
                  iteration >= lastIteration,
                  iteration > 0,
                  iteration <= contract.iterationLimit,
                  gaussianCount > 0,
                  finiteNonNegative(elapsed),
                  peakMemoryBytes > 0,
                  peakMemoryBytes >= lastPeakMemoryBytes,
                  outputBytes > 0 else {
                throw MsplatEventProtocolError("event completed record is invalid")
            }
            try validateContract(event)
            try validateIdentity(event)
            guard event.memoryBudgetBytes == memoryBudgetBytes,
                  let completedRasterFallbackCount = event.rasterFallbackCount,
                  completedRasterFallbackCount == rasterFallbackCount,
                  event.droppedIntersectionCount == 0 else {
                throw MsplatEventProtocolError(
                    "event completed raster evidence is incomplete or unsafe"
                )
            }
            let completedMetrics = try recoveryMetrics(
                from: event,
                fallbackCount: completedRasterFallbackCount
            )
            guard completedMetrics.isAtLeast(currentRecoveryMetrics),
                  completedMetrics.exactFallbackElapsedSeconds <= elapsed,
                  completedMetrics.replayElapsedSeconds <= elapsed else {
                throw MsplatEventProtocolError("event completed raster metrics are inconsistent")
            }
            applyRecoveryMetrics(completedMetrics)
            if stopReason == .iterationLimit && iteration != contract.iterationLimit {
                throw MsplatEventProtocolError("event iteration-limit completion stopped early")
            }
            if stopReason == .plateau && earlyStopIteration != iteration {
                throw MsplatEventProtocolError("event plateau completion has no matching early_stop")
            }
            if stopReason == .iterationLimit && earlyStopIteration != nil {
                throw MsplatEventProtocolError("event iteration-limit completion followed early_stop")
            }
            completed = true
            result = MsplatTrainingResult(
                profile: contract.profile,
                iterationLimit: contract.iterationLimit,
                plateauWindow: contract.plateauWindow,
                completedIteration: iteration,
                stopReason: stopReason,
                gaussianCount: gaussianCount,
                elapsedSeconds: elapsed,
                peakMemoryBytes: peakMemoryBytes,
                memoryBudgetBytes: memoryBudgetBytes,
                rasterFallbackCount: rasterFallbackCount,
                rasterExactFallbackElapsedSeconds: rasterExactFallbackElapsedSeconds,
                rasterExactBufferGrowthCount: rasterExactBufferGrowthCount,
                rasterExactBufferBytesAdded: rasterExactBufferBytesAdded,
                rasterReplayElapsedSeconds: rasterReplayElapsedSeconds,
                rasterPeakExactIntersectionCapacity: rasterPeakExactIntersectionCapacity,
                droppedIntersectionCount: 0,
                sceneBounds: SplatSceneBounds(
                    center: ScenePoint3D(
                        x: sceneCenter[0],
                        y: sceneCenter[1],
                        z: sceneCenter[2]
                    ),
                    radius: sceneRadius
                ),
                outputBytes: outputBytes,
                inputDigest: inputDigest,
                geometryDigest: geometryDigest,
                trainerBuildDigest: trainerBuildDigest,
                latestCheckpoint: latestCheckpoint
            )
            return nil
        default:
            throw MsplatEventProtocolError("event type \(event.event) is not valid during training")
        }
    }

    private func checkpointReceipt(from event: MsplatNativeEvent) throws -> MsplatCheckpointReceipt {
        guard let iteration = event.iteration,
              iteration >= 0,
              iteration < contract.iterationLimit,
              let generation = event.checkpointGeneration,
              generation.count == 73,
              let payloadSHA256 = event.checkpointPayloadSHA256,
              isSHA256(payloadSHA256),
              let payloadBytes = event.checkpointPayloadBytes,
              payloadBytes > 0,
              let gaussianCount = event.gaussianCount,
              gaussianCount > 0,
              let peakMemoryBytes = event.peakMemoryBytes,
              peakMemoryBytes > 0,
              event.memoryBudgetBytes == memoryBudgetBytes,
              let eventRasterFallbackCount = event.rasterFallbackCount,
              validRasterFallbackCount(eventRasterFallbackCount, through: iteration),
              event.droppedIntersectionCount == 0,
              event.version == "1.1.3 (git 106499b)",
              event.profile == contract.argument,
              event.seed == seed,
              event.inputDigest == inputDigest,
              event.geometryDigest == geometryDigest,
              event.trainerBuildDigest == trainerBuildDigest else {
            throw MsplatEventProtocolError("checkpoint event record is invalid")
        }
        let metrics = try recoveryMetrics(
            from: event,
            fallbackCount: eventRasterFallbackCount
        )
        return MsplatCheckpointReceipt(
            iteration: iteration,
            generation: generation,
            payloadSHA256: payloadSHA256,
            payloadBytes: payloadBytes,
            gaussianCount: gaussianCount,
            peakMemoryBytes: peakMemoryBytes,
            memoryBudgetBytes: memoryBudgetBytes,
            rasterFallbackCount: eventRasterFallbackCount,
            rasterExactFallbackElapsedSeconds: metrics.exactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount: metrics.exactBufferGrowthCount,
            rasterExactBufferBytesAdded: metrics.exactBufferBytesAdded,
            rasterReplayElapsedSeconds: metrics.replayElapsedSeconds,
            rasterPeakExactIntersectionCapacity: metrics.peakExactIntersectionCapacity,
            droppedIntersectionCount: 0,
            inputDigest: inputDigest,
            geometryDigest: geometryDigest,
            trainerBuildDigest: trainerBuildDigest
        )
    }

    private func validateContract(_ event: MsplatNativeEvent) throws {
        guard event.profile == contract.argument,
              event.seed == seed,
              event.iterationLimit == contract.iterationLimit,
              event.plateauWindow == contract.plateauWindow else {
            throw MsplatEventProtocolError("event profile, seed, or budget does not match the request")
        }
    }

    private func validateIdentity(_ event: MsplatNativeEvent) throws {
        guard event.version == "1.1.3 (git 106499b)",
              event.inputDigest == inputDigest,
              event.geometryDigest == geometryDigest,
              event.trainerBuildDigest == trainerBuildDigest else {
            throw MsplatEventProtocolError("event identity does not match started")
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func finiteNonNegative(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private func validRasterFallbackCount(_ count: Int, through iteration: Int) -> Bool {
        count >= 0 && count <= min(iteration, Int(UInt32.max))
    }

    private func recoveryMetrics(
        from event: MsplatNativeEvent,
        fallbackCount: Int
    ) throws -> RasterRecoveryMetrics {
        guard let exactFallbackElapsedSeconds = event.rasterExactFallbackElapsedSeconds,
              let exactBufferGrowthCount = event.rasterExactBufferGrowthCount,
              let exactBufferBytesAdded = event.rasterExactBufferBytesAdded,
              let replayElapsedSeconds = event.rasterReplayElapsedSeconds,
              let peakExactIntersectionCapacity = event.rasterPeakExactIntersectionCapacity else {
            throw MsplatEventProtocolError("event raster recovery evidence is incomplete")
        }
        let metrics = RasterRecoveryMetrics(
            fallbackCount: fallbackCount,
            exactFallbackElapsedSeconds: exactFallbackElapsedSeconds,
            exactBufferGrowthCount: exactBufferGrowthCount,
            exactBufferBytesAdded: exactBufferBytesAdded,
            replayElapsedSeconds: replayElapsedSeconds,
            peakExactIntersectionCapacity: peakExactIntersectionCapacity
        )
        guard metrics.isValid,
              metrics.exactBufferBytesAdded == 0
                || 1 + ((metrics.exactBufferBytesAdded - 1) / memoryBudgetBytes)
                    <= Int64(metrics.exactBufferGrowthCount) else {
            throw MsplatEventProtocolError("event raster recovery evidence is inconsistent")
        }
        return metrics
    }

    private var currentRecoveryMetrics: RasterRecoveryMetrics {
        RasterRecoveryMetrics(
            fallbackCount: rasterFallbackCount,
            exactFallbackElapsedSeconds: rasterExactFallbackElapsedSeconds,
            exactBufferGrowthCount: rasterExactBufferGrowthCount,
            exactBufferBytesAdded: rasterExactBufferBytesAdded,
            replayElapsedSeconds: rasterReplayElapsedSeconds,
            peakExactIntersectionCapacity: rasterPeakExactIntersectionCapacity
        )
    }

    private func applyRecoveryMetrics(_ metrics: RasterRecoveryMetrics) {
        rasterFallbackCount = metrics.fallbackCount
        rasterExactFallbackElapsedSeconds = metrics.exactFallbackElapsedSeconds
        rasterExactBufferGrowthCount = metrics.exactBufferGrowthCount
        rasterExactBufferBytesAdded = metrics.exactBufferBytesAdded
        rasterReplayElapsedSeconds = metrics.replayElapsedSeconds
        rasterPeakExactIntersectionCapacity = metrics.peakExactIntersectionCapacity
    }

    private struct RasterRecoveryMetrics: Equatable {
        let fallbackCount: Int
        let exactFallbackElapsedSeconds: Double
        let exactBufferGrowthCount: Int
        let exactBufferBytesAdded: Int64
        let replayElapsedSeconds: Double
        let peakExactIntersectionCapacity: Int64

        var isValid: Bool {
            fallbackCount >= 0
                && exactFallbackElapsedSeconds.isFinite
                && exactFallbackElapsedSeconds >= 0
                && exactBufferGrowthCount >= 0
                && exactBufferGrowthCount <= fallbackCount
                && exactBufferBytesAdded >= 0
                && replayElapsedSeconds.isFinite
                && replayElapsedSeconds >= 0
                && peakExactIntersectionCapacity >= 0
                && peakExactIntersectionCapacity <= Int64(UInt32.max)
                && ((fallbackCount == 0
                    && exactFallbackElapsedSeconds == 0
                    && exactBufferGrowthCount == 0
                    && exactBufferBytesAdded == 0
                    && replayElapsedSeconds == 0
                    && peakExactIntersectionCapacity == 0)
                  || (fallbackCount > 0
                    && exactFallbackElapsedSeconds > 0
                    && exactBufferGrowthCount > 0
                    && exactBufferBytesAdded > 0
                    && replayElapsedSeconds > 0
                    && peakExactIntersectionCapacity > 2_048))
        }

        func isAtLeast(_ prior: Self) -> Bool {
            fallbackCount >= prior.fallbackCount
                && exactFallbackElapsedSeconds >= prior.exactFallbackElapsedSeconds
                && exactBufferGrowthCount >= prior.exactBufferGrowthCount
                && exactBufferBytesAdded >= prior.exactBufferBytesAdded
                && replayElapsedSeconds >= prior.replayElapsedSeconds
                && peakExactIntersectionCapacity >= prior.peakExactIntersectionCapacity
        }
    }

    private struct AcceptedEffect {
        let progress: MsplatTrainingProgress?
        let checkpoint: MsplatCheckpointReceipt?
        let rasterFallback: MsplatRasterFallback?
        let preview: MsplatPreviewReceipt?
        let previewDisabled: String?

        init(
            progress: MsplatTrainingProgress? = nil,
            checkpoint: MsplatCheckpointReceipt? = nil,
            rasterFallback: MsplatRasterFallback? = nil,
            preview: MsplatPreviewReceipt? = nil,
            previewDisabled: String? = nil
        ) {
            self.progress = progress
            self.checkpoint = checkpoint
            self.rasterFallback = rasterFallback
            self.preview = preview
            self.previewDisabled = previewDisabled
        }
    }
}

private struct MsplatEventProtocolError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        "Native trainer event protocol error: \(message)"
    }
}
