import Foundation

#if DEBUG
struct TestSelectedFrameMapping: Codable, Sendable {
    let outputFileName: String
    let groupId: String
    let isVideo: Bool
    let timestampSeconds: Double?
    let lowLightExposureEV: Double?

    init(
        outputFileName: String,
        groupId: String,
        isVideo: Bool,
        timestampSeconds: Double? = nil,
        lowLightExposureEV: Double? = nil
    ) {
        self.outputFileName = outputFileName
        self.groupId = groupId
        self.isVideo = isVideo
        self.timestampSeconds = timestampSeconds
        self.lowLightExposureEV = lowLightExposureEV
    }
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

    func test_applyFrameBudget(to groups: [SelectedFrameGroup], targetCount: Int) throws -> [SelectedFrameGroup] {
        try applyFrameBudget(to: groups, targetCount: targetCount)
    }

    func test_applyFrameBudget(
        to groups: [SelectedFrameGroup],
        targetCount: Int,
        photoSelection: PhotoSelection
    ) throws -> [SelectedFrameGroup] {
        try applyFrameBudget(
            to: groups,
            targetCount: targetCount,
            photoSelection: photoSelection
        )
    }

    func test_copySelected(
        groups: [SelectedFrameGroup],
        to directory: URL,
        manifestURL: URL,
        maxDimension: CGFloat = .greatestFiniteMagnitude
    ) throws -> [TestSelectedFrameMapping] {
        let result = try copySelected(
            groups: groups,
            to: directory,
            manifestURL: manifestURL,
            maxDimension: maxDimension
        )
        return result.manifest.map {
            TestSelectedFrameMapping(
                outputFileName: $0.outputFileName,
                groupId: $0.groupId,
                isVideo: $0.isVideo,
                timestampSeconds: $0.timestampSeconds,
                lowLightExposureEV: $0.lowLightExposureEV
            )
        }
    }

    func test_filterValidUniquePhotos(
        _ photos: [URL]
    ) throws -> (frames: [URL], unreadableCount: Int, duplicateCount: Int) {
        let result = try filterValidUniquePhotos(photos)
        return (result.frames, result.unreadableCount, result.duplicateCount)
    }

    func test_normalizeSelectedImagesForTooling(paths: ProjectPaths) throws -> Int {
        try normalizeSelectedImagesForTooling(paths: paths)
    }

    func test_selectedImagesHaveUniformPixelDimensions(_ images: [URL]) throws -> Bool {
        try selectedImagesHaveUniformPixelDimensions(images)
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

    func test_shouldUseSequential(selectedFrames: [URL], input: InputSpec, forceExhaustive: Bool) -> Bool {
        shouldUseSequential(selectedFrames: selectedFrames, input: input, forceExhaustive: forceExhaustive)
    }

    func test_shouldEmitToolLogLine(_ line: String, isError: Bool) -> Bool {
        Self.shouldEmitToolLogLine(line, isError: isError)
    }

    func test_normalizedToolLogIsError(_ line: String, isError: Bool) -> Bool {
        Self.normalizedToolLogIsError(line, isError: isError)
    }

    func test_da3SharedCameraPreference(
        input: InputSpec,
        cameraGrouping: CameraGrouping
    ) -> Bool {
        da3SharedCameraPreference(input: input, cameraGrouping: cameraGrouping)
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

    func test_persistResolvedPlanChange(
        _ resolvedPlan: ResolvedRunPlan,
        completedBoundary: PipelineStage?,
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        try persistResolvedPlanChange(
            resolvedPlan,
            completedBoundary: completedBoundary,
            metadata: &metadata,
            paths: paths
        )
    }

    func test_runDa3MatchesImporterWithOneShotExactRecovery(
        database: URL,
        matchListPath: URL,
        options: ColmapOptions,
        onExactRecovery: () -> Void
    ) async throws {
        try await runDa3MatchesImporterWithOneShotExactRecovery(
            database: database,
            matchListPath: matchListPath,
            options: options,
            onLog: { _, _ in },
            emit: { _ in },
            onExactRecovery: onExactRecovery
        )
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

    func test_makePipelineErrorPhotoSelectionExceedsBudget(selected: Int, maximum: Int) -> Error {
        PipelineError.photoSelectionExceedsBudget(selected: selected, maximum: maximum)
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
