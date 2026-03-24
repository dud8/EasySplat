import Foundation

public struct ProjectMetadata: Codable, Sendable {
    public var formatVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var input: InputSpec
    public var preset: PresetSpec
    public var state: PipelineState
    public var outputs: OutputSpec?
    public var checkpoint: PipelineCheckpoint?
    public var recoveryPromptSuppressed: Bool?
    public var lastRunStartedAt: Date?
    public var shareMetrics: ShareMetrics?

    public init(
        formatVersion: Int = 1,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        input: InputSpec,
        preset: PresetSpec,
        state: PipelineState = PipelineState(stage: .importInput, attempt: 0, lastError: nil, resumeToken: nil),
        outputs: OutputSpec? = nil,
        checkpoint: PipelineCheckpoint? = nil,
        recoveryPromptSuppressed: Bool? = nil,
        lastRunStartedAt: Date? = nil,
        shareMetrics: ShareMetrics? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.input = input
        self.preset = preset
        self.state = state
        self.outputs = outputs
        self.checkpoint = checkpoint
        self.recoveryPromptSuppressed = recoveryPromptSuppressed
        self.lastRunStartedAt = lastRunStartedAt
        self.shareMetrics = shareMetrics
    }
}

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

public enum PipelineCheckpointDetails: Codable, Sendable {
    case extractFrames(ExtractFramesCheckpoint)
    case selectFrames(SelectFramesCheckpoint)
    case sfmFeatures(SfmFeaturesCheckpoint)
    case sfmMatching(SfmMatchingCheckpoint)
    case sfmMapping(SfmMappingCheckpoint)
    case trainBrush(TrainBrushCheckpoint)
    case exportSplat(ExportSplatCheckpoint)
}

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

public struct SfmFeaturesCheckpoint: Codable, Sendable {
    public var databasePath: String
    public var imageCount: Int

    public init(databasePath: String, imageCount: Int) {
        self.databasePath = databasePath
        self.imageCount = imageCount
    }
}

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

public struct TrainBrushCheckpoint: Codable, Sendable {
    public var latestExportStep: Int?
    public var latestExportPath: String?
    public var progressStep: Int?
    public var progressTotal: Int?
    public var stepsPerSecond: Double?
    public var resumeSnapshotPath: String?

    public init(
        latestExportStep: Int?,
        latestExportPath: String?,
        progressStep: Int?,
        progressTotal: Int?,
        stepsPerSecond: Double?,
        resumeSnapshotPath: String?
    ) {
        self.latestExportStep = latestExportStep
        self.latestExportPath = latestExportPath
        self.progressStep = progressStep
        self.progressTotal = progressTotal
        self.stepsPerSecond = stepsPerSecond
        self.resumeSnapshotPath = resumeSnapshotPath
    }
}

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

public enum CaptureMode: String, Codable, Sendable {
    case object
    case room
}

public enum QualityPreset: String, Codable, Sendable {
    case draft
    case standard
    case ultra
}

public struct PresetSpec: Codable, Sendable {
    public var mode: CaptureMode
    public var quality: QualityPreset

    public init(mode: CaptureMode, quality: QualityPreset) {
        self.mode = mode
        self.quality = quality
    }
}

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

public struct OutputSpec: Codable, Sendable {
    public var splatPlyPath: String
    public var colmapModelPath: String

    public init(splatPlyPath: String, colmapModelPath: String) {
        self.splatPlyPath = splatPlyPath
        self.colmapModelPath = colmapModelPath
    }
}
