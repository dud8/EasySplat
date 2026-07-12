import Foundation

extension PipelineRunner {
    func sfmBackendOverride() -> SfmBackend? {
        config.developmentOverrides.candidateRoute
    }

    func sfmBackendPolicy() -> SfmBackend {
        if let override = sfmBackendOverride() {
            return override
        }
        return .da3
    }

    func sfmBackendFallbackOrder(override: SfmBackend?) -> [SfmBackend] {
        if let override {
            return [override]
        }
        return [.da3, .colmap]
    }

    func sfmBackendFallbackOrder(resolvedPlan: ResolvedRunPlan) throws -> [SfmBackend] {
        try resolvedPlan.validatedBackendOrder()
    }

    func da3DevicePreference() -> String {
        "mps"
    }

    func da3ModelPreference() -> String {
        "DA3-BASE"
    }

    func da3FallbackModelPreference() -> String {
        "DA3-SMALL"
    }

    func da3ProcessResolutionPreference() -> Int {
        504
    }

    func da3MaxPointsPreference(preset: PresetSpec) -> Int {
        switch preset.quality {
        case .draft:
            return 60_000
        case .standard:
            return 100_000
        case .ultra:
            return 150_000
        }
    }

    func da3CameraTypePreference(preset: PresetSpec, lensProjection: LensProjection = .automatic) -> String {
        cameraModel(for: preset, lensProjection: lensProjection)
    }

    func da3SharedCameraPreference(input: InputSpec, cameraGrouping: CameraGrouping = .automatic) -> Bool {
        switch cameraGrouping {
        case .automatic:
            return input.hasVideos && !input.hasPhotos
        case .sameCameraAndLens:
            return true
        case .mixedCamerasOrLenses:
            return false
        }
    }

    func da3ResolvedInputOrdering(requested: InputOrdering, input: InputSpec) -> InputOrdering {
        if requested != .automatic {
            return requested
        }
        switch input {
        case .video:
            return .continuous
        case .photos, .mixed:
            return .unordered
        }
    }

    func da3WindowSizePreference(hardwareTier: HardwareProfile.Tier) -> Int {
        switch hardwareTier {
        case .low:
            return 4
        case .mid:
            return 6
        case .high:
            return 8
        }
    }

    func da3WindowOverlapPreference(hardwareTier: HardwareProfile.Tier) -> Int {
        switch hardwareTier {
        case .low:
            return 1
        case .mid, .high:
            return 2
        }
    }

    func da3DirectMinimumMeanTrackLengthPreference(capturePath: CapturePath) -> Double {
        switch capturePath {
        case .orbit:
            return 1.15
        case .automatic, .walkthrough, .largeArea:
            return 1.20
        }
    }

    func directSparseQualityFailureReason(
        score: ReconstructionScore,
        capturePath: CapturePath,
        minimumTrackLength: Double
    ) -> String? {
        guard ReconstructionScorer.isAcceptable(score, capturePath: capturePath) else {
            return "below the general quality bar"
        }
        guard let pointCount = score.pointCount, pointCount > 0 else {
            return "model_analyzer did not report sparse point count"
        }
        guard let observationCount = score.observationCount, observationCount > 0 else {
            return "model_analyzer did not report observations"
        }
        guard let meanTrackLength = score.meanTrackLength, meanTrackLength > 0 else {
            return "model_analyzer did not report a usable mean track length"
        }

        if meanTrackLength < minimumTrackLength {
            return String(
                format: "mean track length %.2f below direct minimum %.2f",
                meanTrackLength,
                minimumTrackLength
            )
        }
        if observationCount <= pointCount {
            return "observations (\(observationCount)) did not exceed sparse points (\(pointCount))"
        }
        return nil
    }

    func da3DirectQualityFailureReason(score: ReconstructionScore, capturePath: CapturePath) -> String? {
        directSparseQualityFailureReason(
            score: score,
            capturePath: capturePath,
            minimumTrackLength: da3DirectMinimumMeanTrackLengthPreference(capturePath: capturePath)
        )
    }

