import Foundation

/// Event stream emitted by `PipelineRunner` while processing a project.
public enum PipelineEvent: Codable, Sendable {
    case stageStarted(stage: PipelineStage)
    case stageProgress(stage: PipelineStage, fraction: Double, message: String)
    case stageLog(stage: PipelineStage, line: String, isError: Bool)
    case stageFinished(stage: PipelineStage)
    case pipelineFailed(stage: PipelineStage, userMessage: String, debugMessage: String)
    /// A live training preview was republished. Ephemeral by design: nothing durable
    /// is derived from it, and dropping one costs a redraw.
    case trainingPreviewPublished(
        url: URL,
        iteration: Int,
        publication: Int,
        sceneBounds: SplatSceneBounds
    )
    /// The trainer stopped publishing previews for this run. Training continues;
    /// anything already on screen is frozen and must stop being presented as live.
    case trainingPreviewDisabled(reason: String)
}
