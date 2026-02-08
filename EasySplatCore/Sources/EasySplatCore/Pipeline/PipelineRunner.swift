import Foundation
import Dispatch
import ImageIO
import SQLite3
import UniformTypeIdentifiers

public final class PipelineRunner: @unchecked Sendable {

    public struct Tooling {
        public var colmap: ColmapRunner
        public var glomap: GlomapRunner
        public var brush: BrushRunner
        public var vggtSfm: VggtSfmRunning
        public var fastVggtSfm: FastVggtSfmRunning

        public init(colmap: ColmapRunner = ColmapRunner(),
                    glomap: GlomapRunner = GlomapRunner(),
                    brush: BrushRunner = BrushRunner(),
                    vggtSfm: VggtSfmRunning = VggtSfmRunner(),
                    fastVggtSfm: FastVggtSfmRunning = FastVggtSfmRunner()) {
            self.colmap = colmap
            self.glomap = glomap
            self.brush = brush
            self.vggtSfm = vggtSfm
            self.fastVggtSfm = fastVggtSfm
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.glomap = GlomapRunner(runner: runner)
            self.brush = BrushRunner(runner: runner)
            self.vggtSfm = VggtSfmRunner(runner: runner)
            self.fastVggtSfm = FastVggtSfmRunner(runner: runner)
        }
    }
    public struct PipelineConfig: Sendable {
        public var toolchain: ToolchainPaths
        public var preset: PresetSpec
        public var trainingGate: (@Sendable () async throws -> Void)?

        public init(
            toolchain: ToolchainPaths,
            preset: PresetSpec,
            trainingGate: (@Sendable () async throws -> Void)? = nil
        ) {
            self.toolchain = toolchain
            self.preset = preset
            self.trainingGate = trainingGate
        }
    }

    private let projectURL: URL
    private let config: PipelineConfig
    private let tooling: Tooling

    private enum SfmMapperPreference: String {
        case glomap
        case colmap
    }

    public init(projectURL: URL, config: PipelineConfig, tooling: Tooling = Tooling()) {
        self.projectURL = projectURL
        self.config = config
        self.tooling = tooling
    }

    public func run(resumeFrom lastCompletedStage: PipelineStage? = nil, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
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
            guard let raw = ProcessInfo.processInfo.environment["EASYSPLAT_SKIP_TRAINING"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty else {
                return false
            }
            return raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
        }()

        metadata.recoveryPromptSuppressed = false
        metadata.lastRunStartedAt = Date()
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
            try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        }

        func shouldRunStage(_ stage: PipelineStage) throws -> Bool {
            guard let lastCompletedStage else { return true }
            if stageIndex(stage) <= stageIndex(lastCompletedStage) {
                if !resumeValidationMode {
                    return !isStageComplete(stage, paths: paths, metadata: metadata)
                }
                switch try validateStageOutput(stage, paths: paths, metadata: metadata) {
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
            metadata.state = PipelineState(stage: stage, attempt: metadata.state.attempt, lastError: nil, resumeToken: nil)
            metadata.checkpoint = nil
            try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        }

        func emitFailure(stage: PipelineStage, userMessage: String, debugMessage: String) {
            didEmitFailure = true
            metadata.state = PipelineState(stage: stage, attempt: metadata.state.attempt, lastError: userMessage, resumeToken: nil)
            metadata.checkpoint = nil
            metadata.lastRunStartedAt = nil
            try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
            var colmapMaxImageSize = Int(maxDim)
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
                    let totalVideos = Double(max(videos.count, 1))
                    for (index, file) in videos.enumerated() {
                        try Task.checkCancellation()
                        let sourceName = URL(fileURLWithPath: file).lastPathComponent
                        let videoURL = paths.originalsURL.appendingPathComponent(sourceName)
                        let perVideoTarget = targetCountForVideo(index: index, total: videos.count, targetCount: targetFrames)
                        if perVideoTarget == 0 {
                            continue
                        }
                        emit(.stageLog(
                            stage: .extractFrames,
                            line: "Extracting frames from \(sourceName) (target=\(perVideoTarget), maxDim=\(Int(maxDim))px).",
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
                                outputFormat: frameProfile.outputFormat
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
                            let sharpnessByFrame = scoreSharpnessForFrames(
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

                    let selection = try copySelected(
                        groups: groups,
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
                            groupsProcessed: groups.count,
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
                emit(.stageLog(stage: .sfmFeatures, line: tune.summary(profile: detectedHardwareProfile), isError: false))
            }

            try Task.checkCancellation()
            let backendOverride = sfmBackendOverride()
            var backendOrder = sfmBackendFallbackOrder(override: backendOverride)
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
                case .fastvggt:
                    return "FastVGGT"
                case .vggt:
                    return "VGGT"
                case .colmap:
                    return "COLMAP + GLOMAP"
                }
            }

            for (index, backendPolicy) in backendOrder.enumerated() {
                do {
                    if backendPolicy == .fastvggt {
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
                                if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                                    emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: isErr))
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
                                    if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                                        emit(.stageLog(stage: .sfmMatching, line: sanitized, isError: isErr))
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
                            emit(.stageProgress(stage: .sfmMatching, fraction: 0.30, message: "Matching views: starting pair matching…"))

                            let useSequential = self.shouldUseSequential(
                                selectedFrames: selectedFrames,
                                input: metadata.input,
                                forceExhaustive: forceExhaustiveMatching
                            )
                            lastUsedSequentialMatcher = useSequential

                            final class MatchingProgressState: @unchecked Sendable {
                                private let lock = NSLock()
                                private var latestBlockMessage: String?

                                func updateBlockMessage(_ message: String) {
                                    lock.lock()
                                    latestBlockMessage = message
                                    lock.unlock()
                                }

                                func blockMessage() -> String? {
                                    lock.lock()
                                    defer { lock.unlock() }
                                    return latestBlockMessage
                                }
                            }

                            func runMatcherWithProgress(
                                expectedPairs: Int,
                                run: @escaping (@escaping @Sendable (String, Bool) -> Void) async throws -> Void
                            ) async throws {
                                let state = MatchingProgressState()
                                let blockProgress = ColmapMatchingProgressTracker()
                                let onLog: @Sendable (String, Bool) -> Void = { line, isErr in
                                    colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                                    let sanitized = Self.sanitizeToolLogLine(line)
                                    if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                                        emit(.stageLog(stage: .sfmMatching, line: sanitized, isError: isErr))
                                    }
                                    if let update = blockProgress.ingest(line) {
                                        state.updateBlockMessage(update.message)
                                    }
                                }

                                let poller = ColmapDatabaseProgressPoller(databasePath: paths.colmapDatabaseURL)
                                let pollTask = Task.detached(priority: .utility) { [expectedPairs, poller, state, emit] in
                                    let denom = max(1, expectedPairs)
                                    var lastFraction: Double = 0
                                    var lastProcessed = -1
                                    var lastEmit = Date.distantPast

                                    while !Task.isCancelled {
                                        var processed = (try? poller.readProcessedPairCount()) ?? 0
                                        if lastProcessed >= 0, processed < lastProcessed {
                                            processed = lastProcessed
                                        }
                                        let rawFraction = Double(processed) / Double(denom)
                                        let clamped = max(0, min(0.99, rawFraction))
                                        if clamped > lastFraction {
                                            lastFraction = clamped
                                        }

                                        let now = Date()
                                        let shouldEmitZeroHeartbeat = processed == 0 && now.timeIntervalSince(lastEmit) >= 10
                                        if processed != lastProcessed || shouldEmitZeroHeartbeat {
                                            lastProcessed = processed
                                            lastEmit = now
                                            let base = state.blockMessage()
                                            let message: String
                                            if let base {
                                                message = "\(base), pairs \(processed)/\(denom)"
                                            } else {
                                                message = "Matching views (pairs \(processed)/\(denom))"
                                            }
                                            let scaledFraction = min(0.99, 0.30 + (lastFraction * 0.69))
                                            emit(.stageProgress(stage: .sfmMatching, fraction: scaledFraction, message: message))
                                        }

                                        try? await Task.sleep(for: .seconds(1))
                                    }
                                }
                                defer { pollTask.cancel() }

                                try await run(onLog)
                            }

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
                                try await runMatcherWithProgress(expectedPairs: expected) { onLog in
                                    try await self.tooling.colmap.runMatcherSequential(
                                        colmapPath: self.config.toolchain.colmap,
                                        database: paths.colmapDatabaseURL,
                                        options: fastColmapMatchOptions,
                                        onLog: onLog
                                    )
                                }
                            }

                            func runExhaustiveMatcher() async throws {
                                let expected = ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "FastVGGT refinement matching: exhaustive matcher (target pairs ≈ \(expected)).",
                                    isError: false
                                ))
                                try await runMatcherWithProgress(expectedPairs: expected) { onLog in
                                    try await self.tooling.colmap.runMatcherExhaustive(
                                        colmapPath: self.config.toolchain.colmap,
                                        database: paths.colmapDatabaseURL,
                                        options: fastColmapMatchOptions,
                                        onLog: onLog
                                    )
                                }
                            }

                            do {
                                if useSequential {
                                    try await runSequentialMatcher()
                                } else {
                                    try await runExhaustiveMatcher()
                                }
                            } catch {
                                if useSequential {
                                    emit(.stageLog(
                                        stage: .sfmMatching,
                                        line: "Sequential matcher failed during FastVGGT refinement; retrying with exhaustive matching.",
                                        isError: true
                                    ))
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
                                if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                                    emit(.stageLog(stage: .sfmMapping, line: sanitized, isError: isErr))
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
                                let score = ReconstructionScorer.parseModelAnalyzerOutput(report)
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "FastVGGT refinement score: \(ReconstructionScorer.summary(score)).",
                                    isError: false
                                ))
                                if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                                    acceptedModelURL = refinedModelURL
                                    acceptedMapper = fastUseBA ? "point_triangulator+bundle_adjuster" : "point_triangulator"
                                } else {
                                    lastMappingError = PipelineError.lowQualityReconstruction(score)
                                }
                            } catch {
                                lastMappingError = error
                            }

