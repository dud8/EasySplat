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
    public let droppedIntersectionCount: Int
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
        datasetPath: URL,
        outputPath: URL,
        checkpointPath requestedCheckpointPath: URL? = nil,
        resumeFrom: URL? = nil,
        profile: DetailProfile,
        seed: UInt64,
        iterationLimit: Int? = nil,
        plateauWindow: Int? = nil,
        memoryBudgetBytes: Int64,
        onProgress: @escaping @Sendable (MsplatTrainingProgress) -> Void = { _ in },
        onCheckpoint: @escaping @Sendable (MsplatCheckpointReceipt) -> Void = { _ in },
        onRasterFallback: @escaping @Sendable (MsplatRasterFallback) -> Void = { _ in },
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
            "--checkpoint", checkpointPath.path,
            "--seed", String(seed),
            "--memory-budget-bytes", String(memoryBudgetBytes),
            "--events-fd", "1",
        ]
        if let resumeFrom {
            arguments.append(contentsOf: ["--resume", resumeFrom.path])
        }
        let events = MsplatEventStream(
            contract: contract,
            seed: seed,
            memoryBudgetBytes: memoryBudgetBytes,
            checkpointURL: checkpointPath,
            resumeRequested: resumeFrom != nil,
            onProgress: onProgress,
            onCheckpoint: onCheckpoint,
            onRasterFallback: onRasterFallback
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
        guard ProjectArtifactValidator.validatePlyFile(at: stagingOutputPath) == .valid,
              let header = ProjectArtifactValidator.readPlyHeader(at: stagingOutputPath),
              header.vertexCount == completion.gaussianCount else {
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
    let droppedIntersectionCount: Int?
    let intersectionCount: Int64?
    let allocationBytes: Int64?
    let requiredBytes: Int64?
    let budgetBytes: Int64?
    let maximumBufferBytes: Int64?

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
        case droppedIntersectionCount = "dropped_intersection_count"
        case intersectionCount = "intersection_count"
        case allocationBytes = "allocation_bytes"
        case requiredBytes = "required_bytes"
        case budgetBytes = "budget_bytes"
        case maximumBufferBytes = "max_buffer_bytes"
    }
}

