import Foundation

public struct ResolvedRunPlan: Codable, Sendable, Equatable {
    public var routeIdentifier: String
    public var modelIdentifier: String
    public var memoryTier: String
    public var chunkSize: Int
    public var keyframeBudget: Int
    public var maximumImageDimension: Int
    public var cameraGrouping: CameraGrouping
    public var lensProjection: LensProjection
    public var refinementIterationLimit: Int
    public var trainerIterationLimit: Int
    public var plateauWindow: Int
    public var requiredToolchainCapabilities: [String]
    public var fallbackRouteIdentifiers: [String]

    public init(
        routeIdentifier: String,
        modelIdentifier: String,
        memoryTier: String,
        chunkSize: Int,
        keyframeBudget: Int,
        maximumImageDimension: Int,
        cameraGrouping: CameraGrouping,
        lensProjection: LensProjection,
        refinementIterationLimit: Int,
        trainerIterationLimit: Int,
        plateauWindow: Int,
        requiredToolchainCapabilities: [String],
        fallbackRouteIdentifiers: [String]
    ) {
        self.routeIdentifier = routeIdentifier
        self.modelIdentifier = modelIdentifier
        self.memoryTier = memoryTier
        self.chunkSize = chunkSize
        self.keyframeBudget = keyframeBudget
        self.maximumImageDimension = maximumImageDimension
        self.cameraGrouping = cameraGrouping
        self.lensProjection = lensProjection
        self.refinementIterationLimit = refinementIterationLimit
        self.trainerIterationLimit = trainerIterationLimit
        self.plateauWindow = plateauWindow
        self.requiredToolchainCapabilities = requiredToolchainCapabilities
        self.fallbackRouteIdentifiers = fallbackRouteIdentifiers
    }
}
