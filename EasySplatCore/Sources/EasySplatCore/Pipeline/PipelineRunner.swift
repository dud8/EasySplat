import Foundation
import Dispatch
public final class PipelineRunner: @unchecked Sendable {

    public struct Tooling {
        public var colmap: ColmapRunner
        public var brush: BrushRunner
        public var msplat: MsplatRunner
        public var da3Sfm: Da3SfmRunning
        public var mapAnythingSfm: MapAnythingSfmRunning
        public var vggtSfm: VggtSfmRunning
        public var fastVggtSfm: FastVggtSfmRunning

        public init(colmap: ColmapRunner = ColmapRunner(),
                    brush: BrushRunner = BrushRunner(),
                    msplat: MsplatRunner = MsplatRunner(),
                    da3Sfm: Da3SfmRunning = Da3SfmRunner(),
                    mapAnythingSfm: MapAnythingSfmRunning = MapAnythingSfmRunner(),
                    vggtSfm: VggtSfmRunning = VggtSfmRunner(),
                    fastVggtSfm: FastVggtSfmRunning = FastVggtSfmRunner()) {
            self.colmap = colmap
            self.brush = brush
            self.msplat = msplat
            self.da3Sfm = da3Sfm
            self.mapAnythingSfm = mapAnythingSfm
            self.vggtSfm = vggtSfm
            self.fastVggtSfm = fastVggtSfm
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.brush = BrushRunner(runner: runner)
            self.msplat = MsplatRunner(runner: runner)
            self.da3Sfm = Da3SfmRunner(runner: runner)
            self.mapAnythingSfm = MapAnythingSfmRunner(runner: runner)
            self.vggtSfm = VggtSfmRunner(runner: runner)
            self.fastVggtSfm = FastVggtSfmRunner(runner: runner)
        }
    }

    public enum SpeedProfile: Sendable, Equatable {
        case standard
        case fast
    }

    public struct PipelineConfig: Sendable {
        public var toolchain: ToolchainPaths
        public var preset: PresetSpec
        public var speedProfile: SpeedProfile
        public var trainingGate: (@Sendable () async throws -> Void)?

        public init(
            toolchain: ToolchainPaths,
            preset: PresetSpec,
            speedProfile: SpeedProfile = .standard,
            trainingGate: (@Sendable () async throws -> Void)? = nil
        ) {
            self.toolchain = toolchain
            self.preset = preset
            self.speedProfile = speedProfile
            self.trainingGate = trainingGate
        }
    }

    private let projectURL: URL
    let config: PipelineConfig
    let tooling: Tooling
    let powerAssertion: PowerAssertionManaging
    let initialEnvironment: [String: String]
    private let capturedEnvironment: [String: String]?

    enum SfmMapperPreference: String {
        case glomap
        case colmap
    }

    struct MapAnythingExecutionPlan: Sendable {
        var mode: MapAnythingRunMode
        var device: String
        var resolution: Int
        var memoryEfficientInference: Bool
        var useAMP: Bool
        var minibatchSize: Int
        var maxPoints: Int
        var cameraType: String
        var sharedCamera: Bool
        var anchorMaxViews: Int
        var windowSize: Int
        var windowOverlap: Int
        var directViewLimit: Int
        var directAllowed: Bool

