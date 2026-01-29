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

    public init(
        formatVersion: Int = 1,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        input: InputSpec,
        preset: PresetSpec,
        state: PipelineState = PipelineState(stage: .importInput, attempt: 0, lastError: nil, resumeToken: nil),
        outputs: OutputSpec? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.input = input
        self.preset = preset
        self.state = state
        self.outputs = outputs
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
