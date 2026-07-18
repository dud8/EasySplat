import Foundation
import Dispatch
public final class PipelineRunner: @unchecked Sendable {

    private struct DevelopmentStop: Error {}

    public struct Tooling {
        public var colmap: ColmapRunner
        public var msplat: MsplatRunner
        public var da3Sfm: Da3SfmRunning
        let checkCancellation: @Sendable () throws -> Void
        let colmapGPUSupport: (@Sendable (URL) -> Bool)?

        public init(colmap: ColmapRunner = ColmapRunner(),
                    msplat: MsplatRunner = MsplatRunner(),
                    da3Sfm: Da3SfmRunning = Da3SfmRunner()) {
            self.colmap = colmap
            self.msplat = msplat
            self.da3Sfm = da3Sfm
            self.checkCancellation = { try Task.checkCancellation() }
            self.colmapGPUSupport = nil
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.msplat = MsplatRunner(runner: runner)
            self.da3Sfm = Da3SfmRunner(runner: runner)
            self.checkCancellation = { try Task.checkCancellation() }
            self.colmapGPUSupport = nil
        }

        init(
            runner: SubprocessRunning,
            checkCancellation: @escaping @Sendable () throws -> Void = {
                try Task.checkCancellation()
            },
            colmapGPUSupport: (@Sendable (URL) -> Bool)? = nil
        ) {
            self.colmap = ColmapRunner(runner: runner)
            self.msplat = MsplatRunner(runner: runner)
            self.da3Sfm = Da3SfmRunner(runner: runner)
            self.checkCancellation = checkCancellation
            self.colmapGPUSupport = colmapGPUSupport
        }
    }

    public struct PipelineConfig: Sendable {
        public var toolchain: ToolchainPaths
        public var developmentOverrides: DevelopmentOverrides
        public var hardwareProfile: HardwareProfile?
        public var resolvedRunPlan: ResolvedRunPlan?

        public init(
            toolchain: ToolchainPaths,
            developmentOverrides: DevelopmentOverrides = .none,
            hardwareProfile: HardwareProfile? = nil,
            resolvedRunPlan: ResolvedRunPlan? = nil
        ) {
            self.toolchain = toolchain
            self.developmentOverrides = developmentOverrides
            self.hardwareProfile = hardwareProfile
            self.resolvedRunPlan = resolvedRunPlan
        }
    }

