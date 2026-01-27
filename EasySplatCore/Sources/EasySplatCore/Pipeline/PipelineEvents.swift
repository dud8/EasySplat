import Foundation

public enum PipelineEvent: Codable, Sendable {
    case stageStarted(stage: PipelineStage)
    case stageProgress(stage: PipelineStage, fraction: Double, message: String)
    case stageLog(stage: PipelineStage, line: String, isError: Bool)
    case stageFinished(stage: PipelineStage)
    case pipelineFailed(stage: PipelineStage, userMessage: String, debugMessage: String)
}

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
