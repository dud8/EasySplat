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

public enum PairGraphMeasurementStatus: String, Codable, Sendable, Equatable {
    case notEvaluated
    case measured
}

public enum DescriptorMatcher: String, Codable, Sendable, Equatable {
    case faiss
    case exact
}

public enum PairGraphRecoveryLevel: String, Codable, Sendable, Equatable {
    case normal
    case expanded
    case maximum
}

public enum PairMatchingAttemptOutcome: String, Codable, Sendable, Equatable {
    case completed
    case failed
}

public struct PairMatchingAttemptArtifact: Codable, Sendable, Equatable {
    public var attemptNumber: Int
    public var matcher: DescriptorMatcher
    public var recoveryLevel: PairGraphRecoveryLevel
    public var outcome: PairMatchingAttemptOutcome
    public var scheduledPairCount: Int
    public var attemptedPairCount: Int
    public var rawMatchedPairCount: Int
    public var spatiallyVerifiedPairCount: Int
    public var durationSeconds: Double

    public init(
        attemptNumber: Int,
        matcher: DescriptorMatcher,
        recoveryLevel: PairGraphRecoveryLevel,
        outcome: PairMatchingAttemptOutcome,
        scheduledPairCount: Int,
        attemptedPairCount: Int,
        rawMatchedPairCount: Int,
        spatiallyVerifiedPairCount: Int,
        durationSeconds: Double
    ) {
        self.attemptNumber = attemptNumber
        self.matcher = matcher
        self.recoveryLevel = recoveryLevel
        self.outcome = outcome
        self.scheduledPairCount = scheduledPairCount
        self.attemptedPairCount = attemptedPairCount
        self.rawMatchedPairCount = rawMatchedPairCount
        self.spatiallyVerifiedPairCount = spatiallyVerifiedPairCount
        self.durationSeconds = durationSeconds
    }
}

public struct PairGraphMeasurement: Codable, Sendable, Equatable {
    public var scheduledPairCount: Int
    public var attemptedPairCount: Int
    public var rawMatchedPairCount: Int
    public var spatiallyVerifiedPairCount: Int
    public var localPairCount: Int
    public var retrievalPairCount: Int
    public var loopRevisitPairCount: Int
    public var connectedComponentCount: Int
    public var isolatedViewCount: Int
    public var degreeP10: Int
    public var degreeMedian: Int
    public var degreeP90: Int
    public var matcherAttempts: [PairMatchingAttemptArtifact]
    public var pairListDigest: String
    public var featureDatabaseDigest: String
    public var matchingDatabaseDigest: String
    public var matchingDurationSeconds: Double

    public init(
        scheduledPairCount: Int,
        attemptedPairCount: Int,
        rawMatchedPairCount: Int,
        spatiallyVerifiedPairCount: Int,
        localPairCount: Int,
        retrievalPairCount: Int,
        loopRevisitPairCount: Int,
        connectedComponentCount: Int,
        isolatedViewCount: Int,
        degreeP10: Int,
        degreeMedian: Int,
        degreeP90: Int,
        matcherAttempts: [PairMatchingAttemptArtifact],
        pairListDigest: String,
        featureDatabaseDigest: String,
        matchingDatabaseDigest: String,
        matchingDurationSeconds: Double
    ) {
        self.scheduledPairCount = scheduledPairCount
        self.attemptedPairCount = attemptedPairCount
        self.rawMatchedPairCount = rawMatchedPairCount
        self.spatiallyVerifiedPairCount = spatiallyVerifiedPairCount
        self.localPairCount = localPairCount
        self.retrievalPairCount = retrievalPairCount
        self.loopRevisitPairCount = loopRevisitPairCount
        self.connectedComponentCount = connectedComponentCount
        self.isolatedViewCount = isolatedViewCount
        self.degreeP10 = degreeP10
        self.degreeMedian = degreeMedian
        self.degreeP90 = degreeP90
        self.matcherAttempts = matcherAttempts
        self.pairListDigest = pairListDigest
        self.featureDatabaseDigest = featureDatabaseDigest
        self.matchingDatabaseDigest = matchingDatabaseDigest
        self.matchingDurationSeconds = matchingDurationSeconds
    }
}

