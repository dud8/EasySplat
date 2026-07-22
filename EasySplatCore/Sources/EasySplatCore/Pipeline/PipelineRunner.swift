import Foundation
import Dispatch
public final class PipelineRunner: @unchecked Sendable {

    private struct DevelopmentStop: Error {}

    public struct Tooling {
        public var colmap: ColmapRunner
        public var msplat: MsplatRunner
        public var da3Sfm: Da3SfmRunning
        public var trainingResourceObserver: any TrainingResourceObserving
        let checkCancellation: @Sendable () throws -> Void
        let colmapGPUSupport: (@Sendable (URL) -> Bool)?
        let validateVideoInputs: @Sendable (ProjectMetadata, ProjectPaths) throws -> Void
        let prepareRuntimeInputLease: @Sendable (
            ProjectMetadata,
            ProjectPaths,
            ResolvedPairingPolicy?
        ) throws -> RuntimeInputSnapshotLease

        public init(colmap: ColmapRunner = ColmapRunner(),
                    msplat: MsplatRunner = MsplatRunner(),
                    da3Sfm: Da3SfmRunning = Da3SfmRunner(),
                    trainingResourceObserver: any TrainingResourceObserving = LiveTrainingResourceObserver()) {
            self.colmap = colmap
            self.msplat = msplat
            self.da3Sfm = da3Sfm
            self.trainingResourceObserver = trainingResourceObserver
            self.checkCancellation = { try Task.checkCancellation() }
            self.colmapGPUSupport = nil
            self.validateVideoInputs = { try VideoInputReceiptValidator.validateFiles(metadata: $0, paths: $1) }
            self.prepareRuntimeInputLease = {
                try RuntimeInputSnapshotLease.prepare(metadata: $0, paths: $1, pairingPolicy: $2)
            }
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.msplat = MsplatRunner(runner: runner)
            self.da3Sfm = Da3SfmRunner(runner: runner)
            self.trainingResourceObserver = LiveTrainingResourceObserver()
            self.checkCancellation = { try Task.checkCancellation() }
            self.colmapGPUSupport = nil
            self.validateVideoInputs = { try VideoInputReceiptValidator.validateFiles(metadata: $0, paths: $1) }
            self.prepareRuntimeInputLease = {
                try RuntimeInputSnapshotLease.prepare(metadata: $0, paths: $1, pairingPolicy: $2)
            }
        }

        init(
            runner: SubprocessRunning,
            checkCancellation: @escaping @Sendable () throws -> Void = {
                try Task.checkCancellation()
            },
            colmapGPUSupport: (@Sendable (URL) -> Bool)? = nil,
            trainingResourceObserver: any TrainingResourceObserving = LiveTrainingResourceObserver(),
            validateVideoInputs: @escaping @Sendable (ProjectMetadata, ProjectPaths) throws -> Void = {
                try VideoInputReceiptValidator.validateFiles(metadata: $0, paths: $1)
            },
            prepareRuntimeInputLease: @escaping @Sendable (
                ProjectMetadata,
                ProjectPaths,
                ResolvedPairingPolicy?
            ) throws -> RuntimeInputSnapshotLease = {
                try RuntimeInputSnapshotLease.prepare(metadata: $0, paths: $1, pairingPolicy: $2)
            }
        ) {
            self.colmap = ColmapRunner(runner: runner)
            self.msplat = MsplatRunner(runner: runner)
            self.da3Sfm = Da3SfmRunner(runner: runner)
            self.trainingResourceObserver = trainingResourceObserver
            self.checkCancellation = checkCancellation
            self.colmapGPUSupport = colmapGPUSupport
            self.validateVideoInputs = validateVideoInputs
            self.prepareRuntimeInputLease = prepareRuntimeInputLease
        }
    }

    public struct PipelineConfig: Sendable {
        public var toolchain: ToolchainPaths
        public var developmentOverrides: DevelopmentOverrides
        public var hardwareProfile: HardwareProfile?
        public var resolvedRunPlan: ResolvedRunPlan?
        public var prePipelineDurationSeconds: TimeInterval
        public var prePipelineStartedAt: Date?

        public init(
            toolchain: ToolchainPaths,
            developmentOverrides: DevelopmentOverrides = .none,
            hardwareProfile: HardwareProfile? = nil,
            resolvedRunPlan: ResolvedRunPlan? = nil,
            prePipelineDurationSeconds: TimeInterval = 0,
            prePipelineStartedAt: Date? = nil
        ) {
            self.toolchain = toolchain
            self.developmentOverrides = developmentOverrides
            self.hardwareProfile = hardwareProfile
            self.resolvedRunPlan = resolvedRunPlan
            self.prePipelineDurationSeconds = prePipelineDurationSeconds
            self.prePipelineStartedAt = prePipelineStartedAt
        }
    }

    let projectURL: URL
    let config: PipelineConfig
    let tooling: Tooling
    let powerAssertion: PowerAssertionManaging

    public init(
        projectURL: URL,
        config: PipelineConfig,
        tooling: Tooling = Tooling(),
        powerAssertion: PowerAssertionManaging = SystemPowerAssertion()
    ) {
        self.projectURL = projectURL
        self.config = config
        self.tooling = tooling
        self.powerAssertion = powerAssertion
    }

    public func run(resumeFrom lastCompletedStage: PipelineStage? = nil, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        try await runPipeline(
            resumeFrom: lastCompletedStage,
            freshPublicationAttestation: nil,
            events: events
        )
    }

    public func run(
        resumeFrom lastCompletedStage: PipelineStage? = nil,
        freshPublicationAttestation: FreshProjectPublicationAttestation,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        try await runPipeline(
            resumeFrom: lastCompletedStage,
            freshPublicationAttestation: freshPublicationAttestation,
            events: events
        )
    }

    private func runPipeline(
        resumeFrom lastCompletedStage: PipelineStage?,
        freshPublicationAttestation: FreshProjectPublicationAttestation?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        defer { freshPublicationAttestation?.discard() }
        // Keep the Mac awake while work is active. Display sleep remains available, and
        // the assertion is released on every exit — success, failure, stop, or cancellation.
        let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is processing a project")
        defer { idleSleepAssertion.release() }

        let paths = ProjectPaths(root: projectURL)
        let stageTiming = StageTimingTracker(
            initialImportDurationSeconds: config.prePipelineDurationSeconds,
            importStartedAt: config.prePipelineStartedAt
        )

        // Load metadata BEFORE clearing any logs. If project.json is malformed, unreadable,
        // or from a future build, we want the user to keep the previous run's diagnostic
        // tool logs for inspection — wiping them on a no-op startup
        // failure would destroy the only evidence of why the prior attempt died.
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        try authenticateStartupVideoInputs(
            metadata: metadata,
            paths: paths,
            freshPublicationAttestation: freshPublicationAttestation
        )
        try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
        // No project directory is created or repaired until the immutable video receipts
        // have been rebound to the exact controlled bytes they describe.
        try paths.ensureDirectories()
        let detectedHardwareProfile = config.hardwareProfile ?? .detect()
        let requestedOptions = metadata.requestedRunOptions
        try RunPlanResolver.validate(
            requestedOptions: requestedOptions,
            input: metadata.input,
            hardware: detectedHardwareProfile
        )
        let previousResolvedRunPlan = metadata.resolvedRunPlan
        let hardwareResolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: metadata.input,
            hardware: detectedHardwareProfile,
            developmentOverrides: config.developmentOverrides,
            trainingMemoryRetryBudgetBytes: metadata.trainingMemoryRetryBudgetBytes
        )
        let resolvedRunPlan: ResolvedRunPlan = {
            var plan = config.resolvedRunPlan ?? hardwareResolvedRunPlan
            if !metadata.input.hasVideos {
                plan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks =
                    hardwareResolvedRunPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks
            }
            return plan
        }()
        try resolvedRunPlan.validate()
        let planChangedForCurrentHardware = previousResolvedRunPlan != nil
            && previousResolvedRunPlan != resolvedRunPlan
        let videoAnalysisRequiresRefresh = try videoFrameAnalysisRequiresRefresh(
            metadata: metadata,
            currentPlan: resolvedRunPlan
        )
        if videoAnalysisRequiresRefresh {
            stageTiming.start(.importInput)
        }
        let inputLease = try prepareStartupRuntimeInputLease(
            metadata: metadata,
            paths: paths,
            pairingPolicy: resolvedRunPlan.pairingPolicy,
            freshPublicationAttestation: freshPublicationAttestation
        )
        defer { inputLease.discard() }
        let photoSelectionProjection = inputLease.photoSelectionProjection
        var effectiveLastCompletedStage = RunPlanResolver.safeResumeStage(
            lastCompletedStage,
            input: metadata.input,
            previousPlan: planChangedForCurrentHardware ? previousResolvedRunPlan : resolvedRunPlan,
            currentPlan: resolvedRunPlan
        )
        let invalidatedUnprovenBackendRecovery: Bool = {
            guard let recovery = metadata.geometryRecovery else { return false }
            return !recovery.isBound(to: resolvedRunPlan.geometryBackend)
        }()
        if invalidatedUnprovenBackendRecovery {
            let stages = PipelineStage.allCases
            let selectedIndex = stages.firstIndex(of: .selectFrames) ?? 0
            if let completed = effectiveLastCompletedStage,
               let completedIndex = stages.firstIndex(of: completed),
               completedIndex > selectedIndex {
                effectiveLastCompletedStage = .selectFrames
            }
        }
        if videoAnalysisRequiresRefresh {
            effectiveLastCompletedStage = .importInput
        }
        let refreshedVideoAnalysis = try await refreshVideoFrameAnalysisIfNeeded(
            metadata: metadata,
            currentPlan: resolvedRunPlan,
            inputLease: inputLease,
            paths: paths
        )
        var publishedRefreshedVideoAnalysis = false
        defer {
            if !publishedRefreshedVideoAnalysis {
                refreshedVideoAnalysis?.creationLedger.rollback()
            }
        }
        guard !videoAnalysisRequiresRefresh || refreshedVideoAnalysis != nil else {
            throw RuntimeInputSnapshotError.invalidMetadata
        }
        if let refreshedVideoAnalysis {
            metadata.videoInputReceipts = refreshedVideoAnalysis.receipts
            var candidateMetadata = metadata
            candidateMetadata.resolvedRunPlan = resolvedRunPlan
            try VideoInputReceiptValidator.validateFiles(
                metadata: candidateMetadata,
                paths: paths
            )
        }
        let initialColmapRuntimeClosure = try tooling.colmap.captureRuntimeClosure(
            colmapPath: config.toolchain.colmap
        )
        let workerExecutionRecorder = try GeometryWorkerExecutionRecorder(
            paths: paths,
            budget: resolvedRunPlan.geometryWorkerBudget,
            runtimeClosure: initialColmapRuntimeClosure,
            resumeAfter: effectiveLastCompletedStage,
            inputHasVideos: metadata.input.hasVideos,
            resetForPlanChange: planChangedForCurrentHardware
                || refreshedVideoAnalysis != nil
                || invalidatedUnprovenBackendRecovery
        )
        let recoveredWorkerExecution = workerExecutionRecorder.maximumSafeResumeBoundary != nil
        if let maximumSafeBoundary = workerExecutionRecorder.maximumSafeResumeBoundary,
           let completedStage = effectiveLastCompletedStage,
           let completedIndex = PipelineStage.allCases.firstIndex(of: completedStage),
           let safeIndex = PipelineStage.allCases.firstIndex(of: maximumSafeBoundary),
           completedIndex > safeIndex {
            effectiveLastCompletedStage = maximumSafeBoundary
        }
        let invalidatedMatchingForPlanChange = planChangedForCurrentHardware
            && effectiveLastCompletedStage == .sfmFeatures
        if planChangedForCurrentHardware
            || refreshedVideoAnalysis != nil
            || recoveredWorkerExecution
            || invalidatedUnprovenBackendRecovery {
            try persistResolvedPlanChange(
                resolvedRunPlan,
                completedBoundary: effectiveLastCompletedStage,
                metadata: &metadata,
                paths: paths
            )
        } else if metadata.resolvedRunPlan != resolvedRunPlan {
            metadata.resolvedRunPlan = resolvedRunPlan
            try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        }
        if let refreshedVideoAnalysis {
            refreshedVideoAnalysis.creationLedger.commit()
            publishedRefreshedVideoAnalysis = true
        }
        if let refreshedVideoAnalysis {
            let referenced = Set(refreshedVideoAnalysis.receipts.map(\.analysisArtifactPath))
            for removal in refreshedVideoAnalysis.supersededArtifactRemovals {
                guard let relativePath = try? paths.projectRelativePath(for: removal.url),
                      !referenced.contains(relativePath) else {
                    continue
                }
                _ = try? VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(removal)
            }
        }
        if refreshedVideoAnalysis != nil {
            _ = stageTiming.finish(.importInput)
            if let timing = stageTiming.consumeRecord(.importInput) {
                var timings = metadata.stageTimings ?? []
                timings.removeAll { $0.stage == .importInput }
                timings.append(StageTimingRecord(
                    stage: .importInput,
                    startedAt: timing.startedAt,
                    durationSeconds: timing.durationSeconds
                ))
                metadata.stageTimings = timings
                try ProjectMetadataStore.savePreservingUserEditableFields(
                    metadata,
                    to: paths.metadataURL
                )
            }
        }
        try workerExecutionRecorder.commitRecoveryBaseline()
        var trainingManifestWarning: String?
        let trainingManifestExists = FileManager.default.fileExists(
            atPath: paths.trainingManifestURL.path
        ) || ((try? FileManager.default.destinationOfSymbolicLink(
            atPath: paths.trainingManifestURL.path
        )) != nil)
        if trainingManifestExists {
            do {
                _ = try TrainingArtifactStore.load(
                    from: paths.trainingManifestURL,
                    projectPaths: paths
                )
            } catch {
                trainingManifestWarning = error.localizedDescription
            }
        }
        let preserveTerminalPairRecovery: Bool
        if metadata.state.lastError != nil,
           metadata.state.stage == .sfmMatching {
            preserveTerminalPairRecovery = try hasBoundTerminalPairRecovery(
                paths: paths,
                resolvedRunPlan: resolvedRunPlan
            )
        } else {
            preserveTerminalPairRecovery = false
        }
        if preserveTerminalPairRecovery {
            effectiveLastCompletedStage = .sfmFeatures
        }
        if metadata.state.lastError != nil,
           metadata.geometryRecovery != nil,
           !preserveTerminalPairRecovery {
            metadata.geometryRecovery = nil
            try ProjectMetadataStore.savePreservingUserEditableFields(
                metadata,
                to: paths.metadataURL
            )
        }
        let metadataForResumeValidation = metadata

        // Now we've committed to a new run: reset per-tool logs so users see only the
        // current attempt. ToolLogWriter is now an appender (so multiple stages within
        // one run share a file cleanly); the orchestrator owns the cross-run truncation.
        Self.resetPerRunToolLogs(at: paths)
        tooling.colmap.setWorkerExecutionObserver { invocation in
            try workerExecutionRecorder.record(invocation)
        }
        defer { tooling.colmap.setWorkerExecutionObserver(nil) }
        let logger = PipelineLogger(eventsURL: paths.eventsLogURL, logURL: paths.pipelineLogURL, emit: events)
        var currentStage: PipelineStage = .importInput
        var didEmitFailure = false
        var didRetryWithCpu = false
        var didRetryWithExactMatcher = false
        var pairRecoveryLevel: PairRecoveryLevel = .normal
        var pairAttemptMode: PairAttemptMode = .policy
        var latestPreparedPairPlan: ColmapPairPlan?
        var latestPreparedRetrievalEvidence: PairGraphRetrievalAttemptEvidence?
        var latestCompletedPairPlan: ColmapPairPlan?
        var pairGraphAttempts: [PairGraphAttemptEvidence] = []
        var retrievalWasScheduled = false
        var attemptedPairConfigurations: Set<String> = []
        var acceptedPairGraphEvidence: PairGraphEvidence?
        var acceptedDa3PairGraphEvidence: PairGraphEvidence?
        var latestRejectedCaptureConnectionFailure: CaptureConnectionFailure?
        var matchingDurationSeconds = 0.0
        let resumeValidationMode = effectiveLastCompletedStage != nil
        let hasInterruptionEvidence = metadata.checkpoint != nil || metadata.lastRunStartedAt != nil
        let wasInterrupted = metadata.state.lastError == nil
            && metadata.state.stage != .done
            && hasInterruptionEvidence
        let skipTraining = config.developmentOverrides.skipTraining

