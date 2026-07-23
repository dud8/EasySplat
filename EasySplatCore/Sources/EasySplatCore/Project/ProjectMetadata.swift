import Foundation

/// Persisted top-level metadata for a single `.easysplatproj` bundle.
public struct ProjectMetadata: Codable, Sendable {
    public var formatVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var input: InputSpec
    public var videoInputReceipts: [VideoInputReceipt]?
    public var photoInputReceipts: [PhotoInputReceipt]?
    public var photoSelectionReceipt: PhotoSelectionReceipt?
    /// Present exactly when `input` is a dataset: binds the imported pose
    /// seed, its source geometry files, and the entry-to-adopted-image
    /// mapping. Introduced in project format 32.
    public var datasetPoseSeed: DatasetPoseSeedReceipt?
    public var requestedRunOptions: RequestedRunOptions
    public var resolvedRunPlan: ResolvedRunPlan?
    public var trainingMemoryRetryBudgetBytes: Int64?
    public var geometryRecovery: GeometryRecoveryState?
    public var viewerPreferences: ViewerPreferences
    public var state: PipelineState
    public var checkpoint: PipelineCheckpoint?
    public var lastRunStartedAt: Date?
    public var stageTimings: [StageTimingRecord]?
    /// Monotonic elapsed time from the user's Create action until the first
    /// rendered preview for that run. This is an end-to-end boundary, not a
    /// pipeline stage, and must not be included in stage timing totals.
    public var createToViewerReadySeconds: Double?
    public var notes: String?
    public var lastFailureAt: Date?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case id
        case createdAt
        case title
        case input
        case videoInputReceipts
        case photoInputReceipts
        case photoSelectionReceipt
        case datasetPoseSeed
        case requestedRunOptions
        case resolvedRunPlan
        case trainingMemoryRetryBudgetBytes
        case geometryRecovery
        case viewerPreferences
        case state
        case checkpoint
        case lastRunStartedAt
        case stageTimings
        case createToViewerReadySeconds
        case notes
        case lastFailureAt
    }

    public init(
        formatVersion: Int = ProjectMetadataStore.supportedFormatVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        input: InputSpec,
        videoInputReceipts: [VideoInputReceipt]? = nil,
        photoInputReceipts: [PhotoInputReceipt]? = nil,
        photoSelectionReceipt: PhotoSelectionReceipt? = nil,
        datasetPoseSeed: DatasetPoseSeedReceipt? = nil,
        requestedRunOptions: RequestedRunOptions = RequestedRunOptions(),
        resolvedRunPlan: ResolvedRunPlan? = nil,
        trainingMemoryRetryBudgetBytes: Int64? = nil,
        geometryRecovery: GeometryRecoveryState? = nil,
        viewerPreferences: ViewerPreferences = ViewerPreferences(),
        state: PipelineState = PipelineState(stage: .importInput, lastError: nil),
        checkpoint: PipelineCheckpoint? = nil,
        lastRunStartedAt: Date? = nil,
        stageTimings: [StageTimingRecord]? = nil,
        createToViewerReadySeconds: Double? = nil,
        notes: String? = nil,
        lastFailureAt: Date? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.input = input
        self.videoInputReceipts = videoInputReceipts
        self.photoInputReceipts = photoInputReceipts
        self.photoSelectionReceipt = photoSelectionReceipt
        self.datasetPoseSeed = datasetPoseSeed
        self.requestedRunOptions = requestedRunOptions
        self.resolvedRunPlan = resolvedRunPlan
        self.trainingMemoryRetryBudgetBytes = trainingMemoryRetryBudgetBytes
        self.geometryRecovery = geometryRecovery
        self.viewerPreferences = viewerPreferences
        self.state = state
        self.checkpoint = checkpoint
        self.lastRunStartedAt = lastRunStartedAt
        self.stageTimings = stageTimings
        self.createToViewerReadySeconds = createToViewerReadySeconds
        self.notes = notes
        self.lastFailureAt = lastFailureAt
    }
}

public struct ViewerPreferences: Codable, Sendable, Equatable {
    public var isUprightFlipActive: Bool

    public init(isUprightFlipActive: Bool = false) {
        self.isUprightFlipActive = isUprightFlipActive
    }
}

extension ProjectMetadata {
    var effectiveDetailProfile: DetailProfile {
        requestedRunOptions.detailProfile
    }
}

/// Persisted timing measurement for a single completed pipeline stage. Surfaced
/// in the UI so users can see which stage dominated wall-clock time without
/// digging into the run logs. Failed-and-retried stages overwrite the previous
/// entry so the recorded duration reflects the run that actually succeeded.
public struct StageTimingRecord: Codable, Sendable, Equatable {
    public var stage: PipelineStage
    public var startedAt: Date
    public var durationSeconds: Double