public struct PairGraphArtifact: Codable, Sendable, Equatable {
    public var status: PairGraphMeasurementStatus
    public var measurement: PairGraphMeasurement?
    public var mappingAttemptNumber: Int
    public var bundleAdjustmentCycleCount: Int
    public var fallbackReason: String?

    public init(
        status: PairGraphMeasurementStatus,
        measurement: PairGraphMeasurement?,
        mappingAttemptNumber: Int,
        bundleAdjustmentCycleCount: Int,
        fallbackReason: String?
    ) {
        self.status = status
        self.measurement = measurement
        self.mappingAttemptNumber = mappingAttemptNumber
        self.bundleAdjustmentCycleCount = bundleAdjustmentCycleCount
        self.fallbackReason = fallbackReason
    }

    public static func notEvaluated(
        mappingAttemptNumber: Int,
        bundleAdjustmentCycleCount: Int,
        fallbackReason: String?
    ) -> PairGraphArtifact {
        PairGraphArtifact(
            status: .notEvaluated,
            measurement: nil,
            mappingAttemptNumber: mappingAttemptNumber,
            bundleAdjustmentCycleCount: bundleAdjustmentCycleCount,
            fallbackReason: fallbackReason
        )
    }

    public static func measured(
        _ measurement: PairGraphMeasurement,
        mappingAttemptNumber: Int,
        bundleAdjustmentCycleCount: Int,
        fallbackReason: String?
    ) -> PairGraphArtifact {
        PairGraphArtifact(
            status: .measured,
            measurement: measurement,
            mappingAttemptNumber: mappingAttemptNumber,
            bundleAdjustmentCycleCount: bundleAdjustmentCycleCount,
            fallbackReason: fallbackReason
        )
    }
}

public enum CanonicalOrientationStatus: String, Codable, Sendable, Equatable {
    case verified
    case axisAlignedSignUnverified
    case unresolved
}

public enum CanonicalOrientationMethod: String, Codable, Sendable, Equatable {
    case cameraRightNullspace
    case cameraUpConsensus
}

public struct CanonicalQuaternionWXYZ: Codable, Sendable, Equatable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct CanonicalDirection: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct CanonicalOrientationEvidence: Codable, Sendable, Equatable {
    public var supportCount: Int
    /// Ascending, trace-normalized eigenvalues of the camera-right scatter matrix.
    public var eigenvalue0: Double
    public var eigenvalue1: Double
    public var eigenvalue2: Double
    /// `eigenvalue1 / max(eigenvalue0, 1e-9)`.
    public var eigengap: Double
    public var medianResidualDegrees: Double
    public var p90ResidualDegrees: Double
    public var medianAbsoluteImageUpAgreement: Double?
    public var signAgreement: Double?
    public var bootstrapP95VariationDegrees: Double
    public var trajectoryPlaneAgreementDegrees: Double?
    public var trajectoryLineConcentration: Double?
    public var cameraUpConcentration: Double?
    public var cameraUpMedianSpreadDegrees: Double?
    public var cameraUpP90SpreadDegrees: Double?

