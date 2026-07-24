import Foundation

public enum SplatOutputVariant: String, Codable, Sendable, Equatable {
    case original
    case subject
}
public struct ValidatedSplatOutput: Sendable, Equatable {
    public let variant: SplatOutputVariant
    public let url: URL
    public let sha256: String
    public let byteCount: UInt64
    public let gaussianCount: Int
    public let sceneBounds: SplatSceneBounds

    public init(
        variant: SplatOutputVariant,
        url: URL,
        sha256: String,
        byteCount: UInt64,
        gaussianCount: Int,
        sceneBounds: SplatSceneBounds
    ) {
        self.variant = variant
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.gaussianCount = gaussianCount
        self.sceneBounds = sceneBounds
    }
}

public struct CanonicalSplatPublication: Sendable, Equatable {
    public let outputEvidence: ValidatedPlyArtifactEvidence
    public let trainingManifestSHA256: String
    public let trainingInputDigest: String
    public let trainingGeometryDigest: String
    public let selectedFramesDigest: String
    public let selectedImageOrder: [String]

    init(
        outputEvidence: ValidatedPlyArtifactEvidence,
        trainingManifestSHA256: String,
        trainingInputDigest: String,
        trainingGeometryDigest: String,
        selectedFramesDigest: String,
        selectedImageOrder: [String]
    ) {
        self.outputEvidence = outputEvidence
        self.trainingManifestSHA256 = trainingManifestSHA256
        self.trainingInputDigest = trainingInputDigest
        self.trainingGeometryDigest = trainingGeometryDigest
        self.selectedFramesDigest = selectedFramesDigest
        self.selectedImageOrder = selectedImageOrder
    }
}

public struct SubjectAnchor: Codable, Sendable, Equatable {
    public var imageIdentity: String
    public var instanceLabel: UInt8
    public var normalizedX: Double
    public var normalizedY: Double

    public init(
        imageIdentity: String,
        instanceLabel: UInt8,
        normalizedX: Double,
        normalizedY: Double
    ) {
        self.imageIdentity = imageIdentity
        self.instanceLabel = instanceLabel
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
    }
}

public struct SubjectChoiceRequest: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public let componentIdentity: String
        public let instanceLabel: UInt8
        public let confidence: Double
        public let previewMaskURL: URL?

        public init(
            componentIdentity: String,
            instanceLabel: UInt8,
            confidence: Double,
            previewMaskURL: URL? = nil
        ) {
            self.componentIdentity = componentIdentity
            self.instanceLabel = instanceLabel
            self.confidence = confidence
            self.previewMaskURL = previewMaskURL
        }
    }

    public let keyframeImageURL: URL
    public let combinedInstanceLabelMaskURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let candidates: [Candidate]

    public init(
        keyframeImageURL: URL,
        combinedInstanceLabelMaskURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        candidates: [Candidate]
    ) {
        self.keyframeImageURL = keyframeImageURL
        self.combinedInstanceLabelMaskURL = combinedInstanceLabelMaskURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.candidates = candidates
    }
}

public enum SubjectIsolationPhase: String, Sendable, Equatable {
    case preparing
    case segmenting
    case validating
    case filtering
    case publishing
}

public struct SubjectIsolationProgress: Sendable, Equatable {
    public let phase: SubjectIsolationPhase
    public let completedUnitCount: Int
    public let totalUnitCount: Int