    func da3ScoreApplyingCoverageFallback(
        _ score: ReconstructionScore,
        coverageManifest: Da3CoverageManifest?
    ) -> ReconstructionScore {
        guard let coverageManifest else {
            return score
        }
        return ReconstructionScore(
            registeredImages: score.registeredImages,
            totalImages: score.totalImages,
            meanReprojectionError: score.meanReprojectionError,
            pointCount: score.pointCount ?? coverageManifest.fusedSparsePointCount,
            observationCount: score.observationCount ?? coverageManifest.finalObservationCount,
            meanTrackLength: score.meanTrackLength ?? coverageManifest.meanTrackLength
        )
    }

    func shouldUseColmapGpu(colmapPath: URL) -> Bool {
        detectColmapGpuSupport(colmapPath: colmapPath)
    }

    func shouldAutoTune() -> Bool {
        true
    }

    func isFastSpeedProfile() -> Bool {
        config.speedProfile == .fast
    }

    func fastSpeedProfileFrameBudget() -> Int {
        30
    }

    func fastSpeedProfileFrameExtractionCap(targetCount: Int) -> Int {
        max(targetCount, Int(ceil(Double(targetCount) / 0.75)))
    }

    func globalMapperOptions(threadHint: Int, defaultUseGpu: Bool = true) -> ColmapGlobalMapperOptions {
        let preferredThreads = max(1, threadHint)
        return ColmapGlobalMapperOptions(
            useGpuForGlobalPositioning: defaultUseGpu,
            gpuIndexForGlobalPositioning: "-1",
            useGpuForBundleAdjustment: defaultUseGpu,
            gpuIndexForBundleAdjustment: "-1",
            numThreads: preferredThreads,
            minNumMatches: nil,
            baNumIterations: nil
        )
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

    @discardableResult
    func applySpeedProfileIfNeeded(
        colmapMaxImageSize: inout Int,
        colmapExtractOptions: inout ColmapOptions,
        colmapMatchOptions: inout ColmapOptions
    ) -> Bool {
        guard isFastSpeedProfile() else { return false }

        colmapMaxImageSize = min(colmapMaxImageSize, 512)
        colmapExtractOptions.sequentialOverlap = min(colmapExtractOptions.sequentialOverlap, 2)
        colmapMatchOptions.sequentialOverlap = min(colmapMatchOptions.sequentialOverlap, 2)
        colmapExtractOptions.maxNumFeatures = colmapExtractOptions.maxNumFeatures.map { min($0, 4_000) } ?? 4_000
        colmapMatchOptions.maxNumFeatures = colmapMatchOptions.maxNumFeatures.map { min($0, 4_000) } ?? 4_000
        colmapMatchOptions.maxNumMatches = colmapMatchOptions.maxNumMatches.map { min($0, 4_000) } ?? 4_000
        colmapMatchOptions.exhaustiveBlockSize = colmapMatchOptions.exhaustiveBlockSize.map { min($0, 25) } ?? 25
        return true
    }

    func updateThreadEnvironment(_ options: inout ColmapOptions, threadCount: Int) {
        if options.environment.isEmpty { return }
        options.environment["OMP_NUM_THREADS"] = "\(threadCount)"
        options.environment["OPENBLAS_NUM_THREADS"] = "\(threadCount)"
        options.environment["MKL_NUM_THREADS"] = "\(threadCount)"
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

    func colmapErrorIndicatesMissingGlobalMapper(_ error: ColmapRunnerError) -> Bool {
        let output: String
        switch error {
        case let .failed(_, _, _, stdoutTail, stderrTail):
            output = (stderrTail + "\n" + stdoutTail).lowercased()
        }
        if output.contains("command `global_mapper` not recognized") { return true }
        if output.contains("global_mapper") && output.contains("not recognized") { return true }
        if output.contains("unknown option") && output.contains("globalmapper.") { return true }
        return false
    }
}
