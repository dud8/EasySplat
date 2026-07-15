import CryptoKit
import Darwin
import Foundation

public struct MsplatCheckpointReceipt: Sendable, Equatable {
    public let iteration: Int
    public let generation: String
    public let payloadSHA256: String
    public let payloadBytes: Int64
    public let gaussianCount: Int
    public let peakMemoryBytes: Int64
    public let memoryBudgetBytes: Int64
    public let rasterFallbackCount: Int
    public let rasterExactFallbackElapsedSeconds: Double
    public let rasterExactBufferGrowthCount: Int
    public let rasterExactBufferBytesAdded: Int64
    public let rasterReplayElapsedSeconds: Double
    public let rasterPeakExactIntersectionCapacity: Int64
    public let droppedIntersectionCount: Int
    public let inputDigest: String
    public let geometryDigest: String
    public let trainerBuildDigest: String

    public init(
        iteration: Int,
        generation: String,
        payloadSHA256: String,
        payloadBytes: Int64,
        gaussianCount: Int,
        peakMemoryBytes: Int64,
        memoryBudgetBytes: Int64,
        rasterFallbackCount: Int,
        rasterExactFallbackElapsedSeconds: Double,
        rasterExactBufferGrowthCount: Int,
        rasterExactBufferBytesAdded: Int64,
        rasterReplayElapsedSeconds: Double,
        rasterPeakExactIntersectionCapacity: Int64,
        droppedIntersectionCount: Int,
        inputDigest: String,
        geometryDigest: String,
        trainerBuildDigest: String
    ) {
        self.iteration = iteration
        self.generation = generation
        self.payloadSHA256 = payloadSHA256
        self.payloadBytes = payloadBytes
        self.gaussianCount = gaussianCount
        self.peakMemoryBytes = peakMemoryBytes
        self.memoryBudgetBytes = memoryBudgetBytes
        self.rasterFallbackCount = rasterFallbackCount
        self.rasterExactFallbackElapsedSeconds = rasterExactFallbackElapsedSeconds
        self.rasterExactBufferGrowthCount = rasterExactBufferGrowthCount
        self.rasterExactBufferBytesAdded = rasterExactBufferBytesAdded
        self.rasterReplayElapsedSeconds = rasterReplayElapsedSeconds
        self.rasterPeakExactIntersectionCapacity = rasterPeakExactIntersectionCapacity
        self.droppedIntersectionCount = droppedIntersectionCount
        self.inputDigest = inputDigest
        self.geometryDigest = geometryDigest
        self.trainerBuildDigest = trainerBuildDigest
    }
}

public struct MsplatTrainingInterrupted: Error, Sendable, Equatable {
    public let completedIteration: Int
    public let checkpoint: MsplatCheckpointReceipt

    public init(completedIteration: Int, checkpoint: MsplatCheckpointReceipt) {
        self.completedIteration = completedIteration
        self.checkpoint = checkpoint
    }
}

struct MsplatCheckpointExpectation: Sendable {
    let trainerVersion: String
    let trainerBuildDigest: String
    let profile: String
    let iterationLimit: Int
    let plateauWindow: Int
    let seed: UInt64
    let cameraCount: Int
    let inputDigest: String
    let geometryDigest: String
    let memoryBudgetBytes: Int64
}

enum MsplatCheckpointValidator {
    private static let maximumManifestBytes = 4 * 1_024 * 1_024
    private static let maximumPayloadBytes: Int64 = 32 * 1_024 * 1_024 * 1_024
    private static let manifestKeys: Set<String> = [
        "backing_capacity", "best_camera_losses", "camera_count", "camera_draw_count",
        "dropped_intersection_count", "elapsed_seconds", "gaussian_count", "geometry_digest", "input_digest",
        "iteration", "iteration_limit", "last_improvement_iteration", "latest_loss",
        "latest_loss_iteration", "memory_budget_bytes", "payload_bytes", "payload_file", "payload_schema",
        "payload_sha256", "plateau_window", "profile", "schema_version", "seed",
        "raster_exact_buffer_bytes_added", "raster_exact_buffer_growth_count",
        "raster_exact_fallback_elapsed_seconds", "raster_fallback_count",
        "raster_peak_exact_intersection_capacity", "raster_replay_elapsed_seconds",
        "trainer_build_digest", "trainer_version",
    ]