    public init(
        supportCount: Int,
        eigenvalue0: Double,
        eigenvalue1: Double,
        eigenvalue2: Double,
        eigengap: Double,
        medianResidualDegrees: Double,
        p90ResidualDegrees: Double,
        medianAbsoluteImageUpAgreement: Double?,
        signAgreement: Double?,
        bootstrapP95VariationDegrees: Double,
        trajectoryPlaneAgreementDegrees: Double?,
        trajectoryLineConcentration: Double? = nil,
        cameraUpConcentration: Double? = nil,
        cameraUpMedianSpreadDegrees: Double? = nil,
        cameraUpP90SpreadDegrees: Double? = nil
    ) {
        self.supportCount = supportCount
        self.eigenvalue0 = eigenvalue0
        self.eigenvalue1 = eigenvalue1
        self.eigenvalue2 = eigenvalue2
        self.eigengap = eigengap
        self.medianResidualDegrees = medianResidualDegrees
        self.p90ResidualDegrees = p90ResidualDegrees
        self.medianAbsoluteImageUpAgreement = medianAbsoluteImageUpAgreement
        self.signAgreement = signAgreement
        self.bootstrapP95VariationDegrees = bootstrapP95VariationDegrees
        self.trajectoryPlaneAgreementDegrees = trajectoryPlaneAgreementDegrees
        self.trajectoryLineConcentration = trajectoryLineConcentration
        self.cameraUpConcentration = cameraUpConcentration
        self.cameraUpMedianSpreadDegrees = cameraUpMedianSpreadDegrees
        self.cameraUpP90SpreadDegrees = cameraUpP90SpreadDegrees
    }
}

public struct CanonicalOrientationArtifact: Codable, Sendable, Equatable {
    public var status: CanonicalOrientationStatus
    public var method: CanonicalOrientationMethod?
    /// Proper source-to-canonical rotation. Component order is fixed by the type name.
    public var sourceToCanonicalQuaternionWXYZ: CanonicalQuaternionWXYZ?
    public var evidence: CanonicalOrientationEvidence?
    /// Camera-forward direction from the opening eye position toward the scene.
    public var canonicalOpeningViewDirection: CanonicalDirection?
    public var isViewOnlyFlipActive: Bool

    public init(
        status: CanonicalOrientationStatus,
        method: CanonicalOrientationMethod?,
        sourceToCanonicalQuaternionWXYZ: CanonicalQuaternionWXYZ?,
        evidence: CanonicalOrientationEvidence?,
        canonicalOpeningViewDirection: CanonicalDirection?,
        isViewOnlyFlipActive: Bool
    ) {
        self.status = status
        self.method = method
        self.sourceToCanonicalQuaternionWXYZ = sourceToCanonicalQuaternionWXYZ
        self.evidence = evidence
        self.canonicalOpeningViewDirection = canonicalOpeningViewDirection
        self.isViewOnlyFlipActive = isViewOnlyFlipActive
    }

    public static func unresolved(openingViewDirection: CanonicalDirection) -> Self {
        Self(
            status: .unresolved,
            method: nil,
            sourceToCanonicalQuaternionWXYZ: nil,
            evidence: nil,
            canonicalOpeningViewDirection: openingViewDirection,
            isViewOnlyFlipActive: false
        )
    }
}

public struct GeometryArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var solverVersion: String
    public var runtimeVersion: String
    public var modelVersion: String
    public var inputDigest: String
    public var selectedFramesDigest: String
    public var orderedImageNames: [String]
    public var orderedImageTimestamps: [Double?]
    /// Accepted source-frame COLMAP model. `canonicalOrientation` is applied by
    /// the trainer without rewriting this measured geometry.
    public var sourceModelPath: String
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
    public var pairGraph: PairGraphArtifact
    public var canonicalOrientation: CanonicalOrientationArtifact

    public init(
        schemaVersion: Int,
        solverVersion: String,
        runtimeVersion: String,
        modelVersion: String,
        inputDigest: String,
        selectedFramesDigest: String,
        orderedImageNames: [String],
        orderedImageTimestamps: [Double?],
        sourceModelPath: String,
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
        pairGraph: PairGraphArtifact,
        learnedPointInitializer: LearnedPointInitializerArtifact? = nil,
        canonicalOrientation: CanonicalOrientationArtifact
    ) {
        self.schemaVersion = schemaVersion
        self.solverVersion = solverVersion
        self.runtimeVersion = runtimeVersion
        self.modelVersion = modelVersion
        self.inputDigest = inputDigest
        self.selectedFramesDigest = selectedFramesDigest
        self.orderedImageNames = orderedImageNames
        self.orderedImageTimestamps = orderedImageTimestamps
        self.sourceModelPath = sourceModelPath
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
        self.pairGraph = pairGraph
        self.canonicalOrientation = canonicalOrientation
    }
}
