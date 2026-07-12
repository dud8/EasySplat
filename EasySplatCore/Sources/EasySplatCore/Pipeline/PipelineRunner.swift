import Foundation
import Dispatch
public final class PipelineRunner: @unchecked Sendable {

    private struct DevelopmentStop: Error {}

    public struct Tooling {
        public var colmap: ColmapRunner
        public var msplat: MsplatRunner
        public var da3Sfm: Da3SfmRunning

        public init(colmap: ColmapRunner = ColmapRunner(),
                    msplat: MsplatRunner = MsplatRunner(),
                    da3Sfm: Da3SfmRunning = Da3SfmRunner()) {
            self.colmap = colmap
            self.msplat = msplat
            self.da3Sfm = da3Sfm
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.msplat = MsplatRunner(runner: runner)
            self.da3Sfm = Da3SfmRunner(runner: runner)
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
            developmentOverrides: config.developmentOverrides
        )
        let resolvedRunPlan = config.resolvedRunPlan ?? hardwareResolvedRunPlan
        let planChangedForCurrentHardware = previousResolvedRunPlan != nil
            && previousResolvedRunPlan != resolvedRunPlan
        if metadata.resolvedRunPlan != resolvedRunPlan {
            metadata.resolvedRunPlan = resolvedRunPlan
            try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        }
        var trainingManifestWarning: String?
        do {
            _ = try TrainingArtifactStore.reconcile(metadata: &metadata, paths: paths)
        } catch {
            trainingManifestWarning = error.localizedDescription
        }
        let metadataForResumeValidation = metadata

        // Now we've committed to a new run: reset per-tool logs so users see only the
        // current attempt. ToolLogWriter is now an appender (so multiple stages within
        // one run share a file cleanly); the orchestrator owns the cross-run truncation.
        Self.resetPerRunToolLogs(at: paths)
        let logger = PipelineLogger(eventsURL: paths.eventsLogURL, logURL: paths.pipelineLogURL, emit: events)
        var currentStage: PipelineStage = .importInput
        var didEmitFailure = false
        var didRetryWithFewerFrames = false
        var didRetryWithCpu = false
        var didRetryWithHigherSequentialOverlap = false
        var forceExhaustiveMatching = false
        var disableGlobalMapperForThisRun = false
        var lastUsedSequentialMatcher = false
        var lastExpectedMatchingPairs = 0
        let effectiveLastCompletedStage = RunPlanResolver.safeResumeStage(
            lastCompletedStage,
            input: metadata.input,
            previousPlan: planChangedForCurrentHardware ? previousResolvedRunPlan : resolvedRunPlan,
            currentPlan: resolvedRunPlan
        )
        let resumeValidationMode = effectiveLastCompletedStage != nil
        let hasInterruptionEvidence = metadata.checkpoint != nil || metadata.lastRunStartedAt != nil
        let wasInterrupted = metadata.state.lastError == nil
            && metadata.state.stage != .done
            && hasInterruptionEvidence
        let skipTraining = config.developmentOverrides.skipTraining

        metadata.lastRunStartedAt = Date()
        try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)

