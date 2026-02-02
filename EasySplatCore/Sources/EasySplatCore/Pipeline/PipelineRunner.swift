import Foundation
import Dispatch
import ImageIO
import UniformTypeIdentifiers

public final class PipelineRunner: @unchecked Sendable {

    public struct Tooling {
        public var colmap: ColmapRunner
        public var glomap: GlomapRunner
        public var brush: BrushRunner
        public var vggtSfm: VggtSfmRunning
        public var learnedMatching: LearnedMatchingRunning

        public init(colmap: ColmapRunner = ColmapRunner(),
                    glomap: GlomapRunner = GlomapRunner(),
                    brush: BrushRunner = BrushRunner(),
                    vggtSfm: VggtSfmRunning = VggtSfmRunner(),
                    learnedMatching: LearnedMatchingRunning = LearnedMatchingRunner()) {
            self.colmap = colmap
            self.glomap = glomap
            self.brush = brush
            self.vggtSfm = vggtSfm
            self.learnedMatching = learnedMatching
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.glomap = GlomapRunner(runner: runner)
            self.brush = BrushRunner(runner: runner)
            self.vggtSfm = VggtSfmRunner(runner: runner)
            self.learnedMatching = LearnedMatchingRunner(runner: runner)
        }
    }
    public struct PipelineConfig: Sendable {
        public var toolchain: ToolchainPaths
        public var preset: PresetSpec