    public init(stage: PipelineStage, startedAt: Date, durationSeconds: Double) {
        self.stage = stage
        self.startedAt = startedAt
        self.durationSeconds = max(0, durationSeconds)
    }
}

extension Array where Element == StageTimingRecord {
    /// Total wall-clock time across all recorded stages. `nil` when no timings exist.
    public var totalDurationSeconds: Double? {
        guard !isEmpty else { return nil }
        return reduce(0) { $0 + $1.durationSeconds }
    }
}

/// Resume and recovery marker captured while a pipeline stage is in flight.
public struct PipelineCheckpoint: Codable, Sendable {
    public var stage: PipelineStage
    public var updatedAt: Date
    public var progressFraction: Double?
    public var message: String?
    public var inputReceiptDigest: String?
    public var details: PipelineCheckpointDetails?

    public init(
        stage: PipelineStage,
        updatedAt: Date = Date(),
        progressFraction: Double? = nil,
        message: String? = nil,
        inputReceiptDigest: String? = nil,
        details: PipelineCheckpointDetails? = nil
    ) {
        self.stage = stage
        self.updatedAt = updatedAt
        self.progressFraction = progressFraction
        self.message = message
        self.inputReceiptDigest = inputReceiptDigest
        self.details = details
    }
}

/// Stage-specific payload attached to a pipeline checkpoint.
public enum PipelineCheckpointDetails: Codable, Sendable {
    case extractFrames(ExtractFramesCheckpoint)
    case selectFrames(SelectFramesCheckpoint)
    case sfmFeatures(SfmFeaturesCheckpoint)
    case sfmMatching(SfmMatchingCheckpoint)
    case trainSplat(TrainSplatCheckpoint)
    case exportSplat(ExportSplatCheckpoint)

    private enum CaseKey: String, CodingKey {
        case extractFrames
        case selectFrames
        case sfmFeatures
        case sfmMatching
        case trainSplat
        case exportSplat
    }

    private enum ValueKey: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Pipeline checkpoint details must contain exactly one known stage."
            ))
        }

        func decode<Value: Decodable>(_ type: Value.Type, for key: CaseKey) throws -> Value {
            let value = try container.nestedContainer(keyedBy: ValueKey.self, forKey: key)
            return try value.decode(Value.self, forKey: .value)
        }

        switch key {
        case .extractFrames:
            self = .extractFrames(try decode(ExtractFramesCheckpoint.self, for: key))
        case .selectFrames:
            self = .selectFrames(try decode(SelectFramesCheckpoint.self, for: key))
        case .sfmFeatures:
            self = .sfmFeatures(try decode(SfmFeaturesCheckpoint.self, for: key))
        case .sfmMatching:
            self = .sfmMatching(try decode(SfmMatchingCheckpoint.self, for: key))
        case .trainSplat:
            self = .trainSplat(try decode(TrainSplatCheckpoint.self, for: key))
        case .exportSplat:
            self = .exportSplat(try decode(ExportSplatCheckpoint.self, for: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)

        switch self {
        case .extractFrames(let details):
            var value = container.nestedContainer(keyedBy: ValueKey.self, forKey: .extractFrames)
            try value.encode(details, forKey: .value)
        case .selectFrames(let details):
            var value = container.nestedContainer(keyedBy: ValueKey.self, forKey: .selectFrames)
            try value.encode(details, forKey: .value)
        case .sfmFeatures(let details):
            var value = container.nestedContainer(keyedBy: ValueKey.self, forKey: .sfmFeatures)
            try value.encode(details, forKey: .value)
        case .sfmMatching(let details):
            var value = container.nestedContainer(keyedBy: ValueKey.self, forKey: .sfmMatching)
            try value.encode(details, forKey: .value)
        case .trainSplat(let details):
            var value = container.nestedContainer(keyedBy: ValueKey.self, forKey: .trainSplat)
            try value.encode(details, forKey: .value)
        case .exportSplat(let details):
            var value = container.nestedContainer(keyedBy: ValueKey.self, forKey: .exportSplat)
            try value.encode(details, forKey: .value)
        }
    }
}

/// Checkpoint details for extracted video frames.
public struct ExtractFramesCheckpoint: Codable, Sendable {
    public var videoIndex: Int
    public var videoName: String
    public var extractedCount: Int
    public var targetCount: Int

