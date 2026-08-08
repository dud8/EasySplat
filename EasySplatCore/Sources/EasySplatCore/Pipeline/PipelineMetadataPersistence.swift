import Foundation

package enum PipelineMetadataWriteOperation: String, Sendable, Hashable, CaseIterable {
    case runStart
    case checkpoint
    case stageCompletion
    case developmentStop
    case skipTrainingCompletion
    case terminalFailure
    case finalCompletion
}

package struct PipelinePresentedProcessingFailure: Sendable, Equatable {
    package let userMessage: String
    package let technicalMessage: String

    package init(userMessage: String, technicalMessage: String) {
        self.userMessage = userMessage
        self.technicalMessage = technicalMessage
    }
}

package struct PipelineMetadataPersistenceFailure: Error, LocalizedError, Sendable, Equatable {
    package static let maximumSummaryBytes = 512

    package let operation: PipelineMetadataWriteOperation
    package let stage: PipelineStage
    package let persistenceErrorSummary: String
    package let originalProcessingFailure: PipelinePresentedProcessingFailure?
    package let terminalFailureWasPersisted: Bool

    package init(
        operation: PipelineMetadataWriteOperation,
        stage: PipelineStage,
        persistenceError: Error,
        originalProcessingFailure: PipelinePresentedProcessingFailure? = nil,
        terminalFailureWasPersisted: Bool = false
    ) {
        self.operation = operation
        self.stage = stage
        self.persistenceErrorSummary = Self.boundedSummary(for: persistenceError)
        self.originalProcessingFailure = originalProcessingFailure
        self.terminalFailureWasPersisted = terminalFailureWasPersisted
    }

    private init(
        operation: PipelineMetadataWriteOperation,
        stage: PipelineStage,
        persistenceErrorSummary: String,
        originalProcessingFailure: PipelinePresentedProcessingFailure?,
        terminalFailureWasPersisted: Bool
    ) {
        self.operation = operation
        self.stage = stage
        self.persistenceErrorSummary = persistenceErrorSummary
        self.originalProcessingFailure = originalProcessingFailure
        self.terminalFailureWasPersisted = terminalFailureWasPersisted
    }

    package func recordingPersistedTerminalFailure()
        -> PipelineMetadataPersistenceFailure {
        PipelineMetadataPersistenceFailure(
            operation: operation,
            stage: stage,
            persistenceErrorSummary: persistenceErrorSummary,
            originalProcessingFailure: originalProcessingFailure,
            terminalFailureWasPersisted: true
        )
    }

    package var errorDescription: String? {
        "Project metadata could not be saved during \(operation.rawValue) at "
            + "\(stage.rawValue): \(persistenceErrorSummary)"
    }

    private static func boundedSummary(for error: Error) -> String {
        let localized = error.localizedDescription
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let reflected = String(reflecting: error)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let combined = localized == reflected
            ? localized
            : "\(localized) [\(reflected)]"
        var bytes = Array(combined.utf8.prefix(maximumSummaryBytes))
        while String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

package typealias PipelineMetadataWriter = @Sendable (
    _ metadata: ProjectMetadata,
    _ metadataURL: URL,
    _ operation: PipelineMetadataWriteOperation,
    _ stage: PipelineStage
) throws -> Void
