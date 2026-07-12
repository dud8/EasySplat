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

    func test_shouldUseSequential(selectedFrames: [URL], input: InputSpec, forceExhaustive: Bool) -> Bool {
        shouldUseSequential(selectedFrames: selectedFrames, input: input, forceExhaustive: forceExhaustive)
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

    func test_sfmBackendPolicy() -> SfmBackend {
        sfmBackendPolicy()
    }

    func test_sfmBackendFallbackOrder() -> [SfmBackend] {
        sfmBackendFallbackOrder(override: sfmBackendOverride())
    }

    func test_da3ResolvedInputOrdering(requested: InputOrdering, input: InputSpec) -> InputOrdering {
        da3ResolvedInputOrdering(requested: requested, input: input)
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

    func test_sfmMapperPreference() -> String {
        sfmMapperPreference().rawValue
    }

    func test_globalMapperOptions(threadHint: Int, defaultUseGpu: Bool = true) -> ColmapGlobalMapperOptions {
        globalMapperOptions(threadHint: threadHint, defaultUseGpu: defaultUseGpu)
    }

    func test_colmapErrorIndicatesGpuFailure(_ error: ColmapRunnerError) -> Bool {
        colmapErrorIndicatesGpuFailure(error)
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