    public init(videoIndex: Int, videoName: String, extractedCount: Int, targetCount: Int) {
        self.videoIndex = videoIndex
        self.videoName = videoName
        self.extractedCount = extractedCount
        self.targetCount = targetCount
    }
}

/// Checkpoint details for selected frame manifests.
public struct SelectFramesCheckpoint: Codable, Sendable {
    public var groupsProcessed: Int
    public var selectedCount: Int
    public var manifestPath: String?

    public init(groupsProcessed: Int, selectedCount: Int, manifestPath: String?) {
        self.groupsProcessed = groupsProcessed
        self.selectedCount = selectedCount
        self.manifestPath = manifestPath
    }
}

/// Checkpoint details for feature extraction state.
public struct SfmFeaturesCheckpoint: Codable, Sendable {
    public var databasePath: String
    public var imageCount: Int
    public var cameraGroupingReceipt: ColmapCameraGroupingReceipt?
    public var cameraInitializationReceipt: ColmapCameraInitializationReceipt?
    public var featureDatabaseDigest: String?

    public init(
        databasePath: String,
        imageCount: Int,
        cameraGroupingReceipt: ColmapCameraGroupingReceipt? = nil,
        cameraInitializationReceipt: ColmapCameraInitializationReceipt? = nil,
        featureDatabaseDigest: String? = nil
    ) {
        self.databasePath = databasePath
        self.imageCount = imageCount
        self.cameraGroupingReceipt = cameraGroupingReceipt
        self.cameraInitializationReceipt = cameraInitializationReceipt
        self.featureDatabaseDigest = featureDatabaseDigest
    }
}

/// Checkpoint details for image matching progress.
public struct SfmMatchingCheckpoint: Codable, Sendable {
    public var databasePath: String
    public var expectedPairs: Int?
    public var processedPairs: Int?

    public init(databasePath: String, expectedPairs: Int?, processedPairs: Int?) {
        self.databasePath = databasePath
        self.expectedPairs = expectedPairs
        self.processedPairs = processedPairs
    }
}

/// Checkpoint details for native training progress.
public struct TrainSplatCheckpoint: Codable, Sendable {
    public var progressStep: Int?
    public var progressTotal: Int?

    public init(progressStep: Int? = nil, progressTotal: Int? = nil) {
        self.progressStep = progressStep
        self.progressTotal = progressTotal
    }
}

/// Checkpoint details for the final exported splat artifact.
public struct ExportSplatCheckpoint: Codable, Sendable {
    public var outputPath: String
    public var sourcePath: String
    public var sizeBytes: Int64

    public init(outputPath: String, sourcePath: String, sizeBytes: Int64) {
        self.outputPath = outputPath
        self.sourcePath = sourcePath
        self.sizeBytes = sizeBytes
    }
}

/// Immutable proof that a selected external video was copied, decoded through the
/// shipping frame path, and adopted under a controlled project-relative name.
public struct VideoInputReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let projectRelativePath: String
    public let safeDisplayName: String
    public let byteCount: Int64
    public let sha256: String
    public let trackID: Int32
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let durationSeconds: Double
    public let nominalFrameRate: Double
    public let isHDR: Bool
    public let decodedFrameCount: Int
    public let transformA: Double
    public let transformB: Double
    public let transformC: Double
    public let transformD: Double
    public let transformTX: Double
    public let transformTY: Double
    public let clipGroupID: String
    public let analysisPolicySHA256: String
    public let analysisArtifactPath: String
    public let analysisArtifactByteCount: Int64
    public let analysisArtifactSHA256: String

    public init(
        schemaVersion: Int = VideoInputReceipt.currentSchemaVersion,
        projectRelativePath: String,
        safeDisplayName: String,
        byteCount: Int64,
        sha256: String,
        trackID: Int32,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        nominalFrameRate: Double,
        isHDR: Bool,
        decodedFrameCount: Int,
        transformA: Double,
        transformB: Double,
        transformC: Double,
        transformD: Double,
        transformTX: Double,
        transformTY: Double,
        clipGroupID: String,
        analysisPolicySHA256: String,
        analysisArtifactPath: String,
        analysisArtifactByteCount: Int64,
        analysisArtifactSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.projectRelativePath = projectRelativePath
        self.safeDisplayName = safeDisplayName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.trackID = trackID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.nominalFrameRate = nominalFrameRate
        self.isHDR = isHDR
        self.decodedFrameCount = decodedFrameCount
        self.transformA = transformA
        self.transformB = transformB
        self.transformC = transformC
        self.transformD = transformD
        self.transformTX = transformTX
        self.transformTY = transformTY
        self.clipGroupID = clipGroupID
        self.analysisPolicySHA256 = analysisPolicySHA256
        self.analysisArtifactPath = analysisArtifactPath
        self.analysisArtifactByteCount = analysisArtifactByteCount
        self.analysisArtifactSHA256 = analysisArtifactSHA256
    }
}