    public init(
        phase: SubjectIsolationPhase,
        completedUnitCount: Int,
        totalUnitCount: Int
    ) {
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

public enum SubjectIsolationOutcome: Sendable, Equatable {
    case progress(SubjectIsolationProgress)
    case ambiguity(SubjectChoiceRequest)
    case noSubject
    case cancelled
    case completed(ValidatedSplatOutput)
}

public struct IsolationArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumMaskCount = 24
    public static let maximumMaskDimension = 4_096
    public static let maximumDecodedMaskPixelCount = 16_777_216

    public struct DatasetIdentity: Codable, Sendable, Equatable {
        public var inputDigest: String
        public var geometryDigest: String
        public var selectedFramesDigest: String
        public var selectedImageOrder: [String]

        public init(
            inputDigest: String,
            geometryDigest: String,
            selectedFramesDigest: String,
            selectedImageOrder: [String]
        ) {
            self.inputDigest = inputDigest
            self.geometryDigest = geometryDigest
            self.selectedFramesDigest = selectedFramesDigest
            self.selectedImageOrder = selectedImageOrder
        }
    }

    public struct Mask: Codable, Sendable, Equatable {
        public var relativePath: String
        public var imageIdentity: String
        public var imageSHA256: String
        public var maskSHA256: String
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var instanceLabels: [UInt8]

        public init(
            relativePath: String,
            imageIdentity: String,
            imageSHA256: String,
            maskSHA256: String,
            pixelWidth: Int,
            pixelHeight: Int,
            instanceLabels: [UInt8]
        ) {
            self.relativePath = relativePath
            self.imageIdentity = imageIdentity
            self.imageSHA256 = imageSHA256
            self.maskSHA256 = maskSHA256
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.instanceLabels = instanceLabels
        }
    }

    public struct Policy: Codable, Sendable, Equatable {
        public var version: Int
        public var minimumMaskConfidence: Double
        public var minimumHeldOutMedianIoU: Double
        public var minimumHeldOutFirstQuartileIoU: Double
        public var minimumRetainedGaussianFraction: Double
        public var maximumRetainedGaussianFraction: Double

        public init(
            version: Int,
            minimumMaskConfidence: Double,
            minimumHeldOutMedianIoU: Double,
            minimumHeldOutFirstQuartileIoU: Double,
            minimumRetainedGaussianFraction: Double,
            maximumRetainedGaussianFraction: Double
        ) {
            self.version = version
            self.minimumMaskConfidence = minimumMaskConfidence
            self.minimumHeldOutMedianIoU = minimumHeldOutMedianIoU
            self.minimumHeldOutFirstQuartileIoU = minimumHeldOutFirstQuartileIoU
            self.minimumRetainedGaussianFraction = minimumRetainedGaussianFraction
            self.maximumRetainedGaussianFraction = maximumRetainedGaussianFraction
        }
    }

    public struct ValidationMetrics: Codable, Sendable, Equatable {
        public var meanMaskConfidence: Double
        public var heldOutMeanIoU: Double?
        public var heldOutMedianIoU: Double?
        public var heldOutFirstQuartileIoU: Double?
        public var retainedGaussianFraction: Double

        public init(
            meanMaskConfidence: Double,
            heldOutMeanIoU: Double?,
            heldOutMedianIoU: Double?,
            heldOutFirstQuartileIoU: Double?,
            retainedGaussianFraction: Double
        ) {
            self.meanMaskConfidence = meanMaskConfidence
            self.heldOutMeanIoU = heldOutMeanIoU
            self.heldOutMedianIoU = heldOutMedianIoU
            self.heldOutFirstQuartileIoU = heldOutFirstQuartileIoU
            self.retainedGaussianFraction = retainedGaussianFraction
        }
    }

    public struct OutputIdentity: Codable, Sendable, Equatable {
        public var identity: UUID
        public var relativePath: String
        public var sha256: String
        public var byteCount: UInt64
        public var gaussianCount: Int
        public var sceneBounds: SplatSceneBounds

        public init(
            identity: UUID,
            relativePath: String,
            sha256: String,
            byteCount: UInt64,
            gaussianCount: Int,
            sceneBounds: SplatSceneBounds
        ) {
            self.identity = identity
            self.relativePath = relativePath
            self.sha256 = sha256
            self.byteCount = byteCount
            self.gaussianCount = gaussianCount
            self.sceneBounds = sceneBounds
        }
    }

    public var schemaVersion: Int
    public var sourcePlySHA256: String
    public var trainingManifestSHA256: String
    public var dataset: DatasetIdentity
    public var masks: [Mask]
    public var toolchainBuildIdentity: String
    public var nativeExecutableSHA256: String
    public var visionRequestRevision: Int
    public var selectedViewIdentities: [String]
    public var heldOutViewIdentities: [String]
    public var policy: Policy
    public var subjectAnchor: SubjectAnchor?
    public var metrics: ValidationMetrics
    public var output: OutputIdentity

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sourcePlySHA256: String,
        trainingManifestSHA256: String,
        dataset: DatasetIdentity,
        masks: [Mask],
        toolchainBuildIdentity: String,
        nativeExecutableSHA256: String,
        visionRequestRevision: Int,
        selectedViewIdentities: [String],
        heldOutViewIdentities: [String],
        policy: Policy,
        subjectAnchor: SubjectAnchor?,
        metrics: ValidationMetrics,
        output: OutputIdentity
    ) {
        self.schemaVersion = schemaVersion
        self.sourcePlySHA256 = sourcePlySHA256
        self.trainingManifestSHA256 = trainingManifestSHA256
        self.dataset = dataset
        self.masks = masks
        self.toolchainBuildIdentity = toolchainBuildIdentity
        self.nativeExecutableSHA256 = nativeExecutableSHA256
        self.visionRequestRevision = visionRequestRevision
        self.selectedViewIdentities = selectedViewIdentities
        self.heldOutViewIdentities = heldOutViewIdentities
        self.policy = policy
        self.subjectAnchor = subjectAnchor
        self.metrics = metrics
        self.output = output
    }
}
