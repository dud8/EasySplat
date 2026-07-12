import Foundation

public enum MsplatStopReason: String, Sendable, Equatable {
    case iterationLimit = "iteration_limit"
    case plateau
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

public struct MsplatTrainingResult: Sendable, Equatable {
    public let profile: DetailProfile
    public let iterationLimit: Int
    public let plateauWindow: Int
    public let completedIteration: Int
    public let stopReason: MsplatStopReason
    public let gaussianCount: Int
    public let elapsedSeconds: Double
    public let outputBytes: Int64
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
        profile: DetailProfile,
        seed: UInt64,
        onProgress: @escaping @Sendable (MsplatTrainingProgress) -> Void = { _ in },
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> MsplatTrainingResult {
        let fileManager = FileManager.default
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

        let contract = MsplatProfileContract(profile: profile)
        let arguments = [
            "--dataset", datasetPath.path,
            "--output", outputPath.path,
            "--profile", contract.argument,
            "--seed", String(seed),
            "--events-fd", "1",
        ]
        let events = MsplatEventStream(
            contract: contract,
            seed: seed,
            onProgress: onProgress
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

        if events.consumedLineCount == 0 {
            for line in result.stdout.split(whereSeparator: \.isNewline) {
                events.consume(String(line))
            }
        }
        let completion = try events.finish()
        guard let attributes = try? fileManager.attributesOfItem(atPath: outputPath.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw MsplatEventProtocolError("event stream completed without a published output")
        }
        guard size.int64Value == completion.outputBytes else {
            throw MsplatEventProtocolError(
                "event output size \(completion.outputBytes) does not match file size \(size.int64Value)"
            )
        }
        return completion
    }
}

private struct MsplatProfileContract: Sendable {
    let profile: DetailProfile
    let argument: String
    let iterationLimit: Int
    let plateauWindow: Int

    init(profile: DetailProfile) {
        self.profile = profile
        switch profile {
        case .fast:
            argument = "fast"
            iterationLimit = 3_000
            plateauWindow = 400
        case .balanced:
            argument = "balanced"
            iterationLimit = 7_000
            plateauWindow = 800
        case .highDetail:
            argument = "high-detail"
            iterationLimit = 15_000
            plateauWindow = 1_500
        }
    }
}

private struct MsplatNativeEvent: Decodable {
    let event: String
    let schemaVersion: Int
    let sequence: UInt64
    let version: String?
    let profile: String?
    let seed: UInt64?
    let iteration: Int?
    let iterationLimit: Int?
    let plateauWindow: Int?
    let cameraCount: Int?
    let initialGaussianCount: Int?
    let gaussianCount: Int?
    let elapsedSeconds: Double?
    let iterationsPerSecond: Double?
    let etaSeconds: Double?
    let loss: Double?
    let lossIteration: Int?
    let outputBytes: Int64?
    let stopReason: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case event
        case schemaVersion = "schema_version"
        case sequence
        case version
        case profile
        case seed
        case iteration
        case iterationLimit = "iteration_limit"
        case plateauWindow = "plateau_window"
        case cameraCount = "camera_count"
        case initialGaussianCount = "initial_gaussian_count"
        case gaussianCount = "gaussian_count"
        case elapsedSeconds = "elapsed_seconds"
        case iterationsPerSecond = "iterations_per_second"
        case etaSeconds = "eta_seconds"
        case loss
        case lossIteration = "loss_iteration"
        case outputBytes = "output_bytes"
        case stopReason = "stop_reason"
        case reason
    }
}

private final class MsplatEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private let contract: MsplatProfileContract
    private let seed: UInt64
    private let onProgress: @Sendable (MsplatTrainingProgress) -> Void
    private var nextSequence: UInt64 = 1
    private var started = false
    private var completed = false
    private var lastIteration = 0
    private var earlyStopIteration: Int?
    private var lineCount = 0
    private var failure: Error?
    private var result: MsplatTrainingResult?

    init(
        contract: MsplatProfileContract,
        seed: UInt64,
        onProgress: @escaping @Sendable (MsplatTrainingProgress) -> Void
    ) {
        self.contract = contract
        self.seed = seed
        self.onProgress = onProgress
    }

    var consumedLineCount: Int {
        lock.withLock { lineCount }
    }

    func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let progress: MsplatTrainingProgress? = lock.withLock {
            lineCount += 1
            guard failure == nil else { return nil }
            do {
                let event = try JSONDecoder().decode(
                    MsplatNativeEvent.self,
                    from: Data(trimmed.utf8)
                )
                return try accept(event)
            } catch {
                failure = error is MsplatEventProtocolError
                    ? error
                    : MsplatEventProtocolError("event record is invalid: \(error.localizedDescription)")
                return nil
            }
        }
        if let progress {
            onProgress(progress)
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

    private func accept(_ event: MsplatNativeEvent) throws -> MsplatTrainingProgress? {
        guard event.schemaVersion == 1 else {
            throw MsplatEventProtocolError("event schema must be 1")
        }
        guard event.sequence == nextSequence else {
            throw MsplatEventProtocolError(
                "event sequence \(event.sequence) does not match expected \(nextSequence)"
            )
        }
        nextSequence += 1
        guard !completed else {
            throw MsplatEventProtocolError("event arrived after completed")
        }

        switch event.event {
        case "started":
            guard !started, event.sequence == 1,
                  event.version == "1.1.3 (git 106499b)",
                  event.iteration == 0,
                  event.cameraCount.map({ $0 > 0 }) == true,
                  event.initialGaussianCount.map({ $0 > 0 }) == true else {
                throw MsplatEventProtocolError("event started record is incomplete or duplicated")
            }
            try validateContract(event)
            started = true
            return nil
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
            return MsplatTrainingProgress(
                iteration: iteration,
                iterationLimit: limit,
                gaussianCount: gaussianCount,
                elapsedSeconds: elapsed,
                iterationsPerSecond: rate,
                etaSeconds: eta,
                loss: event.loss,
                lossIteration: event.lossIteration
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
        case "completed":
            guard started,
                  let iteration = event.iteration,
                  let gaussianCount = event.gaussianCount,
                  let elapsed = event.elapsedSeconds,
                  let outputBytes = event.outputBytes,
                  let rawStopReason = event.stopReason,
                  let stopReason = MsplatStopReason(rawValue: rawStopReason),
                  iteration >= lastIteration,
                  iteration > 0,
                  iteration <= contract.iterationLimit,
                  gaussianCount > 0,
                  finiteNonNegative(elapsed),
                  outputBytes > 0 else {
                throw MsplatEventProtocolError("event completed record is invalid")
            }
            try validateContract(event)
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
                outputBytes: outputBytes
            )
            return nil
        default:
            throw MsplatEventProtocolError("event type \(event.event) is not valid during training")
        }
    }

    private func validateContract(_ event: MsplatNativeEvent) throws {
        guard event.profile == contract.argument,
              event.seed == seed,
              event.iterationLimit == contract.iterationLimit,
              event.plateauWindow == contract.plateauWindow else {
            throw MsplatEventProtocolError("event profile, seed, or budget does not match the request")
        }
    }

    private func finiteNonNegative(_ value: Double) -> Bool {
        value.isFinite && value >= 0
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