    private let projectURL: URL
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
            events: events
        )
    }

    private func runPipeline(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        // Keep the Mac awake while work is active. Display sleep remains available, and
        // the assertion is released on every exit — success, failure, stop, or cancellation.
        let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is processing a project")
        defer { idleSleepAssertion.release() }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        // Load metadata BEFORE clearing any logs. If project.json is malformed, unreadable,
        // or from a future build, we want the user to keep the previous run's diagnostic
        // tool logs for inspection — wiping them on a no-op startup
        // failure would destroy the only evidence of why the prior attempt died.
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
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
        var effectiveLastCompletedStage = RunPlanResolver.safeResumeStage(
            lastCompletedStage,
            input: metadata.input,
            previousPlan: planChangedForCurrentHardware ? previousResolvedRunPlan : resolvedRunPlan,
            currentPlan: resolvedRunPlan
        )
        let workerExecutionRecorder = try GeometryWorkerExecutionRecorder(
            paths: paths,
            budget: resolvedRunPlan.geometryWorkerBudget,
            resumeAfter: effectiveLastCompletedStage,
            inputHasVideos: metadata.input.hasVideos,
            resetForPlanChange: planChangedForCurrentHardware
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
        if planChangedForCurrentHardware || recoveredWorkerExecution {
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
        try workerExecutionRecorder.commitRecoveryBaseline()
        var trainingManifestWarning: String?
        do {
            _ = try TrainingArtifactStore.reconcile(metadata: &metadata, paths: paths)
        } catch {
            trainingManifestWarning = error.localizedDescription
        }
        if metadata.state.lastError != nil, metadata.geometryRecovery != nil {
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
        var latestCompletedPairPlan: ColmapPairPlan?
        var pairGraphAttempts: [PairGraphAttemptEvidence] = []
        var usedLocalVocabularyRetrieval = false
        var attemptedPairConfigurations: Set<String> = []
        var acceptedPairGraphEvidence: PairGraphEvidence?
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
            try cleanForRetry(failedStage: metadata.state.stage, paths: paths)
            try paths.ensureDirectories()
        }

        let stageTiming = StageTimingTracker()
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
                details: details
            )
            try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        }

        func shouldRunStage(_ stage: PipelineStage) throws -> Bool {
            let validationMetadata = resumeValidationMode ? metadataForResumeValidation : metadata
            if stage == .sfmMapping,
               !reranStageBeforeTraining,
               validationMetadata.geometryArtifact != nil,
               try validateStageOutput(
                   stage,
                   paths: paths,
                   metadata: validationMetadata
               ) == .valid {
                metadata.geometryArtifact = validationMetadata.geometryArtifact
                metadata.geometryRecovery = nil
                metadata.reconstruction = validationMetadata.reconstruction
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
               validationMetadata.trainingArtifact?.completionStatus == .completed {
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
            if wasInterrupted, let checkpoint = metadata.checkpoint {
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
            var preparedPhotoFilter: ValidPhotoFilterResult?
            var resolvedFrameTargets: GlobalFrameTargets?
            var verifiedRawFrameManifest: ExtractedFrameManifest?
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
                    let videos = metadata.input.videoFiles
                    let importedVideos = importedVideoURLs(for: videos, paths: paths)
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
                    if metadata.input.hasPhotos {
                        let discoveredPhotos = try loadPhotos(in: paths.importedPhotosURL)
                        preparedPhotoFilter = try filterValidUniquePhotos(discoveredPhotos)
                    }
                    let videoTargetFrames: Int
                    if preparedPhotoFilter?.frames.isEmpty == false {
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
                    let preliminaryPlan = try resolveGlobalFrameTargets(
                        videos: sources.map {
                            VideoFrameAllocationInput(
                                durationSeconds: $0.durationSeconds,
                                availableCandidateCount: videoTargetFrames
                            )
                        },
                        validPhotoCount: preparedPhotoFilter?.frames.count ?? 0,
                        targetCount: videoTargetFrames,
                        photoSelection: resolvedRunPlan.photoSelection
                    )
                    let preliminaryTargets = preliminaryPlan.videoTargets
                    let sourceAnalysisConcurrency = Self.videoSourceAnalysisConcurrency(
                        maximumConcurrentTasks: resolvedRunPlan.geometryWorkerBudget
                            .maximumConcurrentVideoSourceAnalysisTasks,
                        videoSourceCount: sources.count
                    )
                    let sourceAnalysisConcurrencyMeter = VideoSourceAnalysisConcurrencyMeter()
                    for file in videos {
                        try Task.checkCancellation()
                        let sourceName = URL(fileURLWithPath: file).lastPathComponent
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Analyzing \(sourceName).",
                            isError: false
                        ))
                    }
                    let initialAnalysisProgress = WeightedVideoAnalysisProgress(
                        weights: sources.map(\.durationSeconds),
                        base: 0,
                        span: 0.4
                    ) { fraction in
                        emit(.stageProgress(
                            stage: .extractFrames,
                            fraction: fraction,
                            message: "Analyzing videos"
                        ))
                    }
                    var analyses = try await analyzeVideoSources(
                        sources,
                        options: analysisOptions,
                        targetCounts: preliminaryTargets,
                        maximumConcurrentTasks: sourceAnalysisConcurrency,
                        concurrencyMeter: sourceAnalysisConcurrencyMeter
                    ) { index, fraction in
                        initialAnalysisProgress.update(index: index, fraction: fraction)
                    }
                    emit(.stageProgress(
                        stage: .extractFrames,
                        fraction: 0.4,
                        message: "Analyzing videos"
                    ))
                    let attainablePlan = try resolveGlobalFrameTargets(
                        videos: analyses.map {
                            VideoFrameAllocationInput(
                                durationSeconds: $0.durationSeconds,
                                availableCandidateCount: $0.decodedFrameCount
                            )
                        },
                        validPhotoCount: preparedPhotoFilter?.frames.count ?? 0,
                        targetCount: videoTargetFrames,
                        photoSelection: resolvedRunPlan.photoSelection
                    )
                    let reanalysisIndices = analyses.indices.filter {
                        analyses[$0].availableCandidateCount
                            < attainablePlan.videoTargets[$0]
                    }
                    for index in reanalysisIndices {
                        try Task.checkCancellation()
                        let sourceName = URL(fileURLWithPath: videos[index]).lastPathComponent
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Analyzing \(sourceName) again after redistributing the frame budget.",
                            isError: false
                        ))
                    }
                    if !reanalysisIndices.isEmpty {
                        let sourcesToReanalyze = reanalysisIndices.map { sources[$0] }
                        let reanalysisTargets = reanalysisIndices.map {
                            attainablePlan.videoTargets[$0]
                        }
                        let reanalysisProgress = WeightedVideoAnalysisProgress(
                            weights: sourcesToReanalyze.map(\.durationSeconds),
                            base: 0.4,
                            span: 0.05
                        ) { fraction in
                            emit(.stageProgress(
                                stage: .extractFrames,
                                fraction: fraction,
                                message: "Analyzing videos"
                            ))
                        }
                        let expandedAnalyses = try await analyzeVideoSources(
                            sourcesToReanalyze,
                            options: analysisOptions,
                            targetCounts: reanalysisTargets,
                            maximumConcurrentTasks: min(
                                sourceAnalysisConcurrency,
                                sourcesToReanalyze.count
                            ),
                            concurrencyMeter: sourceAnalysisConcurrencyMeter
                        ) { index, fraction in
                            reanalysisProgress.update(index: index, fraction: fraction)
                        }
                        for (offset, sourceIndex) in reanalysisIndices.enumerated() {
                            analyses[sourceIndex] = expandedAnalyses[offset]
                        }
                    }
                    try workerExecutionRecorder.recordVideoSourceAnalysis(
                        videoSourceCount: sources.count,
                        snapshot: sourceAnalysisConcurrencyMeter.snapshot()
                    )
                    emit(.stageProgress(
                        stage: .extractFrames,
                        fraction: 0.45,
                        message: "Choosing frames"
                    ))
                    let finalPlan = try resolveGlobalFrameTargets(
                        videos: analyses.map {
                            VideoFrameAllocationInput(
                                durationSeconds: $0.durationSeconds,
                                availableCandidateCount: $0.availableCandidateCount
                            )
                        },
                        validPhotoCount: preparedPhotoFilter?.frames.count ?? 0,
                        targetCount: videoTargetFrames,
                        photoSelection: resolvedRunPlan.photoSelection
                    )
                    if finalPlan.totalTargetCount < attainablePlan.totalTargetCount {
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Using \(finalPlan.totalTargetCount) frames because only that many decoded frames produced valid analysis data.",
                            isError: true
                        ))
                    }
                    resolvedFrameTargets = finalPlan
                    let targets = finalPlan.videoTargets
                    var extractedGroups: [[URL]] = []
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
                        let extracted = try await extractor.extractFrames(
                            from: analysis,
                            targetCount: perVideoTarget,
                            to: rawDir,
                            options: outputOptions,
                            progress: { fraction, message in
                                let completedDuration = progressStartDuration
                                    + progressClipDuration * fraction
                                let scaled = 0.45
                                    + 0.55 * completedDuration / totalVideoDuration
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
                            progress: 0.45
                                + 0.55 * cumulativeDurations[index + 1] / totalVideoDuration,
                            message: "Extracted \(extracted.count) frames from \(sourceName)",
                            details: .extractFrames(ExtractFramesCheckpoint(
                                videoIndex: index,
                                videoName: sourceName,
                                extractedCount: extracted.count,
                                targetCount: perVideoTarget
                            ))
                        )
                    }
                    verifiedRawFrameManifest = try ExtractedFrameManifestStore.persist(
                        groups: extractedGroups,
                        targetCounts: targets,
                        paths: paths
                    )
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
                                expectedVideoCount: metadata.input.videoFiles.count,
                                maximumTotalFrames: targetFrames
                            )
                        }
                        let frameGroups = try ExtractedFrameManifestStore.frameGroups(
                            from: manifest,
                            paths: paths
                        )
                        for (index, rawFrames) in frameGroups.enumerated() {
                            try Task.checkCancellation()
                            let groupID = String(format: "video_%03d", index)
                            groups.append(.init(id: groupID, frames: rawFrames, isVideo: true))
                        }
                    }

                    if metadata.input.photosFolder != nil {
                        let sourceFolder = paths.importedPhotosURL
                        let photoFilter: ValidPhotoFilterResult
                        if let preparedPhotoFilter {
                            photoFilter = preparedPhotoFilter
                        } else {
                            let discoveredPhotos = try loadPhotos(in: sourceFolder)
                            photoFilter = try filterValidUniquePhotos(discoveredPhotos)
                        }
                        let photoTarget: Int
                        if metadata.input.hasVideos {
                            let videoFrameCount = groups
                                .filter(\.isVideo)
                                .reduce(0) { $0 + $1.frames.count }
                            photoTarget = resolvedFrameTargets?.photoTarget
                                ?? min(
                                    photoFilter.frames.count,
                                    max(0, targetFrames - videoFrameCount)
                                )
                        } else {
                            photoTarget = photoFilter.frames.count
                        }
                        let selectedPhotos = evenlySpacedFrames(
                            photoFilter.frames,
                            targetCount: photoTarget
                        )
                        if !selectedPhotos.isEmpty {
                            groups.append(.init(id: "photos", frames: selectedPhotos, isVideo: false))
                            emit(.stageLog(
                                stage: .selectFrames,
                                line: "Using \(selectedPhotos.count) of \(photoFilter.frames.count) valid, unique photos.",
                                isError: false
                            ))
                        }
                        if photoFilter.unreadableCount > 0 || photoFilter.duplicateCount > 0 {
                            emit(.stageLog(
                                stage: .selectFrames,
                                line: "Skipped \(photoFilter.unreadableCount) unreadable and \(photoFilter.duplicateCount) duplicate photo(s).",
                                isError: false
                            ))
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

                    let selection = try copySelected(
                        groups: budgetedGroups,
                        to: paths.framesSelectedURL,
                        manifestURL: paths.framesSelectedManifestURL,
                        maxDimension: maxDim,
                        progress: { fraction, message in
                            emit(.stageProgress(stage: .selectFrames, fraction: fraction, message: message))
                        }
                    )
                    selectedFrames = selection.frames
                    selectedFrameManifest = selection.manifest
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

            let convertedHeic = try normalizeSelectedImagesForTooling(paths: paths)
            if convertedHeic > 0 {
                emit(.stageLog(
                    stage: .selectFrames,
                    line: "Converted \(convertedHeic) HEIC image(s) to JPEG for tool compatibility.",
                    isError: false
                ))
                selectedFrames = try loadImages(in: paths.framesSelectedURL)
                selectedFrameManifest = (try? loadSelectedFrameManifest(from: paths.framesSelectedManifestURL)) ?? selectedFrameManifest
            }
            if selectedFrames.count < RunPlanResolver.minimumReconstructionImageCount {
                throw PipelineError.insufficientInputImages(selectedFrames.count)
            }
            let sharedCameraRequested = da3SharedCameraPreference(
                input: metadata.input,
                cameraGrouping: resolvedRunPlan.cameraGrouping
            )
            let shareCameraAcrossSelectedFrames: Bool
            if sharedCameraRequested {
                shareCameraAcrossSelectedFrames = try selectedImagesHaveUniformPixelDimensions(
                    selectedFrames
                )
            } else {
                shareCameraAcrossSelectedFrames = false
            }

            let geometryMemorySampler = GeometryMemorySampler()
            geometryMemorySampler.start()
            defer { geometryMemorySampler.cancel() }

            try Task.checkCancellation()
            let da3WindowSize = resolvedRunPlan.chunkSize
            let backendOrder = try sfmBackendFallbackOrder(resolvedPlan: resolvedRunPlan)
            let geometryRecoveryImageNames = selectedFrames.map(\.lastPathComponent)
            let geometryRecoveryFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: geometryRecoveryImageNames,
                projectPaths: paths
            )
            let plannedIncrementalCadence = resolvedRunPlan.incrementalMappingCadence

            func sfmBackend(for backend: GeometryRecoveryBackend) -> SfmBackend {
                switch backend {
                case .da3: return .da3
                case .colmap: return .colmap
                }
            }

            let restoredGeometryRecovery: GeometryRecoveryState?
            if let recovery = metadata.geometryRecovery {
                do {
                    try recovery.validateBinding(
                        expectedImageNames: geometryRecoveryImageNames,
                        expectedSelectedFramesDigest: geometryRecoveryFramesDigest,
                        expectedPlannedIncrementalCadence: recovery.activeBackend == .colmap
                            ? plannedIncrementalCadence
                            : nil
                    )
                    guard backendOrder.contains(sfmBackend(for: recovery.activeBackend)) else {
                        throw GeometryRecoveryState.ValidationError.invalidBackendFields
                    }
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

            let backendName: (SfmBackend) -> String = { backend in
                switch backend {
                case .da3:
                    return "Depth Anything 3"
                case .colmap:
                    return "COLMAP"
                }
            }

            var acceptedReconstructionSummary: ReconstructionSummary?
            var mappingAttemptCount = restoredGeometryRecovery?.mappingAttemptCount ?? 0
            var acceptedMappingArtifact: MappingArtifact?
            var mappingFallbackReasons = restoredGeometryRecovery?.mappingFallbackReasons ?? []
            var activeIncrementalCadence = restoredGeometryRecovery?
                .activeIncrementalCadence ?? plannedIncrementalCadence
            var recoveredActiveBackend = restoredGeometryRecovery.map {
                sfmBackend(for: $0.activeBackend)
            }
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
                if recovery.activeBackend == .da3,
                   recovery.da3DescriptorMatcher == .exact {
                    colmapMatchOptions.descriptorMatcher = .exact
                    didRetryWithExactMatcher = true
                }
                if recovery.activeBackend == .colmap,
                   sparseModelFilesExist(at: paths.colmapSeedModelURL) {
                    try prepareForClassicalFeatureExtraction(paths: paths)
                    try paths.ensureDirectories()
                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "Finished an interrupted reconstruction-route handoff before resuming.",
                        isError: false
                    ))
                }
            }

            func recordMappingFallback(_ reason: String) {
                guard !mappingFallbackReasons.contains(reason) else { return }
                mappingFallbackReasons.append(reason)
            }

            func persistGeometryRecovery(
                activeBackend: SfmBackend,
                pendingPairRecoveryLevel: PairGraphRecoveryLevel? = nil,
                da3DescriptorMatcher: DescriptorMatcher? = nil
            ) throws {
                let recoveryBackend: GeometryRecoveryBackend
                switch activeBackend {
                case .da3: recoveryBackend = .da3
                case .colmap: recoveryBackend = .colmap
                }
                let state = GeometryRecoveryState(
                    selectedFramesDigest: geometryRecoveryFramesDigest,
                    orderedImageNames: geometryRecoveryImageNames,
                    activeBackend: recoveryBackend,
                    mappingAttemptCount: mappingAttemptCount,
                    mappingFallbackReasons: mappingFallbackReasons,
                    pendingPairRecoveryLevel: pendingPairRecoveryLevel,
                    da3DescriptorMatcher: da3DescriptorMatcher,
                    colmapComputeMode: recoveryBackend == .colmap
                        ? (colmapMatchOptions.useGPU ? .gpu : .cpu)
                        : nil,
                    plannedIncrementalCadence: recoveryBackend == .colmap
                        ? plannedIncrementalCadence
                        : nil,
                    activeIncrementalCadence: recoveryBackend == .colmap
                        ? activeIncrementalCadence
                        : nil
                )
                try state.validate()
                metadata.geometryRecovery = state
                try ProjectMetadataStore.savePreservingUserEditableFields(
                    metadata,
                    to: paths.metadataURL
                )
            }

            func beginMappingAttempt(
                activeBackend: SfmBackend,
                pendingPairRecoveryLevel: PairGraphRecoveryLevel? = nil,
                da3DescriptorMatcher: DescriptorMatcher? = nil
            ) throws -> Int {
                if resumingInterruptedMapping {
                    recordMappingFallback("interrupted mapping resumed")
                    resumingInterruptedMapping = false
                }
                guard mappingAttemptCount < GeometryRecoveryState.maximumMappingAttemptCount else {
                    throw GeometryRecoveryState.ValidationError.invalidMappingAttemptCount
                }
                let mappingAttemptOrdinal = try workerExecutionRecorder.beginMappingAttempt()
                mappingAttemptCount += 1
                try persistGeometryRecovery(
                    activeBackend: activeBackend,
                    pendingPairRecoveryLevel: pendingPairRecoveryLevel,
                    da3DescriptorMatcher: da3DescriptorMatcher
                )
                return mappingAttemptOrdinal
            }

            for (index, backendPolicy) in backendOrder.enumerated() {
                if let pendingRecoveredBackend = recoveredActiveBackend {
                    guard backendPolicy == pendingRecoveredBackend else { continue }
                    // Apply the persisted route exactly once; later entries remain
                    // available as the normal fallback order for this resumed run.
                    recoveredActiveBackend = nil
                }
                // Reset accepted-quality state at the start of every backend attempt so a
                // partial failure from the previous backend cannot leak its score/summary
                // into a later backend's successful run.
                acceptedReconstructionSummary = nil
                acceptedMappingArtifact = nil
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
                            fallbackModelSubdirectory: resolvedRunPlan.modelIdentifier == "DA3-BASE"
                                ? da3FallbackModelPreference()
                                : resolvedRunPlan.modelIdentifier,
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
                                expectedPrimaryModelSubdirectory: da3Config.modelSubdirectory,
                                expectedFallbackModelSubdirectory: da3Config.fallbackModelSubdirectory
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
                            } catch {
                                emit(.stageLog(
                                    stage: currentStage,
                                    line: "DA3 learned point initializer was invalid (\(error.localizedDescription)).",
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
                                line: "DA3 candidate: single batch, ordering=\(da3Config.inputOrdering.rawValue) model=\(da3Config.modelSubdirectory) fallback=\(da3Config.fallbackModelSubdirectory) device=\(da3Config.device) processRes=\(da3Config.processResolution) maxPoints=\(da3Config.maxPoints) sharedCamera=\(da3Config.sharedCamera) cameraType=\(da3Config.cameraType) views=\(da3Config.windowSize).",
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
                                    "fallbackModel": da3Config.fallbackModelSubdirectory,
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

                        if try shouldRunStage(.sfmMatching) {
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
                            emit(.stageProgress(stage: .sfmMatching, fraction: 0.02, message: "Extracting local features…"))
                            try await self.tooling.colmap.runFeatureExtractor(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                maxImageSize: colmapMaxImageSize,
                                cameraModel: da3Config.cameraType,
                                singleCamera: da3Config.sharedCamera,
                                options: da3ColmapExtractOptions,
                                onLog: { line, isErr in
                                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                }
                            )
                            self.logKeypointStats(database: paths.colmapDatabaseURL, stage: .sfmMatching, emit: emit)
                            try resetMatchingIfNeeded()
                            if restoredGeometryRecovery?.activeBackend == .da3,
                               restoredGeometryRecovery?.da3DescriptorMatcher == .exact {
                                try ColmapDatabaseMatchStore.clearMatchingResults(
                                    at: paths.colmapDatabaseURL
                                )
                            }

                            let seedManifest = try readDa3CoverageManifest(required: true)
                            guard let localPairs = seedManifest?.boundedMatchPairs,
                                  !localPairs.isEmpty else {
                                throw PipelineError.outputMissing
                            }
                            let includesLoopClosures = false
                            let loopPairs: [String] = []
                            guard let trustedPairLimit = Da3CoverageManifest.trustedRefinementMatchPairLimit(
                                selectedImageCount: selectedFrames.count,
                                windowSize: da3Config.windowSize,
                                windowOverlap: da3Config.windowOverlap,
                                inputOrdering: da3Config.inputOrdering,
                                includesLoopClosures: includesLoopClosures
                            ) else {
                                throw PipelineError.outputMissing
                            }
                            let pairPlan = try ColmapPairEstimator.da3RefinementPairPlan(
                                imageNames: selectedFrames.map(\.lastPathComponent),
                                localPairs: localPairs,
                                loopPairs: loopPairs,
                                maxPairCount: trustedPairLimit
                            )
                            let matchListURL = paths.colmapSeedURL.appendingPathComponent("match_pairs.txt")
                            try pairPlan.serializedData.write(to: matchListURL, options: .atomic)
                            let persistedPairData = try Data(contentsOf: matchListURL)
                            guard pairPlan.validates(persistedPairData) else {
                                throw PipelineError.outputMissing
                            }
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "DA3 refinement pair plan: \(pairPlan.localPairCount) local + \(pairPlan.loopPairCount) loop, sha256 \(pairPlan.sha256).",
                                isError: false
                            ))
                            let matcherLog: @Sendable (String, Bool) -> Void = { line, isErr in
                                colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                            }
                            try await self.runDa3MatchesImporterWithOneShotExactRecovery(
                                database: paths.colmapDatabaseURL,
                                matchListPath: matchListURL,
                                options: da3ColmapMatchOptions,
                                onLog: matcherLog,
                                emit: emit,
                                onExactRecovery: {
                                    didRetryWithExactMatcher = true
                                    colmapMatchOptions.descriptorMatcher = .exact
                                    recordMappingFallback("exact descriptor matching")
                                    try persistGeometryRecovery(
                                        activeBackend: .da3,
                                        da3DescriptorMatcher: .exact
                                    )
                                }
                            )
                            let expectedPairs = pairPlan.pairs.count
                            let processedPairs = (try? ColmapDatabaseProgressPoller(
                                databasePath: paths.colmapDatabaseURL
                            ).readAttemptedPairCount()) ?? 0
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
                            try persistGeometryRecovery(
                                activeBackend: .da3,
                                da3DescriptorMatcher:
                                    colmapMatchOptions.descriptorMatcher == .exact
                                        ? .exact
                                        : nil
                            )
                            try stopIfRequested(after: .sfmMatching)
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
                                message: "DA3 refinement started",
                                details: .sfmMapping(SfmMappingCheckpoint(
                                    mapper: "da3-refined",
                                    sparsePath: try paths.projectRelativePath(for: sparseZero),
                                    registeredImages: nil
                                ))
                            )
                            let mappingAttemptOrdinal = try beginMappingAttempt(
                                activeBackend: .da3,
                                da3DescriptorMatcher:
                                    colmapMatchOptions.descriptorMatcher == .exact
                                        ? .exact
                                        : nil
                            )
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
                            _ = try self.ensureTextSparseModelFiles(at: sparseZero)

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
                                fallbackReason: nil
                            )
                            acceptedReconstructionSummary = ReconstructionSummary(
                                score: score,
                                mapper: "da3-refined",
                                capturedAt: Date()
                            )
                            writeCheckpoint(
                                stage: .sfmMapping,
                                progress: 1.0,
                                message: "DA3 refinement completed",
                                details: .sfmMapping(SfmMappingCheckpoint(
                                    mapper: "da3-refined",
                                    sparsePath: try paths.projectRelativePath(for: sparseZero),
                                    registeredImages: score.registeredImages
                                ))
                            )
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
                guard evidence.pairingPolicy == resolvedRunPlan.pairingPolicy,
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
                pairGraphAttempts = evidence.attempts
                usedLocalVocabularyRetrieval = evidence.usedLocalVocabularyRetrieval
                acceptedPairGraphEvidence = evidence
                matchingDurationSeconds = evidence.matchingDurationSeconds
                pairRecoveryLevel = acceptedRecoveryLevel
                colmapMatchOptions.descriptorMatcher = acceptedAttempt.artifact.matcher
                didRetryWithExactMatcher = acceptedAttempt.artifact.matcher == .exact
                latestPreparedPairPlan = acceptedPlan
                pairAttemptMode = acceptedAttempt.artifact.matcher == .exact
                    ? .sameScheduleExact(acceptedPlan)
                    : .policy
                for reason in evidence.fallbackReasons {
                    recordMappingFallback(reason)
                }
            }

            let selectedImageNames = selectedFrames.map(\.lastPathComponent)
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
                if mode.isPolicyRecovery {
                    return colmapMatchOptions.descriptorMatcher == .faiss
                        ? .policy
                        : .sameScheduleExact
                }
                return .sameScheduleExact
            }

            func persistPairRecoveryIntent(
                mode: PairGraphRecoveryMode,
                activePlan: ColmapPairPlan,
                phase: PairGraphRecoveryPhase = .matching
            ) throws {
                metadata.checkpoint = PipelineCheckpoint(
                    stage: .sfmMatching,
                    updatedAt: Date(),
                    progressFraction: 0,
                    message: "Image matching recovery pending",
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
                    pairingPolicy: resolvedRunPlan.pairingPolicy,
                    mode: mode,
                    computeMode: colmapMatchOptions.useGPU ? .gpu : .cpu,
                    phase: phase,
                    activeRecoveryLevel: pairRecoveryLevel.artifactValue,
                    activePlan: activePlan,
                    attempts: pairGraphAttempts,
                    usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval,
                    matchingDurationSeconds: matchingDurationSeconds,
                    fallbackReasons: mappingFallbackReasons
                )
                try PairGraphRecoveryStore.save(
                    state,
                    to: paths.pairGraphRecoveryURL,
                    projectPaths: paths
                )
                try persistGeometryRecovery(
                    activeBackend: .colmap,
                    pendingPairRecoveryLevel: pairRecoveryLevel.artifactValue
                )
            }

            func persistAttemptRecoveryIntent(
                mode: PairAttemptMode,
                activePlan: ColmapPairPlan
            ) throws {
                if mode.isPolicyRecovery, pairGraphAttempts.isEmpty {
                    return
                }
                let recoveryMode = persistedRecoveryMode(for: mode)
                try persistPairRecoveryIntent(
                    mode: recoveryMode,
                    activePlan: activePlan
                )
            }

            func restorePendingPairRecovery(
                _ recovered: RestoredPairGraphRecovery
            ) throws {
                guard recovered.pairingPolicy == resolvedRunPlan.pairingPolicy else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
                if recovered.computeMode == .cpu {
                    colmapExtractOptions.useGPU = false
                    colmapMatchOptions.useGPU = false
                }
                pairGraphAttempts = recovered.attempts
                usedLocalVocabularyRetrieval = recovered.usedLocalVocabularyRetrieval
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
                    colmapMatchOptions.descriptorMatcher = .exact
                    didRetryWithExactMatcher = true
                    latestPreparedPairPlan = recovered.activePlan
                    pairAttemptMode = .sameScheduleExact(recovered.activePlan)
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
                      Array(evidence.attempts.dropLast()) == recovered.attempts,
                      evidence.usedLocalVocabularyRetrieval
                        == recovered.usedLocalVocabularyRetrieval,
                      evidence.fallbackReasons == recovered.fallbackReasons,
                      let accepted = evidence.attempts.last,
                      accepted.artifact.recoveryLevel == recovered.recoveryLevel,
                      accepted.artifact.outcome == .completed,
                      accepted.scheduledPairs == recovered.activePlan.pairs else {
                    return false
                }
                switch recovered.mode {
                case .policy:
                    return accepted.artifact.matcher == .faiss
                case .sameScheduleExact:
                    return accepted.artifact.matcher == .exact
                }
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
                    if let completedEvidence,
                       evidenceCompletesPendingRecovery(
                        completedEvidence,
                        recovered: recovered
                       ) {
                        try restoreAcceptedPairEvidence(completedEvidence)
                        try persistGeometryRecovery(activeBackend: .colmap)
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
                } catch {
                    try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
                    try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
                    try workerExecutionRecorder.invalidate(startingAt: .sfmMatching)
                    pairGraphAttempts.removeAll(keepingCapacity: true)
                    usedLocalVocabularyRetrieval = false
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
                    try persistGeometryRecovery(activeBackend: .colmap)
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
                    usedLocalVocabularyRetrieval = false
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
                    try persistGeometryRecovery(activeBackend: .colmap)
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
                        "featureExtractionWorkers": "\(colmapExtractOptions.extractThreads)"
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
                try persistGeometryRecovery(activeBackend: .colmap)
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
                    cameraModel: self.cameraModel(
                        detailProfile: metadata.requestedRunOptions.detailProfile,
                        capturePath: resolvedRunPlan.capturePath,
                        lensProjection: resolvedRunPlan.lensProjection
                    ),
                    singleCamera: shareCameraAcrossSelectedFrames,
                    options: colmapExtractOptions,
                    onLog: onFeaturesLog
                )
                let featureImageNames = selectedFrames.map(\.lastPathComponent)
                let featureDatabaseDigest = try ColmapDatabaseDigester
                    .digests(at: paths.colmapDatabaseURL).feature
                try ColmapFeatureEvidenceStore.save(
                    ColmapFeatureEvidence(
                        selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                            orderedImageNames: featureImageNames,
                            projectPaths: paths
                        ),
                        imageNames: featureImageNames,
                        featureDatabaseDigest: featureDatabaseDigest
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
                        imageCount: selectedFrames.count
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
                let groups = try Self.colmapPairGroups(
                    imageNames: imageNames,
                    manifest: selectedFrameManifest
                )
                let attemptNumber = pairGraphAttempts.count + 1
                let attemptClock = ContinuousClock()
                let attemptStart = attemptClock.now
                latestPreparedPairPlan = nil
                latestCompletedPairPlan = nil
                let attemptMode = pairAttemptMode
                var pairPlan = try attemptMode.planOverride
                    ?? Self.baseColmapPairPlan(
                        imageNames: imageNames,
                        groups: groups,
                        resolvedPlan: resolvedRunPlan,
                        recoveryLevel: pairRecoveryLevel
                    )
                func recordPlanningFailure() {
                    let duration = Self.durationInSeconds(attemptClock.now - attemptStart)
                    pairGraphAttempts.append(PairGraphAttemptEvidence(
                        artifact: PairMatchingAttemptArtifact(
                            attemptNumber: attemptNumber,
                            matcher: colmapMatchOptions.descriptorMatcher,
                            recoveryLevel: pairRecoveryLevel.artifactValue,
                            outcome: .failed,
                            scheduledPairCount: pairPlan.pairs.count,
                            attemptedPairCount: 0,
                            rawMatchedPairCount: 0,
                            spatiallyVerifiedPairCount: 0,
                            durationSeconds: duration
                        ),
                        scheduledPairs: pairPlan.pairs
                    ))
                    matchingDurationSeconds += duration
                }
                if attemptMode.planOverride == nil,
                   let request = Self.vocabularyRetrievalRequest(
                    imageNames: imageNames,
                    resolvedPlan: resolvedRunPlan,
                    recoveryLevel: pairRecoveryLevel
                ) {
                    let queryListURL = try self.writeVocabularyQueryList(
                        request.queryImageNames,
                        attemptNumber: attemptNumber,
                        paths: paths
                    )
                    let outputURL = paths.colmapSeedURL.appendingPathComponent(
                        "retrieval_pairs_attempt_\(attemptNumber).txt"
                    )
                    let excludedPairListURL: URL?
                    if pairPlan.pairs.isEmpty {
                        excludedPairListURL = nil
                    } else {
                        excludedPairListURL = try self.writeColmapPairList(
                            pairPlan.pairLines,
                            fileName: "retrieval_exclusions_attempt_\(attemptNumber).txt",
                            paths: paths
                        )
                    }
                    self.removeIfExists(outputURL)
                    emit(.stageProgress(
                        stage: .sfmMatching,
                        fraction: 0,
                        message: "Finding revisited views"
                    ))
                    try await self.tooling.colmap.runLocalVocabularyRetriever(
                        colmapPath: self.config.toolchain.colmap,
                        database: paths.colmapDatabaseURL,
                        outputPairListPath: outputURL,
                        queryImageListPath: queryListURL,
                        excludedPairListPath: excludedPairListURL,
                        options: try ColmapVocabularyRetrievalOptions(
                            candidateCount: request.candidateCount,
                            returnedNeighborCount: request.returnedNeighborCount,
                            minimumFrameSeparation: request.minimumFrameSeparation,
                            threadCount: vocabularyRetrievalWorkers
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
                    usedLocalVocabularyRetrieval = true
                    let retrievalLines = try Self.validatedVocabularyRetrievalPairLines(
                        self.readGeneratedPairLines(from: outputURL),
                        request: request,
                        imageNames: imageNames,
                        excluding: pairPlan
                    )
                    pairPlan = try pairPlan.addingRetrievalPairLines(
                        retrievalLines,
                        pairingPolicy: resolvedRunPlan.pairingPolicy
                    )
                }
                latestPreparedPairPlan = pairPlan
                guard !pairPlan.pairs.isEmpty else {
                    recordPlanningFailure()
                    throw ColmapPairPlanningError.disconnectedPairSchedule
                }
                guard pairPlan.isConnected else {
                    recordPlanningFailure()
                    throw ColmapPairPlanningError.disconnectedPairSchedule
                }
                let attemptConfiguration = [
                    colmapMatchOptions.descriptorMatcher.rawValue,
                    colmapMatchOptions.useGPU ? "gpu" : "cpu",
                    pairPlan.sha256,
                ].joined(separator: ":")
                guard attemptedPairConfigurations.insert(attemptConfiguration).inserted else {
                    recordPlanningFailure()
                    throw ColmapPairPlanningError.repeatedAttempt
                }
                let pairListURL = try self.writeColmapPairPlan(
                    pairPlan,
                    attemptNumber: attemptNumber,
                    paths: paths
                )
                if attemptMode.isPolicyRecovery,
                   colmapMatchOptions.descriptorMatcher == .faiss,
                   !pairGraphAttempts.isEmpty {
                    try persistPairRecoveryIntent(
                        mode: .policy,
                        activePlan: pairPlan
                    )
                } else {
                    try persistAttemptRecoveryIntent(
                        mode: attemptMode,
                        activePlan: pairPlan
                    )
                }
                try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
                if pendingMatchingResetMessage == nil {
                    try ColmapDatabaseMatchStore.clearMatchingResults(
                        at: paths.colmapDatabaseURL
                    )
                } else {
                    try resetMatchingIfNeeded()
                }
                emit(.stageLog(
                    stage: .sfmMatching,
                    line: "Pair graph: \(pairPlan.localPairCount) local, \(pairPlan.retrievalPairCount) retrieval, \(pairPlan.loopRevisitPairCount) revisit (\(pairPlan.pairs.count) total).",
                    isError: false
                ))

                let inspection: ColmapPairGraphInspection
                do {
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
                                options: colmapMatchOptions,
                                onLog: onLog
                            )
                        },
                        emit: emit
                    )
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
                    if matcherError is CancellationError { throw matcherError }
                    try Task.checkCancellation()
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
                            scheduledPairCount: pairPlan.pairs.count,
                            attemptedPairCount: partialInspection?.attemptedPairCount ?? 0,
                            rawMatchedPairCount: partialInspection?.rawMatchedPairCount ?? 0,
                            spatiallyVerifiedPairCount: partialInspection?.spatiallyVerifiedPairCount ?? 0,
                            durationSeconds: duration
                        ),
                        scheduledPairs: pairPlan.pairs
                    ))
                    matchingDurationSeconds += duration
                    if attemptMode.isPolicyRecovery,
                       colmapMatchOptions.descriptorMatcher == .faiss {
                        try persistPairRecoveryIntent(
                            mode: .policy,
                            activePlan: pairPlan
                        )
                    } else {
                        try persistAttemptRecoveryIntent(
                            mode: attemptMode,
                            activePlan: pairPlan
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
                pairGraphAttempts.append(PairGraphAttemptEvidence(
                    artifact: PairMatchingAttemptArtifact(
                        attemptNumber: attemptNumber,
                        matcher: colmapMatchOptions.descriptorMatcher,
                        recoveryLevel: pairRecoveryLevel.artifactValue,
                        outcome: graphWasAccepted ? .completed : .rejected,
                        scheduledPairCount: inspection.scheduledPairCount,
                        attemptedPairCount: inspection.attemptedPairCount,
                        rawMatchedPairCount: inspection.rawMatchedPairCount,
                        spatiallyVerifiedPairCount: inspection.spatiallyVerifiedPairCount,
                        durationSeconds: duration
                    ),
                    scheduledPairs: pairPlan.pairs
                ))
                matchingDurationSeconds += duration
                latestCompletedPairPlan = pairPlan
                guard graphWasAccepted else {
                    if attemptMode.isPolicyRecovery,
                       colmapMatchOptions.descriptorMatcher == .faiss {
                        try persistPairRecoveryIntent(
                            mode: .policy,
                            activePlan: pairPlan
                        )
                    } else {
                        try persistAttemptRecoveryIntent(
                            mode: attemptMode,
                            activePlan: pairPlan
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
                    attempts: pairGraphAttempts,
                    acceptedAttemptNumber: attemptNumber,
                    acceptedInspection: inspection,
                    usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval,
                    matchingDurationSeconds: matchingDurationSeconds,
                    fallbackReasons: mappingFallbackReasons
                )
                try PairGraphEvidenceStore.save(
                    evidence,
                    to: paths.pairGraphEvidenceURL,
                    projectPaths: paths
                )
                acceptedPairGraphEvidence = evidence
                try persistGeometryRecovery(activeBackend: .colmap)
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
                        activePlan: activePlan
                    )
                } else if let activePlan = latestPreparedPairPlan,
                          !pairGraphAttempts.isEmpty {
                    try persistPairRecoveryIntent(
                        mode: .policy,
                        activePlan: activePlan
                    )
                } else {
                    try persistGeometryRecovery(
                        activeBackend: .colmap,
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
                ) else {
                    return false
                }
                guard let recoverySourcePlan = latestCompletedPairPlan
                        ?? latestPreparedPairPlan else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                pairRecoveryLevel = next
                pairAttemptMode = .policy
                latestPreparedPairPlan = nil
                latestCompletedPairPlan = nil
                acceptedPairGraphEvidence = nil
                recordMappingFallback(reason)
                let recoveryMode: PairGraphRecoveryMode =
                    colmapMatchOptions.descriptorMatcher == .exact
                        ? .sameScheduleExact
                        : .policy
                try persistPairRecoveryIntent(
                    mode: recoveryMode,
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
                               currentMatcher: colmapMatchOptions.descriptorMatcher
                           ) {
                            didRetryWithExactMatcher = true
                            colmapMatchOptions.descriptorMatcher = .exact
                            pairAttemptMode = .sameScheduleExact(sourcePlan)
                            recordMappingFallback("exact descriptor matching")
                            try persistAttemptRecoveryIntent(
                                mode: pairAttemptMode,
                                activePlan: sourcePlan
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
                        let pairPlanningError = error as? ColmapPairPlanningError
                        if pairPlanningError == .repeatedAttempt,
                           try advancePairRecovery("Image retrieval repeated the previous pair graph") {
                            forceSfMRun = false
                            forceMatchingRun = true
                            continue
                        }
                        if (pairPlanningError == .disconnectedPairSchedule
                                || pairPlanningError == .disconnectedVerifiedGraph),
                           try advancePairRecovery("Image matching did not produce a connected graph") {
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
                           (pairPlanningError == .repeatedAttempt
                               || (pairPlanningError == .disconnectedVerifiedGraph
                                   && Self.nextPairRecoveryLevel(
                                       after: pairRecoveryLevel,
                                       imageCount: selectedFrames.count,
                                       pairingPolicy: resolvedRunPlan.pairingPolicy
                                   ) == nil)) {
                            guard let sourcePlan = pairPlanningError == .disconnectedVerifiedGraph
                                ? latestCompletedPairPlan
                                : latestPreparedPairPlan else {
                                throw PairGraphEvidenceStoreError.invalidEvidence
                            }
                            let nextMode = PairAttemptMode.sameScheduleExact(sourcePlan)
                            didRetryWithExactMatcher = true
                            colmapMatchOptions.descriptorMatcher = .exact
                            pairAttemptMode = nextMode
                            recordMappingFallback("exact descriptor matching")
                            try persistAttemptRecoveryIntent(
                                mode: nextMode,
                                activePlan: nextMode.planOverride ?? sourcePlan
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
                        message: "Camera mapping started",
                        details: .sfmMapping(SfmMappingCheckpoint(
                            mapper: "colmap",
                            sparsePath: try paths.projectRelativePath(
                                for: paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                            ),
                            registeredImages: nil
                        ))
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
                        var snapshots: [Int: MappedSparseModelSnapshot] = [:]
                        snapshots.reserveCapacity(modelDirectories.count)
                        for model in modelDirectories {
                            snapshots[model.order] = try self.captureMappedSparseModel(
                                at: model.url
                            )
                        }
                        let memberships = try ColmapSparseModelMembershipReader(
                            databaseURL: paths.colmapDatabaseURL,
                            selectedImageNames: selectedFrames.map(\.lastPathComponent)
                        ).read(
                            modelDirectories: modelDirectories.map(\.url),
                            checkCancellation: self.tooling.checkCancellation
                        )
                        for model in modelDirectories {
                            guard let snapshot = snapshots[model.order] else {
                                throw PipelineError.outputMissing
                            }
                            try self.validateMappedSparseModel(snapshot, at: model.url)
                        }
                        let membershipByOrder = Dictionary(
                            uniqueKeysWithValues: memberships.models.map {
                                ($0.modelOrder, $0.imageIDs)
                            }
                        )
                        var candidates: [MappedSparseModelCandidate] = []
                        candidates.reserveCapacity(modelDirectories.count)
                        var firstAnalysisError: Error?
                        for model in modelDirectories {
                            try Task.checkCancellation()
                            do {
                                guard let snapshot = snapshots[model.order],
                                      let membership = membershipByOrder[model.order] else {
                                    throw PipelineError.outputMissing
                                }
                                let report = try await self.tooling.colmap.runModelAnalyzer(
                                    colmapPath: self.config.toolchain.colmap,
                                    modelPath: model.url,
                                    environment: [:]
                                )
                                try Task.checkCancellation()
                                try self.validateMappedSparseModel(snapshot, at: model.url)
                                for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                                    colmapToolLog.append(stream: "stdout", line: String(line))
                                }
                                let score = ReconstructionScorer.applyingExpectedTotalImages(
                                    ReconstructionScorer.parseModelAnalyzerOutput(report),
                                    expectedTotalImages: selectedFrames.count
                                )
                                guard score.registeredImages == membership.count else {
                                    throw PipelineError.geometryRegisteredImagesMismatch
                                }
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
                        var residualValidatedModelOrders: Set<Int> = []
                        if candidates.count > 1 {
                            for candidate in candidates {
                                guard let imageIDs = membershipByOrder[candidate.order],
                                      Self.credibleFragmentCandidate(
                                        candidate,
                                        imageIDs: imageIDs,
                                        totalSelectedViewCount: selectedFrames.count
                                      ) else {
                                    continue
                                }
                                do {
                                    _ = try self.ensureTextSparseModelFiles(at: candidate.url)
                                    let measurement = try self.validatedGeometryMeasurement(
                                        modelDirectory: candidate.url,
                                        selectedFrames: selectedFrames,
                                        minimumRegisteredViewCount: candidate.score.registeredImages,
                                        requireStrongObservationCoverage: false
                                    )
                                    guard measurement.residuals.registeredViewCount
                                            == candidate.score.registeredImages else {
                                        throw PipelineError.geometryRegisteredImagesMismatch
                                    }
                                    residualValidatedModelOrders.insert(candidate.order)
                                } catch {
                                    if error is CancellationError { throw error }
                                    try Task.checkCancellation()
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "Ignored COLMAP model \(candidate.order) as fragmentation evidence because its measured tracks did not validate.",
                                        isError: false
                                    ))
                                }
                            }
                        }
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
                                _ = try self.ensureTextSparseModelFiles(
                                    at: selected.url
                                )
                                _ = try self.validatedGeometryMeasurement(
                                    modelDirectory: selected.url,
                                    selectedFrames: selectedFrames,
                                    requireStrongObservationCoverage: false
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
                                let selectedSnapshot = try self.captureMappedSparseModel(
                                    at: selected.url
                                )
                                writeCheckpoint(
                                    stage: .sfmMapping,
                                    progress: 0.95,
                                    message: "Mapping score: \(ReconstructionScorer.summary(score))",
                                    details: .sfmMapping(SfmMappingCheckpoint(
                                        mapper: "colmap",
                                        sparsePath: try paths.projectRelativePath(
                                            for: selected.url
                                        ),
                                        registeredImages: score.registeredImages
                                    ))
                                )
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
                                    incrementalCadence: cadence,
                                    fallbackReason: nil
                                )
                                self.warnIfWeakAcceptedSolve(
                                    score: score,
                                    mapper: "colmap",
                                    emit: emit
                                )
                                acceptedReconstructionSummary = ReconstructionSummary(
                                    score: score,
                                    mapper: "colmap",
                                    capturedAt: Date()
                                )
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
                        acceptedReconstructionSummary = nil
                        do {
                            let mappingAttemptOrdinal = try beginMappingAttempt(
                                activeBackend: .colmap
                            )
                            try self.resetDirectory(paths.colmapSparseURL)
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
                                onLog: { line, isErr in
                                    colmapToolLog.append(
                                        stream: isErr ? "stderr" : "stdout",
                                        line: line
                                    )
                                    onMappingLog(line, isErr)
                                }
                            )
                            mappingSucceeded = try await evaluateMappingResult(
                                mappingAttemptOrdinal: mappingAttemptOrdinal,
                                acceptedRefinementInvocationCount:
                                    mappingProgress.globalRefinementInvocationCount,
                                cadence: cadence
                            )
                        } catch {
                            if error is CancellationError { throw error }
                            try Task.checkCancellation()
                            lastMappingError = Self.normalizedUnusableSparseModelError(error)
                        }
                        if mappingSucceeded {
                            break mappingAttemptLoop
                        }
                        guard cadence == .orderedFast,
                              let reason = Self.conservativeCadenceFallbackReason(
                                after: lastMappingError
                              ) else {
                            break mappingAttemptLoop
                        }
                        activeIncrementalCadence = .conservative
                        recordMappingFallback(reason)
                        try persistGeometryRecovery(activeBackend: .colmap)
                        try self.resetDirectory(paths.colmapSparseURL)
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "The fast camera solve missed a geometry gate. Retrying the accepted image graph with conservative refinement.",
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

                    if !mappingSucceeded,
                       Self.shouldRecoverPairGraph(after: lastMappingError),
                       !didRetryWithExactMatcher,
                       colmapMatchOptions.descriptorMatcher == .faiss,
                       Self.nextPairRecoveryLevel(
                           after: pairRecoveryLevel,
                           imageCount: selectedFrames.count,
                           pairingPolicy: resolvedRunPlan.pairingPolicy
                       ) == nil {
                        guard let sourcePlan = latestPreparedPairPlan else {
                            throw PairGraphEvidenceStoreError.invalidEvidence
                        }
                        suspendStageTimingForRetry(.sfmMapping)
                        didRetryWithExactMatcher = true
                        colmapMatchOptions.descriptorMatcher = .exact
                        pairAttemptMode = .sameScheduleExact(sourcePlan)
                        recordMappingFallback("exact descriptor matching")
                        try persistAttemptRecoveryIntent(
                            mode: pairAttemptMode,
                            activePlan: sourcePlan
                        )
                        try self.resetDirectory(paths.colmapSparseURL)
                        acceptedPairGraphEvidence = nil
                        emit(.stageLog(
                            stage: .sfmMatching,
                            line: "The densest FAISS solve did not produce one acceptable camera solve. Retrying the same schedule with exact descriptor matching.",
                            isError: true
                        ))
                        forceSfMRun = false
                        forceMatchingRun = true
                        continue sfmAttemptLoop
                    }

                    guard mappingSucceeded else {
                        if let pipelineError = lastMappingError as? PipelineError,
                           case .fragmentedReconstruction = pipelineError {
                            let message = failureMessages(
                                for: pipelineError,
                                stage: .sfmMapping
                            )
                            emitFailure(
                                stage: .sfmMapping,
                                userMessage: message.userMessage,
                                debugMessage: message.debugMessage
                            )
                            throw pipelineError
                        }
                        let debugMessage: String
                        if let pipelineError = lastMappingError as? PipelineError,
                           case let .lowQualityReconstruction(score, _) = pipelineError {
                            let summary = ReconstructionScorer.summary(score)
                            debugMessage = "Low-quality reconstruction. \(summary). Last attempt: colmap."
                        } else if let colmapError = lastMappingError as? ColmapRunnerError {
                            debugMessage = debugDescription(for: colmapError)
                        } else {
                            debugMessage = "\(lastMappingError ?? PipelineError.lowQualityReconstruction(.init(registeredImages: 0, totalImages: 0, meanReprojectionError: nil), mapper: nil))"
                        }
                        let userMessage = "The camera solve was unstable. Try a slower capture with more light."
                        emitFailure(
                            stage: .sfmMapping,
                            userMessage: userMessage,
                            debugMessage: debugMessage
                        )
                        throw lastMappingError ?? PipelineError.lowQualityReconstruction(.init(registeredImages: 0, totalImages: 0, meanReprojectionError: nil), mapper: nil)
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
                    let finalSparseModel = canonicalSparseModel
                    writeCheckpoint(
                        stage: .sfmMapping,
                        progress: 1.0,
                        message: "Camera mapping completed",
                        details: .sfmMapping(SfmMappingCheckpoint(
                            mapper: "colmap",
                            sparsePath: try paths.projectRelativePath(for: finalSparseModel),
                            registeredImages: nil
                        ))
                    )
                }

                break
            }
            }

            try Task.checkCancellation()
            // Geometry reconciliation is part of the durable mapping boundary even
            // when resume validation skipped the mapper subprocess itself.
            currentStage = .sfmMapping
            var mappingDurationText: String?
            if acceptedReconstructionSummary != nil
                || metadata.geometryArtifact == nil
                || !FileManager.default.fileExists(atPath: paths.geometryManifestURL.path) {
                guard let mapper = (acceptedReconstructionSummary ?? metadata.reconstruction)?.mapper else {
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
                        expectedPrimaryModelSubdirectory: da3Config.modelSubdirectory,
                        expectedFallbackModelSubdirectory: da3Config.fallbackModelSubdirectory
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
                if mapper.lowercased().contains("da3") {
                    measuredPairGraph = .notEvaluated()
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
                try persistMeasuredGeometryArtifact(
                    metadata: &metadata,
                    paths: paths,
                    resolvedPlan: resolvedRunPlan,
                    mapper: mapper,
                    acceptedDa3ModelSubdirectory: acceptedDa3ModelSubdirectory,
                    selectedFrames: selectedFrames,
                    selectedFrameManifest: currentSelectedFrameManifest,
                    peakMemoryBytes: geometryPeakMemoryBytes,
                    pairGraph: measuredPairGraph,
                    mapping: measuredMapping,
                    workerExecution: try workerExecutionRecorder.validatedArtifact(),
                    acceptedReconstructionSummary: acceptedReconstructionSummary,
                    currentMappingDurationSeconds: {
                        stageTiming.elapsedSeconds(.sfmMapping)
                    }
                )
            } else {
                let artifact = try GeometryArtifactStore.load(
                    from: paths.geometryManifestURL,
                    projectPaths: paths
                )
                if metadata.geometryArtifact != artifact {
                    metadata.geometryArtifact = artifact
                    try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
                }
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
                let isLast = index == backendOrder.count - 1
                if isLast {
                    throw error
                }
                let nextBackend = backendOrder[index + 1]
                recordMappingFallback("\(backendPolicy.rawValue) fallback to \(nextBackend.rawValue)")
                let debug = failureMessages(for: error, stage: .sfmFeatures).debugMessage
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "\(backendName(backendPolicy)) failed (\(debug)). Falling back to \(backendName(nextBackend)).",
                    isError: true
                ))
                try cleanForRetry(failedStage: .sfmFeatures, paths: paths)
                try paths.ensureDirectories()
                try persistGeometryRecovery(activeBackend: nextBackend)
                continue
            }
            break
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
                    guard let geometryArtifact = metadata.geometryArtifact else {
                        throw PipelineError.outputMissing
                    }
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
                            metadata: metadata,
                            paths: paths,
                            profile: detailProfile,
                            cameraOrderSeed: cameraOrderSeed,
                            resolvedPlan: resolvedRunPlan,
                            datasetIdentity: datasetIdentity
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
                    var activeResumeURL = resumeURL
                    while completedTrainingResult == nil {
                        do {
                            try paths.ensureMutableTrainingDirectories()
                            completedTrainingResult = try await self.tooling.msplat.runTrain(
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
                                memoryBudgetBytes: resolvedRunPlan.trainerMemoryBudgetBytes,
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
                                            datasetIdentity: datasetIdentity,
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
                                datasetIdentity: datasetIdentity,
                                paths: paths
                            )
                            metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
                            throw CancellationError()
                        }
                    }
                    guard let trainingResult = completedTrainingResult else {
                        throw PipelineError.outputMissing
                    }
                    guard ProjectArtifactValidator.validatePlyFile(at: outputURL) == .valid else {
                        throw PipelineError.outputMissing
                    }
                    try persistMsplatCompletion(
                        trainingResult,
                        profile: detailProfile,
                        cameraOrderSeed: cameraOrderSeed,
                        resolvedPlan: resolvedRunPlan,
                        datasetIdentity: datasetIdentity,
                        paths: paths
                    )
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
                let outputDirectory = try paths.resolveProjectRelativePath("Output")
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let outputPly = try paths.resolveProjectRelativePath("Output/splat.ply")
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

            metadata.trainingArtifact = try promoteMsplatCompletionToPublicOutput(paths: paths)
            metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
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
