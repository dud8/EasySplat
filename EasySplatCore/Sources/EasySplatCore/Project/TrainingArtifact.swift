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
    public var outputSHA256: String?
    public var outputBytes: Int64?
    public var gaussianCount: Int
    public var elapsedSeconds: Double?
    public var peakMemoryBytes: Int64
    public var memoryBudgetBytes: Int64
    public var rasterFallbackCount: Int
    public var droppedIntersectionCount: Int
    public var completionStatus: TrainingCompletionStatus

    public init(
        schemaVersion: Int = 2,
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
        outputSHA256: String? = nil,
        outputBytes: Int64? = nil,
        gaussianCount: Int,
        elapsedSeconds: Double?,
        peakMemoryBytes: Int64,
        memoryBudgetBytes: Int64,
        rasterFallbackCount: Int,
        droppedIntersectionCount: Int,
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
        self.outputSHA256 = outputSHA256
        self.outputBytes = outputBytes
        self.gaussianCount = gaussianCount
        self.elapsedSeconds = elapsedSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.memoryBudgetBytes = memoryBudgetBytes
        self.rasterFallbackCount = rasterFallbackCount
        self.droppedIntersectionCount = droppedIntersectionCount
        self.completionStatus = completionStatus
    }

}