public struct PhotoSourceProvenance: Codable, Equatable, Sendable {
    public let byteCount: Int64
    public let sha256: String
    public let typeIdentifier: String

    public init(byteCount: Int64, sha256: String, typeIdentifier: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
        self.typeIdentifier = typeIdentifier
    }
}

public struct RawDevelopmentSettings: Codable, Equatable, Sendable {
    /// Version 2 binds orientation-normalized, privacy-sanitized camera metadata.
    public static let currentVersion = 2

    public let version: Int
    public let maximumPixelDimension: Int
    public let draftModeEnabled: Bool
    public let lensCorrectionEnabled: Bool
    public let highlightRecoveryEnabled: Bool
    public let luminanceNoiseReductionAmount: Float
    public let colorNoiseReductionAmount: Float
    public let sharpnessAmount: Float
    public let detailAmount: Float
    public let moireReductionAmount: Float
    public let extendedDynamicRangeAmount: Float
    public let outputTypeIdentifier: String
    public let outputColorSpace: String
    public let outputBitDepth: Int

    public static func production(maximumPixelDimension: Int) -> Self {
        Self(
            version: currentVersion,
            maximumPixelDimension: maximumPixelDimension,
            draftModeEnabled: false,
            lensCorrectionEnabled: true,
            highlightRecoveryEnabled: true,
            luminanceNoiseReductionAmount: 0.5,
            colorNoiseReductionAmount: 0.5,
            sharpnessAmount: 0,
            detailAmount: 0,
            moireReductionAmount: 0,
            extendedDynamicRangeAmount: 0,
            outputTypeIdentifier: "public.png",
            outputColorSpace: "sRGB IEC61966-2.1",
            outputBitDepth: 8
        )
    }

    public init(
        version: Int,
        maximumPixelDimension: Int,
        draftModeEnabled: Bool,
        lensCorrectionEnabled: Bool,
        highlightRecoveryEnabled: Bool,
        luminanceNoiseReductionAmount: Float,
        colorNoiseReductionAmount: Float,
        sharpnessAmount: Float,
        detailAmount: Float,
        moireReductionAmount: Float,
        extendedDynamicRangeAmount: Float,
        outputTypeIdentifier: String,
        outputColorSpace: String,
        outputBitDepth: Int
    ) {
        self.version = version
        self.maximumPixelDimension = maximumPixelDimension
        self.draftModeEnabled = draftModeEnabled
        self.lensCorrectionEnabled = lensCorrectionEnabled
        self.highlightRecoveryEnabled = highlightRecoveryEnabled
        self.luminanceNoiseReductionAmount = luminanceNoiseReductionAmount
        self.colorNoiseReductionAmount = colorNoiseReductionAmount
        self.sharpnessAmount = sharpnessAmount
        self.detailAmount = detailAmount
        self.moireReductionAmount = moireReductionAmount
        self.extendedDynamicRangeAmount = extendedDynamicRangeAmount
        self.outputTypeIdentifier = outputTypeIdentifier
        self.outputColorSpace = outputColorSpace
        self.outputBitDepth = outputBitDepth
    }
}

public struct RawDevelopmentEvidence: Codable, Equatable, Sendable {
    public let decoderIdentifier: String
    public let decoderVersion: String
    public let settings: RawDevelopmentSettings
    public let nativePixelWidth: Int
    public let nativePixelHeight: Int
    public let sourceOrientation: Int

    public init(
        decoderIdentifier: String,
        decoderVersion: String,
        settings: RawDevelopmentSettings,
        nativePixelWidth: Int,
        nativePixelHeight: Int,
        sourceOrientation: Int
    ) {
        self.decoderIdentifier = decoderIdentifier
        self.decoderVersion = decoderVersion
        self.settings = settings
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        self.sourceOrientation = sourceOrientation
    }
}

public enum PhotoImportMode: Codable, Equatable, Sendable {
    case unchanged
    case rawDevelopment(RawDevelopmentEvidence)
}

