import EasySplatCore
import Foundation

struct InstalledCurrentPublishedResult {
    let outputURL: URL
    let metadata: ProjectMetadata
    let publishedResult: ValidatedPublishedResult?
}

extension AppModel {
    @discardableResult
    func viewPreviousResult(at projectURL: URL) -> Bool {
        guard !hasActiveWork else { return false }
        let timingTask = cancelResultViewerTiming()
        let token = UUID()
        currentTaskToken = token
        currentRunOrigin = .resume
        isRunActive = true
        currentProjectURL = projectURL
        currentTask = Task { [self] in
            if let timingTask {
                await timingTask.value
            }
            guard !Task.isCancelled, isCurrentTaskToken(token) else {
                if isCurrentTaskToken(token) {
                    finishRun(taskToken: token, projectRunLeaseOwner: nil)
                }
                return
            }
            guard flushPendingNotesSave() else {
                finishRun(taskToken: token, projectRunLeaseOwner: nil)
                return
            }
            await openPreviousResultTask(
                at: projectURL,
                taskToken: token
            )
        }
        return true
    }

    private func openPreviousResultTask(
        at projectURL: URL,
        taskToken: UUID
    ) async {
        defer {
            finishRun(taskToken: taskToken, projectRunLeaseOwner: nil)
        }
        guard isCurrentTaskToken(taskToken) else { return }
        reset()
        currentProjectURL = projectURL
        viewState = .opening
        statusTitle = "Opening previous result"
        statusDetail = nil
        progress = nil

        do {
            let resolved = try await resolvePublishedResult(at: projectURL)
            guard isCurrentTaskToken(taskToken) else { return }
            guard case .previous = resolved else {
                throw PreviousResultOpenError.unavailable
            }
            let metadata = try ProjectMetadataStore.load(
                from: ProjectPaths(root: projectURL).metadataURL
            )
            guard installResolvedPublishedResult(
                resolved,
                projectURL: projectURL,
                latestMetadata: metadata
            ) else {
                throw PreviousResultOpenError.unavailable
            }
            markProjectOpened(at: projectURL)
            await reloadSubjectIsolationArtifact(for: projectURL)
            guard isCurrentTaskToken(taskToken), isShowingPreviousResult else {
                return
            }
            viewState = .viewer
            refreshProjectSummaries()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentTaskToken(taskToken) else { return }
            clearResolvedPublishedResult()
            outputPlyURL = nil
            currentProjectURL = nil
            viewState = .home
            actionFailure = ActionFailurePresentation(
                title: "Previous splat unavailable",
                message: "EasySplat couldn’t verify the previous result. Try the project again or restore an untampered project copy."
            )
            refreshProjectSummaries()
        }
    }

