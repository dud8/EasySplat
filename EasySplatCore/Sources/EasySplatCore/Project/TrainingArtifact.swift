import Foundation

public enum TrainingCompletionStatus: String, Codable, Sendable, Equatable {
    case checkpointed
    case completed
}

public struct TrainingArtifact: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var trainerVersion: String
    public var runtimeVersion: String
    public var trainerBuildDigest: String
    public var inputDigest: String
    public var geometryDigest: String
    public var detailProfile: DetailProfile
    public var iterationLimit: Int
    public var plateauWindow: Int
    public var deterministicSeed: UInt64
    public var completedIteration: Int
    public var checkpointPath: String?
    public var checkpointDigest: String?
    public var outputPath: String?
    public var gaussianCount: Int
    public var elapsedSeconds: Double?
    public var peakMemoryBytes: Int64?
    public var completionStatus: TrainingCompletionStatus

    public init(
        schemaVersion: Int = 1,
        trainerVersion: String,
        runtimeVersion: String,
        trainerBuildDigest: String,
        inputDigest: String,
        geometryDigest: String,
        detailProfile: DetailProfile,
        iterationLimit: Int,
        plateauWindow: Int,
        deterministicSeed: UInt64,
        completedIteration: Int,
        checkpointPath: String?,
        checkpointDigest: String?,
        outputPath: String?,
        gaussianCount: Int,
        elapsedSeconds: Double?,
        peakMemoryBytes: Int64?,
        completionStatus: TrainingCompletionStatus
    ) {
        self.schemaVersion = schemaVersion
        self.trainerVersion = trainerVersion
        self.runtimeVersion = runtimeVersion
        self.trainerBuildDigest = trainerBuildDigest
        self.inputDigest = inputDigest
        self.geometryDigest = geometryDigest
        self.detailProfile = detailProfile
        self.iterationLimit = iterationLimit
        self.plateauWindow = plateauWindow
        self.deterministicSeed = deterministicSeed
        self.completedIteration = completedIteration
        self.checkpointPath = checkpointPath
        self.checkpointDigest = checkpointDigest
        self.outputPath = outputPath
        self.gaussianCount = gaussianCount
        self.elapsedSeconds = elapsedSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.completionStatus = completionStatus
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        trainerVersion = try values.decode(String.self, forKey: .trainerVersion)
        runtimeVersion = try values.decode(String.self, forKey: .runtimeVersion)
        trainerBuildDigest = try values.decodeIfPresent(String.self, forKey: .trainerBuildDigest)
            ?? (Self.looksLikeSHA256(runtimeVersion) ? runtimeVersion : "")
        inputDigest = try values.decodeIfPresent(String.self, forKey: .inputDigest) ?? ""
        geometryDigest = try values.decode(String.self, forKey: .geometryDigest)
        detailProfile = try values.decode(DetailProfile.self, forKey: .detailProfile)
        iterationLimit = try values.decode(Int.self, forKey: .iterationLimit)
        plateauWindow = try values.decode(Int.self, forKey: .plateauWindow)
        deterministicSeed = try values.decode(UInt64.self, forKey: .deterministicSeed)
        completedIteration = try values.decodeIfPresent(Int.self, forKey: .completedIteration) ?? 0
        checkpointPath = try values.decodeIfPresent(String.self, forKey: .checkpointPath)
        checkpointDigest = try values.decodeIfPresent(String.self, forKey: .checkpointDigest)
        outputPath = try values.decodeIfPresent(String.self, forKey: .outputPath)
        gaussianCount = try values.decode(Int.self, forKey: .gaussianCount)
        elapsedSeconds = try values.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
        peakMemoryBytes = try values.decodeIfPresent(Int64.self, forKey: .peakMemoryBytes)
        completionStatus = try values.decode(TrainingCompletionStatus.self, forKey: .completionStatus)
    }

    private static func looksLikeSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
