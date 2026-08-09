import EasySplatCore
import Foundation
import OSLog

private let projectLibraryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.easysplat.app",
    category: "ProjectLibrary"
)

private final class SynchronizedAppValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock { storedValue = value }
    }
}

struct RunTimingBoundary: Sendable {
    struct Sample: Sendable, Equatable {
        let wallClock: Date
        let monotonicSeconds: TimeInterval
    }

    let startedAt: Date
    private let elapsed: @Sendable () -> TimeInterval

    static func capture() -> RunTimingBoundary {
        let clock = ContinuousClock()
        let monotonicStartedAt = clock.now
        return RunTimingBoundary(startedAt: Date()) {
            durationSeconds(clock.now - monotonicStartedAt)
        }
    }

    static func capture(
        sample: @escaping @Sendable () -> Sample
    ) -> RunTimingBoundary {
        let started = sample()
        return RunTimingBoundary(startedAt: started.wallClock) {
            sample().monotonicSeconds - started.monotonicSeconds
        }
    }

    func elapsedSeconds() -> TimeInterval {
        let seconds = elapsed()
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return seconds
    }

    private static func durationSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}

struct PendingResultViewerTiming: Sendable {
    enum Phase: Sendable, Equatable {
        case awaitingViewerReady
        case updatingReceipt
    }

    let generationID: UUID
    let projectID: UUID
    let projectURL: URL
    let outputURL: URL
    let projectRootIdentity: AppProjectRootIdentity
    let expectedPublicationID: UUID
    let expectedGeneration: PublishedResultGeneration?
    let boundary: RunTimingBoundary?
    var firstReadyElapsedSeconds: TimeInterval?
    var phase: Phase

    var isReceiptUpdateInFlight: Bool {
        phase == .updatingReceipt
    }
}

private struct ResultViewerTimingCommitRequest: Sendable {
    let generationID: UUID
    let projectID: UUID
    let projectURL: URL
    let outputURL: URL
    let projectRootIdentity: AppProjectRootIdentity
    let expectedPublicationID: UUID
    let expectedGeneration: PublishedResultGeneration?
    let elapsedSeconds: TimeInterval
    let isMetadataHealing: Bool
}

private enum ResultViewerTimingWorkerResult: Sendable {
    case recorded(ProjectMetadata)
    case retired
}

private enum ResultViewerTimingCommitError: Error {
    case invalidProjectState
}

extension AppModel {
    func prepareResultViewerTiming(
        projectID: UUID,
        projectURL: URL,
        outputURL: URL,
        expectedPublicationID: UUID? = nil,
        expectedGeneration: PublishedResultGeneration? = nil,
        projectRootIdentity suppliedProjectRootIdentity:
            AppProjectRootIdentity? = nil,
        boundary: RunTimingBoundary
    ) {
        cancelResultViewerTiming()
        guard let expectedPublicationID,
              outputURL.standardizedFileURL.path
                == ProjectPaths(root: projectURL).outputSplatURL
                    .standardizedFileURL.path,
              let projectRootIdentity = suppliedProjectRootIdentity
                ?? (try? AppProjectRootIdentity.capture(at: projectURL)) else {
            return
        }
        pendingResultViewerTiming = PendingResultViewerTiming(
            generationID: UUID(),
            projectID: projectID,
            projectURL: projectURL,
            outputURL: outputURL,
            projectRootIdentity: projectRootIdentity,
            expectedPublicationID: expectedPublicationID,
            expectedGeneration: expectedGeneration,
            boundary: boundary,
            firstReadyElapsedSeconds: nil,
            phase: .awaitingViewerReady
        )
    }

    func prepareResultViewerTimingMetadataHealing(
        projectID: UUID,
        projectURL: URL,
        outputURL: URL,
        expectedPublicationID: UUID,
        expectedGeneration: PublishedResultGeneration? = nil,
        elapsedSeconds: TimeInterval,
        projectRootIdentity suppliedProjectRootIdentity:
            AppProjectRootIdentity? = nil
    ) {
        guard elapsedSeconds.isFinite,
              elapsedSeconds >= 0,
              outputURL.standardizedFileURL.path
                == ProjectPaths(root: projectURL).outputSplatURL
                    .standardizedFileURL.path,
              let projectRootIdentity = suppliedProjectRootIdentity
                ?? (try? AppProjectRootIdentity.capture(at: projectURL)) else {
            return
        }
        cancelResultViewerTiming()
        pendingResultViewerTiming = PendingResultViewerTiming(
            generationID: UUID(),
            projectID: projectID,
            projectURL: projectURL,
            outputURL: outputURL,
            projectRootIdentity: projectRootIdentity,
            expectedPublicationID: expectedPublicationID,
            expectedGeneration: expectedGeneration,
            boundary: nil,
            firstReadyElapsedSeconds: elapsedSeconds,
            phase: .awaitingViewerReady
        )
    }

    func resultViewerDidBecomeReady(projectURL: URL, outputURL: URL) {
        guard viewState == .viewer,
              ProjectSummary.hasSameLocation(currentProjectURL, projectURL),
              ProjectSummary.hasSameLocation(outputPlyURL, outputURL),
              var pending = pendingResultViewerTiming,
              ProjectSummary.hasSameLocation(pending.projectURL, projectURL),
              ProjectSummary.hasSameLocation(pending.outputURL, outputURL),
              pending.phase == .awaitingViewerReady,
              resultViewerTimingTask == nil else {
            return
        }
        let elapsedSeconds: TimeInterval
        if let recorded = pending.firstReadyElapsedSeconds {
            elapsedSeconds = recorded
        } else if let boundary = pending.boundary {
            elapsedSeconds = boundary.elapsedSeconds()
            pending.firstReadyElapsedSeconds = elapsedSeconds
        } else {
            pendingResultViewerTiming = nil
            return
        }
        pending.phase = .updatingReceipt
        pendingResultViewerTiming = pending

        let request = ResultViewerTimingCommitRequest(
            generationID: pending.generationID,
            projectID: pending.projectID,
            projectURL: pending.projectURL,
            outputURL: pending.outputURL,
            projectRootIdentity: pending.projectRootIdentity,
            expectedPublicationID: pending.expectedPublicationID,
            expectedGeneration: pending.expectedGeneration,
            elapsedSeconds: elapsedSeconds,
            isMetadataHealing: pending.boundary == nil
        )
        let metadataLoader = projectMetadataDescriptorLoader
        let metadataUpdater = projectMetadataUpdater
        let leaseAcquirer = projectRunLeaseOwnerAcquirer
        let receiptUpdater = resultViewerTimingReceiptUpdater
        let pairOperations = resultViewerTimingPairOperations
        let task = Task.detached(priority: .utility) { [weak self] in
            let result = Self.performResultViewerTimingCommit(
                request: request,
                metadataLoader: metadataLoader,
                metadataUpdater: metadataUpdater,
                leaseAcquirer: leaseAcquirer,
                receiptUpdater: receiptUpdater,
                pairOperations: pairOperations
            )
            await self?.finishResultViewerTimingCommit(
                result,
                generationID: request.generationID
            )
        }
        resultViewerTimingTask = task
    }