        var requiresRefinement: Bool {
            mode == .seedRefine
        }
    }

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
        self.initialEnvironment = RuntimeEnvironment.current
        self.capturedEnvironment = nil
    }

    var runtimeEnvironment: [String: String] {
        capturedEnvironment ?? RuntimeEnvironment.current
    }

    public func run(resumeFrom lastCompletedStage: PipelineStage? = nil, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        let environment = initialEnvironment
        let scopedRunner = PipelineRunner(
            projectURL: projectURL,
            config: config,
            tooling: tooling,
            powerAssertion: powerAssertion,
            capturedEnvironment: environment
        )
        try await scopedRunner.runWithCapturedEnvironment(
            resumeFrom: lastCompletedStage,
            environment: environment,
            events: events
        )
    }

    private init(
        projectURL: URL,
        config: PipelineConfig,
        tooling: Tooling,
        powerAssertion: PowerAssertionManaging,
        capturedEnvironment: [String: String]
    ) {
        self.projectURL = projectURL
        self.config = config
        self.tooling = tooling
        self.powerAssertion = powerAssertion
        self.initialEnvironment = capturedEnvironment
        self.capturedEnvironment = capturedEnvironment
    }

    private func runWithCapturedEnvironment(
        resumeFrom lastCompletedStage: PipelineStage?,
        environment: [String: String],
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        // Keep the Mac awake for the entire run. Runs are multi-hour and training has no
        // resumable checkpoint, so a system idle-sleep partway through loses the session.
        // Released on every exit — success, throw, or cancellation.
        let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is processing a project")
        defer { idleSleepAssertion.release() }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        // Load metadata BEFORE clearing any logs. If project.json is malformed, unreadable,
        // or from a future build, we want the user to keep the previous run's diagnostic
        // tool logs (colmap/brush/etc.) for inspection — wiping them on a no-op startup
        // failure would destroy the only evidence of why the prior attempt died.
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
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
        var disableGlomapForThisRun = false
        var lastUsedSequentialMatcher = false
        let resumeValidationMode = lastCompletedStage != nil
        let hasInterruptionEvidence = metadata.checkpoint != nil || metadata.lastRunStartedAt != nil
        let wasInterrupted = metadata.state.lastError == nil
            && metadata.state.stage != .done
            && hasInterruptionEvidence
        let skipTraining: Bool = {
            let env = runtimeEnvironment
            let stopAfterSfmRaw = env["EASYSPLAT_STOP_AFTER_SFM"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if stopAfterSfmRaw == "1" || stopAfterSfmRaw == "true" || stopAfterSfmRaw == "yes" {
                return true
            }
            guard let raw = env["EASYSPLAT_SKIP_TRAINING"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty else {
                return false
            }
            return raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
        }()

        metadata.recoveryPromptSuppressed = false
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

        func stageIndex(_ stage: PipelineStage) -> Int {
            PipelineStage.allCases.firstIndex(of: stage) ?? 0
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
            guard let lastCompletedStage else { return true }
            if stageIndex(stage) <= stageIndex(lastCompletedStage) {
                if !resumeValidationMode {
                    return !isStageComplete(stage, paths: paths, metadata: metadata)
                }
                let validationMetadata = resumeValidationMode ? metadataForResumeValidation : metadata
                switch try validateStageOutput(stage, paths: paths, metadata: validationMetadata) {
                case .valid:
                    return false
                case .missing:
                    return true
                case .corrupt(let reason):
                    emit(.stageLog(
                        stage: stage,
                        line: "Detected partial/corrupt stage output for resume (\(reason)). Re-running \(stage.displayName).",
                        isError: true
                    ))
                    try? cleanForRetry(failedStage: stage, paths: paths)
                    try? paths.ensureDirectories()
                    return true
                }
            }
            return true
        }

        func markStageComplete(_ stage: PipelineStage) {
            if stage == .sfmMapping,
               case let .sfmMapping(checkpoint)? = metadata.checkpoint?.details {
                metadata.completedSfmMapping = checkpoint
            }
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
            metadata.state = PipelineState(stage: stage, attempt: metadata.state.attempt, lastError: nil, resumeToken: nil)
            metadata.checkpoint = nil
            try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        }

        func emitFailure(stage: PipelineStage, userMessage: String, debugMessage: String) {
            didEmitFailure = true
            metadata.state = PipelineState(stage: stage, attempt: metadata.state.attempt, lastError: userMessage, resumeToken: nil)
            metadata.checkpoint = nil
            metadata.lastRunStartedAt = nil
            // Record the actual failure moment alongside the lastError so the
            // home stats "Last failure" card and any other consumer doesn't
            // have to infer the failure time from later-unrelated events
            // (e.g., the user opening the project afterwards).
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
            }

            let frameProfile = frameExtractionProfile(for: metadata.preset.quality)
            let targetFrames = frameProfile.targetCount
            let maxDim = frameProfile.maxDimension
            var colmapMaxImageSize = colmapMaxImageSizeOverride() ?? Int(maxDim)
            var colmapExtractOptions = colmapOptionsForExtraction()
            var colmapMatchOptions = colmapOptionsForMatching()
            let preferColmapGpu = shouldUseColmapGpu(colmapPath: config.toolchain.colmap)
            let mapperPreference = sfmMapperPreference()
            colmapExtractOptions.useGPU = preferColmapGpu
            colmapMatchOptions.useGPU = preferColmapGpu
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

                    if let photosFolder = metadata.input.photosFolder {
                        let sourceFolder = paths.originalsURL.appendingPathComponent(URL(fileURLWithPath: photosFolder).lastPathComponent, isDirectory: true)
                        let photos = try loadPhotos(in: sourceFolder)
                        if !photos.isEmpty {
                            groups.append(.init(id: "photos", frames: photos, isVideo: false))
                            emit(.stageLog(
                                stage: .selectFrames,
                                line: "Using \(photos.count) photos from \(sourceFolder.lastPathComponent).",
                                isError: false
                            ))
                        }
                    }

                    let budgetedGroups = applyFrameBudget(to: groups, targetCount: targetFrames)
                    let selectedCountBeforeBudget = groups.reduce(0) { $0 + $1.frames.count }
                    let selectedCountAfterBudget = budgetedGroups.reduce(0) { $0 + $1.frames.count }
                    if selectedCountAfterBudget < selectedCountBeforeBudget {
                        emit(.stageLog(
                            stage: .selectFrames,
                            line: "Applied \(metadata.preset.quality.rawValue) frame budget: \(selectedCountBeforeBudget) -> \(selectedCountAfterBudget).",
                            isError: false
                        ))
                    }

                    let selection = try copySelected(
                        groups: budgetedGroups,
                        to: paths.framesSelectedURL,
                        manifestURL: paths.framesSelectedManifestURL,
                        progress: { fraction, message in
                            emit(.stageProgress(stage: .selectFrames, fraction: fraction, message: message))
                        }
                    )
                    selectedFrames = selection.frames
                    selectedFrameManifest = selection.manifest
                    writeCheckpoint(
                        stage: .selectFrames,
                        progress: 1.0,
                        message: "Selected \(selection.frames.count) frames",
                            details: .selectFrames(SelectFramesCheckpoint(
                            groupsProcessed: budgetedGroups.count,
                            selectedCount: selection.frames.count,
                            manifestPath: paths.framesSelectedManifestURL.path
                        ))
                    )
                    emit(.stageFinished(stage: .selectFrames))
                    markStageComplete(.selectFrames)
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

            var autoTuneProfile: AutoTuneProfile? = nil
            let detectedHardwareProfile = HardwareProfile.detect()
            if shouldAutoTune() {
                let tune = AutoTuner.make(
                    profile: detectedHardwareProfile,
                    preset: metadata.preset,
                    selectedFrameCount: selectedFrames.count
                )
                autoTuneProfile = tune
                applyAutoTune(
                    tune,
                    colmapMaxImageSize: &colmapMaxImageSize,
                    colmapExtractOptions: &colmapExtractOptions,
                    colmapMatchOptions: &colmapMatchOptions
                )
                if let explicitColmapMaxImageSize = colmapMaxImageSizeOverride() {
                    colmapMaxImageSize = explicitColmapMaxImageSize
                }
                emit(.stageLog(stage: .sfmFeatures, line: tune.summary(profile: detectedHardwareProfile), isError: false))
                let snapshot = tune.snapshot(profile: detectedHardwareProfile)
                if metadata.autoTune != snapshot {
                    metadata.autoTune = snapshot
                    try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
                }
            }
            if applySpeedProfileIfNeeded(
                colmapMaxImageSize: &colmapMaxImageSize,
                colmapExtractOptions: &colmapExtractOptions,
                colmapMatchOptions: &colmapMatchOptions
            ) {
                let colmapSizeText = colmapMaxImageSizeOverride().map { "\($0)px (explicit)" } ?? "<=512px"
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "Speed profile fast: frame budget=\(fastSpeedProfileFrameBudget()), extraction cap=\(fastSpeedProfileFrameExtractionCap(targetCount: fastSpeedProfileFrameBudget())), COLMAP max image size \(colmapSizeText), features<=4000, sequential overlap<=2.",
                    isError: false
                ))
            }
            if let sequentialOverlap = colmapSequentialOverlapOverride() {
                colmapExtractOptions.sequentialOverlap = sequentialOverlap
                colmapMatchOptions.sequentialOverlap = sequentialOverlap
                emit(.stageLog(stage: .sfmFeatures, line: "COLMAP sequential overlap override: \(sequentialOverlap).", isError: false))
            }

            try Task.checkCancellation()
            let backendOverride = sfmBackendOverride(environment: environment)
            let da3WindowSize = da3WindowSizePreference(hardwareTier: detectedHardwareProfile.tier)
            var backendOrder = sfmBackendFallbackOrder(override: backendOverride)
            if let backendOverride, backendOverride == .fastvggt {
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "Deprecated SfM backend override '\(backendOverride.rawValue)' is enabled. Fast defaults to COLMAP; other profiles use DA3 with MapAnything and COLMAP fallback.",
                    isError: true
                ))
            }
            let deprecatedFastVggtEnvKeys = [
                "EASYSPLAT_FASTVGGT_TRACK_MODE",
                "EASYSPLAT_FASTVGGT_REFINEMENT_POLICY",
                "EASYSPLAT_FASTVGGT_WATCHDOG_SECONDS",
                "EASYSPLAT_FASTVGGT_MAX_TRACKS_PROFILE",
                "EASYSPLAT_FASTVGGT_ALLOW_TRACK_ONLY_DEGRADE",
                "EASYSPLAT_ENABLE_VGGT_GRACE_FALLBACK"
            ]
            for key in deprecatedFastVggtEnvKeys where hasEnvValue(key) {
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "Deprecated env '\(key)' is ignored. FastVGGT now uses external COLMAP/GLOMAP refinement.",
                    isError: true
                ))
            }

            let strictFastVggtRequested = fastvggtFullCoveragePreference() || fastvggtNoFallbackPreference()
            if let autoTuneProfile, !autoTuneProfile.vggtAllowed,
               backendOrder.contains(where: { $0 == .fastvggt || $0 == .vggt }) {
                let name: String = {
                    if let override = backendOverride {
                        return override == .fastvggt ? "FastVGGT" : "VGGT"
                    }
                    return "FastVGGT/VGGT"
                }()
                if strictFastVggtRequested {
                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "Auto-tune marks \(name) as high risk on this hardware tier, but strict FastVGGT mode is enabled. Continuing with conservative strict settings (no fallback).",
                        isError: true
                    ))
                } else if backendOverride != nil {
                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "Auto-tune marks \(name) as high risk on this hardware tier, but it was explicitly requested. Continuing without changing the backend.",
                        isError: true
                    ))
                } else {
                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "Auto-tune disabled \(name) on this hardware tier; falling back to COLMAP + GLOMAP.",
                        isError: true
                    ))
                    backendOrder = [.colmap]
                }
            }

            let backendName: (SfmBackend) -> String = { backend in
                switch backend {
                case .da3:
                    return "Depth Anything 3"
                case .mapanything:
                    return "MapAnything"
                case .fastvggt:
                    return "FastVGGT"
                case .vggt:
                    return "VGGT"
                case .colmap:
                    return "GLOMAP (COLMAP global_mapper)"
                }
            }

            var acceptedReconstructionScore: ReconstructionScore?
            var acceptedReconstructionSummary: ReconstructionSummary?
            for (index, backendPolicy) in backendOrder.enumerated() {
                // Reset accepted-quality state at the start of every backend attempt so a
                // partial failure from the previous backend cannot leak its score/summary
                // into a later backend's successful run.
                acceptedReconstructionScore = nil
                acceptedReconstructionSummary = nil
                do {
                    if backendPolicy == .da3 {
                        let fm = FileManager.default
                        let seedZero = paths.colmapSeedModelURL
                        let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                        let da3CoverageManifest = paths.da3CoverageManifestURL
                        let da3Mode: Da3RunMode = selectedFrames.count <= max(4, da3WindowSize) ? .direct : .seedRefine
                        let requestedOrdering = metadata.requestedRunOptions?.inputOrdering ?? .automatic
                        let da3InputOrdering = da3ResolvedInputOrdering(
                            requested: requestedOrdering,
                            input: metadata.input
                        )
                        let da3RefinementOptions = tuneMapAnythingRefinementColmapOptions(
                            frameCount: selectedFrames.count,
                            extractOptions: colmapExtractOptions,
                            matchOptions: colmapMatchOptions
                        )
                        let da3ColmapExtractOptions = da3RefinementOptions.extract
                        let da3ColmapMatchOptions = da3RefinementOptions.match
                        let da3Config = Da3SfmConfig(
                            device: da3DevicePreference(),
                            mode: da3Mode,
                            modelSubdirectory: da3ModelPreference(),
                            fallbackModelSubdirectory: da3FallbackModelPreference(),
                            processResolution: da3ProcessResolutionPreference(),
                            maxPoints: da3MaxPointsPreference(preset: metadata.preset),
                            cameraType: da3CameraTypePreference(preset: metadata.preset),
                            sharedCamera: da3SharedCameraPreference(input: metadata.input),
                            inputOrdering: da3InputOrdering,
                            windowSize: max(4, da3WindowSize),
                            windowOverlap: da3Mode == .seedRefine
                                ? max(3, da3WindowOverlapPreference(hardwareTier: detectedHardwareProfile.tier))
                                : da3WindowOverlapPreference(hardwareTier: detectedHardwareProfile.tier),
                            coverageManifestPath: da3CoverageManifest
                        )

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
                                expectedMode: da3Mode,
                                selectedImageNames: selectedFrames.map(\.lastPathComponent)
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
                            emit(.stageLog(stage: currentStage, line: "DA3 coverage: \(manifest.summary).", isError: false))
                            return manifest
                        }

                        func analyzeDa3Model(
                            at modelURL: URL,
                            mapper: String,
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
                                line: "DA3 score: \(ReconstructionScorer.summary(score, mapper: mapper)).",
                                isError: false
                            ))
                            return score
                        }

                        let preparedDa3Model = da3Mode == .direct ? sparseZero : seedZero

                        if try shouldRunStage(.sfmFeatures) {
                            currentStage = .sfmFeatures
                            emit(.stageStarted(stage: .sfmFeatures))
                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 0,
                                message: "Depth Anything 3 SfM started",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageLog(stage: .sfmFeatures, line: "SfM backend: da3-mps.", isError: false))
                            emit(.stageLog(
                                stage: .sfmFeatures,
                                line: "DA3 policy: mode=\(da3Config.mode.rawValue) ordering=\(da3Config.inputOrdering.rawValue) model=\(da3Config.modelSubdirectory) fallback=\(da3Config.fallbackModelSubdirectory) device=\(da3Config.device) processRes=\(da3Config.processResolution) maxPoints=\(da3Config.maxPoints) sharedCamera=\(da3Config.sharedCamera) cameraType=\(da3Config.cameraType) window=\(da3Config.windowSize) overlap=\(da3Config.windowOverlap).",
                                isError: false
                            ))

                            self.removeIfExists(paths.colmapDatabaseURL)
                            try self.resetDirectory(paths.colmapSeedURL)
                            try self.resetDirectory(paths.colmapSparseURL)
                            try self.resetDirectory(sparseZero)
                            self.removeIfExists(da3CoverageManifest)
                            self.removeIfExists(paths.mapanythingCoverageManifestURL)

                            let da3ToolLog = ToolLogWriter(fileURL: paths.da3LogURL, toolName: "da3-mps")
                            da3ToolLog.beginSection(
                                title: "sfm",
                                metadata: [
                                    "device": da3Config.device,
                                    "mode": da3Config.mode.rawValue,
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

                            let solveLabel = da3Mode == .direct ? "direct" : "aligned seed"
                            emit(.stageProgress(stage: .sfmFeatures, fraction: 0.0, message: "Starting DA3 \(solveLabel) solve (\(selectedFrames.count) images)…"))
                            try await self.tooling.da3Sfm.run(
                                toolchain: self.config.toolchain.da3,
                                images: paths.framesSelectedURL,
                                outSparse: preparedDa3Model,
                                config: da3Config,
                                onLog: onDa3Log
                            )
                            guard sparseModelFilesExist(at: preparedDa3Model) else {
                                throw PipelineError.outputMissing
                            }
                            let imagesTxt = preparedDa3Model.appendingPathComponent("images.txt")
                            if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                                emit(.stageLog(
                                    stage: .sfmFeatures,
                                    line: "Normalized DA3 \(solveLabel) COLMAP model (added missing POINTS2D lines to images.txt).",
                                    isError: false
                                ))
                            }
                            let coverageManifest = try readDa3CoverageManifest(required: true)
                            if da3Mode == .direct {
                                let da3ValidationIssues = da3DirectSparseValidationIssues(
                                    paths: paths,
                                    textStats: colmapSparseTextStats(at: sparseZero)
                                )
                                if !da3ValidationIssues.isEmpty {
                                    emit(.stageLog(
                                        stage: currentStage,
                                        line: "DA3 sparse output was inconsistent: \(da3ValidationIssues.joined(separator: "; ")).",
                                        isError: true
                                    ))
                                    throw PipelineError.outputMissing
                                }
                                let rawScore = try await analyzeDa3Model(
                                    at: sparseZero,
                                    mapper: "da3-direct",
                                    toolLog: da3ToolLog
                                )
                                let score = da3ScoreApplyingCoverageFallback(
                                    rawScore,
                                    coverageManifest: coverageManifest
                                )
                                if let rejection = da3DirectQualityFailureReason(score: score, mode: metadata.preset.mode) {
                                    emit(.stageLog(
                                        stage: .sfmFeatures,
                                        line: "DA3 direct solve was below the quality bar (\(rejection)); trying the next SfM backend.",
                                        isError: true
                                    ))
                                    throw PipelineError.lowQualityReconstruction(score, mapper: "da3-direct")
                                }
                                acceptedReconstructionScore = score
                                acceptedReconstructionSummary = ReconstructionSummary(
                                    score: score,
                                    mapper: "da3-direct",
                                    capturedAt: Date()
                                )
                            }
                            if !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                                fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                            }

                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 1.0,
                                message: da3Mode == .direct ? "DA3 direct sparse model ready" : "DA3 aligned pose seed ready",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageFinished(stage: .sfmFeatures))
                            markStageComplete(.sfmFeatures)
                        } else if sparseModelFilesExist(at: preparedDa3Model) && !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                            fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                        }

                        if try shouldRunStage(.sfmMatching) {
                            currentStage = .sfmMatching
                            emit(.stageStarted(stage: .sfmMatching))
                            if da3Mode == .direct {
                                writeCheckpoint(
                                    stage: .sfmMatching,
                                    progress: 1.0,
                                    message: "DA3 direct path skips matching",
                                    details: .sfmMatching(SfmMatchingCheckpoint(
                                        databasePath: paths.colmapDatabaseURL.path,
                                        expectedPairs: nil,
                                        processedPairs: nil
                                    ))
                                )
                                emit(.stageLog(stage: .sfmMatching, line: "DA3 direct solve produced a sparse model directly; skipping matching.", isError: false))
                            } else {
                                writeCheckpoint(
                                    stage: .sfmMatching,
                                    progress: 0,
                                    message: "DA3 refinement matching started",
                                    details: .sfmMatching(SfmMatchingCheckpoint(
                                        databasePath: paths.colmapDatabaseURL.path,
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
                                guard let matchPairs = seedManifest?.boundedMatchPairs,
                                      !matchPairs.isEmpty,
                                      matchPairs.count <= Da3CoverageManifest.hardMatchPairLimit else {
                                    throw PipelineError.outputMissing
                                }
                                let matchListURL = paths.colmapSeedURL.appendingPathComponent("match_pairs.txt")
                                try (matchPairs.joined(separator: "\n") + "\n").write(
                                    to: matchListURL,
                                    atomically: true,
                                    encoding: .utf8
                                )
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
                                let expectedPairs = matchPairs.count
                                let processedPairs = (try? ColmapDatabaseProgressPoller(
                                    databasePath: paths.colmapDatabaseURL
                                ).readProcessedPairCount()) ?? 0
                                writeCheckpoint(
                                    stage: .sfmMatching,
                                    progress: 1.0,
                                    message: "DA3 refinement matching completed",
                                    details: .sfmMatching(SfmMatchingCheckpoint(
                                        databasePath: paths.colmapDatabaseURL.path,
                                        expectedPairs: expectedPairs,
                                        processedPairs: processedPairs
                                    ))
                                )
                            }
                            emit(.stageFinished(stage: .sfmMatching))
                            markStageComplete(.sfmMatching)
                        }

                        if try shouldRunStage(.sfmMapping) {
                            currentStage = .sfmMapping
                            emit(.stageStarted(stage: .sfmMapping))
                            if da3Mode == .direct {
                            guard sparseModelFilesExist(at: sparseZero) else {
                                throw PipelineError.outputMissing
                            }
                            if try ensureTextSparseModelFiles(at: sparseZero) {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Converted DA3 sparse model to COLMAP text format for training compatibility.",
                                    isError: false
                                ))
                            }
                            let imagesTxt = sparseZero.appendingPathComponent("images.txt")
                            if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Normalized DA3 direct COLMAP model (added missing POINTS2D lines to images.txt).",
                                    isError: false
                                ))
                            }
                            let da3ValidationIssues = da3DirectSparseValidationIssues(
                                paths: paths,
                                textStats: colmapSparseTextStats(at: sparseZero)
                            )
                            if !da3ValidationIssues.isEmpty {
                                emit(.stageLog(
                                    stage: currentStage,
                                    line: "DA3 sparse output was inconsistent: \(da3ValidationIssues.joined(separator: "; ")).",
                                    isError: true
                                ))
                                throw PipelineError.outputMissing
                            }
                            writeCheckpoint(
                                stage: .sfmMapping,
                                progress: 1.0,
                                message: "DA3 direct sparse model accepted",
                                details: .sfmMapping(SfmMappingCheckpoint(
                                    mapper: "da3-direct",
                                    sparsePath: sparseZero.path,
                                    registeredImages: nil
                                ))
                            )
                            emit(.stageLog(stage: .sfmMapping, line: "DA3 direct sparse model accepted as the final SfM output.", isError: false))
                            } else {
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
                                    bundleOptions: ColmapBundleAdjustmentOptions(),
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
                                    mapper: "da3-refined",
                                    toolLog: colmapToolLog
                                )
                                guard ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode),
                                      let residual = score.meanReprojectionError,
                                      residual.isFinite else {
                                    throw PipelineError.lowQualityReconstruction(score, mapper: "da3-refined")
                                }
                                acceptedReconstructionScore = score
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
                                        sparsePath: sparseZero.path,
                                        registeredImages: score.registeredImages
                                    ))
                                )
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "DA3 aligned seed accepted after triangulation and bounded bundle adjustment.",
                                    isError: false
                                ))
                            }
                            emit(.stageFinished(stage: .sfmMapping))
                            markStageComplete(.sfmMapping)
                        }
                    } else if backendPolicy == .mapanything {
                        let fm = FileManager.default
                        let seedZero = paths.colmapSeedModelURL
                        let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                        let mapPlan = mapAnythingExecutionPlan(
                            hardwareProfile: detectedHardwareProfile,
                            input: metadata.input,
                            selectedFrameCount: selectedFrames.count,
                            preset: metadata.preset,
                            autoTune: autoTuneProfile,
                            explicitlyRequested: backendOverride == .mapanything
                        )
                        let mapCheckpoint = mapAnythingCheckpointPreference()
                        let mapCoverageManifest = paths.mapanythingCoverageManifestURL
                        let mapRefinementOptions = tuneMapAnythingRefinementColmapOptions(
                            frameCount: selectedFrames.count,
                            extractOptions: colmapExtractOptions,
                            matchOptions: colmapMatchOptions
                        )
                        let mapColmapExtractOptions = mapRefinementOptions.extract
                        let mapColmapMatchOptions = mapRefinementOptions.match
                        var preparedMapAnythingMode = inferPreparedMapAnythingMode(paths: paths)

                        func mapAnythingConfig(mode: MapAnythingRunMode) -> MapAnythingSfmConfig {
                            MapAnythingSfmConfig(
                                device: mapPlan.device,
                                mode: mode,
                                checkpointSubdirectory: mapCheckpoint,
                                resolution: mapPlan.resolution,
                                memoryEfficientInference: mapPlan.memoryEfficientInference,
                                minibatchSize: mapPlan.minibatchSize,
                                useAMP: mapPlan.useAMP,
                                maxPoints: mapPlan.maxPoints,
                                cameraType: mapPlan.cameraType,
                                sharedCamera: mapPlan.sharedCamera,
                                anchorMaxViews: mapPlan.anchorMaxViews,
                                windowSize: mapPlan.windowSize,
                                windowOverlap: mapPlan.windowOverlap,
                                coverageManifestPath: mapCoverageManifest
                            )
                        }

                        func analyzeMapAnythingModel(
                            at modelURL: URL,
                            candidate: String,
                            mapper: String,
                            toolLog: ToolLogWriter? = nil
                        ) async throws -> ReconstructionScore {
                            let report = try await self.tooling.colmap.runModelAnalyzer(
                                colmapPath: self.config.toolchain.colmap,
                                modelPath: modelURL,
                                options: mapColmapMatchOptions
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
                                line: "MapAnything score (\(candidate)): \(ReconstructionScorer.summary(score, mapper: mapper)).",
                                isError: false
                            ))
                            return score
                        }

                        func readMapAnythingCoverageManifest(
                            expectedMode: MapAnythingRunMode,
                            required: Bool
                        ) throws -> MapAnythingCoverageManifest? {
                            guard fm.fileExists(atPath: mapCoverageManifest.path) else {
                                let line = "MapAnything coverage manifest was missing at \(mapCoverageManifest.lastPathComponent)."
                                emit(.stageLog(stage: currentStage, line: line, isError: required))
                                if required {
                                    throw PipelineError.outputMissing
                                }
                                return nil
                            }

                            let manifest: MapAnythingCoverageManifest
                            do {
                                manifest = try MapAnythingCoverageManifest.load(from: mapCoverageManifest)
                            } catch {
                                emit(.stageLog(
                                    stage: currentStage,
                                    line: "MapAnything coverage manifest could not be decoded (\(error.localizedDescription)).",
                                    isError: required
                                ))
                                if required {
                                    throw error
                                }
                                return nil
                            }

                            let issues = manifest.validationIssues(
                                expectedMode: expectedMode,
                                selectedImageCount: selectedFrames.count
                            )
                            if !issues.isEmpty {
                                emit(.stageLog(
                                    stage: currentStage,
                                    line: "MapAnything coverage manifest was inconsistent: \(issues.joined(separator: "; ")).",
                                    isError: required
                                ))
                                if required {
                                    throw PipelineError.outputMissing
                                }
                                return nil
                            }

                            emit(.stageLog(
                                stage: currentStage,
                                line: "MapAnything coverage: \(manifest.summary).",
                                isError: false
                            ))
                            return manifest
                        }

                        if try shouldRunStage(.sfmFeatures) {
                            currentStage = .sfmFeatures
                            emit(.stageStarted(stage: .sfmFeatures))
                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 0,
                                message: "MapAnything SfM started",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageLog(stage: .sfmFeatures, line: "SfM backend: mapanything-mps.", isError: false))
                            emit(.stageLog(
                                stage: .sfmFeatures,
                                line: "MapAnything policy: tier=\(detectedHardwareProfile.tier.rawValue.lowercased()) directLimit=\(mapPlan.directViewLimit) selected=\(selectedFrames.count) mode=\(mapPlan.mode.rawValue) resolution=\(mapPlan.resolution) memoryEfficient=\(mapPlan.memoryEfficientInference) amp=\(mapPlan.useAMP) sharedCamera=\(mapPlan.sharedCamera) window=\(mapPlan.windowSize) overlap=\(mapPlan.windowOverlap) directMinTrack=\(String(format: "%.2f", mapAnythingDirectMinimumMeanTrackLengthPreference(mode: metadata.preset.mode))).",
                                isError: false
                            ))
                            if !mapRefinementOptions.notes.isEmpty {
                                for note in mapRefinementOptions.notes {
                                    emit(.stageLog(stage: .sfmFeatures, line: note, isError: false))
                                }
                            }

                            self.removeIfExists(paths.colmapDatabaseURL)
                            try self.resetDirectory(paths.colmapSeedURL)
                            try self.resetDirectory(seedZero)
                            try self.resetDirectory(paths.colmapSparseURL)
                            try self.resetDirectory(sparseZero)
                            self.removeIfExists(mapCoverageManifest)
                            self.removeIfExists(paths.da3CoverageManifestURL)

                            let mapToolLog = ToolLogWriter(fileURL: paths.mapanythingLogURL, toolName: "mapanything-mps")
                            mapToolLog.beginSection(
                                title: "sfm",
                                metadata: [
                                    "device": mapPlan.device,
                                    "mode": mapPlan.mode.rawValue,
                                    "images": paths.framesSelectedURL.path,
                                    "resolution": "\(mapPlan.resolution)",
                                    "memoryEfficientInference": mapPlan.memoryEfficientInference ? "1" : "0",
                                    "useAMP": mapPlan.useAMP ? "1" : "0",
                                    "maxPoints": "\(mapPlan.maxPoints)",
                                    "sharedCamera": mapPlan.sharedCamera ? "1" : "0",
                                    "cameraType": mapPlan.cameraType,
                                    "anchorMaxViews": "\(mapPlan.anchorMaxViews)",
                                    "windowSize": "\(mapPlan.windowSize)",
                                    "windowOverlap": "\(mapPlan.windowOverlap)",
                                    "checkpoint": mapCheckpoint,
                                    "manifest": mapCoverageManifest.path,
                                    "tool": self.config.toolchain.mapanything.sfmTool.path,
                                    "modelsDir": self.config.toolchain.mapanything.models.path
                                ]
                            )
                            emit(.stageLog(stage: .sfmFeatures, line: "MapAnything tool log: \(paths.mapanythingLogURL.lastPathComponent)", isError: false))
                            emit(.stageLog(stage: .sfmFeatures, line: "MapAnything coverage manifest: \(mapCoverageManifest.lastPathComponent)", isError: false))

                            let onMapAnythingLog: @Sendable (String, Bool) -> Void = { line, isErr in
                                mapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                let sanitized = Self.sanitizeToolLogLine(line)
                                let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                                if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                                    emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: effectiveIsErr))
                                }
                            }

                            var acceptedDirect = false
                            if mapPlan.directAllowed {
                                let directConfig = mapAnythingConfig(mode: .direct)
                                emit(.stageProgress(stage: .sfmFeatures, fraction: 0.0, message: "Starting MapAnything direct solve (\(selectedFrames.count) images)…"))
                                do {
                                    try await self.tooling.mapAnythingSfm.run(
                                        toolchain: self.config.toolchain.mapanything,
                                        images: paths.framesSelectedURL,
                                        outSparse: sparseZero,
                                        config: directConfig,
                                        onLog: onMapAnythingLog
                                    )
                                    guard sparseModelFilesExist(at: sparseZero) else {
                                        throw PipelineError.outputMissing
                                    }
                                    let imagesTxt = sparseZero.appendingPathComponent("images.txt")
                                    if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                                        emit(.stageLog(
                                            stage: .sfmFeatures,
                                            line: "Normalized MapAnything direct COLMAP model (added missing POINTS2D lines to images.txt).",
                                            isError: false
                                        ))
                                    }
                                    let coverageManifest = try readMapAnythingCoverageManifest(
                                        expectedMode: .direct,
                                        required: true
                                    )
                                    let rawScore = try await analyzeMapAnythingModel(
                                        at: sparseZero,
                                        candidate: "direct",
                                        mapper: "mapanything-direct",
                                        toolLog: mapToolLog
                                    )
                                    let score = mapAnythingScoreApplyingCoverageFallback(
                                        rawScore,
                                        coverageManifest: coverageManifest
                                    )
                                    if let rejection = mapAnythingDirectQualityFailureReason(
                                        score: score,
                                        mode: metadata.preset.mode
                                    ) {
                                        emit(.stageLog(
                                            stage: .sfmFeatures,
                                            line: "MapAnything direct solve was below the quality bar (\(rejection)); switching to seed_refine.",
                                            isError: true
                                        ))
                                    } else {
                                        acceptedDirect = true
                                        preparedMapAnythingMode = .direct
                                        acceptedReconstructionScore = score
                                        acceptedReconstructionSummary = ReconstructionSummary(
                                            score: score,
                                            mapper: "mapanything-direct",
                                            capturedAt: Date()
                                        )
                                    }
                                } catch {
                                    if error is CancellationError { throw error }
                                    try Task.checkCancellation()
                                    emit(.stageLog(
                                        stage: .sfmFeatures,
                                        line: "MapAnything direct solve failed (\(failureMessages(for: error, stage: .sfmFeatures).debugMessage)). Switching to seed_refine.",
                                        isError: true
                                    ))
                                }
                            } else {
                                emit(.stageLog(
                                    stage: .sfmFeatures,
                                    line: "MapAnything direct solve disabled on this hardware/profile; using seed_refine.",
                                    isError: false
                                ))
                            }

                            if !acceptedDirect {
                                self.removeIfExists(paths.colmapDatabaseURL)
                                try self.resetDirectory(paths.colmapSeedURL)
                                try self.resetDirectory(seedZero)
                                try self.resetDirectory(paths.colmapSparseURL)
                                let seedConfig = mapAnythingConfig(mode: .seedRefine)
                                emit(.stageProgress(stage: .sfmFeatures, fraction: 0.0, message: "Starting MapAnything seed solve (\(selectedFrames.count) images)…"))
                                try await self.tooling.mapAnythingSfm.run(
                                    toolchain: self.config.toolchain.mapanything,
                                    images: paths.framesSelectedURL,
                                    outSparse: seedZero,
                                    config: seedConfig,
                                    onLog: onMapAnythingLog
                                )
                                guard sparseModelFilesExist(at: seedZero) else {
                                    throw PipelineError.outputMissing
                                }
                                let imagesTxt = seedZero.appendingPathComponent("images.txt")
                                if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                                    emit(.stageLog(
                                        stage: .sfmFeatures,
                                        line: "Normalized MapAnything seed COLMAP model (added missing POINTS2D lines to images.txt).",
                                        isError: false
                                    ))
                                }
                                _ = try readMapAnythingCoverageManifest(
                                    expectedMode: .seedRefine,
                                    required: true
                                )
                                preparedMapAnythingMode = .seedRefine
                            }

                            if !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                                fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                            }

                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 1.0,
                                message: preparedMapAnythingMode == .direct ? "MapAnything direct sparse model ready" : "MapAnything seed model ready",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageFinished(stage: .sfmFeatures))
                            markStageComplete(.sfmFeatures)
                        } else if let preparedMode = inferPreparedMapAnythingMode(paths: paths) {
                            preparedMapAnythingMode = preparedMode
                            if !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                                fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                            }
                        }

                        let effectiveMapAnythingMode = preparedMapAnythingMode ?? inferPreparedMapAnythingMode(paths: paths)
                        guard let effectiveMapAnythingMode else {
                            throw PipelineError.outputMissing
                        }

                        if effectiveMapAnythingMode == .direct {
                            if try shouldRunStage(.sfmMatching) {
                                currentStage = .sfmMatching
                                emit(.stageStarted(stage: .sfmMatching))
                                writeCheckpoint(
                                    stage: .sfmMatching,
                                    progress: 1.0,
                                    message: "MapAnything direct path skips matching",
                                    details: .sfmMatching(SfmMatchingCheckpoint(
                                        databasePath: paths.colmapDatabaseURL.path,
                                        expectedPairs: nil,
                                        processedPairs: nil
                                    ))
                                )
                                emit(.stageLog(stage: .sfmMatching, line: "MapAnything direct solve produced a sparse model directly; skipping matching.", isError: false))
                                emit(.stageFinished(stage: .sfmMatching))
                                markStageComplete(.sfmMatching)
                            }

                            if try shouldRunStage(.sfmMapping) {
                                currentStage = .sfmMapping
                                emit(.stageStarted(stage: .sfmMapping))
                                guard sparseModelFilesExist(at: sparseZero) else {
                                    throw PipelineError.outputMissing
                                }
                                if try ensureTextSparseModelFiles(at: sparseZero) {
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "Converted MapAnything sparse model to COLMAP text format for training compatibility.",
                                        isError: false
                                    ))
                                }
                                let imagesTxt = sparseZero.appendingPathComponent("images.txt")
                                if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "Normalized MapAnything direct COLMAP model (added missing POINTS2D lines to images.txt).",
                                        isError: false
                                    ))
                                }
                                writeCheckpoint(
                                    stage: .sfmMapping,
                                    progress: 1.0,
                                    message: "MapAnything direct sparse model accepted",
                                    details: .sfmMapping(SfmMappingCheckpoint(
                                        mapper: "mapanything-direct",
                                        sparsePath: sparseZero.path,
                                        registeredImages: nil
                                    ))
                                )
                                emit(.stageLog(stage: .sfmMapping, line: "MapAnything direct sparse model accepted as the final SfM output.", isError: false))
                                emit(.stageFinished(stage: .sfmMapping))
                                markStageComplete(.sfmMapping)
                            }
                        } else {
                            if try shouldRunStage(.sfmMatching) {
                                currentStage = .sfmMatching
                                emit(.stageStarted(stage: .sfmMatching))
                                writeCheckpoint(
                                    stage: .sfmMatching,
                                    progress: 0,
                                    message: "MapAnything refinement matching started",
                                    details: .sfmMatching(SfmMatchingCheckpoint(
                                        databasePath: paths.colmapDatabaseURL.path,
                                        expectedPairs: nil,
                                        processedPairs: 0
                                    ))
                                )

                                let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                                colmapToolLog.beginSection(
                                    title: "mapanything_matching",
                                    metadata: [
                                        "database": paths.colmapDatabaseURL.path,
                                        "images": paths.framesSelectedURL.path,
                                        "tool": self.config.toolchain.colmap.path
                                    ]
                                )
                                emit(.stageLog(stage: .sfmMatching, line: "COLMAP tool log: \(paths.colmapLogURL.lastPathComponent)", isError: false))
                                if !mapRefinementOptions.notes.isEmpty {
                                    for note in mapRefinementOptions.notes {
                                        emit(.stageLog(stage: .sfmMatching, line: note, isError: false))
                                    }
                                }
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: mapColmapExtractOptions.useGPU ? "Using GPU for COLMAP feature extraction." : "Using CPU for COLMAP feature extraction.",
                                    isError: false
                                ))
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "MapAnything refinement matching options: overlap=\(mapColmapMatchOptions.sequentialOverlap), maxMatches=\(mapColmapMatchOptions.maxNumMatches.map(String.init) ?? "default"), threads=\(mapColmapMatchOptions.matchThreads).",
                                    isError: false
                                ))
                                emit(.stageProgress(stage: .sfmMatching, fraction: 0.02, message: "Matching views: extracting local features…"))
                                let featureProgress = ColmapFeatureProgressTracker()
                                try await self.tooling.colmap.runFeatureExtractor(
                                    colmapPath: self.config.toolchain.colmap,
                                    database: paths.colmapDatabaseURL,
                                    imagePath: paths.framesSelectedURL,
                                    maxImageSize: colmapMaxImageSize,
                                    cameraModel: mapPlan.cameraType,
                                    singleCamera: mapPlan.sharedCamera,
                                    options: mapColmapExtractOptions,
                                    onLog: { line, isErr in
                                        colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                        let sanitized = Self.sanitizeToolLogLine(line)
                                        let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                                        if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                                            emit(.stageLog(stage: .sfmMatching, line: sanitized, isError: effectiveIsErr))
                                        }
                                        if let update = featureProgress.ingest(line) {
                                            let scaledFraction = min(0.30, update.fraction * 0.30)
                                            let message = update.message.replacingOccurrences(
                                                of: "Finding features",
                                                with: "Matching views: extracting local features"
                                            )
                                            emit(.stageProgress(stage: .sfmMatching, fraction: scaledFraction, message: message))
                                        }
                                    }
                                )
                                self.logKeypointStats(database: paths.colmapDatabaseURL, stage: .sfmMatching, emit: emit)
                                emit(.stageProgress(stage: .sfmMatching, fraction: 0.30, message: "Matching views: starting pair matching…"))

                                let useSequential = self.shouldUseSequential(
                                    selectedFrames: selectedFrames,
                                    input: metadata.input,
                                    forceExhaustive: forceExhaustiveMatching
                                )
                                lastUsedSequentialMatcher = useSequential

                                func runSequentialMatcher() async throws {
                                    let expected = ColmapPairEstimator.expectedSequentialPairs(
                                        imageCount: selectedFrames.count,
                                        overlap: mapColmapMatchOptions.sequentialOverlap
                                    )
                                    emit(.stageLog(
                                        stage: .sfmMatching,
                                        line: "MapAnything refinement matching: sequential matcher (target pairs ≈ \(expected)).",
                                        isError: false
                                    ))
                                    try await self.runColmapMatcherAttempt(
                                        stage: .sfmMatching,
                                        paths: paths,
                                        colmapToolLog: colmapToolLog,
                                        expectedPairs: expected,
                                        progressStart: 0.30,
                                        progressSpan: 0.69,
                                        blockMessageFallback: "Matching views",
                                        invokeMatcher: { onLog in
                                            try await self.tooling.colmap.runMatcherSequential(
                                                colmapPath: self.config.toolchain.colmap,
                                                database: paths.colmapDatabaseURL,
                                                options: mapColmapMatchOptions,
                                                onLog: onLog
                                            )
                                        },
                                        emit: emit
                                    )
                                }

                                func runExhaustiveMatcher() async throws {
                                    let expected = ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                                    emit(.stageLog(
                                        stage: .sfmMatching,
                                        line: "MapAnything refinement matching: exhaustive matcher (target pairs ≈ \(expected)).",
                                        isError: false
                                    ))
                                    try await self.runColmapMatcherAttempt(
                                        stage: .sfmMatching,
                                        paths: paths,
                                        colmapToolLog: colmapToolLog,
                                        expectedPairs: expected,
                                        progressStart: 0.30,
                                        progressSpan: 0.69,
                                        blockMessageFallback: "Matching views",
                                        invokeMatcher: { onLog in
                                            try await self.tooling.colmap.runMatcherExhaustive(
                                                colmapPath: self.config.toolchain.colmap,
                                                database: paths.colmapDatabaseURL,
                                                options: mapColmapMatchOptions,
                                                onLog: onLog
                                            )
                                        },
                                        emit: emit
                                    )
                                }

                                do {
                                    if useSequential {
                                        try await runSequentialMatcher()
                                    } else {
                                        try await runExhaustiveMatcher()
                                    }
                                } catch {
                                    if error is CancellationError { throw error }
                                    try Task.checkCancellation()
                                    if useSequential {
                                        emit(.stageLog(
                                            stage: .sfmMatching,
                                            line: "Sequential matcher failed during MapAnything refinement; retrying with exhaustive matching.",
                                            isError: true
                                        ))
                                        self.emitColmapRetryDiagnostics(error, stage: .sfmMatching, emit: emit)
                                        lastUsedSequentialMatcher = false
                                        try await runExhaustiveMatcher()
                                    } else {
                                        throw error
                                    }
                                }

                                let expectedPairs = lastUsedSequentialMatcher
                                    ? ColmapPairEstimator.expectedSequentialPairs(
                                        imageCount: selectedFrames.count,
                                        overlap: mapColmapMatchOptions.sequentialOverlap
                                    )
                                    : ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                                let processedPairs = (try? ColmapDatabaseProgressPoller(databasePath: paths.colmapDatabaseURL).readProcessedPairCount()) ?? 0
                                writeCheckpoint(
                                    stage: .sfmMatching,
                                    progress: 1.0,
                                    message: "MapAnything refinement matching completed",
                                    details: .sfmMatching(SfmMatchingCheckpoint(
                                        databasePath: paths.colmapDatabaseURL.path,
                                        expectedPairs: expectedPairs,
                                        processedPairs: processedPairs
                                    ))
                                )
                                emit(.stageFinished(stage: .sfmMatching))
                                markStageComplete(.sfmMatching)
                            }

                            if try shouldRunStage(.sfmMapping) {
                                currentStage = .sfmMapping
                                emit(.stageStarted(stage: .sfmMapping))
                                writeCheckpoint(
                                    stage: .sfmMapping,
                                    progress: 0,
                                    message: "MapAnything refinement mapping started",
                                    details: .sfmMapping(SfmMappingCheckpoint(
                                        mapper: "mapanything-refinement",
                                        sparsePath: sparseZero.path,
                                        registeredImages: nil
                                    ))
                                )

                                let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                                colmapToolLog.beginSection(
                                    title: "mapanything_refinement",
                                    metadata: [
                                        "database": paths.colmapDatabaseURL.path,
                                        "images": paths.framesSelectedURL.path,
                                        "seed": seedZero.path,
                                        "output": sparseZero.path,
                                        "tool": self.config.toolchain.colmap.path
                                    ]
                                )
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

                                var acceptedModelURL: URL?
                                var acceptedMapper = "mapanything-refinement"
                                var lastMappingError: Error?

                                do {
                                    guard sparseModelFilesExist(at: seedZero) else {
                                        throw PipelineError.outputMissing
                                    }
                                    if try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                                        seedModelURL: seedZero,
                                        databaseURL: paths.colmapDatabaseURL
                                    ) {
                                        emit(.stageLog(
                                            stage: .sfmMapping,
                                            line: "Aligned MapAnything seed model IDs with COLMAP database IDs.",
                                            isError: false
                                        ))
                                    }
                                    try self.resetDirectory(paths.colmapSparseURL)
                                    try self.resetDirectory(sparseZero)
                                    emit(.stageLog(stage: .sfmMapping, line: "Running refinement: point_triangulator.", isError: false))
                                    try await self.tooling.colmap.runPointTriangulator(
                                        colmapPath: self.config.toolchain.colmap,
                                        database: paths.colmapDatabaseURL,
                                        imagePath: paths.framesSelectedURL,
                                        inputPath: seedZero,
                                        outputPath: sparseZero,
                                        options: mapColmapMatchOptions,
                                        onLog: { line, isErr in
                                            colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                            onMappingLog(line, isErr)
                                        }
                                    )

                                    let baOutput = paths.colmapSparseURL.appendingPathComponent("0_ba", isDirectory: true)
                                    self.removeIfExists(baOutput)
                                    try fm.createDirectory(at: baOutput, withIntermediateDirectories: true)
                                    emit(.stageLog(stage: .sfmMapping, line: "Running refinement: bundle_adjuster.", isError: false))
                                    try await self.tooling.colmap.runBundleAdjuster(
                                        colmapPath: self.config.toolchain.colmap,
                                        inputPath: sparseZero,
                                        outputPath: baOutput,
                                        options: mapColmapMatchOptions,
                                        bundleOptions: ColmapBundleAdjustmentOptions(),
                                        onLog: { line, isErr in
                                            colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                            onMappingLog(line, isErr)
                                        }
                                    )
                                    guard sparseModelFilesExist(at: baOutput) else {
                                        throw PipelineError.outputMissing
                                    }
                                    self.removeIfExists(sparseZero)
                                    try fm.moveItem(at: baOutput, to: sparseZero)

                                    let score = try await analyzeMapAnythingModel(
                                        at: sparseZero,
                                        candidate: "point_triangulator+bundle_adjuster",
                                        mapper: "point_triangulator+bundle_adjuster",
                                        toolLog: colmapToolLog
                                    )
                                    if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                                        acceptedModelURL = sparseZero
                                        acceptedMapper = "point_triangulator+bundle_adjuster"
                                        acceptedReconstructionScore = score
                                        acceptedReconstructionSummary = ReconstructionSummary(
                                            score: score,
                                            mapper: "point_triangulator+bundle_adjuster",
                                            capturedAt: Date()
                                        )
                                    } else {
                                        lastMappingError = PipelineError.lowQualityReconstruction(
                                            score,
                                            mapper: "point_triangulator+bundle_adjuster"
                                        )
                                    }
                                } catch {
                                    if error is CancellationError { throw error }
                                    try Task.checkCancellation()
                                    lastMappingError = error
                                }

                                if acceptedModelURL == nil {
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "MapAnything refinement was not usable; trying solver fallback (global_mapper -> mapper).",
                                        isError: true
                                    ))

                                    let globalMapperToolLog = ToolLogWriter(
                                        fileURL: paths.glomapLogURL,
                                        toolName: "colmap-global_mapper"
                                    )
                                    globalMapperToolLog.beginSection(
                                        title: "mapper_fallback",
                                        metadata: [
                                            "database": paths.colmapDatabaseURL.path,
                                            "images": paths.framesSelectedURL.path,
                                            "output": paths.colmapSparseURL.path,
                                            "tool": self.config.toolchain.colmap.path
                                        ]
                                    )
                                    emit(.stageLog(stage: .sfmMapping, line: "Global mapper log: \(paths.glomapLogURL.lastPathComponent)", isError: false))

                                    func evaluateFallbackModel(candidate: String) async throws -> Bool {
                                        guard sparseModelFilesExist(at: sparseZero) else {
                                            throw PipelineError.outputMissing
                                        }
                                        let score = try await analyzeMapAnythingModel(
                                            at: sparseZero,
                                            candidate: candidate,
                                            mapper: candidate,
                                            toolLog: colmapToolLog
                                        )
                                        if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                                            acceptedModelURL = sparseZero
                                            acceptedMapper = candidate
                                            acceptedReconstructionScore = score
                                            self.warnIfWeakAcceptedSolve(score: score, mapper: candidate, emit: emit)
                                            acceptedReconstructionSummary = ReconstructionSummary(
                                                score: score,
                                                mapper: candidate,
                                                capturedAt: Date()
                                            )
                                            return true
                                        }
                                        lastMappingError = PipelineError.lowQualityReconstruction(score, mapper: candidate)
                                        return false
                                    }

                                    let threadHint = max(mapColmapExtractOptions.extractThreads, mapColmapMatchOptions.matchThreads)
                                    let baseGlobalMapperOptions = self.globalMapperOptions(
                                        threadHint: threadHint,
                                        defaultUseGpu: mapColmapExtractOptions.useGPU || mapColmapMatchOptions.useGPU
                                    )
                                    var shouldTryIncrementalMapper = true

                                    if mapperPreference == .glomap && !disableGlomapForThisRun {
                                        let gpuPreferredOptions = baseGlobalMapperOptions
                                        let gpuRequested = gpuPreferredOptions.useGpuForGlobalPositioning || gpuPreferredOptions.useGpuForBundleAdjustment
                                        do {
                                            try self.resetDirectory(paths.colmapSparseURL)
                                            emit(.stageLog(
                                                stage: .sfmMapping,
                                                line: "Mapper fallback: running COLMAP global_mapper (gp_use_gpu=\(gpuPreferredOptions.useGpuForGlobalPositioning), ba_use_gpu=\(gpuPreferredOptions.useGpuForBundleAdjustment), threads=\(gpuPreferredOptions.numThreads)).",
                                                isError: false
                                            ))
                                            try await self.tooling.colmap.runGlobalMapper(
                                                colmapPath: self.config.toolchain.colmap,
                                                database: paths.colmapDatabaseURL,
                                                imagePath: paths.framesSelectedURL,
                                                outputPath: paths.colmapSparseURL,
                                                options: gpuPreferredOptions,
                                                environment: mapColmapMatchOptions.environment,
                                                onLog: { line, isErr in
                                                    globalMapperToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                                    onMappingLog(line, isErr)
                                                }
                                            )
                                            if try await evaluateFallbackModel(candidate: gpuRequested ? "global_mapper-gpu" : "global_mapper") {
                                                shouldTryIncrementalMapper = false
                                            }
                                        } catch {
                                            if error is CancellationError { throw error }
                                            try Task.checkCancellation()
                                            lastMappingError = error
                                            if let colmapError = error as? ColmapRunnerError,
                                               colmapErrorIndicatesMissingGlobalMapper(colmapError) {
                                                disableGlomapForThisRun = true
                                                emit(.stageLog(
                                                    stage: .sfmMapping,
                                                    line: "COLMAP global_mapper is unavailable in this toolchain; falling back to COLMAP mapper.",
                                                    isError: true
                                                ))
                                            } else if let colmapError = error as? ColmapRunnerError,
                                                      gpuRequested,
                                                      colmapErrorIndicatesGpuFailure(colmapError) {
                                                var cpuOptions = gpuPreferredOptions
                                                cpuOptions.useGpuForGlobalPositioning = false
                                                cpuOptions.useGpuForBundleAdjustment = false
                                                emit(.stageLog(
                                                    stage: .sfmMapping,
                                                    line: "global_mapper GPU path failed; retrying global_mapper with GPU disabled.",
                                                    isError: true
                                                ))
                                                self.emitColmapRetryDiagnostics(colmapError, stage: .sfmMapping, emit: emit)
                                                do {
                                                    try self.resetDirectory(paths.colmapSparseURL)
                                                    try await self.tooling.colmap.runGlobalMapper(
                                                        colmapPath: self.config.toolchain.colmap,
                                                        database: paths.colmapDatabaseURL,
                                                        imagePath: paths.framesSelectedURL,
                                                        outputPath: paths.colmapSparseURL,
                                                        options: cpuOptions,
                                                        environment: mapColmapMatchOptions.environment,
                                                        onLog: { line, isErr in
                                                            globalMapperToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                                            onMappingLog(line, isErr)
                                                        }
                                                    )
                                                    if try await evaluateFallbackModel(candidate: "global_mapper-cpu") {
                                                        shouldTryIncrementalMapper = false
                                                    }
                                                } catch {
                                                    if error is CancellationError { throw error }
                                                    try Task.checkCancellation()
                                                    lastMappingError = error
                                                }
                                            }
                                        }
                                    } else if mapperPreference == .glomap && disableGlomapForThisRun {
                                        emit(.stageLog(stage: .sfmMapping, line: "Skipping global_mapper for this run (disabled after previous launch failure).", isError: true))
                                    }

                                    if shouldTryIncrementalMapper {
                                        emit(.stageLog(
                                            stage: .sfmMapping,
                                            line: "Trying COLMAP incremental mapper fallback.",
                                            isError: true
                                        ))
                                        do {
                                            try self.resetDirectory(paths.colmapSparseURL)
                                            try await self.tooling.colmap.runMapper(
                                                colmapPath: self.config.toolchain.colmap,
                                                database: paths.colmapDatabaseURL,
                                                imagePath: paths.framesSelectedURL,
                                                outputPath: paths.colmapSparseURL,
                                                options: mapColmapMatchOptions,
                                                onLog: { line, isErr in
                                                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                                    onMappingLog(line, isErr)
                                                }
                                            )
                                            _ = try await evaluateFallbackModel(candidate: "colmap")
                                        } catch {
                                            if error is CancellationError { throw error }
                                            try Task.checkCancellation()
                                            lastMappingError = error
                                        }
                                    }
                                }

                                guard let finalSparseModel = acceptedModelURL else {
                                    throw lastMappingError ?? PipelineError.outputMissing
                                }
                                writeCheckpoint(
                                    stage: .sfmMapping,
                                    progress: 1.0,
                                    message: "MapAnything refinement completed",
                                    details: .sfmMapping(SfmMappingCheckpoint(
                                        mapper: acceptedMapper,
                                        sparsePath: finalSparseModel.path,
                                        registeredImages: nil
                                    ))
                                )
                                emit(.stageFinished(stage: .sfmMapping))
                                markStageComplete(.sfmMapping)
                            }
                        }
                    } else if backendPolicy == .fastvggt {
                        let fm = FileManager.default
                        let seedZero = paths.colmapSeedModelURL
                        let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                        let strictFullCoverage = fastvggtFullCoveragePreference()
                        let strictNoFallback = fastvggtNoFallbackPreference()
                        let strictFastVggtMode = strictFullCoverage || strictNoFallback
                        let strictCoverage = fastvggtCoverageConfig(
                            strictModeEnabled: strictFastVggtMode,
                            input: metadata.input,
                            selectedFrameCount: selectedFrames.count,
                            autoTune: autoTuneProfile,
                            hardwareProfile: detectedHardwareProfile,
                            manifestPath: strictFastVggtMode ? paths.fastvggtCoverageManifestURL : nil
                        )
                        let fastSeedModelURL = strictFastVggtMode ? sparseZero : seedZero
                        let fastRequireRefined = fastvggtRequireRefinedModelPreference()
                        let fastUseBA = fastvggtUseBundleAdjustmentPreference()
                        let fastCameraType = vggtCameraTypePreference()
                        let fastSharedCamera = vggtSharedCameraPreference()
                        let fastBAOptions = ColmapBundleAdjustmentOptions(
                            maxNumIterations: fastvggtBaMaxIterationsPreference(),
                            refineFocalLength: fastvggtBaRefineFocalPreference(),
                            refinePrincipalPoint: fastvggtBaRefinePrincipalPointPreference(),
                            refineExtraParams: fastvggtBaRefineExtraParamsPreference()
                        )
                        let fastRefinementOptions = tuneFastVggtRefinementColmapOptions(
                            frameCount: selectedFrames.count,
                            extractOptions: colmapExtractOptions,
                            matchOptions: colmapMatchOptions
                        )
                        let fastColmapExtractOptions = fastRefinementOptions.extract
                        let fastColmapMatchOptions = fastRefinementOptions.match

                        if try shouldRunStage(.sfmFeatures) {
                            currentStage = .sfmFeatures
                            emit(.stageStarted(stage: .sfmFeatures))
                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 0,
                                message: strictFastVggtMode ? "FastVGGT strict full-coverage run started" : "FastVGGT seed export started",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageLog(stage: .sfmFeatures, line: "SfM backend: fastvggt-mps.", isError: false))
                            if strictFastVggtMode {
                                emit(.stageLog(
                                    stage: .sfmFeatures,
                                    line: "FastVGGT strict mode enabled: GPU-only coverage planner=\(strictCoverage.coveragePlanner), no external mapper fallback.",
                                    isError: false
                                ))
                                emit(.stageLog(
                                    stage: .sfmFeatures,
                                    line: fastvggtCoverageSummary(
                                        config: strictCoverage,
                                        autoTune: autoTuneProfile,
                                        hardwareProfile: detectedHardwareProfile
                                    ),
                                    isError: false
                                ))
                            }

                            self.removeIfExists(paths.colmapDatabaseURL)
                            try self.resetDirectory(paths.colmapSeedURL)
                            try self.resetDirectory(seedZero)
                            try self.resetDirectory(paths.colmapSparseURL)

                            let fastDevice = vggtDevicePreference()
                            let fastConfig = FastVggtSfmConfig(
                                device: fastDevice,
                                dtype: fastvggtDtypePreference(),
                                vggtFixedResolution: vggtFixedResolutionValue(autoTune: autoTuneProfile),
                                confidenceThreshold: fastvggtConfidenceThresholdPreference(),
                                maxPoints: vggtMaxPointsValue(preset: metadata.preset, autoTune: autoTuneProfile),
                                merging: fastvggtMergingPreference(),
                                mergeRatio: fastvggtMergeRatioPreference(),
                                sharedCamera: fastSharedCamera,
                                cameraType: fastCameraType,
                                coverage: strictFastVggtMode ? strictCoverage : nil
                            )

                            emit(.stageLog(
                                stage: .sfmFeatures,
                                line: "Running FastVGGT on \(fastConfig.device) (vggt=\(fastConfig.vggtFixedResolution)px, maxPoints=\(fastConfig.maxPoints), merging=\(fastConfig.merging), mergeRatio=\(fastConfig.mergeRatio)).",
                                isError: false
                            ))
                            emit(.stageLog(
                                stage: .sfmFeatures,
                                line: "FastVGGT output: sharedCamera=\(fastConfig.sharedCamera) cameraType=\(fastConfig.cameraType).",
                                isError: false
                            ))
                            emit(.stageLog(
                                stage: .sfmFeatures,
                                line: strictFastVggtMode
                                    ? "FastVGGT refinement policy: strict GPU-only (postprocess=\(strictCoverage.postprocessMode), requireFullCoverage=\(strictCoverage.requireFullCoverage), maxRounds=\(strictCoverage.coverageMaxRounds))."
                                    : "FastVGGT refinement policy: external COLMAP (useBA=\(fastUseBA) requireRefined=\(fastRequireRefined) baMaxIters=\(fastBAOptions.maxNumIterations) refineFocal=\(fastBAOptions.refineFocalLength) refinePP=\(fastBAOptions.refinePrincipalPoint) refineExtra=\(fastBAOptions.refineExtraParams)).",
                                isError: false
                            ))

                            let fastToolLog = ToolLogWriter(fileURL: paths.fastvggtLogURL, toolName: "fastvggt-mps")
                            fastToolLog.beginSection(
                                title: "sfm",
                                metadata: [
                                    "device": fastConfig.device,
                                    "dtype": fastConfig.dtype,
                                    "images": paths.framesSelectedURL.path,
                                    "sharedCamera": "\(fastConfig.sharedCamera)",
                                    "cameraType": fastConfig.cameraType,
                                    "maxPoints": "\(fastConfig.maxPoints)",
                                    "merging": "\(fastConfig.merging)",
                                    "mergeRatio": "\(fastConfig.mergeRatio)",
                                    "modelsDir": self.config.toolchain.fastvggt.models.path,
                                    "outSeedSparse": fastSeedModelURL.path,
                                    "tool": self.config.toolchain.fastvggt.sfmTool.path,
                                    "vggtResolution": "\(fastConfig.vggtFixedResolution)"
                                ]
                            )
                            emit(.stageLog(stage: .sfmFeatures, line: "FastVGGT tool log: \(paths.fastvggtLogURL.lastPathComponent)", isError: false))
                            let fastImagesCount = selectedFrames.count
                            let fastProgress = FastVggtSfmProgressTracker(totalImages: fastImagesCount)
                            let onFastLog: @Sendable (String, Bool) -> Void = { line, isErr in
                                fastToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                if let update = fastProgress.ingest(line) {
                                    emit(.stageProgress(stage: .sfmFeatures, fraction: update.fraction, message: update.message))
                                }
                                let sanitized = Self.sanitizeToolLogLine(line)
                                let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                                if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                                    emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: effectiveIsErr))
                                }
                            }
                            emit(.stageProgress(stage: .sfmFeatures, fraction: 0.0, message: "Starting FastVGGT (\(fastImagesCount) images)…"))
                            try await self.tooling.fastVggtSfm.run(
                                toolchain: self.config.toolchain.fastvggt,
                                images: paths.framesSelectedURL,
                                outSparse: fastSeedModelURL,
                                config: fastConfig,
                                onLog: onFastLog
                            )

                            guard sparseModelFilesExist(at: fastSeedModelURL) else {
                                throw PipelineError.outputMissing
                            }
                            let imagesTxt = fastSeedModelURL.appendingPathComponent("images.txt")
                            if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                                emit(.stageLog(
                                    stage: .sfmFeatures,
                                    line: "Normalized FastVGGT seed COLMAP model (added missing POINTS2D lines to images.txt).",
                                    isError: false
                                ))
                            }

                            if !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                                fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                            }

                            writeCheckpoint(
                                stage: .sfmFeatures,
                                progress: 1.0,
                                message: strictFastVggtMode ? "FastVGGT strict sparse model ready" : "FastVGGT seed model ready",
                                details: .sfmFeatures(SfmFeaturesCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    imageCount: selectedFrames.count
                                ))
                            )
                            emit(.stageFinished(stage: .sfmFeatures))
                            markStageComplete(.sfmFeatures)
                        } else if sparseModelFilesExist(at: fastSeedModelURL) && !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                            fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                        }

                        if strictFastVggtMode {
                            if try shouldRunStage(.sfmMatching) {
                                currentStage = .sfmMatching
                                emit(.stageStarted(stage: .sfmMatching))
                                writeCheckpoint(
                                    stage: .sfmMatching,
                                    progress: 1.0,
                                    message: "FastVGGT strict mode skips external matching",
                                    details: .sfmMatching(SfmMatchingCheckpoint(
                                        databasePath: paths.colmapDatabaseURL.path,
                                        expectedPairs: nil,
                                        processedPairs: nil
                                    ))
                                )
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "FastVGGT strict mode: skipping COLMAP matching stage (no external matcher/fallback).",
                                    isError: false
                                ))
                                emit(.stageFinished(stage: .sfmMatching))
                                markStageComplete(.sfmMatching)
                            }
                        } else if try shouldRunStage(.sfmMatching) {
                            currentStage = .sfmMatching
                            emit(.stageStarted(stage: .sfmMatching))
                            writeCheckpoint(
                                stage: .sfmMatching,
                                progress: 0,
                                message: "FastVGGT refinement matching started",
                                details: .sfmMatching(SfmMatchingCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    expectedPairs: nil,
                                    processedPairs: 0
                                ))
                            )

                            let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                            colmapToolLog.beginSection(
                                title: "fastvggt_matching",
                                metadata: [
                                    "database": paths.colmapDatabaseURL.path,
                                    "images": paths.framesSelectedURL.path,
                                    "tool": self.config.toolchain.colmap.path
                                ]
                            )
                            emit(.stageLog(stage: .sfmMatching, line: "COLMAP tool log: \(paths.colmapLogURL.lastPathComponent)", isError: false))
                            if !fastRefinementOptions.notes.isEmpty {
                                for note in fastRefinementOptions.notes {
                                    emit(.stageLog(stage: .sfmMatching, line: note, isError: false))
                                }
                            }
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: fastColmapExtractOptions.useGPU ? "Using GPU for COLMAP feature extraction." : "Using CPU for COLMAP feature extraction.",
                                isError: false
                            ))
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "FastVGGT refinement matching options: overlap=\(fastColmapMatchOptions.sequentialOverlap), maxMatches=\(fastColmapMatchOptions.maxNumMatches.map(String.init) ?? "default"), threads=\(fastColmapMatchOptions.matchThreads).",
                                isError: false
                            ))
                            emit(.stageProgress(stage: .sfmMatching, fraction: 0.02, message: "Matching views: extracting local features…"))
                            let featureProgress = ColmapFeatureProgressTracker()
                            try await self.tooling.colmap.runFeatureExtractor(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                maxImageSize: colmapMaxImageSize,
                                cameraModel: fastCameraType,
                                singleCamera: fastSharedCamera,
                                options: fastColmapExtractOptions,
                                onLog: { line, isErr in
                                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                    let sanitized = Self.sanitizeToolLogLine(line)
                                    let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                                    if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                                        emit(.stageLog(stage: .sfmMatching, line: sanitized, isError: effectiveIsErr))
                                    }
                                    if let update = featureProgress.ingest(line) {
                                        let scaledFraction = min(0.30, update.fraction * 0.30)
                                        let message = update.message.replacingOccurrences(
                                            of: "Finding features",
                                            with: "Matching views: extracting local features"
                                        )
                                        emit(.stageProgress(stage: .sfmMatching, fraction: scaledFraction, message: message))
                                    }
                                }
                            )
                            self.logKeypointStats(database: paths.colmapDatabaseURL, stage: .sfmMatching, emit: emit)
                            emit(.stageProgress(stage: .sfmMatching, fraction: 0.30, message: "Matching views: starting pair matching…"))

                            let useSequential = self.shouldUseSequential(
                                selectedFrames: selectedFrames,
                                input: metadata.input,
                                forceExhaustive: forceExhaustiveMatching
                            )
                            lastUsedSequentialMatcher = useSequential

                            func runSequentialMatcher() async throws {
                                let expected = ColmapPairEstimator.expectedSequentialPairs(
                                    imageCount: selectedFrames.count,
                                    overlap: fastColmapMatchOptions.sequentialOverlap
                                )
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "FastVGGT refinement matching: sequential matcher (target pairs ≈ \(expected)).",
                                    isError: false
                                ))
                                try await self.runColmapMatcherAttempt(
                                    stage: .sfmMatching,
                                    paths: paths,
                                    colmapToolLog: colmapToolLog,
                                    expectedPairs: expected,
                                    progressStart: 0.30,
                                    progressSpan: 0.69,
                                    blockMessageFallback: "Matching views",
                                    invokeMatcher: { onLog in
                                        try await self.tooling.colmap.runMatcherSequential(
                                            colmapPath: self.config.toolchain.colmap,
                                            database: paths.colmapDatabaseURL,
                                            options: fastColmapMatchOptions,
                                            onLog: onLog
                                        )
                                    },
                                    emit: emit
                                )
                            }

                            func runExhaustiveMatcher() async throws {
                                let expected = ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "FastVGGT refinement matching: exhaustive matcher (target pairs ≈ \(expected)).",
                                    isError: false
                                ))
                                try await self.runColmapMatcherAttempt(
                                    stage: .sfmMatching,
                                    paths: paths,
                                    colmapToolLog: colmapToolLog,
                                    expectedPairs: expected,
                                    progressStart: 0.30,
                                    progressSpan: 0.69,
                                    blockMessageFallback: "Matching views",
                                    invokeMatcher: { onLog in
                                        try await self.tooling.colmap.runMatcherExhaustive(
                                            colmapPath: self.config.toolchain.colmap,
                                            database: paths.colmapDatabaseURL,
                                            options: fastColmapMatchOptions,
                                            onLog: onLog
                                        )
                                    },
                                    emit: emit
                                )
                            }

                            do {
                                if useSequential {
                                    try await runSequentialMatcher()
                                } else {
                                    try await runExhaustiveMatcher()
                                }
                            } catch {
                                if error is CancellationError { throw error }
                                try Task.checkCancellation()
                                if useSequential {
                                    emit(.stageLog(
                                        stage: .sfmMatching,
                                        line: "Sequential matcher failed during FastVGGT refinement; retrying with exhaustive matching.",
                                        isError: true
                                    ))
                                    self.emitColmapRetryDiagnostics(error, stage: .sfmMatching, emit: emit)
                                    lastUsedSequentialMatcher = false
                                    try await runExhaustiveMatcher()
                                } else {
                                    throw error
                                }
                            }

                            let expectedPairs = lastUsedSequentialMatcher
                                ? ColmapPairEstimator.expectedSequentialPairs(
                                    imageCount: selectedFrames.count,
                                    overlap: fastColmapMatchOptions.sequentialOverlap
                                )
                                : ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                            let processedPairs = (try? ColmapDatabaseProgressPoller(databasePath: paths.colmapDatabaseURL).readProcessedPairCount()) ?? 0
                            writeCheckpoint(
                                stage: .sfmMatching,
                                progress: 1.0,
                                message: "FastVGGT refinement matching completed",
                                details: .sfmMatching(SfmMatchingCheckpoint(
                                    databasePath: paths.colmapDatabaseURL.path,
                                    expectedPairs: expectedPairs,
                                    processedPairs: processedPairs
                                ))
                            )
                            emit(.stageFinished(stage: .sfmMatching))
                            markStageComplete(.sfmMatching)
                        }

                        if strictFastVggtMode {
                            if try shouldRunStage(.sfmMapping) {
                                currentStage = .sfmMapping
                                emit(.stageStarted(stage: .sfmMapping))
                                guard sparseModelFilesExist(at: sparseZero) else {
                                    throw PipelineError.outputMissing
                                }
                                writeCheckpoint(
                                    stage: .sfmMapping,
                                    progress: 1.0,
                                    message: "FastVGGT strict sparse model accepted",
                                    details: .sfmMapping(SfmMappingCheckpoint(
                                        mapper: "fastvggt-strict",
                                        sparsePath: sparseZero.path,
                                        registeredImages: nil
                                    ))
                                )
                                if strictCoverage.coverageManifestPath != nil {
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "FastVGGT strict coverage manifest: \(paths.fastvggtCoverageManifestURL.lastPathComponent).",
                                        isError: false
                                    ))
                                }
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "FastVGGT strict mode: skipping external mapping/refinement fallback.",
                                    isError: false
                                ))
                                emit(.stageFinished(stage: .sfmMapping))
                                markStageComplete(.sfmMapping)
                            }
                        } else if try shouldRunStage(.sfmMapping) {
                            currentStage = .sfmMapping
                            emit(.stageStarted(stage: .sfmMapping))
                            writeCheckpoint(
                                stage: .sfmMapping,
                                progress: 0,
                                message: "FastVGGT refinement mapping started",
                                details: .sfmMapping(SfmMappingCheckpoint(
                                    mapper: "fastvggt-refinement",
                                    sparsePath: sparseZero.path,
                                    registeredImages: nil
                                ))
                            )

                            let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
                            colmapToolLog.beginSection(
                                title: "fastvggt_refinement",
                                metadata: [
                                    "database": paths.colmapDatabaseURL.path,
                                    "images": paths.framesSelectedURL.path,
                                    "seed": seedZero.path,
                                    "output": sparseZero.path,
                                    "tool": self.config.toolchain.colmap.path,
                                    "useBA": fastUseBA ? "1" : "0",
                                    "requireRefined": fastRequireRefined ? "1" : "0"
                                ]
                            )
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

                            var acceptedModelURL: URL?
                            var acceptedMapper = "fastvggt-refinement"
                            var lastMappingError: Error?

                            do {
                                guard sparseModelFilesExist(at: seedZero) else {
                                    throw PipelineError.outputMissing
                                }
                                if try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                                    seedModelURL: seedZero,
                                    databaseURL: paths.colmapDatabaseURL
                                ) {
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "Aligned FastVGGT seed model IDs with COLMAP database IDs.",
                                        isError: false
                                    ))
                                }
                                try self.resetDirectory(paths.colmapSparseURL)
                                try self.resetDirectory(sparseZero)
                                emit(.stageLog(stage: .sfmMapping, line: "Running refinement: point_triangulator.", isError: false))
                                try await self.tooling.colmap.runPointTriangulator(
                                    colmapPath: self.config.toolchain.colmap,
                                    database: paths.colmapDatabaseURL,
                                    imagePath: paths.framesSelectedURL,
                                    inputPath: seedZero,
                                    outputPath: sparseZero,
                                    options: fastColmapMatchOptions,
                                    onLog: { line, isErr in
                                        colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                        onMappingLog(line, isErr)
                                    }
                                )

                                var refinedModelURL = sparseZero
                                if fastUseBA {
                                    let baOutput = paths.colmapSparseURL.appendingPathComponent("0_ba", isDirectory: true)
                                    self.removeIfExists(baOutput)
                                    try fm.createDirectory(at: baOutput, withIntermediateDirectories: true)
                                    emit(.stageLog(stage: .sfmMapping, line: "Running refinement: bundle_adjuster.", isError: false))
                                    try await self.tooling.colmap.runBundleAdjuster(
                                        colmapPath: self.config.toolchain.colmap,
                                        inputPath: sparseZero,
                                        outputPath: baOutput,
                                        options: fastColmapMatchOptions,
                                        bundleOptions: fastBAOptions,
                                        onLog: { line, isErr in
                                            colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                            onMappingLog(line, isErr)
                                        }
                                    )
                                    guard sparseModelFilesExist(at: baOutput) else {
                                        throw PipelineError.outputMissing
                                    }
                                    self.removeIfExists(sparseZero)
                                    try fm.moveItem(at: baOutput, to: sparseZero)
                                    refinedModelURL = sparseZero
                                }

                                let report = try await self.tooling.colmap.runModelAnalyzer(
                                    colmapPath: self.config.toolchain.colmap,
                                    modelPath: refinedModelURL,
                                    options: fastColmapMatchOptions
                                )
                                for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                                    colmapToolLog.append(stream: "stdout", line: String(line))
                                }
                                let score = ReconstructionScorer.applyingExpectedTotalImages(
                                    ReconstructionScorer.parseModelAnalyzerOutput(report),
                                    expectedTotalImages: selectedFrames.count
                                )
                                let mapperLabel = fastUseBA ? "point_triangulator+bundle_adjuster" : "point_triangulator"
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "FastVGGT refinement score: \(ReconstructionScorer.summary(score, mapper: mapperLabel)).",
                                    isError: false
                                ))
                                if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                                    acceptedModelURL = refinedModelURL
                                    acceptedMapper = mapperLabel
                                    acceptedReconstructionScore = score
                                    acceptedReconstructionSummary = ReconstructionSummary(
                                        score: score,
                                        mapper: mapperLabel,
                                        capturedAt: Date()
                                    )
                                } else {
                                    lastMappingError = PipelineError.lowQualityReconstruction(score, mapper: mapperLabel)
                                }
                            } catch {
                                if error is CancellationError { throw error }
                                try Task.checkCancellation()
                                lastMappingError = error
                            }

                            if acceptedModelURL == nil {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "FastVGGT refinement was not usable; trying solver fallback (global_mapper -> mapper).",
                                    isError: true
                                ))

                                let globalMapperToolLog = ToolLogWriter(
                                    fileURL: paths.glomapLogURL,
                                    toolName: "colmap-global_mapper"
                                )
                                globalMapperToolLog.beginSection(
                                    title: "mapper_fallback",
                                    metadata: [
                                        "database": paths.colmapDatabaseURL.path,
                                        "images": paths.framesSelectedURL.path,
                                        "output": paths.colmapSparseURL.path,
                                        "tool": self.config.toolchain.colmap.path
                                    ]
                                )
                                emit(.stageLog(stage: .sfmMapping, line: "Global mapper log: \(paths.glomapLogURL.lastPathComponent)", isError: false))

                                func evaluateFallbackModel(candidate: String) async throws -> Bool {
                                    guard sparseModelFilesExist(at: sparseZero) else {
                                        throw PipelineError.outputMissing
                                    }
                                    let report = try await self.tooling.colmap.runModelAnalyzer(
                                        colmapPath: self.config.toolchain.colmap,
                                        modelPath: sparseZero,
                                        options: fastColmapMatchOptions
                                    )
                                    let score = ReconstructionScorer.applyingExpectedTotalImages(
                                        ReconstructionScorer.parseModelAnalyzerOutput(report),
                                        expectedTotalImages: selectedFrames.count
                                    )
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "Mapper fallback score (\(candidate)): \(ReconstructionScorer.summary(score, mapper: candidate)).",
                                        isError: false
                                    ))
                                    if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                                        acceptedModelURL = sparseZero
                                        acceptedMapper = candidate
                                        acceptedReconstructionScore = score
                                        self.warnIfWeakAcceptedSolve(score: score, mapper: candidate, emit: emit)
                                        acceptedReconstructionSummary = ReconstructionSummary(
                                            score: score,
                                            mapper: candidate,
                                            capturedAt: Date()
                                        )
                                        return true
                                    }
                                    lastMappingError = PipelineError.lowQualityReconstruction(score, mapper: candidate)
                                    return false
                                }

                                let threadHint = max(fastColmapExtractOptions.extractThreads, fastColmapMatchOptions.matchThreads)
                                let baseGlobalMapperOptions = self.globalMapperOptions(
                                    threadHint: threadHint,
                                    defaultUseGpu: fastColmapExtractOptions.useGPU || fastColmapMatchOptions.useGPU
                                )
                                var shouldTryIncrementalMapper = true

                                if mapperPreference == .glomap && !disableGlomapForThisRun {
                                    let gpuPreferredOptions = baseGlobalMapperOptions
                                    let gpuRequested = gpuPreferredOptions.useGpuForGlobalPositioning || gpuPreferredOptions.useGpuForBundleAdjustment
                                    do {
                                        try self.resetDirectory(paths.colmapSparseURL)
                                        emit(.stageLog(
                                            stage: .sfmMapping,
                                            line: "Mapper fallback: running COLMAP global_mapper (gp_use_gpu=\(gpuPreferredOptions.useGpuForGlobalPositioning), ba_use_gpu=\(gpuPreferredOptions.useGpuForBundleAdjustment), threads=\(gpuPreferredOptions.numThreads)).",
                                            isError: false
                                        ))
                                        try await self.tooling.colmap.runGlobalMapper(
                                            colmapPath: self.config.toolchain.colmap,
                                            database: paths.colmapDatabaseURL,
                                            imagePath: paths.framesSelectedURL,
                                            outputPath: paths.colmapSparseURL,
                                            options: gpuPreferredOptions,
                                            environment: fastColmapMatchOptions.environment,
                                            onLog: { line, isErr in
                                                globalMapperToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                                onMappingLog(line, isErr)
                                            }
                                        )
                                        if try await evaluateFallbackModel(candidate: gpuRequested ? "global_mapper-gpu" : "global_mapper") {
                                            shouldTryIncrementalMapper = false
                                        }
                                    } catch {
                                        if error is CancellationError { throw error }
                                        try Task.checkCancellation()
                                        lastMappingError = error
                                        if let colmapError = error as? ColmapRunnerError,
                                           colmapErrorIndicatesMissingGlobalMapper(colmapError) {
                                            disableGlomapForThisRun = true
                                            emit(.stageLog(
                                                stage: .sfmMapping,
                                                line: "COLMAP global_mapper is unavailable in this toolchain; falling back to COLMAP mapper.",
                                                isError: true
                                            ))
                                        } else if let colmapError = error as? ColmapRunnerError,
                                                  gpuRequested,
                                                  colmapErrorIndicatesGpuFailure(colmapError) {
                                            var cpuOptions = gpuPreferredOptions
                                            cpuOptions.useGpuForGlobalPositioning = false
                                            cpuOptions.useGpuForBundleAdjustment = false
                                            emit(.stageLog(
                                                stage: .sfmMapping,
                                                line: "global_mapper GPU path failed; retrying global_mapper with GPU disabled.",
                                                isError: true
                                            ))
                                            self.emitColmapRetryDiagnostics(colmapError, stage: .sfmMapping, emit: emit)
                                            do {
                                                try self.resetDirectory(paths.colmapSparseURL)
                                                try await self.tooling.colmap.runGlobalMapper(
                                                    colmapPath: self.config.toolchain.colmap,
                                                    database: paths.colmapDatabaseURL,
                                                    imagePath: paths.framesSelectedURL,
                                                    outputPath: paths.colmapSparseURL,
                                                    options: cpuOptions,
                                                    environment: fastColmapMatchOptions.environment,
                                                    onLog: { line, isErr in
                                                        globalMapperToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                                        onMappingLog(line, isErr)
                                                    }
                                                )
                                                if try await evaluateFallbackModel(candidate: "global_mapper-cpu") {
                                                    shouldTryIncrementalMapper = false
                                                }
                                            } catch {
                                                if error is CancellationError { throw error }
                                                try Task.checkCancellation()
                                                lastMappingError = error
                                            }
                                        }
                                    }
                                } else if mapperPreference == .glomap && disableGlomapForThisRun {
                                    emit(.stageLog(stage: .sfmMapping, line: "Skipping global_mapper for this run (disabled after previous launch failure).", isError: true))
                                }

                                if shouldTryIncrementalMapper {
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "Trying COLMAP incremental mapper fallback.",
                                        isError: true
                                    ))
                                    do {
                                        try self.resetDirectory(paths.colmapSparseURL)
                                        try await self.tooling.colmap.runMapper(
                                            colmapPath: self.config.toolchain.colmap,
                                            database: paths.colmapDatabaseURL,
                                            imagePath: paths.framesSelectedURL,
                                            outputPath: paths.colmapSparseURL,
                                            options: fastColmapMatchOptions,
                                            onLog: { line, isErr in
                                                colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                                onMappingLog(line, isErr)
                                            }
                                        )
                                        _ = try await evaluateFallbackModel(candidate: "colmap")
                                    } catch {
                                        if error is CancellationError { throw error }
                                        try Task.checkCancellation()
                                        lastMappingError = error
                                    }
                                }
                            }

                            if acceptedModelURL == nil, !fastRequireRefined, sparseModelFilesExist(at: seedZero) {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Refinement unavailable; accepting FastVGGT seed model because EASYSPLAT_FASTVGGT_REQUIRE_REFINED_MODEL=0.",
                                    isError: true
                                ))
                                try self.resetDirectory(paths.colmapSparseURL)
                                try self.resetDirectory(sparseZero)
                                let seedFiles = try fm.contentsOfDirectory(at: seedZero, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                                for file in seedFiles {
                                    try fm.copyItem(at: file, to: sparseZero.appendingPathComponent(file.lastPathComponent))
                                }
                                acceptedModelURL = sparseZero
                                acceptedMapper = "fastvggt-seed"
                                // Score the seed model so the viewer's reconstruction panel
                                // still has data even on this opt-in fallback path.
                                // Failures are non-fatal: a missing summary just means the
                                // panel renders without a quality badge.
                                if let report = try? await self.tooling.colmap.runModelAnalyzer(
                                    colmapPath: self.config.toolchain.colmap,
                                    modelPath: sparseZero,
                                    options: fastColmapMatchOptions
                                ) {
                                    let seedScore = ReconstructionScorer.applyingExpectedTotalImages(
                                        ReconstructionScorer.parseModelAnalyzerOutput(report),
                                        expectedTotalImages: selectedFrames.count
                                    )
                                    acceptedReconstructionScore = seedScore
                                    acceptedReconstructionSummary = ReconstructionSummary(
                                        score: seedScore,
                                        mapper: "fastvggt-seed",
                                        capturedAt: Date()
                                    )
                                }
                            }

                            guard let finalSparseModel = acceptedModelURL else {
                                throw lastMappingError ?? PipelineError.outputMissing
                            }
                            writeCheckpoint(
                                stage: .sfmMapping,
                                progress: 1.0,
                                message: "FastVGGT refinement completed",
                                details: .sfmMapping(SfmMappingCheckpoint(
                                    mapper: acceptedMapper,
                                    sparsePath: finalSparseModel.path,
                                    registeredImages: nil
                                ))
                            )
                            emit(.stageFinished(stage: .sfmMapping))
                            markStageComplete(.sfmMapping)
                        }
                    } else if backendPolicy == .vggt {
                let fm = FileManager.default
                let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                let vggtMaxPoints = vggtMaxPointsValue(preset: metadata.preset, autoTune: autoTuneProfile)

                // VGGT produces a COLMAP-format sparse model directly (no database/matching/mapping).
                if try shouldRunStage(.sfmFeatures) {
                    currentStage = .sfmFeatures
                    emit(.stageStarted(stage: .sfmFeatures))
                    writeCheckpoint(
                        stage: .sfmFeatures,
                        progress: 0,
                        message: "VGGT SfM started",
                        details: .sfmFeatures(SfmFeaturesCheckpoint(
                            databasePath: paths.colmapDatabaseURL.path,
                            imageCount: selectedFrames.count
                        ))
                    )
                    emit(.stageLog(stage: .sfmFeatures, line: "SfM backend: vggt-mps.", isError: false))

                    self.removeIfExists(paths.colmapDatabaseURL)
                    try self.resetDirectory(paths.colmapSparseURL)
                    try self.resetDirectory(sparseZero)

                    let vggtDevice = vggtDevicePreference()
                    let baMaxFrames = vggtBaMaxFramesLimit(autoTune: autoTuneProfile)
                    var useBA = vggtUseBundleAdjustmentPreference()
                    if useBA, vggtDevice == "mps", baMaxFrames > 0, selectedFrames.count > baMaxFrames {
                        emit(.stageLog(
                            stage: .sfmFeatures,
                            line: "Auto-tune disabled VGGT bundle adjustment (frames=\(selectedFrames.count) > limit=\(baMaxFrames)).",
                            isError: true
                        ))
                        useBA = false
                    }

                    let vggtConfig = VggtSfmConfig(
                        device: vggtDevice,
                        imageLoadResolution: vggtImageLoadResolutionValue(
                            preset: metadata.preset,
                            autoTune: autoTuneProfile
                        ),
                        vggtFixedResolution: vggtFixedResolutionValue(autoTune: autoTuneProfile),
                        confidenceThreshold: vggtConfidenceThresholdPreference(),
                        maxPoints: vggtMaxPoints,
                        useBundleAdjustment: useBA,
                        maxReprojectionError: vggtMaxReprojectionErrorPreference(),
                        sharedCamera: vggtSharedCameraPreference(),
                        cameraType: vggtCameraTypePreference(),
                        visibilityThreshold: vggtVisibilityThresholdPreference(),
                        queryFrameCount: vggtQueryFrameCountPreference(),
                        maxQueryPoints: vggtMaxQueryPointsPreference(),
                        fineTracking: vggtFineTrackingPreference(),
                        keypointExtractor: vggtKeypointExtractorPreference(),
                        bundleAdjustmentMaxFrames: baMaxFrames
                    )

                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "Running VGGT on \(vggtConfig.device) (load=\(vggtConfig.imageLoadResolution)px, vggt=\(vggtConfig.vggtFixedResolution)px, maxPoints=\(vggtConfig.maxPoints)).",
                        isError: false
                    ))
                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "VGGT BA: use=\(vggtConfig.useBundleAdjustment) maxFrames=\(vggtConfig.bundleAdjustmentMaxFrames) maxReproj=\(vggtConfig.maxReprojectionError) sharedCamera=\(vggtConfig.sharedCamera) cameraType=\(vggtConfig.cameraType) visThresh=\(vggtConfig.visibilityThreshold) queryFrames=\(vggtConfig.queryFrameCount) maxQueryPts=\(vggtConfig.maxQueryPoints) fineTracking=\(vggtConfig.fineTracking) keypointExtractor=\(vggtConfig.keypointExtractor).",
                        isError: false
                    ))

                    let vggtToolLog = ToolLogWriter(fileURL: paths.vggtLogURL, toolName: "vggt-mps")
                    vggtToolLog.beginSection(
                        title: "sfm",
                        metadata: [
                            "device": vggtConfig.device,
                            "images": paths.framesSelectedURL.path,
                            "useBA": "\(vggtConfig.useBundleAdjustment)",
                            "maxFrames": "\(vggtConfig.bundleAdjustmentMaxFrames)",
                            "maxReprojError": "\(vggtConfig.maxReprojectionError)",
                            "sharedCamera": "\(vggtConfig.sharedCamera)",
                            "cameraType": vggtConfig.cameraType,
                            "visThresh": "\(vggtConfig.visibilityThreshold)",
                            "queryFrames": "\(vggtConfig.queryFrameCount)",
                            "maxQueryPts": "\(vggtConfig.maxQueryPoints)",
                            "fineTracking": "\(vggtConfig.fineTracking)",
                            "keypointExtractor": vggtConfig.keypointExtractor,
                            "maxPoints": "\(vggtConfig.maxPoints)",
                            "modelsDir": self.config.toolchain.vggt.models.path,
                            "outSparse": sparseZero.path,
                            "tool": self.config.toolchain.vggt.sfmTool.path,
                            "vggtResolution": "\(vggtConfig.vggtFixedResolution)",
                            "imgLoadResolution": "\(vggtConfig.imageLoadResolution)"
                        ]
                    )
                    emit(.stageLog(stage: .sfmFeatures, line: "VGGT tool log: \(paths.vggtLogURL.lastPathComponent)", isError: false))
                    let vggtImagesCount = selectedFrames.count
                    let vggtProgress = VggtSfmProgressTracker(totalImages: vggtImagesCount)
                    let onVggtLog: @Sendable (String, Bool) -> Void = { line, isErr in
                        vggtToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                        if let update = vggtProgress.ingest(line) {
                            emit(.stageProgress(stage: .sfmFeatures, fraction: update.fraction, message: update.message))
                        }
                        let sanitized = Self.sanitizeToolLogLine(line)
                        let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
                        if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                            emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: effectiveIsErr))
                        }
                    }
                    emit(.stageProgress(stage: .sfmFeatures, fraction: 0.0, message: "Starting VGGT (\(vggtImagesCount) images)…"))
                    try await self.tooling.vggtSfm.run(
                        toolchain: self.config.toolchain.vggt,
                        images: paths.framesSelectedURL,
                        outSparse: sparseZero,
                        config: vggtConfig,
                        onLog: onVggtLog
                    )

                    guard sparseModelFilesExist(at: sparseZero) else {
                        throw PipelineError.outputMissing
                    }
                    let imagesTxt = sparseZero.appendingPathComponent("images.txt")
                    if try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt) {
                        emit(.stageLog(
                            stage: .sfmFeatures,
                            line: "Normalized VGGT COLMAP model (added missing POINTS2D lines to images.txt).",
                            isError: false
                        ))
                    }

                    // Stage completeness expects a database for historical reasons. For VGGT we create a placeholder.
                    if !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                        fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                    }

                    writeCheckpoint(
                        stage: .sfmFeatures,
                        progress: 1.0,
                        message: "VGGT sparse model ready",
                        details: .sfmFeatures(SfmFeaturesCheckpoint(
                            databasePath: paths.colmapDatabaseURL.path,
                            imageCount: selectedFrames.count
                        ))
                    )
                    emit(.stageFinished(stage: .sfmFeatures))
                    markStageComplete(.sfmFeatures)
                } else if sparseModelFilesExist(at: sparseZero) && !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                    fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                }

                if try shouldRunStage(.sfmMatching) {
                    currentStage = .sfmMatching
                    emit(.stageStarted(stage: .sfmMatching))
                    writeCheckpoint(
                        stage: .sfmMatching,
                        progress: 1.0,
                        message: "VGGT path skips matching",
                        details: .sfmMatching(SfmMatchingCheckpoint(
                            databasePath: paths.colmapDatabaseURL.path,
                            expectedPairs: nil,
                            processedPairs: nil
                        ))
                    )
                    emit(.stageLog(stage: .sfmMatching, line: "VGGT produces a sparse model directly; skipping matching.", isError: false))
                    emit(.stageFinished(stage: .sfmMatching))
                    markStageComplete(.sfmMatching)
                }

                if try shouldRunStage(.sfmMapping) {
                    currentStage = .sfmMapping
                    emit(.stageStarted(stage: .sfmMapping))
                    guard sparseModelFilesExist(at: sparseZero) else {
                        throw PipelineError.outputMissing
                    }
                    guard let score = ReconstructionScorer.parseSparseTextModel(
                        at: sparseZero,
                        expectedTotalImages: selectedFrames.count
                    ) else {
                        throw PipelineError.outputMissing
                    }
                    emit(.stageLog(
                        stage: .sfmMapping,
                        line: "VGGT sparse score: \(ReconstructionScorer.summary(score)).",
                        isError: false
                    ))
                    if let failureReason = vggtDirectQualityFailureReason(
                        score: score,
                        selectedFrameCount: selectedFrames.count,
                        mode: metadata.preset.mode,
                        maxPoints: vggtMaxPoints
                    ) {
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "VGGT sparse model rejected: \(failureReason).",
                            isError: true
                        ))
                        throw PipelineError.lowQualityReconstruction(score, mapper: "vggt")
                    }
                    acceptedReconstructionScore = score
                    acceptedReconstructionSummary = ReconstructionSummary(
                        score: score,
                        mapper: "vggt",
                        capturedAt: Date()
                    )
                    writeCheckpoint(
                        stage: .sfmMapping,
                        progress: 1.0,
                        message: "VGGT sparse model accepted",
                        details: .sfmMapping(SfmMappingCheckpoint(
                            mapper: "vggt",
                            sparsePath: sparseZero.path,
                            registeredImages: score.registeredImages
                        ))
                    )
                    emit(.stageLog(stage: .sfmMapping, line: "VGGT produced sparse model; skipping mapping.", isError: false))
                    emit(.stageFinished(stage: .sfmMapping))
                    markStageComplete(.sfmMapping)
                }
            } else {
            let runFeatures: (Bool) async throws -> Void = { force in
                guard try (force || shouldRunStage(.sfmFeatures)) else { return }
                currentStage = .sfmFeatures
                emit(.stageStarted(stage: .sfmFeatures))
                let featureMapperLabel = mapperPreference == .glomap
                    ? "SfM backend: GLOMAP (COLMAP global_mapper), with COLMAP mapper fallback."
                    : "SfM backend: COLMAP mapper only."
                emit(.stageLog(stage: .sfmFeatures, line: featureMapperLabel, isError: false))
                writeCheckpoint(
                    stage: .sfmFeatures,
                    progress: 0,
                    message: "COLMAP feature extraction started",
                    details: .sfmFeatures(SfmFeaturesCheckpoint(
                        databasePath: paths.colmapDatabaseURL.path,
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
                    cameraModel: self.cameraModel(for: metadata.preset),
                    options: colmapExtractOptions,
                    onLog: onFeaturesLog
                )
                self.logKeypointStats(database: paths.colmapDatabaseURL, emit: emit)
                writeCheckpoint(
                    stage: .sfmFeatures,
                    progress: 1.0,
                    message: "COLMAP feature extraction completed",
                    details: .sfmFeatures(SfmFeaturesCheckpoint(
                        databasePath: paths.colmapDatabaseURL.path,
                        imageCount: selectedFrames.count
                    ))
                )
                emit(.stageFinished(stage: .sfmFeatures))
                markStageComplete(.sfmFeatures)
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
                        databasePath: paths.colmapDatabaseURL.path,
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
                    forceExhaustive: forceExhaustiveMatching
                )

                let exhaustiveFallbackMaxFrames = 60
                lastUsedSequentialMatcher = useSequential

                if !useSequential, metadata.input.videoFiles.count > 1 {
                    emit(.stageLog(
                        stage: .sfmMatching,
                        line: "Multiple video clips detected (\(metadata.input.videoFiles.count)); using exhaustive matching so frames from different clips can link. Sequential matching would only connect frames adjacent within one clip.",
                        isError: false
                    ))
                }

                func runSequential() async throws {
                    let expected = ColmapPairEstimator.expectedSequentialPairs(
                        imageCount: selectedFrames.count,
                        overlap: colmapMatchOptions.sequentialOverlap
                    )
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
                }

                func runExhaustive() async throws {
                    let expected = ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
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
                                    cameraModel: self.cameraModel(for: metadata.preset),
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
                    try await runExhaustive()
                }
                let expectedPairs = lastUsedSequentialMatcher
                    ? ColmapPairEstimator.expectedSequentialPairs(
                        imageCount: selectedFrames.count,
                        overlap: colmapMatchOptions.sequentialOverlap
                    )
                    : ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                let processedPairs = (try? ColmapDatabaseProgressPoller(databasePath: paths.colmapDatabaseURL).readProcessedPairCount()) ?? 0
                writeCheckpoint(
                    stage: .sfmMatching,
                    progress: 1.0,
                    message: "COLMAP matching completed",
                    details: .sfmMatching(SfmMatchingCheckpoint(
                        databasePath: paths.colmapDatabaseURL.path,
                        expectedPairs: expectedPairs,
                        processedPairs: processedPairs
                    ))
                )
                emit(.stageFinished(stage: .sfmMatching))
                markStageComplete(.sfmMatching)
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
                guard error is ColmapRunnerError else { return false }
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
                    currentStage = .sfmMapping
                    emit(.stageStarted(stage: .sfmMapping))
                    writeCheckpoint(
                        stage: .sfmMapping,
                        progress: 0,
                        message: "Camera mapping started",
                        details: .sfmMapping(SfmMappingCheckpoint(
                            mapper: mapperPreference.rawValue,
                            sparsePath: paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true).path,
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
                    let globalMapperToolLog = ToolLogWriter(fileURL: paths.glomapLogURL, toolName: "colmap-global_mapper")
                    globalMapperToolLog.beginSection(
                        title: "global_mapper",
                        metadata: [
                            "database": paths.colmapDatabaseURL.path,
                            "images": paths.framesSelectedURL.path,
                            "output": paths.colmapSparseURL.path,
                            "tool": self.config.toolchain.colmap.path
                        ]
                    )
                    let toolLogNames = [paths.colmapLogURL.lastPathComponent, paths.glomapLogURL.lastPathComponent]
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
                    var acceptedMappingStrategy = mapperPreference == .glomap ? "global_mapper" : "colmap"
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
                            message: "Mapping score: \(ReconstructionScorer.summary(score, mapper: candidate))",
                            details: .sfmMapping(SfmMappingCheckpoint(
                                mapper: candidate,
                                sparsePath: modelURL.path,
                                registeredImages: score.registeredImages
                            ))
                        )
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "Reconstruction score (\(candidate)): \(ReconstructionScorer.summary(score, mapper: candidate)).",
                            isError: false
                        ))
                        if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                            acceptedMappingStrategy = candidate
                            acceptedReconstructionScore = score
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

                    let mapperLabel: String = {
                        switch mapperPreference {
                        case .colmap:
                            return "COLMAP mapper only"
                        case .glomap:
                            return disableGlomapForThisRun
                                ? "COLMAP global_mapper disabled for this run; COLMAP mapper fallback only"
                                : "COLMAP global_mapper preferred with COLMAP mapper fallback"
                        }
                    }()
                    emit(.stageLog(
                        stage: .sfmMapping,
                        line: "Mapping preference: \(mapperLabel).",
                        isError: false
                    ))

                    if mapperPreference == .glomap && !disableGlomapForThisRun {
                        let threadHint = max(colmapExtractOptions.extractThreads, colmapMatchOptions.matchThreads)
                        let baseGlobalMapperOptions = self.globalMapperOptions(
                            threadHint: threadHint,
                            defaultUseGpu: colmapExtractOptions.useGPU || colmapMatchOptions.useGPU
                        )
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
                                disableGlomapForThisRun = true
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
                    } else if mapperPreference == .glomap && disableGlomapForThisRun {
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "Skipping global_mapper for this run due to previous launch failure.",
                            isError: true
                        ))
                    }

                    if !mappingSucceeded {
                        if mapperPreference == .glomap {
                            emit(.stageLog(stage: .sfmMapping, line: "global_mapper mapping failed; trying COLMAP mapper.", isError: true))
                        }
                        do {
                            try self.resetDirectory(paths.colmapSparseURL)
                            lastMappingAttempt = "colmap"
                            try await self.tooling.colmap.runMapper(
                                colmapPath: self.config.toolchain.colmap,
                                database: paths.colmapDatabaseURL,
                                imagePath: paths.framesSelectedURL,
                                outputPath: paths.colmapSparseURL,
                                options: colmapMatchOptions,
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
                               case let .lowQualityReconstruction(score, mapper) = pipelineError {
                                let summary = mapper.map { ReconstructionScorer.summary(score, mapper: $0) }
                                    ?? ReconstructionScorer.summary(score)
                                debugMessage = "Low-quality reconstruction. \(summary)."
                            } else if let colmapError = lastMappingError as? ColmapRunnerError {
                                debugMessage = debugDescription(for: colmapError)
                            } else {
                                debugMessage = "\(lastMappingError ?? PipelineError.lowQualityReconstruction(.init(registeredImages: 0, totalImages: 0, meanReprojectionError: nil), mapper: nil))"
                            }
                            let userMessage = "I couldn't get a stable camera solve. Last attempt: \(lastMappingAttempt). Try a slower capture and more light."
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
                                sparsePath: finalSparseModel.path,
                                registeredImages: nil
                            ))
                        )
                        emit(.stageFinished(stage: .sfmMapping))
                        markStageComplete(.sfmMapping)
                }

                break
            }
            }
            } catch {
                if error is CancellationError {
                    throw error
                }
                if Task.isCancelled {
                    throw CancellationError()
                }
                if backendPolicy == .fastvggt && fastvggtNoFallbackPreference() {
                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "FastVGGT strict no-fallback mode is enabled; aborting without backend fallback.",
                        isError: true
                    ))
                    throw error
                }
                let isLast = index == backendOrder.count - 1
                if isLast {
                    throw error
                }
                let nextBackend = backendOrder[index + 1]
                let debug = failureMessages(for: error, stage: .sfmFeatures).debugMessage
                let prefix = backendPolicy == .fastvggt ? "FastVGGT quality fallback" : "\(backendName(backendPolicy)) failed"
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "\(prefix) (\(debug)). Falling back to \(backendName(nextBackend)).",
                    isError: true
                ))
                try? cleanForRetry(failedStage: .sfmFeatures, paths: paths)
                continue
            }
            break
        }

            try Task.checkCancellation()
            if let summary = acceptedReconstructionSummary, metadata.reconstruction != summary {
                metadata.reconstruction = summary
                try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
            }
            if skipTraining {
                emit(.stageLog(
                    stage: .sfmMapping,
                    line: "Stopping early after SfM (EASYSPLAT_SKIP_TRAINING=1 or EASYSPLAT_STOP_AFTER_SFM=1).",
                    isError: false
                ))
                metadata.lastRunStartedAt = nil
                try? ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
                return
            }
            let trainingCutoffMetadata = resumeValidationMode ? metadataForResumeValidation : metadata
            var currentTrainingStartedAt = trainingExportMinimumDate(metadata: trainingCutoffMetadata)
            // When the run resumes from .sfmMapping or later, the SfM stages are skipped and
            // `acceptedReconstructionScore` stays nil even though the persisted reconstruction
            // summary describes a valid solve. Rehydrate from metadata so the automatic
            // Brush-vs-msplat guard sees the same point count the uninterrupted run would have.
            let effectiveReconstructionScore: ReconstructionScore? = acceptedReconstructionScore
                ?? metadata.reconstruction.map(Self.reconstructionScore(fromPersistedSummary:))
            let preferredTrainingBackend = checkpointTrainingBackend(metadata: trainingCutoffMetadata)
                ?? trainingBackendPreference()
            let trainingBackend: TrainingBackend
            if preferredTrainingBackend == .msplat,
               shouldUseBrushInsteadOfAutomaticMsplat(for: effectiveReconstructionScore) {
                let pointCount = effectiveReconstructionScore?.pointCount ?? 0
                let minimumPointCount = automaticMsplatMinimumSparsePoints()
                emit(.stageLog(
                    stage: .sfmMapping,
                    line: "Fast msplat auto-selection skipped because sparse reconstruction has \(pointCount) points (< \(minimumPointCount)); using Brush for predictable training.",
                    isError: false
                ))
                trainingBackend = .brush
            } else {
                trainingBackend = preferredTrainingBackend
            }
            if try shouldRunStage(.trainBrush) {
                currentStage = .trainBrush
                emit(.stageStarted(stage: .trainBrush))
                emit(.trainingBackendSelected(backend: trainingBackend))
                let checkpointTotalSteps = trainingBackend == .brush
                    ? brushTrainingPlan(for: metadata.preset).totalSteps
                    : nil
                writeCheckpoint(
                    stage: .trainBrush,
                    progress: 0,
                    message: "\(trainingBackend.rawValue) training started",
                    details: .trainBrush(TrainBrushCheckpoint(
                        latestExportStep: nil,
                        latestExportPath: nil,
                        progressStep: nil,
                        progressTotal: checkpointTotalSteps,
                        stepsPerSecond: nil,
                        resumeSnapshotPath: trainingBackend == .brush
                            ? paths.trainingURL.appendingPathComponent("latest_snapshot.ply").path
                            : nil,
                        trainingBackend: trainingBackend
                    ))
                )
                if let trainingGate = config.trainingGate {
                    try await trainingGate()
                }
                if trainingBackend == .msplat {
                    let datasetURL = try prepareMsplatDataset(paths: paths, progress: { _, message in
                        emit(.stageProgress(stage: .trainBrush, fraction: -1.0, message: message))
                    })
                    let trainingStartedAt = Date()
                    currentTrainingStartedAt = trainingStartedAt
                    let outputURL = paths.trainingURL.appendingPathComponent("msplat/splat.ply")
                    emit(.stageProgress(stage: .trainBrush, fraction: -1.0, message: "Training model with msplat"))

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
                    try await self.tooling.msplat.runTrain(
                        msplatPath: msplatPath,
                        datasetPath: datasetURL,
                        outputPath: outputURL,
                        iterations: msplatDefaultIterations(),
                        onLog: { line, isErr in
                            msplatToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                            let cleaned = Self.stripAnsiCodes(line)
                            let trimmed = Self.sanitizeToolLogLine(cleaned)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            if Self.shouldEmitToolLogLine(trimmed, isError: isErr) {
                                emit(.stageLog(stage: .trainBrush, line: trimmed, isError: isErr))
                            }
                        }
                    )
                    writeCheckpoint(
                        stage: .trainBrush,
                        progress: 1.0,
                        message: "msplat training completed",
                        details: .trainBrush(TrainBrushCheckpoint(
                            latestExportStep: nil,
                            latestExportPath: outputURL.path,
                            progressStep: nil,
                            progressTotal: nil,
                            stepsPerSecond: nil,
                            resumeSnapshotPath: nil,
                            trainingBackend: .msplat
                        ))
                    )
                    emit(.stageFinished(stage: .trainBrush))
                    markStageComplete(.trainBrush)
                } else {
                    clearBrushResumeSnapshot(in: paths.trainingURL)
                    let brushPlan = brushTrainingPlan(for: metadata.preset)
                    let overrideExportEvery = brushExportEveryOverride()
                    let adaptiveExportEvery = overrideExportEvery ?? brushAdaptiveExportEvery(
                        plan: brushPlan,
                        logURL: paths.brushLogURL
                    )
                    let effectiveExportEvery = adaptiveExportEvery ?? brushPlan.exportEvery
                    // Suppress non-step training logs; details should only update on the configured step cadence.
                    let datasetURL = try prepareBrushDataset(paths: paths, progress: { _, message in
                        // Dataset prep progress is noisy; keep the bar indeterminate until training begins.
                        emit(.stageProgress(stage: .trainBrush, fraction: -1.0, message: message))
                    })
                    let trainingStartedAt = Date()
                    currentTrainingStartedAt = trainingStartedAt
                    let initialStatus = trainingStatusMessage(
                        elapsed: 0,
                        progress: nil,
                        latestExportStep: nil,
                        totalSteps: brushPlan.totalSteps,
                        etaSeconds: nil
                    )
                    emit(.stageProgress(stage: .trainBrush, fraction: -1.0, message: initialStatus))
                    // Suppress non-step training logs; details should only update on the configured step cadence.

                    let brushToolLog = ToolLogWriter(fileURL: paths.brushLogURL, toolName: "brush")
                    brushToolLog.beginSection(
                        title: "train",
                        metadata: [
                            "dataset": datasetURL.path,
                            "tool": self.config.toolchain.brush.path
                        ]
                    )
                    // Suppress non-step training logs; details should only update on the configured step cadence.

                // Brush can take a long time and may not emit newline-delimited logs frequently.
                // Poll for exported .ply files so the user sees forward progress.
                final class BrushProgressBox: @unchecked Sendable {
                    private let lock = NSLock()
                    private var lastSeenStep: Int?
                    private var lastSeenTotal: Int?

                    func latestProgress() -> BrushTrainProgress? {
                        lock.lock()
                        defer { lock.unlock() }
                        guard let step = lastSeenStep, let total = lastSeenTotal else { return nil }
                        return BrushTrainProgress(step: step, total: total)
                    }

                    func update(step: Int, total: Int) {
                        lock.lock()
                        lastSeenStep = step
                        lastSeenTotal = total
                        lock.unlock()
                    }
                }

                final class CheckpointPulseGate: @unchecked Sendable {
                    private let lock = NSLock()
                    private var lastWriteAt: Date = .distantPast

                    func shouldWrite(now: Date, minInterval: TimeInterval) -> Bool {
                        lock.lock()
                        defer { lock.unlock() }
                        if now.timeIntervalSince(lastWriteAt) < minInterval {
                            return false
                        }
                        lastWriteAt = now
                        return true
                    }
                }

                let brushProgress = BrushProgressBox()
                let statusGate = TrainingStatusGate()
                let exportStepBox = BrushExportStepBox()
                let rateBox = BrushTrainingRateBox()
                let etaEstimator = BrushTrainingEtaEstimator()
                let stepLogGate = BrushTrainingStepLogGate(stepInterval: 1_500)
                let checkpointGate = CheckpointPulseGate()
                let snapshotManager = BrushSnapshotManager(
                    defaultExportEvery: effectiveExportEvery,
                    minSteps: brushSnapshotMinSteps(),
                    maxSteps: brushSnapshotMaxSteps(),
                    totalSteps: brushPlan.totalSteps,
                    minSeconds: brushSnapshotMinSeconds(),
                    maxSeconds: brushSnapshotMaxSeconds(),
                    defaultSeconds: brushSnapshotDefaultSeconds()
                )

                let emitTrainingStatus: @Sendable (Date) -> Void = { [self] now in
                    let progress = brushProgress.latestProgress()
                    let latestExportStep = exportStepBox.latestStep()
                    guard statusGate.shouldEmit(now: now) else { return }
                    let elapsed = now.timeIntervalSince(trainingStartedAt)
                    let fraction: Double = {
                        guard let progress else { return -1.0 }
                        let f = Double(progress.step) / Double(progress.total)
                        return min(0.99, max(0.0, f))
                    }()
                    let etaSeconds: TimeInterval? = {
                        guard let progress else { return nil }
                        return etaEstimator.estimateRemainingSeconds(step: progress.step, total: progress.total)
                    }()
                    let status = self.trainingStatusMessage(
                        elapsed: elapsed,
                        progress: progress,
                        latestExportStep: latestExportStep,
                        totalSteps: brushPlan.totalSteps,
                        etaSeconds: etaSeconds
                    )
                    emit(.stageProgress(stage: .trainBrush, fraction: fraction, message: status))
                }

                let monitorTask = Task { [
                    trainingURL = paths.trainingURL,
                    trainingStartedAt,
                    emitTrainingStatus,
                    exportStepBox,
                    snapshotManager,
                    rateBox,
                    self
                ] in
                    var lastSeen: String? = nil
                    var lastExportCheckAt = Date.distantPast
                    let exportCheckInterval: TimeInterval = 5.0
                    while !Task.isCancelled {
                        let now = Date()
                        if now.timeIntervalSince(lastExportCheckAt) >= exportCheckInterval {
                            lastExportCheckAt = now
                            if let export = latestBrushExport(in: trainingURL, minModificationDate: trainingStartedAt) {
                                let name = export.file.lastPathComponent
                                if name != lastSeen {
                                    lastSeen = name
                                    if let step = export.step {
                                        exportStepBox.update(step: step)
                                        self.updateBrushResumeSnapshot(from: export.file, trainingURL: trainingURL)
                                        let decision = snapshotManager.handleSnapshot(
                                            file: export.file,
                                            step: step,
                                            stepsPerSecond: rateBox.latestRate()
                                        )
                                        if let deleteURL = decision.delete {
                                            try? FileManager.default.removeItem(at: deleteURL)
                                        }
                                        if decision.keep {
                                            // Keep snapshots silently; training logs must be step-gated.
                                        }
                                        self.persistCheckpoint(
                                            paths: paths,
                                            stage: .trainBrush,
                                            progress: nil,
                                            message: "Saved training snapshot at step \(step)",
                                            details: .trainBrush(TrainBrushCheckpoint(
                                                latestExportStep: step,
                                                latestExportPath: export.file.path,
                                                progressStep: brushProgress.latestProgress()?.step,
                                                progressTotal: brushProgress.latestProgress()?.total ?? brushPlan.totalSteps,
                                                stepsPerSecond: rateBox.latestRate(),
                                                resumeSnapshotPath: trainingURL.appendingPathComponent("latest_snapshot.ply").path,
                                                trainingBackend: .brush
                                            ))
                                        )
                                    } else {
                                        // Keep snapshots silently; training logs must be step-gated.
                                    }
                                }
                            }
                        }
                        if checkpointGate.shouldWrite(now: now, minInterval: 15.0) {
                            let progress = brushProgress.latestProgress()
                            let fraction: Double? = {
                                guard let progress, progress.total > 0 else { return nil }
                                return min(0.99, max(0.0, Double(progress.step) / Double(progress.total)))
                            }()
                            self.persistCheckpoint(
                                paths: paths,
                                stage: .trainBrush,
                                progress: fraction,
                                message: "Training heartbeat",
                                details: .trainBrush(TrainBrushCheckpoint(
                                    latestExportStep: exportStepBox.latestStep(),
                                    latestExportPath: self.latestBrushExport(
                                        in: trainingURL,
                                        minModificationDate: trainingStartedAt
                                    )?.file.path,
                                    progressStep: progress?.step,
                                    progressTotal: progress?.total ?? brushPlan.totalSteps,
                                    stepsPerSecond: rateBox.latestRate(),
                                    resumeSnapshotPath: trainingURL.appendingPathComponent("latest_snapshot.ply").path,
                                    trainingBackend: .brush
                                ))
                            )
                        }
                        emitTrainingStatus(now)
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                defer { monitorTask.cancel() }

                defer {
                    updateResumeSnapshotFromLatestExport(
                        trainingURL: paths.trainingURL,
                        minModificationDate: trainingStartedAt
                    )
                }

                try await self.tooling.brush.runTrain(
                    brushPath: self.config.toolchain.brush,
                    datasetPath: datasetURL,
                    totalSteps: brushPlan.totalSteps,
                    exportEvery: effectiveExportEvery,
                    onLog: { line, isErr in
                        brushToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)

                        let cleaned = Self.stripAnsiCodes(line)
                        if let progress = self.brushTrainStepProgress(from: cleaned),
                           progress.total > 0,
                           progress.step >= 0,
                           progress.step <= progress.total {
                            brushProgress.update(step: progress.step, total: progress.total)
                            emitTrainingStatus(Date())
                            if checkpointGate.shouldWrite(now: Date(), minInterval: 15.0) {
                                self.persistCheckpoint(
                                    paths: paths,
                                    stage: .trainBrush,
                                    progress: min(0.99, max(0.0, Double(progress.step) / Double(progress.total))),
                                    message: "Training step \(progress.step)/\(progress.total)",
                                    details: .trainBrush(TrainBrushCheckpoint(
                                        latestExportStep: exportStepBox.latestStep(),
                                        latestExportPath: self.latestBrushExport(
                                            in: paths.trainingURL,
                                            minModificationDate: trainingStartedAt
                                        )?.file.path,
                                        progressStep: progress.step,
                                        progressTotal: progress.total,
                                        stepsPerSecond: rateBox.latestRate(),
                                        resumeSnapshotPath: paths.trainingURL.appendingPathComponent("latest_snapshot.ply").path,
                                        trainingBackend: .brush
                                    ))
                                )
                            }
                            if stepLogGate.shouldEmit(step: progress.step) {
                                let now = Date()
                                let etaSeconds = etaEstimator.estimateRemainingSeconds(
                                    step: progress.step,
                                    total: progress.total
                                )
                                let message = self.trainingStatusMessage(
                                    elapsed: now.timeIntervalSince(trainingStartedAt),
                                    progress: progress,
                                    latestExportStep: exportStepBox.latestStep(),
                                    totalSteps: brushPlan.totalSteps,
                                    etaSeconds: etaSeconds
                                )
                                emit(.stageLog(stage: .trainBrush, line: message, isError: false))
                            }
                        }
                        if let rate = self.brushTrainStepRate(from: cleaned) {
                            rateBox.update(rate: rate)
                            etaEstimator.update(rate: rate)
                        }

                        // Brush tends to write status spinners and "ok" lines to stderr, often via "\r"
                        // redraws. Those would drown out our own stage progress updates, so only surface
                        // lines that look like real warnings/errors.
                        let sanitized = Self.sanitizeToolLogLine(cleaned)
                        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }

                        if Self.looksLikeBrushSpinnerLine(trimmed) {
                            return
                        }

                        let lower = trimmed.lowercased()
                        let looksErrorish = Self.looksLikeErrorishLine(lower)
                        let effectiveIsErr = isErr && looksErrorish

                        if effectiveIsErr, Self.shouldEmitToolLogLine(trimmed, isError: effectiveIsErr) {
                            emit(.stageLog(stage: .trainBrush, line: trimmed, isError: true))
                        }
                    }
                )
                writeCheckpoint(
                    stage: .trainBrush,
                    progress: 1.0,
                    message: "Brush training completed",
                    details: .trainBrush(TrainBrushCheckpoint(
                        latestExportStep: exportStepBox.latestStep(),
                        latestExportPath: latestBrushExport(
                            in: paths.trainingURL,
                            minModificationDate: trainingStartedAt
                        )?.file.path,
                        progressStep: brushPlan.totalSteps,
                        progressTotal: brushPlan.totalSteps,
                        stepsPerSecond: rateBox.latestRate(),
                        resumeSnapshotPath: paths.trainingURL.appendingPathComponent("latest_snapshot.ply").path,
                        trainingBackend: .brush
                    ))
                )
                emit(.stageFinished(stage: .trainBrush))
                markStageComplete(.trainBrush)
                }
            }

            try Task.checkCancellation()
            if try shouldRunStage(.exportSplat) {
                currentStage = .exportSplat
                emit(.stageStarted(stage: .exportSplat))
                writeCheckpoint(stage: .exportSplat, progress: 0, message: "Export started")
                guard let ply = latestTrainingExport(
                    in: paths.trainingURL,
                    backend: trainingBackend,
                    minModificationDate: currentTrainingStartedAt
                ) else {
                    throw PipelineError.outputMissing
                }
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
                        outputPath: outputPly.path,
                        sourcePath: ply.path,
                        sizeBytes: sizeBytes
                    ))
                )
                emit(.stageFinished(stage: .exportSplat))
                markStageComplete(.exportSplat)
            }

            metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
            metadata.state = PipelineState(stage: .done, attempt: metadata.state.attempt, lastError: nil, resumeToken: nil)
            metadata.lastRunStartedAt = nil
            try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)

            emit(.stageFinished(stage: .done))
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
            paths.glomapLogURL,
            paths.da3LogURL,
            paths.mapanythingLogURL,
            paths.vggtLogURL,
            paths.fastvggtLogURL,
            paths.brushLogURL,
            paths.msplatLogURL,
        ]
        for url in toolLogs where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }
}
