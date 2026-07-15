import Foundation

public enum TrainingCompletionStatus: String, Codable, Sendable, Equatable {
    case checkpointed
    case completed
}

public struct ScenePoint3D: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

public struct SplatSceneBounds: Codable, Sendable, Equatable {
    public var center: ScenePoint3D
    public var radius: Double

    public init(center: ScenePoint3D, radius: Double) {
        self.center = center
        self.radius = radius
    }

    var isValid: Bool {
        center.isFinite && radius.isFinite && radius > 0
    }
}

public struct TrainingArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 4

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
    public var rasterExactFallbackElapsedSeconds: Double
    public var rasterExactBufferGrowthCount: Int
    public var rasterExactBufferBytesAdded: Int64
    public var rasterReplayElapsedSeconds: Double
    public var rasterPeakExactIntersectionCapacity: Int64
    public var droppedIntersectionCount: Int
    public var sceneBounds: SplatSceneBounds?
    public var completionStatus: TrainingCompletionStatus

    public init(
        schemaVersion: Int = currentSchemaVersion,
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
        rasterExactFallbackElapsedSeconds: Double,
        rasterExactBufferGrowthCount: Int,
        rasterExactBufferBytesAdded: Int64,
        rasterReplayElapsedSeconds: Double,
        rasterPeakExactIntersectionCapacity: Int64,
        droppedIntersectionCount: Int,
        sceneBounds: SplatSceneBounds? = nil,
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
        self.rasterExactFallbackElapsedSeconds = rasterExactFallbackElapsedSeconds
        self.rasterExactBufferGrowthCount = rasterExactBufferGrowthCount
        self.rasterExactBufferBytesAdded = rasterExactBufferBytesAdded
        self.rasterReplayElapsedSeconds = rasterReplayElapsedSeconds
        self.rasterPeakExactIntersectionCapacity = rasterPeakExactIntersectionCapacity
        self.droppedIntersectionCount = droppedIntersectionCount
        self.sceneBounds = sceneBounds
        self.completionStatus = completionStatus
    }

}