    nonisolated private static func performResultViewerTimingCommit(
        request: ResultViewerTimingCommitRequest,
        metadataLoader: ProjectMetadataDescriptorLoader,
        metadataUpdater: ProjectMetadataUpdater,
        leaseAcquirer: ProjectRunLeaseOwnerAcquirer,
        receiptUpdater: ResultViewerTimingReceiptUpdater,
        pairOperations: PublishedResultPairOperations
    ) -> ResultViewerTimingWorkerResult {
        do {
            let leaseOwner = try AppProjectRunLeaseOwner(
                projectURL: request.projectURL,
                acquire: leaseAcquirer
            )
            defer { leaseOwner.release() }
            return try leaseOwner.withValidatedProjectRootDescriptor {
                projectRootDescriptor in
                guard try AppProjectRootIdentity.capture(
                    descriptor: projectRootDescriptor
                ) == request.projectRootIdentity,
                request.outputURL.standardizedFileURL.path
                    == ProjectPaths(root: request.projectURL).outputSplatURL
                        .standardizedFileURL.path else {
                    return .retired
                }
                let metadata: ProjectMetadata
                do {
                    metadata = try loadResultViewerTimingMetadata(
                        descriptor: projectRootDescriptor,
                        loader: metadataLoader
                    )
                } catch {
                    return .retired
                }
                guard isCurrentResultViewerTimingMetadata(
                    metadata,
                    projectID: request.projectID
                ), let resolvedRunPlan = metadata.resolvedRunPlan else {
                    return .retired
                }

                if let recorded = metadata.createToViewerReadySeconds,
                   recorded != request.elapsedSeconds {
                    return .retired
                }
                let elapsedSeconds = request.elapsedSeconds
                guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
                    return .retired
                }
                let projectPaths = ProjectPaths(root: request.projectURL)
                let committedGeneration: PublishedResultGeneration
                var allowingFirstViewerTimingTransition = false
                if request.isMetadataHealing {
                    guard !Task.isCancelled else { return .retired }
                    if let expectedGeneration = request.expectedGeneration {
                        let committed = try PublishedResultPairStore
                            .commitReceiptBoundStateIf(
                                projectPaths: projectPaths,
                                projectRootDescriptor: projectRootDescriptor,
                                expectedGeneration: expectedGeneration,
                                expectedViewerReadySeconds: elapsedSeconds,
                                operations: pairOperations,
                                shouldCancel: { Task.isCancelled },
                                afterValidation: {}
                            )
                        guard committed else { return .retired }
                        committedGeneration = expectedGeneration
                    } else {
                        guard let result = try PublishedResultPublisher
                            .resolveCompletedTraining(
                                metadata: metadata,
                                resolvedRunPlan: resolvedRunPlan,
                                paths: projectPaths,
                                projectRootDescriptor: projectRootDescriptor,
                                pairOperations: pairOperations,
                                shouldCancel: { Task.isCancelled }
                            ),
                            !Task.isCancelled,
                            result.receipt.projectID == request.projectID,
                            result.receipt.publicationID
                                == request.expectedPublicationID,
                            result.receipt.presentation
                                .createToViewerReadySeconds == elapsedSeconds,
                            let generation = result.generation else {
                            return .retired
                        }
                        committedGeneration = generation
                    }
                } else {
                    do {
                        let result = try receiptUpdater(
                            elapsedSeconds,
                            request.expectedPublicationID,
                            request.expectedGeneration,
                            projectPaths,
                            projectRootDescriptor,
                            pairOperations,
                            { Task.isCancelled }
                        )
                        guard result.receipt.projectID == request.projectID,
                              result.receipt.publicationID
                                == request.expectedPublicationID,
                              result.receipt.presentation
                                .createToViewerReadySeconds == elapsedSeconds,
                              let generation = result.generation else {
                            return .retired
                        }
                        committedGeneration = generation
                    } catch is CancellationError {
                        guard let predecessor = request.expectedGeneration else {
                            return .retired
                        }
                        let committed = try PublishedResultPairStore
                            .commitReceiptBoundStateIf(
                                projectPaths: projectPaths,
                                projectRootDescriptor: projectRootDescriptor,
                                expectedGeneration: predecessor,
                                expectedViewerReadySeconds: elapsedSeconds,
                                allowingFirstViewerTimingTransition: true,
                                operations: pairOperations,
                                shouldCancel: { false },
                                afterValidation: {}
                            )
                        guard committed else { return .retired }
                        committedGeneration = predecessor
                        allowingFirstViewerTimingTransition = true
                    } catch {
                        return .retired
                    }
                }

                // Receipt authority is now known to be committed. Cancellation
                // may retire UI state, but it cannot leave project.json stale.
                for attempt in 0..<2 {
                    do {
                        let committedMetadata =
                            SynchronizedAppValue<ProjectMetadata?>(nil)
                        let committed = try PublishedResultPairStore
                            .commitReceiptBoundStateIf(
                                projectPaths: projectPaths,
                                projectRootDescriptor: projectRootDescriptor,
                                expectedGeneration: committedGeneration,
                                expectedViewerReadySeconds: elapsedSeconds,
                                allowingFirstViewerTimingTransition:
                                    allowingFirstViewerTimingTransition,
                                operations: pairOperations,
                                shouldCancel: { false },
                                afterValidation: {
                                    committedMetadata.set(
                                        try metadataUpdater(
                                            projectRootDescriptor
                                        ) { current in
                                            guard isCurrentResultViewerTimingMetadata(
                                                current,
                                                projectID: request.projectID
                                            ) else {
                                                throw ResultViewerTimingCommitError
                                                    .invalidProjectState
                                            }
                                            if let recorded = current
                                                .createToViewerReadySeconds {
                                                guard recorded == elapsedSeconds else {
                                                    throw ResultViewerTimingCommitError
                                                        .invalidProjectState
                                                }
                                            } else {
                                                current.createToViewerReadySeconds =
                                                    elapsedSeconds
                                            }
                                        }
                                    )
                                }
                            )
                        guard committed,
                              let committedMetadata = committedMetadata.value,
                              isCurrentResultViewerTimingMetadata(
                                committedMetadata,
                                projectID: request.projectID
                              ),
                              committedMetadata.createToViewerReadySeconds
                                == elapsedSeconds else {
                            return .retired
                        }
                        return .recorded(committedMetadata)
                    } catch ResultViewerTimingCommitError.invalidProjectState {
                        return .retired
                    } catch {
                        if attempt == 1 { return .retired }
                    }
                }
                return .retired
            }
        } catch {
            return .retired
        }
    }

    nonisolated private static func loadResultViewerTimingMetadata(
        descriptor: Int32,
        loader: ProjectMetadataDescriptorLoader
    ) throws -> ProjectMetadata {
        do {
            if Task.isCancelled { throw CancellationError() }
            return try loader(descriptor)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return try loader(descriptor)
        }
    }

    nonisolated private static func isCurrentResultViewerTimingMetadata(
        _ metadata: ProjectMetadata,
        projectID: UUID
    ) -> Bool {
        metadata.id == projectID
            && metadata.state.stage == .done
            && metadata.state.lastError == nil
            && metadata.checkpoint == nil
            && metadata.lastRunStartedAt == nil
            && metadata.pendingPublicationID == nil
    }

    private func finishResultViewerTimingCommit(
        _ result: ResultViewerTimingWorkerResult,
        generationID: UUID
    ) {
        guard pendingResultViewerTiming?.generationID == generationID else {
            return
        }
        resultViewerTimingTask = nil
        pendingResultViewerTiming = nil
        if case .recorded(let metadata) = result {
            currentCreateToViewerReadySeconds =
                metadata.createToViewerReadySeconds
            refreshProjectSummaries()
        }
    }

    @discardableResult
    func cancelResultViewerTiming() -> Task<Void, Never>? {
        let task = resultViewerTimingTask
        task?.cancel()
        resultViewerTimingTask = nil
        pendingResultViewerTiming = nil
        return task
    }

    /// Returns to a clean new-splat workspace. Backs the File > New Splat
    /// menu command and the sidebar toolbar button.
    @discardableResult
    func beginNewSplat() -> Bool {
        guard !hasActiveWork else { return false }
        guard flushPendingNotesSave() else { return false }
        reset()
        clearPendingInputs()
        viewState = .home
        return true
    }

    /// Asks the result workspace to run its export flow. Only meaningful with
    /// a finished splat on screen.
    func requestExportFromMenu() {
        guard viewState == .viewer, outputPlyURL != nil else { return }
        exportMenuRequestCount += 1
    }

    func startFromPendingSelection(timingBoundary: RunTimingBoundary? = nil) {
        let timingBoundary = timingBoundary ?? .capture()
        guard !hasActiveWork else { return }
        guard let inputSpec = buildInputSpec() else { return }
        let photoURLs = pendingPhotoURLs
        let datasetInputSource = pendingDataset?.inputSource
        let title = projectTitle(for: inputSpec)
        let token = UUID()
        currentTaskToken = token
        currentRunOrigin = .fresh
        isRunActive = true
        currentTask = Task {
            await startProject(
                input: inputSpec,
                photoURLs: photoURLs,
                datasetInputSource: datasetInputSource,
                title: title,
                taskToken: token,
                timingBoundary: timingBoundary
            )
        }
    }

    @discardableResult
    func resumeProject(at url: URL) -> Bool {
        guard !hasActiveWork else { return false }
        let timingTask = cancelResultViewerTiming()
        let timingBoundary = RunTimingBoundary.capture()
        if let timingTask {
            let token = UUID()
            currentTaskToken = token
            currentRunOrigin = .resume
            isRunActive = true
            currentTask = Task { [self, timingTask] in
                await timingTask.value
                if Task.isCancelled {
                    if isCurrentTaskToken(token) {
                        finishRun(
                            taskToken: token,
                            projectRunLeaseOwner: nil
                        )
                    }
                    return
                }
                guard isCurrentTaskToken(token) else { return }
                guard flushPendingNotesSave() else {
                    finishRun(taskToken: token, projectRunLeaseOwner: nil)
                    return
                }
                // Do not advertise the next project until the old timing
                // transaction has released its short lease and the current
                // project's pending notes are durable.
                currentProjectURL = url
                await resumeProjectTask(
                    at: url,
                    taskToken: token,
                    timingBoundary: timingBoundary
                )
            }
            return true
        }
        guard flushPendingNotesSave() else { return false }
        let token = UUID()
        currentTaskToken = token
        currentRunOrigin = .resume
        isRunActive = true
        // Record the target before the task's first suspension so the project
        // is locked (rename/trash) for the entire open, not just after its
        // metadata loads.
        currentProjectURL = url
        currentTask = Task {
            await resumeProjectTask(
                at: url,
                taskToken: token,
                timingBoundary: timingBoundary
            )
        }
        return true
    }

    /// Re-runs a finished project at the requested detail profile. The pipeline
    /// re-resolves the plan and rolls back only the stages the plan diff
    /// invalidates; the published output is replaced when the new export lands.
    @discardableResult
    func retrainProject(at url: URL, profile: DetailProfile) -> Bool {
        guard !hasActiveWork else { return false }
        let timingTask = cancelResultViewerTiming()
        let timingBoundary = RunTimingBoundary.capture()
        if let timingTask {
            let token = UUID()
            currentTaskToken = token
            currentRunOrigin = .retrain
            isRunActive = true
            currentTask = Task { [self, timingTask] in
                await timingTask.value
                if Task.isCancelled {
                    if isCurrentTaskToken(token) {
                        finishRun(
                            taskToken: token,
                            projectRunLeaseOwner: nil
                        )
                    }
                    return
                }
                guard isCurrentTaskToken(token) else { return }
                guard flushPendingNotesSave() else {
                    finishRun(taskToken: token, projectRunLeaseOwner: nil)
                    return
                }
                await beginDeferredRetrain(
                    at: url,
                    profile: profile,
                    taskToken: token,
                    timingBoundary: timingBoundary
                )
            }
            return true
        }
        guard flushPendingNotesSave() else { return false }
        var leaseOwner: AppProjectRunLeaseOwner?
        var leaseOwnershipTransferred = false
        defer {
            if !leaseOwnershipTransferred {
                leaseOwner?.release()
            }
        }
        do {
            let acquired = try acquireAppProjectRunLeaseOwner(at: url)
            leaseOwner = acquired
            _ = try updateProjectMetadata(
                at: url,
                leaseOwner: acquired
            ) { metadata in
                metadata.requestedRunOptions.detailProfile = profile
            }
        } catch {
            presentProjectMutationFailure(
                error,
                fallbackTitle: "Couldn’t update project options"
            )
            return false
        }
        guard let leaseOwner else { return false }
        clearSubjectIsolationSession()
        let token = UUID()
        currentTaskToken = token
        currentRunOrigin = .retrain
        isRunActive = true
        currentProjectURL = url
        currentTask = Task { [self, leaseOwner] in
            await resumeProjectTask(
                at: url,
                taskToken: token,
                bypassFinishedOutput: true,
                projectRunLeaseOwner: leaseOwner,
                timingBoundary: timingBoundary
            )
        }
        leaseOwnershipTransferred = true
        return true
    }

    private func beginDeferredRetrain(
        at url: URL,
        profile: DetailProfile,
        taskToken: UUID,
        timingBoundary: RunTimingBoundary
    ) async {
        var leaseOwner: AppProjectRunLeaseOwner?
        var leaseOwnershipTransferred = false
        defer {
            if !leaseOwnershipTransferred {
                leaseOwner?.release()
            }
        }
        do {
            let acquired = try acquireAppProjectRunLeaseOwner(at: url)
            leaseOwner = acquired
            _ = try updateProjectMetadata(
                at: url,
                leaseOwner: acquired
            ) { metadata in
                metadata.requestedRunOptions.detailProfile = profile
            }
        } catch {
            presentProjectMutationFailure(
                error,
                fallbackTitle: "Couldn’t update project options"
            )
            finishRun(taskToken: taskToken, projectRunLeaseOwner: nil)
            return
        }
        guard let leaseOwner, isCurrentTaskToken(taskToken) else { return }
        clearSubjectIsolationSession()
        currentProjectURL = url
        leaseOwnershipTransferred = true
        await resumeProjectTask(
            at: url,
            taskToken: taskToken,
            bypassFinishedOutput: true,
            projectRunLeaseOwner: leaseOwner,
            timingBoundary: timingBoundary
        )
    }

    static func validationRecovery(for error: RunPlanResolver.ValidationError) -> RunValidationRecovery? {
        switch error {
        case .continuousMixedInputUnsupported:
            return .useUnordered
        case .fastDetailRequired:
            return .useFast
        case .highDetailRequiresMoreMemory:
            return .useBalanced
        case .noValidPhotos, .insufficientValidPhotos:
            return nil
        case .photoSelectionExceedsSafeLimit:
            return .useAutomaticPhotoSelection
        }
    }

    static func rasterMemoryRecovery(
        requestedOptions: RequestedRunOptions,
        currentBudgetBytes: Int64,
        hardware: HardwareProfile
    ) -> RunValidationRecovery? {
        let largerBudgets = [
            TrainingMemoryBudget.resolve(hardware: hardware, resourcePolicy: .automatic),
            TrainingMemoryBudget.resolve(hardware: hardware, resourcePolicy: .maximumPerformance),
        ]
            .filter { $0 > currentBudgetBytes }
            .sorted()
        if let nextBudget = largerBudgets.first {
            return .useMoreTrainingMemory(nextBudget)
        }
        if requestedOptions.detailProfile == .highDetail {
            return .useBalanced
        }
        if requestedOptions.detailProfile != .fast {
            return .useFastForMemory
        }
        return nil
    }

    static func rasterResourceRecovery(
        requestedOptions: RequestedRunOptions
    ) -> RunValidationRecovery? {
        switch requestedOptions.detailProfile {
        case .highDetail:
            return .useBalanced
        case .balanced:
            return .useFastForMemory
        case .fast:
            return nil
        }
    }

    func configureRuntimeRecovery(for error: Error) {
        let options = currentRunOptions ?? requestedRunOptions
        if let admissionError = error as? TrainingResourceAdmissionError {
            let message: String = switch admissionError {
            case .invalidObservation:
                "Current memory availability could not be verified. Try again."
            case .staleObservation:
                "Memory availability changed before training could start. Try again."
            case .insufficientAvailableMemory:
                "Training needs more free unified memory. Close other demanding apps, then try again."
            }
            validationRecovery = nil
            failureRetryAllowed = true
            lastError = message
            statusTitle = message
            statusDetail = nil
            return
        }
        if error is MsplatMetalAllocationUnavailable {
            let message = "Training could not reserve unified memory. Close other demanding apps, then try again."
            validationRecovery = nil
            failureRetryAllowed = true
            lastError = message
            statusTitle = message
            statusDetail = nil
            return
        }
        if error is MsplatRasterResourceLimitExceeded {
            let recovery = Self.rasterResourceRecovery(requestedOptions: options)
            validationRecovery = recovery
            failureRetryAllowed = recovery != nil
            let message: String = switch recovery {
            case .useBalanced:
                "This scene exceeded Metal's buffer limit. Use Balanced detail."
            case .useFastForMemory:
                "This scene exceeded Metal's buffer limit. Use Fast detail."
            case nil:
                "This scene exceeded Metal's buffer limit even at Fast detail."
            case .useMoreTrainingMemory, .useUnordered, .useFast, .useAutomaticPhotoSelection:
                preconditionFailure("Unexpected recovery for a raster resource limit")
            }
            lastError = message
            statusTitle = message
            statusDetail = nil
            return
        }
        guard error is MsplatRasterMemoryBudgetExceeded else { return }
        let currentBudget = currentProjectURL
            .flatMap { try? ProjectMetadataStore.load(from: ProjectPaths(root: $0).metadataURL) }
            .flatMap(\.resolvedRunPlan)
            .map(\.trainerMemoryBudgetBytes)
            ?? TrainingMemoryBudget.resolve(
                hardware: hardwareProfile,
                resourcePolicy: options.resourcePolicy
            )
        let recovery = Self.rasterMemoryRecovery(
            requestedOptions: options,
            currentBudgetBytes: currentBudget,
            hardware: hardwareProfile
        )
        validationRecovery = recovery
        failureRetryAllowed = recovery != nil
        let message: String = switch recovery {
        case .useMoreTrainingMemory:
            "Training needs more memory than this run allows. Use more unified memory."
        case .useFastForMemory:
            "Training needs more memory than this run allows. Use Fast detail."
        case nil:
            "Training needs more memory than this Mac can safely use for this scene."
        case .useBalanced:
            "Training needs more memory than this run allows. Use Balanced detail."
        case .useUnordered, .useFast, .useAutomaticPhotoSelection:
            preconditionFailure("Unexpected recovery for a raster memory failure")
        }
        lastError = message
        statusTitle = message
        statusDetail = nil
    }

    @discardableResult
    func applyValidationRecovery(
        _ recovery: RunValidationRecovery,
        projectURL: URL?
    ) -> Bool {
        if case .useMoreTrainingMemory(let budgetBytes) = recovery {
            guard let projectURL, budgetBytes > 0 else {
                presentProjectMutationFailure(
                    nil,
                    fallbackTitle: "Couldn’t update the training plan"
                )
                return false
            }
            do {
                _ = try updateProjectMetadata(at: projectURL) { metadata in
                    metadata.trainingMemoryRetryBudgetBytes = budgetBytes
                }
            } catch {
                presentProjectMutationFailure(
                    error,
                    fallbackTitle: "Couldn’t update the training plan"
                )
                return false
            }
            return true
        }
        if let projectURL {
            do {
                _ = try updateProjectMetadata(at: projectURL) { [hardwareProfile] metadata in
                    var options = metadata.requestedRunOptions
                    recovery.apply(to: &options)
                    if !RunPlanResolver.supports(
                        resourcePolicy: options.resourcePolicy,
                        memoryGB: hardwareProfile.memoryGB
                    ) {
                        options.resourcePolicy = .automatic
                    }
                    metadata.requestedRunOptions = options
                }
            } catch {
                presentProjectMutationFailure(
                    error,
                    fallbackTitle: "Couldn’t update project options"
                )
                return false
            }
            return true
        }

        recovery.apply(to: &requestedRunOptions)
        if !RunPlanResolver.supports(
            resourcePolicy: requestedRunOptions.resourcePolicy,
            memoryGB: hardwareProfile.memoryGB
        ) {
            requestedRunOptions.resourcePolicy = .automatic
        }
        return true
    }

    func retryAfterFailure() {
        guard failureRetryAllowed else { return }
        let projectURL = currentProjectURL
        if let projectURL {
            if let recovery = validationRecovery {
                guard retryProject(
                    at: projectURL,
                    applying: recovery
                ) else { return }
                validationRecovery = nil
            } else {
                resumeProject(at: projectURL)
            }
        } else {
            if let recovery = validationRecovery {
                guard applyValidationRecovery(recovery, projectURL: nil) else { return }
                validationRecovery = nil
            }
            startFromPendingSelection()
        }
    }

    private func retryProject(
        at projectURL: URL,
        applying recovery: RunValidationRecovery
    ) -> Bool {
        guard !hasActiveWork else { return false }
        let timingTask = cancelResultViewerTiming()
        let timingBoundary = RunTimingBoundary.capture()
        if let timingTask {
            let token = UUID()
            currentTaskToken = token
            currentRunOrigin = .resume
            isRunActive = true
            currentTask = Task { [self, timingTask] in
                await timingTask.value
                if Task.isCancelled {
                    if isCurrentTaskToken(token) {
                        finishRun(
                            taskToken: token,
                            projectRunLeaseOwner: nil
                        )
                    }
                    return
                }
                guard isCurrentTaskToken(token) else { return }
                guard flushPendingNotesSave() else {
                    finishRun(taskToken: token, projectRunLeaseOwner: nil)
                    return
                }
                await beginDeferredRetry(
                    at: projectURL,
                    applying: recovery,
                    taskToken: token,
                    timingBoundary: timingBoundary
                )
            }
            return true
        }
        guard flushPendingNotesSave() else { return false }
        var leaseOwner: AppProjectRunLeaseOwner?
        var leaseOwnershipTransferred = false
        defer {
            if !leaseOwnershipTransferred {
                leaseOwner?.release()
            }
        }
        do {
            let acquired = try acquireAppProjectRunLeaseOwner(at: projectURL)
            leaseOwner = acquired
            _ = try updateProjectMetadata(
                at: projectURL,
                leaseOwner: acquired
            ) { [hardwareProfile] metadata in
                if case .useMoreTrainingMemory(let budgetBytes) = recovery {
                    guard budgetBytes > 0 else { return }
                    metadata.trainingMemoryRetryBudgetBytes = budgetBytes
                    return
                }
                var options = metadata.requestedRunOptions
                recovery.apply(to: &options)
                if !RunPlanResolver.supports(
                    resourcePolicy: options.resourcePolicy,
                    memoryGB: hardwareProfile.memoryGB
                ) {
                    options.resourcePolicy = .automatic
                }
                metadata.requestedRunOptions = options
            }
        } catch {
            presentProjectMutationFailure(
                error,
                fallbackTitle: "Couldn’t update project options"
            )
            return false
        }
        guard let leaseOwner else { return false }

        let token = UUID()
        currentTaskToken = token
        currentRunOrigin = .resume
        isRunActive = true
        currentProjectURL = projectURL
        currentTask = Task { [self, leaseOwner] in
            await resumeProjectTask(
                at: projectURL,
                taskToken: token,
                projectRunLeaseOwner: leaseOwner,
                timingBoundary: timingBoundary
            )
        }
        leaseOwnershipTransferred = true
        return true
    }

    private func beginDeferredRetry(
        at projectURL: URL,
        applying recovery: RunValidationRecovery,
        taskToken: UUID,
        timingBoundary: RunTimingBoundary
    ) async {
        var leaseOwner: AppProjectRunLeaseOwner?
        var leaseOwnershipTransferred = false
        defer {
            if !leaseOwnershipTransferred {
                leaseOwner?.release()
            }
        }
        do {
            let acquired = try acquireAppProjectRunLeaseOwner(at: projectURL)
            leaseOwner = acquired
            _ = try updateProjectMetadata(
                at: projectURL,
                leaseOwner: acquired
            ) { [hardwareProfile] metadata in
                if case .useMoreTrainingMemory(let budgetBytes) = recovery {
                    guard budgetBytes > 0 else { return }
                    metadata.trainingMemoryRetryBudgetBytes = budgetBytes
                    return
                }
                var options = metadata.requestedRunOptions
                recovery.apply(to: &options)
                if !RunPlanResolver.supports(
                    resourcePolicy: options.resourcePolicy,
                    memoryGB: hardwareProfile.memoryGB
                ) {
                    options.resourcePolicy = .automatic
                }
                metadata.requestedRunOptions = options
            }
        } catch {
            presentProjectMutationFailure(
                error,
                fallbackTitle: "Couldn’t update project options"
            )
            finishRun(taskToken: taskToken, projectRunLeaseOwner: nil)
            return
        }
        guard let leaseOwner, isCurrentTaskToken(taskToken) else { return }
        currentProjectURL = projectURL
        leaseOwnershipTransferred = true
        await resumeProjectTask(
            at: projectURL,
            taskToken: taskToken,
            projectRunLeaseOwner: leaseOwner,
            timingBoundary: timingBoundary
        )
    }

    func refreshProjectSummaries() {
        projectSummaryRefreshTask?.cancel()
        projectSummaryRefreshTask = nil
        projectSummaries = Self.loadProjectSummaries(
            from: projectBaseDirectory(),
            currentProjectURL: currentProjectURL,
            isRunActive: isRunActive
        )
    }

    func refreshProjectSummariesInBackground() {
        projectSummaryRefreshTask?.cancel()
        let base = projectBaseDirectory()
        let activeProjectURL = currentProjectURL
        let runIsActive = isRunActive
        projectSummaryRefreshTask = Task { [weak self] in
            let summaries = await Task.detached(priority: .utility) {
                Self.loadProjectSummaries(
                    from: base,
                    currentProjectURL: activeProjectURL,
                    isRunActive: runIsActive
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.projectSummaries = summaries
            self?.projectSummaryRefreshTask = nil
        }
    }

    nonisolated private static func loadProjectSummaries(
        from base: URL,
        currentProjectURL: URL?,
        isRunActive: Bool
    ) -> [ProjectSummary] {
        _ = ProjectPublicationTransaction.reconcile(in: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var summaries: [ProjectSummary] = []
        for url in contents where url.pathExtension == "easysplatproj" {
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            let snapshot: ProjectArtifactSnapshot?
            let metadata: ProjectMetadata
            do {
                let loaded = try ProjectArtifactSnapshotStore.load(
                    projectURL: url,
                    validationDepth: .quick
                )
                snapshot = loaded
                metadata = loaded.metadata
            } catch {
                guard let currentMetadata = try? ProjectMetadataStore.load(
                    from: ProjectPaths(root: url).metadataURL
                ) else {
                    projectLibraryLogger.notice(
                        "Skipping unreadable project at \(url.path, privacy: .private): \(String(describing: error), privacy: .public)"
                    )
                    continue
                }
                snapshot = nil
                metadata = currentMetadata
                projectLibraryLogger.notice(
                    "Project artifacts are unavailable at \(url.path, privacy: .private): \(String(describing: error), privacy: .public)"
                )
            }
            let outputURL = snapshot.flatMap {
                readyOutputURLOnDisk(
                    projectURL: url,
                    snapshot: $0,
                    validationDepth: .quick
                )
            }
            let outputExists = outputURL != nil
            let isActive = ProjectSummary.hasSameLocation(currentProjectURL, url)
                && isRunActive
            let hasInterruptionEvidence = metadata.checkpoint != nil || metadata.lastRunStartedAt != nil
            let isInterrupted = !isActive
                && !outputExists
                && metadata.state.lastError == nil
                && metadata.state.stage != .done
                && hasInterruptionEvidence
            let status: ProjectStatus
            if isActive {
                status = .inProgress
            } else if outputExists {
                status = .ready
            } else if metadata.state.lastError != nil {
                status = .failed
            } else if metadata.state.stage == .done {
                status = .failed
            } else {
                status = .inProgress
            }
            let sidecarOpened = LastOpenedSidecar.load(from: ProjectPaths(root: url).lastOpenedSidecarURL)
            summaries.append(ProjectSummary(
                id: metadata.id,
                title: metadata.title,
                url: url,
                createdAt: metadata.createdAt,
                status: status,
                isActive: isActive,
                isInterrupted: isInterrupted,
                checkpointUpdatedAt: metadata.checkpoint?.updatedAt,
                stageTimings: metadata.stageTimings ?? [],
                createToViewerReadySeconds: metadata.createToViewerReadySeconds,
                input: metadata.input,
                requestedRunOptions: metadata.requestedRunOptions,
                lastOpenedAt: sidecarOpened,
                lastRunStartedAt: metadata.lastRunStartedAt,
                lastFailureAt: metadata.lastFailureAt
            ))
        }

        return summaries.sorted { $0.createdAt > $1.createdAt }
    }

    func projectBaseDirectory() -> URL {
        let fm = FileManager.default
        if let projectBaseURL {
            return projectBaseURL
        }
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return fm.temporaryDirectory.appendingPathComponent("EasySplat Projects", isDirectory: true)
        }
        return docs.appendingPathComponent("EasySplat Projects", isDirectory: true)
    }

    func resumeStage(from metadata: ProjectMetadata) -> PipelineStage? {
        guard metadata.state.lastError == nil else {
            let stages = PipelineStage.allCases
            guard let index = stages.firstIndex(of: metadata.state.stage), index > 0 else {
                return nil
            }
            return stages[index - 1]
        }
        return metadata.state.stage
    }

    func outputFileState(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    func canonicalOutputURL(projectURL: URL, metadata: ProjectMetadata? = nil) -> URL? {
        guard let snapshot = try? ProjectArtifactSnapshotStore.load(projectURL: projectURL) else {
            return nil
        }
        let paths = ProjectPaths(root: projectURL)
        guard snapshot.trainingArtifact?.completionStatus == .completed,
              snapshot.trainingArtifact?.outputPath == "Output/splat.ply" else {
            return nil
        }
        return paths.outputSplatURL
    }

    func readyOutputURL(
        projectURL: URL,
        metadata: ProjectMetadata? = nil,
        validationDepth: ProjectArtifactValidationDepth
    ) -> URL? {
        Self.readyOutputURLOnDisk(
            projectURL: projectURL,
            metadata: metadata,
            validationDepth: validationDepth
        )
    }

    nonisolated static func readyOutputURLOnDisk(
        projectURL: URL,
        metadata: ProjectMetadata? = nil,
        validationDepth: ProjectArtifactValidationDepth
    ) -> URL? {
        let snapshotDepth: ProjectArtifactSnapshotStore.ValidationDepth = switch validationDepth {
        case .quick: .quick
        case .full: .full
        }
        guard let snapshot = try? ProjectArtifactSnapshotStore.load(
            projectURL: projectURL,
            validationDepth: snapshotDepth
        ) else {
            return nil
        }
        return readyOutputURLOnDisk(
            projectURL: projectURL,
            snapshot: snapshot,
            validationDepth: validationDepth
        )
    }

    nonisolated private static func readyOutputURLOnDisk(
        projectURL: URL,
        snapshot: ProjectArtifactSnapshot,
        validationDepth: ProjectArtifactValidationDepth
    ) -> URL? {
        guard snapshot.metadata.state.stage == .done,
              snapshot.metadata.state.lastError == nil,
              let trainingArtifact = snapshot.trainingArtifact,
              trainingArtifact.completionStatus == .completed,
              trainingArtifact.outputPath == "Output/splat.ply" else {
            return nil
        }
        let outputURL = ProjectPaths(root: projectURL).outputSplatURL
        switch validationDepth {
        case .quick:
            guard ProjectArtifactValidator.validatePlyFile(at: outputURL, depth: .quick) == .valid else {
                return nil
            }
        case .full:
            do {
                try TrainingArtifactStore.validateCompletedOutput(
                    trainingArtifact,
                    at: outputURL
                )
            } catch {
                return nil
            }
        }
        return outputURL
    }

    func validatedFinishedOutputURL(projectURL: URL) async throws -> URL? {
        let validator = finishedOutputValidator
        let validationTask = Task.detached(priority: .userInitiated) {
            validator(projectURL)
        }
        return try await withTaskCancellationHandler {
            let outputURL = await validationTask.value
            try Task.checkCancellation()
            return outputURL
        } onCancel: {
            validationTask.cancel()
        }
    }

    /// Reload the persisted per-stage timings. Returns an empty array when no timings
    /// have been recorded yet so callers can drive UI state with a single property.
    func loadStageTimings(projectURL: URL) -> [StageTimingRecord] {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?.stageTimings ?? []
    }

    func loadCreateToViewerReadySeconds(projectURL: URL) -> TimeInterval? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?
            .createToViewerReadySeconds
    }

    func loadProjectConfig(projectURL: URL) -> (options: RequestedRunOptions, input: InputSpec)? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        guard let metadata = try? ProjectMetadataStore.load(from: metadataURL) else { return nil }
        return (metadata.requestedRunOptions, metadata.input)
    }

    /// Free disk space on the volume that hosts the project base directory.
    /// Returns nil when the system cannot report capacity (e.g., a read-only
    /// mount or a permission error). Callers should treat nil as "don't warn".
    /// This is a fresh stat call; the cheap path for SwiftUI consumers is
    /// `cachedFreeDiskBytes` which is refreshed by `refreshFreeDiskSpace`.
    func freeDiskSpaceBytes() -> Int64? {
        let baseURL = projectBaseDirectory()
        let fm = FileManager.default
        try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        do {
            let attrs = try fm.attributesOfFileSystem(forPath: baseURL.path)
            return (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        } catch {
            return nil
        }
    }

    /// Probe the project volume on a background task and update the cached
    /// value so SwiftUI render bodies never call into `attributesOfFileSystem`
    /// directly. Safe to call from the main actor.
    func refreshFreeDiskSpace() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let base = await self.projectBaseDirectory()
            let fm = FileManager.default
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let bytes: Int64? = {
                guard let attrs = try? fm.attributesOfFileSystem(forPath: base.path) else { return nil }
                return (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            }()
            await MainActor.run {
                self.cachedFreeDiskBytes = bytes
            }
        }
    }

    /// Leaves room for selected frames, accepted geometry, checkpoints, and output.
    static let recommendedFreeSpaceBytes: Int64 = 8 * 1024 * 1024 * 1024

    static let notesAutoSaveDelay: TimeInterval = 0.5

    /// Schedule a debounced save of the project's notes. Cancels any prior
    /// pending save so only the final value in the typing burst lands.
    /// Also remembers the pending (url, text) so a teardown path can flush
    /// the last edit synchronously instead of dropping it.
    func scheduleNotesSave(at url: URL, to text: String) {
        notesSaveTask?.cancel()
        pendingNotesSave = (url: url, text: text)
        notesSaveState = .saving
        let token = url
        let value = text
        notesSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(AppModel.notesAutoSaveDelay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard ProjectSummary.hasSameLocation(self.currentProjectURL, token) else { return }
                guard let pending = self.pendingNotesSave,
                      ProjectSummary.hasSameLocation(pending.url, token),
                      pending.text == value else {
                    return
                }
                self.notesSaveTask = nil
                do {
                    _ = try self.persistProjectNotes(at: token, text: value)
                    self.pendingNotesSave = nil
                    self.notesSaveState = .saved
                } catch {
                    self.presentNotesSaveFailure(projectURL: token)
                }
            }
        }
    }

    /// Synchronously write the last pending notes value, cancelling the
    /// debounce timer. Safe to call when no save is pending. Use before
    /// reset(), project switch, or app termination so a half-typed note
    /// doesn't silently disappear.
    @discardableResult
    func flushPendingNotesSave(
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) -> Bool {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard let pending = pendingNotesSave else { return true }
        do {
            _ = try persistProjectNotes(
                at: pending.url,
                text: pending.text,
                projectRunLeaseOwner: projectRunLeaseOwner
            )
            pendingNotesSave = nil
            notesSaveState = .saved
            return true
        } catch {
            presentNotesSaveFailure(projectURL: pending.url)
            return false
        }
    }

    /// Stamp the project as opened-by-the-user at this moment. Kept as
    /// diagnostic metadata only; it deliberately does not feed the Recent
    /// sort, so opening a project never reorders the sidebar.
    /// Writes to a sidecar file so it cannot clobber concurrent pipeline
    /// writes to project.json. Silent no-op on file errors.
    func markProjectOpened(at url: URL, at moment: Date = Date()) {
        let sidecar = ProjectPaths(root: url).lastOpenedSidecarURL
        try? LastOpenedSidecar.save(moment, to: sidecar)
    }

    /// Persist a free-text note on the named project. Trims whitespace and
    /// treats empty input as "clear the note" (writes nil) so the UI does
    /// not have to special-case it. Returns false when the project metadata
    /// can't be loaded or when the new note matches the existing one.
    @discardableResult
    func updateProjectNotes(at url: URL, to text: String) -> Bool {
        do {
            let didChange = try persistProjectNotes(at: url, text: text)
            if ProjectSummary.hasSameLocation(currentProjectURL, url) {
                notesSaveState = .saved
            }
            return didChange
        } catch {
            presentNotesSaveFailure(projectURL: url)
            return false
        }
    }

    private func persistProjectNotes(
        at url: URL,
        text: String,
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes: String? = trimmed.isEmpty ? nil : trimmed
        // Deliberately do not assign `currentProjectNotes` here. The binding
        // owner (notes editor) drives that property; reassigning the trimmed
        // value back into the binding mid-typing would yank cursor position
        // and drop in-progress whitespace from the user.
        let didChange = SynchronizedAppValue(false)
        _ = try updateProjectMetadata(
            at: url,
            leaseOwner: projectRunLeaseOwner
        ) { metadata in
            guard metadata.notes != newNotes else { return }
            metadata.notes = newNotes
            didChange.set(true)
        }
        return didChange.value
    }

    private func presentNotesSaveFailure(projectURL: URL) {
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL)
                || pendingNotesSave.map({ ProjectSummary.hasSameLocation($0.url, projectURL) }) == true else {
            return
        }
        let message = "The last edit is still waiting to be saved. Check free space and folder permissions, then try again."
        notesSaveState = .failed(message)
        actionFailure = ActionFailurePresentation(
            title: "Couldn’t save notes",
            message: message
        )
    }

    func presentPendingNotesSaveFailureIfNeeded(at projectURL: URL) {
        guard let pendingNotesSave,
              ProjectSummary.hasSameLocation(
                  pendingNotesSave.url,
                  projectURL
              ) else {
            return
        }
        presentNotesSaveFailure(projectURL: projectURL)
    }

    func loadProjectNotes(projectURL: URL) -> String {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?.notes ?? ""
    }

    /// Rename a project in place. Updates the persisted `title` field in
    /// project.json but does NOT rename the on-disk bundle directory so
    /// project URLs stay stable for live runs and other tooling. Returns
    /// false if the rename was a no-op (empty new title, identical title,
    /// or metadata unreadable).
    @discardableResult
    func renameProject(at url: URL, to newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        actionFailure = nil
        do {
            let didChange = SynchronizedAppValue(false)
            _ = try updateProjectMetadata(at: url) { metadata in
                guard metadata.title != trimmed else { return }
                metadata.title = trimmed
                didChange.set(true)
            }
            guard didChange.value else { return false }
            refreshProjectSummaries()
            return true
        } catch {
            actionFailure = ActionFailurePresentation(
                title: "Couldn’t rename project",
                message: "The project name wasn’t changed. Check folder permissions and try again."
            )
            return false
        }
    }

    @discardableResult
    func updateViewerUprightFlip(
        at projectURL: URL,
        isActive: Bool
    ) throws -> ProjectMetadata {
        try updateProjectMetadata(at: projectURL) { metadata in
            metadata.viewerPreferences.isUprightFlipActive = isActive
        }
    }

}