private final class MsplatEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private let contract: MsplatProfileContract
    private let seed: UInt64
    private let memoryBudgetBytes: Int64
    private let checkpointURL: URL
    private let resumeRequested: Bool
    private let onProgress: @Sendable (MsplatTrainingProgress) -> Void
    private let onCheckpoint: @Sendable (MsplatCheckpointReceipt) -> Void
    private let onRasterFallback: @Sendable (MsplatRasterFallback) -> Void
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
    private var rasterFallbackCount = 0

    init(
        contract: MsplatProfileContract,
        seed: UInt64,
        memoryBudgetBytes: Int64,
        checkpointURL: URL,
        resumeRequested: Bool,
        onProgress: @escaping @Sendable (MsplatTrainingProgress) -> Void,
        onCheckpoint: @escaping @Sendable (MsplatCheckpointReceipt) -> Void,
        onRasterFallback: @escaping @Sendable (MsplatRasterFallback) -> Void
    ) {
        self.contract = contract
        self.seed = seed
        self.memoryBudgetBytes = memoryBudgetBytes
        self.checkpointURL = checkpointURL
        self.resumeRequested = resumeRequested
        self.onProgress = onProgress
        self.onCheckpoint = onCheckpoint
        self.onRasterFallback = onRasterFallback
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
                let event = try JSONDecoder().decode(
                    MsplatNativeEvent.self,
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

    func finishInterruption() throws -> MsplatTrainingInterrupted? {
        let evidence: (Int, MsplatCheckpointReceipt, MsplatCheckpointExpectation)? = try lock.withLock {
            if let failure { throw failure }
            guard lineCount > 0 else { return nil }
            if completed || resumeRejection != nil || memoryBudgetFailure != nil
                || resourceLimitFailure != nil { return nil }
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
        guard event.schemaVersion == 1 else {
            throw MsplatEventProtocolError("event schema must be 1")
        }
        guard event.sequence == nextSequence else {
            throw MsplatEventProtocolError(
                "event sequence \(event.sequence) does not match expected \(nextSequence)"
            )
        }
        nextSequence += 1
        guard !completed, !cancelled, resumeRejection == nil,
              memoryBudgetFailure == nil, resourceLimitFailure == nil else {
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
                  event.checkpointSchema == 2,
                  event.payloadSchema == 2,
                  let eventInputDigest = event.inputDigest,
                  let eventGeometryDigest = event.geometryDigest,
                  let eventTrainerBuildDigest = event.trainerBuildDigest,
                  isSHA256(eventInputDigest),
                  isSHA256(eventGeometryDigest),
                  isSHA256(eventTrainerBuildDigest),
                  resumeRequested || iteration == 0 else {
                throw MsplatEventProtocolError("event started record is incomplete or duplicated")
            }
            try validateContract(event)
            startIteration = iteration
            lastIteration = iteration
            cameraCount = eventCameraCount
            inputDigest = eventInputDigest
            geometryDigest = eventGeometryDigest
            trainerBuildDigest = eventTrainerBuildDigest
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
            rasterFallbackCount = fallbackCount
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
        case "checkpoint_loaded", "checkpoint_completed":
            guard started else {
                throw MsplatEventProtocolError("checkpoint event arrived before started")
            }
            let receipt = try checkpointReceipt(from: event)
            if event.event == "checkpoint_loaded" {
                guard resumeRequested,
                      latestCheckpoint == nil,
                      receipt.iteration == startIteration,
                      receipt.rasterFallbackCount >= rasterFallbackCount else {
                    throw MsplatEventProtocolError("checkpoint_loaded does not match requested resume")
                }
                rasterFallbackCount = receipt.rasterFallbackCount
            } else if latestCheckpoint == nil {
                guard !resumeRequested,
                      receipt.iteration == 0,
                      receipt.rasterFallbackCount == rasterFallbackCount else {
                    throw MsplatEventProtocolError("initial checkpoint_completed is invalid")
                }
            } else {
                guard receipt.iteration > latestCheckpoint!.iteration,
                      receipt.iteration < contract.iterationLimit,
                      receipt.rasterFallbackCount >= latestCheckpoint!.rasterFallbackCount,
                      receipt.rasterFallbackCount == rasterFallbackCount else {
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
        case "early_stop":
            guard started,
                  earlyStopIteration == nil,
                  event.reason == MsplatStopReason.plateau.rawValue,
                  event.plateauWindow == contract.plateauWindow,
                  let iteration = event.iteration,
                  iteration >= lastIteration,
                  iteration <= contract.iterationLimit else {
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
                  event.rasterFallbackCount == rasterFallbackCount,
                  event.droppedIntersectionCount == 0 else {
                throw MsplatEventProtocolError(
                    "event completed raster evidence is incomplete or unsafe"
                )
            }
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
                droppedIntersectionCount: 0,
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
        return MsplatCheckpointReceipt(
            iteration: iteration,
            generation: generation,
            payloadSHA256: payloadSHA256,
            payloadBytes: payloadBytes,
            gaussianCount: gaussianCount,
            peakMemoryBytes: peakMemoryBytes,
            memoryBudgetBytes: memoryBudgetBytes,
            rasterFallbackCount: eventRasterFallbackCount,
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

    private struct AcceptedEffect {
        let progress: MsplatTrainingProgress?
        let checkpoint: MsplatCheckpointReceipt?
        let rasterFallback: MsplatRasterFallback?

        init(
            progress: MsplatTrainingProgress? = nil,
            checkpoint: MsplatCheckpointReceipt? = nil,
            rasterFallback: MsplatRasterFallback? = nil
        ) {
            self.progress = progress
            self.checkpoint = checkpoint
            self.rasterFallback = rasterFallback
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
