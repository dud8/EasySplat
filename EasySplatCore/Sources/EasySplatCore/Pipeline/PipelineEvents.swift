import Foundation

/// Event stream emitted by `PipelineRunner` while processing a project.
public enum PipelineEvent: Codable, Sendable {
    case stageStarted(stage: PipelineStage)
    case stageProgress(stage: PipelineStage, fraction: Double, message: String)
    case stageLog(stage: PipelineStage, line: String, isError: Bool)
    case stageFinished(stage: PipelineStage)
    case pipelineFailed(stage: PipelineStage, userMessage: String, debugMessage: String)
}
