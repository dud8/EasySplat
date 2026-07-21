import Foundation

public struct GeometryRequest: Sendable {
    public let projectURL: URL
    public let selectedImages: [URL]
    public let requestedOptions: RequestedRunOptions
    public let resolvedPlan: ResolvedRunPlan
    public let events: @Sendable (PipelineEvent) -> Void

    public init(
        projectURL: URL,
        selectedImages: [URL],
        requestedOptions: RequestedRunOptions,
        resolvedPlan: ResolvedRunPlan,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) {
        self.projectURL = projectURL
        self.selectedImages = selectedImages
        self.requestedOptions = requestedOptions
        self.resolvedPlan = resolvedPlan
        self.events = events
    }
}

public struct TrainingRequest: Sendable {
    public let projectURL: URL
    public let canonicalGeometry: GeometryArtifact
    public let requestedOptions: RequestedRunOptions
    public let resolvedPlan: ResolvedRunPlan
    public let events: @Sendable (PipelineEvent) -> Void

    public init(
        projectURL: URL,
        canonicalGeometry: GeometryArtifact,
        requestedOptions: RequestedRunOptions,
        resolvedPlan: ResolvedRunPlan,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) {
        self.projectURL = projectURL
        self.canonicalGeometry = canonicalGeometry
        self.requestedOptions = requestedOptions
        self.resolvedPlan = resolvedPlan
        self.events = events
    }
}

public protocol GeometrySolving: Sendable {
    func solve(_ request: GeometryRequest) async throws -> GeometryArtifact
}

public protocol SplatTraining: Sendable {
    func train(_ request: TrainingRequest) async throws -> TrainingArtifact
}
