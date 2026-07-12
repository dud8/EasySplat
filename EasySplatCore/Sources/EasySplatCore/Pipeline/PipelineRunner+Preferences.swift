import Foundation

extension PipelineRunner {
    func sfmMapperPreference() -> SfmMapperPreference {
        let env = runtimeEnvironment
        if let value = env["EASYSPLAT_SFM_MAPPER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "colmap" { return .colmap }
        }
        return .globalMapper
    }

    func sfmBackendOverride() -> SfmBackend? {
        sfmBackendOverride(environment: runtimeEnvironment)
    }

    func sfmBackendOverride(environment env: [String: String]) -> SfmBackend? {
        if let value = env["EASYSPLAT_SFM_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "da3" || value == "depth-anything-3" || value == "depthanything3" { return .da3 }
            if value == "colmap" { return .colmap }
        }
        return nil
    }

    func sfmBackendPolicy() -> SfmBackend {
        if let override = sfmBackendOverride() {
            return override
        }
        return isFastSpeedProfile() ? .colmap : .da3
    }

    func sfmBackendFallbackOrder(override: SfmBackend?) -> [SfmBackend] {
        if let override {
            return [override]
        }
        if isFastSpeedProfile() {
            return [.colmap]
        }
        return [.da3, .colmap]
    }

    func da3DevicePreference() -> String {
        stringEnvValue("EASYSPLAT_DA3_DEVICE") ?? "mps"
    }

    func da3ModelPreference() -> String {
        stringEnvValue("EASYSPLAT_DA3_MODEL") ?? "DA3-BASE"
    }

    func da3FallbackModelPreference() -> String {
        stringEnvValue("EASYSPLAT_DA3_FALLBACK_MODEL") ?? "DA3-SMALL"
    }

    func da3ProcessResolutionPreference() -> Int {
        max(64, intEnvValue("EASYSPLAT_DA3_PROCESS_RES") ?? 504)
    }