    static func validate(
        checkpointURL: URL,
        receipt: MsplatCheckpointReceipt,
        expectation: MsplatCheckpointExpectation
    ) throws {
        guard isGeneration(receipt.generation),
              isSHA256(receipt.payloadSHA256),
              isSHA256(receipt.inputDigest),
              isSHA256(receipt.geometryDigest),
              isSHA256(receipt.trainerBuildDigest),
              receipt.inputDigest == expectation.inputDigest,
              receipt.geometryDigest == expectation.geometryDigest,
              receipt.trainerBuildDigest == expectation.trainerBuildDigest,
              receipt.iteration >= 0,
              receipt.payloadBytes > 0,
              receipt.payloadBytes <= maximumPayloadBytes,
              receipt.gaussianCount > 0,
              receipt.peakMemoryBytes > 0,
              receipt.memoryBudgetBytes == expectation.memoryBudgetBytes,
              isValidRasterFallbackCount(
                  receipt.rasterFallbackCount,
                  through: receipt.iteration
              ),
              recoveryMetricsAreValid(
                  fallbackCount: receipt.rasterFallbackCount,
                  exactFallbackElapsedSeconds: receipt.rasterExactFallbackElapsedSeconds,
                  exactBufferGrowthCount: receipt.rasterExactBufferGrowthCount,
                  exactBufferBytesAdded: receipt.rasterExactBufferBytesAdded,
                  replayElapsedSeconds: receipt.rasterReplayElapsedSeconds,
                  peakExactIntersectionCapacity: receipt.rasterPeakExactIntersectionCapacity,
                  memoryBudgetBytes: receipt.memoryBudgetBytes
              ),
              receipt.droppedIntersectionCount == 0 else {
            throw MsplatCheckpointValidationError("checkpoint receipt is invalid")
        }

        let root = checkpointURL.standardizedFileURL
        try requireDirectory(root, name: "checkpoint root")
        let generationsURL = root.appendingPathComponent("generations", isDirectory: true)
        try requireDirectory(generationsURL, name: "checkpoint generations")
        let currentURL = root.appendingPathComponent("CURRENT")
        let currentData = try boundedData(from: currentURL, maximumBytes: 128)
        guard String(data: currentData, encoding: .utf8) == receipt.generation + "\n" else {
            throw MsplatCheckpointValidationError("checkpoint CURRENT does not match the event receipt")
        }

        let generationURL = generationsURL
            .appendingPathComponent(receipt.generation, isDirectory: true)
        try requireDirectory(generationURL, name: "checkpoint generation")
        let contents = try FileManager.default.contentsOfDirectory(
            at: generationURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard Set(contents.map(\.lastPathComponent)) == ["manifest.json", "state.msplat"] else {
            throw MsplatCheckpointValidationError("checkpoint generation has unexpected contents")
        }

        let manifestURL = generationURL.appendingPathComponent("manifest.json")
        let payloadURL = generationURL.appendingPathComponent("state.msplat")
        let manifestData = try boundedData(from: manifestURL, maximumBytes: maximumManifestBytes)
        guard let object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              Set(object.keys) == manifestKeys else {
            throw MsplatCheckpointValidationError("checkpoint manifest keys do not match schema 3")
        }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: manifestData)

        guard manifest.schemaVersion == 3,
              manifest.payloadSchema == 2,
              manifest.trainerVersion == expectation.trainerVersion,
              manifest.trainerBuildDigest == expectation.trainerBuildDigest,
              manifest.profile == expectation.profile,
              manifest.iterationLimit == expectation.iterationLimit,
              manifest.plateauWindow == expectation.plateauWindow,
              manifest.seed == expectation.seed,
              manifest.cameraCount == expectation.cameraCount,
              manifest.cameraDrawCount == manifest.iteration,
              manifest.inputDigest == expectation.inputDigest,
              manifest.geometryDigest == expectation.geometryDigest,
              manifest.memoryBudgetBytes == expectation.memoryBudgetBytes,
              manifest.iteration >= 0,
              manifest.iteration < expectation.iterationLimit,
              manifest.iteration == receipt.iteration,
              manifest.gaussianCount == receipt.gaussianCount,
              manifest.rasterFallbackCount == receipt.rasterFallbackCount,
              manifest.rasterExactFallbackElapsedSeconds
                  == receipt.rasterExactFallbackElapsedSeconds,
              manifest.rasterExactBufferGrowthCount == receipt.rasterExactBufferGrowthCount,
              manifest.rasterExactBufferBytesAdded == receipt.rasterExactBufferBytesAdded,
              manifest.rasterReplayElapsedSeconds == receipt.rasterReplayElapsedSeconds,
              manifest.rasterPeakExactIntersectionCapacity
                  == receipt.rasterPeakExactIntersectionCapacity,
              recoveryMetricsAreValid(
                  fallbackCount: manifest.rasterFallbackCount,
                  exactFallbackElapsedSeconds: manifest.rasterExactFallbackElapsedSeconds,
                  exactBufferGrowthCount: manifest.rasterExactBufferGrowthCount,
                  exactBufferBytesAdded: manifest.rasterExactBufferBytesAdded,
                  replayElapsedSeconds: manifest.rasterReplayElapsedSeconds,
                  peakExactIntersectionCapacity: manifest.rasterPeakExactIntersectionCapacity,
                  memoryBudgetBytes: manifest.memoryBudgetBytes
              ),
              isValidRasterFallbackCount(
                  manifest.rasterFallbackCount,
                  through: manifest.iteration
              ),
              manifest.droppedIntersectionCount == 0,
              manifest.gaussianCount > 0,
              manifest.backingCapacity >= manifest.gaussianCount,
              manifest.payloadFile == "state.msplat",
              manifest.payloadSHA256 == receipt.payloadSHA256,
              isSHA256(manifest.payloadSHA256),
              manifest.payloadBytes == receipt.payloadBytes,
              manifest.lastImprovementIteration >= 0,
              manifest.lastImprovementIteration <= max(manifest.iteration, 500),
              manifest.latestLossIteration >= 0,
              manifest.latestLossIteration <= manifest.iteration,
              manifest.elapsedSeconds.isFinite,
              manifest.elapsedSeconds >= 0,
              manifest.rasterExactFallbackElapsedSeconds <= manifest.elapsedSeconds,
              manifest.rasterReplayElapsedSeconds <= manifest.elapsedSeconds,
              manifest.bestCameraLosses.count == expectation.cameraCount,
              manifest.bestCameraLosses.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }),
              (manifest.latestLoss.map { $0.isFinite && $0 >= 0 }
                  ?? (manifest.latestLossIteration == 0)) else {
            throw MsplatCheckpointValidationError("checkpoint manifest does not match this training run")
        }

        let generationDigest = SHA256.hash(data: manifestData).hexString
        guard receipt.generation == String(format: "%08d", receipt.iteration) + "-" + generationDigest else {
            throw MsplatCheckpointValidationError("checkpoint generation name does not match its manifest")
        }

        let payloadValues = try payloadURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard payloadValues.isRegularFile == true,
              payloadValues.isSymbolicLink != true,
              Int64(payloadValues.fileSize ?? -1) == receipt.payloadBytes else {
            throw MsplatCheckpointValidationError("checkpoint payload is not an ordinary file of the declared size")
        }
        let actualPayloadDigest = try sha256(
            of: payloadURL,
            expectedBytes: receipt.payloadBytes
        )
        guard actualPayloadDigest == receipt.payloadSHA256 else {
            throw MsplatCheckpointValidationError("checkpoint payload hash does not match its receipt")
        }
    }

    static func validateResume(
        checkpointURL: URL,
        artifact: TrainingArtifact
    ) throws -> MsplatCheckpointReceipt {
        do {
            guard artifact.schemaVersion == TrainingArtifact.currentSchemaVersion,
                  artifact.completionStatus == .checkpointed,
                  artifact.trainerVersion == "1.1.3 (git 106499b)",
                  artifact.runtimeVersion == "native-metal-cli-v2",
                  artifact.checkpointPath == "Training/checkpoints/msplat",
                  artifact.outputPath == nil,
                  isSHA256(artifact.trainerBuildDigest),
                  isSHA256(artifact.inputDigest),
                  isSHA256(artifact.geometryDigest),
                  let recordedPayloadDigest = artifact.checkpointDigest,
                  isSHA256(recordedPayloadDigest),
                  artifact.completedIteration >= 0,
                  artifact.completedIteration < artifact.iterationLimit,
                  artifact.gaussianCount > 0,
                  artifact.peakMemoryBytes > 0,
                  artifact.memoryBudgetBytes > 0,
                  isValidRasterFallbackCount(
                      artifact.rasterFallbackCount,
                      through: artifact.completedIteration
                  ),
                  recoveryMetricsAreValid(
                      fallbackCount: artifact.rasterFallbackCount,
                      exactFallbackElapsedSeconds: artifact.rasterExactFallbackElapsedSeconds,
                      exactBufferGrowthCount: artifact.rasterExactBufferGrowthCount,
                      exactBufferBytesAdded: artifact.rasterExactBufferBytesAdded,
                      replayElapsedSeconds: artifact.rasterReplayElapsedSeconds,
                      peakExactIntersectionCapacity: artifact.rasterPeakExactIntersectionCapacity,
                      memoryBudgetBytes: artifact.memoryBudgetBytes
                  ),
                  artifact.droppedIntersectionCount == 0,
                  artifact.sceneBounds == nil else {
                throw MsplatCheckpointValidationError("training manifest has no compatible resume record")
            }
            let peakMemoryBytes = artifact.peakMemoryBytes

            let root = checkpointURL.standardizedFileURL
            try requireDirectory(root, name: "checkpoint root")
            let generationsURL = root.appendingPathComponent("generations", isDirectory: true)
            try requireDirectory(generationsURL, name: "checkpoint generations")
            let currentData = try boundedData(
                from: root.appendingPathComponent("CURRENT"),
                maximumBytes: 128
            )
            guard let current = String(data: currentData, encoding: .utf8),
                  current.hasSuffix("\n"),
                  current.dropLast().contains(where: { !$0.isNewline }),
                  current.filter(\.isNewline).count == 1 else {
                throw MsplatCheckpointValidationError("checkpoint CURRENT is malformed")
            }
            let generation = String(current.dropLast())
            guard isGeneration(generation) else {
                throw MsplatCheckpointValidationError("checkpoint CURRENT generation is invalid")
            }
            let generationURL = generationsURL.appendingPathComponent(generation, isDirectory: true)
            try requireDirectory(generationURL, name: "checkpoint generation")
            let manifestURL = generationURL.appendingPathComponent("manifest.json")
            let manifestData = try boundedData(from: manifestURL, maximumBytes: maximumManifestBytes)
            guard let object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  Set(object.keys) == manifestKeys else {
                throw MsplatCheckpointValidationError("checkpoint manifest keys do not match schema 3")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            let receipt = MsplatCheckpointReceipt(
                iteration: manifest.iteration,
                generation: generation,
                payloadSHA256: manifest.payloadSHA256,
                payloadBytes: manifest.payloadBytes,
                gaussianCount: manifest.gaussianCount,
                peakMemoryBytes: peakMemoryBytes,
                memoryBudgetBytes: manifest.memoryBudgetBytes,
                rasterFallbackCount: manifest.rasterFallbackCount,
                rasterExactFallbackElapsedSeconds:
                    manifest.rasterExactFallbackElapsedSeconds,
                rasterExactBufferGrowthCount: manifest.rasterExactBufferGrowthCount,
                rasterExactBufferBytesAdded: manifest.rasterExactBufferBytesAdded,
                rasterReplayElapsedSeconds: manifest.rasterReplayElapsedSeconds,
                rasterPeakExactIntersectionCapacity:
                    manifest.rasterPeakExactIntersectionCapacity,
                droppedIntersectionCount: 0,
                inputDigest: manifest.inputDigest,
                geometryDigest: manifest.geometryDigest,
                trainerBuildDigest: manifest.trainerBuildDigest
            )
            let profile: String
            switch artifact.detailProfile {
            case .fast: profile = "fast"
            case .balanced: profile = "balanced"
            case .highDetail: profile = "high-detail"
            }
            try validate(
                checkpointURL: checkpointURL,
                receipt: receipt,
                expectation: MsplatCheckpointExpectation(
                    trainerVersion: artifact.trainerVersion,
                    trainerBuildDigest: artifact.trainerBuildDigest,
                    profile: profile,
                    iterationLimit: artifact.iterationLimit,
                    plateauWindow: artifact.plateauWindow,
                    seed: artifact.deterministicSeed,
                    cameraCount: manifest.cameraCount,
                    inputDigest: artifact.inputDigest,
                    geometryDigest: artifact.geometryDigest,
                    memoryBudgetBytes: artifact.memoryBudgetBytes
                )
            )
            guard receipt.iteration >= artifact.completedIteration,
                  receipt.rasterFallbackCount >= artifact.rasterFallbackCount,
                  receipt.rasterExactFallbackElapsedSeconds
                      >= artifact.rasterExactFallbackElapsedSeconds,
                  receipt.rasterExactBufferGrowthCount
                      >= artifact.rasterExactBufferGrowthCount,
                  receipt.rasterExactBufferBytesAdded >= artifact.rasterExactBufferBytesAdded,
                  receipt.rasterReplayElapsedSeconds >= artifact.rasterReplayElapsedSeconds,
                  receipt.rasterPeakExactIntersectionCapacity
                      >= artifact.rasterPeakExactIntersectionCapacity,
                  receipt.iteration != artifact.completedIteration
                    || (
                        receipt.payloadSHA256 == recordedPayloadDigest
                            && receipt.rasterFallbackCount == artifact.rasterFallbackCount
                            && receipt.rasterExactFallbackElapsedSeconds
                                == artifact.rasterExactFallbackElapsedSeconds
                            && receipt.rasterExactBufferGrowthCount
                                == artifact.rasterExactBufferGrowthCount
                            && receipt.rasterExactBufferBytesAdded
                                == artifact.rasterExactBufferBytesAdded
                            && receipt.rasterReplayElapsedSeconds
                                == artifact.rasterReplayElapsedSeconds
                            && receipt.rasterPeakExactIntersectionCapacity
                                == artifact.rasterPeakExactIntersectionCapacity
                    ) else {
                throw MsplatCheckpointValidationError("checkpoint is older than its training manifest")
            }
            return receipt
        } catch let error as MsplatCheckpointValidationError {
            throw error
        } catch {
            throw MsplatCheckpointValidationError(error.localizedDescription)
        }
    }

    private static func boundedData(from url: URL, maximumBytes: Int) throws -> Data {
        try BoundedFileReader.readRegularFile(at: url, maximumBytes: maximumBytes)
    }

    private static func requireDirectory(_ url: URL, name: String) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MsplatCheckpointValidationError("\(name) is missing or unsafe")
        }
    }

    private static func sha256(of url: URL, expectedBytes: Int64) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MsplatCheckpointValidationError("checkpoint payload could not be opened safely")
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size == expectedBytes else {
            throw MsplatCheckpointValidationError("checkpoint payload changed before hashing")
        }
        var hasher = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw MsplatCheckpointValidationError("checkpoint payload could not be read")
            }
            if count == 0 { break }
            consumed += Int64(count)
            guard consumed <= expectedBytes else {
                throw MsplatCheckpointValidationError("checkpoint payload grew while hashing")
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        guard consumed == expectedBytes else {
            throw MsplatCheckpointValidationError("checkpoint payload size changed while hashing")
        }
        return hasher.finalize().hexString
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isValidRasterFallbackCount(
        _ count: Int,
        through iteration: Int
    ) -> Bool {
        count >= 0 && count <= min(iteration, Int(UInt32.max))
    }

    private static func recoveryMetricsAreValid(
        fallbackCount: Int,
        exactFallbackElapsedSeconds: Double,
        exactBufferGrowthCount: Int,
        exactBufferBytesAdded: Int64,
        replayElapsedSeconds: Double,
        peakExactIntersectionCapacity: Int64,
        memoryBudgetBytes: Int64
    ) -> Bool {
        exactFallbackElapsedSeconds.isFinite
            && exactFallbackElapsedSeconds >= 0
            && exactBufferGrowthCount >= 0
            && exactBufferGrowthCount <= fallbackCount
            && exactBufferBytesAdded >= 0
            && replayElapsedSeconds.isFinite
            && replayElapsedSeconds >= 0
            && peakExactIntersectionCapacity >= 0
            && peakExactIntersectionCapacity <= Int64(UInt32.max)
            && memoryBudgetBytes > 0
            && (exactBufferBytesAdded == 0
                || 1 + ((exactBufferBytesAdded - 1) / memoryBudgetBytes)
                    <= Int64(exactBufferGrowthCount))
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

    private static func isGeneration(_ value: String) -> Bool {
        guard value.count == 73 else { return false }
        let bytes = Array(value.utf8)
        return bytes[8] == 45
            && bytes[0..<8].allSatisfy { (48...57).contains($0) }
            && bytes[9...].allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private struct Manifest: Decodable {
        let backingCapacity: Int
        let bestCameraLosses: [Double?]
        let cameraCount: Int
        let cameraDrawCount: Int
        let elapsedSeconds: Double
        let droppedIntersectionCount: Int
        let gaussianCount: Int
        let geometryDigest: String
        let inputDigest: String
        let iteration: Int
        let iterationLimit: Int
        let lastImprovementIteration: Int
        let latestLoss: Double?
        let latestLossIteration: Int
        let memoryBudgetBytes: Int64
        let payloadBytes: Int64
        let payloadFile: String
        let payloadSchema: Int
        let payloadSHA256: String
        let plateauWindow: Int
        let profile: String
        let rasterExactBufferBytesAdded: Int64
        let rasterExactBufferGrowthCount: Int
        let rasterExactFallbackElapsedSeconds: Double
        let rasterFallbackCount: Int
        let rasterPeakExactIntersectionCapacity: Int64
        let rasterReplayElapsedSeconds: Double
        let schemaVersion: Int
        let seed: UInt64
        let trainerBuildDigest: String
        let trainerVersion: String

        enum CodingKeys: String, CodingKey {
            case backingCapacity = "backing_capacity"
            case bestCameraLosses = "best_camera_losses"
            case cameraCount = "camera_count"
            case cameraDrawCount = "camera_draw_count"
            case elapsedSeconds = "elapsed_seconds"
            case droppedIntersectionCount = "dropped_intersection_count"
            case gaussianCount = "gaussian_count"
            case geometryDigest = "geometry_digest"
            case inputDigest = "input_digest"
            case iteration
            case iterationLimit = "iteration_limit"
            case lastImprovementIteration = "last_improvement_iteration"
            case latestLoss = "latest_loss"
            case latestLossIteration = "latest_loss_iteration"
            case memoryBudgetBytes = "memory_budget_bytes"
            case payloadBytes = "payload_bytes"
            case payloadFile = "payload_file"
            case payloadSchema = "payload_schema"
            case payloadSHA256 = "payload_sha256"
            case plateauWindow = "plateau_window"
            case profile
            case rasterExactBufferBytesAdded = "raster_exact_buffer_bytes_added"
            case rasterExactBufferGrowthCount = "raster_exact_buffer_growth_count"
            case rasterExactFallbackElapsedSeconds = "raster_exact_fallback_elapsed_seconds"
            case rasterFallbackCount = "raster_fallback_count"
            case rasterPeakExactIntersectionCapacity = "raster_peak_exact_intersection_capacity"
            case rasterReplayElapsedSeconds = "raster_replay_elapsed_seconds"
            case schemaVersion = "schema_version"
            case seed
            case trainerBuildDigest = "trainer_build_digest"
            case trainerVersion = "trainer_version"
        }
    }
}

struct MsplatCheckpointValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        "Native trainer checkpoint validation failed: \(message)"
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
