import Foundation

/// Persisted top-level metadata for a single `.easysplatproj` bundle.
public struct ProjectMetadata: Codable, Sendable {
    public var formatVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var input: InputSpec
    public var preset: PresetSpec
    public var requestedRunOptions: RequestedRunOptions?
    public var resolvedRunPlan: ResolvedRunPlan?
    public var geometryArtifact: GeometryArtifact?
    public var trainingArtifact: TrainingArtifact?
    public var state: PipelineState
    public var outputs: OutputSpec?
    public var checkpoint: PipelineCheckpoint?
    public var completedSfmMapping: SfmMappingCheckpoint?
    public var recoveryPromptSuppressed: Bool?
    public var lastRunStartedAt: Date?
    public var shareMetrics: ShareMetrics?
    public var reconstruction: ReconstructionSummary?
    public var stageTimings: [StageTimingRecord]?
    public var autoTune: AutoTuneSnapshot?
    public var notes: String?
    public var lastOpenedAt: Date?
    public var lastFailureAt: Date?

    public init(
        formatVersion: Int = 2,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        input: InputSpec,
        preset: PresetSpec,
        requestedRunOptions: RequestedRunOptions? = RequestedRunOptions(),
        resolvedRunPlan: ResolvedRunPlan? = nil,
        geometryArtifact: GeometryArtifact? = nil,
        trainingArtifact: TrainingArtifact? = nil,
        state: PipelineState = PipelineState(stage: .importInput, attempt: 0, lastError: nil, resumeToken: nil),
        outputs: OutputSpec? = nil,
        checkpoint: PipelineCheckpoint? = nil,
        completedSfmMapping: SfmMappingCheckpoint? = nil,
        recoveryPromptSuppressed: Bool? = nil,
        lastRunStartedAt: Date? = nil,
        shareMetrics: ShareMetrics? = nil,
        reconstruction: ReconstructionSummary? = nil,
        stageTimings: [StageTimingRecord]? = nil,
        autoTune: AutoTuneSnapshot? = nil,
        notes: String? = nil,
        lastOpenedAt: Date? = nil,
        lastFailureAt: Date? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.input = input
        self.preset = preset
        self.requestedRunOptions = requestedRunOptions
        self.resolvedRunPlan = resolvedRunPlan
        self.geometryArtifact = geometryArtifact
        self.trainingArtifact = trainingArtifact
        self.state = state
        self.outputs = outputs
        self.checkpoint = checkpoint
        self.completedSfmMapping = completedSfmMapping
        self.recoveryPromptSuppressed = recoveryPromptSuppressed
        self.lastRunStartedAt = lastRunStartedAt
        self.shareMetrics = shareMetrics
        self.reconstruction = reconstruction
        self.stageTimings = stageTimings
        self.autoTune = autoTune
        self.notes = notes
        self.lastOpenedAt = lastOpenedAt
        self.lastFailureAt = lastFailureAt
    }
}

extension ProjectMetadata {
    var effectiveDetailProfile: DetailProfile {
        if let requestedRunOptions {
            return requestedRunOptions.detailProfile
        }
        switch preset.quality {
        case .draft: return .fast
        case .standard: return .balanced
        case .ultra: return .highDetail
        }
    }
}

/// Legacy AutoTuner snapshot retained only to decode older project metadata.
public struct AutoTuneSnapshot: Codable, Sendable, Equatable {
    public var tier: String
    public var memoryGB: Double
    public var cpuCount: Int
    public var gpuWorkingSetGB: Double?
    public var mapAnythingResolution: Int
    public var mapAnythingDirectViewLimit: Int
    public var mapAnythingAnchorMaxViews: Int
    public var mapAnythingWindowSize: Int
    public var mapAnythingWindowOverlap: Int
    public var vggtImageLoadResolution: Int
    public var vggtFixedResolution: Int
    public var vggtMaxPoints: Int
    public var vggtAllowed: Bool
    public var colmapMaxNumFeatures: Int
    public var colmapMaxNumMatches: Int
    public var colmapSequentialOverlap: Int
    public var colmapExhaustiveBlockSize: Int
    public var threadCap: Int
    public var colmapMaxImageSizeCap: Int?
    public var capturedAt: Date

