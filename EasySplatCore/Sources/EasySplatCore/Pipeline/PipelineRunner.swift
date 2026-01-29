import Foundation

public final class PipelineRunner: @unchecked Sendable {
    public struct Tooling {
        public var colmap: ColmapRunner
        public var glomap: GlomapRunner
        public var brush: BrushRunner

        public init(colmap: ColmapRunner = ColmapRunner(),
                    glomap: GlomapRunner = GlomapRunner(),
                    brush: BrushRunner = BrushRunner()) {
            self.colmap = colmap
            self.glomap = glomap
            self.brush = brush
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.glomap = GlomapRunner(runner: runner)
            self.brush = BrushRunner(runner: runner)
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
                try importInputs(metadata: metadata, paths: paths)
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
                        let rawDir = rawFramesDirectory(index: index, paths: paths)
                        try self.resetDirectory(rawDir)
                        _ = try await extractor.extractFrames(
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
                    let selector = FrameSelector()
                    var candidates: [URL] = []

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
                            candidates.append(contentsOf: chosen)
                        }
                    }

                    if let photosFolder = metadata.input.photosFolder {
                        let sourceFolder = paths.originalsURL.appendingPathComponent(URL(fileURLWithPath: photosFolder).lastPathComponent, isDirectory: true)
                        let photos = try loadPhotos(in: sourceFolder)
                        candidates.append(contentsOf: photos)
                    }

                    selectedFrames = try copySelected(candidates, to: paths.framesSelectedURL)
                    emit(.stageFinished(stage: .selectFrames))
                    markStageComplete(.selectFrames)
                }
            }

            selectedFrames = try loadImages(in: paths.framesSelectedURL)
            if selectedFrames.isEmpty {
                throw PipelineError.invalidInput
            }

            try Task.checkCancellation()
            let runFeatures: (Bool) async throws -> Void = { force in
                guard force || shouldRunStage(.sfmFeatures) else { return }
                currentStage = .sfmFeatures
                emit(.stageStarted(stage: .sfmFeatures))
                let featureProgress = ColmapFeatureProgressTracker()
                let onFeaturesLog: @Sendable (String, Bool) -> Void = { line, isErr in
                    emit(.stageLog(stage: .sfmFeatures, line: line, isError: isErr))
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
                guard force || shouldRunStage(.sfmMatching) else { return }
                currentStage = .sfmMatching
                emit(.stageStarted(stage: .sfmMatching))
                emit(.stageLog(
                    stage: .sfmMatching,
                    line: colmapMatchOptions.useGPU ? "Using GPU for COLMAP matching." : "Using CPU for COLMAP matching.",
                    isError: false
                ))
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
                        emit(.stageLog(stage: .sfmMatching, line: line, isError: isErr))
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
                                    onLog: { line, isErr in emit(.stageLog(stage: .sfmMatching, line: line, isError: isErr)) }
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
                    let mappingProgress = ColmapMappingProgressTracker(totalImages: selectedFrames.count)
                    let onMappingLog: @Sendable (String, Bool) -> Void = { line, isErr in
                        emit(.stageLog(stage: .sfmMapping, line: line, isError: isErr))
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
                                    onLog: onMappingLog
                                )
                            } else {
                                try await self.tooling.colmap.runMapper(
                                    colmapPath: self.config.toolchain.colmap,
                                    database: paths.colmapDatabaseURL,
                                    imagePath: paths.framesSelectedURL,
                                    outputPath: paths.colmapSparseURL,
                                    options: colmapMatchOptions,
                                    onLog: onMappingLog
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

            try Task.checkCancellation()
            if shouldRunStage(.trainBrush) {
                currentStage = .trainBrush
                emit(.stageStarted(stage: .trainBrush))
                let datasetURL = try prepareBrushDataset(paths: paths)
                try await self.tooling.brush.runTrain(
                    brushPath: self.config.toolchain.brush,
                    datasetPath: datasetURL,
                    onLog: { line, isErr in emit(.stageLog(stage: .trainBrush, line: line, isError: isErr)) }
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
        case outputMissing
    }

    var supportedImageExtensions: Set<String> {
        ["jpg", "jpeg", "png", "heic"]
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
        _ = try copySelected(reduced, to: tempSelected)
        self.removeIfExists(paths.framesSelectedURL)
        try FileManager.default.moveItem(at: tempSelected, to: paths.framesSelectedURL)
        return try loadImages(in: paths.framesSelectedURL)
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
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .selectFrames:
            self.removeIfExists(paths.framesSelectedURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .sfmFeatures, .sfmMatching:
            self.removeIfExists(paths.colmapDatabaseURL)
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

    func importInputs(metadata: ProjectMetadata, paths: ProjectPaths) throws {
        let fm = FileManager.default
        switch metadata.input {
        case .video(let files):
            for file in files {
                let source = URL(fileURLWithPath: file)
                let dest = paths.originalsURL.appendingPathComponent(source.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: source, to: dest)
                }
            }
        case .photos(let folder):
            let sourceFolder = URL(fileURLWithPath: folder)
            let dest = paths.originalsURL.appendingPathComponent(sourceFolder.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: sourceFolder, to: dest)
            }
        case .mixed(let videos, let photosFolder):
            for file in videos {
                let source = URL(fileURLWithPath: file)
                let dest = paths.originalsURL.appendingPathComponent(source.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: source, to: dest)
                }
            }
            let sourceFolder = URL(fileURLWithPath: photosFolder)
            let dest = paths.originalsURL.appendingPathComponent(sourceFolder.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: sourceFolder, to: dest)
            }
        }
    }

    func copySelected(_ frames: [URL], to directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var output: [URL] = []
        for (index, url) in frames.enumerated() {
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let dest = directory.appendingPathComponent(String(format: "frame_%06d.%@", index, ext))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
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
        if selectedFrames.count < 30 { return false }
        return true
    }

    func prepareBrushDataset(paths: ProjectPaths) throws -> URL {
        let fm = FileManager.default
        let dataset = paths.trainingURL.appendingPathComponent("dataset", isDirectory: true)
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try resetDirectory(images)
        try resetDirectory(sparse)

        let selected = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
        let imageFiles = selected.filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageFiles.isEmpty else { throw PipelineError.invalidInput }
        for url in imageFiles {
            let dest = images.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
        }

        let sourceSparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        guard sparseModelFilesExist(at: sourceSparse) else { throw PipelineError.outputMissing }
        let files = try fm.contentsOfDirectory(at: sourceSparse, includingPropertiesForKeys: nil)
        for file in files {
            let dest = sparse.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
        }
        return dataset
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

private final class PipelineLogger: @unchecked Sendable {
    private let eventsURL: URL
    private let logURL: URL
    private let emit: @Sendable (PipelineEvent) -> Void
    private let encoder: JSONEncoder
    private let logHandle: FileHandle?
    private let eventsHandle: FileHandle?
    private let lock = NSLock()

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
        if case let .stageLog(_, line, isError) = event {
            appendLogLine(line, isError: isError)
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

    private func appendLogLine(_ line: String, isError: Bool) {
        guard let handle = logHandle else { return }
        let prefix = isError ? "[err] " : ""
        if let data = "\(prefix)\(line)\n".data(using: .utf8) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }
}

#if DEBUG
extension PipelineRunner {
    func loadImagesForTesting(in directory: URL) throws -> [URL] {
        try loadImages(in: directory)
    }
}
#endif
