import Foundation

/// Event stream emitted by `PipelineRunner` while processing a project.
public enum PipelineEvent: Codable, Sendable {
    case stageStarted(stage: PipelineStage)
    case stageProgress(stage: PipelineStage, fraction: Double, message: String)
    case stageLog(stage: PipelineStage, line: String, isError: Bool)
    case trainingBackendSelected(backend: TrainingBackend)
    case stageFinished(stage: PipelineStage)
    case pipelineFailed(stage: PipelineStage, userMessage: String, debugMessage: String)
}

public enum TrainingBackend: String, Codable, Sendable {
    case brush
    case msplat
}

/// Snapshot of user-facing progress for a single pipeline stage.
public struct PipelineProgress: Sendable {
    public var stage: PipelineStage
    public var fraction: Double
    public var message: String

    public init(stage: PipelineStage, fraction: Double, message: String) {
        self.stage = stage
        self.fraction = fraction
        self.message = message
    }
}