        metadata.lastRunStartedAt = Date()
        try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)

        if metadata.state.lastError != nil {
            try cleanForRetry(
                failedStage: metadata.state.stage,
                paths: paths,
                preservingPairGraphRecovery: preserveTerminalPairRecovery
            )
            try paths.ensureDirectories()
        }

        let emit: @Sendable (PipelineEvent) -> Void = { event in
            switch event {
            case .stageStarted(let stage):
                stageTiming.start(stage)
                logger.emit(event)
            case .stageFinished(let stage):
                logger.emit(event)
                if let durationText = stageTiming.finish(stage) {
                    logger.emit(.stageLog(stage: stage, line: "Stage duration: \(durationText)", isError: false))
                }
            default:
                logger.emit(event)
            }
        }
        if let trainingManifestWarning {
            emit(.stageLog(
                stage: .trainSplat,
                line: "Ignored an invalid training resume record: \(trainingManifestWarning)",
                isError: true
            ))
        }
        if invalidatedMatchingForPlanChange {
            emit(.stageLog(
                stage: .sfmMatching,
                line: "Discarded stale image matches after reconstruction policy changed.",
                isError: false
            ))
        }

        var pendingMatchingResetMessage: String?
        if wasInterrupted && metadataForResumeValidation.checkpoint?.stage == .sfmMatching {
            pendingMatchingResetMessage = "Discarded partial image matches before resuming reconstruction."
        }

        func resetMatchingIfNeeded() throws {
            guard let message = pendingMatchingResetMessage else { return }
            try ColmapDatabaseMatchStore.clearMatchingResults(at: paths.colmapDatabaseURL)
            pendingMatchingResetMessage = nil
            emit(.stageLog(
                stage: .sfmMatching,
                line: message,
                isError: false
            ))
        }

        func stageIndex(_ stage: PipelineStage) -> Int {
            PipelineStage.allCases.firstIndex(of: stage) ?? 0
        }

        var reranStageBeforeTraining = false
        var runtimeInputReceiptDigest: String?

        func markStageForRerun(
            _ stage: PipelineStage,
            discardWorkerEvidence: Bool = false
        ) throws -> Bool {
            guard stageIndex(stage) < stageIndex(.trainSplat) else { return true }
            guard !reranStageBeforeTraining else { return true }
            reranStageBeforeTraining = true
            try invalidateAcceptedArtifactsForGeometryRerun(
                startingAt: stage,
                metadata: &metadata,
                paths: paths
            )
            if discardWorkerEvidence {
                try workerExecutionRecorder.invalidate(startingAt: stage)
            }
            try paths.ensureDirectories()
            return true
        }

        func writeCheckpoint(
            stage: PipelineStage,
            progress: Double? = nil,
            message: String? = nil,
            details: PipelineCheckpointDetails? = nil
        ) {
            metadata.checkpoint = PipelineCheckpoint(
                stage: stage,
                updatedAt: Date(),
                progressFraction: progress,
                message: message,
                inputReceiptDigest: runtimeInputReceiptDigest,
                details: details
            )
            try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        }

        func shouldRunStage(_ stage: PipelineStage) throws -> Bool {
            let validationMetadata = resumeValidationMode ? metadataForResumeValidation : metadata
            if stage == .sfmMapping,
               !reranStageBeforeTraining,
               FileManager.default.fileExists(atPath: paths.geometryManifestURL.path),
               try validateStageOutput(
                   stage,
                   paths: paths,
                   metadata: validationMetadata
               ) == .valid {
                metadata.geometryRecovery = nil
                metadata.state = PipelineState(stage: .sfmMapping, lastError: nil)
                metadata.checkpoint = nil
                try ProjectMetadataStore.savePreservingUserEditableFields(
                    metadata,
                    to: paths.metadataURL
                )
                emit(.stageLog(
                    stage: .sfmMapping,
                    line: "Recovered the completed camera reconstruction.",
                    isError: false
                ))
                return false
            }
            guard let lastCompletedStage = effectiveLastCompletedStage else { return true }
            if stage == .trainSplat,
               !reranStageBeforeTraining,
               (try? TrainingArtifactStore.load(
                   from: paths.trainingManifestURL,
                   projectPaths: paths
               ).completionStatus) == .completed {
                switch try validateStageOutput(stage, paths: paths, metadata: validationMetadata) {
                case .valid:
                    return false
                case .missing:
                    emit(.stageLog(
                        stage: stage,
                        line: "The completed training result is missing. Training will restart.",
                        isError: true
                    ))
                case .corrupt(let reason):
                    emit(.stageLog(
                        stage: stage,
                        line: "The completed training result is invalid (\(reason)). Training will restart.",
                        isError: true
                    ))
                }
                try TrainingArtifactStore.discardCompletedArtifact(
                    metadata: &metadata,
                    paths: paths
                )
                try paths.ensureDirectories()
                return true
            }
            if stage == .trainSplat, reranStageBeforeTraining {
                return true
            }
            if stageIndex(stage) <= stageIndex(lastCompletedStage) {
                if !resumeValidationMode {
                    return !isStageComplete(stage, paths: paths, metadata: metadata)
                }
                switch try validateStageOutput(stage, paths: paths, metadata: validationMetadata) {
                case .valid:
                    return false
                case .missing:
                    return try markStageForRerun(stage, discardWorkerEvidence: true)
                case .corrupt(let reason):
                    emit(.stageLog(
                        stage: stage,
                        line: "Detected partial/corrupt stage output for resume (\(reason)). Re-running \(stage.displayName).",
                        isError: true
                    ))
                    try cleanForRetry(failedStage: stage, paths: paths)
                    try paths.ensureDirectories()
                    return try markStageForRerun(stage, discardWorkerEvidence: true)
                }
            }
            return try markStageForRerun(stage)
        }

        func recordFinishedStageTiming(_ stage: PipelineStage) {
            if let timing = stageTiming.consumeRecord(stage) {
                var timings = metadata.stageTimings ?? []
                timings.removeAll { $0.stage == stage }
                timings.append(StageTimingRecord(
                    stage: stage,
                    startedAt: timing.startedAt,
                    durationSeconds: timing.durationSeconds
                ))
                metadata.stageTimings = timings
            }
        }

        func suspendStageTimingForRetry(_ stage: PipelineStage) {
            if let durationText = stageTiming.finish(stage) {
                logger.emit(.stageLog(
                    stage: stage,
                    line: "Cumulative stage duration before retry: \(durationText)",
                    isError: false
                ))
            }
        }

        func markStageComplete(_ stage: PipelineStage) {
            recordFinishedStageTiming(stage)
            metadata.state = PipelineState(stage: stage, lastError: nil)
            metadata.checkpoint = nil
            try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        }

        func stopIfRequested(after stage: PipelineStage) throws {
            guard config.developmentOverrides.stopAfterStage == stage else { return }
            emit(.stageLog(stage: stage, line: "Stopped after \(stage.displayName) by development override.", isError: false))
            metadata.lastRunStartedAt = nil
            try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
            throw DevelopmentStop()
        }

        func emitFailure(stage: PipelineStage, userMessage: String, debugMessage: String) {
            didEmitFailure = true
            _ = stageTiming.finish(stage)
            recordFinishedStageTiming(stage)
            metadata.state = PipelineState(stage: stage, lastError: userMessage)
            metadata.checkpoint = nil
            metadata.lastRunStartedAt = nil
            // Keep the actual failure time for diagnostics; a later project open
            // must not make a failed run appear newer than it was.
            metadata.lastFailureAt = Date()
            try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
            emit(.pipelineFailed(stage: stage, userMessage: userMessage, debugMessage: debugMessage))
        }

        do {
            try inputLease.validate()
            let videoClipIdentities = try VideoClipIdentityResolver.resolve(
                sourceSHA256s: inputLease.videos.map(\.sha256),
                pairingPolicy: resolvedRunPlan.pairingPolicy
            )
            let processingVideos = videoClipIdentities.map {
                inputLease.videos[$0.sourceIndex]
            }
            runtimeInputReceiptDigest = inputLease.receiptDigest
            if wasInterrupted, let checkpoint = metadata.checkpoint {
                guard checkpoint.inputReceiptDigest == inputLease.receiptDigest else {
                    throw RuntimeInputSnapshotError.invalidMetadata
                }
                emit(.stageLog(
                    stage: checkpoint.stage,
                    line: "Recovered interrupted run checkpoint from \(checkpoint.updatedAt.formatted(date: .abbreviated, time: .standard)); validating resume outputs.",
                    isError: false
                ))
            }
            try Task.checkCancellation()
            if try shouldRunStage(.importInput) {
                currentStage = .importInput
                emit(.stageStarted(stage: .importInput))
                writeCheckpoint(stage: .importInput, progress: 0, message: "Import started")
                try importInputs(metadata: metadata, paths: paths, progress: { fraction, message in
                    emit(.stageProgress(stage: .importInput, fraction: fraction, message: message))
                })
                emit(.stageFinished(stage: .importInput))
                markStageComplete(.importInput)
                try stopIfRequested(after: .importInput)
            }

            let frameProfile = frameExtractionProfile(
                for: resolvedRunPlan,
                detail: requestedOptions.detailProfile
            )
            let targetFrames = frameProfile.targetCount
            let maxDim = frameProfile.maxDimension
            let colmapMaxImageSize = resolvedRunPlan.colmapMaximumImageDimension
            let featureExtractionWorkers = resolvedRunPlan.geometryWorkerBudget
                .featureExtractionWorkers
            let featureMatchingWorkers = resolvedRunPlan.geometryWorkerBudget
                .coupledMatchingWorkers
            let vocabularyRetrievalWorkers = resolvedRunPlan.geometryWorkerBudget
                .vocabularyRetrievalWorkers
            var colmapExtractOptions = colmapOptionsForExtraction(
                workerCount: featureExtractionWorkers
            )
            var colmapMatchOptions = colmapOptionsForMatching(
                workerCount: featureMatchingWorkers
            )
            let preferColmapGpu = tooling.colmapGPUSupport?(config.toolchain.colmap)
                ?? shouldUseColmapGpu(colmapPath: config.toolchain.colmap)
            colmapExtractOptions.useGPU = preferColmapGpu
            colmapMatchOptions.useGPU = preferColmapGpu
            colmapExtractOptions.maxNumFeatures = resolvedRunPlan.colmapMaximumFeatureCount
            colmapMatchOptions.maxNumFeatures = resolvedRunPlan.colmapMaximumFeatureCount
            colmapMatchOptions.maxNumMatches = resolvedRunPlan.colmapMaximumMatchCount
            var selectedFrames: [URL] = []
            var selectedFrameManifest: [SelectedFrameMapping] = []
            var resolvedFrameTargets: GlobalFrameTargets?
            var verifiedRawFrameManifest: ExtractedFrameManifest?
            var inspectedVideoSources: [FrameExtractionSource]?
            if metadata.input.hasVideos {
                if try shouldRunStage(.extractFrames) {
                    currentStage = .extractFrames
                    emit(.stageStarted(stage: .extractFrames))
                    writeCheckpoint(stage: .extractFrames, progress: 0, message: "Frame extraction started")
                    emit(.stageLog(
                        stage: .extractFrames,
                        line: "Detail frame ceiling: \(targetFrames).",
                        isError: false
                    ))
                    self.removeIfExists(paths.framesRawManifestURL)
                    try self.resetDirectory(paths.framesRawURL)
                    let extractor = FrameExtractor()
                    let selectedVideoFiles = metadata.input.videoFiles
                    guard inputLease.videos.map(\.projectRelativePath) == selectedVideoFiles else {
                        throw PipelineError.invalidInput
                    }
                    let videos = processingVideos.map(\.projectRelativePath)
                    let importedVideos = processingVideos.map(\.url)
                    try inputLease.validate()
                    var analysisOptions = FrameExtractionOptions(
                        targetCount: targetFrames,
                        maxDimension: maxDim,
                        targetFPS: frameProfile.targetFPS,
                        minDistanceRatio: frameProfile.minDistanceRatio,
                        outputFormat: frameProfile.outputFormat
                    )
                    var sources: [FrameExtractionSource] = []
                    sources.reserveCapacity(videos.count)
                    for (index, file) in videos.enumerated() {
                        try Task.checkCancellation()
                        let sourceName = URL(fileURLWithPath: file).lastPathComponent
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Inspecting \(sourceName).",
                            isError: false
                        ))
                        sources.append(try await extractor.inspect(importedVideos[index]))
                    }
                    inspectedVideoSources = sources
                    var cumulativeDurations = [0.0]
                    cumulativeDurations.reserveCapacity(sources.count + 1)
                    for source in sources {
                        cumulativeDurations.append(
                            cumulativeDurations[cumulativeDurations.count - 1]
                                + source.durationSeconds
                        )
                    }
                    let totalVideoDuration = cumulativeDurations.last ?? 0
                    guard totalVideoDuration.isFinite, totalVideoDuration > 0 else {
                        throw PipelineError.invalidInput
                    }
                    let retainedPhotoCount = photoSelectionProjection?
                        .canonicalReceipts.count ?? 0
                    let videoTargetFrames: Int
                    if retainedPhotoCount > 0 {
                        videoTargetFrames = targetFrames
                    } else {
                        guard let durationTarget = Self.durationAwareVideoFrameTarget(
                            durations: sources.map(\.durationSeconds),
                            frameCeiling: targetFrames,
                            analysisFrameRate: resolvedRunPlan.analysisFrameRate,
                            detail: requestedOptions.detailProfile
                        ) else {
                            throw PipelineError.invalidInput
                        }
                        videoTargetFrames = durationTarget
                    }
                    analysisOptions.targetCount = videoTargetFrames
                    if videoTargetFrames < targetFrames {
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Using up to \(videoTargetFrames) frames for \(String(format: "%.0f", ceil(totalVideoDuration))) seconds of video.",
                            isError: false
                        ))
                    }
                    guard let inputReceipts = metadata.videoInputReceipts,
                          inputReceipts.count == inputLease.videos.count else {
                        throw PipelineError.invalidInput
                    }
                    let analysisPolicy = VideoFrameAnalysisPolicy(
                        resolvedRunPlan: resolvedRunPlan
                    )
                    var analyses: [FrameExtractionAnalysis] = []
                    analyses.reserveCapacity(sources.count)
                    for (index, source) in sources.enumerated() {
                        try Task.checkCancellation()
                        let identity = videoClipIdentities[index]
                        let receipt = inputReceipts[identity.sourceIndex]
                        let analysisURL = try paths.resolveProjectRelativePath(
                            receipt.analysisArtifactPath
                        )
                        let artifact = try VideoFrameAnalysisArtifactStore.load(
                            from: analysisURL,
                            receipt: receipt,
                            expectedPolicy: analysisPolicy,
                            expectedClipGroupID: identity.groupID,
                            expectedSourceIndex: identity.sourceIndex,
                            projectPaths: paths
                        )
                        analyses.append(try artifact.frameExtractionAnalysis(source: source))
                        let sourceName = URL(
                            fileURLWithPath: receipt.projectRelativePath
                        ).lastPathComponent
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Using verified frame analysis for \(sourceName).",
                            isError: false
                        ))
                    }
                    try workerExecutionRecorder.recordVideoSourceAnalysis(
                        videoSourceCount: sources.count,
                        snapshot: VideoSourceAnalysisConcurrencySnapshot(
                            startedAnalysisTaskCount: sources.count,
                            peakInFlightAnalysisTaskCount: min(
                                sources.count,
                                analysisPolicy.maximumConcurrentDecoders
                            )
                        )
                    )
                    emit(.stageProgress(
                        stage: .extractFrames,
                        fraction: 0.1,
                        message: "Choosing frames"
                    ))
                    let finalPlan = try resolveGlobalFrameTargets(
                        videos: analyses.map {
                            VideoFrameAllocationInput(
                                durationSeconds: $0.durationSeconds,
                                availableCandidateCount: $0.availableCandidateCount
                            )
                        },
                        validPhotoCount: retainedPhotoCount,
                        targetCount: videoTargetFrames,
                        photoSelection: resolvedRunPlan.photoSelection
                    )
                    if finalPlan.totalTargetCount < videoTargetFrames {
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Using \(finalPlan.totalTargetCount) frames because only that many decoded frames produced valid analysis data.",
                            isError: true
                        ))
                    }
                    resolvedFrameTargets = finalPlan
                    let targets = finalPlan.videoTargets
                    var extractedGroups: [[ExtractedFrameOutput]] = []
                    extractedGroups.reserveCapacity(analyses.count)
                    for (index, analysis) in analyses.enumerated() {
                        try Task.checkCancellation()
                        let perVideoTarget = targets[index]
                        guard perVideoTarget > 0 else {
                            throw PipelineError.videoFrameBudgetTooSmall(
                                required: videos.count,
                                available: targets.reduce(0, +)
                            )
                        }
                        let sourceName = URL(fileURLWithPath: videos[index]).lastPathComponent
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Extracting \(perVideoTarget) frames from \(sourceName).",
                            isError: false
                        ))
                        let rawDir = rawFramesDirectory(index: index, paths: paths)
                        try self.resetDirectory(rawDir)
                        var outputOptions = analysisOptions
                        outputOptions.targetCount = perVideoTarget
                        let progressStartDuration = cumulativeDurations[index]
                        let progressClipDuration = sources[index].durationSeconds
                        let extracted = try await extractor.extractFrameOutputs(
                            from: analysis,
                            targetCount: perVideoTarget,
                            to: rawDir,
                            options: outputOptions,
                            progress: { fraction, message in
                                let completedDuration = progressStartDuration
                                    + progressClipDuration * fraction
                                let scaled = 0.1
                                    + 0.9 * completedDuration / totalVideoDuration
                                emit(.stageProgress(stage: .extractFrames, fraction: scaled, message: message))
                            }
                        )
                        extractedGroups.append(extracted)
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Wrote \(extracted.count) extracted frame(s) from \(sourceName).",
                            isError: false
                        ))
                        writeCheckpoint(
                            stage: .extractFrames,
                            progress: 0.1
                                + 0.9 * cumulativeDurations[index + 1] / totalVideoDuration,
                            message: "Extracted \(extracted.count) frames from \(sourceName)",
                            details: .extractFrames(ExtractFramesCheckpoint(
                                videoIndex: index,
                                videoName: videoClipIdentities[index].groupID,
                                extractedCount: extracted.count,
                                targetCount: perVideoTarget
                            ))
                        )
                    }
                    verifiedRawFrameManifest = try ExtractedFrameManifestStore.persist(
                        groups: extractedGroups,
                        targetCounts: targets,
                        sourceEvidence: processingVideos.map {
                            ExtractedFrameSourceEvidence(
                                projectRelativePath: $0.projectRelativePath,
                                byteCount: $0.byteCount,
                                sha256: $0.sha256
                            )
                        },
                        paths: paths
                    )
                    try inputLease.validate()
                    emit(.stageFinished(stage: .extractFrames))
                    markStageComplete(.extractFrames)
                    try stopIfRequested(after: .extractFrames)
                }
            }

            if metadata.input.hasVideos || metadata.input.hasPhotos {
                if try shouldRunStage(.selectFrames) {
                    currentStage = .selectFrames
                    emit(.stageStarted(stage: .selectFrames))
                    writeCheckpoint(stage: .selectFrames, progress: 0, message: "Frame selection started")
                    try self.resetDirectory(paths.framesSelectedURL)
                    self.removeIfExists(paths.framesSelectedManifestURL)
                    var groups: [SelectedFrameGroup] = []

                    if metadata.input.hasVideos {
                        let manifest: ExtractedFrameManifest
                        if let verifiedRawFrameManifest {
                            manifest = verifiedRawFrameManifest
                        } else {
                            manifest = try ExtractedFrameManifestStore.loadVerified(
                                paths: paths,
                                expectedSourceEvidence: processingVideos.map {
                                    ExtractedFrameSourceEvidence(
                                        projectRelativePath: $0.projectRelativePath,
                                        byteCount: $0.byteCount,
                                        sha256: $0.sha256
                                    )
                                },
                                maximumTotalFrames: targetFrames
                            )
                        }
                        let frameGroups = try ExtractedFrameManifestStore.frameGroupsWithEvidence(
                            from: manifest,
                            paths: paths
                        )
                        let importedVideos = processingVideos.map(\.url)
                        try inputLease.validate()
                        let sources: [FrameExtractionSource]
                        if let inspectedVideoSources {
                            sources = inspectedVideoSources
                        } else {
                            let extractor = FrameExtractor()
                            var inspected: [FrameExtractionSource] = []
                            inspected.reserveCapacity(importedVideos.count)
                            for video in importedVideos {
                                inspected.append(try await extractor.inspect(video))
                            }
                            inspectedVideoSources = inspected
                            sources = inspected
                        }
                        guard frameGroups.count == importedVideos.count,
                              sources.count == importedVideos.count else {
                            throw PipelineError.invalidInput
                        }
                        for (index, rawOutputs) in frameGroups.enumerated() {
                            try Task.checkCancellation()
                            let groupID = videoClipIdentities[index].groupID
                            let videoSnapshot = processingVideos[index]
                            groups.append(.init(
                                id: groupID,
                                frames: rawOutputs.map(\.url),
                                isVideo: true,
                                videoSource: SelectedVideoSource(
                                    projectRelativePath: videoSnapshot.projectRelativePath,
                                    sourceSHA256: videoSnapshot.sha256,
                                    source: sources[index]
                                ),
                                videoOriginsByFileName: Dictionary(
                                    uniqueKeysWithValues: rawOutputs.map {
                                        ($0.url.lastPathComponent, $0.origin)
                                    }
                                )
                            ))
                        }
                    }

                    if metadata.input.photosFolder != nil {
                        if let photoSelectionProjection {
                            let photoTarget: Int
                            if metadata.input.hasVideos {
                                let videoFrameCount = groups
                                    .filter(\.isVideo)
                                    .reduce(0) { $0 + $1.frames.count }
                                photoTarget = resolvedFrameTargets?.photoTarget
                                    ?? min(
                                        photoSelectionProjection.canonicalReceipts.count,
                                        max(0, targetFrames - videoFrameCount)
                                    )
                            } else {
                                photoTarget = photoSelectionProjection.canonicalReceipts.count
                            }
                            let selectedReceipts = try photoSelectionProjection.project(
                                targetCount: photoTarget
                            )
                            let snapshotByProjectRelativePath = Dictionary(
                                uniqueKeysWithValues: inputLease.photos.map {
                                    ($0.projectRelativePath, $0)
                                }
                            )
                            var selectedPhotos: [URL] = []
                            var photoBindings: [String: SelectedInputSource] = [:]
                            selectedPhotos.reserveCapacity(selectedReceipts.count)
                            photoBindings.reserveCapacity(selectedReceipts.count)
                            for receipt in selectedReceipts {
                                guard let snapshot = snapshotByProjectRelativePath[
                                    receipt.projectRelativePath
                                ], snapshot.sha256 == receipt.sha256,
                                   snapshot.byteCount == receipt.byteCount else {
                                    throw PipelineError.invalidInput
                                }
                                selectedPhotos.append(snapshot.url)
                                photoBindings[snapshot.url.lastPathComponent] =
                                    SelectedInputSource(
                                        projectRelativePath: snapshot.projectRelativePath,
                                        sha256: snapshot.sha256,
                                        photoRetainedRank: receipt.retainedRank
                                    )
                            }
                            if !selectedPhotos.isEmpty {
                                let budgetProjection: FrameBudgetProjection
                                switch photoSelectionProjection.policy {
                                case .rankedPrefix:
                                    budgetProjection = .rankedPrefix
                                case .evenlySpaced:
                                    budgetProjection = .evenlySpaced
                                case .preserve:
                                    budgetProjection = .preserve
                                }
                                groups.append(.init(
                                    id: "photos",
                                    frames: selectedPhotos,
                                    isVideo: false,
                                    budgetProjection: budgetProjection,
                                    sourceBindingsByFileName: photoBindings
                                ))
                                emit(.stageLog(
                                    stage: .selectFrames,
                                    line: "Using \(selectedPhotos.count) of \(photoSelectionProjection.artifact.acceptedCount) valid photos.",
                                    isError: false
                                ))
                            }
                            let duplicateCount =
                                photoSelectionProjection.artifact.exactDuplicateCount
                                + photoSelectionProjection.artifact.companionDuplicateCount
                            if photoSelectionProjection.artifact.unreadableCount > 0
                                || duplicateCount > 0 {
                                emit(.stageLog(
                                    stage: .selectFrames,
                                    line: "Skipped \(photoSelectionProjection.artifact.unreadableCount) unreadable and \(duplicateCount) duplicate photo(s).",
                                    isError: false
                                ))
                            }
                        } else if !metadata.input.hasVideos || !inputLease.photos.isEmpty {
                            throw PipelineError.invalidInput
                        }
                    }

                    let budgetedGroups = try applyFrameBudget(
                        to: groups,
                        targetCount: targetFrames,
                        photoSelection: resolvedRunPlan.photoSelection
                    )
                    let selectedCountBeforeBudget = groups.reduce(0) { $0 + $1.frames.count }
                    let selectedCountAfterBudget = budgetedGroups.reduce(0) { $0 + $1.frames.count }
                    if selectedCountAfterBudget < selectedCountBeforeBudget {
                        emit(.stageLog(
                            stage: .selectFrames,
                            line: "Applied \(metadata.requestedRunOptions.detailProfile.rawValue) frame budget: \(selectedCountBeforeBudget) -> \(selectedCountAfterBudget).",
                            isError: false
                        ))
                    }

                    try inputLease.validate()
                    let selection = try copySelected(
                        groups: budgetedGroups,
                        to: paths.framesSelectedURL,
                        manifestURL: paths.framesSelectedManifestURL,
                        maxDimension: maxDim,
                        projectPaths: paths,
                        progress: { fraction, message in
                            emit(.stageProgress(stage: .selectFrames, fraction: fraction, message: message))
                        }
                    )
                    selectedFrames = selection.frames
                    selectedFrameManifest = selection.manifest
                    try inputLease.validate()
                    let adjustedLowLightFrames = selection.manifest.filter {
                        ($0.lowLightExposureEV ?? 0) > 0
                    }.count
                    if adjustedLowLightFrames > 0 {
                        emit(.stageLog(
                            stage: .selectFrames,
                            line: "Adjusted exposure for \(adjustedLowLightFrames) safely underexposed selected frame(s).",
                            isError: false
                        ))
                    }
                    writeCheckpoint(
                        stage: .selectFrames,
                        progress: 1.0,
                        message: "Selected \(selection.frames.count) frames",
                            details: .selectFrames(SelectFramesCheckpoint(
                            groupsProcessed: budgetedGroups.count,
                            selectedCount: selection.frames.count,
                            manifestPath: try paths.projectRelativePath(for: paths.framesSelectedManifestURL)
                        ))
                    )
                    emit(.stageFinished(stage: .selectFrames))
                    markStageComplete(.selectFrames)
                    try cleanupRawFramesAfterDurableSelection(
                        paths: paths,
                        metadata: metadata
                    )
                    try stopIfRequested(after: .selectFrames)
                }
            }

            try cleanupRawFramesAfterDurableSelection(
                paths: paths,
                metadata: metadata
            )

            selectedFrames = try loadImages(in: paths.framesSelectedURL)
            if selectedFrames.isEmpty {
                throw PipelineError.invalidInput
            }
            if selectedFrameManifest.isEmpty {
                selectedFrameManifest = (try? loadSelectedFrameManifest(from: paths.framesSelectedManifestURL)) ?? []
            }

            if selectedFrames.count < RunPlanResolver.minimumReconstructionImageCount {
                throw PipelineError.insufficientInputImages(selectedFrames.count)
            }
            let sharedCameraRequested = da3SharedCameraPreference(
                input: metadata.input,
                cameraGrouping: resolvedRunPlan.cameraGrouping
            )
            let selectedUniformPixelDimensions: SelectedImagePixelDimensions?
            let shareCameraAcrossSelectedFrames: Bool
            if sharedCameraRequested {
                selectedUniformPixelDimensions = try selectedImageUniformPixelDimensions(
                    selectedFrames
                )
                shareCameraAcrossSelectedFrames = selectedUniformPixelDimensions != nil
            } else {
                selectedUniformPixelDimensions = nil
                shareCameraAcrossSelectedFrames = false
            }
            if resolvedRunPlan.cameraGrouping == .sameCameraAndLens,
               !shareCameraAcrossSelectedFrames {
                throw PipelineError.incompatibleSharedCameraDimensions
            }
            let featureCameraInitialization = try ColmapCameraInitializationReceipt.resolve(
                recipe: resolvedRunPlan.cameraInitializationRecipe,
                cameraModel: cameraModel(
                    detailProfile: metadata.requestedRunOptions.detailProfile,
                    capturePath: resolvedRunPlan.capturePath,
                    lensProjection: resolvedRunPlan.lensProjection
                ),
                singleCamera: shareCameraAcrossSelectedFrames,
                uniformDimensions: selectedUniformPixelDimensions
            )

            let geometryMemorySampler = GeometryMemorySampler()
            geometryMemorySampler.start()
            defer { geometryMemorySampler.cancel() }

            try Task.checkCancellation()
            let da3WindowSize = resolvedRunPlan.chunkSize
            let geometryRecoveryImageNames = selectedFrames.map(\.lastPathComponent)
            let geometryRecoveryFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: geometryRecoveryImageNames,
                projectPaths: paths
            )
            let plannedIncrementalCadence = resolvedRunPlan.incrementalMappingCadence

            let restoredGeometryRecovery: GeometryRecoveryState?
            if let recovery = metadata.geometryRecovery {
                do {
                    try recovery.validateBinding(
                        expectedImageNames: geometryRecoveryImageNames,
                        expectedSelectedFramesDigest: geometryRecoveryFramesDigest,
                        expectedGeometryBackend: resolvedRunPlan.geometryBackend,
                        expectedPlannedIncrementalCadence: recovery.activeBackend == .colmap
                            ? plannedIncrementalCadence
                            : nil
                    )
                    restoredGeometryRecovery = recovery
                } catch {
                    metadata.geometryRecovery = nil
                    try ProjectMetadataStore.savePreservingUserEditableFields(
                        metadata,
                        to: paths.metadataURL
                    )
                    restoredGeometryRecovery = nil
                    emit(.stageLog(
                        stage: .sfmMapping,
                        line: "Discarded stale reconstruction recovery data.",
                        isError: true
                    ))
                }
            } else {
                restoredGeometryRecovery = nil
            }
            var acceptedMapper: String?
            let preservedMappingAttemptCount =
                workerExecutionRecorder.maximumRecordedMappingAttemptOrdinal
            var mappingAttemptCount = max(
                restoredGeometryRecovery?.mappingAttemptCount ?? 0,
                preservedMappingAttemptCount
            )
            var acceptedMappingArtifact: MappingArtifact?
            var acceptedConditioningAnalysis: GeometryConditioningAnalysis?
            var canonicalPublicationByAttemptAndPath:
                [String: CanonicalModelPublicationArtifact] = [:]
            func prepareCanonicalTextCandidate(
                at url: URL,
                mappingAttemptOrdinal: Int
            ) throws -> CanonicalModelPublicationArtifact {
                let key = "\(mappingAttemptOrdinal):\(url.standardizedFileURL.path)"
                if let existing = canonicalPublicationByAttemptAndPath[key] {
                    return existing
                }
                let binaryNames = ["cameras.bin", "images.bin", "points3D.bin"]
                let hasBinaryModel = binaryNames.allSatisfy {
                    FileManager.default.fileExists(
                        atPath: url.appendingPathComponent($0).path
                    )
                }
                let imagesTextURL = url.appendingPathComponent("images.txt")
                if !hasBinaryModel {
                    _ = try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(
                        at: imagesTextURL,
                        checkCancellation: self.tooling.checkCancellation
                    )
                }
                let publication = try self.prepareTextSparseModelForCanonicalPublication(
                    at: url,
                    mappingAttemptOrdinal: mappingAttemptOrdinal,
                    workerExecutionRecorder: workerExecutionRecorder
                )
                if hasBinaryModel,
                   try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(
                       at: imagesTextURL,
                       checkCancellation: self.tooling.checkCancellation
                   ) {
                    throw PipelineError.outputMissing
                }
                canonicalPublicationByAttemptAndPath[key] = publication
                return publication
            }
            var mappingFallbackReasons = restoredGeometryRecovery?.mappingFallbackReasons ?? []
            if restoredGeometryRecovery == nil,
               preservedMappingAttemptCount > 0 {
                mappingFallbackReasons.append("mapping retry after failed run")
            }
            var activeIncrementalCadence = restoredGeometryRecovery?
                .activeIncrementalCadence ?? plannedIncrementalCadence
            var activeCadenceFallbackTrigger = restoredGeometryRecovery?
                .cadenceFallbackTrigger
            var activeMapperGraphContext: ColmapMapperWorkerInvocationContext? = {
                guard let recovery = restoredGeometryRecovery,
                      let ordinal = recovery.acceptedPairAttemptOrdinal,
                      let pairListDigest = recovery.pairListDigest,
                      let matchingDatabaseDigest = recovery.matchingDatabaseDigest else {
                    return nil
                }
                return ColmapMapperWorkerInvocationContext(
                    pairGraphAttemptOrdinal: ordinal,
                    pairListDigest: pairListDigest,
                    descriptorMatcher: resolvedRunPlan.normalDescriptorMatcher,
                    matchingDatabaseDigest: matchingDatabaseDigest
                )
            }()
            var resumingInterruptedMapping = restoredGeometryRecovery != nil
                && metadata.checkpoint?.stage == .sfmMapping
                && mappingAttemptCount > 0

            if let recovery = restoredGeometryRecovery {
                if recovery.activeBackend == .colmap {
                    switch recovery.colmapComputeMode {
                    case .cpu:
                        colmapExtractOptions.useGPU = false
                        colmapMatchOptions.useGPU = false
                    case .gpu:
                        break
                    case nil:
                        throw GeometryRecoveryState.ValidationError.invalidBackendFields
                    }
                }
                if recovery.activeBackend == .colmap,
                   let level = recovery.pendingPairRecoveryLevel {
                    pairRecoveryLevel = PairRecoveryLevel(level)
                }
            }

            func recordMappingFallback(_ reason: String) {
                guard !mappingFallbackReasons.contains(reason) else { return }
                mappingFallbackReasons.append(reason)
            }

            func persistGeometryRecovery(
                pendingPairRecoveryLevel: PairGraphRecoveryLevel? = nil
            ) throws {
                let recoveryBackend = resolvedRunPlan.geometryBackend
                let mapperGraphContext = recoveryBackend == .colmap
                    ? activeMapperGraphContext
                    : nil
                let state = GeometryRecoveryState(
                    selectedFramesDigest: geometryRecoveryFramesDigest,
                    orderedImageNames: geometryRecoveryImageNames,
                    activeBackend: recoveryBackend,
                    mappingAttemptCount: mappingAttemptCount,
                    mappingFallbackReasons: mappingFallbackReasons,
                    pendingPairRecoveryLevel: pendingPairRecoveryLevel,
                    colmapComputeMode: recoveryBackend == .colmap
                        ? (colmapMatchOptions.useGPU ? .gpu : .cpu)
                        : nil,
                    plannedIncrementalCadence: recoveryBackend == .colmap
                        ? plannedIncrementalCadence
                        : nil,
                    activeIncrementalCadence: recoveryBackend == .colmap
                        ? activeIncrementalCadence
                        : nil,
                    cadenceFallbackTrigger: recoveryBackend == .colmap
                        ? activeCadenceFallbackTrigger
                        : nil,
                    acceptedPairAttemptOrdinal:
                        mapperGraphContext?.pairGraphAttemptOrdinal,
                    pairListDigest: mapperGraphContext?.pairListDigest,
                    matchingDatabaseDigest:
                        mapperGraphContext?.matchingDatabaseDigest
                )
                try state.validate()
                metadata.geometryRecovery = state
                try ProjectMetadataStore.savePreservingUserEditableFields(
                    metadata,
                    to: paths.metadataURL
                )
            }

            func beginMappingAttempt(
                pendingPairRecoveryLevel: PairGraphRecoveryLevel? = nil
            ) throws -> Int {
                if resumingInterruptedMapping {
                    recordMappingFallback("interrupted mapping resumed")
                    resumingInterruptedMapping = false
                }
                guard mappingAttemptCount < GeometryRecoveryState.maximumMappingAttemptCount else {
                    throw GeometryRecoveryState.ValidationError.invalidMappingAttemptCount
                }
                if resolvedRunPlan.geometryBackend == .colmap,
                   acceptedPairGraphEvidence == nil {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                if resolvedRunPlan.geometryBackend == .da3,
                   acceptedDa3PairGraphEvidence == nil {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                let mappingAttemptOrdinal = try workerExecutionRecorder.beginMappingAttempt()
                mappingAttemptCount += 1
                try persistGeometryRecovery(
                    pendingPairRecoveryLevel: pendingPairRecoveryLevel
                )
                return mappingAttemptOrdinal
            }

            let backendPolicy = resolvedRunPlan.geometryBackend
            var completedMappingThisAttempt = false
            var acceptedDa3ModelSubdirectory: String?
            var da3ConfigurationForAttempt: Da3SfmConfig?
            do {
                    if backendPolicy == .da3 {
                        let fm = FileManager.default
                        let seedZero = paths.colmapSeedModelURL
                        let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                        let da3CoverageManifest = paths.da3CoverageManifestURL
                        let da3InputOrdering = resolvedRunPlan.inputOrdering
                        let da3ColmapExtractOptions = colmapExtractOptions
                        let da3ColmapMatchOptions = colmapMatchOptions
                        let effectiveDa3WindowSize = max(4, da3WindowSize)
                        let da3Config = Da3SfmConfig(
                            device: da3DevicePreference(),
                            modelSubdirectory: resolvedRunPlan.modelIdentifier,
                            processResolution: resolvedRunPlan.geometryProcessResolution,
                            maxPoints: da3MaxPointsPreference(
                                detailProfile: metadata.requestedRunOptions.detailProfile
                            ),
                            cameraType: da3CameraTypePreference(
                                detailProfile: metadata.requestedRunOptions.detailProfile,
                                capturePath: resolvedRunPlan.capturePath,
                                lensProjection: resolvedRunPlan.lensProjection
                            ),
                            sharedCamera: shareCameraAcrossSelectedFrames,
                            inputOrdering: da3InputOrdering,
                            windowSize: effectiveDa3WindowSize,
                            windowOverlap: 0,
                            coverageManifestPath: da3CoverageManifest
                        )
                        da3ConfigurationForAttempt = da3Config

                        func readDa3CoverageManifest(required: Bool) throws -> Da3CoverageManifest? {
                            guard fm.fileExists(atPath: da3CoverageManifest.path) else {
                                let line = "DA3 coverage manifest was missing at \(da3CoverageManifest.lastPathComponent)."
                                emit(.stageLog(stage: currentStage, line: line, isError: required))
                                if required {
                                    throw PipelineError.outputMissing
                                }
                                return nil
                            }
                            let manifest: Da3CoverageManifest
                            do {
                                manifest = try Da3CoverageManifest.load(from: da3CoverageManifest)
                            } catch {
                                emit(.stageLog(
                                    stage: currentStage,
                                    line: "DA3 coverage manifest could not be decoded (\(error.localizedDescription)).",
                                    isError: required
                                ))
                                if required {
                                    throw error
                                }
                                return nil
                            }
                            let issues = manifest.validationIssues(
                                selectedImageNames: selectedFrames.map(\.lastPathComponent),
                                expectedWindowSize: da3Config.windowSize,
                                expectedWindowOverlap: da3Config.windowOverlap,
                                expectedInputOrdering: da3Config.inputOrdering,
                                expectedProcessResolution: da3Config.processResolution,
                                expectedMaxPoints: da3Config.maxPoints,
                                expectedCameraType: da3Config.cameraType,
                                expectedSharedCamera: da3Config.sharedCamera,
                                expectedModelSubdirectory: da3Config.modelSubdirectory
                            )
                            if !issues.isEmpty {
                                emit(.stageLog(
                                    stage: currentStage,
                                    line: "DA3 coverage manifest was inconsistent: \(issues.joined(separator: "; ")).",
                                    isError: required
                                ))
                                if required {
                                    throw PipelineError.outputMissing
                                }
                                return nil
                            }
                            guard let learnedPointCount = manifest.fusedSparsePointCount else {
                                throw PipelineError.outputMissing
                            }
                            do {
                                try Da3LearnedPointInitializer.validate(
                                    learnedPointsURL: seedZero.appendingPathComponent("learned_points3D.txt"),
                                    expectedPointCount: learnedPointCount,
                                    maximumPointCount: da3Config.maxPoints
                                )
                                try Self.requireDa3SeedCameraModel(
                                    at: seedZero,
                                    expectedCameraModel: da3Config.cameraType
                                )
                            } catch {
                                emit(.stageLog(
                                    stage: currentStage,
                                    line: "DA3 seed geometry was invalid (\(error.localizedDescription)).",
                                    isError: required
                                ))
                                if required { throw error }
                                return nil
                            }
                            acceptedDa3ModelSubdirectory = manifest.modelSubdirectory
                            emit(.stageLog(stage: currentStage, line: "DA3 coverage: \(manifest.summary).", isError: false))
                            return manifest
                        }

                        func analyzeDa3Model(
                            at modelURL: URL,
                            toolLog: ToolLogWriter? = nil
                        ) async throws -> ReconstructionScore {
                            let report = try await self.tooling.colmap.runModelAnalyzer(
                                colmapPath: self.config.toolchain.colmap,
                                modelPath: modelURL,
                                environment: [:]
                            )
                            for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                                toolLog?.append(stream: "stdout", line: String(line))
                            }
                            let score = ReconstructionScorer.applyingExpectedTotalImages(
                                ReconstructionScorer.parseModelAnalyzerOutput(report),
                                expectedTotalImages: selectedFrames.count
                            )
                            emit(.stageLog(
                                stage: currentStage,
                                line: "DA3 score: \(ReconstructionScorer.summary(score)).",
                                isError: false
                            ))
                            return score
                        }

                        if try shouldRunStage(.sfmFeatures) {
                            currentStage = .sfmFeatures
                            emit(.stageStarted(stage: .sfmFeatures))
                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 0,
                                message: "Depth Anything 3 SfM started",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageLog(stage: .sfmFeatures, line: "SfM backend: da3-mps.", isError: false))
                            emit(.stageLog(
                                stage: .sfmFeatures,
                                line: "DA3 candidate: single batch, ordering=\(da3Config.inputOrdering.rawValue) model=\(da3Config.modelSubdirectory) device=\(da3Config.device) processRes=\(da3Config.processResolution) maxPoints=\(da3Config.maxPoints) sharedCamera=\(da3Config.sharedCamera) cameraType=\(da3Config.cameraType) views=\(da3Config.windowSize).",
                                isError: false
                            ))

                            self.removeIfExists(paths.colmapDatabaseURL)
                            try self.resetDirectory(paths.colmapSeedURL)
                            try self.resetDirectory(paths.colmapSparseURL)
                            try self.resetDirectory(sparseZero)
                            self.removeIfExists(da3CoverageManifest)

                            let da3ToolLog = ToolLogWriter(fileURL: paths.da3LogURL, toolName: "da3-mps")
                            da3ToolLog.beginSection(
                                title: "sfm",
                                metadata: [
                                    "device": da3Config.device,
                                    "mode": "seed_refine",
                                    "images": paths.framesSelectedURL.path,
                                    "processRes": "\(da3Config.processResolution)",
                                    "maxPoints": "\(da3Config.maxPoints)",
                                    "sharedCamera": da3Config.sharedCamera ? "1" : "0",
                                    "cameraType": da3Config.cameraType,
                                    "inputOrdering": da3Config.inputOrdering.rawValue,
                                    "windowSize": "\(da3Config.windowSize)",
                                    "windowOverlap": "\(da3Config.windowOverlap)",
                                    "model": da3Config.modelSubdirectory,
                                    "manifest": da3CoverageManifest.path,
                                    "tool": self.config.toolchain.da3.sfmTool.path,
                                    "modelsDir": self.config.toolchain.da3.models.path
                                ]
                            )
                            emit(.stageLog(stage: .sfmFeatures, line: "DA3 tool log: \(paths.da3LogURL.lastPathComponent)", isError: false))
                            emit(.stageLog(stage: .sfmFeatures, line: "DA3 coverage manifest: \(da3CoverageManifest.lastPathComponent)", isError: false))
                            let onDa3Log: @Sendable (String, Bool) -> Void = { line, isErr in
                                da3ToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                let sanitized = Self.sanitizeToolLogLine(line)
                                let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                                if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                                    emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: effectiveIsErr))
                                }
                            }

                            emit(.stageProgress(stage: .sfmFeatures, fraction: 0.0, message: "Starting DA3 single-batch seed (\(selectedFrames.count) images)…"))
                            try await self.tooling.da3Sfm.run(
                                toolchain: self.config.toolchain.da3,
                                images: paths.framesSelectedURL,
                                outSparse: seedZero,
                                config: da3Config,
                                onLog: onDa3Log
                            )
                            guard sparseModelFilesExist(at: seedZero) else {
                                throw PipelineError.outputMissing
                            }
                            _ = try readDa3CoverageManifest(required: true)
                            if !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                                fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                            }

                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 1.0,
                                message: "DA3 aligned pose seed ready",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageFinished(stage: .sfmFeatures))
                            markStageComplete(.sfmFeatures)
                            try stopIfRequested(after: .sfmFeatures)
                        } else if sparseModelFilesExist(at: seedZero) && !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                            fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                        }

                        guard let seedManifest = try readDa3CoverageManifest(
                            required: true
                        ) else {
                            throw PipelineError.outputMissing
                        }
                        let featureImageNames = selectedFrames.map(
                            \.lastPathComponent
                        )
                        let pairPlan = try ColmapPairEstimator.validatedDa3RefinementPairPlan(
                            manifest: seedManifest,
                            imageNames: featureImageNames,
                            resolvedPlan: resolvedRunPlan
                        )
                        let pairPlanBinding = PairGraphPlanBinding(
                            resolvedRunPlan
                        )
                        let restoredDa3PairEvidence: PairGraphEvidence? = try {
                            guard fm.fileExists(
                                atPath: paths.pairGraphEvidenceURL.path
                            ), fm.fileExists(
                                atPath: paths.workerExecutionURL.path
                            ) else {
                                return nil
                            }
                            do {
                                let evidence = try PairGraphEvidenceStore
                                    .loadVerifiedDa3Refinement(
                                        from: paths.pairGraphEvidenceURL,
                                        expectedImageNames: featureImageNames,
                                        expectedPlanBinding: pairPlanBinding,
                                        expectedPairPlan: pairPlan,
                                        databaseURL: paths.colmapDatabaseURL,
                                        projectPaths: paths
                                    )
                                let workerExecution = try GeometryWorkerExecutionArtifactStore
                                    .load(
                                        from: paths.workerExecutionURL,
                                        expectedBudget:
                                            resolvedRunPlan.geometryWorkerBudget,
                                        projectPaths: paths
                                    )
                                try PairGraphEvidenceStore
                                    .validateDa3WorkerExecution(
                                        evidence,
                                        expectedPlanBinding: pairPlanBinding,
                                        expectedPairPlan: pairPlan,
                                        workerExecution: workerExecution
                                    )
                                return evidence
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "Discarded incomplete DA3 matching evidence and restarted matching from FAISS.",
                                    isError: true
                                ))
                                return nil
                            }
                        }()
                        if let restoredDa3PairEvidence {
                            pendingMatchingResetMessage = nil
                            acceptedDa3PairGraphEvidence =
                                restoredDa3PairEvidence
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "Recovered verified DA3 image matches.",
                                isError: false
                            ))
                            try stopIfRequested(after: .sfmMatching)
                        } else if try shouldRunStage(.sfmMatching) {
                            currentStage = .sfmMatching
                            emit(.stageStarted(stage: .sfmMatching))
                            writeCheckpoint(
                                stage: .sfmMatching,
                                progress: 0,
                                message: "DA3 refinement matching started",
                                details: .sfmMatching(SfmMatchingCheckpoint(
                                    databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                                    expectedPairs: nil,
                                    processedPairs: 0
                                ))
                            )
                            let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                            colmapToolLog.beginSection(
                                title: "da3_refinement_matching",
                                metadata: [
                                    "database": paths.colmapDatabaseURL.path,
                                    "images": paths.framesSelectedURL.path,
                                    "tool": self.config.toolchain.colmap.path
                                ]
                            )
                            let cameraGroupingEvidence = try Self.colmapCameraGroupingEvidence(
                                imageNames: featureImageNames,
                                manifest: selectedFrameManifest
                            )
                            let cameraGroupingMode = Self.colmapCameraGroupingMode(
                                cameraGrouping: resolvedRunPlan.cameraGrouping,
                                evidence: cameraGroupingEvidence
                            )
                            let reusesFeatureEvidence = (try? ColmapFeatureEvidenceStore
                                .loadVerified(
                                    from: paths.colmapFeatureEvidenceURL,
                                    expectedImageNames: featureImageNames,
                                    expectedCameraEvidence: cameraGroupingEvidence,
                                    expectedCameraGroupingMode: cameraGroupingMode,
                                    expectedCameraInitializationReceipt:
                                        featureCameraInitialization,
                                    databaseURL: paths.colmapDatabaseURL,
                                    projectPaths: paths
                                )) != nil
                            if reusesFeatureEvidence {
                                emit(.stageProgress(
                                    stage: .sfmMatching,
                                    fraction: 0.40,
                                    message: "Resuming image matching…"
                                ))
                            } else {
                                try workerExecutionRecorder.invalidate(
                                    startingAt: .sfmFeatures
                                )
                                for url in [
                                    paths.colmapDatabaseURL,
                                    URL(fileURLWithPath:
                                        paths.colmapDatabaseURL.path + "-wal"),
                                    URL(fileURLWithPath:
                                        paths.colmapDatabaseURL.path + "-shm"),
                                    URL(fileURLWithPath:
                                        paths.colmapDatabaseURL.path + "-journal"),
                                    paths.colmapFeatureEvidenceURL,
                                ] {
                                    try self.removeItemIfPresent(url)
                                }
                                emit(.stageProgress(
                                    stage: .sfmMatching,
                                    fraction: 0.02,
                                    message: "Extracting local features…"
                                ))
                                try await self.tooling.colmap.runFeatureExtractor(
                                    colmapPath: self.config.toolchain.colmap,
                                    database: paths.colmapDatabaseURL,
                                    imagePath: paths.framesSelectedURL,
                                    maxImageSize: colmapMaxImageSize,
                                    cameraInitialization: featureCameraInitialization,
                                    options: da3ColmapExtractOptions,
                                    onLog: { line, isErr in
                                        colmapToolLog.append(
                                            stream: isErr ? "stderr" : "stdout",
                                            line: line
                                        )
                                    }
                                )
                                try ColmapDatabaseDurability.seal(
                                    at: paths.colmapDatabaseURL
                                )
                                try ColmapFeatureDatabaseIdentityVerifier.verify(
                                    databaseURL: paths.colmapDatabaseURL,
                                    expectedImageNames: featureImageNames
                                )
                                let cameraGroupingReceipt = try ColmapCameraGroupingStore
                                    .normalize(
                                        databaseURL: paths.colmapDatabaseURL,
                                        selectedImages: cameraGroupingEvidence,
                                        mode: cameraGroupingMode
                                    )
                                try ColmapDatabaseDurability.seal(
                                    at: paths.colmapDatabaseURL
                                )
                                try ColmapFeatureEvidenceStore.save(
                                    ColmapFeatureEvidence(
                                        selectedFramesDigest: try GeometryArtifactStore
                                            .selectedFramesDigest(
                                                orderedImageNames: featureImageNames,
                                                projectPaths: paths
                                            ),
                                        imageNames: featureImageNames,
                                        featureDatabaseDigest: try ColmapDatabaseDigester
                                            .digests(at: paths.colmapDatabaseURL).feature,
                                        cameraGroupingReceipt: cameraGroupingReceipt,
                                        cameraInitializationReceipt: featureCameraInitialization
                                    ),
                                    to: paths.colmapFeatureEvidenceURL,
                                    projectPaths: paths
                                )
                            }
                            self.logKeypointStats(database: paths.colmapDatabaseURL, stage: .sfmMatching, emit: emit)
                            try workerExecutionRecorder.invalidate(
                                startingAt: .sfmMatching
                            )
                            try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
                            try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
                            if pendingMatchingResetMessage != nil {
                                try resetMatchingIfNeeded()
                            } else {
                                try ColmapDatabaseMatchStore.clearMatchingResults(
                                    at: paths.colmapDatabaseURL
                                )
                            }
                            let matchListURL = paths.colmapSeedURL.appendingPathComponent("match_pairs.txt")
                            try pairPlan.serializedData.write(to: matchListURL, options: .atomic)
                            let persistedPairData = try Data(contentsOf: matchListURL)
                            guard pairPlan.validates(persistedPairData) else {
                                throw PipelineError.outputMissing
                            }
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "DA3 refinement pair plan: \(pairPlan.localPairCount) local + \(pairPlan.loopRevisitPairCount) loop, sha256 \(pairPlan.sha256).",
                                isError: false
                            ))
                            let matcherLog: @Sendable (String, Bool) -> Void = { line, isErr in
                                colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                            }
                            var effectiveDa3MatchOptions =
                                da3ColmapMatchOptions
                            effectiveDa3MatchOptions.descriptorMatcher = .faiss
                            let matchingExecution = try await self
                                .runDa3MatchesImporterWithOneShotExactRecovery(
                                database: paths.colmapDatabaseURL,
                                matchListPath: matchListURL,
                                pairPlan: pairPlan,
                                randomSeed: resolvedRunPlan.runSeed,
                                options: effectiveDa3MatchOptions,
                                onLog: matcherLog,
                                emit: emit,
                                onExactRecovery: { _ in
                                    didRetryWithExactMatcher = true
                                    colmapMatchOptions.descriptorMatcher = .exact
                                    recordMappingFallback("exact descriptor matching")
                                }
                            )
                            let da3PairEvidence = PairGraphEvidence(
                                selectedFramesDigest: try GeometryArtifactStore
                                    .selectedFramesDigest(
                                        orderedImageNames: selectedFrames.map(
                                            \.lastPathComponent
                                        ),
                                        projectPaths: paths
                                    ),
                                imageNames: selectedFrames.map(\.lastPathComponent),
                                pairingPolicy: resolvedRunPlan.pairingPolicy,
                                planBinding: PairGraphPlanBinding(resolvedRunPlan),
                                attempts: matchingExecution.attempts,
                                acceptedAttemptNumber:
                                    matchingExecution.attempts.count,
                                acceptedInspection:
                                    matchingExecution.acceptedInspection,
                                retrievalWasScheduled: false,
                                usedLocalVocabularyRetrieval: false,
                                matchingDurationSeconds:
                                    matchingExecution.matchingDurationSeconds,
                                fallbackReasons: mappingFallbackReasons
                            )
                            let workerExecution = try workerExecutionRecorder
                                .validatedArtifact()
                            try PairGraphEvidenceStore
                                .validateDa3WorkerExecution(
                                    da3PairEvidence,
                                    expectedPlanBinding: pairPlanBinding,
                                    expectedPairPlan: pairPlan,
                                    workerExecution: workerExecution
                                )
                            try PairGraphEvidenceStore.saveDa3Refinement(
                                da3PairEvidence,
                                expectedPlanBinding: pairPlanBinding,
                                expectedPairPlan: pairPlan,
                                to: paths.pairGraphEvidenceURL,
                                projectPaths: paths
                            )
                            let publishedEvidence = try PairGraphEvidenceStore
                                .loadVerifiedDa3Refinement(
                                    from: paths.pairGraphEvidenceURL,
                                    expectedImageNames: featureImageNames,
                                    expectedPlanBinding: pairPlanBinding,
                                    expectedPairPlan: pairPlan,
                                    databaseURL: paths.colmapDatabaseURL,
                                    projectPaths: paths
                                )
                            try PairGraphEvidenceStore
                                .validateDa3WorkerExecution(
                                    publishedEvidence,
                                    expectedPlanBinding: pairPlanBinding,
                                    expectedPairPlan: pairPlan,
                                    workerExecution: workerExecution
                                )
                            acceptedDa3PairGraphEvidence = publishedEvidence
                            let expectedPairs = pairPlan.pairs.count
                            let processedPairs = matchingExecution
                                .acceptedInspection.attemptedPairCount
                            writeCheckpoint(
                                stage: .sfmMatching,
                                progress: 1.0,
                                message: "DA3 refinement matching completed",
                                details: .sfmMatching(SfmMatchingCheckpoint(
                                    databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                                    expectedPairs: expectedPairs,
                                    processedPairs: processedPairs
                                ))
                            )
                            emit(.stageFinished(stage: .sfmMatching))
                            markStageComplete(.sfmMatching)
                            try persistGeometryRecovery()
                            try stopIfRequested(after: .sfmMatching)
                        } else {
                            throw PairGraphEvidenceStoreError.invalidEvidence
                        }

                        if try shouldRunStage(.sfmMapping) {
                            completedMappingThisAttempt = true
                            currentStage = .sfmMapping
                            emit(.stageStarted(stage: .sfmMapping))
                            guard sparseModelFilesExist(at: seedZero) else {
                                throw PipelineError.outputMissing
                            }
                            let refinementSeed = paths.colmapRefinementSeedModelURL
                            defer { self.removeIfExists(refinementSeed.deletingLastPathComponent()) }
                            if try self.prepareDa3RefinementSeed(
                                rawModelURL: seedZero,
                                outputModelURL: refinementSeed,
                                databaseURL: paths.colmapDatabaseURL,
                                checkCancellation: self.tooling.checkCancellation
                            ) {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Prepared the DA3 refinement seed for the COLMAP feature database.",
                                    isError: false
                                ))
                            }
                            writeCheckpoint(
                                stage: .sfmMapping,
                                progress: 0,
                                message: "DA3 refinement started"
                            )
                            let mappingAttemptOrdinal = try beginMappingAttempt()
                            try self.resetDirectory(paths.colmapSparseURL)
                            try self.resetDirectory(sparseZero)
                            let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                            colmapToolLog.beginSection(
                                title: "da3_refinement",
                                metadata: [
                                    "database": paths.colmapDatabaseURL.path,
                                    "images": paths.framesSelectedURL.path,
                                    "seed": refinementSeed.path,
                                    "output": sparseZero.path,
                                    "tool": self.config.toolchain.colmap.path
                                ]
                            )
                            emit(.stageLog(stage: .sfmMapping, line: "Running DA3 refinement: point_triangulator.", isError: false))
                            try self.tooling.checkCancellation()
                            try await self.tooling.colmap.runPointTriangulator(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                inputPath: refinementSeed,
                                outputPath: sparseZero,
                                environment: [:],
                                onLog: { line, isErr in
                                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                }
                            )

                            let baOutput = paths.colmapSparseURL.appendingPathComponent("0_ba", isDirectory: true)
                            self.removeIfExists(baOutput)
                            try fm.createDirectory(at: baOutput, withIntermediateDirectories: true)
                            emit(.stageLog(stage: .sfmMapping, line: "Running DA3 refinement: bundle_adjuster.", isError: false))
                            try await self.tooling.colmap.runBundleAdjuster(
                                colmapPath: self.config.toolchain.colmap,
                                inputPath: sparseZero,
                                outputPath: baOutput,
                                environment: [:],
                                bundleOptions: ColmapBundleAdjustmentOptions(
                                    maxNumIterations: resolvedRunPlan.refinementIterationLimit,
                                    refineExtraParams: !["PINHOLE", "SIMPLE_PINHOLE"].contains(
                                        da3Config.cameraType
                                    )
                                ),
                                onLog: { line, isErr in
                                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                }
                            )
                            guard sparseModelFilesExist(at: baOutput) else {
                                throw PipelineError.outputMissing
                            }
                            self.removeIfExists(sparseZero)
                            try fm.moveItem(at: baOutput, to: sparseZero)
                            let canonicalModelPublication = try prepareCanonicalTextCandidate(
                                at: sparseZero,
                                mappingAttemptOrdinal: mappingAttemptOrdinal
                            )
                            let conditioningAnalysis = try self.validatedConditionedGeometry(
                                modelDirectory: sparseZero,
                                selectedFrames: selectedFrames,
                                requireStrongObservationCoverage: true
                            )

                            let membership = try ColmapSparseModelMembershipReader(
                                databaseURL: paths.colmapDatabaseURL,
                                selectedImageNames: selectedFrames.map(\.lastPathComponent)
                            ).read(
                                modelDirectories: [sparseZero],
                                checkCancellation: self.tooling.checkCancellation
                            )

                            let score = try await analyzeDa3Model(
                                at: sparseZero,
                                toolLog: colmapToolLog
                            )
                            guard ReconstructionScorer.isAcceptable(
                                score,
                                capturePath: resolvedRunPlan.capturePath
                            ),
                                  score.registeredImages
                                    == membership.largestModelRegisteredViewCount,
                                  conditioningAnalysis.residuals.registeredViewCount
                                    == score.registeredImages,
                                  let residual = score.meanReprojectionError,
                                  residual.isFinite else {
                                throw PipelineError.lowQualityReconstruction(score, mapper: "da3-refined")
                            }
                            acceptedMappingArtifact = MappingArtifact(
                                modelCount: membership.modelCount,
                                largestModelRegisteredViewCount:
                                    membership.largestModelRegisteredViewCount,
                                secondLargestModelRegisteredViewCount:
                                    membership.secondLargestModelRegisteredViewCount,
                                unionRegisteredViewCount: membership.unionRegisteredViewCount,
                                attemptCount: mappingAttemptCount,
                                acceptedMappingAttemptOrdinal: mappingAttemptOrdinal,
                                acceptedRefinementKind: .seededBundleAdjustment,
                                acceptedRefinementInvocationCount: 1,
                                incrementalCadence: nil,
                                canonicalModelPublication: canonicalModelPublication,
                                fallbackReason: nil
                            )
                            acceptedMapper = "da3-refined"
                            acceptedConditioningAnalysis = conditioningAnalysis
                            emit(.stageLog(
                                stage: .sfmMapping,
                                line: "DA3 aligned seed accepted after triangulation and bounded bundle adjustment.",
                                isError: false
                            ))
                        }
                    } else {
            var resumingPersistedPolicyRecovery =
                restoredGeometryRecovery?.activeBackend == .colmap
                && restoredGeometryRecovery?.pendingPairRecoveryLevel != nil

            func restoreAcceptedPairEvidence(_ evidence: PairGraphEvidence) throws {
                guard evidence.planBinding == PairGraphPlanBinding(resolvedRunPlan),
                      let acceptedAttempt = evidence.attempts.last else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                let acceptedRecoveryLevel = PairRecoveryLevel(
                    acceptedAttempt.artifact.recoveryLevel
                )
                guard Self.permitsAcceptedComponentShape(
                    evidence.acceptedInspection.componentViewCounts,
                    pairingPolicy: resolvedRunPlan.pairingPolicy,
                    recoveryLevel: acceptedRecoveryLevel
                ) else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                let acceptedPlan = try evidence.restoredPairPlan()
                let mapperGraphContext = try evidence.mapperWorkerInvocationContext()
                if let recovery = restoredGeometryRecovery,
                   recovery.activeBackend == .colmap,
                   metadata.checkpoint?.stage == .sfmMapping {
                    try recovery.validatePairGraphBinding(
                        acceptedPairAttemptOrdinal:
                            mapperGraphContext.pairGraphAttemptOrdinal,
                        pairListDigest: mapperGraphContext.pairListDigest,
                        matchingDatabaseDigest:
                            mapperGraphContext.matchingDatabaseDigest
                    )
                }
                pairGraphAttempts = evidence.attempts
                retrievalWasScheduled = evidence.retrievalWasScheduled
                acceptedPairGraphEvidence = evidence
                activeMapperGraphContext = mapperGraphContext
                matchingDurationSeconds = evidence.matchingDurationSeconds
                pairRecoveryLevel = acceptedRecoveryLevel
                colmapMatchOptions.descriptorMatcher = acceptedAttempt.artifact.matcher
                didRetryWithExactMatcher = acceptedAttempt.artifact.matcher == .exact
                latestPreparedPairPlan = acceptedPlan
                if acceptedAttempt.artifact.matcher == .exact {
                    guard let reason = acceptedAttempt.artifact.exactRecoveryReason else {
                        throw PairGraphEvidenceStoreError.invalidEvidence
                    }
                    pairAttemptMode = .sameScheduleExact(acceptedPlan, reason)
                } else {
                    pairAttemptMode = .policy
                }
                for reason in evidence.fallbackReasons {
                    recordMappingFallback(reason)
                }
            }

            let selectedImageNames = selectedFrames.map(\.lastPathComponent)
            let selectedPairGroups = try Self.colmapPairGroups(
                imageNames: selectedImageNames,
                manifest: selectedFrameManifest
            )
            var selectedFramesDigestForRecovery: String?
            var resumingPersistedExactRecovery = false
            var recoveredAcceptedExactEvidence = false
            var restartingAfterInvalidRecoveryState = false
            var recoveredPolicyRecoverySidecar = false

            func selectedFramesDigestForExactRecovery() throws -> String {
                if let selectedFramesDigestForRecovery {
                    return selectedFramesDigestForRecovery
                }
                let digest = try GeometryArtifactStore.selectedFramesDigest(
                    orderedImageNames: selectedImageNames,
                    projectPaths: paths
                )
                selectedFramesDigestForRecovery = digest
                return digest
            }

            func persistedRecoveryMode(
                for mode: PairAttemptMode
            ) -> PairGraphRecoveryMode {
                mode.isPolicyRecovery ? .policy : .sameScheduleExact
            }

            func persistPairRecoveryIntent(
                mode: PairGraphRecoveryMode,
                exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil,
                activePlan: ColmapPairPlan,
                activeRetrieval: PairGraphRetrievalAttemptEvidence? = nil,
                phase: PairGraphRecoveryPhase = .matching
            ) throws {
                metadata.checkpoint = PipelineCheckpoint(
                    stage: .sfmMatching,
                    updatedAt: Date(),
                    progressFraction: 0,
                    message: "Image matching recovery pending",
                    inputReceiptDigest: runtimeInputReceiptDigest,
                    details: .sfmMatching(SfmMatchingCheckpoint(
                        databasePath: try paths.projectRelativePath(
                            for: paths.colmapDatabaseURL
                        ),
                        expectedPairs: phase == .matching
                            ? activePlan.pairs.count
                            : nil,
                        processedPairs: 0
                    ))
                )
                let state = PairGraphRecoveryState(
                    selectedFramesDigest: try selectedFramesDigestForExactRecovery(),
                    imageNames: selectedImageNames,
                    groups: selectedPairGroups,
                    pairingPolicy: resolvedRunPlan.pairingPolicy,
                    planBinding: PairGraphPlanBinding(resolvedRunPlan),
                    mode: mode,
                    exactRecoveryReason: exactRecoveryReason,
                    computeMode: colmapMatchOptions.useGPU ? .gpu : .cpu,
                    phase: phase,
                    activeRecoveryLevel: pairRecoveryLevel.artifactValue,
                    activePlan: activePlan,
                    activeRetrieval: activeRetrieval,
                    attempts: pairGraphAttempts,
                    retrievalWasScheduled: retrievalWasScheduled,
                    usedLocalVocabularyRetrieval: activeRetrieval != nil
                        || pairGraphAttempts.contains(where: \.retrievalWasExecuted),
                    matchingDurationSeconds: matchingDurationSeconds,
                    fallbackReasons: mappingFallbackReasons
                )
                try PairGraphRecoveryStore.save(
                    state,
                    to: paths.pairGraphRecoveryURL,
                    projectPaths: paths
                )
                try persistGeometryRecovery(
                    pendingPairRecoveryLevel: pairRecoveryLevel.artifactValue
                )
            }

            func persistAttemptRecoveryIntent(
                mode: PairAttemptMode,
                activePlan: ColmapPairPlan,
                activeRetrieval: PairGraphRetrievalAttemptEvidence? = nil
            ) throws {
                if mode.isPolicyRecovery, pairGraphAttempts.isEmpty {
                    return
                }
                let recoveryMode = persistedRecoveryMode(for: mode)
                try persistPairRecoveryIntent(
                    mode: recoveryMode,
                    exactRecoveryReason: mode.exactRecoveryReason,
                    activePlan: activePlan,
                    activeRetrieval: activeRetrieval
                )
            }

            func restorePendingPairRecovery(
                _ recovered: RestoredPairGraphRecovery
            ) throws {
                guard recovered.planBinding == PairGraphPlanBinding(resolvedRunPlan) else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
                if recovered.phase == .matching {
                    let groups = selectedPairGroups
                    let recoveryLevel = PairRecoveryLevel(recovered.recoveryLevel)
                    var expectedPlan = try Self.baseColmapPairPlan(
                        imageNames: selectedImageNames,
                        groups: groups,
                        resolvedPlan: resolvedRunPlan,
                        recoveryLevel: recoveryLevel
                    )
                    if let request = try Self.vocabularyRetrievalRequest(
                        imageNames: selectedImageNames,
                        groups: groups,
                        resolvedPlan: resolvedRunPlan,
                        recoveryLevel: recoveryLevel
                    ) {
                        guard let retrieval = recovered.activeRetrieval,
                              retrieval.engine == resolvedRunPlan.retrievalEngine,
                              retrieval.queryImageNames == request.queryImageNames,
                              retrieval.queryStride == resolvedRunPlan.retrievalQueryStride,
                              retrieval.candidateCount == request.candidateCount,
                              retrieval.returnedNeighborCount == request.returnedNeighborCount,
                              retrieval.minimumFrameSeparation
                                == request.minimumFrameSeparation else {
                            throw PairGraphRecoveryStoreError.invalidState
                        }
                        let lines = try Self.validatedVocabularyRetrievalEvidence(
                            retrieval,
                            request: request,
                            imageNames: selectedImageNames,
                            excluding: expectedPlan
                        )
                        expectedPlan = try expectedPlan.addingRetrievalPairLines(
                            lines,
                            pairingPolicy: resolvedRunPlan.pairingPolicy,
                            groups: groups,
                            requiresCrossClipRetrieval:
                                resolvedRunPlan.requiresCrossClipRetrieval
                        )
                    } else if recovered.activeRetrieval != nil {
                        throw PairGraphRecoveryStoreError.invalidState
                    }
                    guard expectedPlan == recovered.activePlan else {
                        throw PairGraphRecoveryStoreError.invalidState
                    }
                }
                if recovered.computeMode == .cpu {
                    colmapExtractOptions.useGPU = false
                    colmapMatchOptions.useGPU = false
                }
                pairGraphAttempts = recovered.attempts
                latestPreparedRetrievalEvidence = recovered.activeRetrieval
                retrievalWasScheduled = recovered.retrievalWasScheduled
                matchingDurationSeconds = recovered.matchingDurationSeconds
                pairRecoveryLevel = PairRecoveryLevel(recovered.recoveryLevel)
                if recovered.phase == .preparing {
                    colmapMatchOptions.descriptorMatcher = recovered.mode == .policy
                        ? resolvedRunPlan.normalDescriptorMatcher
                        : .exact
                    didRetryWithExactMatcher = recovered.mode != .policy
                    pairAttemptMode = .policy
                    latestPreparedPairPlan = nil
                    latestCompletedPairPlan = nil
                    resumingPersistedPolicyRecovery = recovered.mode == .policy
                    resumingPersistedExactRecovery = recovered.mode != .policy
                    recoveredPolicyRecoverySidecar = recovered.mode == .policy
                    for reason in recovered.fallbackReasons {
                        recordMappingFallback(reason)
                    }
                    return
                }
                switch recovered.mode {
                case .policy:
                    colmapMatchOptions.descriptorMatcher = resolvedRunPlan
                        .normalDescriptorMatcher
                    didRetryWithExactMatcher = false
                    pairAttemptMode = .restoredPolicy(recovered.activePlan)
                    latestPreparedPairPlan = recovered.activePlan
                    latestCompletedPairPlan = nil
                    resumingPersistedPolicyRecovery = true
                    recoveredPolicyRecoverySidecar = true
                case .sameScheduleExact:
                    guard let reason = recovered.exactRecoveryReason else {
                        throw PairGraphRecoveryStoreError.invalidState
                    }
                    colmapMatchOptions.descriptorMatcher = .exact
                    didRetryWithExactMatcher = true
                    latestPreparedPairPlan = recovered.activePlan
                    pairAttemptMode = .sameScheduleExact(
                        recovered.activePlan,
                        reason
                    )
                case .terminalExact:
                    throw PairGraphRecoveryStoreError.terminalExactRecovery
                }
                for reason in recovered.fallbackReasons {
                    recordMappingFallback(reason)
                }
            }

            func evidenceCompletesPendingRecovery(
                _ evidence: PairGraphEvidence,
                recovered: RestoredPairGraphRecovery
            ) -> Bool {
                guard recovered.phase == .matching,
                      evidence.attempts.count == recovered.attempts.count + 1,
                      evidence.planBinding == recovered.planBinding,
                      Array(evidence.attempts.dropLast()) == recovered.attempts,
                      evidence.retrievalWasScheduled
                        == recovered.retrievalWasScheduled,
                      evidence.fallbackReasons == recovered.fallbackReasons,
                      let accepted = evidence.attempts.last,
                      evidence.usedLocalVocabularyRetrieval
                        == (accepted.retrieval != nil),
                      accepted.artifact.recoveryLevel == recovered.recoveryLevel,
                      accepted.artifact.outcome == .completed,
                      accepted.retrieval == recovered.activeRetrieval,
                      accepted.scheduledPairs == recovered.activePlan.pairs else {
                    return false
                }
                switch recovered.mode {
                case .policy:
                    return accepted.artifact.matcher == .faiss
                case .sameScheduleExact:
                    return accepted.artifact.matcher == .exact
                        && accepted.artifact.exactRecoveryReason
                            == recovered.exactRecoveryReason
                case .terminalExact:
                    return false
                }
            }

            func evidenceSupersedesPendingExactRecovery(
                _ evidence: PairGraphEvidence,
                recovered: RestoredPairGraphRecovery
            ) -> Bool {
                guard recovered.mode == .sameScheduleExact,
                      recovered.phase == .matching,
                      evidence.planBinding == recovered.planBinding,
                      evidence.retrievalWasScheduled
                        == recovered.retrievalWasScheduled,
                      let accepted = evidence.attempts.last,
                      let pending = recovered.attempts.last,
                      accepted.artifact.matcher == .faiss,
                      accepted.artifact.exactRecoveryReason == nil,
                      accepted.artifact.outcome == .completed,
                      accepted.artifact.attemptNumber
                        == pending.artifact.attemptNumber,
                      accepted.artifact.recoveryLevel == recovered.recoveryLevel,
                      accepted.scheduledPairs == recovered.activePlan.pairs,
                      accepted.retrieval == recovered.activeRetrieval,
                      Array(evidence.attempts.dropLast())
                        == Array(recovered.attempts.dropLast()) else {
                    return false
                }
                return true
            }

            let recoveryFileManager = FileManager.default
            let recoveryFileExists = recoveryFileManager.fileExists(
                atPath: paths.pairGraphRecoveryURL.path
            ) || ((try? recoveryFileManager.destinationOfSymbolicLink(
                atPath: paths.pairGraphRecoveryURL.path
            )) != nil)
            if recoveryFileExists {
                resumingPersistedPolicyRecovery = false
                do {
                    let recoveryState = try PairGraphRecoveryStore.loadBound(
                        from: paths.pairGraphRecoveryURL,
                        expectedImageNames: selectedImageNames,
                        expectedGroups: selectedPairGroups,
                        projectPaths: paths
                    )
                    let recovered = try recoveryState.restoredRecovery()
                    if recovered.computeMode == .cpu {
                        colmapExtractOptions.useGPU = false
                        colmapMatchOptions.useGPU = false
                    }
                    let completedEvidence: PairGraphEvidence?
                    do {
                        completedEvidence = try PairGraphEvidenceStore.loadVerified(
                            from: paths.pairGraphEvidenceURL,
                            expectedImageNames: selectedImageNames,
                            databaseURL: paths.colmapDatabaseURL,
                            projectPaths: paths
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        completedEvidence = nil
                    }
                    if let completedEvidence {
                        try PairGraphEvidenceStore.validateSchedule(
                            completedEvidence,
                            resolvedPlan: resolvedRunPlan,
                            groups: selectedPairGroups
                        )
                        guard evidenceCompletesPendingRecovery(
                            completedEvidence,
                            recovered: recovered
                        ) || evidenceSupersedesPendingExactRecovery(
                            completedEvidence,
                            recovered: recovered
                        ) else {
                            throw PairGraphRecoveryStoreError
                                .conflictingCompletedEvidence
                        }
                        try PairGraphEvidenceStore.validateWorkerExecution(
                            completedEvidence,
                            workerExecution: try workerExecutionRecorder
                                .validatedArtifact()
                        )
                        try ColmapDatabaseDurability.seal(at: paths.colmapDatabaseURL)
                        try restoreAcceptedPairEvidence(completedEvidence)
                        try persistGeometryRecovery()
                        markStageComplete(.sfmMatching)
                        try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
                        recoveredAcceptedExactEvidence = true
                    } else {
                        try restorePendingPairRecovery(recovered)
                        acceptedPairGraphEvidence = nil
                        if recovered.mode != .policy {
                            resumingPersistedExactRecovery = true
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch PairGraphRecoveryStoreError.terminalExactRecovery {
                    throw PairGraphRecoveryStoreError.terminalExactRecovery
                } catch PairGraphRecoveryStoreError.conflictingCompletedEvidence {
                    throw PairGraphRecoveryStoreError.conflictingCompletedEvidence
                } catch {
                    try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
                    try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
                    try workerExecutionRecorder.invalidate(startingAt: .sfmMatching)
                    pairGraphAttempts.removeAll(keepingCapacity: true)
                    retrievalWasScheduled = false
                    matchingDurationSeconds = 0
                    pairRecoveryLevel = .normal
                    pairAttemptMode = .policy
                    latestPreparedPairPlan = nil
                    latestCompletedPairPlan = nil
                    acceptedPairGraphEvidence = nil
                    didRetryWithExactMatcher = false
                    colmapMatchOptions.descriptorMatcher = resolvedRunPlan.normalDescriptorMatcher
                    pendingMatchingResetMessage = "Discarded inconsistent image-matching recovery data before resuming reconstruction."
                    restartingAfterInvalidRecoveryState = true
                    try persistGeometryRecovery()
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "Discarded inconsistent pair-graph recovery state and restarted matching from preserved features.",
                        isError: true
                    ))
                }
            }

            if resumingPersistedPolicyRecovery && !recoveredPolicyRecoverySidecar {
                do {
                    let previousEvidence = try PairGraphEvidenceStore.loadVerified(
                        from: paths.pairGraphEvidenceURL,
                        expectedImageNames: selectedImageNames,
                        databaseURL: paths.colmapDatabaseURL,
                        projectPaths: paths
                    )
                    try PairGraphEvidenceStore.validateSchedule(
                        previousEvidence,
                        resolvedPlan: resolvedRunPlan,
                        groups: selectedPairGroups
                    )
                    try restoreAcceptedPairEvidence(previousEvidence)
                    guard let pendingLevel = restoredGeometryRecovery?
                        .pendingPairRecoveryLevel else {
                        throw PairGraphEvidenceStoreError.invalidEvidence
                    }
                    pairRecoveryLevel = PairRecoveryLevel(pendingLevel)
                    pairAttemptMode = .policy
                    colmapMatchOptions.descriptorMatcher = resolvedRunPlan
                        .normalDescriptorMatcher
                    didRetryWithExactMatcher = false
                    latestPreparedPairPlan = nil
                    latestCompletedPairPlan = nil
                    acceptedPairGraphEvidence = nil
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "Resuming the denser image-pair recovery graph.",
                        isError: false
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
                    try workerExecutionRecorder.invalidate(startingAt: .sfmMatching)
                    pairGraphAttempts.removeAll(keepingCapacity: true)
                    retrievalWasScheduled = false
                    matchingDurationSeconds = 0
                    pairRecoveryLevel = .normal
                    pairAttemptMode = .policy
                    latestPreparedPairPlan = nil
                    latestCompletedPairPlan = nil
                    acceptedPairGraphEvidence = nil
                    didRetryWithExactMatcher = false
                    colmapMatchOptions.descriptorMatcher = resolvedRunPlan
                        .normalDescriptorMatcher
                    pendingMatchingResetMessage =
                        "Discarded inconsistent image-pair recovery data before resuming reconstruction."
                    restartingAfterInvalidRecoveryState = true
                    resumingPersistedPolicyRecovery = false
                    try persistGeometryRecovery()
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "Discarded inconsistent image-pair recovery data and restarted matching from preserved features.",
                        isError: true
                    ))
                }
            }

            let runFeatures: (Bool) async throws -> Void = { force in
                guard try (force || shouldRunStage(.sfmFeatures)) else { return }
                currentStage = .sfmFeatures
                emit(.stageStarted(stage: .sfmFeatures))
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "SfM backend: COLMAP mapper.",
                    isError: false
                ))
                writeCheckpoint(
                    stage: .sfmFeatures,
                    progress: 0,
                    message: "COLMAP feature extraction started",
                    details: .sfmFeatures(SfmFeaturesCheckpoint(
                        databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                        imageCount: selectedFrames.count
                    ))
                )
                let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                colmapToolLog.beginSection(
                    title: "feature_extractor",
                    metadata: [
                        "database": paths.colmapDatabaseURL.path,
                        "images": paths.framesSelectedURL.path,
                        "tool": self.config.toolchain.colmap.path,
                        "useGPU": colmapExtractOptions.useGPU ? "1" : "0",
                        "featureExtractionWorkers": "\(colmapExtractOptions.extractThreads)",
                        "cameraInitializationRecipe": featureCameraInitialization.recipe.rawValue
                    ]
                )
                emit(.stageLog(stage: .sfmFeatures, line: "COLMAP tool log: \(paths.colmapLogURL.lastPathComponent)", isError: false))
                let featureProgress = ColmapFeatureProgressTracker()
                let onFeaturesLog: @Sendable (String, Bool) -> Void = { line, isErr in
                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                    let sanitized = Self.sanitizeToolLogLine(line)
                    let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                    if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                        emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: effectiveIsErr))
                    }
                    if let update = featureProgress.ingest(line) {
                        emit(.stageProgress(stage: .sfmFeatures, fraction: update.fraction, message: update.message))
                    }
                }
                try self.prepareForClassicalFeatureExtraction(paths: paths)
                pairGraphAttempts.removeAll(keepingCapacity: true)
                attemptedPairConfigurations.removeAll(keepingCapacity: true)
                acceptedPairGraphEvidence = nil
                matchingDurationSeconds = 0
                pairRecoveryLevel = .normal
                pairAttemptMode = .policy
                latestPreparedPairPlan = nil
                latestCompletedPairPlan = nil
                didRetryWithExactMatcher = false
                colmapMatchOptions.descriptorMatcher = resolvedRunPlan.normalDescriptorMatcher
                resumingPersistedExactRecovery = false
                recoveredAcceptedExactEvidence = false
                restartingAfterInvalidRecoveryState = false
                resumingPersistedPolicyRecovery = false
                try persistGeometryRecovery()
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: colmapExtractOptions.useGPU ? "Using GPU for COLMAP feature extraction." : "Using CPU for COLMAP feature extraction.",
                    isError: false
                ))
                try await self.tooling.colmap.runFeatureExtractor(
                    colmapPath: self.config.toolchain.colmap,
                    database: paths.colmapDatabaseURL,
                    imagePath: paths.framesSelectedURL,
                    maxImageSize: colmapMaxImageSize,
                    cameraInitialization: featureCameraInitialization,
                    options: colmapExtractOptions,
                    onLog: onFeaturesLog
                )
                let featureImageNames = selectedFrames.map(\.lastPathComponent)
                try ColmapDatabaseDurability.seal(at: paths.colmapDatabaseURL)
                try ColmapFeatureDatabaseIdentityVerifier.verify(
                    databaseURL: paths.colmapDatabaseURL,
                    expectedImageNames: featureImageNames
                )
                let cameraGroupingEvidence = try Self.colmapCameraGroupingEvidence(
                    imageNames: featureImageNames,
                    manifest: selectedFrameManifest
                )
                let cameraGroupingReceipt = try ColmapCameraGroupingStore.normalize(
                    databaseURL: paths.colmapDatabaseURL,
                    selectedImages: cameraGroupingEvidence,
                    mode: Self.colmapCameraGroupingMode(
                        cameraGrouping: resolvedRunPlan.cameraGrouping,
                        evidence: cameraGroupingEvidence
                    )
                )
                try ColmapDatabaseDurability.seal(at: paths.colmapDatabaseURL)
                let featureDatabaseDigest = try ColmapDatabaseDigester
                    .digests(at: paths.colmapDatabaseURL).feature
                try ColmapFeatureEvidenceStore.save(
                    ColmapFeatureEvidence(
                        selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                            orderedImageNames: featureImageNames,
                            projectPaths: paths
                        ),
                        imageNames: featureImageNames,
                        featureDatabaseDigest: featureDatabaseDigest,
                        cameraGroupingReceipt: cameraGroupingReceipt,
                        cameraInitializationReceipt: featureCameraInitialization
                    ),
                    to: paths.colmapFeatureEvidenceURL,
                    projectPaths: paths
                )
                self.logKeypointStats(database: paths.colmapDatabaseURL, emit: emit)
                writeCheckpoint(
                    stage: .sfmFeatures,
                    progress: 1.0,
                    message: "COLMAP feature extraction completed",
                    details: .sfmFeatures(SfmFeaturesCheckpoint(
                        databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                        imageCount: selectedFrames.count,
                        cameraGroupingReceipt: cameraGroupingReceipt,
                        cameraInitializationReceipt: featureCameraInitialization,
                        featureDatabaseDigest: featureDatabaseDigest
                    ))
                )
                emit(.stageFinished(stage: .sfmFeatures))
                markStageComplete(.sfmFeatures)
                try stopIfRequested(after: .sfmFeatures)
            }

            func loadPairGraphEvidenceIfNeeded() throws {
                guard acceptedPairGraphEvidence == nil else { return }
                let imageNames = selectedFrames.map(\.lastPathComponent)
                let evidence = try PairGraphEvidenceStore.loadVerified(
                    from: paths.pairGraphEvidenceURL,
                    expectedImageNames: imageNames,
                    databaseURL: paths.colmapDatabaseURL,
                    projectPaths: paths
                )
                try PairGraphEvidenceStore.validateSchedule(
                    evidence,
                    resolvedPlan: resolvedRunPlan,
                    groups: selectedPairGroups
                )
                try restoreAcceptedPairEvidence(evidence)
            }

            let runMatching: (Bool) async throws -> Void = { force in
                if recoveredAcceptedExactEvidence {
                    recoveredAcceptedExactEvidence = false
                    return
                }
                guard try (force
                    || resumingPersistedExactRecovery
                    || resumingPersistedPolicyRecovery
                    || restartingAfterInvalidRecoveryState
                    || shouldRunStage(.sfmMatching)) else {
                    try loadPairGraphEvidenceIfNeeded()
                    return
                }
                resumingPersistedExactRecovery = false
                resumingPersistedPolicyRecovery = false
                restartingAfterInvalidRecoveryState = false
                currentStage = .sfmMatching
                emit(.stageStarted(stage: .sfmMatching))
                writeCheckpoint(
                    stage: .sfmMatching,
                    progress: 0,
                    message: "COLMAP matching started",
                    details: .sfmMatching(SfmMatchingCheckpoint(
                        databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                        expectedPairs: nil,
                        processedPairs: 0
                    ))
                )
                emit(.stageLog(
                    stage: .sfmMatching,
                    line: colmapMatchOptions.useGPU
                        ? "Using GPU for image matching."
                        : "Using CPU for image matching.",
                    isError: false
                ))
                let colmapToolLog = ToolLogWriter(
                    fileURL: paths.colmapLogURL,
                    toolName: "colmap"
                )
                colmapToolLog.beginSection(
                    title: "matching",
                    metadata: [
                        "database": paths.colmapDatabaseURL.path,
                        "tool": self.config.toolchain.colmap.path,
                        "useGPU": colmapMatchOptions.useGPU ? "1" : "0",
                        "coupledMatchWorkers": "\(colmapMatchOptions.matchThreads)",
                        "vocabularyRetrievalWorkers": "\(vocabularyRetrievalWorkers)",
                        "recovery": "\(pairRecoveryLevel.rawValue)",
                        "matcher": colmapMatchOptions.descriptorMatcher.rawValue,
                    ]
                )
                emit(.stageLog(
                    stage: .sfmMatching,
                    line: "Tool log: \(paths.colmapLogURL.lastPathComponent)",
                    isError: false
                ))

                let imageNames = selectedFrames.map(\.lastPathComponent)
                let groups = selectedPairGroups
                let attemptNumber = pairGraphAttempts.count + 1
                let attemptClock = ContinuousClock()
                let attemptStart = attemptClock.now
                latestPreparedPairPlan = nil
                latestCompletedPairPlan = nil
                let attemptMode = pairAttemptMode
                var retrievalEvidence: PairGraphRetrievalAttemptEvidence?
                var retrievalWasExecuted = false
                var pairPlan = try attemptMode.planOverride
                    ?? Self.baseColmapPairPlan(
                        imageNames: imageNames,
                        groups: groups,
                        resolvedPlan: resolvedRunPlan,
                        recoveryLevel: pairRecoveryLevel
                    )
                if attemptMode.planOverride == nil,
                   let request = try Self.vocabularyRetrievalRequest(
                    imageNames: imageNames,
                    groups: groups,
                    resolvedPlan: resolvedRunPlan,
                    recoveryLevel: pairRecoveryLevel
                ) {
                    let queryListURL = try self.writeVocabularyQueryList(
                        request.queryImageNames,
                        recoveryLevel: pairRecoveryLevel.artifactValue,
                        paths: paths
                    )
                    let imageGroupListURL: URL?
                    if let imageGroupContract = request.imageGroupContract {
                        imageGroupListURL = try self.writeVocabularyImageGroupList(
                            imageGroupContract,
                            recoveryLevel: pairRecoveryLevel.artifactValue,
                            paths: paths
                        )
                    } else {
                        imageGroupListURL = nil
                    }
                    let retrievalRecoveryLevel = pairRecoveryLevel
                        .artifactValue.rawValue
                    let outputURL = paths.colmapSeedURL.appendingPathComponent(
                        "retrieval_pairs_\(retrievalRecoveryLevel).txt"
                    )
                    let excludedPairListURL: URL?
                    if pairPlan.pairs.isEmpty {
                        excludedPairListURL = nil
                    } else {
                        excludedPairListURL = try self.writeColmapPairList(
                            pairPlan.pairLines,
                            fileName: "retrieval_exclusions_\(retrievalRecoveryLevel).txt",
                            paths: paths
                        )
                    }
                    self.removeIfExists(outputURL)
                    emit(.stageProgress(
                        stage: .sfmMatching,
                        fraction: 0,
                        message: "Finding revisited views"
                    ))
                    retrievalWasScheduled = true
                    let recoveryPlan: ColmapPairPlan
                    if let previousAttempt = pairGraphAttempts.last {
                        recoveryPlan = try ColmapPairPlan.persisted(
                            imageNames: imageNames,
                            scheduledPairs: previousAttempt.scheduledPairs
                        )
                    } else {
                        recoveryPlan = pairPlan
                    }
                    try persistPairRecoveryIntent(
                        mode: persistedRecoveryMode(for: attemptMode),
                        activePlan: recoveryPlan,
                        phase: .preparing
                    )
                    let retrievalRequestDigest = PairGraphEvidenceStore
                        .retrievalRequestDigest(
                            engine: resolvedRunPlan.retrievalEngine,
                            queryImageNames: request.queryImageNames,
                            queryStride: resolvedRunPlan.retrievalQueryStride,
                            candidateCount: request.candidateCount,
                            returnedNeighborCount: request.returnedNeighborCount,
                            minimumFrameSeparation: request.minimumFrameSeparation,
                            candidatePolicy: request.imageGroupContract?.policy,
                            imageGroupListDigest: request.imageGroupContract?.digest
                        )
                    try await self.tooling.colmap.runLocalVocabularyRetriever(
                        colmapPath: self.config.toolchain.colmap,
                        database: paths.colmapDatabaseURL,
                        outputPairListPath: outputURL,
                        queryImageListPath: queryListURL,
                        excludedPairListPath: excludedPairListURL,
                        imageGroupListPath: imageGroupListURL,
                        imageGroupListDigest: request.imageGroupContract?.digest,
                        options: try ColmapVocabularyRetrievalOptions(
                            candidateCount: request.candidateCount,
                            returnedNeighborCount: request.returnedNeighborCount,
                            minimumFrameSeparation: request.minimumFrameSeparation,
                            queryStride: resolvedRunPlan.retrievalQueryStride,
                            threadCount: vocabularyRetrievalWorkers,
                            memoryBudgetBytes: resolvedRunPlan.geometryWorkerBudget
                                .retrievalMemoryBudgetBytes
                        ),
                        pairContext: ColmapPairWorkerInvocationContext(
                            attemptOrdinal: attemptNumber,
                            descriptorMatcher: colmapMatchOptions.descriptorMatcher,
                            retrievalRequestDigest: retrievalRequestDigest,
                            retrievalOutputURL: outputURL
                        ),
                        environment: self.colmapWorkerEnvironment(
                            workerCount: vocabularyRetrievalWorkers
                        ),
                        onLog: { line, isErr in
                            colmapToolLog.append(
                                stream: isErr ? "stderr" : "stdout",
                                line: line
                            )
                        }
                    )
                    retrievalWasExecuted = true
                    let validatedRetrieval: PairGraphRetrievalAttemptEvidence
                    do {
                        validatedRetrieval = try Self.validatedVocabularyRetrievalContract(
                            self.readGeneratedPairLines(from: outputURL),
                            engine: resolvedRunPlan.retrievalEngine,
                            queryStride: resolvedRunPlan.retrievalQueryStride,
                            request: request,
                            imageNames: imageNames,
                            excluding: pairPlan
                        )
                    } catch {
                        latestPreparedPairPlan = pairPlan
                        try workerExecutionRecorder.discardPairPreparationWithoutMatcher(
                            attemptOrdinal: attemptNumber
                        )
                        throw error
                    }
                    let mergedPlan: ColmapPairPlan
                    do {
                        mergedPlan = try pairPlan.addingRetrievalPairLines(
                            validatedRetrieval.directedPairLines,
                            pairingPolicy: resolvedRunPlan.pairingPolicy,
                            groups: groups,
                            requiresCrossClipRetrieval:
                                resolvedRunPlan.requiresCrossClipRetrieval
                        )
                    } catch {
                        latestPreparedPairPlan = pairPlan
                        try workerExecutionRecorder.discardPairPreparationWithoutMatcher(
                            attemptOrdinal: attemptNumber
                        )
                        throw error
                    }
                    guard !mergedPlan.pairs.isEmpty, mergedPlan.isConnected else {
                        latestPreparedPairPlan = mergedPlan
                        try workerExecutionRecorder.rejectCompletedVocabularyRetrieval(
                            pairAttemptOrdinal: attemptNumber,
                            planBinding: PairGraphPlanBinding(resolvedRunPlan),
                            recoveryLevel: pairRecoveryLevel.artifactValue,
                            imageNames: imageNames,
                            groups: groups,
                            retrieval: validatedRetrieval,
                            durationSeconds: Self.durationInSeconds(
                                attemptClock.now - attemptStart
                            )
                        )
                        throw DisconnectedVocabularyRetrievalEvidence(
                            evidence: validatedRetrieval
                        )
                    }
                    pairPlan = mergedPlan
                    retrievalEvidence = validatedRetrieval
                } else if attemptMode.planOverride != nil {
                    retrievalEvidence = latestPreparedRetrievalEvidence
                        ?? pairGraphAttempts.last?.retrieval
                    retrievalWasExecuted = workerExecutionRecorder
                        .hasSuccessfulVocabularyRetrieval(
                            attemptOrdinal: attemptNumber
                        )
                }
                latestPreparedPairPlan = pairPlan
                latestPreparedRetrievalEvidence = retrievalEvidence
                guard !pairPlan.pairs.isEmpty else {
                    try workerExecutionRecorder.discardPairPreparationWithoutMatcher(
                        attemptOrdinal: attemptNumber
                    )
                    throw ColmapPairPlanningError.disconnectedPairSchedule
                }
                guard pairPlan.isConnected else {
                    try workerExecutionRecorder.discardPairPreparationWithoutMatcher(
                        attemptOrdinal: attemptNumber
                    )
                    throw ColmapPairPlanningError.disconnectedPairSchedule
                }
                guard colmapMatchOptions.descriptorMatcher != .exact
                        || DescriptorMatcherRecoveryPolicy.permitsExactRecovery(
                            scheduledPairCount: pairPlan.pairs.count
                        ) else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
                let attemptConfiguration = [
                    colmapMatchOptions.descriptorMatcher.rawValue,
                    colmapMatchOptions.useGPU ? "gpu" : "cpu",
                    pairPlan.sha256,
                    retrievalEvidence == nil
                        ? "without-vocabulary-receipt"
                        : "with-vocabulary-receipt",
                ].joined(separator: ":")
                guard attemptedPairConfigurations.insert(attemptConfiguration).inserted else {
                    try workerExecutionRecorder.discardPairPreparationWithoutMatcher(
                        attemptOrdinal: attemptNumber
                    )
                    throw ColmapPairPlanningError.repeatedAttempt
                }
                let pairListURL = try self.writeColmapPairPlan(
                    pairPlan,
                    attemptNumber: attemptNumber,
                    paths: paths
                )
                let existingMatcherInvocations = workerExecutionRecorder
                    .matchingInvocations(attemptOrdinal: attemptNumber)
                var reuseCompletedExactMatcher = false
                if colmapMatchOptions.descriptorMatcher == .exact {
                    guard let exactReason = attemptMode.exactRecoveryReason,
                          existingMatcherInvocations.count <= 1 else {
                        throw PairGraphRecoveryStoreError
                            .conflictingCompletedEvidence
                    }
                    if let existing = existingMatcherInvocations.first {
                        let binding = existing.pairExecution
                        guard existing.command == .matchesImporter,
                              binding?.descriptorMatcher == .exact,
                              binding?.attemptOrdinal == attemptNumber,
                              binding?.scheduledPairCount == pairPlan.pairs.count,
                              binding?.pairListDigest == pairPlan.sha256,
                              binding?.exactRecoveryReason == exactReason,
                              binding?.retrievalRequestDigest
                                == retrievalEvidence.map(
                                    PairGraphEvidenceStore.retrievalRequestDigest
                                ),
                              binding?.retrievalOutputDigest
                                == retrievalEvidence.map(
                                    PairGraphEvidenceStore.retrievalOutputDigest
                                ) else {
                            throw PairGraphRecoveryStoreError
                                .conflictingCompletedEvidence
                        }
                        if existing.succeeded {
                            reuseCompletedExactMatcher = true
                        } else {
                            let partialInspection = try? ColmapPairGraphInspector(
                                databaseURL: paths.colmapDatabaseURL
                            ).inspect(
                                schedule: ColmapPairSchedule(
                                    imageNames: imageNames,
                                    pairs: pairPlan.pairs
                                ),
                                completion: .failed
                            )
                            pairGraphAttempts.append(PairGraphAttemptEvidence(
                                artifact: PairMatchingAttemptArtifact(
                                    attemptNumber: attemptNumber,
                                    matcher: .exact,
                                    recoveryLevel: pairRecoveryLevel.artifactValue,
                                    outcome: .failed,
                                    exactRecoveryReason: exactReason,
                                    scheduledPairCount: pairPlan.pairs.count,
                                    attemptedPairCount:
                                        partialInspection?.attemptedPairCount ?? 0,
                                    rawMatchedPairCount:
                                        partialInspection?.rawMatchedPairCount ?? 0,
                                    spatiallyVerifiedPairCount:
                                        partialInspection?
                                            .spatiallyVerifiedPairCount ?? 0,
                                    durationSeconds: 0
                                ),
                                scheduledPairs: pairPlan.pairs,
                                retrieval: retrievalEvidence,
                                retrievalWasExecuted: false
                            ))
                            try persistPairRecoveryIntent(
                                mode: .terminalExact,
                                exactRecoveryReason: exactReason,
                                activePlan: pairPlan,
                                activeRetrieval: retrievalEvidence
                            )
                            throw PairGraphRecoveryStoreError.terminalExactRecovery
                        }
                    }
                } else {
                    try workerExecutionRecorder.discardUnacceptedMatcherInvocation(
                        attemptOrdinal: attemptNumber
                    )
                }
                if attemptMode.isPolicyRecovery,
                   colmapMatchOptions.descriptorMatcher == .faiss,
                   !pairGraphAttempts.isEmpty {
                    try persistPairRecoveryIntent(
                        mode: .policy,
                        activePlan: pairPlan,
                        activeRetrieval: retrievalEvidence
                    )
                } else {
                    try persistAttemptRecoveryIntent(
                        mode: attemptMode,
                        activePlan: pairPlan,
                        activeRetrieval: retrievalEvidence
                    )
                }
                try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
                if !reuseCompletedExactMatcher {
                    if pendingMatchingResetMessage == nil {
                        try ColmapDatabaseMatchStore.clearMatchingResults(
                            at: paths.colmapDatabaseURL
                        )
                    } else {
                        try resetMatchingIfNeeded()
                    }
                }
                emit(.stageLog(
                    stage: .sfmMatching,
                    line: "Pair graph: \(pairPlan.localPairCount) local, \(pairPlan.retrievalPairCount) retrieval, \(pairPlan.loopRevisitPairCount) revisit (\(pairPlan.pairs.count) total).",
                    isError: false
                ))

                let inspection: ColmapPairGraphInspection
                do {
                    if !reuseCompletedExactMatcher {
                        try await self.runColmapMatcherAttempt(
                            stage: .sfmMatching,
                            paths: paths,
                            colmapToolLog: colmapToolLog,
                            expectedPairs: pairPlan.pairs.count,
                            progressStart: 0,
                            progressSpan: 1,
                            blockMessageFallback: "Matching views",
                            invokeMatcher: { onLog in
                                try await self.tooling.colmap.runMatchesImporter(
                                    colmapPath: self.config.toolchain.colmap,
                                    database: paths.colmapDatabaseURL,
                                    matchListPath: pairListURL,
                                    matchType: "pairs",
                                    randomSeed: resolvedRunPlan.runSeed,
                                    options: colmapMatchOptions,
                                    pairContext: ColmapPairWorkerInvocationContext(
                                        attemptOrdinal: attemptNumber,
                                        descriptorMatcher:
                                            colmapMatchOptions.descriptorMatcher,
                                        scheduledPairCount: pairPlan.pairs.count,
                                        pairListDigest: pairPlan.sha256,
                                        exactRecoveryReason:
                                            attemptMode.exactRecoveryReason,
                                        retrievalRequestDigest: retrievalEvidence.map(
                                            PairGraphEvidenceStore.retrievalRequestDigest
                                        ),
                                        retrievalOutputDigest: retrievalEvidence.map(
                                            PairGraphEvidenceStore.retrievalOutputDigest
                                        )
                                    ),
                                    onLog: onLog
                                )
                            },
                            emit: emit
                        )
                    }
                    inspection = try ColmapPairGraphInspector(
                        databaseURL: paths.colmapDatabaseURL
                    ).inspect(
                        schedule: ColmapPairSchedule(
                            imageNames: imageNames,
                            pairs: pairPlan.pairs
                        ),
                        completion: .succeeded
                    )
                } catch let matcherError {
                    if matcherError is CancellationError || Task.isCancelled {
                        let completedExact = colmapMatchOptions.descriptorMatcher
                                == .exact
                            && workerExecutionRecorder.matchingInvocations(
                                attemptOrdinal: attemptNumber
                            ).contains(where: \.succeeded)
                        if !completedExact {
                            try workerExecutionRecorder
                                .discardUnacceptedMatcherInvocation(
                                    attemptOrdinal: attemptNumber
                                )
                        }
                        throw CancellationError()
                    }
                    let duration = Self.durationInSeconds(attemptClock.now - attemptStart)
                    let partialInspection = try? ColmapPairGraphInspector(
                        databaseURL: paths.colmapDatabaseURL
                    ).inspect(
                        schedule: ColmapPairSchedule(
                            imageNames: imageNames,
                            pairs: pairPlan.pairs
                        ),
                        completion: .failed
                    )
                    pairGraphAttempts.append(PairGraphAttemptEvidence(
                        artifact: PairMatchingAttemptArtifact(
                            attemptNumber: attemptNumber,
                            matcher: colmapMatchOptions.descriptorMatcher,
                            recoveryLevel: pairRecoveryLevel.artifactValue,
                            outcome: .failed,
                            exactRecoveryReason: attemptMode.exactRecoveryReason,
                            scheduledPairCount: pairPlan.pairs.count,
                            attemptedPairCount: partialInspection?.attemptedPairCount ?? 0,
                            rawMatchedPairCount: partialInspection?.rawMatchedPairCount ?? 0,
                            spatiallyVerifiedPairCount: partialInspection?.spatiallyVerifiedPairCount ?? 0,
                            durationSeconds: duration
                        ),
                        scheduledPairs: pairPlan.pairs,
                        retrieval: retrievalEvidence,
                        retrievalWasExecuted: retrievalWasExecuted
                    ))
                    matchingDurationSeconds += duration
                    if colmapMatchOptions.descriptorMatcher == .exact,
                       let exactReason = attemptMode.exactRecoveryReason {
                        try persistPairRecoveryIntent(
                            mode: .terminalExact,
                            exactRecoveryReason: exactReason,
                            activePlan: pairPlan,
                            activeRetrieval: retrievalEvidence
                        )
                    } else if attemptMode.isPolicyRecovery,
                              colmapMatchOptions.descriptorMatcher == .faiss {
                        try persistPairRecoveryIntent(
                            mode: .policy,
                            activePlan: pairPlan,
                            activeRetrieval: retrievalEvidence
                        )
                    } else {
                        try persistAttemptRecoveryIntent(
                            mode: attemptMode,
                            activePlan: pairPlan,
                            activeRetrieval: retrievalEvidence
                        )
                    }
                    throw matcherError
                }

                let allowsMinorVerifiedComponents = Self.allowsMinorVerifiedComponents(
                    pairingPolicy: resolvedRunPlan.pairingPolicy,
                    recoveryLevel: pairRecoveryLevel
                )
                let graphWasAccepted = inspection.hasAcceptableDominantVerifiedComponent(
                    allowMinorVerifiedComponents: allowsMinorVerifiedComponents
                )
                let duration = Self.durationInSeconds(attemptClock.now - attemptStart)
                let attemptArtifact = PairMatchingAttemptArtifact(
                    attemptNumber: attemptNumber,
                    matcher: colmapMatchOptions.descriptorMatcher,
                    recoveryLevel: pairRecoveryLevel.artifactValue,
                    outcome: graphWasAccepted ? .completed : .rejected,
                    exactRecoveryReason: attemptMode.exactRecoveryReason,
                    scheduledPairCount: inspection.scheduledPairCount,
                    attemptedPairCount: inspection.attemptedPairCount,
                    rawMatchedPairCount: inspection.rawMatchedPairCount,
                    spatiallyVerifiedPairCount: inspection.spatiallyVerifiedPairCount,
                    durationSeconds: duration
                )
                pairGraphAttempts.append(PairGraphAttemptEvidence(
                    artifact: attemptArtifact,
                    scheduledPairs: pairPlan.pairs,
                    retrieval: retrievalEvidence,
                    retrievalWasExecuted: retrievalWasExecuted
                ))
                matchingDurationSeconds += duration
                latestCompletedPairPlan = pairPlan
                latestRejectedCaptureConnectionFailure = graphWasAccepted
                    ? nil
                    : try CaptureConnectionFailure(
                        pairingPolicy: resolvedRunPlan.pairingPolicy,
                        selectedViewCount: imageNames.count,
                        attempt: attemptArtifact,
                        connectedComponentCount: inspection.connectedComponentCount,
                        isolatedViewCount: inspection.isolatedViewCount,
                        descriptorlessViewCount: inspection.descriptorlessViewCount,
                        componentViewCounts: inspection.verifiedGraph.components.map(\.count),
                        degreeP10: inspection.degreeP10,
                        degreeMedian: inspection.degreeMedian,
                        degreeP90: inspection.degreeP90
                    )
                guard graphWasAccepted else {
                    if colmapMatchOptions.descriptorMatcher == .exact,
                       let exactReason = attemptMode.exactRecoveryReason {
                        try persistPairRecoveryIntent(
                            mode: .terminalExact,
                            exactRecoveryReason: exactReason,
                            activePlan: pairPlan,
                            activeRetrieval: retrievalEvidence
                        )
                    } else if attemptMode.isPolicyRecovery,
                              colmapMatchOptions.descriptorMatcher == .faiss {
                        try persistPairRecoveryIntent(
                            mode: .policy,
                            activePlan: pairPlan,
                            activeRetrieval: retrievalEvidence
                        )
                    } else {
                        try persistAttemptRecoveryIntent(
                            mode: attemptMode,
                            activePlan: pairPlan,
                            activeRetrieval: retrievalEvidence
                        )
                    }
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "Pair graph remained disconnected (\(inspection.connectedComponentCount) components, \(inspection.isolatedViewCount) isolated views).",
                        isError: true
                    ))
                    throw ColmapPairPlanningError.disconnectedVerifiedGraph
                }
                let unmatchedViewCount = inspection.isolatedViewCount
                    - inspection.descriptorlessViewCount
                let componentViewCounts = inspection.verifiedGraph.components
                    .map(\.count)
                    .sorted(by: >)
                let dominantViewCount = componentViewCounts.first ?? 0
                let minorVerifiedViewCount = imageNames.count
                    - dominantViewCount
                    - inspection.isolatedViewCount
                if unmatchedViewCount > 0 {
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "\(unmatchedViewCount) view\(unmatchedViewCount == 1 ? "" : "s") had no verified overlap and may stay unregistered.",
                        isError: false
                    ))
                }
                if inspection.descriptorlessViewCount > 0 {
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "\(inspection.descriptorlessViewCount) view\(inspection.descriptorlessViewCount == 1 ? "" : "s") had no usable descriptors and may stay unregistered.",
                        isError: false
                    ))
                }
                if minorVerifiedViewCount > 0 {
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "\(minorVerifiedViewCount) view\(minorVerifiedViewCount == 1 ? "" : "s") matched only within small disconnected fragments and may stay unregistered.",
                        isError: false
                    ))
                }

                let evidence = PairGraphEvidence(
                    selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                        orderedImageNames: imageNames,
                        projectPaths: paths
                    ),
                    imageNames: imageNames,
                    pairingPolicy: resolvedRunPlan.pairingPolicy,
                    planBinding: PairGraphPlanBinding(resolvedRunPlan),
                    attempts: pairGraphAttempts,
                    acceptedAttemptNumber: attemptNumber,
                    acceptedInspection: inspection,
                    retrievalWasScheduled: retrievalWasScheduled,
                    usedLocalVocabularyRetrieval:
                        pairGraphAttempts.last?.retrieval != nil,
                    matchingDurationSeconds: matchingDurationSeconds,
                    fallbackReasons: mappingFallbackReasons
                )
                try ColmapDatabaseDurability.seal(at: paths.colmapDatabaseURL)
                try PairGraphEvidenceStore.save(
                    evidence,
                    to: paths.pairGraphEvidenceURL,
                    projectPaths: paths
                )
                acceptedPairGraphEvidence = evidence
                activeMapperGraphContext = try evidence.mapperWorkerInvocationContext()
                try persistGeometryRecovery()
                writeCheckpoint(
                    stage: .sfmMatching,
                    progress: 1,
                    message: "Image matching completed",
                    details: .sfmMatching(SfmMatchingCheckpoint(
                        databasePath: try paths.projectRelativePath(
                            for: paths.colmapDatabaseURL
                        ),
                        expectedPairs: inspection.scheduledPairCount,
                        processedPairs: inspection.attemptedPairCount
                    ))
                )
                emit(.stageFinished(stage: .sfmMatching))
                markStageComplete(.sfmMatching)
                try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
                try stopIfRequested(after: .sfmMatching)
            }

            let retryWithCpuIfNeeded: (Error) throws -> Bool = { error in
                guard !didRetryWithCpu else { return false }
                guard colmapMatchOptions.descriptorMatcher == .faiss else {
                    return false
                }
                guard colmapExtractOptions.useGPU || colmapMatchOptions.useGPU else { return false }
                guard let colmapError = error as? ColmapRunnerError else { return false }
                guard self.colmapErrorIndicatesGpuFailure(colmapError) else { return false }
                didRetryWithCpu = true
                colmapExtractOptions.useGPU = false
                colmapMatchOptions.useGPU = false
                recordMappingFallback("CPU recovery after GPU failure")
                if let activePlan = latestPreparedPairPlan,
                   colmapMatchOptions.descriptorMatcher == .exact {
                    try persistAttemptRecoveryIntent(
                        mode: pairAttemptMode,
                        activePlan: activePlan,
                        activeRetrieval: latestPreparedRetrievalEvidence
                    )
                } else if let activePlan = latestPreparedPairPlan,
                          !pairGraphAttempts.isEmpty {
                    try persistPairRecoveryIntent(
                        mode: .policy,
                        activePlan: activePlan,
                        activeRetrieval: latestPreparedRetrievalEvidence
                    )
                } else {
                    try persistGeometryRecovery(
                        pendingPairRecoveryLevel: pairRecoveryLevel.artifactValue
                    )
                }
                emit(.stageLog(stage: currentStage, line: "COLMAP GPU failed or unsupported; retrying on CPU.", isError: true))
                return true
            }

            let advancePairRecovery: (String) throws -> Bool = { reason in
                guard let next = Self.nextPairRecoveryLevel(
                    after: pairRecoveryLevel,
                    imageCount: selectedFrames.count,
                    pairingPolicy: resolvedRunPlan.pairingPolicy
                ), colmapMatchOptions.descriptorMatcher == .faiss else {
                    return false
                }
                guard let recoverySourcePlan = latestCompletedPairPlan
                        ?? latestPreparedPairPlan else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                pairRecoveryLevel = next
                pairAttemptMode = .policy
                latestPreparedPairPlan = nil
                latestPreparedRetrievalEvidence = nil
                latestCompletedPairPlan = nil
                acceptedPairGraphEvidence = nil
                recordMappingFallback(reason)
                if next == .maximum, selectedFrames.count <= 250 {
                    recordMappingFallback("exhaustive pair graph")
                }
                try persistPairRecoveryIntent(
                    mode: .policy,
                    activePlan: recoverySourcePlan,
                    phase: .preparing
                )
                emit(.stageLog(
                    stage: currentStage,
                    line: "\(reason). Retrying with a denser pair graph.",
                    isError: true
                ))
                return true
            }

            var forceSfMRun = false
            var forceMatchingRun = false
            sfmAttemptLoop: while true {
                while true {
                    do {
                        if !forceMatchingRun {
                            try await runFeatures(forceSfMRun)
                        }
                        try await runMatching(forceSfMRun || forceMatchingRun)
                        forceMatchingRun = false
                        forceSfMRun = false
                        if didRetryWithCpu {
                            emit(.stageLog(stage: .sfmMatching, line: "Retry on CPU succeeded.", isError: false))
                        }
                        break
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        if try retryWithCpuIfNeeded(error) {
                            forceSfMRun = currentStage == .sfmFeatures
                            forceMatchingRun = currentStage == .sfmMatching
                            continue
                        }
                        if !didRetryWithExactMatcher,
                           let sourcePlan = latestPreparedPairPlan,
                           let reason = DescriptorMatcherRecoveryPolicy.reason(
                               for: error,
                               currentMatcher: colmapMatchOptions.descriptorMatcher,
                               scheduledPairCount: sourcePlan.pairs.count
                           ) {
                            didRetryWithExactMatcher = true
                            colmapMatchOptions.descriptorMatcher = .exact
                            pairAttemptMode = .sameScheduleExact(sourcePlan, reason)
                            recordMappingFallback("exact descriptor matching")
                            try persistAttemptRecoveryIntent(
                                mode: pairAttemptMode,
                                activePlan: sourcePlan,
                                activeRetrieval: latestPreparedRetrievalEvidence
                            )
                            try self.resetDirectory(paths.colmapSparseURL)
                            acceptedPairGraphEvidence = nil
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "FAISS matching failed (\(reason.rawValue)); preserving features and retrying with exact matching.",
                                isError: true
                            ))
                            self.emitColmapRetryDiagnostics(error, stage: .sfmMatching, emit: emit)
                            forceSfMRun = false
                            forceMatchingRun = true
                            continue
                        }
                        let disconnectedRetrieval = error
                            as? DisconnectedVocabularyRetrievalEvidence
                        if disconnectedRetrieval != nil,
                           try advancePairRecovery(
                                "Image retrieval did not connect the scheduled pair graph"
                           ) {
                            self.emitColmapRetryDiagnostics(
                                error,
                                stage: .sfmMatching,
                                emit: emit
                            )
                            forceSfMRun = false
                            forceMatchingRun = true
                            continue
                        }
                        if disconnectedRetrieval != nil {
                            let workerEvidence = try workerExecutionRecorder
                                .validatedArtifact()
                            throw try CaptureRetrievalConnectionFailure(
                                pairingPolicy: resolvedRunPlan.pairingPolicy,
                                selectedViewCount: selectedFrames.count,
                                attempts: workerEvidence
                                    .rejectedVocabularyRetrievalInvocations
                            )
                        }
                        let pairPlanningError = error as? ColmapPairPlanningError
                        if pairPlanningError == .repeatedAttempt,
                           try advancePairRecovery("Image retrieval repeated the previous pair graph") {
                            forceSfMRun = false
                            forceMatchingRun = true
                            continue
                        }
                        if (pairPlanningError == .disconnectedPairSchedule
                                || pairPlanningError == .disconnectedVerifiedGraph),
                           try advancePairRecovery(
                                "Image matching did not produce a connected graph"
                           ) {
                            self.emitColmapRetryDiagnostics(
                                error,
                                stage: .sfmMatching,
                                emit: emit
                            )
                            forceSfMRun = false
                            forceMatchingRun = true
                            continue
                        }
                        if !didRetryWithExactMatcher,
                           colmapMatchOptions.descriptorMatcher == .faiss,
                           pairPlanningError == .disconnectedVerifiedGraph,
                           Self.nextPairRecoveryLevel(
                               after: pairRecoveryLevel,
                               imageCount: selectedFrames.count,
                               pairingPolicy: resolvedRunPlan.pairingPolicy
                           ) == nil,
                           let sourcePlan = latestCompletedPairPlan,
                           let exactReason = DescriptorMatcherRecoveryPolicy
                            .reasonForRejectedGeometry(
                               currentMatcher: colmapMatchOptions.descriptorMatcher,
                               exhaustedFaissRetries: true,
                               scheduledPairCount: sourcePlan.pairs.count
                           ) {
                            let nextMode = PairAttemptMode.sameScheduleExact(
                                sourcePlan,
                                exactReason
                            )
                            didRetryWithExactMatcher = true
                            colmapMatchOptions.descriptorMatcher = .exact
                            pairAttemptMode = nextMode
                            recordMappingFallback("exact descriptor matching")
                            try persistAttemptRecoveryIntent(
                                mode: nextMode,
                                activePlan: nextMode.planOverride ?? sourcePlan,
                                activeRetrieval: latestPreparedRetrievalEvidence
                            )
                            acceptedPairGraphEvidence = nil
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "The densest FAISS schedule did not pass. Retrying that complete schedule with exact descriptor matching.",
                                isError: true
                            ))
                            forceSfMRun = false
                            forceMatchingRun = true
                            continue
                        }
                        if pairPlanningError == .disconnectedVerifiedGraph,
                           let captureFailure = latestRejectedCaptureConnectionFailure {
                            throw captureFailure
                        }
                        throw error
                    }
                }

                try Task.checkCancellation()
                if try shouldRunStage(.sfmMapping) {
                    completedMappingThisAttempt = true
                    currentStage = .sfmMapping
                    emit(.stageStarted(stage: .sfmMapping))
                    try self.resetDirectory(paths.colmapSparseURL)
                    writeCheckpoint(
                        stage: .sfmMapping,
                        progress: 0,
                        message: "Camera mapping started"
                    )
                    let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                    colmapToolLog.beginSection(
                        title: "mapper",
                        metadata: [
                            "database": paths.colmapDatabaseURL.path,
                            "images": paths.framesSelectedURL.path,
                            "output": paths.colmapSparseURL.path,
                            "tool": self.config.toolchain.colmap.path
                        ]
                    )
                    emit(.stageLog(
                        stage: .sfmMapping,
                        line: "Tool log: \(paths.colmapLogURL.lastPathComponent)",
                        isError: false
                    ))
                    var mappingSucceeded = false
                    var lastMappingError: Error?
                    var selectedMappedModel: MappedSparseModelCandidate?
                    var selectedMappedModelSnapshot: MappedSparseModelSnapshot?
                    var selectedMappedModelTextIsCanonical = false

                    func evaluateMappingResult(
                        mappingAttemptOrdinal: Int,
                        acceptedRefinementInvocationCount: Int,
                        cadence: IncrementalMappingCadenceArtifact
                    ) async throws -> Bool {
                        let modelDirectories = try self.mappedSparseModelDirectories(
                            in: paths.colmapSparseURL
                        )
                        let memberships = try ColmapSparseModelMembershipReader(
                            databaseURL: paths.colmapDatabaseURL,
                            selectedImageNames: selectedFrames.map(\.lastPathComponent)
                        ).read(
                            modelDirectories: modelDirectories.map(\.url),
                            checkCancellation: self.tooling.checkCancellation
                        )
                        let membershipByOrder = Dictionary(
                            uniqueKeysWithValues: memberships.models.map {
                                ($0.modelOrder, $0.imageIDs)
                            }
                        )
                        var candidates: [MappedSparseModelCandidate] = []
                        candidates.reserveCapacity(modelDirectories.count)
                        var snapshotByOrder: [Int: MappedSparseModelSnapshot] = [:]
                        var publicationByOrder: [Int: CanonicalModelPublicationArtifact] = [:]
                        var conditioningByOrder: [Int: GeometryConditioningAnalysis] = [:]
                        var firstAnalysisError: Error?
                        for model in modelDirectories {
                            try Task.checkCancellation()
                            do {
                                guard let membership = membershipByOrder[model.order] else {
                                    throw PipelineError.outputMissing
                                }
                                let publication = try prepareCanonicalTextCandidate(
                                    at: model.url,
                                    mappingAttemptOrdinal: mappingAttemptOrdinal
                                )
                                let conditioning = try self.validatedConditionedGeometry(
                                    modelDirectory: model.url,
                                    selectedFrames: selectedFrames,
                                    minimumRegisteredViewCount: membership.count,
                                    requireStrongObservationCoverage: false
                                )
                                let snapshot = try self.captureMappedSparseModel(at: model.url)
                                let report = try await self.tooling.colmap.runModelAnalyzer(
                                    colmapPath: self.config.toolchain.colmap,
                                    modelPath: model.url,
                                    environment: [:]
                                )
                                try Task.checkCancellation()
                                try self.validateMappedSparseModel(snapshot, at: model.url)
                                try GeometryModelSnapshot.validate(
                                    conditioning.modelSnapshot,
                                    at: model.url
                                )
                                for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                                    colmapToolLog.append(stream: "stdout", line: String(line))
                                }
                                let score = ReconstructionScorer.applyingExpectedTotalImages(
                                    ReconstructionScorer.parseModelAnalyzerOutput(report),
                                    expectedTotalImages: selectedFrames.count
                                )
                                guard score.registeredImages == membership.count,
                                      conditioning.residuals.registeredViewCount
                                        == membership.count else {
                                    throw PipelineError.geometryRegisteredImagesMismatch
                                }
                                snapshotByOrder[model.order] = snapshot
                                publicationByOrder[model.order] = publication
                                conditioningByOrder[model.order] = conditioning
                                candidates.append(MappedSparseModelCandidate(
                                    url: model.url,
                                    order: model.order,
                                    score: score
                                ))
                            } catch {
                                if error is CancellationError { throw error }
                                try Task.checkCancellation()
                                if firstAnalysisError == nil { firstAnalysisError = error }
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Could not inspect COLMAP model \(model.order); trying the remaining reconstruction candidates.",
                                    isError: true
                                ))
                            }
                        }
                        guard !candidates.isEmpty else {
                            throw firstAnalysisError ?? PipelineError.outputMissing
                        }
                        let residualValidatedModelOrders = Set(candidates.map(\.order))
                        let rankedCandidates = Self.rankedMappedSparseModels(
                            candidates,
                            capturePath: resolvedRunPlan.capturePath
                        )
                        guard !rankedCandidates.isEmpty else {
                            throw PipelineError.outputMissing
                        }
                        var preferredValidationError: Error?
                        var preferredLowQualityScore: ReconstructionScore?
                        var preferredFragmentationEvidence: MappingFragmentationEvidence?
                        for selected in rankedCandidates {
                            let score = selected.score
                            guard ReconstructionScorer.isAcceptable(
                                score,
                                capturePath: resolvedRunPlan.capturePath
                            ) else {
                                if preferredLowQualityScore == nil {
                                    preferredLowQualityScore = score
                                }
                                continue
                            }
                            let modelLabel = String(selected.order)
                            do {
                                guard let canonicalModelPublication =
                                        publicationByOrder[selected.order],
                                      let conditioningAnalysis =
                                        conditioningByOrder[selected.order],
                                      let selectedSnapshot = snapshotByOrder[selected.order] else {
                                    throw PipelineError.outputMissing
                                }
                                try self.validateMappedSparseModel(
                                    selectedSnapshot,
                                    at: selected.url
                                )
                                try GeometryModelSnapshot.validate(
                                    conditioningAnalysis.modelSnapshot,
                                    at: selected.url
                                )
                                if let fragmentation = Self.mappingFragmentationEvidence(
                                    selected: selected,
                                    candidates: candidates,
                                    memberships: memberships.models,
                                    residualValidatedModelOrders: residualValidatedModelOrders,
                                    totalSelectedViewCount: selectedFrames.count
                                ) {
                                    if preferredFragmentationEvidence == nil {
                                        preferredFragmentationEvidence = fragmentation
                                    }
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "Rejected COLMAP model \(modelLabel): it omitted \(fragmentation.omittedRecoverableViewCount) views that reconstructed in credible sibling models (\(fragmentation.selectedRegisteredViewCount)/\(fragmentation.credibleUnionRegisteredViewCount) selected/union).",
                                        isError: true
                                    ))
                                    continue
                                }
                                emit(.stageProgress(
                                    stage: .sfmMapping,
                                    fraction: 0.95,
                                    message: "Validating camera solve"
                                ))
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Selected COLMAP model \(modelLabel) (\(score.registeredImages)/\(score.totalImages) registered views).",
                                    isError: false
                                ))
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Reconstruction score (colmap): \(ReconstructionScorer.summary(score)).",
                                    isError: false
                                ))
                                selectedMappedModel = selected
                                selectedMappedModelSnapshot = selectedSnapshot
                                selectedMappedModelTextIsCanonical = true
                                acceptedMappingArtifact = MappingArtifact(
                                    modelCount: memberships.modelCount,
                                    largestModelRegisteredViewCount:
                                        memberships.largestModelRegisteredViewCount,
                                    secondLargestModelRegisteredViewCount:
                                        memberships.secondLargestModelRegisteredViewCount,
                                    unionRegisteredViewCount:
                                        memberships.unionRegisteredViewCount,
                                    attemptCount: mappingAttemptCount,
                                    acceptedMappingAttemptOrdinal: mappingAttemptOrdinal,
                                    acceptedRefinementKind: .incrementalGlobal,
                                    acceptedRefinementInvocationCount:
                                        acceptedRefinementInvocationCount,
                                    plannedIncrementalCadence:
                                        plannedIncrementalCadence,
                                    incrementalCadence: cadence,
                                    cadenceFallbackTrigger:
                                        activeCadenceFallbackTrigger,
                                    canonicalModelPublication: canonicalModelPublication,
                                    fallbackReason: nil
                                )
                                self.warnIfWeakAcceptedSolve(
                                    score: score,
                                    mapper: "colmap",
                                    emit: emit
                                )
                                acceptedMapper = "colmap"
                                acceptedConditioningAnalysis = conditioningAnalysis
                                return true
                            } catch {
                                if error is CancellationError { throw error }
                                try Task.checkCancellation()
                                let validationError = Self.normalizedUnusableSparseModelError(
                                    error
                                )
                                if preferredValidationError == nil {
                                    preferredValidationError = validationError
                                }
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Rejected COLMAP model \(modelLabel) because its measured geometry did not pass validation; trying the next reconstruction candidate.",
                                    isError: true
                                ))
                            }
                        }

                        if let preferredFragmentationEvidence {
                            lastMappingError = PipelineError.fragmentedReconstruction(
                                preferredFragmentationEvidence
                            )
                        } else if let preferredValidationError {
                            lastMappingError = preferredValidationError
                        } else if let preferredLowQualityScore {
                            lastMappingError = PipelineError.lowQualityReconstruction(
                                preferredLowQualityScore,
                                mapper: "colmap"
                            )
                        } else {
                            lastMappingError = PipelineError.outputMissing
                        }
                        return false
                    }

                    mappingAttemptLoop: while true {
                        let cadence = activeIncrementalCadence
                        let mappingProgress = ColmapMappingProgressTracker(
                            totalImages: selectedFrames.count
                        )
                        let onMappingLog: @Sendable (String, Bool) -> Void = { line, isErr in
                            let sanitized = Self.sanitizeToolLogLine(line)
                            let effectiveIsErr = Self.normalizedToolLogIsError(
                                sanitized,
                                isError: isErr
                            )
                            if Self.shouldEmitToolLogLine(
                                sanitized,
                                isError: effectiveIsErr
                            ) {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: sanitized,
                                    isError: effectiveIsErr
                                ))
                            }
                            if let update = mappingProgress.ingest(line) {
                                emit(.stageProgress(
                                    stage: .sfmMapping,
                                    fraction: update.fraction,
                                    message: update.message
                                ))
                            }
                        }
                        lastMappingError = nil
                        selectedMappedModel = nil
                        selectedMappedModelSnapshot = nil
                        selectedMappedModelTextIsCanonical = false
                        acceptedMappingArtifact = nil
                        acceptedMapper = nil
                        acceptedConditioningAnalysis = nil
                        mappingSucceeded = false
                        guard let pairEvidence = acceptedPairGraphEvidence else {
                            throw PairGraphEvidenceStoreError.invalidEvidence
                        }
                        let mapperContext = try pairEvidence
                            .mapperWorkerInvocationContext()
                        activeMapperGraphContext = mapperContext
                        let mappingAttemptOrdinal = try beginMappingAttempt()
                        try self.resetDirectory(paths.colmapSparseURL)
                        do {
                            try await self.tooling.colmap.runMapper(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                outputPath: paths.colmapSparseURL,
                                environment: [:],
                                mapperOptions: try ColmapMapperOptions(
                                    globalFramesRatio: cadence.globalFramesRatio,
                                    globalPointsRatio: cadence.globalPointsRatio,
                                    localMaxRefinements: cadence.localMaxRefinements,
                                    globalMaxRefinements: cadence.globalMaxRefinements,
                                    globalMaxNumIterations:
                                        resolvedRunPlan.refinementIterationLimit,
                                    localMaxNumIterations: cadence.localMaxNumIterations,
                                    localFunctionTolerance: cadence.localFunctionTolerance,
                                    globalFunctionTolerance: cadence.globalFunctionTolerance,
                                    localImageCount: cadence.localImageCount,
                                    randomSeed: resolvedRunPlan.runSeed,
                                    refineFocalLength: true
                                ),
                                mapperContext: mapperContext,
                                onLog: { line, isErr in
                                    colmapToolLog.append(
                                        stream: isErr ? "stderr" : "stdout",
                                        line: line
                                    )
                                    onMappingLog(line, isErr)
                                }
                            )
                        } catch {
                            if error is CancellationError { throw error }
                            if Task.isCancelled { throw CancellationError() }
                            lastMappingError = Self.normalizedUnusableSparseModelError(error)
                        }
                        if lastMappingError == nil {
                            do {
                                mappingSucceeded = try await evaluateMappingResult(
                                    mappingAttemptOrdinal: mappingAttemptOrdinal,
                                    acceptedRefinementInvocationCount:
                                        mappingProgress.globalRefinementInvocationCount,
                                    cadence: cadence
                                )
                            } catch {
                                if error is CancellationError || Task.isCancelled {
                                    try workerExecutionRecorder.recordMapperEvaluation(
                                        mappingAttemptOrdinal: mappingAttemptOrdinal,
                                        evaluation: ColmapMapperEvaluationEvidence(
                                            status: .interrupted,
                                            fallbackTrigger: nil
                                        )
                                    )
                                    throw CancellationError()
                                }
                                lastMappingError = Self.normalizedUnusableSparseModelError(
                                    error
                                )
                            }
                            let evaluation: ColmapMapperEvaluationEvidence
                            if mappingSucceeded {
                                evaluation = ColmapMapperEvaluationEvidence(
                                    status: .accepted,
                                    fallbackTrigger: nil
                                )
                            } else if lastMappingError is PipelineError {
                                evaluation = ColmapMapperEvaluationEvidence(
                                    status: .rejected,
                                    fallbackTrigger:
                                        Self.mappingCadenceFallbackTrigger(
                                            after: lastMappingError
                                        )
                                )
                            } else {
                                evaluation = ColmapMapperEvaluationEvidence(
                                    status: .failed,
                                    fallbackTrigger: nil
                                )
                            }
                            try workerExecutionRecorder.recordMapperEvaluation(
                                mappingAttemptOrdinal: mappingAttemptOrdinal,
                                evaluation: evaluation
                            )
                        }
                        if mappingSucceeded {
                            break mappingAttemptLoop
                        }
                        guard let trigger = Self.mappingCadenceFallbackTrigger(
                            after: lastMappingError
                        ),
                              let fallbackCadence = IncrementalMappingCadencePolicy
                                .fallbackCadence(
                                    planned: plannedIncrementalCadence,
                                    active: cadence,
                                    existingTrigger: activeCadenceFallbackTrigger
                                ) else {
                            break mappingAttemptLoop
                        }
                        let verifiedEvidence = try PairGraphEvidenceStore.loadVerified(
                            from: paths.pairGraphEvidenceURL,
                            expectedImageNames: selectedFrames.map(\.lastPathComponent),
                            databaseURL: paths.colmapDatabaseURL,
                            projectPaths: paths
                        )
                        try PairGraphEvidenceStore.validateSchedule(
                            verifiedEvidence,
                            resolvedPlan: resolvedRunPlan,
                            groups: selectedPairGroups
                        )
                        try PairGraphEvidenceStore.validateWorkerExecution(
                            verifiedEvidence,
                            workerExecution: try workerExecutionRecorder
                                .validatedArtifact()
                        )
                        let verifiedMapperContext = try verifiedEvidence
                            .mapperWorkerInvocationContext()
                        guard verifiedMapperContext == mapperContext else {
                            throw PairGraphEvidenceStoreError.invalidEvidence
                        }
                        acceptedPairGraphEvidence = verifiedEvidence
                        activeMapperGraphContext = verifiedMapperContext
                        activeIncrementalCadence = fallbackCadence
                        activeCadenceFallbackTrigger = trigger
                        recordMappingFallback(trigger.diagnosticReason)
                        try persistGeometryRecovery()
                        try self.resetDirectory(paths.colmapSparseURL)
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "The camera solve missed a geometry gate. Retrying the same verified image graph with denser global refinement.",
                            isError: true
                        ))
                    }
                    let mappingPairRecoveryReason: String?
                    if let pipelineError = lastMappingError as? PipelineError,
                       case .fragmentedReconstruction = pipelineError {
                        mappingPairRecoveryReason = "Camera mapping split recoverable views across separate models"
                    } else if Self.shouldRecoverPairGraph(after: lastMappingError) {
                        mappingPairRecoveryReason = "Reconstruction coverage was below the acceptance gate"
                    } else {
                        mappingPairRecoveryReason = nil
                    }
                    if !mappingSucceeded,
                       let mappingPairRecoveryReason,
                       try advancePairRecovery(mappingPairRecoveryReason) {
                        suspendStageTimingForRetry(.sfmMapping)
                        forceSfMRun = false
                        forceMatchingRun = true
                        continue sfmAttemptLoop
                    }

                    guard mappingSucceeded else {
                        let terminalError = lastMappingError
                            ?? PipelineError.lowQualityReconstruction(
                                .init(
                                    registeredImages: 0,
                                    totalImages: 0,
                                    meanReprojectionError: nil
                                ),
                                mapper: nil
                            )
                        let message = failureMessages(
                            for: terminalError,
                            stage: .sfmMapping
                        )
                        emitFailure(
                            stage: .sfmMapping,
                            userMessage: message.userMessage,
                            debugMessage: message.debugMessage
                        )
                        throw terminalError
                    }
                    guard let selectedMappedModel, let selectedMappedModelSnapshot else {
                        throw PipelineError.outputMissing
                    }
                    try Task.checkCancellation()
                    try self.publishCanonicalSparseModel(
                        from: selectedMappedModel.url,
                        snapshot: selectedMappedModelSnapshot,
                        at: paths.colmapSparseURL
                    )
                    let canonicalSparseModel = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                    let convertedCanonicalModel: Bool
                    if selectedMappedModelTextIsCanonical {
                        try requireTextSparseModelFiles(at: canonicalSparseModel)
                        convertedCanonicalModel = false
                    } else {
                        convertedCanonicalModel = try ensureTextSparseModelFiles(
                            at: canonicalSparseModel
                        )
                    }
                    if convertedCanonicalModel {
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "Converted sparse model to COLMAP text format for training compatibility.",
                            isError: false
                        ))
                    }
                    let normalizedImagesTxt = canonicalSparseModel.appendingPathComponent("images.txt")
                    if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: normalizedImagesTxt) {
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "Normalized COLMAP model (added missing POINTS2D lines to images.txt).",
                            isError: false
                        ))
                    }
                }

                break
            }
            }

            try Task.checkCancellation()
            // Geometry reconciliation is part of the durable mapping boundary even
            // when resume validation skipped the mapper subprocess itself.
            currentStage = .sfmMapping
            var mappingDurationText: String?
            if acceptedMapper != nil
                || !FileManager.default.fileExists(atPath: paths.geometryManifestURL.path) {
                guard let mapper = acceptedMapper else {
                    throw PipelineError.geometryResidualsUnavailable(
                        "The current project has accepted geometry without solver provenance"
                    )
                }
                if mapper.lowercased().contains("da3"),
                   acceptedDa3ModelSubdirectory == nil,
                   let da3Config = da3ConfigurationForAttempt {
                    let manifest = try Da3CoverageManifest.load(from: paths.da3CoverageManifestURL)
                    let issues = manifest.validationIssues(
                        selectedImageNames: selectedFrames.map(\.lastPathComponent),
                        expectedWindowSize: da3Config.windowSize,
                        expectedWindowOverlap: da3Config.windowOverlap,
                        expectedInputOrdering: da3Config.inputOrdering,
                        expectedProcessResolution: da3Config.processResolution,
                        expectedCameraType: da3Config.cameraType,
                        expectedSharedCamera: da3Config.sharedCamera,
                        expectedModelSubdirectory: da3Config.modelSubdirectory
                    )
                    guard issues.isEmpty else {
                        throw PipelineError.outputMissing
                    }
                    acceptedDa3ModelSubdirectory = manifest.modelSubdirectory
                }
                let currentSelectedFrameManifest = (try? loadSelectedFrameManifest(
                    from: paths.framesSelectedManifestURL
                )) ?? selectedFrameManifest
                guard let geometryPeakMemoryBytes = geometryMemorySampler.sampledPeak() else {
                    throw PipelineError.geometryResidualsUnavailable(
                        "Geometry-stage physical memory could not be measured"
                    )
                }
                let mappingFallbackReason = mappingFallbackReasons.isEmpty
                    ? nil
                    : mappingFallbackReasons.joined(separator: "; ")
                let measuredPairGraph: PairGraphArtifact
                var publicationDa3PairPlan: ColmapPairPlan?
                if mapper.lowercased().contains("da3") {
                    guard let pairEvidence = acceptedDa3PairGraphEvidence else {
                        throw PairGraphEvidenceStoreError.invalidEvidence
                    }
                    let pairPlan = try ColmapPairEstimator.validatedDa3RefinementPairPlan(
                        manifest: try Da3CoverageManifest.load(
                            from: paths.da3CoverageManifestURL
                        ),
                        imageNames: selectedFrames.map(\.lastPathComponent),
                        resolvedPlan: resolvedRunPlan
                    )
                    publicationDa3PairPlan = pairPlan
                    measuredPairGraph = try PairGraphEvidenceStore
                        .da3PairGraphArtifact(
                            pairEvidence,
                            expectedPlanBinding: PairGraphPlanBinding(
                                resolvedRunPlan
                            ),
                            expectedPairPlan: pairPlan
                        )
                } else {
                    guard let pairEvidence = acceptedPairGraphEvidence else {
                        throw PairGraphEvidenceStoreError.invalidEvidence
                    }
                    measuredPairGraph = try pairEvidence.pairGraphArtifact()
                }
                guard var measuredMapping = acceptedMappingArtifact else {
                    throw PipelineError.geometryResidualsUnavailable(
                        "The accepted camera solve did not produce mapping evidence"
                    )
                }
                measuredMapping.attemptCount = mappingAttemptCount
                measuredMapping.fallbackReason = mappingFallbackReason
                let finalColmapRuntimeClosure = try tooling.colmap.captureRuntimeClosure(
                    colmapPath: config.toolchain.colmap
                )
                try workerExecutionRecorder.rebindColmapRuntimeClosure(
                    finalColmapRuntimeClosure
                )
                let workerExecution = try workerExecutionRecorder.validatedArtifact()
                if let pairEvidence = acceptedPairGraphEvidence {
                    try PairGraphEvidenceStore.validateWorkerExecution(
                        pairEvidence,
                        workerExecution: workerExecution
                    )
                } else if let pairEvidence = acceptedDa3PairGraphEvidence,
                          let pairPlan = publicationDa3PairPlan {
                    try PairGraphEvidenceStore.validateDa3WorkerExecution(
                        pairEvidence,
                        expectedPlanBinding: PairGraphPlanBinding(
                            resolvedRunPlan
                        ),
                        expectedPairPlan: pairPlan,
                        workerExecution: workerExecution
                    )
                }
                guard let acceptedConditioningAnalysis else {
                    throw PipelineError.geometryResidualsUnavailable(
                        "The accepted camera solve did not retain conditioning evidence"
                    )
                }
                let canonicalSparseModel = paths.colmapSparseURL.appendingPathComponent(
                    "0",
                    isDirectory: true
                )
                try requireTextSparseModelFiles(at: canonicalSparseModel)
                let normalizedImagesTxt = canonicalSparseModel.appendingPathComponent(
                    "images.txt"
                )
                if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(
                    at: normalizedImagesTxt,
                    checkCancellation: self.tooling.checkCancellation
                ) {
                    emit(.stageLog(
                        stage: .sfmMapping,
                        line: "Normalized the published camera model before final verification.",
                        isError: false
                    ))
                }
                let publishedConditioningAnalysis = try validatedConditionedGeometry(
                    modelDirectory: canonicalSparseModel,
                    selectedFrames: selectedFrames,
                    requireStrongObservationCoverage: acceptedDa3ModelSubdirectory != nil
                )
                try requirePublishedGeometry(
                    publishedConditioningAnalysis,
                    matches: acceptedConditioningAnalysis,
                    at: canonicalSparseModel
                )
                try persistMeasuredGeometryArtifact(
                    metadata: &metadata,
                    paths: paths,
                    resolvedPlan: resolvedRunPlan,
                    mapper: mapper,
                    acceptedDa3ModelSubdirectory: acceptedDa3ModelSubdirectory,
                    selectedFrames: selectedFrames,
                    selectedFrameManifest: currentSelectedFrameManifest,
                    inputSnapshots: inputLease.videos + inputLease.photos,
                    peakMemoryBytes: geometryPeakMemoryBytes,
                    pairGraph: measuredPairGraph,
                    mapping: measuredMapping,
                    workerExecution: workerExecution,
                    acceptedAnalysis: publishedConditioningAnalysis,
                    currentMappingDurationSeconds: {
                        stageTiming.elapsedSeconds(.sfmMapping)
                    }
                )
                writeCheckpoint(
                    stage: .sfmMapping,
                    progress: 1.0,
                    message: "Camera mapping completed"
                )
            } else {
                let artifact = try GeometryArtifactStore.load(
                    from: paths.geometryManifestURL,
                    projectPaths: paths
                )
                try GeometryArtifactStore.requireRunPlanBinding(
                    artifact,
                    plan: resolvedRunPlan
                )
            }
            if completedMappingThisAttempt {
                mappingDurationText = stageTiming.finish(.sfmMapping)
                recordFinishedStageTiming(.sfmMapping)
            }
            _ = geometryMemorySampler.stop()
            if completedMappingThisAttempt {
                logger.emit(.stageFinished(stage: .sfmMapping))
                if let mappingDurationText {
                    logger.emit(.stageLog(
                        stage: .sfmMapping,
                        line: "Stage duration: \(mappingDurationText)",
                        isError: false
                    ))
                }
                markStageComplete(.sfmMapping)
            }
            // Geometry publication seals the worker ledger. Later COLMAP utility
            // calls prepare trainer input and must not mutate that attestation.
            tooling.colmap.setWorkerExecutionObserver(nil)
            } catch {
                if error is DevelopmentStop {
                    throw error
                }
                if error is CancellationError {
                    throw error
                }
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }

            try stopIfRequested(after: .sfmMapping)
            if skipTraining {
                emit(.stageLog(
                    stage: .sfmMapping,
                    line: "Stopping after geometry by development override.",
                    isError: false
                ))
                metadata.lastRunStartedAt = nil
                try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
                return
            }
            if try shouldRunStage(.trainSplat) {
                currentStage = .trainSplat
                emit(.stageStarted(stage: .trainSplat))
                let detailProfile = metadata.effectiveDetailProfile
                let trainingBudget = (
                    iterationLimit: resolvedRunPlan.trainerIterationLimit,
                    plateauWindow: resolvedRunPlan.plateauWindow
                )
                writeCheckpoint(
                    stage: .trainSplat,
                    progress: 0,
                    message: "Splat training started",
                    details: .trainSplat(TrainSplatCheckpoint(
                        progressStep: nil,
                        progressTotal: trainingBudget.iterationLimit
                    ))
                )
                    try paths.ensureMutableTrainingDirectories()
                    let geometryArtifact = try GeometryArtifactStore.load(
                        from: paths.geometryManifestURL,
                        projectPaths: paths,
                        expectedInput: metadata.input
                    )
                    let preparedDataset = try await prepareMsplatDataset(
                        paths: paths,
                        maxImageSize: resolvedRunPlan.maximumImageDimension,
                        geometryArtifact: geometryArtifact,
                        progress: { _, message in
                            emit(.stageProgress(stage: .trainSplat, fraction: -1.0, message: message))
                        }
                    )
                    let datasetURL = preparedDataset.url
                    let datasetIdentity = preparedDataset.identity
                    let datasetDerivation = preparedDataset.derivation
                    let outputURL = paths.msplatOutputURL
                    emit(.stageProgress(stage: .trainSplat, fraction: -1.0, message: "Training model with msplat"))

                    let msplatToolLog = ToolLogWriter(fileURL: paths.msplatLogURL, toolName: "msplat")
                    let msplatPath = msplatToolPath()
                    msplatToolLog.beginSection(
                        title: "train",
                        metadata: [
                            "dataset": datasetURL.path,
                            "output": outputURL.path,
                            "tool": msplatPath.path
                        ]
                    )
                    let cameraOrderSeed = resolvedRunPlan.runSeed
                    let resumeURL: URL?
                    do {
                        resumeURL = try msplatResumeURL(
                            paths: paths,
                            profile: detailProfile,
                            cameraOrderSeed: cameraOrderSeed,
                            resolvedPlan: resolvedRunPlan,
                            datasetIdentity: datasetIdentity,
                            datasetDerivation: datasetDerivation
                        )
                    } catch let validationError as MsplatCheckpointValidationError {
                        emit(.stageLog(
                            stage: .trainSplat,
                            line: "Saved training state could not be validated; restarting from reconstructed cameras. \(validationError.localizedDescription)",
                            isError: true
                        ))
                        var persistedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
                        try TrainingArtifactStore.discardCheckpointedArtifact(
                            metadata: &persistedMetadata,
                            paths: paths
                        )
                        metadata = persistedMetadata
                        resumeURL = nil
                    }
                    var completedTrainingResult: MsplatTrainingResult?
                    var completedTrainingAdmission: TrainingResourceAdmission?
                    var activeResumeURL = resumeURL
                    while completedTrainingResult == nil {
                        try paths.ensureMutableTrainingDirectories()
                        let resourceAdmission = try TrainingMemoryBudget.admit(
                            observing: self.tooling.trainingResourceObserver,
                            resourcePolicy: requestedOptions.resourcePolicy
                        )
                        let checkpointBudget = activeResumeURL == nil
                            ? nil
                            : try? TrainingArtifactStore.load(
                                from: paths.trainingManifestURL,
                                projectPaths: paths
                            ).memoryBudgetBytes
                        let admittedBudget = try TrainingMemoryBudget.trainerBudget(
                            plannedBytes: resolvedRunPlan.trainerMemoryBudgetBytes,
                            checkpointBytes: checkpointBudget,
                            admission: resourceAdmission
                        )
                        emit(.stageLog(
                            stage: .trainSplat,
                            line: "Training admitted \(ByteCountFormatter.string(fromByteCount: admittedBudget, countStyle: .memory)) from current unified-memory capacity.",
                            isError: false
                        ))
                        do {
                            let result = try await self.tooling.msplat.runTrain(
                                msplatPath: msplatPath,
                                datasetPath: datasetURL,
                                outputPath: outputURL,
                                expectedIdentity: datasetIdentity,
                                checkpointPath: paths.msplatCheckpointURL,
                                resumeFrom: activeResumeURL,
                                profile: detailProfile,
                                seed: cameraOrderSeed,
                                iterationLimit: resolvedRunPlan.trainerIterationLimit,
                                plateauWindow: resolvedRunPlan.plateauWindow,
                                memoryBudgetBytes: admittedBudget,
                                onProgress: { progress in
                                    let fraction = Double(progress.iteration) / Double(progress.iterationLimit)
                                    emit(.stageProgress(
                                        stage: .trainSplat,
                                        fraction: fraction,
                                        message: "Training splat · \(progress.iteration.formatted()) of \(progress.iterationLimit.formatted())"
                                    ))
                                },
                                onCheckpoint: { receipt in
                                    do {
                                        try self.persistMsplatCheckpoint(
                                            receipt,
                                            profile: detailProfile,
                                            cameraOrderSeed: cameraOrderSeed,
                                            resolvedPlan: resolvedRunPlan,
                                            resourceAdmission: resourceAdmission,
                                            datasetIdentity: datasetIdentity,
                                            datasetDerivation: datasetDerivation,
                                            paths: paths
                                        )
                                    } catch {
                                        emit(.stageLog(
                                            stage: .trainSplat,
                                            line: "Could not record an intermediate training checkpoint: \(error.localizedDescription)",
                                            isError: true
                                        ))
                                    }
                                },
                                onRasterFallback: { fallback in
                                    emit(.stageLog(
                                        stage: .trainSplat,
                                        line: "Exact raster fallback \(fallback.fallbackCount): \(fallback.intersectionCount.formatted()) intersections, \(ByteCountFormatter.string(fromByteCount: fallback.allocationBytes, countStyle: .memory)).",
                                        isError: false
                                    ))
                                },
                                onLog: { line, isErr in
                                    msplatToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                    let cleaned = Self.stripAnsiCodes(line)
                                    let trimmed = Self.sanitizeToolLogLine(cleaned)
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    let effectiveIsError = isErr && Self.looksLikeErrorishLine(trimmed.lowercased())
                                    if Self.shouldEmitToolLogLine(trimmed, isError: effectiveIsError) {
                                        emit(.stageLog(
                                            stage: .trainSplat,
                                            line: trimmed,
                                            isError: effectiveIsError
                                        ))
                                    }
                                }
                            )
                            completedTrainingResult = result
                            completedTrainingAdmission = resourceAdmission
                        } catch let rejection as MsplatResumeRejected where activeResumeURL != nil {
                            emit(.stageLog(
                                stage: .trainSplat,
                                line: "Saved training state no longer matches this run; restarting from reconstructed cameras. \(rejection.localizedDescription)",
                                isError: true
                            ))
                            var persistedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
                            try TrainingArtifactStore.discardCheckpointedArtifact(
                                metadata: &persistedMetadata,
                                paths: paths
                            )
                            metadata = persistedMetadata
                            activeResumeURL = nil
                        } catch let interruption as MsplatTrainingInterrupted {
                            try persistMsplatCheckpoint(
                                interruption.checkpoint,
                                profile: detailProfile,
                                cameraOrderSeed: cameraOrderSeed,
                                resolvedPlan: resolvedRunPlan,
                                resourceAdmission: resourceAdmission,
                                datasetIdentity: datasetIdentity,
                                datasetDerivation: datasetDerivation,
                                paths: paths
                            )
                            metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
                            throw CancellationError()
                        }
                    }
                    guard let trainingResult = completedTrainingResult else {
                        throw PipelineError.outputMissing
                    }
                    guard let trainingAdmission = completedTrainingAdmission else {
                        throw PipelineError.outputMissing
                    }
                    guard ProjectArtifactValidator.validatePlyFile(at: outputURL) == .valid else {
                        throw PipelineError.outputMissing
                    }
                    guard try currentMsplatDatasetDerivation(
                        paths: paths,
                        geometryArtifact: geometryArtifact,
                        maxImageSize: resolvedRunPlan.maximumImageDimension
                    ) == datasetDerivation else {
                        throw GeometryArtifactStore.Error.artifactDigestMismatch("training dataset")
                    }
                    let completedArtifact = try persistMsplatCompletion(
                        trainingResult,
                        profile: detailProfile,
                        cameraOrderSeed: cameraOrderSeed,
                        resolvedPlan: resolvedRunPlan,
                        resourceAdmission: trainingAdmission,
                        datasetIdentity: datasetIdentity,
                        datasetDerivation: datasetDerivation,
                        paths: paths
                    )
                    if let measuredBounds = completedArtifact.sceneBounds,
                       !SplatSceneBoundsCalculator.matches(
                            trainingResult.sceneBounds,
                            measuredBounds
                       ) {
                        emit(.stageLog(
                            stage: .trainSplat,
                            line: "Trainer-reported scene bounds differed from the validated PLY; the host measurement was retained.",
                            isError: false
                        ))
                    }
                    metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
                    if FileManager.default.fileExists(atPath: paths.msplatCheckpointURL.path) {
                        do {
                            try FileManager.default.removeItem(at: paths.msplatCheckpointURL)
                        } catch {
                            emit(.stageLog(
                                stage: .trainSplat,
                                line: "Could not remove completed training checkpoints: \(error.localizedDescription)",
                                isError: true
                            ))
                        }
                    }
                    writeCheckpoint(
                        stage: .trainSplat,
                        progress: 1.0,
                        message: "msplat training completed",
                        details: .trainSplat(TrainSplatCheckpoint(
                            progressStep: trainingResult.completedIteration,
                            progressTotal: trainingResult.iterationLimit
                        ))
                    )
                    emit(.stageFinished(stage: .trainSplat))
                    markStageComplete(.trainSplat)
                    try stopIfRequested(after: .trainSplat)
            }

            try Task.checkCancellation()
            if try shouldRunStage(.exportSplat) {
                currentStage = .exportSplat
                emit(.stageStarted(stage: .exportSplat))
                writeCheckpoint(stage: .exportSplat, progress: 0, message: "Export started")
                let ply = paths.msplatOutputURL
                guard ProjectArtifactValidator.validatePlyFile(at: ply) == .valid else {
                    throw PipelineError.outputMissing
                }
                let geometryArtifact = try GeometryArtifactStore.load(
                    from: paths.geometryManifestURL,
                    projectPaths: paths,
                    expectedInput: metadata.input
                )
                let trainingArtifact = try TrainingArtifactStore.load(
                    from: paths.trainingManifestURL,
                    projectPaths: paths
                )
                guard try currentMsplatDatasetDerivation(
                        paths: paths,
                        geometryArtifact: geometryArtifact,
                        maxImageSize: resolvedRunPlan.maximumImageDimension
                      ) == trainingArtifact.datasetDerivation else {
                    throw GeometryArtifactStore.Error.artifactDigestMismatch("training dataset")
                }
                let outputDirectory = try paths.resolveProjectRelativePath("Output")
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let outputPly = paths.outputSplatURL
                try SplatExport.copyIfExists(from: ply, to: outputPly)
                guard ProjectArtifactValidator.validatePlyFile(at: outputPly) == .valid else {
                    throw PipelineError.outputMissing
                }
                let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: outputPly.path)[.size] as? NSNumber)?.int64Value ?? 0
                writeCheckpoint(
                    stage: .exportSplat,
                    progress: 1.0,
                    message: "Exported splat.ply",
                    details: .exportSplat(ExportSplatCheckpoint(
                        outputPath: try paths.projectRelativePath(for: outputPly),
                        sourcePath: try paths.projectRelativePath(for: ply),
                        sizeBytes: sizeBytes
                    ))
                )
                emit(.stageFinished(stage: .exportSplat))
                markStageComplete(.exportSplat)
                try stopIfRequested(after: .exportSplat)
            }

            _ = try promoteMsplatCompletionToPublicOutput(paths: paths)
            metadata.state = PipelineState(stage: .done, lastError: nil)
            metadata.lastRunStartedAt = nil
            try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)

            do {
                try removeDisposableCompletedTrainingPayload(paths: paths)
            } catch {
                emit(.stageLog(
                    stage: .done,
                    line: "Could not remove disposable training files: \(error.localizedDescription)",
                    isError: true
                ))
            }

            emit(.stageFinished(stage: .done))
        } catch is DevelopmentStop {
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !didEmitFailure {
                let message = failureMessages(for: error, stage: currentStage)
                emitFailure(
                    stage: currentStage,
                    userMessage: message.userMessage,
                    debugMessage: message.debugMessage
                )
            }
            throw error
        }
    }

    func authenticateStartupVideoInputs(
        metadata: ProjectMetadata,
        paths: ProjectPaths,
        freshPublicationAttestation: FreshProjectPublicationAttestation?
    ) throws {
        if let freshPublicationAttestation {
            try freshPublicationAttestation.consume(projectURL: projectURL, metadata: metadata)
        } else {
            try tooling.validateVideoInputs(metadata, paths)
        }
    }

    func prepareStartupRuntimeInputLease(
        metadata: ProjectMetadata,
        paths: ProjectPaths,
        pairingPolicy: ResolvedPairingPolicy?,
        freshPublicationAttestation: FreshProjectPublicationAttestation?
    ) throws -> RuntimeInputSnapshotLease {
        let lease = try tooling.prepareRuntimeInputLease(metadata, paths, pairingPolicy)
        do {
            try freshPublicationAttestation?.completeConsumption()
            return lease
        } catch {
            lease.discard()
            throw error
        }
    }

    /// Removes the per-tool log files at the start of a run so each attempt has a clean
    /// log surface. Within a single run, ToolLogWriter is an appender — multiple stages
    /// targeting the same file (e.g. consecutive COLMAP stages) accumulate cleanly.
    /// Across runs, the orchestrator clears them here.
    static func resetPerRunToolLogs(at paths: ProjectPaths) {
        let fm = FileManager.default
        let toolLogs: [URL] = [
            paths.colmapLogURL,
            paths.da3LogURL,
            paths.msplatLogURL,
        ]
        for url in toolLogs {
            let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
            if fm.fileExists(atPath: url.path) || isSymlink {
                try? fm.removeItem(at: url)
            }
        }
    }
}
