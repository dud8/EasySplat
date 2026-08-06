import EasySplatCore
import Foundation

enum CurrentSplatExportError: LocalizedError {
    case noFinishedOutput
    case noValidSubjectOutput

    var errorDescription: String? {
        switch self {
        case .noFinishedOutput:
            return "This project does not have a valid finished splat to export."
        case .noValidSubjectOutput:
            return "This project does not have a valid Subject splat to export."
        }
    }
}

extension AppModel {
    typealias CurrentSplatPublisher = @Sendable (
        _ source: URL,
        _ destination: URL,
        _ expected: ExpectedPlyArtifactIdentity
    ) throws -> Void

    struct CurrentSplatPublicationSource: Equatable, Sendable {
        let projectURL: URL
        let variant: SplatOutputVariant
        let outputURL: URL
        let expectedIdentity: ExpectedPlyArtifactIdentity
        let defaultFilename: String
    }

    func validatedCurrentSplatForExport() async throws -> URL {
        try await validatedCurrentSplatForPublication().outputURL
    }

    func validatedCurrentSplatForPublication() async throws -> CurrentSplatPublicationSource {
        guard let projectURL = currentProjectURL else {
            throw CurrentSplatExportError.noFinishedOutput
        }
        let variant = selectedSplatOutputVariant
        let selectedSubjectOutput = subjectOutput
        let validator = finishedOutputValidator
        let subjectLoader = subjectIsolationArtifactLoader
        let validation = Task.detached(priority: .userInitiated) {
            try Self.publicationSource(
                projectURL: projectURL,
                variant: variant,
                selectedSubjectOutput: selectedSubjectOutput,
                finishedOutputValidator: validator,
                subjectArtifactLoader: subjectLoader
            )
        }
        let source = try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: {
            validation.cancel()
        }
        try Task.checkCancellation()
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL),
              selectedSplatOutputVariant == variant else {
            throw CancellationError()
        }
        return source
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
        try await exportCurrentSplat(source, to: destination, publisher: publisher)
    }

    func exportCurrentSplat(
        _ source: CurrentSplatPublicationSource,
        to destination: URL
    ) async throws {
        try await exportCurrentSplat(
            source,
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
        _ source: CurrentSplatPublicationSource,
        to destination: URL,
        publisher: @escaping CurrentSplatPublisher
    ) async throws {
        // The save panel's grant belongs to the URL it returned, and the write runs
        // off the main actor after the panel closed. Hold the scope across it so a
        // sandboxed build can finish the export it was told to make.
        let destinationAccess = SecurityScopedAccess()
        destinationAccess.claim([destination])
        defer { destinationAccess.releaseAll() }
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

    private nonisolated static func publicationSource(
        projectURL: URL,
        variant: SplatOutputVariant,
        selectedSubjectOutput: ValidatedSplatOutput?,
        finishedOutputValidator: FinishedOutputValidator,
        subjectArtifactLoader: SubjectIsolationArtifactLoader
    ) throws -> CurrentSplatPublicationSource {
        try Task.checkCancellation()
        let paths = ProjectPaths(root: projectURL)
        let title: String
        let outputURL: URL
        let expectedIdentity: ExpectedPlyArtifactIdentity

        switch variant {
        case .original:
            guard let validatedOutputURL = finishedOutputValidator(projectURL),
                  ProjectSummary.hasSameLocation(
                      validatedOutputURL,
                      paths.outputSplatURL
                  ) else {
                throw CurrentSplatExportError.noFinishedOutput
            }
            try Task.checkCancellation()
            let snapshot: ProjectArtifactSnapshot
            do {
                snapshot = try ProjectArtifactSnapshotStore.load(
                    projectURL: projectURL
                )
            } catch {
                throw CurrentSplatExportError.noFinishedOutput
            }
            guard let training = snapshot.trainingArtifact,
                  training.completionStatus == .completed,
                  training.outputPath == "Output/splat.ply",
                  let identity = expectedPlyIdentity(from: training) else {
                throw CurrentSplatExportError.noFinishedOutput
            }
            title = snapshot.metadata.title
            outputURL = validatedOutputURL
            expectedIdentity = identity

        case .subject:
            guard let selectedSubjectOutput,
                  selectedSubjectOutput.variant == .subject,
                  ProjectSummary.hasSameLocation(
                      selectedSubjectOutput.url,
                      paths.isolatedOutputURL
                  ),
                  let selectedIdentity = expectedPlyIdentity(
                      from: selectedSubjectOutput
                  ),
                  case .valid(_, let validatedOutput) =
                    subjectArtifactLoader(paths),
                  validatedOutput.variant == .subject,
                  ProjectSummary.hasSameLocation(
                      validatedOutput.url,
                      selectedSubjectOutput.url
                  ),
                  ProjectSummary.hasSameLocation(
                      validatedOutput.url,
                      paths.isolatedOutputURL
                  ),
                  let validatedIdentity = expectedPlyIdentity(
                      from: validatedOutput
                  ),
                  validatedIdentity == selectedIdentity else {
                throw CurrentSplatExportError.noValidSubjectOutput
            }
            do {
                title = try ProjectMetadataStore.load(
                    from: paths.metadataURL
                ).title
            } catch {
                throw CurrentSplatExportError.noValidSubjectOutput
            }
            outputURL = validatedOutput.url
            expectedIdentity = validatedIdentity
        }
        try Task.checkCancellation()
        return CurrentSplatPublicationSource(
            projectURL: projectURL.standardizedFileURL,
            variant: variant,
            outputURL: outputURL.standardizedFileURL,
            expectedIdentity: expectedIdentity,
            defaultFilename: publicationFilename(title: title, variant: variant)
        )
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
        // The destination came from a save panel, so the sandbox grants the file
        // itself and not the directory around it.
        if let expected {
            _ = try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: expected,
                destinationKind: .userSelected
            )
        } else {
            _ = try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                destinationKind: .userSelected
            )
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

    nonisolated static func expectedPlyIdentity(
        from output: ValidatedSplatOutput
    ) -> ExpectedPlyArtifactIdentity? {
        guard output.byteCount > 0,
              output.gaussianCount > 0,
              output.sha256.count == 64 else {
            return nil
        }
        return ExpectedPlyArtifactIdentity(
            byteCount: output.byteCount,
            vertexCount: output.gaussianCount,
            sha256: output.sha256
        )
    }

    nonisolated static func publicationFilename(
        title: String,
        variant: SplatOutputVariant
    ) -> String {
        let normalizedTitle = title.precomposedStringWithCanonicalMapping
        var component = ""
        var separatorPending = false
        for scalar in normalizedTitle.unicodeScalars {
            let isUnsafeSeparator = scalar == "/" || scalar == "\\" || scalar == ":"
            let isSpacing = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if isUnsafeSeparator || isSpacing {
                if !component.isEmpty { separatorPending = true }
                continue
            }
            if separatorPending {
                component.append(" ")
                separatorPending = false
            }
            component.unicodeScalars.append(scalar)
        }
        component = component.trimmingCharacters(in: .whitespacesAndNewlines)
        while component.first == "." {
            component.removeFirst()
        }
        component = component.trimmingCharacters(in: .whitespacesAndNewlines)
        if component.isEmpty {
            component = "Project"
        }

        let suffix = variant == .subject ? " (Subject).ply" : ".ply"
        let maximumStemBytes = 240 - suffix.utf8.count
        var bounded = ""
        for character in component {
            let candidate = bounded + String(character)
            guard candidate.utf8.count <= maximumStemBytes else { break }
            bounded = candidate
        }
        bounded = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        return (bounded.isEmpty ? "Project" : bounded) + suffix
    }
}
