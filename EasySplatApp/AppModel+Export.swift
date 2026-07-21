import EasySplatCore
import Foundation

enum CurrentSplatExportError: LocalizedError {
    case noFinishedOutput

    var errorDescription: String? {
        switch self {
        case .noFinishedOutput:
            return "This project does not have a valid finished splat to export."
        }
    }
}

extension AppModel {
    typealias CurrentSplatPublisher = @Sendable (
        _ source: URL,
        _ destination: URL,
        _ expected: ExpectedPlyArtifactIdentity
    ) throws -> Void

    struct CurrentSplatPublicationSource: Equatable {
        let projectURL: URL
        let outputURL: URL
        let expectedIdentity: ExpectedPlyArtifactIdentity
    }

    func validatedCurrentSplatForExport() async throws -> URL {
        try await validatedCurrentSplatForPublication().outputURL
    }

    func validatedCurrentSplatForPublication() async throws -> CurrentSplatPublicationSource {
        guard let projectURL = currentProjectURL,
              let source = try await validatedFinishedOutputURL(projectURL: projectURL) else {
            throw CurrentSplatExportError.noFinishedOutput
        }
        let snapshot: ProjectArtifactSnapshot
        do {
            snapshot = try ProjectArtifactSnapshotStore.load(projectURL: projectURL)
        } catch {
            throw CurrentSplatExportError.noFinishedOutput
        }
        let expectedOutputURL = ProjectPaths(root: projectURL).outputSplatURL
        guard let training = snapshot.trainingArtifact,
              training.completionStatus == .completed,
              training.outputPath == "Output/splat.ply",
              let expectedIdentity = Self.expectedPlyIdentity(from: training),
              ProjectSummary.hasSameLocation(source, expectedOutputURL) else {
            throw CurrentSplatExportError.noFinishedOutput
        }
        try Task.checkCancellation()
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL) else {
            throw CancellationError()
        }
        return CurrentSplatPublicationSource(
            projectURL: projectURL.standardizedFileURL,
            outputURL: source.standardizedFileURL,
            expectedIdentity: expectedIdentity
        )
    }

    func exportCurrentSplat(to destination: URL) async throws {
        try await exportCurrentSplat(
            to: destination,
            publisher: { source, destination, expected in
                try Self.exportValidatedSplat(
                    from: source,
                    to: destination,
                    expected: expected
                )
            }
        )
    }

    func exportCurrentSplat(
        to destination: URL,
        publisher: @escaping CurrentSplatPublisher
    ) async throws {
        let source = try await validatedCurrentSplatForPublication()
        let worker = Task.detached(priority: .userInitiated) {
            try publisher(source.outputURL, destination, source.expectedIdentity)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
    }

    nonisolated static func exportValidatedSplat(from source: URL, to destination: URL) throws {
        try exportValidatedSplat(from: source, to: destination, expected: nil)
    }

    nonisolated static func exportValidatedSplat(
        from source: URL,
        to destination: URL,
        expected: ExpectedPlyArtifactIdentity?
    ) throws {
        if source.standardizedFileURL == destination.standardizedFileURL {
            return
        }
        if let expected {
            _ = try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: expected
            )
        } else {
            _ = try ProjectArtifactValidator.publishValidatedPly(from: source, to: destination)
        }
    }

    nonisolated static func expectedPlyIdentity(
        from artifact: TrainingArtifact?
    ) -> ExpectedPlyArtifactIdentity? {
        guard let artifact,
              let outputSHA256 = artifact.outputSHA256,
              let outputBytes = artifact.outputBytes,
              outputBytes > 0,
              artifact.gaussianCount > 0 else {
            return nil
        }
        return ExpectedPlyArtifactIdentity(
            byteCount: UInt64(outputBytes),
            vertexCount: artifact.gaussianCount,
            sha256: outputSHA256
        )
    }
}
