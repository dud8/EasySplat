import CryptoKit
import Foundation

public struct ColmapRuntimeClosureEvidence: Codable, Sendable, Equatable {
    public struct Component: Codable, Sendable, Equatable {
        public var toolchainRelativePath: String
        public var sha256: String

        public init(toolchainRelativePath: String, sha256: String) {
            self.toolchainRelativePath = toolchainRelativePath
            self.sha256 = sha256
        }
    }

    public static let canonicalToolchainRelativePaths = [
        "bin/colmap",
        "lib/libomp.dylib",
    ]

    public var components: [Component]
    public var closureSHA256: String

    public init(components: [Component], closureSHA256: String) {
        self.components = components
        self.closureSHA256 = closureSHA256
    }

    public static func canonical(
        executableSHA256: String,
        openMPSHA256: String
    ) -> Self? {
        let components = [
            Component(toolchainRelativePath: "bin/colmap", sha256: executableSHA256),
            Component(toolchainRelativePath: "lib/libomp.dylib", sha256: openMPSHA256),
        ]
        guard let closureSHA256 = closureDigest(for: components) else { return nil }
        return Self(components: components, closureSHA256: closureSHA256)
    }

    public static func closureDigest(for components: [Component]) -> String? {
        guard components.map(\.toolchainRelativePath) == canonicalToolchainRelativePaths,
              components.allSatisfy({ GeometryArtifactStore.isSHA256($0.sha256) }) else {
            return nil
        }
        var hasher = SHA256()
        func update(_ data: Data) {
            var byteCount = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &byteCount) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        update(Data("easysplat-colmap-runtime-closure-v1".utf8))
        for component in components {
            update(Data(component.toolchainRelativePath.utf8))
            update(Data(component.sha256.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var isValid: Bool {
        Self.closureDigest(for: components) == closureSHA256
    }

    public func sha256(for toolchainRelativePath: String) -> String? {
        components.first {
            $0.toolchainRelativePath == toolchainRelativePath
        }?.sha256
    }
}

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
    case rejected
    case failed
}

public struct PairMatchingAttemptArtifact: Codable, Sendable, Equatable {
    public var attemptNumber: Int
    public var matcher: DescriptorMatcher
    public var recoveryLevel: PairGraphRecoveryLevel
    public var outcome: PairMatchingAttemptOutcome
    public var exactRecoveryReason: DescriptorMatcherRecoveryReason?
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
        exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil,
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
        self.exactRecoveryReason = exactRecoveryReason
        self.scheduledPairCount = scheduledPairCount
        self.attemptedPairCount = attemptedPairCount
        self.rawMatchedPairCount = rawMatchedPairCount
        self.spatiallyVerifiedPairCount = spatiallyVerifiedPairCount
        self.durationSeconds = durationSeconds
    }
}

public struct PairGraphMeasurement: Codable, Sendable, Equatable {
    public var pairingPolicy: ResolvedPairingPolicy
    public var scheduledPairCount: Int
    public var attemptedPairCount: Int
    public var rawMatchedPairCount: Int
    public var spatiallyVerifiedPairCount: Int
    public var localPairCount: Int
    public var retrievalPairCount: Int
    public var loopRevisitPairCount: Int
    public var connectedComponentCount: Int
    public var isolatedViewCount: Int
    public var descriptorlessViewCount: Int
    public var componentViewCounts: [Int]
    public var articulationViewCount: Int
    public var biconnectedBlockCount: Int
    public var largestBiconnectedBlockViewCount: Int
    public var secondLargestBiconnectedBlockViewCount: Int
    public var degreeP10: Int
    public var degreeMedian: Int
    public var degreeP90: Int
    public var matcherAttempts: [PairMatchingAttemptArtifact]
    public var pairListDigest: String
    public var featureDatabaseDigest: String
    public var matchingDatabaseDigest: String
    public var matchingDurationSeconds: Double

    public init(
        pairingPolicy: ResolvedPairingPolicy = .unorderedRetrieval,
        scheduledPairCount: Int,
        attemptedPairCount: Int,
        rawMatchedPairCount: Int,
        spatiallyVerifiedPairCount: Int,
        localPairCount: Int,
        retrievalPairCount: Int,
        loopRevisitPairCount: Int,
        connectedComponentCount: Int,
        isolatedViewCount: Int,
        descriptorlessViewCount: Int = 0,
        componentViewCounts: [Int],
        articulationViewCount: Int,
        biconnectedBlockCount: Int,
        largestBiconnectedBlockViewCount: Int,
        secondLargestBiconnectedBlockViewCount: Int,
        degreeP10: Int,
        degreeMedian: Int,
        degreeP90: Int,
        matcherAttempts: [PairMatchingAttemptArtifact],
        pairListDigest: String,
        featureDatabaseDigest: String,
        matchingDatabaseDigest: String,
        matchingDurationSeconds: Double
    ) {
        self.pairingPolicy = pairingPolicy
        self.scheduledPairCount = scheduledPairCount
        self.attemptedPairCount = attemptedPairCount
        self.rawMatchedPairCount = rawMatchedPairCount
        self.spatiallyVerifiedPairCount = spatiallyVerifiedPairCount
        self.localPairCount = localPairCount
        self.retrievalPairCount = retrievalPairCount
        self.loopRevisitPairCount = loopRevisitPairCount
        self.connectedComponentCount = connectedComponentCount
        self.isolatedViewCount = isolatedViewCount
        self.descriptorlessViewCount = descriptorlessViewCount
        self.componentViewCounts = componentViewCounts
        self.articulationViewCount = articulationViewCount
        self.biconnectedBlockCount = biconnectedBlockCount
        self.largestBiconnectedBlockViewCount = largestBiconnectedBlockViewCount
        self.secondLargestBiconnectedBlockViewCount = secondLargestBiconnectedBlockViewCount
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
    public var requiresCrossClipRetrieval: Bool
    public var retrievalWasScheduled: Bool
    public var usedLocalVocabularyRetrieval: Bool

    public init(
        status: PairGraphMeasurementStatus,
        measurement: PairGraphMeasurement?,
        requiresCrossClipRetrieval: Bool = false,
        retrievalWasScheduled: Bool = false,
        usedLocalVocabularyRetrieval: Bool = false
    ) {
        self.status = status
        self.measurement = measurement
        self.requiresCrossClipRetrieval = requiresCrossClipRetrieval
        self.retrievalWasScheduled = retrievalWasScheduled
        self.usedLocalVocabularyRetrieval = usedLocalVocabularyRetrieval
    }

    public static func notEvaluated() -> PairGraphArtifact {
        PairGraphArtifact(
            status: .notEvaluated,
            measurement: nil,
            requiresCrossClipRetrieval: false,
            retrievalWasScheduled: false,
            usedLocalVocabularyRetrieval: false
        )
    }

    public static func measured(
        _ measurement: PairGraphMeasurement,
        requiresCrossClipRetrieval: Bool = false,
        retrievalWasScheduled: Bool = false,
        usedLocalVocabularyRetrieval: Bool = false
    ) -> PairGraphArtifact {
        PairGraphArtifact(
            status: .measured,
            measurement: measurement,
            requiresCrossClipRetrieval: requiresCrossClipRetrieval,
            retrievalWasScheduled: retrievalWasScheduled,
            usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval
        )
    }
}

enum PairGraphRetrievalScheduling {
    static func isRequired(
        pairingPolicy: ResolvedPairingPolicy,
        selectedFrameCount: Int,
        requiresCrossClipRetrieval: Bool
    ) -> Bool {
        if requiresCrossClipRetrieval {
            return true
        }
        switch pairingPolicy {
        case .orderedContinuous:
            return selectedFrameCount >= 120
        case .orderedOrbit, .orderedWalkthrough, .orderedLargeArea, .segmentedMixed:
            return true
        case .unorderedRetrieval:
            return selectedFrameCount > 60
        }
    }
}

public enum MappingRefinementKind: String, Codable, Sendable, Equatable {
    case incrementalGlobal
    case seededBundleAdjustment
}

public enum MappingCadenceFallbackTrigger: String, Codable, Sendable, Equatable {
    case insufficientViewSupport
    case collapsedCameraTrajectory
    case insufficientParallax
    case degeneratePointDistribution
    case lowReconstructionQuality
    case fragmentedReconstruction
    case lowRegisteredViewCoverage
    case sparseResidualCoverage
    case excessiveResiduals

    var diagnosticReason: String {
        switch self {
        case .insufficientViewSupport:
            return "mapping cadence retry after insufficient view support"
        case .collapsedCameraTrajectory:
            return "mapping cadence retry after collapsed camera motion"
        case .insufficientParallax:
            return "mapping cadence retry after insufficient parallax"
        case .degeneratePointDistribution:
            return "mapping cadence retry after degenerate scene structure"
        case .lowReconstructionQuality:
            return "mapping cadence retry after quality rejection"
        case .fragmentedReconstruction:
            return "mapping cadence retry after fragmented reconstruction"
        case .lowRegisteredViewCoverage:
            return "mapping cadence retry after low registered-view coverage"
        case .sparseResidualCoverage:
            return "mapping cadence retry after sparse residual coverage"
        case .excessiveResiduals:
            return "mapping cadence retry after excessive residuals"
        }
    }
}

public struct IncrementalMappingCadenceArtifact: Codable, Sendable, Equatable {
    public var localMaxRefinements: Int
    public var globalFramesRatio: Double
    public var globalPointsRatio: Double
    public var globalMaxRefinements: Int
    public var localMaxNumIterations: Int
    public var localFunctionTolerance: Double
    public var globalFunctionTolerance: Double
    public var localImageCount: Int

    public init(
        localMaxRefinements: Int,
        globalFramesRatio: Double,
        globalPointsRatio: Double,
        globalMaxRefinements: Int,
        localMaxNumIterations: Int = 10,
        localFunctionTolerance: Double = 0.001,
        globalFunctionTolerance: Double = 0.000_001,
        localImageCount: Int = 6
    ) {
        self.localMaxRefinements = localMaxRefinements
        self.globalFramesRatio = globalFramesRatio
        self.globalPointsRatio = globalPointsRatio
        self.globalMaxRefinements = globalMaxRefinements
        self.localMaxNumIterations = localMaxNumIterations
        self.localFunctionTolerance = localFunctionTolerance
        self.globalFunctionTolerance = globalFunctionTolerance
        self.localImageCount = localImageCount
    }

    public static let orderedFast = Self(
        localMaxRefinements: 1,
        globalFramesRatio: 4,
        globalPointsRatio: 4,
        globalMaxRefinements: 5
    )

    public static let balancedGlobal = Self(
        localMaxRefinements: 2,
        globalFramesRatio: 1.4,
        globalPointsRatio: 1.4,
        globalMaxRefinements: 5
    )

    public static let frequentGlobal = Self(
        localMaxRefinements: 2,
        globalFramesRatio: 1.1,
        globalPointsRatio: 1.1,
        globalMaxRefinements: 5
    )

    var isValid: Bool {
        localMaxRefinements > 0
            && globalFramesRatio.isFinite
            && globalFramesRatio > 1
            && globalPointsRatio.isFinite
            && globalPointsRatio > 1
            && globalMaxRefinements > 0
            && localMaxNumIterations > 0
            && localFunctionTolerance.isFinite
            && localFunctionTolerance > 0
            && globalFunctionTolerance.isFinite
            && globalFunctionTolerance > 0
            && localImageCount > 0
    }
}

enum IncrementalMappingCadencePolicy {
    static func isRecognized(_ cadence: IncrementalMappingCadenceArtifact) -> Bool {
        cadence == .orderedFast
            || cadence == .balancedGlobal
            || cadence == .frequentGlobal
    }

    static func fallbackCadence(
        planned: IncrementalMappingCadenceArtifact,
        active: IncrementalMappingCadenceArtifact,
        existingTrigger: MappingCadenceFallbackTrigger?
    ) -> IncrementalMappingCadenceArtifact? {
        guard active == planned, existingTrigger == nil else { return nil }
        if planned == .orderedFast {
            return .balancedGlobal
        }
        if planned == .balancedGlobal {
            return .frequentGlobal
        }
        return nil
    }

    static func validates(
        planned: IncrementalMappingCadenceArtifact,
        accepted: IncrementalMappingCadenceArtifact,
        trigger: MappingCadenceFallbackTrigger?
    ) -> Bool {
        guard isRecognized(planned), isRecognized(accepted) else { return false }
        if planned == accepted {
            return trigger == nil
        }
        guard trigger != nil else { return false }
        return (planned == .orderedFast && accepted == .balancedGlobal)
            || (planned == .balancedGlobal && accepted == .frequentGlobal)
    }
}

public enum CanonicalModelPublicationKind: String, Codable, Sendable, Equatable {
    case convertedFromBinary
    case directText
    case resumedCanonicalText
}

public struct CanonicalModelConversionArtifact: Codable, Sendable, Equatable {
    /// One-based ordinal among model-converter invocations in the accepted mapping attempt.
    public var invocationOrdinal: Int
    public var workerEvidence: ColmapModelConversionWorkerEvidence

    public init(
        invocationOrdinal: Int,
        workerEvidence: ColmapModelConversionWorkerEvidence
    ) {
        self.invocationOrdinal = invocationOrdinal
        self.workerEvidence = workerEvidence
    }
}

public struct CanonicalModelPublicationArtifact: Codable, Sendable, Equatable {
    public var kind: CanonicalModelPublicationKind
    public var sourceModelHashes: [String: String]
    public var conversion: CanonicalModelConversionArtifact?

    public init(
        kind: CanonicalModelPublicationKind,
        sourceModelHashes: [String: String],
        conversion: CanonicalModelConversionArtifact?
    ) {
        self.kind = kind
        self.sourceModelHashes = sourceModelHashes
        self.conversion = conversion
    }
}

public struct MappingArtifact: Codable, Sendable, Equatable {
    public var modelCount: Int
    public var largestModelRegisteredViewCount: Int
    public var secondLargestModelRegisteredViewCount: Int
    public var unionRegisteredViewCount: Int
    public var attemptCount: Int
    public var acceptedMappingAttemptOrdinal: Int
    public var acceptedRefinementKind: MappingRefinementKind
    /// Observed global-refinement invocations from the accepted mapping attempt.
    public var acceptedRefinementInvocationCount: Int
    public var plannedIncrementalCadence: IncrementalMappingCadenceArtifact?
    public var incrementalCadence: IncrementalMappingCadenceArtifact?
    public var cadenceFallbackTrigger: MappingCadenceFallbackTrigger?
    public var canonicalModelPublication: CanonicalModelPublicationArtifact
    public var fallbackReason: String?

    public init(
        modelCount: Int,
        largestModelRegisteredViewCount: Int,
        secondLargestModelRegisteredViewCount: Int,
        unionRegisteredViewCount: Int,
        attemptCount: Int,
        acceptedMappingAttemptOrdinal: Int,
        acceptedRefinementKind: MappingRefinementKind,
        acceptedRefinementInvocationCount: Int,
        plannedIncrementalCadence: IncrementalMappingCadenceArtifact? = nil,
        incrementalCadence: IncrementalMappingCadenceArtifact?,
        cadenceFallbackTrigger: MappingCadenceFallbackTrigger? = nil,
        canonicalModelPublication: CanonicalModelPublicationArtifact,
        fallbackReason: String?
    ) {
        self.modelCount = modelCount
        self.largestModelRegisteredViewCount = largestModelRegisteredViewCount
        self.secondLargestModelRegisteredViewCount = secondLargestModelRegisteredViewCount
        self.unionRegisteredViewCount = unionRegisteredViewCount
        self.attemptCount = attemptCount
        self.acceptedMappingAttemptOrdinal = acceptedMappingAttemptOrdinal
        self.acceptedRefinementKind = acceptedRefinementKind
        self.acceptedRefinementInvocationCount = acceptedRefinementInvocationCount
        self.plannedIncrementalCadence = plannedIncrementalCadence
            ?? incrementalCadence
        self.incrementalCadence = incrementalCadence
        self.cadenceFallbackTrigger = cadenceFallbackTrigger
        self.canonicalModelPublication = canonicalModelPublication
        self.fallbackReason = fallbackReason
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

    var isCanonicalUnitRotation: Bool {
        let components = [w, x, y, z]
        guard components.allSatisfy(\.isFinite) else { return false }
        let squaredNorm = components.reduce(0) { $0 + $1 * $1 }
        guard abs(squaredNorm - 1) <= 1e-6 else { return false }
        if w > 0 { return true }
        if w < 0 { return false }
        for component in [x, y, z] where component != 0 {
            return component > 0
        }
        return false
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

    public init(
        status: CanonicalOrientationStatus,
        method: CanonicalOrientationMethod?,
        sourceToCanonicalQuaternionWXYZ: CanonicalQuaternionWXYZ?,
        evidence: CanonicalOrientationEvidence?,
        canonicalOpeningViewDirection: CanonicalDirection?
    ) {
        self.status = status
        self.method = method
        self.sourceToCanonicalQuaternionWXYZ = sourceToCanonicalQuaternionWXYZ
        self.evidence = evidence
        self.canonicalOpeningViewDirection = canonicalOpeningViewDirection
    }

    public static func unresolved(openingViewDirection: CanonicalDirection) -> Self {
        Self(
            status: .unresolved,
            method: nil,
            sourceToCanonicalQuaternionWXYZ: nil,
            evidence: nil,
            canonicalOpeningViewDirection: openingViewDirection
        )
    }
}

public struct GeometryConditioningArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2
    public static let currentAcceptancePolicy = "capture-agnostic-conditioning-v2"
    public static let defaultMaximumRayPairEvaluations = 100_000_000

    public var schemaVersion: Int
    public var measurementProvenance: String
    public var acceptancePolicy: String
    public var maximumRayPairEvaluations: Int
    public var sourceModelClosureSHA256: String
    public var measurement: GeometryConditioningMeasurement

    public init(
        schemaVersion: Int = currentSchemaVersion,
        measurementProvenance: String = GeometryConditioningMeasurement.provenance,
        acceptancePolicy: String = currentAcceptancePolicy,
        maximumRayPairEvaluations: Int = defaultMaximumRayPairEvaluations,
        sourceModelClosureSHA256: String,
        measurement: GeometryConditioningMeasurement
    ) {
        self.schemaVersion = schemaVersion
        self.measurementProvenance = measurementProvenance
        self.acceptancePolicy = acceptancePolicy
        self.maximumRayPairEvaluations = maximumRayPairEvaluations
        self.sourceModelClosureSHA256 = sourceModelClosureSHA256
        self.measurement = measurement
    }
}

public struct GeometryArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 35

    public var schemaVersion: Int
    public var solverVersion: String
    public var runtimeVersion: String
    public var modelVersion: String
    public var inputDigest: String
    public var selectedFramesDigest: String
    public var orderedImageNames: [String]
    public var orderedImageTimestamps: [Double?]
    /// Accepted COLMAP model in its source reconstruction frame. The orientation
    /// artifact maps this immutable model into EasySplat's canonical output frame.
    public var sourceModelPath: String
    /// Describes whether persisted poses transform world-to-camera or camera-to-world.
    public var poseConvention: String
    /// Component order used by every persisted quaternion, such as `wxyz`.
    public var quaternionOrder: String
    public var handedness: String
    public var scaleType: String
    public var cameraModel: String
    public var cameraGrouping: CameraGrouping
    public var cameraGroupingReceipt: ColmapCameraGroupingReceipt?
    public var cameraInitializationReceipt: ColmapCameraInitializationReceipt
    public var featureDatabaseDigest: String?
    public var registeredViewCount: Int
    public var totalViewCount: Int
    public var observationCount: Int
    public var pointCount: Int
    public var residualProvenance: String
    public var medianPixelResidual: Double
    public var p90PixelResidual: Double
    public var conditioning: GeometryConditioningArtifact
    public var timings: [String: Double]
    public var peakMemoryBytes: Int64
    public var modelHashes: [String: String]
    public var provenance: GeometryProvenance
    public var learnedPointInitializer: LearnedPointInitializerArtifact?
    public var workerExecution: GeometryWorkerExecutionArtifact
    public var pairGraph: PairGraphArtifact
    public var mapping: MappingArtifact
    public var canonicalOrientation: CanonicalOrientationArtifact

    public var allowsViewOnlyUprightFlip: Bool {
        switch canonicalOrientation.status {
        case .axisAlignedSignUnverified, .unresolved:
            // Unresolved scenes train in the raw source frame; the flip is a
            // best-effort 180-degree correction for the common inverted case.
            return GeometryArtifactStore.isCanonicalOrientationValid(
                canonicalOrientation,
                registeredViewCount: registeredViewCount
            )
        case .verified:
            return false
        }
    }

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
        cameraGroupingReceipt: ColmapCameraGroupingReceipt? = nil,
        cameraInitializationReceipt: ColmapCameraInitializationReceipt,
        featureDatabaseDigest: String? = nil,
        registeredViewCount: Int,
        totalViewCount: Int,
        observationCount: Int,
        pointCount: Int,
        residualProvenance: String,
        medianPixelResidual: Double,
        p90PixelResidual: Double,
        conditioning: GeometryConditioningArtifact,
        timings: [String: Double],
        peakMemoryBytes: Int64,
        modelHashes: [String: String],
        provenance: GeometryProvenance,
        workerExecution: GeometryWorkerExecutionArtifact,
        pairGraph: PairGraphArtifact,
        mapping: MappingArtifact,
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
        self.cameraGroupingReceipt = cameraGroupingReceipt
        self.cameraInitializationReceipt = cameraInitializationReceipt
        self.featureDatabaseDigest = featureDatabaseDigest
        self.registeredViewCount = registeredViewCount
        self.totalViewCount = totalViewCount
        self.observationCount = observationCount
        self.pointCount = pointCount
        self.residualProvenance = residualProvenance
        self.medianPixelResidual = medianPixelResidual
        self.p90PixelResidual = p90PixelResidual
        self.conditioning = conditioning
        self.timings = timings
        self.peakMemoryBytes = peakMemoryBytes
        self.modelHashes = modelHashes
        self.provenance = provenance
        self.learnedPointInitializer = learnedPointInitializer
        self.workerExecution = workerExecution
        self.pairGraph = pairGraph
        self.mapping = mapping
        self.canonicalOrientation = canonicalOrientation
    }
}
