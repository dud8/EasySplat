import Foundation

public enum TrainingCompletionStatus: String, Codable, Sendable, Equatable {
    case checkpointed
    case completed
}

public enum MsplatDatasetPreparationKind: String, Codable, Sendable, Equatable {
    case direct
    case undistorted
}

public struct MsplatDatasetDerivationArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sourceGeometryManifestSHA256: String
    public var sourceSelectedFramesDigest: String
    public var preparationKind: MsplatDatasetPreparationKind
    public var maximumImageDimension: Int
    public var toolchainVersion: String
    public var colmapProvenance: GeometryComponentProvenance
    public var registeredImageNames: [String]
    public var datasetInputDigest: String
    public var datasetGeometryDigest: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sourceGeometryManifestSHA256: String,
        sourceSelectedFramesDigest: String,
        preparationKind: MsplatDatasetPreparationKind,
        maximumImageDimension: Int,
        toolchainVersion: String,
        colmapProvenance: GeometryComponentProvenance,
        registeredImageNames: [String],
        datasetInputDigest: String,
        datasetGeometryDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.sourceGeometryManifestSHA256 = sourceGeometryManifestSHA256
        self.sourceSelectedFramesDigest = sourceSelectedFramesDigest
        self.preparationKind = preparationKind
        self.maximumImageDimension = maximumImageDimension
        self.toolchainVersion = toolchainVersion
        self.colmapProvenance = colmapProvenance
        self.registeredImageNames = registeredImageNames
        self.datasetInputDigest = datasetInputDigest
        self.datasetGeometryDigest = datasetGeometryDigest
    }
}

struct PreparedMsplatDataset: Sendable, Equatable {
    let url: URL
    let identity: MsplatDatasetIdentity
    let derivation: MsplatDatasetDerivationArtifact
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
    public static let currentSchemaVersion = 7

    public var schemaVersion: Int
    public var trainerVersion: String
    public var runtimeVersion: String
    public var trainerBuildDigest: String
    public var inputDigest: String
    public var geometryDigest: String
    public var datasetDerivation: MsplatDatasetDerivationArtifact
    public var detailProfile: DetailProfile
    public var iterationLimit: Int
    public var plateauWindow: Int
    public var cameraOrderSeed: UInt64
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
    public var resourceAdmission: TrainingResourceAdmission
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
        datasetDerivation: MsplatDatasetDerivationArtifact,
        detailProfile: DetailProfile,
        iterationLimit: Int,
        plateauWindow: Int,
        cameraOrderSeed: UInt64,
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
        resourceAdmission: TrainingResourceAdmission,
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
        self.datasetDerivation = datasetDerivation
        self.detailProfile = detailProfile
        self.iterationLimit = iterationLimit
        self.plateauWindow = plateauWindow
        self.cameraOrderSeed = cameraOrderSeed
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
        self.resourceAdmission = resourceAdmission
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

    func matchesResolvedTrainingPlan(
        _ plan: ResolvedRunPlan,
        resourcePolicy: ResourcePolicy
    ) -> Bool {
        iterationLimit == plan.trainerIterationLimit
            && plateauWindow == plan.plateauWindow
            && memoryBudgetBytes > 0
            && memoryBudgetBytes <= plan.trainerMemoryBudgetBytes
            && cameraOrderSeed == plan.runSeed
            && resourceAdmission.resourcePolicy == resourcePolicy
    }
}