    func resolvePublishedResult(
        at projectURL: URL
    ) async throws -> ResolvedPublishedResult {
        let resolver = publishedResultResolver
        let worker = Task.detached(priority: .userInitiated) {
            try resolver(projectURL)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    func preservePublishedResultForRetraining(
        at projectURL: URL
    ) async throws -> ValidatedPublishedResult {
        let preserver = publishedResultPreserver
        let worker = Task.detached(priority: .userInitiated) {
            try preserver(projectURL)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    func resolveAndInstallCurrentPublishedResult(
        at projectURL: URL
    ) async throws -> InstalledCurrentPublishedResult {
        let result = try await resolvePublishedResult(at: projectURL)
        guard case .current = result else {
            throw CurrentPublishedResultInstallError.unavailable
        }
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        guard installResolvedPublishedResult(
            result,
            projectURL: projectURL,
            latestMetadata: metadata
        ), let outputURL = outputPlyURL else {
            throw CurrentPublishedResultInstallError.unavailable
        }
        let publishedResult: ValidatedPublishedResult? = switch result {
        case .current(.receiptBound(let current)):
            current.publishedResult
        case .current(.legacy), .previous, .unavailable:
            nil
        }
        return InstalledCurrentPublishedResult(
            outputURL: outputURL,
            metadata: metadata,
            publishedResult: publishedResult
        )
    }

    func prepareViewerTiming(
        for installed: InstalledCurrentPublishedResult,
        projectURL: URL,
        projectRootIdentity: AppProjectRootIdentity?,
        boundary: RunTimingBoundary?
    ) {
        guard let publishedResult = installed.publishedResult,
              let generation = publishedResult.generation else {
            cancelResultViewerTiming()
            return
        }
        let publicationID = publishedResult.receipt.publicationID
        if let elapsedSeconds = publishedResult.receipt.presentation
            .createToViewerReadySeconds {
            if installed.metadata.createToViewerReadySeconds != elapsedSeconds {
                prepareResultViewerTimingMetadataHealing(
                    projectID: installed.metadata.id,
                    projectURL: projectURL,
                    outputURL: installed.outputURL,
                    expectedPublicationID: publicationID,
                    expectedGeneration: generation,
                    elapsedSeconds: elapsedSeconds,
                    projectRootIdentity: projectRootIdentity
                )
            } else {
                cancelResultViewerTiming()
            }
        } else if let boundary {
            prepareResultViewerTiming(
                projectID: installed.metadata.id,
                projectURL: projectURL,
                outputURL: installed.outputURL,
                expectedPublicationID: publicationID,
                expectedGeneration: generation,
                projectRootIdentity: projectRootIdentity,
                boundary: boundary
            )
        } else {
            cancelResultViewerTiming()
        }
    }

    @discardableResult
    func installResolvedPublishedResult(
        _ result: ResolvedPublishedResult,
        projectURL: URL,
        latestMetadata: ProjectMetadata
    ) -> Bool {
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL) else {
            return false
        }
        let outputURL: URL
        let liveProject: PublishedResultLiveProject
        let presentation: PublishedResultPresentation?
        let snapshot: ProjectArtifactSnapshot?
        let evidence: ValidatedPlyArtifactEvidence?
        let isPrevious: Bool

        switch result {
        case .current(.receiptBound(let current)):
            outputURL = current.publishedResult.outputURL
            liveProject = current.liveProject
            presentation = current.presentation
            snapshot = current.snapshot
            evidence = current.publishedResult.outputEvidence
            isPrevious = false
        case .current(.legacy(let legacy)):
            outputURL = legacy.outputURL
            liveProject = legacy.liveProject
            presentation = nil
            snapshot = legacy.snapshot
            evidence = nil
            isPrevious = false
        case .previous(let previous):
            outputURL = previous.publishedResult.outputURL
            liveProject = previous.liveProject
            presentation = previous.presentation
            snapshot = nil
            evidence = previous.publishedResult.outputEvidence
            isPrevious = true
        case .unavailable:
            return false
        }

        let paths = ProjectPaths(root: projectURL)
        guard liveProject.projectID == latestMetadata.id,
              ProjectSummary.hasSameLocation(outputURL, paths.outputSplatURL)
        else {
            return false
        }
        resolvedPublishedResult = result
        outputPlyURL = paths.outputSplatURL
        currentRunOptions = presentation?.requestedRunOptions
            ?? snapshot?.metadata.requestedRunOptions
        currentInput = latestMetadata.input
        currentStageTimings = presentation?.stageTimings
            ?? snapshot?.metadata.stageTimings
            ?? []
        currentCreateToViewerReadySeconds = presentation?
            .createToViewerReadySeconds
            ?? snapshot?.metadata.createToViewerReadySeconds
        if let evidence, evidence.byteCount <= UInt64(Int64.max) {
            currentOutputPlyInfo = OutputPlyInfo(
                vertexCount: evidence.vertexCount,
                sizeBytes: Int64(evidence.byteCount),
                format: evidence.format
            )
        } else {
            currentOutputPlyInfo = OutputPlyInfo.load(from: paths.outputSplatURL)
        }
        currentProjectNotes = liveProject.notes ?? ""
        currentViewerPreferences = liveProject.viewerPreferences
        hasValidatedPreviousResult = isPrevious
        previousResultAttemptOutcome = isPrevious
            ? (latestMetadata.state.lastError == nil ? .interrupted : .failed)
            : nil
        return true
    }

    func clearResolvedPublishedResult() {
        resolvedPublishedResult = nil
        hasValidatedPreviousResult = false
        previousResultAttemptOutcome = nil
        currentViewerPreferences = ViewerPreferences()
    }

    func refreshPreviousResultAvailability(
        at projectURL: URL,
        expectedTaskToken: UUID? = nil
    ) async {
        if let expectedTaskToken,
           !isCurrentTaskToken(expectedTaskToken) {
            return
        }
        let result: ResolvedPublishedResult
        do {
            result = try await resolvePublishedResult(at: projectURL)
        } catch {
            if let expectedTaskToken,
               !isCurrentTaskToken(expectedTaskToken) {
                return
            }
            guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL)
            else { return }
            hasValidatedPreviousResult = false
            return
        }
        if let expectedTaskToken,
           !isCurrentTaskToken(expectedTaskToken) {
            return
        }
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL)
        else { return }
        if case .previous = result {
            hasValidatedPreviousResult = true
        } else {
            hasValidatedPreviousResult = false
        }
    }
}

private enum PreviousResultOpenError: Error {
    case unavailable
}

private enum CurrentPublishedResultInstallError: Error {
    case unavailable
}