        public init(toolchain: ToolchainPaths, preset: PresetSpec) {
            self.toolchain = toolchain
            self.preset = preset
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

        func shouldRunStage(_ stage: PipelineStage) -> Bool {
            guard let lastCompletedStage else { return true }
            if stageIndex(stage) <= stageIndex(lastCompletedStage) {
                return !isStageComplete(stage, paths: paths, metadata: metadata)
            }
            return true
        }

        func markStageComplete(_ stage: PipelineStage) {
            metadata.state = PipelineState(stage: stage, attempt: metadata.state.attempt, lastError: nil, resumeToken: nil)
            try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        }

        func emitFailure(stage: PipelineStage, userMessage: String, debugMessage: String) {
            didEmitFailure = true
            metadata.state = PipelineState(stage: stage, attempt: metadata.state.attempt, lastError: userMessage, resumeToken: nil)
            try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
            emit(.pipelineFailed(stage: stage, userMessage: userMessage, debugMessage: debugMessage))
        }

        do {
            try Task.checkCancellation()
            if shouldRunStage(.importInput) {
                currentStage = .importInput
                emit(.stageStarted(stage: .importInput))
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
            var learnedPairsFile: URL? = nil
            var learnedMpsAvailable = false

            if metadata.input.hasVideos {
                if shouldRunStage(.extractFrames) {
                    currentStage = .extractFrames
                    emit(.stageStarted(stage: .extractFrames))
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
                    }
                    emit(.stageFinished(stage: .extractFrames))
                    markStageComplete(.extractFrames)
                }
            }

            if metadata.input.hasVideos || metadata.input.hasPhotos {
                if shouldRunStage(.selectFrames) {
                    currentStage = .selectFrames
                    emit(.stageStarted(stage: .selectFrames))
                    try self.resetDirectory(paths.framesSelectedURL)
                    self.removeIfExists(paths.framesSelectedManifestURL)
                    self.removeIfExists(paths.sfmPairListURL)
                    let selector = FrameSelector()
                    var groups: [SelectedFrameGroup] = []

                    if metadata.input.hasVideos {
                        let videos = metadata.input.videoFiles
                        let totalVideos = Double(max(videos.count, 1))
                        for (index, _) in videos.enumerated() {
                            try Task.checkCancellation()
                            let rawDir = rawFramesDirectory(index: index, paths: paths)
                            let rawFrames = try loadImages(in: rawDir)
                            let perVideoTarget = targetCountForVideo(index: index, total: videos.count, targetCount: targetFrames)
                            if perVideoTarget == 0 {
                                continue
                            }
                            let chosen = selector.selectFrames(from: rawFrames, targetCount: perVideoTarget, mode: .smartExtracted) { fraction, message in
                                let scaled = (Double(index) / totalVideos) + (fraction / totalVideos)
                                emit(.stageProgress(stage: .selectFrames, fraction: scaled, message: message))
                            }
                            if !chosen.isEmpty {
                                let groupId = String(format: "video_%03d", index)
                                groups.append(.init(id: groupId, frames: chosen, isVideo: true))
                                emit(.stageLog(
                                    stage: .selectFrames,
                                    line: "Selected \(chosen.count) of \(rawFrames.count) frames from \(groupId).",
                                    isError: false
                                ))
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

            try Task.checkCancellation()
            var backendPolicy = sfmBackendPolicy()
            let enableDeprecatedLearned = ProcessInfo.processInfo.environment["EASYSPLAT_ENABLE_DEPRECATED_LEARNED"] == "1"
            if backendPolicy == .learned && !enableDeprecatedLearned {
                emit(.stageLog(
                    stage: .sfmFeatures,
                    line: "SfM backend learned_sfm (MASt3R) is deprecated and disabled; falling back to COLMAP. Set EASYSPLAT_ENABLE_DEPRECATED_LEARNED=1 to override.",
                    isError: true
                ))
                backendPolicy = .colmap
            }

            if backendPolicy == .vggt {
                let fm = FileManager.default
                let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)

                // VGGT produces a COLMAP-format sparse model directly (no database/matching/mapping).
                if shouldRunStage(.sfmFeatures) {
                    currentStage = .sfmFeatures
                    emit(.stageStarted(stage: .sfmFeatures))
                    emit(.stageLog(stage: .sfmFeatures, line: "SfM backend: vggt-mps.", isError: false))

                    self.removeIfExists(paths.colmapDatabaseURL)
                    try self.resetDirectory(paths.colmapSparseURL)
                    try self.resetDirectory(sparseZero)

                    let vggtConfig = VggtSfmConfig(
                        device: vggtDevicePreference(),
                        imageLoadResolution: vggtImageLoadResolutionPreference(preset: metadata.preset),
                        vggtFixedResolution: vggtFixedResolutionPreference(),
                        confidenceThreshold: vggtConfidenceThresholdPreference(),
                        maxPoints: vggtMaxPointsPreference(preset: metadata.preset)
                    )

                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "Running VGGT on \(vggtConfig.device) (load=\(vggtConfig.imageLoadResolution)px, vggt=\(vggtConfig.vggtFixedResolution)px, maxPoints=\(vggtConfig.maxPoints)).",
                        isError: false
                    ))

                    let vggtToolLog = ToolLogWriter(fileURL: paths.vggtLogURL, toolName: "vggt-mps")
                    vggtToolLog.beginSection(
                        title: "sfm",
                        metadata: [
                            "device": vggtConfig.device,
                            "images": paths.framesSelectedURL.path,
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
                        if Self.shouldEmitToolLogLine(line, isError: isErr) {
                            emit(.stageLog(stage: .sfmFeatures, line: line, isError: isErr))
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

                    emit(.stageFinished(stage: .sfmFeatures))
                    markStageComplete(.sfmFeatures)
                } else if sparseModelFilesExist(at: sparseZero) && !fm.fileExists(atPath: paths.colmapDatabaseURL.path) {
                    fm.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
                }

                if shouldRunStage(.sfmMatching) {
                    currentStage = .sfmMatching
                    emit(.stageStarted(stage: .sfmMatching))
                    emit(.stageLog(stage: .sfmMatching, line: "VGGT produces a sparse model directly; skipping matching.", isError: false))
                    emit(.stageFinished(stage: .sfmMatching))
                    markStageComplete(.sfmMatching)
                }

                if shouldRunStage(.sfmMapping) {
                    currentStage = .sfmMapping
                    emit(.stageStarted(stage: .sfmMapping))
                    guard sparseModelFilesExist(at: sparseZero) else {
                        throw PipelineError.outputMissing
                    }
                    emit(.stageLog(stage: .sfmMapping, line: "VGGT produced sparse model; skipping mapping.", isError: false))
                    emit(.stageFinished(stage: .sfmMapping))
                    markStageComplete(.sfmMapping)
                }
            } else {
                if backendPolicy == .learned {
                do {
                    emit(.stageProgress(stage: .sfmFeatures, fraction: 0.01, message: "Probing learned MPS"))
                    let timeout = learnedMpsProbeTimeoutSeconds()
                    let probe = try await runWithTimeout(seconds: timeout) {
                        guard let learnedToolchain = self.config.toolchain.learnedSfm else {
                            return LearnedMpsProbeResult(
                                pythonMachine: "missing",
                                platform: "missing",
                                torchVersion: "missing",
                                mpsBuilt: false,
                                mpsAvailable: false,
                                mpsAllocOK: false,
                                failure: "learned_sfm toolchain missing"
                            )
                        }
                        return try await LearnedMpsProbe.run(python: learnedToolchain.python)
                    }
                    learnedMpsAvailable = probe.isMpsUsable
                    emit(.stageLog(
                        stage: .sfmFeatures,
                        line: "Learned MPS available: \(learnedMpsAvailable ? "yes" : "no").",
                        isError: !learnedMpsAvailable
                    ))
                    if !learnedMpsAvailable, let failure = probe.failure {
                        emit(.stageLog(stage: .sfmFeatures, line: "Learned MPS probe: \(failure)", isError: true))
                    }
                } catch is TimeoutError {
                    learnedMpsAvailable = false
                    emit(.stageLog(stage: .sfmFeatures, line: "Learned MPS probe timed out; skipping learned matching.", isError: true))
                } catch {
                    learnedMpsAvailable = false
                    emit(.stageLog(stage: .sfmFeatures, line: "Learned MPS probe failed; skipping learned matching. \(error)", isError: true))
                }
            }
            let learnedOutputsAvailable = backendPolicy == .learned && learnedOutputsExist(paths: paths)
            let learnedStagesComplete = !shouldRunStage(.sfmFeatures) && !shouldRunStage(.sfmMatching)
            let shouldAttemptLearned = backendPolicy == .learned &&
                (self.config.toolchain.learnedSfm != nil) &&
                learnedMpsAvailable &&
                (shouldRunStage(.sfmFeatures) || shouldRunStage(.sfmMatching))
            var learnedMatchingCompleted = learnedOutputsAvailable && learnedStagesComplete

            if shouldAttemptLearned {
                struct LearnedMatchingWatchdogError: Error {
                    let seconds: Int
                }

                do {
                    let device = learnedDevicePreference()
                    let pairing: String = (metadata.input.hasVideos && !metadata.input.hasPhotos) ? "video" : "photos"
                    let (overlap, stride, loopK): (Int, Int, Int) = {
                        if pairing == "video" {
                            return (colmapMatchOptions.sequentialOverlap, 5, 3)
                        }
                        return (0, 0, 20)
                    }()
                    let learnedMaxImageSize = learnedMaxImageSizePreference(colmapMaxImageSize: colmapMaxImageSize, preset: metadata.preset)

                    currentStage = .sfmFeatures
                    emit(.stageStarted(stage: .sfmFeatures))

                    learnedPairsFile = nil
                    if pairing == "video", metadata.input.videoFiles.count > 1 {
                        do {
                            if selectedFrameManifest.isEmpty {
                                emit(.stageLog(
                                    stage: .sfmFeatures,
                                    line: "Selected-frame manifest missing; learned matching will pair across all frames.",
                                    isError: true
                                ))
                                self.removeIfExists(paths.sfmPairListURL)
                            } else {
                                let available = Set(selectedFrames.map { $0.lastPathComponent })
                                let groups = frameGroups(from: selectedFrameManifest, allowedNames: available)
                                let bridgeCount = learnedPairBridgeCount(overlap: overlap)
                                let pairs = PairListBuilder.buildPairs(
                                    groups: groups,
                                    overlap: overlap,
                                    stride: stride,
                                    bridgeCount: bridgeCount
                                )
                                if pairs.isEmpty {
                                    self.removeIfExists(paths.sfmPairListURL)
                                } else {
                                    try PairListBuilder.writePairs(pairs, to: paths.sfmPairListURL)
                                    learnedPairsFile = paths.sfmPairListURL
                                    emit(.stageLog(
                                        stage: .sfmFeatures,
                                        line: "Learned matching pairs: \(pairs.count) (bridges: \(bridgeCount)).",
                                        isError: false
                                    ))
                                }
                            }
                        } catch {
                            self.removeIfExists(paths.sfmPairListURL)
                            emit(.stageLog(
                                stage: .sfmFeatures,
                                line: "Failed to build learned pairs list; falling back to default pairing. \(error)",
                                isError: true
                            ))
                        }
                    } else {
                        self.removeIfExists(paths.sfmPairListURL)
                    }
                    let learnedConfig = LearnedMatchingConfig(
                        device: device,
                        maxImageSize: learnedMaxImageSize,
                        sequentialOverlap: overlap,
                        stride: stride,
                        loopK: loopK,
                        pairing: pairing,
                        cameraModel: cameraModel(for: metadata.preset),
                        requireDevice: true,
                        offline: true,
                        pairsFile: learnedPairsFile
                    )
                    emit(.stageLog(stage: .sfmFeatures, line: "Running learned matching on \(device) (\(pairing)).", isError: false))
                    if learnedMaxImageSize != colmapMaxImageSize {
                        emit(.stageLog(
                            stage: .sfmFeatures,
                            line: "Learned matching max image size: \(learnedMaxImageSize)px (COLMAP: \(colmapMaxImageSize)px).",
                            isError: false
                        ))
                    }

                    self.removeIfExists(paths.colmapDatabaseURL)
                    try self.resetDirectory(paths.colmapSparseURL)
                    try self.resetDirectory(paths.sfmLearnedFeaturesURL)
                    self.removeIfExists(paths.sfmLearnedMatchListURL)

                    let watchdogSeconds = learnedWatchdogSeconds()
                    let progressTracker = LearnedMatchingProgressTracker()

                    let lastLog = LastLogTimeBox()
                    let learnedMatching = tooling.learnedMatching
                    guard let learnedToolchain = config.toolchain.learnedSfm else {
                        throw LearnedMatchingError.missingTool
                    }
                    let imagesURL = paths.framesSelectedURL
                    let outDatabaseURL = paths.colmapDatabaseURL
                    let outFeaturesURL = paths.sfmLearnedFeaturesURL
                    let outMatchListURL = paths.sfmLearnedMatchListURL

                    let learnedToolLogURL = paths.logsURL.appendingPathComponent("learned_sfm.log")
                    let learnedToolLog = ToolLogWriter(fileURL: learnedToolLogURL, toolName: "learned_sfm")
                    learnedToolLog.beginSection(
                        title: "matching",
                        metadata: [
                            "database": outDatabaseURL.path,
                            "device": device,
                            "images": imagesURL.path,
                            "maxImageSize": "\(learnedMaxImageSize)",
                            "pairing": pairing
                        ]
                    )
                    emit(.stageLog(stage: .sfmFeatures, line: "Learned SfM tool log: \(learnedToolLogURL.lastPathComponent)", isError: false))

                    let onLearnedLog: @Sendable (String, Bool) -> Void = { line, isErr in
                        lastLog.bump()

                        learnedToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
                        if Self.shouldEmitToolLogLine(line, isError: isErr) {
                            emit(.stageLog(stage: .sfmFeatures, line: line, isError: isErr))
                        }
                        if let update = progressTracker.ingest(line) {
                            emit(.stageProgress(stage: .sfmFeatures, fraction: update.fraction, message: update.message))
                        }
                    }

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await learnedMatching.run(
                                toolchain: learnedToolchain,
                                images: imagesURL,
                                outDatabase: outDatabaseURL,
                                outFeatures: outFeaturesURL,
                                outMatchList: outMatchListURL,
                                config: learnedConfig,
                                onLog: onLearnedLog
                            )
                        }
                        group.addTask {
                            do {
                                while true {
                                    try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                                    try Task.checkCancellation()

                                    if lastLog.silenceSeconds() > Double(watchdogSeconds) {
                                        throw LearnedMatchingWatchdogError(seconds: watchdogSeconds)
                                    }
                                }
                            } catch is CancellationError {
                                return
                            }
                        }

                        do {
                            _ = try await group.next()
                            group.cancelAll()
                            while let _ = try await group.next() {}
                        } catch {
                            group.cancelAll()
                            throw error
                        }
                    }

                    guard learnedOutputsExist(paths: paths) else {
                        throw PipelineError.outputMissing
                    }

                    emit(.stageFinished(stage: .sfmFeatures))
                    markStageComplete(.sfmFeatures)

                    currentStage = .sfmMatching
                    emit(.stageStarted(stage: .sfmMatching))
                    emit(.stageFinished(stage: .sfmMatching))
                    markStageComplete(.sfmMatching)
                    learnedMatchingCompleted = true
                } catch {
                    if let stalled = error as? LearnedMatchingWatchdogError {
                        emit(.stageLog(
                            stage: .sfmFeatures,
                            line: "Learned matching produced no output for \(stalled.seconds)s; falling back to COLMAP.",
                            isError: true
                        ))
                    } else {
                        emit(.stageLog(
                            stage: .sfmFeatures,
                            line: "Learned matching failed; falling back to COLMAP. \(error)",
                            isError: true
                        ))
                    }
                    learnedMatchingCompleted = false
                }
            }
            let runFeatures: (Bool) async throws -> Void = { force in
                guard !learnedMatchingCompleted else { return }
                guard force || shouldRunStage(.sfmFeatures) else { return }
                currentStage = .sfmFeatures
                emit(.stageStarted(stage: .sfmFeatures))
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
                    if Self.shouldEmitToolLogLine(line, isError: isErr) {
                        emit(.stageLog(stage: .sfmFeatures, line: line, isError: isErr))
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
                emit(.stageFinished(stage: .sfmFeatures))
                markStageComplete(.sfmFeatures)
            }

            let runMatching: (Bool) async throws -> Void = { force in
                guard !learnedMatchingCompleted else { return }
                guard force || shouldRunStage(.sfmMatching) else { return }
                currentStage = .sfmMatching
                emit(.stageStarted(stage: .sfmMatching))
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
                        if Self.shouldEmitToolLogLine(line, isError: isErr) {
                            emit(.stageLog(stage: .sfmMatching, line: line, isError: isErr))
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
                                        if Self.shouldEmitToolLogLine(line, isError: isErr) {
                                            emit(.stageLog(stage: .sfmMatching, line: line, isError: isErr))
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
                if shouldRunStage(.sfmMapping) {
                    currentStage = .sfmMapping
                    emit(.stageStarted(stage: .sfmMapping))
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
                            if Self.shouldEmitToolLogLine(line, isError: isErr) {
                                emit(.stageLog(stage: .sfmMapping, line: line, isError: isErr))
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

                        if !mappingSucceeded, learnedMatchingCompleted {
                            emit(.stageLog(stage: .sfmMapping, line: "Learned matching did not yield a stable reconstruction. Retrying with COLMAP matching.", isError: true))
                            emit(.stageFinished(stage: .sfmMapping))
                            self.removeIfExists(paths.sfmLearnedURL)
                            learnedMatchingCompleted = false
                            forceSfMRun = true
                            continue sfmAttemptLoop
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
                        emit(.stageFinished(stage: .sfmMapping))
                        markStageComplete(.sfmMapping)
                }

                break
            }
            }

            try Task.checkCancellation()
            if shouldRunStage(.trainBrush) {
                currentStage = .trainBrush
                emit(.stageStarted(stage: .trainBrush))
                let brushPlan = brushTrainingPlan(for: metadata.preset)
                if let totalSteps = brushPlan.totalSteps {
                    emit(.stageLog(
                        stage: .trainBrush,
                        line: "Training target: \(formatStepCount(totalSteps)) steps",
                        isError: false
                    ))
                }
                if let exportEvery = brushPlan.exportEvery {
                    emit(.stageLog(
                        stage: .trainBrush,
                        line: "Preview updates every \(formatStepCount(exportEvery)) steps",
                        isError: false
                    ))
                }
                let datasetPrepWeight = 0.20
                let datasetURL = try prepareBrushDataset(paths: paths, progress: { fraction, message in
                    // Keep overall stage progress monotonic: dataset prep is the first slice.
                    emit(.stageProgress(stage: .trainBrush, fraction: datasetPrepWeight * fraction, message: message))
                })
                let trainingStartedAt = Date()
                let initialStatus = trainingStatusMessage(
                    elapsed: 0,
                    progress: nil,
                    latestExportStep: nil,
                    totalSteps: brushPlan.totalSteps
                )
                emit(.stageProgress(stage: .trainBrush, fraction: -1.0, message: initialStatus))
                emit(.stageLog(stage: .trainBrush, line: "Running Brush training...", isError: false))

                let brushToolLog = ToolLogWriter(fileURL: paths.brushLogURL, toolName: "brush")
                brushToolLog.beginSection(
                    title: "train",
                    metadata: [
                        "dataset": datasetURL.path,
                        "tool": self.config.toolchain.brush.path
                    ]
                )
                emit(.stageLog(stage: .trainBrush, line: "Brush tool log: \(paths.brushLogURL.lastPathComponent)", isError: false))

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

                let brushProgress = BrushProgressBox()

                let monitorTask = Task { [trainingURL = paths.trainingURL, brushProgress] in
                    var lastSeen: String? = nil
                    var latestExportStep: Int? = nil
                    var lastEmittedStep: Int? = nil
                    var lastEmittedTotal: Int? = nil
                    var lastEmittedExportStep: Int? = nil
                    var lastStatusAt = Date.distantPast
                    var lastExportCheckAt = Date.distantPast
                    let statusInterval: TimeInterval = 1.0
                    let exportCheckInterval: TimeInterval = 5.0
                    while !Task.isCancelled {
                        let now = Date()
                        if now.timeIntervalSince(lastExportCheckAt) >= exportCheckInterval {
                            lastExportCheckAt = now
                            if let export = latestBrushExport(in: trainingURL) {
                                let name = export.file.lastPathComponent
                                if name != lastSeen {
                                    lastSeen = name
                                    if let step = export.step {
                                        latestExportStep = step
                                        emit(.stageLog(
                                            stage: .trainBrush,
                                            line: "Saved a preview at \(formatStepCount(step)) steps",
                                            isError: false
                                        ))
                                    } else {
                                        emit(.stageLog(stage: .trainBrush, line: "Saved a preview model", isError: false))
                                    }
                                }
                            }
                        }
                        if now.timeIntervalSince(lastStatusAt) >= statusInterval {
                            lastStatusAt = now
                            let elapsed = now.timeIntervalSince(trainingStartedAt)
                            let progress = brushProgress.latestProgress()
                            let shouldEmit: Bool = {
                                if let progress {
                                    return progress.step != lastEmittedStep
                                        || progress.total != lastEmittedTotal
                                        || latestExportStep != lastEmittedExportStep
                                }
                                return latestExportStep != lastEmittedExportStep
                            }()
                            if shouldEmit {
                                if let progress {
                                    lastEmittedStep = progress.step
                                    lastEmittedTotal = progress.total
                                }
                                lastEmittedExportStep = latestExportStep
                                let fraction: Double = {
                                    guard let progress else { return -1.0 }
                                    let f = Double(progress.step) / Double(progress.total)
                                    let weighted = datasetPrepWeight + (1.0 - datasetPrepWeight) * f
                                    return min(0.99, max(0.0, weighted))
                                }()
                                let status = trainingStatusMessage(
                                    elapsed: elapsed,
                                    progress: progress,
                                    latestExportStep: latestExportStep,
                                    totalSteps: brushPlan.totalSteps
                                )
                                emit(.stageProgress(stage: .trainBrush, fraction: fraction, message: status))
                            }
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                defer { monitorTask.cancel() }

                try await self.tooling.brush.runTrain(
                    brushPath: self.config.toolchain.brush,
                    datasetPath: datasetURL,
                    totalSteps: brushPlan.totalSteps,
                    exportEvery: brushPlan.exportEvery,
                    onLog: { line, isErr in
                        brushToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)

                        if let progress = self.brushTrainStepProgress(from: line),
                           progress.total > 0,
                           progress.step >= 0,
                           progress.step <= progress.total {
                            brushProgress.update(step: progress.step, total: progress.total)
                        }

                        if Self.shouldEmitToolLogLine(line, isError: isErr) {
                            emit(.stageLog(stage: .trainBrush, line: line, isError: isErr))
                        }
                    }
                )
                emit(.stageFinished(stage: .trainBrush))
                markStageComplete(.trainBrush)
            }

            try Task.checkCancellation()
            if shouldRunStage(.exportSplat) {
                currentStage = .exportSplat
                emit(.stageStarted(stage: .exportSplat))
                guard let ply = self.tooling.brush.findLatestPly(in: paths.trainingURL) else {
                    throw PipelineError.outputMissing
                }
                try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
                let outputPly = paths.outputURL.appendingPathComponent("splat.ply")
                try SplatExport.copyIfExists(from: ply, to: outputPly)
                emit(.stageFinished(stage: .exportSplat))
                markStageComplete(.exportSplat)
            }

            metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
            metadata.state = PipelineState(stage: .done, attempt: metadata.state.attempt, lastError: nil, resumeToken: nil)
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

    struct TimeoutError: Error {}

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

    func frameGroups(from manifest: [SelectedFrameMapping], allowedNames: Set<String>) -> [FrameGroup] {
        var order: [String] = []
        var framesByGroup: [String: [String]] = [:]
        var isVideoByGroup: [String: Bool] = [:]
        for entry in manifest {
            guard allowedNames.contains(entry.outputFileName) else { continue }
            if framesByGroup[entry.groupId] == nil {
                order.append(entry.groupId)
            }
            framesByGroup[entry.groupId, default: []].append(entry.outputFileName)
            isVideoByGroup[entry.groupId] = entry.isVideo
        }
        return order.compactMap { groupId in
            guard let files = framesByGroup[groupId], !files.isEmpty else { return nil }
            return FrameGroup(id: groupId, fileNames: files, isVideo: isVideoByGroup[groupId] ?? false)
        }
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

    private func sfmMapperPreference() -> SfmMapperPreference {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_SFM_MAPPER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "colmap" { return .colmap }
            if value == "glomap" { return .glomap }
        }
        return .glomap
    }

    func sfmBackendPolicy() -> SfmBackend {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_SFM_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "colmap" { return .colmap }
            if value == "vggt" || value == "vggt-mps" { return .vggt }
            if value == "learned" { return .learned }
        }
        return .vggt
    }

    func learnedOutputsExist(paths: ProjectPaths) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.colmapDatabaseURL.path) else { return false }
        guard fm.fileExists(atPath: paths.sfmLearnedMatchListURL.path) else { return false }
        guard fm.fileExists(atPath: paths.sfmLearnedFeaturesURL.path) else { return false }
        let contents = (try? fm.contentsOfDirectory(at: paths.sfmLearnedFeaturesURL, includingPropertiesForKeys: nil)) ?? []
        return !contents.isEmpty
    }

    func learnedDevicePreference() -> String {
        let env = ProcessInfo.processInfo.environment
        if let value = env["EASYSPLAT_LEARNED_DEVICE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "mps"
    }

    func learnedMaxImageSizePreference(colmapMaxImageSize: Int, preset: PresetSpec) -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_LEARNED_MAX_IMAGE_SIZE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        if preset.quality == .ultra {
            return colmapMaxImageSize
        }
        return min(colmapMaxImageSize, 1024)
    }

    func learnedWatchdogSeconds() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_LEARNED_WATCHDOG_SECONDS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 600
    }

    func learnedMpsProbeTimeoutSeconds() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_LEARNED_MPS_PROBE_TIMEOUT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 60
    }

    func runWithTimeout<T: Sendable>(seconds: Int, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let timeoutNanos = UInt64(max(1, seconds)) * 1_000_000_000
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw TimeoutError()
            }
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    func learnedPairBridgeCount(overlap: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["EASYSPLAT_LEARNED_PAIR_BRIDGE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override >= 0 {
            return override
        }
        return min(3, max(0, overlap))
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

    func shouldUseColmapGpu(colmapPath: URL) -> Bool {
        if let override = colmapGpuOverride() {
            return override
        }
        return detectColmapGpuSupport(colmapPath: colmapPath)
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
            self.removeIfExists(paths.sfmPairListURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.sfmLearnedURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .selectFrames:
            self.removeIfExists(paths.framesSelectedURL)
            self.removeIfExists(paths.framesSelectedManifestURL)
            self.removeIfExists(paths.sfmPairListURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.sfmLearnedURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .sfmFeatures, .sfmMatching:
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.sfmLearnedURL)
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
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func targetCountForVideo(index: Int, total: Int, targetCount: Int) -> Int {
        guard total > 0 else { return targetCount }
        let base = targetCount / total
        let remainder = targetCount % total
        return base + (index < remainder ? 1 : 0)
    }

    func isStageComplete(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) -> Bool {
        let fm = FileManager.default
        switch stage {
        case .importInput:
            var ok = true
            for file in metadata.input.videoFiles {
                let name = URL(fileURLWithPath: file).lastPathComponent
                let dest = paths.originalsURL.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) { ok = false }
            }
            if let photosFolder = metadata.input.photosFolder {
                let name = URL(fileURLWithPath: photosFolder).lastPathComponent
                let dest = paths.originalsURL.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) { ok = false }
            }
            return ok && (!metadata.input.videoFiles.isEmpty || metadata.input.photosFolder != nil)
        case .extractFrames:
            guard metadata.input.hasVideos else { return true }
            for index in metadata.input.videoFiles.indices {
                let profile = frameExtractionProfile(for: metadata.preset.quality)
                let perVideoTarget = targetCountForVideo(index: index, total: metadata.input.videoFiles.count, targetCount: profile.targetCount)
                if perVideoTarget == 0 { continue }
                let rawDir = rawFramesDirectory(index: index, paths: paths)
                if !fm.fileExists(atPath: rawDir.path) { return false }
            }
            return true
        case .selectFrames:
            guard fm.fileExists(atPath: paths.framesSelectedURL.path) else { return false }
            let contents = (try? fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)) ?? []
            return !contents.isEmpty
        case .sfmFeatures:
            return fm.fileExists(atPath: paths.colmapDatabaseURL.path)
        case .sfmMatching:
            return fm.fileExists(atPath: paths.colmapDatabaseURL.path)
        case .sfmMapping:
            let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
            return sparseModelFilesExist(at: sparseZero)
        case .trainBrush:
            return tooling.brush.findLatestPly(in: paths.trainingURL) != nil
        case .exportSplat, .done:
            let output = paths.outputURL.appendingPathComponent("splat.ply")
            return fm.fileExists(atPath: output.path)
        }
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

    func latestBrushExport(in trainingURL: URL) -> (file: URL, step: Int?)? {
        let fm = FileManager.default
        let exportsDir = trainingURL.appendingPathComponent("dataset_exports", isDirectory: true)

        if fm.fileExists(atPath: exportsDir.path) {
            if let export = latestBrushExportInDirectory(exportsDir) {
                return export
            }
        }

        // Fallback: search recursively in case Brush is configured with a different export path.
        let enumerator = fm.enumerator(at: trainingURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var latest: (URL, Date)?
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "ply" else { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if latest == nil || date > latest!.1 {
                latest = (item, date)
            }
        }
        guard let latest else { return nil }
        return (file: latest.0, step: brushExportStep(from: latest.0))
    }

    private func latestBrushExportInDirectory(_ directory: URL) -> (file: URL, step: Int?)? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []

        // Prefer the highest parsed step (export_05000.ply, export_10000.ply, ...).
        var bestStep: (Int, URL)?
        var bestDate: (Date, URL)?
        for file in files where file.pathExtension.lowercased() == "ply" {
            if let step = brushExportStep(from: file) {
                if bestStep == nil || step > bestStep!.0 {
                    bestStep = (step, file)
                }
                continue
            }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if bestDate == nil || date > bestDate!.0 {
                bestDate = (date, file)
            }
        }

        if let bestStep {
            return (file: bestStep.1, step: bestStep.0)
        }
        if let bestDate {
            return (file: bestDate.1, step: nil)
        }
        return nil
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
        totalSteps: Int?
    ) -> String {
        let elapsedText = formatElapsed(elapsed)
        if let progress, progress.total > 0 {
            let stepText = formatStepCount(progress.step)
            let totalText = formatStepCount(progress.total)
            return "Training model - \(stepText)/\(totalText) steps (running \(elapsedText))"
        }
        if let totalSteps {
            let fallbackStep = max(0, latestExportStep ?? 0)
            let clamped = min(fallbackStep, totalSteps)
            let stepText = formatStepCount(clamped)
            let totalText = formatStepCount(totalSteps)
            return "Training model - \(stepText)/\(totalText) steps (running \(elapsedText))"
        }
        if let latestExportStep {
            let stepText = formatStepCount(latestExportStep)
            return "Training model - \(stepText) steps (running \(elapsedText))"
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

    private static func shouldEmitToolLogLine(_ line: String, isError: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isError {
            return true
        }
        if trimmed.hasPrefix("EasySplat:") {
            return true
        }
        let lower = trimmed.lowercased()
        if lower.contains("warning") || lower.contains("warn") {
            return true
        }
        if lower.contains("error") || lower.contains("fatal") || lower.contains("failed") {
            return true
        }
        return false
    }

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

struct TestFrameGroup: Sendable {
    let id: String
    let fileNames: [String]
    let isVideo: Bool
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

extension PipelineRunner {
    func loadImagesForTesting(in directory: URL) throws -> [URL] {
        try loadImages(in: directory)
    }

    func test_downsampleFrames(_ frames: [URL], targetCount: Int) -> [URL] {
        downsampleFrames(frames, targetCount: targetCount)
    }

    func test_downsampleSelectedFrames(to targetCount: Int, paths: ProjectPaths) throws -> [URL]? {
        try downsampleSelectedFrames(to: targetCount, paths: paths)
    }

    func test_frameGroups(from manifest: [TestSelectedFrameMapping], allowedNames: Set<String>) -> [TestFrameGroup] {
        let internalManifest = manifest.map { SelectedFrameMapping(
            outputFileName: $0.outputFileName,
            groupId: $0.groupId,
            isVideo: $0.isVideo,
            sourcePath: $0.sourcePath
        ) }
        return frameGroups(from: internalManifest, allowedNames: allowedNames).map {
            TestFrameGroup(id: $0.id, fileNames: $0.fileNames, isVideo: $0.isVideo)
        }
    }

    func test_normalizeSelectedImagesForTooling(paths: ProjectPaths) throws -> Int {
        try normalizeSelectedImagesForTooling(paths: paths)
    }

    func test_targetCountForVideo(index: Int, total: Int, targetCount: Int) -> Int {
        targetCountForVideo(index: index, total: total, targetCount: targetCount)
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

    func test_latestBrushExport(in trainingURL: URL) -> (file: URL, step: Int?)? {
        latestBrushExport(in: trainingURL)
    }

    func test_brushTrainStepProgress(from line: String) -> TestBrushTrainProgress? {
        guard let progress = brushTrainStepProgress(from: line) else { return nil }
        return TestBrushTrainProgress(step: progress.step, total: progress.total)
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
        totalSteps: Int?
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
            totalSteps: totalSteps
        )
    }

    func test_shouldEmitToolLogLine(_ line: String, isError: Bool) -> Bool {
        Self.shouldEmitToolLogLine(line, isError: isError)
    }

    func test_colmapGpuOverride() -> Bool? {
        colmapGpuOverride()
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
