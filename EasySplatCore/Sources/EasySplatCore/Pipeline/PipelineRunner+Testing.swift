import Foundation

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
    let maxExtractedFrames: Int?
}

struct TestBrushTrainProgress: Sendable {
    let step: Int
    let total: Int
}

struct TestBrushTrainingPlan: Sendable {
    let totalSteps: Int?
    let exportEvery: Int?
}

struct TestColmapSpeedProfile: Sendable {
    let maxImageSize: Int
    let extractSequentialOverlap: Int
    let matchSequentialOverlap: Int
    let maxNumFeatures: Int?
    let maxNumMatches: Int?
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

    func test_applyFrameBudget(to groups: [SelectedFrameGroup], targetCount: Int) -> [SelectedFrameGroup] {
        applyFrameBudget(to: groups, targetCount: targetCount)
    }

    func test_normalizeSelectedImagesForTooling(paths: ProjectPaths) throws -> Int {
        try normalizeSelectedImagesForTooling(paths: paths)
    }

    func test_targetCountForVideo(index: Int, total: Int, targetCount: Int) -> Int {
        targetCountForVideo(index: index, total: total, targetCount: targetCount)
    }

    func test_resolveSparseModelDirectory(_ candidate: URL) throws -> URL {
        try resolveSparseModelDirectory(at: candidate)
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
            outputFormat: .jpeg,
            maxExtractedFrames: nil
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
            outputFormat: profile.outputFormat,
            maxExtractedFrames: profile.maxExtractedFrames
        )
    }

    func test_applySpeedProfileToColmap(
        maxImageSize: Int,
        extractSequentialOverlap: Int,
        matchSequentialOverlap: Int
    ) -> TestColmapSpeedProfile {
        var imageSize = maxImageSize
        var extract = colmapOptionsForExtraction()
        var match = colmapOptionsForMatching()
        extract.sequentialOverlap = extractSequentialOverlap
        match.sequentialOverlap = matchSequentialOverlap
        applySpeedProfileIfNeeded(
            colmapMaxImageSize: &imageSize,
            colmapExtractOptions: &extract,
            colmapMatchOptions: &match
        )
        return TestColmapSpeedProfile(
            maxImageSize: imageSize,
            extractSequentialOverlap: extract.sequentialOverlap,
            matchSequentialOverlap: match.sequentialOverlap,
            maxNumFeatures: extract.maxNumFeatures,
            maxNumMatches: match.maxNumMatches
        )
    }

    func test_shouldUseBrushInsteadOfAutomaticMsplat(for score: ReconstructionScore?) -> Bool {
        shouldUseBrushInsteadOfAutomaticMsplat(for: score)
    }

    static func test_reconstructionScore(fromPersistedSummary summary: ReconstructionSummary) -> ReconstructionScore {
        return reconstructionScore(fromPersistedSummary: summary)
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

    func test_latestTrainingExport(
        in trainingURL: URL,
        backend: TrainingBackend,
        minModificationDate: Date? = nil
    ) -> URL? {
        latestTrainingExport(in: trainingURL, backend: backend, minModificationDate: minModificationDate)
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

    func test_trainingBackendPreference() -> String {
        trainingBackendPreference().rawValue
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

    func test_normalizedToolLogIsError(_ line: String, isError: Bool) -> Bool {
        Self.normalizedToolLogIsError(line, isError: isError)
    }

    func test_colmapGpuOverride() -> Bool? {
        colmapGpuOverride()
    }

    func test_colmapSequentialOverlapOverride() -> Int? {
        colmapSequentialOverlapOverride()
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
                mapAnythingResolution: 518,
                mapAnythingDirectViewLimit: 0,
                mapAnythingAnchorMaxViews: 0,
                mapAnythingWindowSize: 0,
                mapAnythingWindowOverlap: 0,
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

    func test_mapAnythingExecutionPlan(
        hardwareTier: HardwareProfile.Tier,
        selectedFrameCount: Int,
        preset: PresetSpec,
        input: InputSpec = .photos(folder: "/tmp"),
        autoTune: AutoTuneProfile? = nil,
        explicitlyRequested: Bool = false
    ) -> (
        mode: String,
        directAllowed: Bool,
        directViewLimit: Int,
        resolution: Int,
        memoryEfficientInference: Bool,
        useAMP: Bool,
        anchorMaxViews: Int,
        windowSize: Int,
        windowOverlap: Int,
        cameraType: String,
        sharedCamera: Bool
    ) {
        let memoryGB: Double
        switch hardwareTier {
        case .low:
            memoryGB = 16
        case .mid:
            memoryGB = 24
        case .high:
            memoryGB = 48
        }
        let hardwareProfile = HardwareProfile(memoryGB: memoryGB, cpuCount: 8, gpuWorkingSetGB: 8)
        let plan = mapAnythingExecutionPlan(
            hardwareProfile: hardwareProfile,
            input: input,
            selectedFrameCount: selectedFrameCount,
            preset: preset,
            autoTune: autoTune,
            explicitlyRequested: explicitlyRequested
        )
        return (
            mode: plan.mode.rawValue,
            directAllowed: plan.directAllowed,
            directViewLimit: plan.directViewLimit,
            resolution: plan.resolution,
            memoryEfficientInference: plan.memoryEfficientInference,
            useAMP: plan.useAMP,
            anchorMaxViews: plan.anchorMaxViews,
            windowSize: plan.windowSize,
            windowOverlap: plan.windowOverlap,
            cameraType: plan.cameraType,
            sharedCamera: plan.sharedCamera
        )
    }

    func test_mapAnythingSharedCameraPreference(input: InputSpec) -> Bool {
        mapAnythingSharedCameraPreference(input: input)
    }

    func test_da3ResolvedInputOrdering(requested: InputOrdering, input: InputSpec) -> InputOrdering {
        da3ResolvedInputOrdering(requested: requested, input: input)
    }

    func test_mapAnythingResolutionPreference() -> Int {
        mapAnythingResolutionPreference()
    }

    func test_mapAnythingDirectMinimumMeanTrackLengthPreference(mode: CaptureMode) -> Double {
        mapAnythingDirectMinimumMeanTrackLengthPreference(mode: mode)
    }

    func test_da3DirectMinimumMeanTrackLengthPreference(mode: CaptureMode) -> Double {
        da3DirectMinimumMeanTrackLengthPreference(mode: mode)
    }

    func test_da3DirectQualityFailureReason(
        score: ReconstructionScore,
        mode: CaptureMode
    ) -> String? {
        da3DirectQualityFailureReason(score: score, mode: mode)
    }

    func test_mapAnythingDirectQualityFailureReason(
        score: ReconstructionScore,
        mode: CaptureMode
    ) -> String? {
        mapAnythingDirectQualityFailureReason(score: score, mode: mode)
    }

    func test_vggtDirectQualityFailureReason(
        score: ReconstructionScore,
        selectedFrameCount: Int,
        mode: CaptureMode,
        maxPoints: Int? = nil
    ) -> String? {
        vggtDirectQualityFailureReason(
            score: score,
            selectedFrameCount: selectedFrameCount,
            mode: mode,
            maxPoints: maxPoints
        )
    }

    func test_sfmMapperPreference() -> String {
        sfmMapperPreference().rawValue
    }

    func test_globalMapperOptions(threadHint: Int, defaultUseGpu: Bool = true) -> ColmapGlobalMapperOptions {
        globalMapperOptions(threadHint: threadHint, defaultUseGpu: defaultUseGpu)
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
                mapAnythingResolution: 518,
                mapAnythingDirectViewLimit: 0,
                mapAnythingAnchorMaxViews: 0,
                mapAnythingWindowSize: 0,
                mapAnythingWindowOverlap: 0,
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
                mapAnythingResolution: 518,
                mapAnythingDirectViewLimit: 0,
                mapAnythingAnchorMaxViews: 0,
                mapAnythingWindowSize: 0,
                mapAnythingWindowOverlap: 0,
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

    func test_makePipelineErrorLowQuality(_ score: ReconstructionScore, mapper: String? = nil) -> Error {
        return PipelineError.lowQualityReconstruction(score, mapper: mapper)
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