    public init(
        tier: String,
        memoryGB: Double,
        cpuCount: Int,
        gpuWorkingSetGB: Double?,
        mapAnythingResolution: Int,
        mapAnythingDirectViewLimit: Int,
        mapAnythingAnchorMaxViews: Int,
        mapAnythingWindowSize: Int,
        mapAnythingWindowOverlap: Int,
        vggtImageLoadResolution: Int,
        vggtFixedResolution: Int,
        vggtMaxPoints: Int,
        vggtAllowed: Bool,
        colmapMaxNumFeatures: Int,
        colmapMaxNumMatches: Int,
        colmapSequentialOverlap: Int,
        colmapExhaustiveBlockSize: Int,
        threadCap: Int,
        colmapMaxImageSizeCap: Int?,
        capturedAt: Date
    ) {
        self.tier = tier
        self.memoryGB = memoryGB
        self.cpuCount = cpuCount
        self.gpuWorkingSetGB = gpuWorkingSetGB
        self.mapAnythingResolution = mapAnythingResolution
        self.mapAnythingDirectViewLimit = mapAnythingDirectViewLimit
        self.mapAnythingAnchorMaxViews = mapAnythingAnchorMaxViews
        self.mapAnythingWindowSize = mapAnythingWindowSize
        self.mapAnythingWindowOverlap = mapAnythingWindowOverlap
        self.vggtImageLoadResolution = vggtImageLoadResolution
        self.vggtFixedResolution = vggtFixedResolution
        self.vggtMaxPoints = vggtMaxPoints
        self.vggtAllowed = vggtAllowed
        self.colmapMaxNumFeatures = colmapMaxNumFeatures
        self.colmapMaxNumMatches = colmapMaxNumMatches
        self.colmapSequentialOverlap = colmapSequentialOverlap
        self.colmapExhaustiveBlockSize = colmapExhaustiveBlockSize
        self.threadCap = threadCap
        self.colmapMaxImageSizeCap = colmapMaxImageSizeCap
        self.capturedAt = capturedAt
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

/// Persisted summary of the accepted sparse reconstruction. Lets the app surface
/// quality metrics (frame coverage, point density, and — for mappers that produce real
/// pixel residuals — reprojection error) without re-parsing the COLMAP model after the
/// run finishes. See `resolvedReprojectionError` for the honest, display-safe value.
public struct ReconstructionSummary: Codable, Sendable, Equatable {
    public var mapper: String
    public var capturedAt: Date
    public var registeredImages: Int
    public var totalImages: Int
    public var meanReprojectionError: Double?
    public var pointCount: Int?
    public var observationCount: Int?
    public var meanTrackLength: Double?

    public init(
        mapper: String,
        capturedAt: Date,
        registeredImages: Int,
        totalImages: Int,
        meanReprojectionError: Double? = nil,
        pointCount: Int? = nil,
        observationCount: Int? = nil,
        meanTrackLength: Double? = nil
    ) {
        self.mapper = mapper
        self.capturedAt = capturedAt
        self.registeredImages = registeredImages
        self.totalImages = totalImages
        self.meanReprojectionError = meanReprojectionError
        self.pointCount = pointCount
        self.observationCount = observationCount
        self.meanTrackLength = meanTrackLength
    }

    /// Fraction of the requested frames that the mapper actually registered.
    /// Returns 0 when `totalImages` is non-positive so callers do not need to guard.
    public var registeredFraction: Double {
        guard totalImages > 0 else { return 0 }
        return Double(registeredImages) / Double(totalImages)
    }
}

extension ReconstructionSummary {
    /// Mappers whose `model_analyzer` "mean reprojection error" is not a real pixel residual.
    /// GLOMAP (`global_mapper*`) and the feed-forward neural-direct paths (DA3, MapAnything,
    /// FastVGGT seed) hand COLMAP a model that is analyzed WITHOUT a `point_triangulator`
    /// re-triangulation pass (unlike the neural *refinement* paths, which do re-triangulate),
    /// so `model_analyzer` just averages the bridge's stored per-point error — a placeholder:
    /// DA3/MapAnything write `1.0`, FastVGGT writes `0.0`, GLOMAP stores a normalized-coordinate
    /// value (~0.0003). Comparing any of these to the pixel-based acceptance threshold and the
    /// sub-1.2px "strong" cutoff is meaningless (and inflates the rating), so we treat them as
    /// having no measured reprojection error.
    public static func reprojectionErrorIsUnreliable(forMapper mapper: String) -> Bool {
        switch mapper {
        case "global_mapper", "global_mapper-gpu", "global_mapper-cpu",
             "da3-direct", "mapanything-direct", "fastvggt-seed":
            return true
        default:
            return false
        }
    }

    /// The reprojection error to display and consume. Returns nil for mappers whose stored
    /// value is a placeholder (see `reprojectionErrorIsUnreliable`). New summaries already
    /// persist nil for those mappers; this also masks older `project.json` files written
    /// before that value was dropped at persist time.
    public var resolvedReprojectionError: Double? {
        Self.reprojectionErrorIsUnreliable(forMapper: mapper) ? nil : meanReprojectionError
    }

    /// Bridges the per-run `ReconstructionScore` (lives in SfM) onto the persisted summary.
    /// Acceptance has already been decided on the raw `score`; this only shapes what gets
    /// persisted and shown, so it is the right place to drop the non-pixel reprojection error
    /// (see `reprojectionErrorIsUnreliable`) without touching the acceptance gate.
    public init(score: ReconstructionScore, mapper: String, capturedAt: Date) {
        let reproj = Self.reprojectionErrorIsUnreliable(forMapper: mapper) ? nil : score.meanReprojectionError
        self.init(
            mapper: mapper,
            capturedAt: capturedAt,
            registeredImages: score.registeredImages,
            totalImages: score.totalImages,
            meanReprojectionError: reproj,
            pointCount: score.pointCount,
            observationCount: score.observationCount,
            meanTrackLength: score.meanTrackLength
        )
    }
}

/// Legacy share counters retained only to decode older project metadata.
public struct ShareMetrics: Codable, Sendable, Equatable {
    public var shareClickedCount: Int
    public var shareCompletedCount: Int
    public var lastShareService: String?
    public var lastSharedAt: Date?

    public init(
        shareClickedCount: Int = 0,
        shareCompletedCount: Int = 0,
        lastShareService: String? = nil,
        lastSharedAt: Date? = nil
    ) {
        self.shareClickedCount = shareClickedCount
        self.shareCompletedCount = shareCompletedCount
        self.lastShareService = lastShareService
        self.lastSharedAt = lastSharedAt
    }
}

/// Resume and recovery marker captured while a pipeline stage is in flight.
public struct PipelineCheckpoint: Codable, Sendable {
    public var stage: PipelineStage
    public var updatedAt: Date
    public var progressFraction: Double?
    public var message: String?
    public var details: PipelineCheckpointDetails?

    public init(
        stage: PipelineStage,
        updatedAt: Date = Date(),
        progressFraction: Double? = nil,
        message: String? = nil,
        details: PipelineCheckpointDetails? = nil
    ) {
        self.stage = stage
        self.updatedAt = updatedAt
        self.progressFraction = progressFraction
        self.message = message
        self.details = details
    }
}

/// Stage-specific payload attached to a pipeline checkpoint.
public enum PipelineCheckpointDetails: Codable, Sendable {
    case extractFrames(ExtractFramesCheckpoint)
    case selectFrames(SelectFramesCheckpoint)
    case sfmFeatures(SfmFeaturesCheckpoint)
    case sfmMatching(SfmMatchingCheckpoint)
    case sfmMapping(SfmMappingCheckpoint)
    case trainSplat(TrainSplatCheckpoint)
    case exportSplat(ExportSplatCheckpoint)

    private enum CaseKey: String, CodingKey {
        case extractFrames
        case selectFrames
        case sfmFeatures
        case sfmMatching
        case sfmMapping
        case trainSplat
        case trainBrush
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
        case .sfmMapping:
            self = .sfmMapping(try decode(SfmMappingCheckpoint.self, for: key))
        case .trainSplat, .trainBrush:
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
        case .sfmMapping(let details):
            var value = container.nestedContainer(keyedBy: ValueKey.self, forKey: .sfmMapping)
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

    public init(databasePath: String, imageCount: Int) {
        self.databasePath = databasePath
        self.imageCount = imageCount
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

/// Checkpoint details for sparse reconstruction output.
public struct SfmMappingCheckpoint: Codable, Sendable {
    public var mapper: String
    public var sparsePath: String
    public var registeredImages: Int?

    public init(mapper: String, sparsePath: String, registeredImages: Int?) {
        self.mapper = mapper
        self.sparsePath = sparsePath
        self.registeredImages = registeredImages
    }
}

/// Checkpoint details for training progress. Legacy Brush fields remain decode-compatible.
public struct TrainSplatCheckpoint: Codable, Sendable {
    public var latestExportStep: Int?
    public var latestExportPath: String?
    public var progressStep: Int?
    public var progressTotal: Int?
    public var stepsPerSecond: Double?
    public var resumeSnapshotPath: String?
    public var trainingBackend: TrainingBackend?

    private enum CodingKeys: String, CodingKey {
        case latestExportStep
        case latestExportPath
        case progressStep
        case progressTotal
        case stepsPerSecond
        case resumeSnapshotPath
        case trainingBackend
    }

    public init(
        latestExportStep: Int?,
        latestExportPath: String?,
        progressStep: Int?,
        progressTotal: Int?,
        stepsPerSecond: Double?,
        resumeSnapshotPath: String?,
        trainingBackend: TrainingBackend? = nil
    ) {
        self.latestExportStep = latestExportStep
        self.latestExportPath = latestExportPath
        self.progressStep = progressStep
        self.progressTotal = progressTotal
        self.stepsPerSecond = stepsPerSecond
        self.resumeSnapshotPath = resumeSnapshotPath
        self.trainingBackend = trainingBackend
    }

    public init(progressStep: Int? = nil, progressTotal: Int? = nil) {
        latestExportStep = nil
        latestExportPath = nil
        self.progressStep = progressStep
        self.progressTotal = progressTotal
        stepsPerSecond = nil
        resumeSnapshotPath = nil
        trainingBackend = nil
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        latestExportStep = try values.decodeIfPresent(Int.self, forKey: .latestExportStep)
        latestExportPath = try values.decodeIfPresent(String.self, forKey: .latestExportPath)
        progressStep = try values.decodeIfPresent(Int.self, forKey: .progressStep)
        progressTotal = try values.decodeIfPresent(Int.self, forKey: .progressTotal)
        stepsPerSecond = try values.decodeIfPresent(Double.self, forKey: .stepsPerSecond)
        resumeSnapshotPath = try values.decodeIfPresent(String.self, forKey: .resumeSnapshotPath)
        trainingBackend = try values.decodeIfPresent(TrainingBackend.self, forKey: .trainingBackend)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(progressStep, forKey: .progressStep)
        try values.encodeIfPresent(progressTotal, forKey: .progressTotal)
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

/// Normalized user input selection for a project run.
public enum InputSpec: Codable, Sendable {
    case video(files: [String])
    case photos(folder: String)
    case mixed(videos: [String], photosFolder: String)

    public var videoFiles: [String] {
        switch self {
        case .video(let files):
            return files
        case .photos:
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
        }
    }

    public var hasVideos: Bool { !videoFiles.isEmpty }
    public var hasPhotos: Bool { photosFolder != nil }
}

/// High-level capture intent used to tune SfM defaults.
public enum CaptureMode: String, Codable, Sendable {
    case object
    case room
}

/// User-facing quality preset that controls frame and training budgets.
public enum QualityPreset: String, Codable, Sendable {
    case draft
    case standard
    case ultra
}

/// Combination of capture mode and quality preset stored with a project.
public struct PresetSpec: Codable, Sendable {
    public var mode: CaptureMode
    public var quality: QualityPreset

    public init(mode: CaptureMode, quality: QualityPreset) {
        self.mode = mode
        self.quality = quality
    }
}

/// Persisted pipeline state used for status, retry, and resume handling.
public struct PipelineState: Codable, Sendable {
    public var stage: PipelineStage
    public var attempt: Int
    public var lastError: String?
    public var resumeToken: String?

    public init(stage: PipelineStage, attempt: Int, lastError: String?, resumeToken: String?) {
        self.stage = stage
        self.attempt = attempt
        self.lastError = lastError
        self.resumeToken = resumeToken
    }
}

/// Paths for the final exported artifacts recorded in project metadata.
public struct OutputSpec: Codable, Sendable {
    public var splatPlyPath: String
    public var colmapModelPath: String

    public init(splatPlyPath: String, colmapModelPath: String) {
        self.splatPlyPath = splatPlyPath
        self.colmapModelPath = colmapModelPath
    }
}
