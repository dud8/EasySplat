import Foundation

/// Persisted top-level metadata for a single `.easysplatproj` bundle.
public struct ProjectMetadata: Codable, Sendable {
    public var formatVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var input: InputSpec
    public var requestedRunOptions: RequestedRunOptions
    public var resolvedRunPlan: ResolvedRunPlan?
    public var trainingMemoryRetryBudgetBytes: Int64?
    public var geometryRecovery: GeometryRecoveryState?
    public var geometryArtifact: GeometryArtifact?
    public var trainingArtifact: TrainingArtifact?
    public var viewerPreferences: ViewerPreferences
    public var state: PipelineState
    public var outputs: OutputSpec?
    public var checkpoint: PipelineCheckpoint?
    public var lastRunStartedAt: Date?
    public var reconstruction: ReconstructionSummary?
    public var stageTimings: [StageTimingRecord]?
    public var notes: String?
    public var lastFailureAt: Date?

    public init(
        formatVersion: Int = ProjectMetadataStore.supportedFormatVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        input: InputSpec,
        requestedRunOptions: RequestedRunOptions = RequestedRunOptions(),
        resolvedRunPlan: ResolvedRunPlan? = nil,
        trainingMemoryRetryBudgetBytes: Int64? = nil,
        geometryRecovery: GeometryRecoveryState? = nil,
        geometryArtifact: GeometryArtifact? = nil,
        trainingArtifact: TrainingArtifact? = nil,
        viewerPreferences: ViewerPreferences = ViewerPreferences(),
        state: PipelineState = PipelineState(stage: .importInput, lastError: nil),
        outputs: OutputSpec? = nil,
        checkpoint: PipelineCheckpoint? = nil,
        lastRunStartedAt: Date? = nil,
        reconstruction: ReconstructionSummary? = nil,
        stageTimings: [StageTimingRecord]? = nil,
        notes: String? = nil,
        lastFailureAt: Date? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.input = input
        self.requestedRunOptions = requestedRunOptions
        self.resolvedRunPlan = resolvedRunPlan
        self.trainingMemoryRetryBudgetBytes = trainingMemoryRetryBudgetBytes
        self.geometryRecovery = geometryRecovery
        self.geometryArtifact = geometryArtifact
        self.trainingArtifact = trainingArtifact
        self.viewerPreferences = viewerPreferences
        self.state = state
        self.outputs = outputs
        self.checkpoint = checkpoint
        self.lastRunStartedAt = lastRunStartedAt
        self.reconstruction = reconstruction
        self.stageTimings = stageTimings
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

/// Persisted measurements from the accepted sparse reconstruction.
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
    /// Bridges the measured per-run score onto the persisted summary.
    public init(score: ReconstructionScore, mapper: String, capturedAt: Date) {
        self.init(
            mapper: mapper,
            capturedAt: capturedAt,
            registeredImages: score.registeredImages,
            totalImages: score.totalImages,
            meanReprojectionError: score.meanReprojectionError,
            pointCount: score.pointCount,
            observationCount: score.observationCount,
            meanTrackLength: score.meanTrackLength
        )
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

/// Persisted pipeline state used for status, retry, and resume handling.
public struct PipelineState: Codable, Sendable {
    public var stage: PipelineStage
    public var lastError: String?

    public init(stage: PipelineStage, lastError: String?) {
        self.stage = stage
        self.lastError = lastError
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
