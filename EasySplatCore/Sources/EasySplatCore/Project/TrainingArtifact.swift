import Foundation

public struct TrainingArtifact: Codable, Sendable, Equatable {
    public var trainerVersion: String
    public var runtimeVersion: String
    public var geometryDigest: String
    public var detailProfile: DetailProfile
    public var iterationLimit: Int
    public var plateauWindow: Int
    public var deterministicSeed: UInt64
    public var checkpointPath: String?
    public var outputPath: String?
    public var gaussianCount: Int
    public var elapsedSeconds: Double
    public var peakMemoryBytes: Int64
    public var completionStatus: String

    public init(
        trainerVersion: String,
        runtimeVersion: String,
        geometryDigest: String,
        detailProfile: DetailProfile,
        iterationLimit: Int,
        plateauWindow: Int,
        deterministicSeed: UInt64,
        checkpointPath: String?,
        outputPath: String?,
        gaussianCount: Int,
        elapsedSeconds: Double,
        peakMemoryBytes: Int64,
        completionStatus: String
    ) {
        self.trainerVersion = trainerVersion
        self.runtimeVersion = runtimeVersion
        self.geometryDigest = geometryDigest
        self.detailProfile = detailProfile
        self.iterationLimit = iterationLimit
        self.plateauWindow = plateauWindow
        self.deterministicSeed = deterministicSeed
        self.checkpointPath = checkpointPath
        self.outputPath = outputPath
        self.gaussianCount = gaussianCount
        self.elapsedSeconds = elapsedSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.completionStatus = completionStatus
    }
}
