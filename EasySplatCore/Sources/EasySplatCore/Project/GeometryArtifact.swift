import Foundation

public struct GeometryArtifact: Codable, Sendable, Equatable {
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
        fallbackReason: String?
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
    }
}
