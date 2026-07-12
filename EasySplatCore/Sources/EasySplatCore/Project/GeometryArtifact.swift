import Foundation

public struct GeometryComponentProvenance: Codable, Sendable, Equatable {
    public var identifier: String
    public var version: String
    public var revision: String
    public var payloadSHA256: String

    public init(
        identifier: String,
        version: String,
        revision: String,
        payloadSHA256: String
    ) {
        self.identifier = identifier
        self.version = version
        self.revision = revision
        self.payloadSHA256 = payloadSHA256
    }
}

public struct GeometryProvenance: Codable, Sendable, Equatable {
    public var toolchainVersion: String
    public var solver: GeometryComponentProvenance
    public var runtime: GeometryComponentProvenance?
    public var model: GeometryComponentProvenance?

    public init(
        toolchainVersion: String,
        solver: GeometryComponentProvenance,
        runtime: GeometryComponentProvenance?,
        model: GeometryComponentProvenance?
    ) {
        self.toolchainVersion = toolchainVersion
        self.solver = solver
        self.runtime = runtime
        self.model = model
    }
}

public struct LearnedPointInitializerArtifact: Codable, Sendable, Equatable {
    public var path: String
    public var sha256: String
    public var pointCount: Int

    public init(path: String, sha256: String, pointCount: Int) {
        self.path = path
        self.sha256 = sha256
        self.pointCount = pointCount
    }
}

public struct GeometryArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var solverVersion: String
    public var runtimeVersion: String
    public var modelVersion: String
    public var inputDigest: String
    public var selectedFramesDigest: String
    public var orderedImageNames: [String]
    public var orderedImageTimestamps: [Double?]
    public var canonicalModelPath: String
    /// Describes whether persisted poses transform world-to-camera or camera-to-world.
    public var poseConvention: String
    /// Component order used by every persisted quaternion, such as `wxyz`.
    public var quaternionOrder: String
    public var handedness: String
    public var scaleType: String
    public var cameraModel: String
    public var cameraGrouping: CameraGrouping
    public var registeredViewCount: Int
    public var totalViewCount: Int
    public var trackCount: Int
    public var pointCount: Int
    public var residualProvenance: String
    public var medianPixelResidual: Double
    public var p90PixelResidual: Double
    public var timings: [String: Double]
    public var peakMemoryBytes: Int64
    public var modelHashes: [String: String]
    public var fallbackReason: String?
    public var provenance: GeometryProvenance
    public var learnedPointInitializer: LearnedPointInitializerArtifact?

    public init(
        schemaVersion: Int,
        solverVersion: String,
        runtimeVersion: String,
        modelVersion: String,
        inputDigest: String,
        selectedFramesDigest: String,
        orderedImageNames: [String],
        orderedImageTimestamps: [Double?],
        canonicalModelPath: String,
        poseConvention: String,
        quaternionOrder: String,
        handedness: String,
        scaleType: String,
        cameraModel: String,
        cameraGrouping: CameraGrouping,
        registeredViewCount: Int,
        totalViewCount: Int,
        trackCount: Int,
        pointCount: Int,
        residualProvenance: String,
        medianPixelResidual: Double,
        p90PixelResidual: Double,
        timings: [String: Double],
        peakMemoryBytes: Int64,
        modelHashes: [String: String],
        fallbackReason: String?,
        provenance: GeometryProvenance,
        learnedPointInitializer: LearnedPointInitializerArtifact? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.solverVersion = solverVersion
        self.runtimeVersion = runtimeVersion
        self.modelVersion = modelVersion
        self.inputDigest = inputDigest
        self.selectedFramesDigest = selectedFramesDigest
        self.orderedImageNames = orderedImageNames
        self.orderedImageTimestamps = orderedImageTimestamps
        self.canonicalModelPath = canonicalModelPath
        self.poseConvention = poseConvention
        self.quaternionOrder = quaternionOrder
        self.handedness = handedness
        self.scaleType = scaleType
        self.cameraModel = cameraModel
        self.cameraGrouping = cameraGrouping
        self.registeredViewCount = registeredViewCount
        self.totalViewCount = totalViewCount
        self.trackCount = trackCount
        self.pointCount = pointCount
        self.residualProvenance = residualProvenance
        self.medianPixelResidual = medianPixelResidual
        self.p90PixelResidual = p90PixelResidual
        self.timings = timings
        self.peakMemoryBytes = peakMemoryBytes
        self.modelHashes = modelHashes
        self.fallbackReason = fallbackReason
        self.provenance = provenance
        self.learnedPointInitializer = learnedPointInitializer
    }
}