    func da3MaxPointsPreference(preset: PresetSpec) -> Int {
        if let override = intEnvValue("EASYSPLAT_DA3_MAX_POINTS"), override > 0 {
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

    func da3CameraTypePreference(preset: PresetSpec) -> String {
        stringEnvValue("EASYSPLAT_DA3_CAMERA_TYPE") ?? cameraModel(for: preset)
    }

    func da3SharedCameraPreference(input: InputSpec) -> Bool {
        boolEnvValue("EASYSPLAT_DA3_SHARED_CAMERA", default: input.hasVideos)
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
        if let override = intEnvValue("EASYSPLAT_DA3_WINDOW_SIZE"), override > 0 {
            return override
        }
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
        if let override = intEnvValue("EASYSPLAT_DA3_WINDOW_OVERLAP"), override >= 0 {
            return override
        }
        switch hardwareTier {
        case .low:
            return 1
        case .mid, .high:
            return 2
        }
    }

    func da3DirectMinimumMeanTrackLengthPreference(mode: CaptureMode) -> Double {
        if let override = doubleEnvValue("EASYSPLAT_DA3_DIRECT_MIN_TRACK_LENGTH"),
           override.isFinite,
           override > 0 {
            return override
        }
        switch mode {
        case .room:
            return 1.20
        case .object:
            return 1.15
        }
    }

    func directSparseQualityFailureReason(
        score: ReconstructionScore,
        mode: CaptureMode,
        minimumTrackLength: Double
    ) -> String? {
        guard ReconstructionScorer.isAcceptable(score, mode: mode) else {
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

    func da3DirectQualityFailureReason(score: ReconstructionScore, mode: CaptureMode) -> String? {
        directSparseQualityFailureReason(
            score: score,
            mode: mode,
            minimumTrackLength: da3DirectMinimumMeanTrackLengthPreference(mode: mode)
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
        if let override = colmapGpuOverride() {
            return override
        }
        return detectColmapGpuSupport(colmapPath: colmapPath)
    }

    func shouldAutoTune() -> Bool {
        if let value = runtimeEnvironment["EASYSPLAT_AUTOTUNE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if ["0", "false", "no"].contains(value) { return false }
        }
        return true
    }

    func hasEnvValue(_ key: String) -> Bool {
        if let value = runtimeEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return !value.isEmpty
        }
        return false
    }

    func boolEnvValue(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = runtimeEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if ["1", "true", "yes"].contains(value) { return true }
            if ["0", "false", "no"].contains(value) { return false }
        }
        return defaultValue
    }

    func intEnvValue(_ key: String) -> Int? {
        guard let raw = runtimeEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw) else {
            return nil
        }
        return value
    }

    func doubleEnvValue(_ key: String) -> Double? {
        guard let raw = runtimeEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(raw),
              value.isFinite else {
            return nil
        }
        return value
    }

    func stringEnvValue(_ key: String) -> String? {
        guard let raw = runtimeEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    func isFastSpeedProfile() -> Bool {
        if config.speedProfile == .fast { return true }
        guard let raw = stringEnvValue("EASYSPLAT_SPEED_PROFILE")?.lowercased() else { return false }
        return ["fast", "apple-silicon-fast"].contains(raw)
    }

    func fastSpeedProfileFrameBudget() -> Int {
        30
    }

    func fastSpeedProfileFrameExtractionCap(targetCount: Int) -> Int {
        max(targetCount, Int(ceil(Double(targetCount) / 0.75)))
    }

    func colmapMaxImageSizeOverride() -> Int? {
        intEnvValue("EASYSPLAT_COLMAP_MAX_IMAGE_SIZE")
            .flatMap { $0 > 0 ? max(64, $0) : nil }
    }

    func globalMapperOptions(threadHint: Int, defaultUseGpu: Bool = true) -> ColmapGlobalMapperOptions {
        let preferredThreads = max(1, intEnvValue("EASYSPLAT_GLOBAL_MAPPER_THREADS") ?? threadHint)
        let gpUseGpu = boolEnvValue("EASYSPLAT_GLOBAL_MAPPER_GP_USE_GPU", default: defaultUseGpu)
        let baUseGpu = boolEnvValue("EASYSPLAT_GLOBAL_MAPPER_BA_USE_GPU", default: defaultUseGpu)
        let gpuIndex = stringEnvValue("EASYSPLAT_GLOBAL_MAPPER_GPU_INDEX") ?? "-1"
        let gpGpuIndex = stringEnvValue("EASYSPLAT_GLOBAL_MAPPER_GP_GPU_INDEX") ?? gpuIndex
        let baGpuIndex = stringEnvValue("EASYSPLAT_GLOBAL_MAPPER_BA_GPU_INDEX") ?? gpuIndex
        let minNumMatches = intEnvValue("EASYSPLAT_GLOBAL_MAPPER_MIN_NUM_MATCHES")
        let baIterations = intEnvValue("EASYSPLAT_GLOBAL_MAPPER_BA_NUM_ITERATIONS")
        return ColmapGlobalMapperOptions(
            useGpuForGlobalPositioning: gpUseGpu,
            gpuIndexForGlobalPositioning: gpGpuIndex,
            useGpuForBundleAdjustment: baUseGpu,
            gpuIndexForBundleAdjustment: baGpuIndex,
            numThreads: preferredThreads,
            minNumMatches: minNumMatches,
            baNumIterations: baIterations
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

        if colmapMaxImageSizeOverride() == nil {
            colmapMaxImageSize = min(colmapMaxImageSize, 512)
        }
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

    func colmapSequentialOverlapOverride() -> Int? {
        guard let value = intEnvValue("EASYSPLAT_COLMAP_SEQUENTIAL_OVERLAP") else {
            return nil
        }
        return min(30, max(1, value))
    }

    func colmapGpuOverride() -> Bool? {
        let env = runtimeEnvironment
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