                            if acceptedModelURL == nil {
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "FastVGGT refinement was not usable; trying mapper fallback.",
                                    isError: true
                                ))

                                let usesGlomap = mapperPreference == .glomap && !disableGlomapForThisRun
                                let glomapToolLog: ToolLogWriter? = {
                                    guard usesGlomap else { return nil }
                                    let log = ToolLogWriter(fileURL: paths.glomapLogURL, toolName: "glomap")
                                    log.beginSection(
                                        title: "mapper_fallback",
                                        metadata: [
                                            "database": paths.colmapDatabaseURL.path,
                                            "images": paths.framesSelectedURL.path,
                                            "output": paths.colmapSparseURL.path,
                                            "tool": self.config.toolchain.glomap.path
                                        ]
                                    )
                                    return log
                                }()

                                let mapperAttempts: [SfmMapperPreference] = {
                                    switch mapperPreference {
                                    case .colmap:
                                        return [.colmap]
                                    case .glomap:
                                        if disableGlomapForThisRun {
                                            return [.colmap]
                                        }
                                        return [.glomap, .colmap]
                                    }
                                }()

                                for (attemptIndex, mapper) in mapperAttempts.enumerated() {
                                    do {
                                        try self.resetDirectory(paths.colmapSparseURL)
                                        if mapper == .glomap {
                                            try await self.tooling.glomap.runMapper(
                                                glomapPath: self.config.toolchain.glomap,
                                                database: paths.colmapDatabaseURL,
                                                imagePath: paths.framesSelectedURL,
                                                outputPath: paths.colmapSparseURL,
                                                onLog: { line, isErr in
                                                    glomapToolLog?.append(stream: isErr ? "stderr" : "stdout", line: line)
                                                    onMappingLog(line, isErr)
                                                }
                                            )
                                        } else {
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
                                        }

                                        guard sparseModelFilesExist(at: sparseZero) else {
                                            throw PipelineError.outputMissing
                                        }
                                        let report = try await self.tooling.colmap.runModelAnalyzer(
                                            colmapPath: self.config.toolchain.colmap,
                                            modelPath: sparseZero,
                                            options: fastColmapMatchOptions
                                        )
                                        let score = ReconstructionScorer.parseModelAnalyzerOutput(report)
                                        emit(.stageLog(
                                            stage: .sfmMapping,
                                            line: "Mapper fallback score: \(ReconstructionScorer.summary(score)).",
                                            isError: false
                                        ))
                                        if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                                            acceptedModelURL = sparseZero
                                            acceptedMapper = mapper == .glomap ? "glomap" : "colmap"
                                            break
                                        }
                                        lastMappingError = PipelineError.lowQualityReconstruction(score)
                                    } catch {
                                        if mapper == .glomap,
                                           !disableGlomapForThisRun,
                                           glomapErrorIndicatesMissingOpenSSL(error) {
                                            disableGlomapForThisRun = true
                                            emit(.stageLog(
                                                stage: .sfmMapping,
                                                line: "GLOMAP failed to launch (missing OpenSSL dylibs / rpath). Falling back to COLMAP mapper.",
                                                isError: true
                                            ))
                                        }
                                        lastMappingError = error
                                    }

                                    if attemptIndex == 0, mapper == .glomap {
                                        emit(.stageLog(stage: .sfmMapping, line: "GLOMAP mapping failed; trying COLMAP mapper.", isError: true))
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
                        maxPoints: vggtMaxPointsValue(preset: metadata.preset, autoTune: autoTuneProfile),
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
                        if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                            emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: isErr))
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
                    writeCheckpoint(
                        stage: .sfmMapping,
                        progress: 1.0,
                        message: "VGGT sparse model accepted",
                        details: .sfmMapping(SfmMappingCheckpoint(
                            mapper: "vggt",
                            sparsePath: sparseZero.path,
                            registeredImages: nil
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
                    if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                        emit(.stageLog(stage: .sfmFeatures, line: sanitized, isError: isErr))
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

                final class MatchingProgressState: @unchecked Sendable {
                    private let lock = NSLock()
                    private var latestBlockMessage: String?

                    func updateBlockMessage(_ message: String) {
                        lock.lock()
                        latestBlockMessage = message
                        lock.unlock()
                    }

                    func blockMessage() -> String? {
                        lock.lock()
                        defer { lock.unlock() }
                        return latestBlockMessage
                    }
                }

                let exhaustiveFallbackMaxFrames = 60
                lastUsedSequentialMatcher = useSequential

                func runMatcherWithProgress(
                    expectedPairs: Int,
                    run: @escaping (@escaping @Sendable (String, Bool) -> Void) async throws -> Void
                ) async throws {
                    let state = MatchingProgressState()
                    let blockProgress = ColmapMatchingProgressTracker()
                    let onLog: @Sendable (String, Bool) -> Void = { line, isErr in
                        colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                        let sanitized = Self.sanitizeToolLogLine(line)
                        if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                            emit(.stageLog(stage: .sfmMatching, line: sanitized, isError: isErr))
                        }
                        if let update = blockProgress.ingest(line) {
                            state.updateBlockMessage(update.message)
                        }
                    }

                    let poller = ColmapDatabaseProgressPoller(databasePath: paths.colmapDatabaseURL)
                    let pollTask = Task.detached(priority: .utility) { [expectedPairs, poller, state, emit] in
                        let denom = max(1, expectedPairs)
                        var lastFraction: Double = 0
                        var lastProcessed = -1
                        var lastEmit = Date.distantPast

                        while !Task.isCancelled {
                            var processed = (try? poller.readProcessedPairCount()) ?? 0
                            if lastProcessed >= 0, processed < lastProcessed {
                                processed = lastProcessed
                            }
                            let rawFraction = Double(processed) / Double(denom)
                            let clamped = max(0, min(0.99, rawFraction))
                            if clamped > lastFraction {
                                lastFraction = clamped
                            }

                            // Emit when we see new pairs, or periodically so the UI can show it's alive.
                            let now = Date()
                            let shouldEmitZeroHeartbeat = processed == 0 && now.timeIntervalSince(lastEmit) >= 10
                            if processed != lastProcessed || shouldEmitZeroHeartbeat {
                                lastProcessed = processed
                                lastEmit = now
                                let base = state.blockMessage()
                                let message: String
                                if let base {
                                    message = "\(base), pairs \(processed)/\(denom)"
                                } else {
                                    message = "Matching views (pairs \(processed)/\(denom))"
                                }
                                emit(.stageProgress(stage: .sfmMatching, fraction: lastFraction, message: message))
                            }

                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    defer { pollTask.cancel() }

                    try await run(onLog)
                }

                func runSequential() async throws {
                    let expected = ColmapPairEstimator.expectedSequentialPairs(
                        imageCount: selectedFrames.count,
                        overlap: colmapMatchOptions.sequentialOverlap
                    )
                    try await runMatcherWithProgress(expectedPairs: expected) { onLog in
                        try await self.tooling.colmap.runMatcherSequential(
                            colmapPath: self.config.toolchain.colmap,
                            database: paths.colmapDatabaseURL,
                            options: colmapMatchOptions,
                            onLog: onLog
                        )
                    }
                }

                func runExhaustive() async throws {
                    let expected = ColmapPairEstimator.expectedExhaustivePairs(imageCount: selectedFrames.count)
                    try await runMatcherWithProgress(expectedPairs: expected) { onLog in
                        try await self.tooling.colmap.runMatcherExhaustive(
                            colmapPath: self.config.toolchain.colmap,
                            database: paths.colmapDatabaseURL,
                            options: colmapMatchOptions,
                            onLog: onLog
                        )
                    }
                }

                if useSequential {
                    do {
                        try await runSequential()
                    } catch {
                        let previousOverlap = colmapMatchOptions.sequentialOverlap
                        let increasedOverlap = min(30, max(previousOverlap + 5, previousOverlap * 2))
                        if increasedOverlap > previousOverlap {
                            emit(.stageLog(
                                stage: .sfmMatching,
                                line: "Sequential matcher failed. Retrying sequential matching with higher overlap (\(previousOverlap) -> \(increasedOverlap)).",
                                isError: true
                            ))
                            colmapMatchOptions.sequentialOverlap = increasedOverlap
                            do {
                                try await runSequential()
                            } catch {
                                emit(.stageLog(
                                    stage: .sfmMatching,
                                    line: "Sequential matcher failed again. Rebuilding database and retrying with exhaustive matching on fewer frames.",
                                    isError: true
                                ))
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
                                        if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                                            emit(.stageLog(stage: .sfmMatching, line: sanitized, isError: isErr))
                                        }
                                    }
                                )
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
                    let usesGlomap = mapperPreference == .glomap && !disableGlomapForThisRun
                    let glomapToolLog: ToolLogWriter? = {
                        guard usesGlomap else { return nil }
                        let log = ToolLogWriter(fileURL: paths.glomapLogURL, toolName: "glomap")
                        log.beginSection(
                            title: "mapper",
                            metadata: [
                                "database": paths.colmapDatabaseURL.path,
                                "images": paths.framesSelectedURL.path,
                                "output": paths.colmapSparseURL.path,
                                "tool": self.config.toolchain.glomap.path
                            ]
                        )
                        return log
                    }()
                    let toolLogNames = [paths.colmapLogURL.lastPathComponent, glomapToolLog != nil ? paths.glomapLogURL.lastPathComponent : nil]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                    emit(.stageLog(stage: .sfmMapping, line: "Tool logs: \(toolLogNames)", isError: false))
                        let mappingProgress = ColmapMappingProgressTracker(totalImages: selectedFrames.count)
                        let onMappingLog: @Sendable (String, Bool) -> Void = { line, isErr in
                            let sanitized = Self.sanitizeToolLogLine(line)
                            if Self.shouldEmitToolLogLine(sanitized, isError: isErr) {
                                emit(.stageLog(stage: .sfmMapping, line: sanitized, isError: isErr))
                            }
                            if let update = mappingProgress.ingest(line) {
                                emit(.stageProgress(stage: .sfmMapping, fraction: update.fraction, message: update.message))
                            }
                        }
                        var mappingSucceeded = false
                        var lastMappingError: Error?

                        let mapperAttempts: [SfmMapperPreference] = {
                            switch mapperPreference {
                            case .colmap:
                                return [.colmap]
                            case .glomap:
                                if disableGlomapForThisRun {
                                    return [.colmap]
                                }
                                return [.glomap, .colmap]
                            }
                        }()

                        let mapperLabel: String = {
                            switch mapperPreference {
                            case .colmap:
                                return "COLMAP"
                            case .glomap:
                                return disableGlomapForThisRun ? "COLMAP (GLOMAP disabled for this run)" : "GLOMAP"
                            }
                        }()
                        emit(.stageLog(
                            stage: .sfmMapping,
                            line: "Mapping preference: \(mapperLabel).",
                            isError: false
                        ))

                        for (index, mapper) in mapperAttempts.enumerated() {
                            do {
                                if mapper == .glomap {
                                    try await self.tooling.glomap.runMapper(
                                        glomapPath: self.config.toolchain.glomap,
                                        database: paths.colmapDatabaseURL,
                                        imagePath: paths.framesSelectedURL,
                                        outputPath: paths.colmapSparseURL,
                                        onLog: { line, isErr in
                                            glomapToolLog?.append(stream: isErr ? "stderr" : "stdout", line: line)
                                            onMappingLog(line, isErr)
                                        }
                                    )
                                } else {
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
                                }

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
                                let score = ReconstructionScorer.parseModelAnalyzerOutput(report)
                                writeCheckpoint(
                                    stage: .sfmMapping,
                                    progress: 0.95,
                                    message: "Mapping score: \(ReconstructionScorer.summary(score))",
                                    details: .sfmMapping(SfmMappingCheckpoint(
                                        mapper: mapper == .glomap ? "glomap" : "colmap",
                                        sparsePath: modelURL.path,
                                        registeredImages: score.registeredImages
                                    ))
                                )
                                emit(.stageLog(
                                    stage: .sfmMapping,
                                    line: "Reconstruction score: \(ReconstructionScorer.summary(score)).",
                                    isError: false
                                ))
                                if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                                    mappingSucceeded = true
                                    break
                                } else {
                                    lastMappingError = PipelineError.lowQualityReconstruction(score)
                                }
                            } catch {
                                if mapper == .glomap,
                                   !disableGlomapForThisRun,
                                   glomapErrorIndicatesMissingOpenSSL(error) {
                                    disableGlomapForThisRun = true
                                    emit(.stageLog(
                                        stage: .sfmMapping,
                                        line: "GLOMAP failed to launch (missing OpenSSL dylibs / rpath). This is a toolchain packaging issue; falling back to COLMAP for the rest of this run.",
                                        isError: true
                                    ))
                                }
                                lastMappingError = error
                            }
                            if !mappingSucceeded,
                               index == 0,
                               mapperPreference == .glomap,
                               mapper == .glomap {
                                emit(.stageLog(stage: .sfmMapping, line: "GLOMAP mapping failed; trying COLMAP mapper.", isError: true))
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
                               case let .lowQualityReconstruction(score) = pipelineError {
                                debugMessage = "Low-quality reconstruction. \(ReconstructionScorer.summary(score))."
                            } else if let colmapError = lastMappingError as? ColmapRunnerError {
                                debugMessage = debugDescription(for: colmapError)
                            } else {
                                debugMessage = "\(lastMappingError ?? PipelineError.lowQualityReconstruction(.init(registeredImages: 0, totalImages: 0, meanReprojectionError: nil)))"
                            }
                            emitFailure(
                                stage: .sfmMapping,
                                userMessage: "I couldn't get a stable camera solve. Try a slower capture and more light.",
                                debugMessage: debugMessage
                            )
                            throw lastMappingError ?? PipelineError.lowQualityReconstruction(.init(registeredImages: 0, totalImages: 0, meanReprojectionError: nil))
                        }
                        let finalSparseModel = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
                        writeCheckpoint(
                            stage: .sfmMapping,
                            progress: 1.0,
                            message: "Camera mapping completed",
                            details: .sfmMapping(SfmMappingCheckpoint(
                                mapper: mapperPreference.rawValue,
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
            if skipTraining {
                emit(.stageLog(
                    stage: .sfmMapping,
                    line: "Stopping early after SfM (EASYSPLAT_SKIP_TRAINING=1).",
                    isError: false
                ))
                metadata.lastRunStartedAt = nil
                try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
                return
            }
            if try shouldRunStage(.trainBrush) {
                currentStage = .trainBrush
                emit(.stageStarted(stage: .trainBrush))
                writeCheckpoint(
                    stage: .trainBrush,
                    progress: 0,
                    message: "Brush training started",
                    details: .trainBrush(TrainBrushCheckpoint(
                        latestExportStep: nil,
                        latestExportPath: nil,
                        progressStep: nil,
                        progressTotal: brushTrainingPlan(for: metadata.preset).totalSteps,
                        stepsPerSecond: nil,
                        resumeSnapshotPath: paths.trainingURL.appendingPathComponent("latest_snapshot.ply").path
                    ))
                )
                if let trainingGate = config.trainingGate {
                    try await trainingGate()
                }
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
                    minSteps: Self.brushSnapshotMinSteps(),
                    maxSteps: Self.brushSnapshotMaxSteps(),
                    totalSteps: brushPlan.totalSteps
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
                                                resumeSnapshotPath: trainingURL.appendingPathComponent("latest_snapshot.ply").path
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
                                    resumeSnapshotPath: trainingURL.appendingPathComponent("latest_snapshot.ply").path
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
                                        resumeSnapshotPath: paths.trainingURL.appendingPathComponent("latest_snapshot.ply").path
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
                        resumeSnapshotPath: paths.trainingURL.appendingPathComponent("latest_snapshot.ply").path
                    ))
                )
                emit(.stageFinished(stage: .trainBrush))
                markStageComplete(.trainBrush)
            }

            try Task.checkCancellation()
            if try shouldRunStage(.exportSplat) {
                currentStage = .exportSplat
                emit(.stageStarted(stage: .exportSplat))
                writeCheckpoint(stage: .exportSplat, progress: 0, message: "Export started")
                guard let ply = self.tooling.brush.findLatestPly(in: paths.trainingURL) else {
                    throw PipelineError.outputMissing
                }
                try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
                let outputPly = paths.outputURL.appendingPathComponent("splat.ply")
                try SplatExport.copyIfExists(from: ply, to: outputPly)
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
            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
}

private extension PipelineRunner {
    enum PipelineError: Error {
        case invalidInput
        case lowQualityReconstruction(ReconstructionScore)
        case imageTranscodeFailed(String)
        case outputMissing
    }

    struct SelectedFrameGroup: Sendable {
        let id: String
        let frames: [URL]
        let isVideo: Bool
    }

    struct SelectedFrameMapping: Codable, Sendable {
        let outputFileName: String
        let groupId: String
        let isVideo: Bool
        let sourcePath: String
    }

    var supportedImageExtensions: Set<String> {
        ["jpg", "jpeg", "png", "heic"]
    }

    func isHeicImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    func transcodeHeicToJpeg(source: URL, destination: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw PipelineError.imageTranscodeFailed("Failed to read HEIC image: \(source.lastPathComponent)")
        }

        let props = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxDim = max(1, max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceShouldCache: false
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(sourceRef, 0, options as CFDictionary) else {
            throw PipelineError.imageTranscodeFailed("Failed to decode HEIC image: \(source.lastPathComponent)")
        }

        guard let destRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PipelineError.imageTranscodeFailed("Failed to create JPEG output: \(destination.lastPathComponent)")
        }

        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        CGImageDestinationAddImage(destRef, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destRef) else {
            throw PipelineError.imageTranscodeFailed("Failed to write JPEG image: \(destination.lastPathComponent)")
        }
    }

    // Legacy support: earlier versions copied HEIC photos into Selected/ directly, but downstream tools
    // (COLMAP/VGGT) expect JPEG/PNG. Transcode in-place so resumed projects still work.
    func normalizeSelectedImagesForTooling(paths: ProjectPaths) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.framesSelectedURL.path) else { return 0 }

        let files = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }

        var renamed: [String: String] = [:]
        var converted = 0
        for file in files where isHeicImage(file) {
            let newName = file.deletingPathExtension().lastPathComponent + ".jpg"
            let dest = paths.framesSelectedURL.appendingPathComponent(newName)

            if !fm.fileExists(atPath: dest.path) {
                try transcodeHeicToJpeg(source: file, destination: dest)
            }
            // Ensure downstream tools don't see a mix of formats with duplicate basenames.
            try? fm.removeItem(at: file)
            renamed[file.lastPathComponent] = newName
            converted += 1
        }

        if converted > 0,
           fm.fileExists(atPath: paths.framesSelectedManifestURL.path),
           let manifest = try? loadSelectedFrameManifest(from: paths.framesSelectedManifestURL) {
            let updated = manifest.map { entry in
                guard let newName = renamed[entry.outputFileName] else { return entry }
                return SelectedFrameMapping(
                    outputFileName: newName,
                    groupId: entry.groupId,
                    isVideo: entry.isVideo,
                    sourcePath: entry.sourcePath
                )
            }
            try saveSelectedFrameManifest(updated, to: paths.framesSelectedManifestURL)
        }

        return converted
    }

    func downsampleFrames(_ frames: [URL], targetCount: Int) -> [URL] {
        guard !frames.isEmpty else { return [] }
        guard targetCount > 0 else { return [] }
        if targetCount == 1 {
            return [frames[frames.count / 2]]
        }
        if frames.count <= targetCount {
            return frames
        }
        let step = Double(frames.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            let position = Int(round(Double(index) * step))
            return frames[position]
        }
    }

    func downsampleSelectedFrames(to targetCount: Int, paths: ProjectPaths) throws -> [URL]? {
        guard targetCount > 0 else { return nil }
        let existing = try loadImages(in: paths.framesSelectedURL)
        guard existing.count > targetCount else { return nil }
        let reduced = downsampleFrames(existing, targetCount: targetCount)

        let tempSelected = paths.framesSelectedURL.deletingLastPathComponent()
            .appendingPathComponent("selected_retry", isDirectory: true)
        try self.resetDirectory(tempSelected)
        let newSelection = try copySelected(reduced, to: tempSelected)
        self.removeIfExists(paths.framesSelectedURL)
        try FileManager.default.moveItem(at: tempSelected, to: paths.framesSelectedURL)
        if FileManager.default.fileExists(atPath: paths.framesSelectedManifestURL.path),
           let manifest = try? loadSelectedFrameManifest(from: paths.framesSelectedManifestURL) {
            let manifestByFile = Dictionary(manifest.map { ($0.outputFileName, $0) }, uniquingKeysWith: { first, _ in first })
            var updated: [SelectedFrameMapping] = []
            updated.reserveCapacity(newSelection.count)
            for (index, original) in reduced.enumerated() where index < newSelection.count {
                let oldName = original.lastPathComponent
                guard let entry = manifestByFile[oldName] else { continue }
                let newName = newSelection[index].lastPathComponent
                updated.append(SelectedFrameMapping(
                    outputFileName: newName,
                    groupId: entry.groupId,
                    isVideo: entry.isVideo,
                    sourcePath: entry.sourcePath
                ))
            }
            try? saveSelectedFrameManifest(updated, to: paths.framesSelectedManifestURL)
        }
        return try loadImages(in: paths.framesSelectedURL)
    }

    func copySelected(
        groups: [SelectedFrameGroup],
        to directory: URL,
        manifestURL: URL,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> (frames: [URL], manifest: [SelectedFrameMapping]) {
        let fm = FileManager.default
        var output: [URL] = []
        var manifest: [SelectedFrameMapping] = []
        let total = groups.reduce(0) { $0 + $1.frames.count }
        var index = 0
        var copied = 0
        for group in groups {
            for frame in group.frames {
                let sourceExt = frame.pathExtension.lowercased()
                let destExt: String = {
                    if sourceExt.isEmpty { return "jpg" }
                    if sourceExt == "heic" || sourceExt == "heif" { return "jpg" }
                    return sourceExt
                }()
                let dest = directory.appendingPathComponent(String(format: "frame_%06d.%@", index, destExt))
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                if isHeicImage(frame) {
                    try transcodeHeicToJpeg(source: frame, destination: dest)
                } else {
                    try fm.copyItem(at: frame, to: dest)
                }
                output.append(dest)
                manifest.append(SelectedFrameMapping(
                    outputFileName: dest.lastPathComponent,
                    groupId: group.id,
                    isVideo: group.isVideo,
                    sourcePath: frame.path
                ))
                index += 1
                copied += 1
                if let progress, total > 0, copied % 5 == 0 || copied == total {
                    let fraction = Double(copied) / Double(total)
                    progress(fraction, "Copying selected frames \(copied)/\(total)")
                }
            }
        }
        try saveSelectedFrameManifest(manifest, to: manifestURL)
        return (output, manifest)
    }

    func saveSelectedFrameManifest(_ manifest: [SelectedFrameMapping], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    func loadSelectedFrameManifest(from url: URL) throws -> [SelectedFrameMapping] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SelectedFrameMapping].self, from: data)
    }

    func sparseModelFilesExist(at url: URL) -> Bool {
        let fm = FileManager.default
        let binFiles = ["cameras.bin", "images.bin", "points3D.bin"]
        let txtFiles = ["cameras.txt", "images.txt", "points3D.txt"]
        let binOK = binFiles.allSatisfy { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        if binOK { return true }
        let txtOK = txtFiles.allSatisfy { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        return txtOK
    }

    func colmapOptionsForExtraction() -> ColmapOptions {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let extractThreads = min(8, max(2, cores / 2))
        return ColmapOptions(
            useGPU: false,
            extractThreads: extractThreads,
            matchThreads: 1,
            sequentialOverlap: 10,
            maxNumFeatures: 8192,
            maxNumMatches: nil,
            useBruteForceMatcher: false,
            exhaustiveBlockSize: nil,
            environment: [
                "OMP_NUM_THREADS": "\(extractThreads)",
                "OPENBLAS_NUM_THREADS": "\(extractThreads)",
                "MKL_NUM_THREADS": "\(extractThreads)"
            ]
        )
    }

    func colmapOptionsForMatching() -> ColmapOptions {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let matchThreads = min(8, max(2, cores / 2))
        return ColmapOptions(
            useGPU: false,
            extractThreads: matchThreads,
            matchThreads: matchThreads,
            sequentialOverlap: 10,
            maxNumFeatures: nil,
            maxNumMatches: 8192,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 20,
            environment: [
                "OMP_NUM_THREADS": "\(matchThreads)",
                "OPENBLAS_NUM_THREADS": "\(matchThreads)",
                "MKL_NUM_THREADS": "\(matchThreads)"
            ]
        )
    }

    func tuneFastVggtRefinementColmapOptions(
        frameCount: Int,
        extractOptions: ColmapOptions,
        matchOptions: ColmapOptions
    ) -> (extract: ColmapOptions, match: ColmapOptions, notes: [String]) {
        var tunedExtract = extractOptions
        var tunedMatch = matchOptions
        var notes: [String] = []

        guard frameCount >= 200 else {
            return (extract: tunedExtract, match: tunedMatch, notes: notes)
        }

        let overlapCap = frameCount >= 450 ? 6 : 8
        if tunedMatch.sequentialOverlap > overlapCap {
            notes.append("FastVGGT refinement speed profile: reduced sequential overlap \(tunedMatch.sequentialOverlap) -> \(overlapCap) for \(frameCount) frames.")
            tunedMatch.sequentialOverlap = overlapCap
        }

        let matchCap = frameCount >= 450 ? 7_000 : 8_000
        if let currentMatches = tunedMatch.maxNumMatches {
            if currentMatches > matchCap {
                notes.append("FastVGGT refinement speed profile: capped max matches \(currentMatches) -> \(matchCap).")
                tunedMatch.maxNumMatches = matchCap
            }
        } else {
            notes.append("FastVGGT refinement speed profile: set max matches to \(matchCap).")
            tunedMatch.maxNumMatches = matchCap
        }

        let featureCap = frameCount >= 450 ? 8_192 : 9_000
        if let currentFeatures = tunedExtract.maxNumFeatures, currentFeatures > featureCap {
            notes.append("FastVGGT refinement speed profile: capped max features \(currentFeatures) -> \(featureCap).")
            tunedExtract.maxNumFeatures = featureCap
        }

        if frameCount >= 450 {
            let blockCap = 30
            if let currentBlock = tunedMatch.exhaustiveBlockSize {
                if currentBlock < blockCap {
                    notes.append("FastVGGT refinement speed profile: raised exhaustive block size \(currentBlock) -> \(blockCap).")
                    tunedMatch.exhaustiveBlockSize = blockCap
                }
            } else {
                notes.append("FastVGGT refinement speed profile: set exhaustive block size to \(blockCap).")
                tunedMatch.exhaustiveBlockSize = blockCap
            }
        }

        return (extract: tunedExtract, match: tunedMatch, notes: notes)
    }

    private func sfmMapperPreference() -> SfmMapperPreference {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_SFM_MAPPER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "colmap" { return .colmap }
            if value == "glomap" { return .glomap }
        }
        return .glomap
    }

    func sfmBackendOverride() -> SfmBackend? {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_SFM_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "colmap" { return .colmap }
            if value == "fastvggt" { return .fastvggt }
            if value == "vggt" || value == "vggt-mps" { return .vggt }
        }
        return nil
    }

    func sfmBackendPolicy() -> SfmBackend {
        sfmBackendOverride() ?? .fastvggt
    }

    func sfmBackendFallbackOrder(override: SfmBackend?) -> [SfmBackend] {
        if let override {
            return [override]
        }
        return [.fastvggt, .colmap]
    }

    func vggtDevicePreference() -> String {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_VGGT_DEVICE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "mps"
    }

    func vggtImageLoadResolutionPreference(preset: PresetSpec) -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_IMG_LOAD_RESOLUTION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        switch preset.quality {
        case .draft:
            return 768
        case .standard:
            return 1024
        case .ultra:
            return 1280
        }
    }

    func vggtFixedResolutionPreference() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_RESOLUTION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 518
    }

    func vggtConfidenceThresholdPreference() -> Double {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_CONF_THRES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0 {
            return override
        }
        return 5.0
    }

    func vggtMaxPointsPreference(preset: PresetSpec) -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_MAX_POINTS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        switch preset.quality {
        case .draft:
            return 60_000
        case .standard:
            return 100_000
        case .ultra:
            return 150_000
        }
    }

    func vggtUseBundleAdjustmentPreference() -> Bool {
        boolEnvValue("EASYSPLAT_VGGT_USE_BA", default: true)
    }

    func vggtMaxReprojectionErrorPreference() -> Double {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_MAX_REPROJ_ERROR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0 {
            return override
        }
        return 8.0
    }

    func vggtSharedCameraPreference() -> Bool {
        boolEnvValue("EASYSPLAT_VGGT_SHARED_CAMERA", default: false)
    }

    func vggtCameraTypePreference() -> String {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_VGGT_CAMERA_TYPE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "SIMPLE_PINHOLE"
    }

    func vggtVisibilityThresholdPreference() -> Double {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_VIS_THRESH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0 {
            return override
        }
        return 0.2
    }

    func vggtQueryFrameCountPreference() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_QUERY_FRAMES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 8
    }

    func vggtMaxQueryPointsPreference() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_MAX_QUERY_PTS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 4096
    }

    func vggtFineTrackingPreference() -> Bool {
        boolEnvValue("EASYSPLAT_VGGT_FINE_TRACKING", default: true)
    }

    func vggtKeypointExtractorPreference() -> String {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_VGGT_KEYPOINT_EXTRACTOR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "aliked+sp"
    }

    func vggtBaMaxFramesPreference() -> Int? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_VGGT_BA_MAX_FRAMES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return nil
    }

    func vggtBaMaxFramesLimit(autoTune: AutoTuneProfile?) -> Int {
        if let override = vggtBaMaxFramesPreference() {
            return override
        }
        guard let autoTune else {
            return 32
        }
        switch autoTune.tier {
        case .low:
            return 24
        case .mid:
            return 48
        case .high:
            return 96
        }
    }

    func fastvggtDtypePreference() -> String {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_FASTVGGT_DTYPE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "auto"
    }

    func fastvggtMergingPreference() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_MERGING"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw) {
            return override
        }
        return 0
    }

    func fastvggtMergeRatioPreference() -> Double {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_MERGE_RATIO"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw) {
            return override
        }
        return 0.9
    }

    func fastvggtConfidenceThresholdPreference() -> Double {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_DEPTH_CONF_THRES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0 {
            return override
        }
        return 3.0
    }

    func fastvggtUseBundleAdjustmentPreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_USE_BA", default: true)
    }

    func fastvggtRequireRefinedModelPreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_REQUIRE_REFINED_MODEL", default: true)
    }

    func fastvggtBaMaxIterationsPreference() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_BA_MAX_ITERS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 50
    }

    func fastvggtBaRefineFocalPreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_BA_REFINE_FOCAL", default: true)
    }

    func fastvggtBaRefinePrincipalPointPreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_BA_REFINE_PP", default: false)
    }

    func fastvggtBaRefineExtraParamsPreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_BA_REFINE_EXTRA", default: false)
    }

    func fastvggtFullCoveragePreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_FULL_COVERAGE", default: false)
    }

    func fastvggtNoFallbackPreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_NO_FALLBACK", default: false)
    }

    struct FastVggtStrictCoverageDefaults: Sendable {
        var coveragePlanner: String
        var coverageWindowTokens: Int
        var coverageOverlap: Double
        var coverageMaxRounds: Int
        var postprocessMode: String
    }

    func fastvggtStrictCoverageDefaults(
        input: InputSpec,
        selectedFrameCount: Int,
        autoTune: AutoTuneProfile?,
        hardwareProfile: HardwareProfile?
    ) -> FastVggtStrictCoverageDefaults {
        let tier = autoTune?.tier ?? hardwareProfile?.tier ?? .mid
        let prefersTemporalPlanner = input.hasVideos

        var defaults: FastVggtStrictCoverageDefaults
        switch tier {
        case .low:
            defaults = FastVggtStrictCoverageDefaults(
                coveragePlanner: prefersTemporalPlanner ? "temporal" : "appearance",
                coverageWindowTokens: 14_000,
                coverageOverlap: 0.55,
                coverageMaxRounds: 7,
                postprocessMode: selectedFrameCount > 1_200 ? "none" : "gpu_ba_lite"
            )
        case .mid:
            defaults = FastVggtStrictCoverageDefaults(
                coveragePlanner: prefersTemporalPlanner ? "temporal" : "appearance",
                coverageWindowTokens: 22_000,
                coverageOverlap: 0.42,
                coverageMaxRounds: 5,
                postprocessMode: selectedFrameCount > 1_800 ? "none" : "gpu_ba_lite"
            )
        case .high:
            defaults = FastVggtStrictCoverageDefaults(
                coveragePlanner: prefersTemporalPlanner ? "temporal" : "auto",
                coverageWindowTokens: 30_000,
                coverageOverlap: 0.32,
                coverageMaxRounds: 4,
                postprocessMode: "gpu_ba_lite"
            )
        }

        if let hardwareProfile {
            let memoryGB = hardwareProfile.memoryGB
            let gpuWorkingSetGB = hardwareProfile.gpuWorkingSetGB ?? memoryGB
            if memoryGB <= 12.0 || gpuWorkingSetGB < 5.0 {
                defaults.coverageWindowTokens = min(defaults.coverageWindowTokens, 12_000)
                defaults.coverageOverlap = max(defaults.coverageOverlap, 0.58)
                defaults.coverageMaxRounds += 1
                if selectedFrameCount > 900 {
                    defaults.postprocessMode = "none"
                }
            } else if memoryGB >= 64.0 || gpuWorkingSetGB >= 24.0 {
                defaults.coverageWindowTokens += 4_000
                defaults.coverageOverlap = max(0.25, defaults.coverageOverlap - 0.05)
                defaults.coverageMaxRounds = max(3, defaults.coverageMaxRounds - 1)
            } else if memoryGB >= 32.0 || gpuWorkingSetGB >= 12.0 {
                defaults.coverageWindowTokens += 2_000
                defaults.coverageOverlap = max(0.28, defaults.coverageOverlap - 0.03)
            }
        }

        if selectedFrameCount >= 900 {
            defaults.coverageMaxRounds += 1
        }
        if selectedFrameCount >= 1_600 {
            defaults.coverageMaxRounds += 1
        }
        if selectedFrameCount <= 180 {
            defaults.coverageMaxRounds = max(3, defaults.coverageMaxRounds - 1)
        }
        if selectedFrameCount >= 2_800 {
            defaults.postprocessMode = "none"
        }

        defaults.coverageWindowTokens = min(max(defaults.coverageWindowTokens, 10_000), 40_000)
        defaults.coverageOverlap = min(max(defaults.coverageOverlap, 0.20), 0.70)
        defaults.coverageMaxRounds = min(max(defaults.coverageMaxRounds, 3), 10)

        return defaults
    }

    func fastvggtCoverageConfig(
        strictModeEnabled: Bool,
        input: InputSpec,
        selectedFrameCount: Int,
        autoTune: AutoTuneProfile?,
        hardwareProfile: HardwareProfile?,
        manifestPath: URL?
    ) -> FastVggtCoverageConfig {
        let defaults = fastvggtStrictCoverageDefaults(
            input: input,
            selectedFrameCount: selectedFrameCount,
            autoTune: autoTune,
            hardwareProfile: hardwareProfile
        )

        let planner = hasEnvValue("EASYSPLAT_FASTVGGT_COVERAGE_PLANNER")
            ? fastvggtCoveragePlannerPreference()
            : defaults.coveragePlanner
        let windowTokens = hasEnvValue("EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS")
            ? fastvggtCoverageWindowTokensPreference()
            : defaults.coverageWindowTokens
        let overlap = hasEnvValue("EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP")
            ? fastvggtCoverageOverlapPreference()
            : defaults.coverageOverlap
        let maxRounds = hasEnvValue("EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS")
            ? fastvggtCoverageMaxRoundsPreference()
            : defaults.coverageMaxRounds
        let gpuOnly = hasEnvValue("EASYSPLAT_FASTVGGT_GPU_ONLY")
            ? fastvggtGpuOnlyPreference()
            : strictModeEnabled
        let postprocess = hasEnvValue("EASYSPLAT_FASTVGGT_POSTPROCESS")
            ? fastvggtPostprocessPreference()
            : defaults.postprocessMode

        return FastVggtCoverageConfig(
            requireFullCoverage: strictModeEnabled,
            coveragePlanner: planner,
            coverageWindowTokens: windowTokens,
            coverageOverlap: overlap,
            coverageMaxRounds: maxRounds,
            coverageManifestPath: manifestPath,
            gpuOnly: gpuOnly,
            postprocessMode: postprocess
        )
    }

    func fastvggtCoverageSummary(
        config: FastVggtCoverageConfig,
        autoTune: AutoTuneProfile?,
        hardwareProfile: HardwareProfile
    ) -> String {
        let sourceTier = autoTune?.tier ?? hardwareProfile.tier
        let memText = String(format: "%.1f", hardwareProfile.memoryGB)
        let gpuText: String = {
            guard let gpu = hardwareProfile.gpuWorkingSetGB else { return "n/a" }
            return String(format: "%.1f", gpu)
        }()
        return "FastVGGT strict auto-config: tier=\(sourceTier.rawValue.lowercased()) memGB=\(memText) gpuWSGB=\(gpuText) planner=\(config.coveragePlanner) windowTokens=\(config.coverageWindowTokens) overlap=\(String(format: "%.2f", config.coverageOverlap)) maxRounds=\(config.coverageMaxRounds) gpuOnly=\(config.gpuOnly ? "1" : "0") postprocess=\(config.postprocessMode)."
    }

    func fastvggtGpuOnlyPreference() -> Bool {
        boolEnvValue("EASYSPLAT_FASTVGGT_GPU_ONLY", default: false)
    }

    func fastvggtPostprocessPreference() -> String {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_POSTPROCESS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let lowered = raw.lowercased()
            if lowered == "gpu_ba_lite" || lowered == "none" {
                return lowered
            }
        }
        return "gpu_ba_lite"
    }

    func fastvggtCoveragePlannerPreference() -> String {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_COVERAGE_PLANNER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let lowered = raw.lowercased()
            if lowered == "auto" || lowered == "temporal" || lowered == "appearance" {
                return lowered
            }
        }
        return "auto"
    }

    func fastvggtCoverageWindowTokensPreference() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override >= 1_000 {
            return override
        }
        return 25_000
    }

    func fastvggtCoverageOverlapPreference() -> Double {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0,
           override < 1 {
            return override
        }
        return 0.35
    }

    func fastvggtCoverageMaxRoundsPreference() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 4
    }

    func vggtImageLoadResolutionValue(preset: PresetSpec, autoTune: AutoTuneProfile?) -> Int {
        if !hasEnvValue("EASYSPLAT_VGGT_IMG_LOAD_RESOLUTION"), let autoTune {
            return autoTune.vggtImageLoadResolution
        }
        return vggtImageLoadResolutionPreference(preset: preset)
    }

    func vggtFixedResolutionValue(autoTune: AutoTuneProfile?) -> Int {
        if !hasEnvValue("EASYSPLAT_VGGT_RESOLUTION"), let autoTune {
            return autoTune.vggtFixedResolution
        }
        return vggtFixedResolutionPreference()
    }

    func vggtMaxPointsValue(preset: PresetSpec, autoTune: AutoTuneProfile?) -> Int {
        if !hasEnvValue("EASYSPLAT_VGGT_MAX_POINTS"), let autoTune {
            return autoTune.vggtMaxPoints
        }
        return vggtMaxPointsPreference(preset: preset)
    }

    func shouldUseColmapGpu(colmapPath: URL) -> Bool {
        if let override = colmapGpuOverride() {
            return override
        }
        return detectColmapGpuSupport(colmapPath: colmapPath)
    }

    func shouldAutoTune() -> Bool {
        if let value = ProcessInfo.processInfo.environment["EASYSPLAT_AUTOTUNE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if ["0", "false", "no"].contains(value) { return false }
        }
        return true
    }

    func hasEnvValue(_ key: String) -> Bool {
        if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return !value.isEmpty
        }
        return false
    }

    func boolEnvValue(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if ["1", "true", "yes"].contains(value) { return true }
            if ["0", "false", "no"].contains(value) { return false }
        }
        return defaultValue
    }

    func applyAutoTune(
        _ tune: AutoTuneProfile,
        colmapMaxImageSize: inout Int,
        colmapExtractOptions: inout ColmapOptions,
        colmapMatchOptions: inout ColmapOptions
    ) {
        if let cap = tune.colmapMaxImageSizeCap {
            colmapMaxImageSize = min(colmapMaxImageSize, cap)
        }

        colmapExtractOptions.maxNumFeatures = tune.colmapMaxNumFeatures
        colmapMatchOptions.maxNumFeatures = tune.colmapMaxNumFeatures
        colmapMatchOptions.maxNumMatches = tune.colmapMaxNumMatches
        colmapExtractOptions.sequentialOverlap = tune.sequentialOverlap
        colmapMatchOptions.sequentialOverlap = tune.sequentialOverlap
        colmapMatchOptions.exhaustiveBlockSize = tune.exhaustiveBlockSize

        if tune.threadCap > 0 {
            colmapExtractOptions.extractThreads = min(colmapExtractOptions.extractThreads, tune.threadCap)
            colmapMatchOptions.matchThreads = min(colmapMatchOptions.matchThreads, tune.threadCap)
            updateThreadEnvironment(&colmapExtractOptions, threadCount: colmapExtractOptions.extractThreads)
            updateThreadEnvironment(&colmapMatchOptions, threadCount: colmapMatchOptions.matchThreads)
        }
    }

    func updateThreadEnvironment(_ options: inout ColmapOptions, threadCount: Int) {
        if options.environment.isEmpty { return }
        options.environment["OMP_NUM_THREADS"] = "\(threadCount)"
        options.environment["OPENBLAS_NUM_THREADS"] = "\(threadCount)"
        options.environment["MKL_NUM_THREADS"] = "\(threadCount)"
    }

    func colmapGpuOverride() -> Bool? {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_COLMAP_FORCE_CPU"], value == "1" {
            return false
        }
        if let value = env["EASYSPLAT_COLMAP_FORCE_GPU"], value == "1" {
            return true
        }
        if let value = env["EASYSPLAT_COLMAP_USE_GPU"] {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes"].contains(normalized) { return true }
            if ["0", "false", "no"].contains(normalized) { return false }
        }
        return nil
    }

    func detectColmapGpuSupport(colmapPath: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: colmapPath.path) else { return false }
        let runner = SubprocessRunner()
        let result = try? runner.run(colmapPath.path, ["-h"])
        guard result?.exitCode == 0 else { return false }
        let output = ((result?.stdout ?? "") + "\n" + (result?.stderr ?? "")).lowercased()
        if output.contains("without cuda") { return false }
        if output.contains("cuda") { return true }
        return false
    }

    func colmapErrorIndicatesGpuFailure(_ error: ColmapRunnerError) -> Bool {
        let output: String
        switch error {
        case let .failed(_, _, _, stdoutTail, stderrTail):
            output = (stderrTail + "\n" + stdoutTail).lowercased()
        }
        if output.contains("without cuda") { return true }
        if output.contains("cuda") { return true }
        if output.contains("use_gpu") { return true }
        if output.contains("gpu") { return true }
        return false
    }

    func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeIfExists(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    func cleanForRetry(failedStage: PipelineStage, paths: ProjectPaths) throws {
        switch failedStage {
        case .importInput:
            return
        case .extractFrames:
            self.removeIfExists(paths.framesRawURL)
            self.removeIfExists(paths.framesSelectedURL)
            self.removeIfExists(paths.framesSelectedManifestURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .selectFrames:
            self.removeIfExists(paths.framesSelectedURL)
            self.removeIfExists(paths.framesSelectedManifestURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .sfmFeatures, .sfmMatching:
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .sfmMapping:
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .trainBrush:
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .exportSplat:
            self.removeIfExists(paths.outputURL)
        case .done:
            return
        }
    }

    func failureMessages(for error: Error, stage: PipelineStage) -> (userMessage: String, debugMessage: String) {
        if let pipelineError = error as? PipelineError {
            switch pipelineError {
            case .invalidInput:
                return ("No usable photos or video frames were found.", String(reflecting: pipelineError))
            case let .lowQualityReconstruction(score):
                return ("I couldn't get a stable camera solve. Try a slower capture and more light.", "Low-quality reconstruction. \(ReconstructionScorer.summary(score)).")
            case let .imageTranscodeFailed(message):
                return ("Failed to convert photos for processing. Try exporting as JPEG/PNG.", message)
            case .outputMissing:
                return ("Processing failed. Expected outputs were missing.", String(reflecting: pipelineError))
            }
        }
        if let subprocessFailure = error as? SubprocessFailure {
            return ("Processing failed. Check details for more info.", subprocessFailure.debugDescription)
        }
        if let colmapError = error as? ColmapRunnerError {
            let debug = debugDescription(for: colmapError)
            switch colmapError {
            case let .failed(_, exitCode, reason, _, _) where reason == .uncaughtSignal && exitCode == 10:
                return ("COLMAP crashed while matching images. Try fewer frames or a lower quality preset.", debug)
            default:
                return ("Processing failed. Check details for more info.", debug)
            }
        }
        return ("Processing failed. Check details for more info.", String(reflecting: error))
    }

    func glomapErrorIndicatesMissingOpenSSL(_ error: Error) -> Bool {
        guard let failure = error as? SubprocessFailure else { return false }
        let text = "\(failure.stdoutTail)\n\(failure.stderrTail)".lowercased()
        if text.contains("library not loaded: @rpath/libcrypto.3.dylib") { return true }
        if text.contains("no lc_rpath") { return true }
        return false
    }

    func debugDescription(for error: ColmapRunnerError) -> String {
        switch error {
        case let .failed(command, exitCode, reason, stdoutTail, stderrTail):
            return """
            Colmap error: \(command)
            Exit code: \(exitCode)
            Termination reason: \(reason)
            Stdout tail:
            \(stdoutTail)
            Stderr tail:
            \(stderrTail)
            """
        }
    }

    func importInputs(
        metadata: ProjectMetadata,
        paths: ProjectPaths,
        progress: (Double, String) -> Void
    ) throws {
        let fm = FileManager.default
        var tasks: [(label: String, action: () throws -> Void)] = []

        for file in metadata.input.videoFiles {
            let source = URL(fileURLWithPath: file)
            let dest = paths.originalsURL.appendingPathComponent(source.lastPathComponent)
            tasks.append((label: source.lastPathComponent, action: {
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: source, to: dest)
                }
            }))
        }

        if let photosFolder = metadata.input.photosFolder {
            let sourceFolder = URL(fileURLWithPath: photosFolder)
            let dest = paths.originalsURL.appendingPathComponent(sourceFolder.lastPathComponent)
            tasks.append((label: "Photos: \(sourceFolder.lastPathComponent)", action: {
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: sourceFolder, to: dest)
                }
            }))
        }

        guard !tasks.isEmpty else { return }
        let total = tasks.count
        for (index, task) in tasks.enumerated() {
            let message = "Copying input \(index + 1)/\(total): \(task.label)"
            let startFraction = Double(index) / Double(total)
            progress(startFraction, message)
            try task.action()
            let endFraction = Double(index + 1) / Double(total)
            progress(endFraction, message)
        }
    }

    func copySelected(_ frames: [URL], to directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var output: [URL] = []
        for (index, url) in frames.enumerated() {
            let sourceExt = url.pathExtension.lowercased()
            let destExt: String = {
                if sourceExt.isEmpty { return "jpg" }
                if sourceExt == "heic" || sourceExt == "heif" { return "jpg" }
                return sourceExt
            }()
            let dest = directory.appendingPathComponent(String(format: "frame_%06d.%@", index, destExt))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            if isHeicImage(url) {
                try transcodeHeicToJpeg(source: url, destination: dest)
            } else {
                try fm.copyItem(at: url, to: dest)
            }
            output.append(dest)
        }
        return output
    }

    func rawFramesDirectory(index: Int, paths: ProjectPaths) -> URL {
        paths.framesRawURL.appendingPathComponent(String(format: "video_%03d", index), isDirectory: true)
    }

    func loadImages(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
            .filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func loadPhotos(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let normalizedRoot = directory.standardizedFileURL
        let looksLikeProjectRoot = fm.fileExists(atPath: directory.appendingPathComponent("project.json").path)
        let excludedProjectDirectories: Set<String> = looksLikeProjectRoot
            ? ["Frames", "SfM", "Training", "Output", "Logs"]
            : []
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var photos: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            if values?.isDirectory == true {
                if looksLikeProjectRoot,
                   url.deletingLastPathComponent().standardizedFileURL == normalizedRoot,
                   let name = values?.name,
                   excludedProjectDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if supportedImageExtensions.contains(url.pathExtension.lowercased()) {
                photos.append(url)
            }
        }

        return photos.sorted { lhs, rhs in
            let left = lhs.path.replacingOccurrences(of: directory.path + "/", with: "")
            let right = rhs.path.replacingOccurrences(of: directory.path + "/", with: "")
            return left < right
        }
    }

    struct BlurFilterResult: Sendable {
        let frames: [URL]
        let dropped: Int
    }

    func scoreSharpnessForFrames(
        _ frames: [URL],
        progress: (Double, String) -> Void
    ) -> [URL: Double] {
        guard !frames.isEmpty else { return [:] }
        let total = Double(frames.count)
        var results: [URL: Double] = [:]
        results.reserveCapacity(frames.count)
        for (index, url) in frames.enumerated() {
            if let score = try? FrameScoring.scoreFrame(at: url) {
                results[url] = max(score.blurScore, score.laplacianScore)
            }
            if index % 10 == 0 || index + 1 == frames.count {
                let fraction = min(Double(index + 1) / total, 1.0)
                progress(fraction, "Analyzing frame sharpness")
            }
        }
        return results
    }

    func filterVeryBlurryVideoFrames(
        frames: [URL],
        sharpnessByFrame: [URL: Double],
        profile: FrameExtractionProfile,
        maxDropFraction: Double,
        floorScale: Double
    ) -> BlurFilterResult {
        guard !frames.isEmpty else { return BlurFilterResult(frames: [], dropped: 0) }
        let safeFraction = max(0.0, min(1.0, maxDropFraction))
        let maxDropCount = Int((Double(frames.count) * safeFraction).rounded(.down))
        guard maxDropCount > 0 else { return BlurFilterResult(frames: frames, dropped: 0) }
        let floor = max(0.0, profile.sharpnessFloor * floorScale)

        var candidates: [(URL, Double)] = []
        candidates.reserveCapacity(frames.count)
        for url in frames {
            guard let sharpness = sharpnessByFrame[url] else { continue }
            if sharpness < floor {
                candidates.append((url, sharpness))
            }
        }
        guard !candidates.isEmpty else { return BlurFilterResult(frames: frames, dropped: 0) }

        let toDrop: Set<URL>
        if candidates.count <= maxDropCount {
            toDrop = Set(candidates.map { $0.0 })
        } else {
            let worst = candidates.sorted { $0.1 < $1.1 }.prefix(maxDropCount)
            toDrop = Set(worst.map { $0.0 })
        }
        guard !toDrop.isEmpty else { return BlurFilterResult(frames: frames, dropped: 0) }
        let filtered = frames.filter { !toDrop.contains($0) }
        let dropped = frames.count - filtered.count
        return BlurFilterResult(frames: filtered, dropped: dropped)
    }

    func targetCountForVideo(index: Int, total: Int, targetCount: Int) -> Int {
        guard total > 0 else { return targetCount }
        let base = targetCount / total
        let remainder = targetCount % total
        return base + (index < remainder ? 1 : 0)
    }

    enum StageOutputStatus: Equatable, Sendable {
        case valid
        case missing
        case corrupt(reason: String)
    }

    func persistCheckpoint(
        paths: ProjectPaths,
        stage: PipelineStage,
        progress: Double? = nil,
        message: String? = nil,
        details: PipelineCheckpointDetails? = nil
    ) {
        guard var metadata = try? ProjectMetadataStore.load(from: paths.metadataURL) else { return }
        metadata.checkpoint = PipelineCheckpoint(
            stage: stage,
            updatedAt: Date(),
            progressFraction: progress,
            message: message,
            details: details
        )
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }

    func validateStageOutput(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) throws -> StageOutputStatus {
        let fm = FileManager.default
        switch stage {
        case .importInput:
            if metadata.input.videoFiles.isEmpty && metadata.input.photosFolder == nil {
                return .missing
            }
            for file in metadata.input.videoFiles {
                let name = URL(fileURLWithPath: file).lastPathComponent
                let dest = paths.originalsURL.appendingPathComponent(name)
                guard fm.fileExists(atPath: dest.path) else { return .missing }
                let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 0 {
                    return .corrupt(reason: "input file \(name) has zero size")
                }
            }
            if let photosFolder = metadata.input.photosFolder {
                let name = URL(fileURLWithPath: photosFolder).lastPathComponent
                let dest = paths.originalsURL.appendingPathComponent(name, isDirectory: true)
                guard fm.fileExists(atPath: dest.path) else { return .missing }
                let photos = try loadPhotos(in: dest)
                if photos.isEmpty {
                    return .corrupt(reason: "photos folder \(name) is empty")
                }
            }
            return .valid
        case .extractFrames:
            guard metadata.input.hasVideos else { return .valid }
            for index in metadata.input.videoFiles.indices {
                let rawDir = rawFramesDirectory(index: index, paths: paths)
                guard fm.fileExists(atPath: rawDir.path) else { return .missing }
                let frames = try loadImages(in: rawDir)
                if frames.isEmpty {
                    return .corrupt(reason: "raw frame folder \(rawDir.lastPathComponent) is empty")
                }
                // Extraction can legitimately produce far fewer frames than the target
                // for short clips, low-motion video, or strict quality filtering.
                // Treat low counts as valid as long as we have at least one usable frame.
                let readableCount = frames.reduce(into: 0) { partial, frameURL in
                    let size = (try? fm.attributesOfItem(atPath: frameURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if size > 0 {
                        partial += 1
                    }
                }
                if readableCount <= 0 {
                    return .corrupt(reason: "raw frame folder \(rawDir.lastPathComponent) has no readable frames")
                }
            }
            return .valid
        case .selectFrames:
            guard fm.fileExists(atPath: paths.framesSelectedURL.path) else { return .missing }
            guard fm.fileExists(atPath: paths.framesSelectedManifestURL.path) else {
                return .corrupt(reason: "selected frame manifest is missing")
            }
            let manifest: [SelectedFrameMapping]
            do {
                manifest = try loadSelectedFrameManifest(from: paths.framesSelectedManifestURL)
            } catch {
                return .corrupt(reason: "selected frame manifest is invalid JSON")
            }
            if manifest.isEmpty {
                return .corrupt(reason: "selected frame manifest is empty")
            }
            let files = try loadImages(in: paths.framesSelectedURL)
            if files.count != manifest.count {
                return .corrupt(reason: "selected frame file count (\(files.count)) does not match manifest (\(manifest.count))")
            }
            let names = Set(files.map(\.lastPathComponent))
            for entry in manifest where !names.contains(entry.outputFileName) {
                return .corrupt(reason: "manifest references missing file \(entry.outputFileName)")
            }
            return .valid
        case .sfmFeatures:
            let seedZero = paths.colmapSeedModelURL
            if sparseModelFilesExist(at: seedZero) {
                return .valid
            }
            return validateColmapDatabaseOutput(paths: paths, requireMatches: false)
        case .sfmMatching:
            return validateColmapDatabaseOutput(paths: paths, requireMatches: true)
        case .sfmMapping:
            let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
            guard sparseModelFilesExist(at: sparseZero) else { return .missing }
            for name in ["cameras.bin", "images.bin", "points3D.bin", "cameras.txt", "images.txt", "points3D.txt"] {
                let fileURL = sparseZero.appendingPathComponent(name)
                if !fm.fileExists(atPath: fileURL.path) { continue }
                let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 0 {
                    return .corrupt(reason: "sparse model file \(name) is empty")
                }
            }
            let imagesTxt = sparseZero.appendingPathComponent("images.txt")
            if fm.fileExists(atPath: imagesTxt.path) {
                let text = (try? String(contentsOf: imagesTxt, encoding: .utf8)) ?? ""
                let imageRows = text.split(separator: "\n").filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                }
                if imageRows.isEmpty {
                    return .corrupt(reason: "images.txt has no registered images")
                }
            } else {
                let imagesBin = sparseZero.appendingPathComponent("images.bin")
                let size = (try? fm.attributesOfItem(atPath: imagesBin.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 8 {
                    return .corrupt(reason: "images.bin appears truncated")
                }
            }
            return .valid
        case .trainBrush:
            guard let latest = tooling.brush.findLatestPly(in: paths.trainingURL) else { return .missing }
            return validatePlyFile(at: latest)
        case .exportSplat, .done:
            let output = paths.outputURL.appendingPathComponent("splat.ply")
            guard fm.fileExists(atPath: output.path) else { return .missing }
            return validatePlyFile(at: output)
        }
    }

    func isStageComplete(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) -> Bool {
        (try? validateStageOutput(stage, paths: paths, metadata: metadata)) == .valid
    }

    func validateColmapDatabaseOutput(paths: ProjectPaths, requireMatches: Bool) -> StageOutputStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.colmapDatabaseURL.path) else { return .missing }

        let size = (try? fm.attributesOfItem(atPath: paths.colmapDatabaseURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
            if sparseModelFilesExist(at: sparseZero) {
                return .valid
            }
            return .corrupt(reason: "database.db is empty")
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let rc = sqlite3_open_v2(paths.colmapDatabaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            return .corrupt(reason: "database.db is unreadable")
        }

        func queryCount(_ sql: String) -> Int? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return nil
            }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return Int(sqlite3_column_int64(statement, 0))
        }

        let imageCount = queryCount("SELECT COUNT(*) FROM images;")
        let keypointCount = queryCount("SELECT COUNT(*) FROM keypoints;")
        let matchesCount = queryCount("SELECT COUNT(*) FROM two_view_geometries;") ?? queryCount("SELECT COUNT(*) FROM matches;")

        guard let imageCount else {
            return .corrupt(reason: "database missing images table")
        }
        guard imageCount > 0 else {
            return .missing
        }
        guard let keypointCount else {
            return .corrupt(reason: "database missing keypoints table")
        }
        if keypointCount <= 0 {
            return .missing
        }
        if requireMatches {
            guard let matchesCount else {
                return .corrupt(reason: "database missing matches/two_view_geometries table")
            }
            if matchesCount <= 0 {
                return .missing
            }
        }
        return .valid
    }

    func validatePlyFile(at url: URL) -> StageOutputStatus {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            return .corrupt(reason: "\(url.lastPathComponent) is empty")
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else {
            return .corrupt(reason: "\(url.lastPathComponent) header is not UTF-8")
        }
        guard text.hasPrefix("ply") else {
            return .corrupt(reason: "\(url.lastPathComponent) is not a PLY file")
        }
        guard text.contains("end_header") else {
            return .corrupt(reason: "\(url.lastPathComponent) is missing end_header")
        }
        let lines = text.split(separator: "\n").map(String.init)
        if let vertexLine = lines.first(where: { $0.lowercased().hasPrefix("element vertex ") }) {
            let comps = vertexLine.split(separator: " ")
            if let raw = comps.last, let count = Int(raw), count > 0 {
                return .valid
            }
            return .corrupt(reason: "\(url.lastPathComponent) has invalid vertex count")
        }
        return .corrupt(reason: "\(url.lastPathComponent) is missing vertex element metadata")
    }

    struct FrameExtractionProfile {
        let targetCount: Int
        let maxDimension: CGFloat
        let targetFPS: Int
        let minDistanceRatio: Double
        let sharpnessFloor: Double
        let sharpnessRatio: Double
        let outputFormat: FrameOutputFormat
    }

    func frameExtractionProfile(for quality: QualityPreset) -> FrameExtractionProfile {
        switch quality {
        case .draft:
            return FrameExtractionProfile(
                targetCount: 120,
                maxDimension: 1024,
                targetFPS: 2,
                minDistanceRatio: 0.20,
                sharpnessFloor: 30.0,
                sharpnessRatio: 0.5,
                outputFormat: .jpeg
            )
        case .standard:
            return FrameExtractionProfile(
                targetCount: 250,
                maxDimension: 1600,
                targetFPS: 3,
                minDistanceRatio: 0.20,
                sharpnessFloor: 40.0,
                sharpnessRatio: 0.6,
                outputFormat: .jpeg
            )
        case .ultra:
            return FrameExtractionProfile(
                targetCount: 500,
                maxDimension: 2048,
                targetFPS: 4,
                minDistanceRatio: 0.20,
                sharpnessFloor: 50.0,
                sharpnessRatio: 0.65,
                outputFormat: .png
            )
        }
    }

    func cameraModel(for preset: PresetSpec) -> String {
        if preset.mode == .room && preset.quality == .ultra {
            return "OPENCV"
        }
        return "SIMPLE_RADIAL"
    }

    func shouldUseSequential(selectedFrames: [URL], input: InputSpec, forceExhaustive: Bool) -> Bool {
        if forceExhaustive { return false }
        guard input.hasVideos, !input.hasPhotos else { return false }
        guard input.videoFiles.count == 1 else { return false }
        if selectedFrames.count < 30 { return false }
        return true
    }

    func prepareBrushDataset(
        paths: ProjectPaths,
        progress: (Double, String) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let dataset = paths.trainingURL.appendingPathComponent("dataset", isDirectory: true)
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try resetDirectory(images)
        try resetDirectory(sparse)

        let selected = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
        let imageFiles = selected.filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageFiles.isEmpty else { throw PipelineError.invalidInput }
        let imageProgressScale = 0.7
        let imageTotal = max(1, imageFiles.count)
        for (index, url) in imageFiles.enumerated() {
            let dest = images.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            if index % 5 == 0 || index + 1 == imageFiles.count {
                let fraction = imageProgressScale * (Double(index + 1) / Double(imageTotal))
                progress(fraction, "Preparing training dataset (images) \(index + 1)/\(imageTotal)")
            }
        }

        let sourceSparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        guard sparseModelFilesExist(at: sourceSparse) else { throw PipelineError.outputMissing }
        let files = try fm.contentsOfDirectory(at: sourceSparse, includingPropertiesForKeys: nil)
        let sparseProgressScale = 1.0 - imageProgressScale
        let sparseTotal = max(1, files.count)
        for (index, file) in files.enumerated() {
            let dest = sparse.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
            let fraction = imageProgressScale + sparseProgressScale * (Double(index + 1) / Double(sparseTotal))
            progress(fraction, "Preparing training dataset (sparse) \(index + 1)/\(sparseTotal)")
        }
        let imagesTxt = sparse.appendingPathComponent("images.txt")
        try _ = ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt)
        return dataset
    }

    func latestBrushExport(in trainingURL: URL, minModificationDate: Date? = nil) -> (file: URL, step: Int?)? {
        let fm = FileManager.default
        let exportsDir = trainingURL.appendingPathComponent("dataset_exports", isDirectory: true)

        if fm.fileExists(atPath: exportsDir.path) {
            if let export = latestBrushExportInDirectory(exportsDir, minModificationDate: minModificationDate) {
                return export
            }
        }

        // Fallback: search recursively in case Brush is configured with a different export path.
        let enumerator = fm.enumerator(at: trainingURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var latest: (file: URL, date: Date, step: Int?)?
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "ply" else { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if let minModificationDate, date < minModificationDate { continue }
            let step = brushExportStep(from: item)
            if let best = latest {
                if date > best.date || (date == best.date && (step ?? -1) > (best.step ?? -1)) {
                    latest = (item, date, step)
                }
            } else {
                latest = (item, date, step)
            }
        }
        guard let latest else { return nil }
        return (file: latest.file, step: latest.step)
    }

    private func latestBrushExportInDirectory(
        _ directory: URL,
        minModificationDate: Date? = nil
    ) -> (file: URL, step: Int?)? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []

        var newest: (file: URL, date: Date, step: Int?)?
        for file in files where file.pathExtension.lowercased() == "ply" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if let minModificationDate, date < minModificationDate {
                continue
            }
            let step = brushExportStep(from: file)
            if let best = newest {
                if date > best.date || (date == best.date && (step ?? -1) > (best.step ?? -1)) {
                    newest = (file, date, step)
                }
            } else {
                newest = (file, date, step)
            }
        }

        guard let newest else { return nil }
        return (file: newest.file, step: newest.step)
    }

    private func brushExportStep(from url: URL) -> Int? {
        let name = url.lastPathComponent
        let stem: String
        if name.hasSuffix(".compressed.ply") {
            stem = String(name.dropLast(".compressed.ply".count))
        } else if name.hasSuffix(".ply") {
            stem = String(name.dropLast(".ply".count))
        } else {
            return nil
        }
        guard stem.hasPrefix("export_") else { return nil }
        return Int(stem.dropFirst("export_".count))
    }

    struct BrushTrainProgress: Sendable {
        let step: Int
        let total: Int
    }

    struct BrushTrainingPlan: Sendable {
        let totalSteps: Int?
        let exportEvery: Int?
    }

    final class BrushExportStepBox: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: Int?

        func update(step: Int) {
            lock.lock()
            latest = step
            lock.unlock()
        }

        func latestStep() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return latest
        }
    }

    struct BrushSnapshotDecision: Sendable {
        let keep: Bool
        let delete: URL?
    }

    final class BrushTrainingRateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: Double?

        func update(rate: Double) {
            lock.lock()
            latest = rate
            lock.unlock()
        }

        func latestRate() -> Double? {
            lock.lock()
            defer { lock.unlock() }
            return latest
        }
    }

    final class BrushTrainingEtaEstimator: @unchecked Sendable {
        private let lock = NSLock()
        private var smoothedRate: Double?
        private var smoothedEtaSeconds: TimeInterval?
        private var lastEstimatedStep: Int?
        private var sampleCount: Int = 0
        private let minSamples = 6
        private let minStep = 50
        private let alpha: Double = 0.2
        private let etaIncreaseAlpha: Double = 0.2
        private let etaDecreaseAlpha: Double = 0.35
        private let maxEtaIncreaseFactor: Double = 1.25

        func update(rate: Double) {
            guard rate > 0 else { return }
            lock.lock()
            if let existing = smoothedRate {
                smoothedRate = alpha * rate + (1.0 - alpha) * existing
            } else {
                smoothedRate = rate
            }
            sampleCount += 1
            lock.unlock()
        }

        func estimateRemainingSeconds(step: Int, total: Int) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            guard sampleCount >= minSamples else { return nil }
            guard step >= minStep else { return nil }
            guard total > step else { return nil }
            guard let rate = smoothedRate, rate > 0 else { return nil }
            if let lastEstimatedStep, step < lastEstimatedStep {
                smoothedEtaSeconds = nil
            }
            let remainingSteps = total - step
            let rawEta = Double(remainingSteps) / rate
            let boundedEta: TimeInterval
            if let existing = smoothedEtaSeconds {
                boundedEta = min(rawEta, existing * maxEtaIncreaseFactor)
            } else {
                boundedEta = rawEta
            }
            let nextEta: TimeInterval
            if let existing = smoothedEtaSeconds {
                let alpha = boundedEta > existing ? etaIncreaseAlpha : etaDecreaseAlpha
                nextEta = alpha * boundedEta + (1.0 - alpha) * existing
            } else {
                nextEta = boundedEta
            }
            smoothedEtaSeconds = nextEta
            lastEstimatedStep = step
            return nextEta
        }
    }

    final class BrushSnapshotManager: @unchecked Sendable {
        private let lock = NSLock()
        private let defaultExportEvery: Int?
        private let minSteps: Int
        private let maxSteps: Int
        private let totalSteps: Int?
        private var lastKeptStep: Int?
        private var lastKeptFile: URL?

        init(
            defaultExportEvery: Int?,
            minSteps: Int,
            maxSteps: Int,
            totalSteps: Int?
        ) {
            self.defaultExportEvery = defaultExportEvery
            self.minSteps = minSteps
            self.maxSteps = maxSteps
            self.totalSteps = totalSteps
        }

        func handleSnapshot(file: URL, step: Int, stepsPerSecond: Double?) -> BrushSnapshotDecision {
            lock.lock()
            defer { lock.unlock() }

            if let lastKeptFile, lastKeptFile.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() {
                lastKeptStep = step
                return BrushSnapshotDecision(keep: true, delete: nil)
            }

            let targetStepInterval = snapshotStepInterval(stepsPerSecond: stepsPerSecond)
            let shouldKeep: Bool
            if let lastKeptStep {
                if step < lastKeptStep {
                    shouldKeep = true
                } else if let totalSteps, step >= max(0, totalSteps - targetStepInterval) {
                    shouldKeep = true
                } else {
                    shouldKeep = (step - lastKeptStep) >= targetStepInterval
                }
            } else {
                shouldKeep = true
            }

            if shouldKeep {
                let delete = lastKeptFile
                lastKeptStep = step
                lastKeptFile = file
                return BrushSnapshotDecision(keep: true, delete: delete)
            }
            return BrushSnapshotDecision(keep: false, delete: file)
        }

        private func snapshotStepInterval(stepsPerSecond: Double?) -> Int {
            let fallback = defaultExportEvery ?? minSteps
            guard let rate = stepsPerSecond, rate > 0 else {
                return clampStepCount(fallback)
            }
            let estimatedTotalSeconds: TimeInterval? = {
                guard let totalSteps else { return nil }
                return Double(totalSteps) / rate
            }()
            let targetSeconds = PipelineRunner.brushSnapshotTargetSeconds(estimatedTotalSeconds: estimatedTotalSeconds)
            let rawSteps = Int((rate * targetSeconds).rounded())
            return clampStepCount(rawSteps)
        }

        private func clampStepCount(_ value: Int) -> Int {
            let safeMin = max(1, minSteps)
            let safeMax = max(safeMin, maxSteps)
            if value < safeMin { return safeMin }
            if value > safeMax { return safeMax }
            return value
        }
    }

    final class TrainingStatusGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastEmitAt: Date = .distantPast
        private let minInterval: TimeInterval = 1.0

        func shouldEmit(now: Date) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if now.timeIntervalSince(lastEmitAt) < minInterval {
                return false
            }
            lastEmitAt = now
            return true
        }
    }

    final class BrushTrainingStepLogGate: @unchecked Sendable {
        private let lock = NSLock()
        private let stepInterval: Int
        private var lastEmittedStep: Int?

        init(stepInterval: Int) {
            self.stepInterval = max(1, stepInterval)
        }

        func shouldEmit(step: Int) -> Bool {
            guard step > 0 else { return false }
            guard step % stepInterval == 0 else { return false }
            lock.lock()
            defer { lock.unlock() }
            if lastEmittedStep == step {
                return false
            }
            lastEmittedStep = step
            return true
        }
    }

    func brushTrainingPlan(for preset: PresetSpec) -> BrushTrainingPlan {
        switch preset.quality {
        case .draft:
            return BrushTrainingPlan(totalSteps: 20_000, exportEvery: 5_000)
        case .standard:
            return BrushTrainingPlan(totalSteps: 40_000, exportEvery: 5_000)
        case .ultra:
            return BrushTrainingPlan(totalSteps: 80_000, exportEvery: 10_000)
        }
    }

    func trainingStatusMessage(
        elapsed: TimeInterval,
        progress: BrushTrainProgress?,
        latestExportStep: Int?,
        totalSteps: Int?,
        etaSeconds: TimeInterval?
    ) -> String {
        let elapsedText = formatElapsed(elapsed)
        let etaText = etaSeconds.map { " • ETA \(formatElapsed($0))" } ?? ""
        if let progress, progress.total > 0 {
            let stepText = formatStepCount(progress.step)
            let totalText = formatStepCount(progress.total)
            return "Training model - \(stepText)/\(totalText) steps\(etaText) (running \(elapsedText))"
        }
        if let totalSteps {
            let fallbackStep = max(0, latestExportStep ?? 0)
            let clamped = min(fallbackStep, totalSteps)
            let stepText = formatStepCount(clamped)
            let totalText = formatStepCount(totalSteps)
            return "Training model - \(stepText)/\(totalText) steps\(etaText) (running \(elapsedText))"
        }
        if let latestExportStep {
            let stepText = formatStepCount(latestExportStep)
            return "Training model - \(stepText) steps\(etaText) (running \(elapsedText))"
        }
        return "Training model - running \(elapsedText)"
    }

    func formatStepCount(_ value: Int) -> String {
        let raw = String(max(0, value))
        var grouped: [Character] = []
        var count = 0
        for ch in raw.reversed() {
            if count != 0 && count % 3 == 0 {
                grouped.append(",")
            }
            grouped.append(ch)
            count += 1
        }
        return String(grouped.reversed())
    }

    func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%dm %02ds", mins, secs)
    }

    private func brushExportEveryOverride() -> Int? {
        Self.envInt("EASYSPLAT_BRUSH_EXPORT_EVERY")
    }

    private func brushAdaptiveExportEvery(plan: BrushTrainingPlan, logURL: URL) -> Int? {
        guard let totalSteps = plan.totalSteps, totalSteps > 0 else { return nil }
        let rates = brushRecentStepRates(from: logURL, maxSamples: 12)
        guard !rates.isEmpty else { return nil }
        let sorted = rates.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return nil }
        let estimatedTotalSeconds = Double(totalSteps) / median
        let targetSeconds = Self.brushSnapshotTargetSeconds(estimatedTotalSeconds: estimatedTotalSeconds)
        let rawSteps = Int((median * targetSeconds).rounded())
        let clamped = Self.clampStepCount(rawSteps, min: Self.brushSnapshotMinSteps(), max: Self.brushSnapshotMaxSteps())
        if clamped <= 0 { return nil }
        return min(clamped, totalSteps)
    }

    private func clearBrushResumeSnapshot(in trainingURL: URL) {
        removeIfExists(trainingURL.appendingPathComponent("latest_snapshot.ply"))
    }

    private func updateResumeSnapshotFromLatestExport(
        trainingURL: URL,
        minModificationDate: Date? = nil
    ) {
        guard let exportURL = latestBrushUncompressedExport(
            in: trainingURL,
            minModificationDate: minModificationDate
        ) else { return }
        updateBrushResumeSnapshot(from: exportURL, trainingURL: trainingURL)
    }

    private func updateBrushResumeSnapshot(from exportURL: URL, trainingURL: URL) {
        guard exportURL.lastPathComponent.hasSuffix(".ply"),
              !exportURL.lastPathComponent.hasSuffix(".compressed.ply") else { return }
        let destURL = trainingURL.appendingPathComponent("latest_snapshot.ply")
        if exportURL.resolvingSymlinksInPath() == destURL.resolvingSymlinksInPath() {
            return
        }
        copyItemReplacing(source: exportURL, destination: destURL)
    }

    private func latestBrushUncompressedExport(in trainingURL: URL, minModificationDate: Date? = nil) -> URL? {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: trainingURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var latest: (URL, Date)?
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "ply" else { continue }
            if item.lastPathComponent.hasSuffix(".compressed.ply") { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if let minModificationDate, date < minModificationDate { continue }
            if latest == nil || date > latest!.1 {
                latest = (item, date)
            }
        }
        return latest?.0
    }

    private func copyItemReplacing(source: URL, destination: URL) {
        let fm = FileManager.default
        if source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
            return
        }
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".tmp")
        try? fm.removeItem(at: tempURL)
        do {
            try fm.copyItem(at: source, to: tempURL)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: tempURL, to: destination)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }

    private func brushRecentStepRates(from logURL: URL, maxSamples: Int) -> [Double] {
        guard let text = readTail(from: logURL, maxBytes: 512 * 1024) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var rates: [Double] = []
        rates.reserveCapacity(maxSamples)
        for line in lines {
            if let rate = brushTrainStepRate(from: String(line)), rate > 0 {
                rates.append(rate)
            }
        }
        if rates.count > maxSamples {
            return Array(rates.suffix(maxSamples))
        }
        return rates
    }

    private func readTail(from url: URL, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let offset = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            if data.isEmpty { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func brushSnapshotTargetSeconds(estimatedTotalSeconds: TimeInterval?) -> TimeInterval {
        let minSeconds = brushSnapshotMinSeconds()
        let maxSeconds = brushSnapshotMaxSeconds()
        let defaultSeconds = brushSnapshotDefaultSeconds()
        guard let estimatedTotalSeconds else {
            return clampSeconds(defaultSeconds, min: minSeconds, max: maxSeconds)
        }

        let target: TimeInterval
        switch estimatedTotalSeconds {
        case ..<600:
            target = minSeconds
        case ..<1800:
            target = max(minSeconds, 30)
        case ..<3600:
            target = max(minSeconds, 60)
        case ..<7200:
            target = max(minSeconds, 120)
        default:
            target = max(minSeconds, 300)
        }
        return clampSeconds(target, min: minSeconds, max: maxSeconds)
    }

    private static func brushSnapshotMinSteps() -> Int {
        Self.envInt("EASYSPLAT_BRUSH_SNAPSHOT_MIN_STEPS") ?? 5
    }

    private static func brushSnapshotMaxSteps() -> Int {
        Self.envInt("EASYSPLAT_BRUSH_SNAPSHOT_MAX_STEPS") ?? 5_000
    }

    private static func brushSnapshotMinSeconds() -> TimeInterval {
        Self.envDouble("EASYSPLAT_BRUSH_SNAPSHOT_MIN_SECONDS") ?? 20
    }

    private static func brushSnapshotMaxSeconds() -> TimeInterval {
        Self.envDouble("EASYSPLAT_BRUSH_SNAPSHOT_MAX_SECONDS") ?? 300
    }

    private static func brushSnapshotDefaultSeconds() -> TimeInterval {
        Self.envDouble("EASYSPLAT_BRUSH_SNAPSHOT_DEFAULT_SECONDS") ?? 120
    }

    private static func clampSeconds(_ value: TimeInterval, min minValue: TimeInterval, max maxValue: TimeInterval) -> TimeInterval {
        let safeMin = Swift.max(0, minValue)
        let safeMax = Swift.max(safeMin, maxValue)
        if value < safeMin { return safeMin }
        if value > safeMax { return safeMax }
        return value
    }

    private static func clampStepCount(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        let safeMin = Swift.max(1, minValue)
        let safeMax = Swift.max(safeMin, maxValue)
        if value < safeMin { return safeMin }
        if value > safeMax { return safeMax }
        return value
    }

    private static func envInt(_ key: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Int(raw),
              value > 0 else { return nil }
        return value
    }

    private static func envDouble(_ key: String) -> Double? {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Double(raw),
              value > 0 else { return nil }
        return value
    }

    private static func shouldEmitToolLogLine(_ line: String, isError: Bool) -> Bool {
        let trimmed = sanitizeToolLogLine(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let hasAlertKeyword = lower.contains("warning")
            || lower.contains("warn")
            || lower.contains("error")
            || lower.contains("fatal")
            || lower.contains("failed")
        if looksLikeProgressBar(trimmed),
           !hasAlertKeyword {
            return false
        }
        if isError {
            if hasAlertKeyword {
                return true
            }
            if glogSeverity(trimmed) == "I" {
                return false
            }
            return true
        }
        if trimmed.hasPrefix("EasySplat:") {
            return true
        }
        if lower.contains("warning") || lower.contains("warn") {
            return true
        }
        if lower.contains("error") || lower.contains("fatal") || lower.contains("failed") {
            return true
        }
        return false
    }

    private static func glogSeverity(_ line: String) -> Character? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return nil }
        let chars = Array(trimmed)
        let severity = chars[0]
        switch severity {
        case "I", "W", "E", "F":
            break
        default:
            return nil
        }
        guard chars[1...4].allSatisfy(\.isNumber) else { return nil }
        return severity
    }

    private static func sanitizeToolLogLine(_ line: String) -> String {
        let stripped = stripAnsiCodes(line)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(stripped.unicodeScalars.count)
        for scalar in stripped.unicodeScalars {
            if scalar.value == 9 {
                scalars.append(scalar)
                continue
            }
            if scalar.value < 32 || scalar.value == 127 {
                continue
            }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func stripAnsiCodes(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var output: [UnicodeScalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                // Skip ANSI escape sequences: ESC [ ... final-byte
                if index + 1 < scalars.count, scalars[index + 1].value == 0x5B {
                    index += 2
                    while index < scalars.count {
                        let value = scalars[index].value
                        if value >= 0x40 && value <= 0x7E {
                            index += 1
                            break
                        }
                        index += 1
                    }
                    continue
                } else {
                    index += 1
                    continue
                }
            }
            output.append(scalar)
            index += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func looksLikeProgressBar(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("steps") && (lower.contains("/s") || lower.contains("remaining") || lower.contains("eta")) {
            return true
        }
        if lower.contains("it/s") && (lower.contains("remaining") || lower.contains("eta")) {
            return true
        }
        // Many CLIs redraw a spinner/progress bar using box characters.
        if trimmed.contains("░") || trimmed.contains("▓") || trimmed.contains("█") || trimmed.contains("▉") || trimmed.contains("▊") {
            return true
        }
        let nonWhitespace = trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        guard nonWhitespace > 0 else { return false }
        let alnumCount = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        if alnumCount * 3 < nonWhitespace {
            return true
        }
        return false
    }

    private static func looksLikeErrorishLine(_ lowercasedLine: String) -> Bool {
        // Conservative: these are the kinds of tokens we want to surface live in the UI.
        if lowercasedLine.contains("error") || lowercasedLine.contains("fatal") || lowercasedLine.contains("failed") {
            return true
        }
        if lowercasedLine.contains("panic") || lowercasedLine.contains("traceback") || lowercasedLine.contains("exception") {
            return true
        }
        if lowercasedLine.contains("warning") || lowercasedLine.contains("warn") {
            return true
        }
        return false
    }

    private static func looksLikeBrushSpinnerLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard lower.contains("training") else { return false }
        // Brush prints a stylized status row like "·•░▓█🖌️ Training" many times.
        if line.contains("🖌") || line.contains("·") || line.contains("•") {
            return true
        }
        if line.contains("░") || line.contains("▓") || line.contains("█") || line.contains("▉") || line.contains("▊") {
            return true
        }
        return false
    }

    private static let brushStepRateRegex: NSRegularExpression = {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(?:it)?/s"#
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? (try! NSRegularExpression(pattern: "$^", options: []))
    }()

    func brushTrainStepProgress(from line: String) -> BrushTrainProgress? {
        // Brush's CLI progress bar includes a "{pos}/{len}" segment (often updated via "\r").
        // We parse the first "<digits>/<digits>" occurrence and treat it as step progress.
        let s = line
        var index = s.startIndex

        func isDigit(_ c: Character) -> Bool {
            c >= "0" && c <= "9"
        }

        while index < s.endIndex {
            // Find the start of a digit run.
            while index < s.endIndex, !isDigit(s[index]) {
                index = s.index(after: index)
            }
            if index >= s.endIndex { break }

            let aStart = index
            var aEnd = index
            while aEnd < s.endIndex, isDigit(s[aEnd]) {
                aEnd = s.index(after: aEnd)
            }
            let aStr = String(s[aStart..<aEnd])
            let a = Int(aStr) ?? -1

            var slash = aEnd
            while slash < s.endIndex, s[slash] == " " {
                slash = s.index(after: slash)
            }
            guard slash < s.endIndex, s[slash] == "/" else {
                index = aEnd
                continue
            }

            var bStart = s.index(after: slash)
            while bStart < s.endIndex, s[bStart] == " " {
                bStart = s.index(after: bStart)
            }
            var bEnd = bStart
            while bEnd < s.endIndex, isDigit(s[bEnd]) {
                bEnd = s.index(after: bEnd)
            }
            guard bEnd > bStart else {
                index = aEnd
                continue
            }

            let bStr = String(s[bStart..<bEnd])
            let b = Int(bStr) ?? -1
            guard a >= 0, b > 0 else {
                index = aEnd
                continue
            }
            return BrushTrainProgress(step: a, total: b)
        }

        return nil
    }

    func brushTrainStepRate(from line: String) -> Double? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = Self.brushStepRateRegex.firstMatch(in: line, range: range) else { return nil }
        guard match.numberOfRanges > 1, let rateRange = Range(match.range(at: 1), in: line) else { return nil }
        let value = Double(line[rateRange])
        guard let value, value > 0 else { return nil }
        return value
    }

}

private final class StageTimingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var starts: [PipelineStage: ContinuousClock.Instant] = [:]

    func start(_ stage: PipelineStage) {
        lock.lock()
        starts[stage] = clock.now
        lock.unlock()
    }

    func finish(_ stage: PipelineStage) -> String? {
        lock.lock()
        guard let start = starts[stage] else {
            lock.unlock()
            return nil
        }
        starts[stage] = nil
        let duration = clock.now - start
        lock.unlock()
        return Self.format(duration)
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = max(0, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        let totalSeconds = Int(seconds.rounded(.down))

        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let rem = totalSeconds % 60
            return "\(minutes)m \(rem)s"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

private final class LastLogTimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLogTime = Date()

    func bump() {
        lock.lock()
        lastLogTime = Date()
        lock.unlock()
    }

    func silenceSeconds() -> TimeInterval {
        lock.lock()
        let silence = Date().timeIntervalSince(lastLogTime)
        lock.unlock()
        return silence
    }
}

private final class PipelineLogger: @unchecked Sendable {
    private let eventsURL: URL
    private let logURL: URL
    private let emit: @Sendable (PipelineEvent) -> Void
    private let encoder: JSONEncoder
    private let logHandle: FileHandle?
    private let eventsHandle: FileHandle?
    private let lock = NSLock()
    private var lastProgressKeyByStage: [PipelineStage: String] = [:]

    init(eventsURL: URL, logURL: URL, emit: @escaping @Sendable (PipelineEvent) -> Void) {
        self.eventsURL = eventsURL
        self.logURL = logURL
        self.emit = emit
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        self.logHandle = try? FileHandle(forWritingTo: logURL)
        self.eventsHandle = try? FileHandle(forWritingTo: eventsURL)
    }

    deinit {
        try? logHandle?.close()
        try? eventsHandle?.close()
    }

    func emit(_ event: PipelineEvent) {
        emit(event)
        lock.lock()
        appendEvent(event)
        switch event {
        case let .stageStarted(stage):
            appendLogLine(stage: stage, line: "Stage started", isError: false)
        case let .stageProgress(stage, fraction, message):
            appendProgressLine(stage: stage, fraction: fraction, message: message)
        case let .stageLog(stage, line, isError):
            appendLogLine(stage: stage, line: line, isError: isError)
        case let .stageFinished(stage):
            appendLogLine(stage: stage, line: "Stage finished", isError: false)
        case let .pipelineFailed(stage, userMessage, _):
            appendLogLine(stage: stage, line: userMessage, isError: true)
        }
        lock.unlock()
    }

    private func appendEvent(_ event: PipelineEvent) {
        guard let data = try? encoder.encode(event) else { return }
        var line = data
        line.append(0x0A)
        guard let handle = eventsHandle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return
        }
    }

    private func appendLogLine(stage: PipelineStage?, line: String, isError: Bool) {
        guard let handle = logHandle else { return }
        let prefix = isError ? "[err] " : ""
        let stagePrefix: String = {
            guard let stage else { return "" }
            return "[\(stage.displayName)] "
        }()
        if let data = "\(prefix)\(stagePrefix)\(line)\n".data(using: .utf8) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }

    private func appendProgressLine(stage: PipelineStage, fraction: Double, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let line: String
        if fraction < 0 {
            line = trimmed
        } else {
            let clamped = min(max(fraction, 0.0), 1.0)
            let pct = Int((clamped * 100.0).rounded())
            line = "\(pct)% \(trimmed)"
        }

        // Progress events can be very frequent; only log when the (percent,message) changes.
        let key = line
        if lastProgressKeyByStage[stage] == key {
            return
        }
        lastProgressKeyByStage[stage] = key
        appendLogLine(stage: stage, line: line, isError: false)
    }
}

#if DEBUG
struct TestSelectedFrameMapping: Codable, Sendable {
    let outputFileName: String
    let groupId: String
    let isVideo: Bool
    let sourcePath: String
}

struct TestFrameExtractionProfile: Sendable {
    let targetCount: Int
    let maxDimension: CGFloat
    let targetFPS: Int
    let minDistanceRatio: Double
    let sharpnessFloor: Double
    let sharpnessRatio: Double
    let outputFormat: FrameOutputFormat
}

struct TestBrushTrainProgress: Sendable {
    let step: Int
    let total: Int
}

struct TestBrushTrainingPlan: Sendable {
    let totalSteps: Int?
    let exportEvery: Int?
}

enum TestStageOutputStatus: Equatable, Sendable {
    case valid
    case missing
    case corrupt
}

extension PipelineRunner {
    func loadImagesForTesting(in directory: URL) throws -> [URL] {
        try loadImages(in: directory)
    }

    func loadPhotosForTesting(in directory: URL) throws -> [URL] {
        try loadPhotos(in: directory)
    }

    func test_downsampleFrames(_ frames: [URL], targetCount: Int) -> [URL] {
        downsampleFrames(frames, targetCount: targetCount)
    }

    func test_downsampleSelectedFrames(to targetCount: Int, paths: ProjectPaths) throws -> [URL]? {
        try downsampleSelectedFrames(to: targetCount, paths: paths)
    }

    func test_normalizeSelectedImagesForTooling(paths: ProjectPaths) throws -> Int {
        try normalizeSelectedImagesForTooling(paths: paths)
    }

    func test_targetCountForVideo(index: Int, total: Int, targetCount: Int) -> Int {
        targetCountForVideo(index: index, total: total, targetCount: targetCount)
    }

    func test_filterVeryBlurryVideoFrames(
        frames: [URL],
        sharpnessByFrame: [URL: Double],
        sharpnessFloor: Double,
        maxDropFraction: Double,
        floorScale: Double
    ) -> (frames: [URL], dropped: Int) {
        let profile = FrameExtractionProfile(
            targetCount: 0,
            maxDimension: 0,
            targetFPS: 1,
            minDistanceRatio: 0,
            sharpnessFloor: sharpnessFloor,
            sharpnessRatio: 0,
            outputFormat: .jpeg
        )
        let result = filterVeryBlurryVideoFrames(
            frames: frames,
            sharpnessByFrame: sharpnessByFrame,
            profile: profile,
            maxDropFraction: maxDropFraction,
            floorScale: floorScale
        )
        return (result.frames, result.dropped)
    }

    func test_frameExtractionProfile(for quality: QualityPreset) -> TestFrameExtractionProfile {
        let profile = frameExtractionProfile(for: quality)
        return TestFrameExtractionProfile(
            targetCount: profile.targetCount,
            maxDimension: profile.maxDimension,
            targetFPS: profile.targetFPS,
            minDistanceRatio: profile.minDistanceRatio,
            sharpnessFloor: profile.sharpnessFloor,
            sharpnessRatio: profile.sharpnessRatio,
            outputFormat: profile.outputFormat
        )
    }

    func test_shouldUseSequential(selectedFrames: [URL], input: InputSpec, forceExhaustive: Bool) -> Bool {
        shouldUseSequential(selectedFrames: selectedFrames, input: input, forceExhaustive: forceExhaustive)
    }

    func test_brushExportStep(from url: URL) -> Int? {
        brushExportStep(from: url)
    }

    func test_latestBrushExport(in trainingURL: URL, minModificationDate: Date? = nil) -> (file: URL, step: Int?)? {
        latestBrushExport(in: trainingURL, minModificationDate: minModificationDate)
    }

    func test_updateBrushResumeSnapshot(from exportURL: URL, trainingURL: URL) {
        updateBrushResumeSnapshot(from: exportURL, trainingURL: trainingURL)
    }

    func test_clearBrushResumeSnapshot(in trainingURL: URL) {
        clearBrushResumeSnapshot(in: trainingURL)
    }

    func test_brushTrainStepProgress(from line: String) -> TestBrushTrainProgress? {
        guard let progress = brushTrainStepProgress(from: line) else { return nil }
        return TestBrushTrainProgress(step: progress.step, total: progress.total)
    }

    func test_brushTrainStepRate(from line: String) -> Double? {
        brushTrainStepRate(from: line)
    }

    func test_brushTrainingPlan(for preset: PresetSpec) -> TestBrushTrainingPlan {
        let plan = brushTrainingPlan(for: preset)
        return TestBrushTrainingPlan(totalSteps: plan.totalSteps, exportEvery: plan.exportEvery)
    }

    func test_trainingStatusMessage(
        elapsed: TimeInterval,
        step: Int?,
        total: Int?,
        latestExportStep: Int?,
        totalSteps: Int?,
        etaSeconds: TimeInterval? = nil
    ) -> String {
        let progress: BrushTrainProgress?
        if let step, let total {
            progress = BrushTrainProgress(step: step, total: total)
        } else {
            progress = nil
        }
        return trainingStatusMessage(
            elapsed: elapsed,
            progress: progress,
            latestExportStep: latestExportStep,
            totalSteps: totalSteps,
            etaSeconds: etaSeconds
        )
    }

    func test_trainingEtaEstimate(rates: [Double], step: Int, total: Int) -> TimeInterval? {
        let estimator = BrushTrainingEtaEstimator()
        for rate in rates {
            estimator.update(rate: rate)
        }
        return estimator.estimateRemainingSeconds(step: step, total: total)
    }

    func test_trainingEtaEstimatesWithSpike(
        initialRates: [Double],
        spikeRate: Double,
        step: Int,
        total: Int
    ) -> (baseline: TimeInterval?, damped: TimeInterval?) {
        let estimator = BrushTrainingEtaEstimator()
        for rate in initialRates {
            estimator.update(rate: rate)
        }
        let baseline = estimator.estimateRemainingSeconds(step: step, total: total)
        estimator.update(rate: spikeRate)
        let damped = estimator.estimateRemainingSeconds(step: step, total: total)
        return (baseline: baseline, damped: damped)
    }

    func test_shouldEmitToolLogLine(_ line: String, isError: Bool) -> Bool {
        Self.shouldEmitToolLogLine(line, isError: isError)
    }

    func test_colmapGpuOverride() -> Bool? {
        colmapGpuOverride()
    }

    func test_vggtUseBundleAdjustmentPreference() -> Bool {
        vggtUseBundleAdjustmentPreference()
    }

    func test_vggtMaxReprojectionErrorPreference() -> Double {
        vggtMaxReprojectionErrorPreference()
    }

    func test_vggtSharedCameraPreference() -> Bool {
        vggtSharedCameraPreference()
    }

    func test_vggtCameraTypePreference() -> String {
        vggtCameraTypePreference()
    }

    func test_vggtVisibilityThresholdPreference() -> Double {
        vggtVisibilityThresholdPreference()
    }

    func test_vggtQueryFrameCountPreference() -> Int {
        vggtQueryFrameCountPreference()
    }

    func test_vggtMaxQueryPointsPreference() -> Int {
        vggtMaxQueryPointsPreference()
    }

    func test_vggtFineTrackingPreference() -> Bool {
        vggtFineTrackingPreference()
    }

    func test_vggtKeypointExtractorPreference() -> String {
        vggtKeypointExtractorPreference()
    }

    func test_vggtBaMaxFramesLimit(autoTuneTier: HardwareProfile.Tier?) -> Int {
        let autoTune = autoTuneTier.map { tier in
            AutoTuneProfile(
                tier: tier,
                vggtImageLoadResolution: 0,
                vggtFixedResolution: 0,
                vggtMaxPoints: 0,
                colmapMaxNumFeatures: 0,
                colmapMaxNumMatches: 0,
                sequentialOverlap: 0,
                exhaustiveBlockSize: 0,
                threadCap: 0,
                colmapMaxImageSizeCap: nil,
                vggtAllowed: true
            )
        }
        return vggtBaMaxFramesLimit(autoTune: autoTune)
    }

    func test_sfmBackendPolicy() -> SfmBackend {
        sfmBackendPolicy()
    }

    func test_sfmBackendFallbackOrder() -> [SfmBackend] {
        sfmBackendFallbackOrder(override: sfmBackendOverride())
    }

    func test_fastvggtMergingPreference() -> Int {
        fastvggtMergingPreference()
    }

    func test_fastvggtMergeRatioPreference() -> Double {
        fastvggtMergeRatioPreference()
    }

    func test_fastvggtConfidenceThresholdPreference() -> Double {
        fastvggtConfidenceThresholdPreference()
    }

    func test_fastvggtUseBundleAdjustmentPreference() -> Bool {
        fastvggtUseBundleAdjustmentPreference()
    }

    func test_fastvggtRequireRefinedModelPreference() -> Bool {
        fastvggtRequireRefinedModelPreference()
    }

    func test_fastvggtBaMaxIterationsPreference() -> Int {
        fastvggtBaMaxIterationsPreference()
    }

    func test_fastvggtBaRefineFocalPreference() -> Bool {
        fastvggtBaRefineFocalPreference()
    }

    func test_fastvggtBaRefinePrincipalPointPreference() -> Bool {
        fastvggtBaRefinePrincipalPointPreference()
    }

    func test_fastvggtBaRefineExtraParamsPreference() -> Bool {
        fastvggtBaRefineExtraParamsPreference()
    }

    func test_fastvggtFullCoveragePreference() -> Bool {
        fastvggtFullCoveragePreference()
    }

    func test_fastvggtNoFallbackPreference() -> Bool {
        fastvggtNoFallbackPreference()
    }

    func test_fastvggtGpuOnlyPreference() -> Bool {
        fastvggtGpuOnlyPreference()
    }

    func test_fastvggtPostprocessPreference() -> String {
        fastvggtPostprocessPreference()
    }

    func test_fastvggtCoveragePlannerPreference() -> String {
        fastvggtCoveragePlannerPreference()
    }

    func test_fastvggtCoverageWindowTokensPreference() -> Int {
        fastvggtCoverageWindowTokensPreference()
    }

    func test_fastvggtCoverageOverlapPreference() -> Double {
        fastvggtCoverageOverlapPreference()
    }

    func test_fastvggtCoverageMaxRoundsPreference() -> Int {
        fastvggtCoverageMaxRoundsPreference()
    }

    func test_fastvggtStrictCoverageDefaults(
        autoTuneTier: HardwareProfile.Tier?,
        hardwareTier: HardwareProfile.Tier?,
        hardwareMemoryGB: Double? = nil,
        hardwareGpuWorkingSetGB: Double? = nil,
        input: InputSpec,
        selectedFrameCount: Int
    ) -> (planner: String, windowTokens: Int, overlap: Double, maxRounds: Int, postprocess: String) {
        let autoTune = autoTuneTier.map { tier in
            AutoTuneProfile(
                tier: tier,
                vggtImageLoadResolution: 0,
                vggtFixedResolution: 0,
                vggtMaxPoints: 0,
                colmapMaxNumFeatures: 0,
                colmapMaxNumMatches: 0,
                sequentialOverlap: 0,
                exhaustiveBlockSize: 0,
                threadCap: 0,
                colmapMaxImageSizeCap: nil,
                vggtAllowed: true
            )
        }
        let hardwareProfile: HardwareProfile? = {
            if let hardwareMemoryGB {
                return HardwareProfile(
                    memoryGB: hardwareMemoryGB,
                    cpuCount: 8,
                    gpuWorkingSetGB: hardwareGpuWorkingSetGB
                )
            }
            guard let hardwareTier else { return nil }
            let memoryGB: Double
            switch hardwareTier {
            case .low:
                memoryGB = 16
            case .mid:
                memoryGB = 24
            case .high:
                memoryGB = 48
            }
            return HardwareProfile(memoryGB: memoryGB, cpuCount: 8, gpuWorkingSetGB: 8)
        }()
        let defaults = fastvggtStrictCoverageDefaults(
            input: input,
            selectedFrameCount: selectedFrameCount,
            autoTune: autoTune,
            hardwareProfile: hardwareProfile
        )
        return (
            planner: defaults.coveragePlanner,
            windowTokens: defaults.coverageWindowTokens,
            overlap: defaults.coverageOverlap,
            maxRounds: defaults.coverageMaxRounds,
            postprocess: defaults.postprocessMode
        )
    }

    func test_fastvggtCoverageConfig(
        strictModeEnabled: Bool,
        input: InputSpec,
        selectedFrameCount: Int,
        autoTuneTier: HardwareProfile.Tier?,
        hardwareTier: HardwareProfile.Tier?,
        hardwareMemoryGB: Double? = nil,
        hardwareGpuWorkingSetGB: Double? = nil
    ) -> FastVggtCoverageConfig {
        let autoTune = autoTuneTier.map { tier in
            AutoTuneProfile(
                tier: tier,
                vggtImageLoadResolution: 0,
                vggtFixedResolution: 0,
                vggtMaxPoints: 0,
                colmapMaxNumFeatures: 0,
                colmapMaxNumMatches: 0,
                sequentialOverlap: 0,
                exhaustiveBlockSize: 0,
                threadCap: 0,
                colmapMaxImageSizeCap: nil,
                vggtAllowed: true
            )
        }
        let hardwareProfile: HardwareProfile? = {
            if let hardwareMemoryGB {
                return HardwareProfile(
                    memoryGB: hardwareMemoryGB,
                    cpuCount: 8,
                    gpuWorkingSetGB: hardwareGpuWorkingSetGB
                )
            }
            guard let hardwareTier else { return nil }
            let memoryGB: Double
            switch hardwareTier {
            case .low:
                memoryGB = 16
            case .mid:
                memoryGB = 24
            case .high:
                memoryGB = 48
            }
            return HardwareProfile(memoryGB: memoryGB, cpuCount: 8, gpuWorkingSetGB: 8)
        }()
        return fastvggtCoverageConfig(
            strictModeEnabled: strictModeEnabled,
            input: input,
            selectedFrameCount: selectedFrameCount,
            autoTune: autoTune,
            hardwareProfile: hardwareProfile,
            manifestPath: nil
        )
    }

    func test_tuneFastVggtRefinementColmapOptions(
        frameCount: Int,
        extractOptions: ColmapOptions,
        matchOptions: ColmapOptions
    ) -> (extract: ColmapOptions, match: ColmapOptions, notes: [String]) {
        tuneFastVggtRefinementColmapOptions(
            frameCount: frameCount,
            extractOptions: extractOptions,
            matchOptions: matchOptions
        )
    }

    func test_colmapErrorIndicatesGpuFailure(_ error: ColmapRunnerError) -> Bool {
        colmapErrorIndicatesGpuFailure(error)
    }

    func test_glomapErrorIndicatesMissingOpenSSL(_ error: Error) -> Bool {
        glomapErrorIndicatesMissingOpenSSL(error)
    }

    func test_failureMessages(for error: Error, stage: PipelineStage) -> (userMessage: String, debugMessage: String) {
        failureMessages(for: error, stage: stage)
    }

    func test_isStageComplete(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) -> Bool {
        isStageComplete(stage, paths: paths, metadata: metadata)
    }

    func test_validateStageOutput(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) throws -> TestStageOutputStatus {
        switch try validateStageOutput(stage, paths: paths, metadata: metadata) {
        case .valid:
            return .valid
        case .missing:
            return .missing
        case .corrupt:
            return .corrupt
        }
    }

    func test_cleanForRetry(failedStage: PipelineStage, paths: ProjectPaths) throws {
        try cleanForRetry(failedStage: failedStage, paths: paths)
    }

    func test_makePipelineErrorInvalidInput() -> Error {
        PipelineError.invalidInput
    }

    func test_makePipelineErrorLowQuality(_ score: ReconstructionScore) -> Error {
        PipelineError.lowQualityReconstruction(score)
    }

    func test_makePipelineErrorImageTranscodeFailed(_ message: String) -> Error {
        PipelineError.imageTranscodeFailed(message)
    }

    func test_makePipelineErrorOutputMissing() -> Error {
        PipelineError.outputMissing
    }

    static func test_writePipelineLogs(events: [PipelineEvent], logURL: URL, eventsURL: URL) {
        let logger = PipelineLogger(eventsURL: eventsURL, logURL: logURL, emit: { _ in })
        for event in events {
            logger.emit(event)
        }
    }
}
#endif