/// Immutable identity and policy closure for `Frames/photo_selection.json`.
public struct PhotoSelectionReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let projectRelativePath = "Frames/photo_selection.json"

    public let schemaVersion: Int
    public let projectRelativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let artifactSchemaVersion: Int
    public let analysisRecipeVersion: Int
    public let analysisRecipeSHA256: String
    public let selectorPolicyVersion: Int
    public let selectorPolicySHA256: String

    public init(
        schemaVersion: Int = PhotoSelectionReceipt.currentSchemaVersion,
        projectRelativePath: String,
        byteCount: Int64,
        sha256: String,
        artifactSchemaVersion: Int,
        analysisRecipeVersion: Int,
        analysisRecipeSHA256: String,
        selectorPolicyVersion: Int,
        selectorPolicySHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.projectRelativePath = projectRelativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.artifactSchemaVersion = artifactSchemaVersion
        self.analysisRecipeVersion = analysisRecipeVersion
        self.analysisRecipeSHA256 = analysisRecipeSHA256
        self.selectorPolicyVersion = selectorPolicyVersion
        self.selectorPolicySHA256 = selectorPolicySHA256
    }
}

/// Immutable source and controlled-output proof for a photo adopted below `Originals/Photos`.
public struct PhotoInputReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let projectRelativePath: String
    public let safeDisplayName: String
    public let byteCount: Int64
    public let sha256: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let orientation: Int
    public let typeIdentifier: String
    public let source: PhotoSourceProvenance
    public let importMode: PhotoImportMode
    public let analysisEvidence: PhotoAnalysisEvidence
    public let retainedRank: Int

    public init(
        schemaVersion: Int = PhotoInputReceipt.currentSchemaVersion,
        projectRelativePath: String,
        safeDisplayName: String,
        byteCount: Int64,
        sha256: String,
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: Int,
        typeIdentifier: String,
        source: PhotoSourceProvenance,
        importMode: PhotoImportMode,
        analysisEvidence: PhotoAnalysisEvidence,
        retainedRank: Int
    ) {
        self.schemaVersion = schemaVersion
        self.projectRelativePath = projectRelativePath
        self.safeDisplayName = safeDisplayName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.typeIdentifier = typeIdentifier
        self.source = source
        self.importMode = importMode
        self.analysisEvidence = analysisEvidence
        self.retainedRank = retainedRank
    }

    /// Convenience for controlled formats whose admitted source bytes are retained unchanged.
    public init(
        schemaVersion: Int = PhotoInputReceipt.currentSchemaVersion,
        projectRelativePath: String,
        safeDisplayName: String,
        byteCount: Int64,
        sha256: String,
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: Int,
        typeIdentifier: String,
        analysisEvidence: PhotoAnalysisEvidence,
        retainedRank: Int
    ) {
        self.init(
            schemaVersion: schemaVersion,
            projectRelativePath: projectRelativePath,
            safeDisplayName: safeDisplayName,
            byteCount: byteCount,
            sha256: sha256,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            orientation: orientation,
            typeIdentifier: typeIdentifier,
            source: PhotoSourceProvenance(
                byteCount: byteCount,
                sha256: sha256,
                typeIdentifier: typeIdentifier
            ),
            importMode: .unchanged,
            analysisEvidence: analysisEvidence,
            retainedRank: retainedRank
        )
    }
}

/// Normalized user input selection for a project run.
public enum InputSpec: Codable, Sendable {
    case video(files: [String])
    case photos(folder: String)
    case mixed(videos: [String], photosFolder: String)
    /// A pre-processed dataset import. `imagesFolder` is surfaced through
    /// `photosFolder` deliberately: dataset images ride the photo admission,
    /// receipt, and frame-selection machinery unchanged, and only the sites
    /// that must diverge branch on `isDataset`. Introduced in project
    /// format 32.
    case dataset(kind: DatasetKind, imagesFolder: String)

    public var videoFiles: [String] {
        switch self {
        case .video(let files):
            return files
        case .photos, .dataset:
            return []
        case .mixed(let videos, _):
            return videos
        }
    }

    public var photosFolder: String? {
        switch self {
        case .video:
            return nil
        case .photos(let folder):
            return folder
        case .mixed(_, let photosFolder):
            return photosFolder
        case .dataset(_, let imagesFolder):
            return imagesFolder
        }
    }

    public var hasVideos: Bool { !videoFiles.isEmpty }
    public var hasPhotos: Bool { photosFolder != nil }

    public var isDataset: Bool {
        if case .dataset = self { return true }
        return false
    }

    public var datasetKind: DatasetKind? {
        if case .dataset(let kind, _) = self { return kind }
        return nil
    }
}

/// Persisted pipeline state used for status, retry, and resume handling.
public struct PipelineState: Codable, Sendable {
    public var stage: PipelineStage
    public var lastError: String?

    public init(stage: PipelineStage, lastError: String?) {
        self.stage = stage
        self.lastError = lastError
    }
}