        if metadata.state.lastError != nil {
            try? cleanForRetry(failedStage: metadata.state.stage, paths: paths)
            try? paths.ensureDirectories()
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

        func stageIndex(_ stage: PipelineStage) -> Int {
            PipelineStage.allCases.firstIndex(of: stage) ?? 0
        }

        var reranStageBeforeTraining = false

        func markStageForRerun(_ stage: PipelineStage) throws -> Bool {
            guard stageIndex(stage) < stageIndex(.trainSplat) else { return true }
            guard !reranStageBeforeTraining else { return true }
            reranStageBeforeTraining = true
            removeIfExists(paths.trainingURL)
            if metadata.trainingArtifact != nil {
                metadata.trainingArtifact = nil
                try ProjectMetadataStore.savePreservingUserEditableFields(
                    metadata,
                    to: paths.metadataURL
                )
            }
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
            guard let lastCompletedStage = effectiveLastCompletedStage else { return true }
            let validationMetadata = resumeValidationMode ? metadataForResumeValidation : metadata
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
                    return try markStageForRerun(stage)
                case .corrupt(let reason):
                    emit(.stageLog(
                        stage: stage,
                        line: "Detected partial/corrupt stage output for resume (\(reason)). Re-running \(stage.displayName).",
                        isError: true
                    ))
                    try? cleanForRetry(failedStage: stage, paths: paths)
                    try? paths.ensureDirectories()
                    return try markStageForRerun(stage)
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
            var colmapMaxImageSize = Int(maxDim)
            var colmapExtractOptions = colmapOptionsForExtraction()
            var colmapMatchOptions = colmapOptionsForMatching()
            let preferColmapGpu = shouldUseColmapGpu(colmapPath: config.toolchain.colmap)
            colmapExtractOptions.useGPU = preferColmapGpu
            colmapMatchOptions.useGPU = preferColmapGpu
            let colmapThreads = min(
                max(1, ProcessInfo.processInfo.activeProcessorCount),
                resolvedRunPlan.colmapThreadLimit
            )
            colmapExtractOptions.maxNumFeatures = resolvedRunPlan.colmapMaximumFeatureCount
            colmapMatchOptions.maxNumFeatures = resolvedRunPlan.colmapMaximumFeatureCount
            colmapMatchOptions.maxNumMatches = resolvedRunPlan.colmapMaximumMatchCount
            colmapMatchOptions.exhaustiveBlockSize = resolvedRunPlan.colmapExhaustiveBlockSize
            colmapExtractOptions.extractThreads = colmapThreads
            colmapMatchOptions.matchThreads = colmapThreads
            updateThreadEnvironment(&colmapExtractOptions, threadCount: colmapThreads)
            updateThreadEnvironment(&colmapMatchOptions, threadCount: colmapThreads)
            var selectedFrames: [URL] = []
            var selectedFrameManifest: [SelectedFrameMapping] = []
            if metadata.input.hasVideos {
                if try shouldRunStage(.extractFrames) {
                    currentStage = .extractFrames
                    emit(.stageStarted(stage: .extractFrames))
                    writeCheckpoint(stage: .extractFrames, progress: 0, message: "Frame extraction started")
                    emit(.stageLog(
                        stage: .extractFrames,
                        line: "Target frames: \(targetFrames).",
                        isError: false
                    ))
                    let extractor = FrameExtractor()
                    let videos = metadata.input.videoFiles
                    let importedVideos = importedVideoURLs(for: videos, paths: paths)
                    let totalVideos = Double(max(videos.count, 1))
                    for (index, file) in videos.enumerated() {
                        try Task.checkCancellation()
                        let sourceName = URL(fileURLWithPath: file).lastPathComponent
                        let videoURL = importedVideos[index]
                        let perVideoTarget = targetCountForVideo(index: index, total: videos.count, targetCount: targetFrames)
                        if perVideoTarget == 0 {
                            continue
                        }
                        let perVideoExtractionCap = frameProfile.maxExtractedFrames.map {
                            targetCountForVideo(index: index, total: videos.count, targetCount: $0)
                        }
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Extracting frames from \(sourceName) (target=\(perVideoTarget), maxDim=\(Int(maxDim))px, rawCap=\(perVideoExtractionCap.map(String.init) ?? "none")).",
                            isError: false
                        ))
                        let rawDir = rawFramesDirectory(index: index, paths: paths)
                        try self.resetDirectory(rawDir)
                        let extracted = try await extractor.extractFrames(
                            from: videoURL,
                            to: rawDir,
                            options: FrameExtractionOptions(
                                targetCount: perVideoTarget,
                                maxDimension: maxDim,
                                targetFPS: frameProfile.targetFPS,
                                minDistanceRatio: frameProfile.minDistanceRatio,
                                sharpnessFloor: frameProfile.sharpnessFloor,
                                sharpnessRatio: frameProfile.sharpnessRatio,
                                outputFormat: frameProfile.outputFormat,
                                maxExtractedFrames: perVideoExtractionCap
                            ),
                            progress: { fraction, message in
                                let scaled = (Double(index) / totalVideos) + (fraction / totalVideos)
                                emit(.stageProgress(stage: .extractFrames, fraction: scaled, message: message))
                            }
                        )
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Wrote \(extracted.count) extracted frame(s) from \(sourceName).",
                            isError: false
                        ))
                        writeCheckpoint(
                            stage: .extractFrames,
                            progress: Double(index + 1) / totalVideos,
                            message: "Extracted \(extracted.count) frames from \(sourceName)",
                            details: .extractFrames(ExtractFramesCheckpoint(
                                videoIndex: index,
                                videoName: sourceName,
                                extractedCount: extracted.count,
                                targetCount: perVideoTarget
                            ))
                        )
                    }
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
                        let videos = metadata.input.videoFiles
                        let totalVideos = Double(max(videos.count, 1))
                        for (index, _) in videos.enumerated() {
                            try Task.checkCancellation()
                            let rawDir = rawFramesDirectory(index: index, paths: paths)
                            let rawFrames = try loadImages(in: rawDir)
                            guard !rawFrames.isEmpty else { continue }
                            let sharpnessByFrame = try scoreSharpnessForFrames(
                                rawFrames,
                                progress: { fraction, message in
                                    let scaled = (Double(index) / totalVideos) + (fraction / totalVideos)
                                    emit(.stageProgress(stage: .selectFrames, fraction: scaled, message: message))
                                }
                            )
                            let filterResult = filterVeryBlurryVideoFrames(
                                frames: rawFrames,
                                sharpnessByFrame: sharpnessByFrame,
                                profile: frameProfile,
                                maxDropFraction: 0.25,
                                floorScale: 0.5
                            )
                            let chosen = filterResult.frames
                            if !chosen.isEmpty {
                                let groupId = String(format: "video_%03d", index)
                                groups.append(.init(id: groupId, frames: chosen, isVideo: true))
                                if filterResult.dropped > 0 {
                                    emit(.stageLog(
                                        stage: .selectFrames,
                                        line: "Filtered \(filterResult.dropped) very blurry frame(s) from \(groupId) (kept \(chosen.count) of \(rawFrames.count)).",
                                        isError: false
                                    ))
                                } else {
                                    emit(.stageLog(
                                        stage: .selectFrames,
                                        line: "Kept all extracted frames from \(groupId) (no downsampling).",
                                        isError: false
                                    ))
                                }
                            }
                        }
                    }

                    if metadata.input.photosFolder != nil {
                        let sourceFolder = paths.importedPhotosURL
                        let discoveredPhotos = try loadPhotos(in: sourceFolder)
                        let photoFilter = try filterValidUniquePhotos(discoveredPhotos)
                        if !photoFilter.frames.isEmpty {
                            groups.append(.init(id: "photos", frames: photoFilter.frames, isVideo: false))
                            emit(.stageLog(
                                stage: .selectFrames,
                                line: "Using \(photoFilter.frames.count) valid, unique photos from \(sourceFolder.lastPathComponent).",
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
                    if metadata.input.hasVideos {
                        removeIfExists(paths.framesRawURL)
                    }
                    try stopIfRequested(after: .selectFrames)
                }
            }

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
            if selectedFrames.count < 2 {
                throw PipelineError.insufficientInputImages(selectedFrames.count)
            }

            let geometryMemorySampler = GeometryMemorySampler()
            geometryMemorySampler.start()
            defer { geometryMemorySampler.cancel() }

            if resolvedRunPlan.sequentialOverlap > 0 {
                colmapExtractOptions.sequentialOverlap = resolvedRunPlan.sequentialOverlap
                colmapMatchOptions.sequentialOverlap = resolvedRunPlan.sequentialOverlap
            }

            try Task.checkCancellation()
            let da3WindowSize = resolvedRunPlan.chunkSize
            let backendOrder = try sfmBackendFallbackOrder(resolvedPlan: resolvedRunPlan)

            let backendName: (SfmBackend) -> String = { backend in
                switch backend {
                case .da3:
                    return "Depth Anything 3"
                case .colmap:
                    return "COLMAP"
                }
            }

            var acceptedReconstructionSummary: ReconstructionSummary?
            for (index, backendPolicy) in backendOrder.enumerated() {
                // Reset accepted-quality state at the start of every backend attempt so a
                // partial failure from the previous backend cannot leak its score/summary
                // into a later backend's successful run.
                acceptedReconstructionSummary = nil
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
                            processResolution: da3ProcessResolutionPreference(),
                            maxPoints: da3MaxPointsPreference(
                                detailProfile: metadata.requestedRunOptions.detailProfile
                            ),
                            cameraType: da3CameraTypePreference(
                                detailProfile: metadata.requestedRunOptions.detailProfile,
                                capturePath: resolvedRunPlan.capturePath,
                                lensProjection: resolvedRunPlan.lensProjection
                            ),
                            sharedCamera: da3SharedCameraPreference(
                                input: metadata.input,
                                cameraGrouping: resolvedRunPlan.cameraGrouping
                            ),
                            inputOrdering: da3InputOrdering,
                            windowSize: effectiveDa3WindowSize,
                            windowOverlap: da3SeedWindowOverlap(
                                windowSize: effectiveDa3WindowSize,
                                hardwareTier: detectedHardwareProfile.tier
                            ),
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
                                options: colmapMatchOptions
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
                                line: "DA3 policy: aligned seed, ordering=\(da3Config.inputOrdering.rawValue) model=\(da3Config.modelSubdirectory) fallback=\(da3Config.fallbackModelSubdirectory) device=\(da3Config.device) processRes=\(da3Config.processResolution) maxPoints=\(da3Config.maxPoints) sharedCamera=\(da3Config.sharedCamera) cameraType=\(da3Config.cameraType) window=\(da3Config.windowSize) overlap=\(da3Config.windowOverlap).",
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

                            emit(.stageProgress(stage: .sfmFeatures, fraction: 0.0, message: "Starting DA3 aligned seed solve (\(selectedFrames.count) images)…"))
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
                            let imagesTxt = seedZero.appendingPathComponent("images.txt")
                            if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                                emit(.stageLog(
                                    stage: .sfmFeatures,
                                    line: "Normalized DA3 aligned seed COLMAP model (added missing POINTS2D lines to images.txt).",
                                    isError: false
                                ))
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

                            let seedManifest = try readDa3CoverageManifest(required: true)
                            guard let localPairs = seedManifest?.boundedMatchPairs,
                                  !localPairs.isEmpty else {
                                throw PipelineError.outputMissing
                            }
                            let includesLoopClosures = da3Config.inputOrdering == .continuous
                            let loopPairs: [String]
                            if includesLoopClosures {
                                let descriptors = try ColmapPairEstimator.imageDescriptors(for: selectedFrames)
                                loopPairs = try ColmapPairEstimator.orderedLoopPairs(
                                    imageNames: selectedFrames.map(\.lastPathComponent),
                                    descriptors: descriptors,
                                    minimumSeparation: max(
                                        da3ColmapMatchOptions.sequentialOverlap + 1,
                                        selectedFrames.count / 5
                                    )
                                )
                            } else {
                                loopPairs = []
                            }
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
                            try await self.tooling.colmap.runMatchesImporter(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                matchListPath: matchListURL,
                                matchType: "pairs",
                                options: da3ColmapMatchOptions,
                                onLog: matcherLog
                            )
                            lastUsedSequentialMatcher = false
                            let expectedPairs = pairPlan.pairs.count
                            let processedPairs = (try? ColmapDatabaseProgressPoller(
                                databasePath: paths.colmapDatabaseURL
                            ).readProcessedPairCount()) ?? 0
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
                            try stopIfRequested(after: .sfmMatching)
                        }

                        if try shouldRunStage(.sfmMapping) {
                            completedMappingThisAttempt = true
                            currentStage = .sfmMapping
                            emit(.stageStarted(stage: .sfmMapping))
                            guard sparseModelFilesExist(at: seedZero) else {
                                throw PipelineError.outputMissing
                            }
                            if try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                                seedModelURL: seedZero,
                                databaseURL: paths.colmapDatabaseURL
                            ) {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Aligned DA3 seed IDs with the COLMAP feature database.",
                                    isError: false
                                ))
                            }
                            try self.resetDirectory(paths.colmapSparseURL)
                            try self.resetDirectory(sparseZero)
                            let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                            colmapToolLog.beginSection(
                                title: "da3_refinement",
                                metadata: [
                                    "database": paths.colmapDatabaseURL.path,
                                    "images": paths.framesSelectedURL.path,
                                    "seed": seedZero.path,
                                    "output": sparseZero.path,
                                    "tool": self.config.toolchain.colmap.path
                                ]
                            )
                            emit(.stageLog(stage: .sfmMapping, line: "Running DA3 refinement: point_triangulator.", isError: false))
                            try await self.tooling.colmap.runPointTriangulator(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                inputPath: seedZero,
                                outputPath: sparseZero,
                                options: da3ColmapMatchOptions,
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
                                options: da3ColmapMatchOptions,
                                bundleOptions: ColmapBundleAdjustmentOptions(
                                    maxNumIterations: resolvedRunPlan.refinementIterationLimit
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

                            let score = try await analyzeDa3Model(
                                at: sparseZero,
                                toolLog: colmapToolLog
                            )
                            guard ReconstructionScorer.isAcceptable(
                                score,
                                capturePath: resolvedRunPlan.capturePath
                            ),
                                  let residual = score.meanReprojectionError,
                                  residual.isFinite else {
                                throw PipelineError.lowQualityReconstruction(score, mapper: "da3-refined")
                            }
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
            let runFeatures: (Bool) async throws -> Void = { force in
                guard try (force || shouldRunStage(.sfmFeatures)) else { return }
                currentStage = .sfmFeatures
                emit(.stageStarted(stage: .sfmFeatures))
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "SfM backend: COLMAP global mapper, with COLMAP mapper fallback.",
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
                        "threads": "\(colmapExtractOptions.extractThreads)"
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
                self.removeIfExists(paths.colmapDatabaseURL)
                try self.resetDirectory(paths.colmapSparseURL)
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
                    singleCamera: self.da3SharedCameraPreference(
                        input: metadata.input,
                        cameraGrouping: resolvedRunPlan.cameraGrouping
                    ),
                    options: colmapExtractOptions,
                    onLog: onFeaturesLog
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

            let runMatching: (Bool) async throws -> Void = { force in
                guard try (force || shouldRunStage(.sfmMatching)) else { return }
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
                    line: colmapMatchOptions.useGPU ? "Using GPU for COLMAP matching." : "Using CPU for COLMAP matching.",
                    isError: false
                ))
                let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                colmapToolLog.beginSection(
                    title: "matching",
                    metadata: [
                        "database": paths.colmapDatabaseURL.path,
                        "tool": self.config.toolchain.colmap.path,
                        "useGPU": colmapMatchOptions.useGPU ? "1" : "0",
                        "threads": "\(colmapMatchOptions.matchThreads)"
                    ]
                )
                emit(.stageLog(stage: .sfmMatching, line: "COLMAP tool log: \(paths.colmapLogURL.lastPathComponent)", isError: false))
                let useSequential = self.shouldUseSequential(
                    selectedFrames: selectedFrames,
                    input: metadata.input,
                    forceExhaustive: forceExhaustiveMatching,
                    pairingPolicy: resolvedRunPlan.pairingPolicy
                )

                let exhaustiveFallbackMaxFrames = 60
                let useBoundedRetrieval = !useSequential
                    && !forceExhaustiveMatching
                    && resolvedRunPlan.pairingPolicy == .unorderedRetrieval
                    && selectedFrames.count >= 120
                lastUsedSequentialMatcher = useSequential

                if !useSequential, metadata.input.videoFiles.count > 1 {
                    let strategy = useBoundedRetrieval
                        ? "using bounded retrieval pairs so overlapping views across clips can link"
                        : "using exhaustive matching so frames from different clips can link"
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "Multiple video clips detected (\(metadata.input.videoFiles.count)); \(strategy).",
                        isError: false
                    ))
                }

                func runSequential() async throws {
                    let descriptors = try ColmapPairEstimator.imageDescriptors(for: selectedFrames)
                    let loopPairs = try ColmapPairEstimator.orderedLoopPairs(
                        imageNames: selectedFrames.map(\.lastPathComponent),
                        descriptors: descriptors,
                        minimumSeparation: max(
                            colmapMatchOptions.sequentialOverlap + 1,
                            selectedFrames.count / 5
                        )
                    )
                    let sequentialExpected = ColmapPairEstimator.expectedSequentialPairs(
                        imageCount: selectedFrames.count,
                        overlap: colmapMatchOptions.sequentialOverlap
                    )
                    let expected = sequentialExpected + loopPairs.count
                    lastExpectedMatchingPairs = expected
                    try await self.runColmapMatcherAttempt(
                        stage: .sfmMatching,
                        paths: paths,
                        colmapToolLog: colmapToolLog,
                        expectedPairs: expected,
                        progressStart: 0.0,
                        progressSpan: 1.0,
                        blockMessageFallback: "Matching views",
                        invokeMatcher: { onLog in
                            try await self.tooling.colmap.runMatcherSequential(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                options: colmapMatchOptions,
                                onLog: onLog
                            )
                        },
                        emit: emit
                    )
                    if !loopPairs.isEmpty {
                        let listURL = try self.writeColmapPairList(
                            loopPairs,
                            fileName: "loop_pairs.txt",
                            paths: paths
                        )
                        emit(.stageLog(
                            stage: .sfmMatching,
                            line: "Adding \(loopPairs.count) verified loop-closure pairs.",
                            isError: false
                        ))
                        try await self.runColmapMatcherAttempt(
                            stage: .sfmMatching,
                            paths: paths,
                            colmapToolLog: colmapToolLog,
                            expectedPairs: expected,
                            progressStart: 0,
                            progressSpan: 1,
                            blockMessageFallback: "Closing capture loops",
                            invokeMatcher: { onLog in
                                try await self.tooling.colmap.runMatchesImporter(
                                    colmapPath: self.config.toolchain.colmap,
                                    database: paths.colmapDatabaseURL,
                                    matchListPath: listURL,
                                    matchType: "pairs",
                                    options: colmapMatchOptions,
                                    onLog: onLog
                                )
                            },
                            emit: emit
                        )
                    }
                }

                func runExhaustive() async throws {
                    let expected = ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                    lastExpectedMatchingPairs = expected
                    try await self.runColmapMatcherAttempt(
                        stage: .sfmMatching,
                        paths: paths,
                        colmapToolLog: colmapToolLog,
                        expectedPairs: expected,
                        progressStart: 0.0,
                        progressSpan: 1.0,
                        blockMessageFallback: "Matching views",
                        invokeMatcher: { onLog in
                            try await self.tooling.colmap.runMatcherExhaustive(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                options: colmapMatchOptions,
                                onLog: onLog
                            )
                        },
                        emit: emit
                    )
                }

                func runRetrieval() async throws {
                    let descriptors = try ColmapPairEstimator.imageDescriptors(for: selectedFrames)
                    let pairs = try ColmapPairEstimator.boundedRetrievalPairs(
                        imageNames: selectedFrames.map(\.lastPathComponent),
                        descriptors: descriptors,
                        maxNeighbors: 8
                    )
                    let listURL = try self.writeColmapPairList(
                        pairs,
                        fileName: "retrieval_pairs.txt",
                        paths: paths
                    )
                    lastExpectedMatchingPairs = pairs.count
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "Using \(pairs.count) bounded retrieval pairs for \(selectedFrames.count) unordered views.",
                        isError: false
                    ))
                    try await self.runColmapMatcherAttempt(
                        stage: .sfmMatching,
                        paths: paths,
                        colmapToolLog: colmapToolLog,
                        expectedPairs: pairs.count,
                        progressStart: 0,
                        progressSpan: 1,
                        blockMessageFallback: "Matching retrieved views",
                        invokeMatcher: { onLog in
                            try await self.tooling.colmap.runMatchesImporter(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                matchListPath: listURL,
                                matchType: "pairs",
                                options: colmapMatchOptions,
                                onLog: onLog
                            )
                        },
                        emit: emit
                    )
                }

                if useSequential {
                    do {
                        try await runSequential()
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        let previousOverlap = colmapMatchOptions.sequentialOverlap
                        let increasedOverlap = min(30, max(previousOverlap + 5, previousOverlap * 2))
                        if increasedOverlap > previousOverlap {
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "Sequential matcher failed. Retrying sequential matching with higher overlap (\(previousOverlap) -> \(increasedOverlap)).",
                                isError: true
                            ))
                            self.emitColmapRetryDiagnostics(error, stage: .sfmMatching, emit: emit)
                            colmapMatchOptions.sequentialOverlap = increasedOverlap
                            do {
                                try await runSequential()
                            } catch {
                                if error is CancellationError { throw error }
                                try Task.checkCancellation()
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "Sequential matcher failed again. Rebuilding database and retrying with exhaustive matching on fewer frames.",
                                    isError: true
                                ))
                                self.emitColmapRetryDiagnostics(error, stage: .sfmMatching, emit: emit)
                                let previousCount = selectedFrames.count
                                let reduced = try self.downsampleSelectedFrames(to: exhaustiveFallbackMaxFrames, paths: paths)
                                if let reduced {
                                    selectedFrames = reduced
                                }
                                didRetryWithFewerFrames = true
                                if previousCount != selectedFrames.count {
                                    emit(.stageLog(
                                        stage: .sfmMatching,
                                        line: "Reduced matching frames \(previousCount) -> \(selectedFrames.count) for exhaustive fallback.",
                                        isError: true
                                    ))
                                }
                                forceExhaustiveMatching = true
                                lastUsedSequentialMatcher = false

                                self.removeIfExists(paths.colmapDatabaseURL)
                                try self.resetDirectory(paths.colmapSparseURL)
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
                                    singleCamera: self.da3SharedCameraPreference(
                                        input: metadata.input,
                                        cameraGrouping: resolvedRunPlan.cameraGrouping
                                    ),
                                    options: colmapExtractOptions,
                                    onLog: { line, isErr in
                                        colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                        let sanitized = Self.sanitizeToolLogLine(line)
                                        let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                                        if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                                            emit(.stageLog(stage: .sfmMatching, line: sanitized, isError: effectiveIsErr))
                                        }
                                    }
                                )
                                self.logKeypointStats(database: paths.colmapDatabaseURL, stage: .sfmMatching, emit: emit)
                                try await runExhaustive()
                            }
                        } else {
                            throw error
                        }
                    }
                } else {
                    lastUsedSequentialMatcher = false
                    if useBoundedRetrieval {
                        try await runRetrieval()
                    } else {
                        try await runExhaustive()
                    }
                }
                let processedPairs = (try? ColmapDatabaseProgressPoller(databasePath: paths.colmapDatabaseURL).readProcessedPairCount()) ?? 0
                writeCheckpoint(
                    stage: .sfmMatching,
                    progress: 1.0,
                    message: "COLMAP matching completed",
                    details: .sfmMatching(SfmMatchingCheckpoint(
                        databasePath: try paths.projectRelativePath(for: paths.colmapDatabaseURL),
                        expectedPairs: lastExpectedMatchingPairs,
                        processedPairs: processedPairs
                    ))
                )
                emit(.stageFinished(stage: .sfmMatching))
                markStageComplete(.sfmMatching)
                try stopIfRequested(after: .sfmMatching)
            }

            let retryWithCpuIfNeeded: (Error) -> Bool = { error in
                guard !didRetryWithCpu else { return false }
                guard colmapExtractOptions.useGPU || colmapMatchOptions.useGPU else { return false }
                guard let colmapError = error as? ColmapRunnerError else { return false }
                guard self.colmapErrorIndicatesGpuFailure(colmapError) else { return false }
                didRetryWithCpu = true
                colmapExtractOptions.useGPU = false
                colmapMatchOptions.useGPU = false
                emit(.stageLog(stage: currentStage, line: "COLMAP GPU failed or unsupported; retrying on CPU.", isError: true))
                return true
            }

            let applyFewerFramesRetry: (String, Bool) async throws -> Bool = { reason, reduceDetail in
                guard !didRetryWithFewerFrames else { return false }
                let reducedTarget = max(40, targetFrames / 2)
                let previousCount = selectedFrames.count
                let reduced = try self.downsampleSelectedFrames(to: reducedTarget, paths: paths)
                let previousMaxImageSize = colmapMaxImageSize
                if reduceDetail {
                    colmapMaxImageSize = max(800, Int(Double(colmapMaxImageSize) * 0.75))
                    if let current = colmapExtractOptions.maxNumFeatures {
                        colmapExtractOptions.maxNumFeatures = max(2000, min(current, 6000))
                    } else {
                        colmapExtractOptions.maxNumFeatures = 6000
                    }
                    if let currentMatches = colmapMatchOptions.maxNumMatches {
                        colmapMatchOptions.maxNumMatches = max(2000, min(currentMatches, 6000))
                    } else {
                        colmapMatchOptions.maxNumMatches = 6000
                    }
                    colmapMatchOptions.useBruteForceMatcher = true
                    colmapMatchOptions.exhaustiveBlockSize = min(colmapMatchOptions.exhaustiveBlockSize ?? 20, 20)
                    colmapMatchOptions.sequentialOverlap = min(colmapMatchOptions.sequentialOverlap, 5)
                }
                didRetryWithFewerFrames = true
                if let reduced = reduced {
                    selectedFrames = reduced
                }
                forceExhaustiveMatching = true
                let countDetail = reduced != nil ? "\(previousCount) -> \(selectedFrames.count)" : "\(previousCount) (no reduction)"
                var details = [countDetail]
                if reduceDetail {
                    details.append("\(previousMaxImageSize)px -> \(colmapMaxImageSize)px")
                }
                emit(.stageLog(
                    stage: currentStage,
                    line: "\(reason) (\(details.joined(separator: ", "))).",
                    isError: true
                ))
                return true
            }

            let retryWithFewerFramesIfNeeded: (Error) async throws -> Bool = { error in
                guard error is ColmapRunnerError || error is ColmapPairPlanningError else { return false }
                return try await applyFewerFramesRetry("COLMAP failed; retrying with fewer frames and exhaustive matching", true)
            }

            var forceSfMRun = false
            sfmAttemptLoop: while true {
                while true {
                    do {
                        try await runFeatures(forceSfMRun)
                        try await runMatching(forceSfMRun)
                        if didRetryWithCpu {
                            emit(.stageLog(stage: .sfmMatching, line: "Retry on CPU succeeded.", isError: false))
                        }
                        if didRetryWithFewerFrames {
                            emit(.stageLog(stage: .sfmMatching, line: "Retry with fewer frames succeeded.", isError: false))
                        }
                        break
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        if retryWithCpuIfNeeded(error) {
                            forceSfMRun = true
                            continue
                        }
                        if try await retryWithFewerFramesIfNeeded(error) {
                            forceSfMRun = true
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
                    writeCheckpoint(
                        stage: .sfmMapping,
                        progress: 0,
                        message: "Camera mapping started",
                        details: .sfmMapping(SfmMappingCheckpoint(
                            mapper: "global_mapper",
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
                    let globalMapperToolLog = ToolLogWriter(fileURL: paths.globalMapperLogURL, toolName: "colmap-global_mapper")
                    globalMapperToolLog.beginSection(
                        title: "global_mapper",
                        metadata: [
                            "database": paths.colmapDatabaseURL.path,
                            "images": paths.framesSelectedURL.path,
                            "output": paths.colmapSparseURL.path,
                            "tool": self.config.toolchain.colmap.path
                        ]
                    )
                    let toolLogNames = [paths.colmapLogURL.lastPathComponent, paths.globalMapperLogURL.lastPathComponent]
                        .joined(separator: ", ")
                    emit(.stageLog(stage: .sfmMapping, line: "Tool logs: \(toolLogNames)", isError: false))
                    let mappingProgress = ColmapMappingProgressTracker(totalImages: selectedFrames.count)
                    let onMappingLog: @Sendable (String, Bool) -> Void = { line, isErr in
                        let sanitized = Self.sanitizeToolLogLine(line)
                        let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                        if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                            emit(.stageLog(stage: .sfmMapping, line: sanitized, isError: effectiveIsErr))
                        }
                        if let update = mappingProgress.ingest(line) {
                            emit(.stageProgress(stage: .sfmMapping, fraction: update.fraction, message: update.message))
                        }
                    }
                    var mappingSucceeded = false
                    var lastMappingError: Error?
                    var acceptedMappingStrategy = "global_mapper"
                    var lastMappingAttempt = "none"

                    func evaluateMappingResult(candidate: String) async throws -> Bool {
                        lastMappingAttempt = candidate
                        let modelURL = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                        guard sparseModelFilesExist(at: modelURL) else {
                            throw PipelineError.outputMissing
                        }

                        let report = try await self.tooling.colmap.runModelAnalyzer(
                            colmapPath: self.config.toolchain.colmap,
                            modelPath: modelURL,
                            options: colmapMatchOptions
                        )
                        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                            colmapToolLog.append(stream: "stdout", line: String(line))
                        }
                        let score = ReconstructionScorer.applyingExpectedTotalImages(
                            ReconstructionScorer.parseModelAnalyzerOutput(report),
                            expectedTotalImages: selectedFrames.count
                        )
                        writeCheckpoint(
                            stage: .sfmMapping,
                            progress: 0.95,
                            message: "Mapping score: \(ReconstructionScorer.summary(score))",
                            details: .sfmMapping(SfmMappingCheckpoint(
                                mapper: candidate,
                                sparsePath: try paths.projectRelativePath(for: modelURL),
                                registeredImages: score.registeredImages
                            ))
                        )
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "Reconstruction score (\(candidate)): \(ReconstructionScorer.summary(score)).",
                            isError: false
                        ))
                        if ReconstructionScorer.isAcceptable(
                            score,
                            capturePath: resolvedRunPlan.capturePath
                        ) {
                            acceptedMappingStrategy = candidate
                            self.warnIfWeakAcceptedSolve(score: score, mapper: candidate, emit: emit)
                            acceptedReconstructionSummary = ReconstructionSummary(
                                score: score,
                                mapper: candidate,
                                capturedAt: Date()
                            )
                            return true
                        } else {
                            lastMappingError = PipelineError.lowQualityReconstruction(score, mapper: candidate)
                            return false
                        }
                    }

                    let mapperLabel = disableGlobalMapperForThisRun
                        ? "COLMAP global_mapper disabled for this run; COLMAP mapper fallback only"
                        : "COLMAP global_mapper preferred with COLMAP mapper fallback"
                    emit(.stageLog(
                        stage: .sfmMapping,
                        line: "Mapping preference: \(mapperLabel).",
                        isError: false
                    ))

                    if !disableGlobalMapperForThisRun {
                        let threadHint = max(colmapExtractOptions.extractThreads, colmapMatchOptions.matchThreads)
                        var baseGlobalMapperOptions = self.globalMapperOptions(
                            threadHint: threadHint,
                            defaultUseGpu: colmapExtractOptions.useGPU || colmapMatchOptions.useGPU
                        )
                        baseGlobalMapperOptions.baNumIterations = resolvedRunPlan.refinementIterationLimit
                        let gpuRequested = baseGlobalMapperOptions.useGpuForGlobalPositioning || baseGlobalMapperOptions.useGpuForBundleAdjustment
                        do {
                            try self.resetDirectory(paths.colmapSparseURL)
                            emit(.stageLog(
                                stage: .sfmMapping,
                                line: "Running COLMAP global_mapper (gp_use_gpu=\(baseGlobalMapperOptions.useGpuForGlobalPositioning), ba_use_gpu=\(baseGlobalMapperOptions.useGpuForBundleAdjustment), threads=\(baseGlobalMapperOptions.numThreads)).",
                                isError: false
                            ))
                            lastMappingAttempt = gpuRequested ? "global_mapper-gpu" : "global_mapper"
                            try await self.tooling.colmap.runGlobalMapper(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                outputPath: paths.colmapSparseURL,
                                options: baseGlobalMapperOptions,
                                environment: colmapMatchOptions.environment,
                                onLog: { line, isErr in
                                    globalMapperToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                    onMappingLog(line, isErr)
                                }
                            )
                            mappingSucceeded = try await evaluateMappingResult(candidate: gpuRequested ? "global_mapper-gpu" : "global_mapper")
                        } catch {
                            if error is CancellationError { throw error }
                            try Task.checkCancellation()
                            lastMappingError = error
                            if let colmapError = error as? ColmapRunnerError,
                               colmapErrorIndicatesMissingGlobalMapper(colmapError) {
                                disableGlobalMapperForThisRun = true
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "COLMAP global_mapper is unavailable in this toolchain; falling back to COLMAP mapper.",
                                    isError: true
                                ))
                            } else if let colmapError = error as? ColmapRunnerError,
                                      gpuRequested,
                                      colmapErrorIndicatesGpuFailure(colmapError) {
                                var cpuGlobalMapperOptions = baseGlobalMapperOptions
                                cpuGlobalMapperOptions.useGpuForGlobalPositioning = false
                                cpuGlobalMapperOptions.useGpuForBundleAdjustment = false
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "global_mapper GPU path failed; retrying global_mapper with GPU disabled.",
                                    isError: true
                                ))
                                self.emitColmapRetryDiagnostics(colmapError, stage: .sfmMapping, emit: emit)
                                do {
                                    try self.resetDirectory(paths.colmapSparseURL)
                                    lastMappingAttempt = "global_mapper-cpu"
                                    try await self.tooling.colmap.runGlobalMapper(
                                        colmapPath: self.config.toolchain.colmap,
                                        database: paths.colmapDatabaseURL,
                                        imagePath: paths.framesSelectedURL,
                                        outputPath: paths.colmapSparseURL,
                                        options: cpuGlobalMapperOptions,
                                        environment: colmapMatchOptions.environment,
                                        onLog: { line, isErr in
                                            globalMapperToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                            onMappingLog(line, isErr)
                                        }
                                    )
                                    mappingSucceeded = try await evaluateMappingResult(candidate: "global_mapper-cpu")
                                } catch {
                                    if error is CancellationError { throw error }
                                    try Task.checkCancellation()
                                    lastMappingError = error
                                }
                            }
                        }
                    } else {
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "Skipping global_mapper for this run due to previous launch failure.",
                            isError: true
                        ))
                    }

                    if !mappingSucceeded {
                        emit(.stageLog(stage: .sfmMapping, line: "global_mapper mapping failed; trying COLMAP mapper.", isError: true))
                        do {
                            try self.resetDirectory(paths.colmapSparseURL)
                            lastMappingAttempt = "colmap"
                            try await self.tooling.colmap.runMapper(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                outputPath: paths.colmapSparseURL,
                                options: colmapMatchOptions,
                                bundleAdjustmentIterationLimit: resolvedRunPlan.refinementIterationLimit,
                                onLog: { line, isErr in
                                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                    onMappingLog(line, isErr)
                                }
                            )
                            mappingSucceeded = try await evaluateMappingResult(candidate: "colmap")
                        } catch {
                            if error is CancellationError { throw error }
                            try Task.checkCancellation()
                            lastMappingError = error
                        }
                    }

                        if !mappingSucceeded,
                           let pipelineError = lastMappingError as? PipelineError,
                           case .lowQualityReconstruction = pipelineError,
                           lastUsedSequentialMatcher,
                           !didRetryWithHigherSequentialOverlap {
                            let previousOverlap = colmapMatchOptions.sequentialOverlap
                            let increasedOverlap = min(30, max(previousOverlap + 5, previousOverlap * 2))
                            if increasedOverlap > previousOverlap {
                                didRetryWithHigherSequentialOverlap = true
                                colmapMatchOptions.sequentialOverlap = increasedOverlap
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Reconstruction quality was low. Retrying with higher sequential overlap (\(previousOverlap) -> \(increasedOverlap)).",
                                    isError: true
                                ))
                                forceSfMRun = true
                                continue sfmAttemptLoop
                            }
                        }

                        if !mappingSucceeded,
                           let pipelineError = lastMappingError as? PipelineError,
                           case .lowQualityReconstruction = pipelineError,
                           try await applyFewerFramesRetry("Reconstruction quality was low; retrying with fewer frames and exhaustive matching", false) {
                            forceSfMRun = true
                            continue sfmAttemptLoop
                        }

                        guard mappingSucceeded else {
                            let debugMessage: String
                            if let pipelineError = lastMappingError as? PipelineError,
                               case let .lowQualityReconstruction(score, _) = pipelineError {
                                let summary = ReconstructionScorer.summary(score)
                                debugMessage = "Low-quality reconstruction. \(summary). Last attempt: \(lastMappingAttempt)."
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
                        let canonicalSparseModel = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                        let resolvedSparseModel = try resolveSparseModelDirectory(at: canonicalSparseModel)
                        if resolvedSparseModel.standardizedFileURL != canonicalSparseModel.standardizedFileURL {
                            try self.resetDirectory(canonicalSparseModel)
                            let fm = FileManager.default
                            let files = try fm.contentsOfDirectory(
                                at: resolvedSparseModel,
                                includingPropertiesForKeys: [.isRegularFileKey],
                                options: [.skipsHiddenFiles]
                            )
                            for file in files {
                                let isRegular = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                                guard isRegular else { continue }
                                try fm.copyItem(at: file, to: canonicalSparseModel.appendingPathComponent(file.lastPathComponent))
                            }
                            emit(.stageLog(
                                stage: .sfmMapping,
                                line: "Canonicalized sparse model layout: \(resolvedSparseModel.lastPathComponent) -> 0.",
                                isError: false
                            ))
                        }
                        if try ensureTextSparseModelFiles(at: canonicalSparseModel) {
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
                                mapper: acceptedMappingStrategy,
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
            let mappingDurationText: String?
            if completedMappingThisAttempt {
                mappingDurationText = stageTiming.finish(.sfmMapping)
                recordFinishedStageTiming(.sfmMapping)
            } else {
                mappingDurationText = nil
            }
            if acceptedReconstructionSummary != nil
                || metadata.geometryArtifact == nil
                || !FileManager.default.fileExists(atPath: paths.geometryManifestURL.path) {
                guard let mapper = (acceptedReconstructionSummary ?? metadata.reconstruction)?.mapper else {
                    throw PipelineError.geometryResidualsUnavailable(
                        "The current project has canonical geometry without solver provenance"
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
                let previousReconstruction = metadata.reconstruction
                if let summary = acceptedReconstructionSummary, metadata.reconstruction != summary {
                    metadata.reconstruction = summary
                }
                do {
                    try persistMeasuredGeometryArtifact(
                        metadata: &metadata,
                        paths: paths,
                        resolvedPlan: resolvedRunPlan,
                        mapper: mapper,
                        acceptedDa3ModelSubdirectory: acceptedDa3ModelSubdirectory,
                        selectedFrames: selectedFrames,
                        selectedFrameManifest: currentSelectedFrameManifest,
                        peakMemoryBytes: geometryPeakMemoryBytes
                    )
                } catch {
                    metadata.reconstruction = previousReconstruction
                    throw error
                }
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
                let debug = failureMessages(for: error, stage: .sfmFeatures).debugMessage
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "\(backendName(backendPolicy)) failed (\(debug)). Falling back to \(backendName(nextBackend)).",
                    isError: true
                ))
                try? cleanForRetry(failedStage: .sfmFeatures, paths: paths)
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
                    let learnedPointInitializer: LearnedPointInitializerArtifact?
                    if metadata.geometryArtifact?.provenance.model != nil,
                       metadata.reconstruction?.mapper.lowercased().contains("da3") == true {
                        learnedPointInitializer = metadata.geometryArtifact?.learnedPointInitializer
                    } else {
                        learnedPointInitializer = nil
                    }
                    let datasetURL = try await prepareMsplatDataset(
                        paths: paths,
                        maxImageSize: resolvedRunPlan.maximumImageDimension,
                        learnedPointInitializer: learnedPointInitializer,
                        progress: { _, message in
                            emit(.stageProgress(stage: .trainSplat, fraction: -1.0, message: message))
                        }
                    )
                    let datasetIdentity = try msplatDatasetIdentity(at: datasetURL)
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
                    let seed = resolvedRunPlan.deterministicSeed
                    let resumeURL: URL?
                    do {
                        resumeURL = try msplatResumeURL(
                            metadata: metadata,
                            paths: paths,
                            profile: detailProfile,
                            seed: seed,
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
                                checkpointPath: paths.msplatCheckpointURL,
                                resumeFrom: activeResumeURL,
                                profile: detailProfile,
                                seed: seed,
                                iterationLimit: resolvedRunPlan.trainerIterationLimit,
                                plateauWindow: resolvedRunPlan.plateauWindow,
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
                                            seed: seed,
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
                                seed: seed,
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
                        seed: seed,
                        resolvedPlan: resolvedRunPlan,
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
            paths.globalMapperLogURL,
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
