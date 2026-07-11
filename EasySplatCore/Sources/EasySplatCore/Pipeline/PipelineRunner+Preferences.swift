import Foundation

extension PipelineRunner {
    func sfmMapperPreference() -> SfmMapperPreference {
        let env = runtimeEnvironment
        if let value = env["EASYSPLAT_SFM_MAPPER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "colmap" { return .colmap }
            if value == "glomap" { return .glomap }
        }
        return .glomap
    }

    func sfmBackendOverride() -> SfmBackend? {
        sfmBackendOverride(environment: runtimeEnvironment)
    }

    func sfmBackendOverride(environment env: [String: String]) -> SfmBackend? {
        if let value = env["EASYSPLAT_SFM_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if value == "da3" || value == "depth-anything-3" || value == "depthanything3" { return .da3 }
            if value == "mapanything" { return .mapanything }
            if value == "glomap" || value == "global_mapper" { return .colmap }
            if value == "colmap" { return .colmap }
            if value == "fastvggt" { return .fastvggt }
            if value == "vggt" || value == "vggt-mps" { return .vggt }
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
            if override == .mapanything {
                return [.mapanything, .colmap]
            }
            return [override]
        }
        if isFastSpeedProfile() {
            return [.colmap]
        }
        return [.da3, .mapanything, .colmap]
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

    func mapAnythingDevicePreference() -> String {
        stringEnvValue("EASYSPLAT_MAPANYTHING_DEVICE") ?? "mps"
    }

    func mapAnythingCheckpointPreference() -> String {
        stringEnvValue("EASYSPLAT_MAPANYTHING_CHECKPOINT") ?? "map-anything-apache"
    }

    func mapAnythingResolutionPreference(autoTune: AutoTuneProfile? = nil) -> Int {
        let requested = max(64, intEnvValue("EASYSPLAT_MAPANYTHING_RESOLUTION") ?? autoTune?.mapAnythingResolution ?? 518)
        let supported = [512, 518]
        if supported.contains(requested) {
            return requested
        }
        return supported.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? 518
    }

    func mapAnythingMemoryEfficientInferencePreference() -> Bool {
        boolEnvValue("EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT", default: true)
    }

    func mapAnythingUseAMPPreference() -> Bool {
        boolEnvValue("EASYSPLAT_MAPANYTHING_USE_AMP", default: false)
    }

    func mapAnythingMinibatchSizePreference() -> Int {
        max(1, intEnvValue("EASYSPLAT_MAPANYTHING_MINIBATCH_SIZE") ?? 1)
    }

    func mapAnythingMaxPointsPreference(preset: PresetSpec) -> Int {
        if let override = intEnvValue("EASYSPLAT_MAPANYTHING_MAX_POINTS"), override > 0 {
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

    func mapAnythingCameraTypePreference(preset: PresetSpec) -> String {
        stringEnvValue("EASYSPLAT_MAPANYTHING_CAMERA_TYPE") ?? cameraModel(for: preset)
    }

    func mapAnythingSharedCameraPreference(input: InputSpec) -> Bool {
        boolEnvValue("EASYSPLAT_MAPANYTHING_SHARED_CAMERA", default: input.hasVideos)
    }

    func mapAnythingAnchorMaxViewsPreference(
        autoTune: AutoTuneProfile? = nil,
        hardwareTier: HardwareProfile.Tier
    ) -> Int {
        if let override = intEnvValue("EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS"), override > 0 {
            return override
        }
        if let autoTuneValue = autoTune?.mapAnythingAnchorMaxViews, autoTuneValue > 0 {
            return autoTuneValue
        }
        switch hardwareTier {
        case .low:
            return 24
        case .mid:
            return 48
        case .high:
            return 64
        }
    }

    func mapAnythingWindowSizePreference(
        autoTune: AutoTuneProfile? = nil,
        hardwareTier: HardwareProfile.Tier
    ) -> Int {
        if let override = intEnvValue("EASYSPLAT_MAPANYTHING_WINDOW_SIZE"), override > 0 {
            return override
        }
        if let autoTuneValue = autoTune?.mapAnythingWindowSize, autoTuneValue > 0 {
            return autoTuneValue
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

    func mapAnythingWindowOverlapPreference(
        autoTune: AutoTuneProfile? = nil,
        hardwareTier: HardwareProfile.Tier
    ) -> Int {
        if let override = intEnvValue("EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP"), override >= 0 {
            return override
        }
        if let autoTuneValue = autoTune?.mapAnythingWindowOverlap, autoTuneValue >= 0 {
            return autoTuneValue
        }
        switch hardwareTier {
        case .low:
            return 1
        case .mid:
            return 2
        case .high:
            return 2
        }
    }

    func mapAnythingDirectMinimumMeanTrackLengthPreference(mode: CaptureMode) -> Double {
        if let override = doubleEnvValue("EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH"),
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

    func vggtDirectMinimumMeanTrackLengthPreference(mode: CaptureMode) -> Double {
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

    func mapAnythingDirectQualityFailureReason(score: ReconstructionScore, mode: CaptureMode) -> String? {
        directSparseQualityFailureReason(
            score: score,
            mode: mode,
            minimumTrackLength: mapAnythingDirectMinimumMeanTrackLengthPreference(mode: mode)
        )
    }

    func mapAnythingScoreApplyingCoverageFallback(
        _ score: ReconstructionScore,
        coverageManifest: MapAnythingCoverageManifest?
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

    func mapAnythingExecutionPlan(
        hardwareProfile: HardwareProfile,
        input: InputSpec,
        selectedFrameCount: Int,
        preset: PresetSpec,
        autoTune: AutoTuneProfile? = nil,
        explicitlyRequested: Bool = false
    ) -> MapAnythingExecutionPlan {
        let device = mapAnythingDevicePreference()
        let resolution = mapAnythingResolutionPreference(autoTune: autoTune)
        let memoryEfficientInference = mapAnythingMemoryEfficientInferencePreference()
        let requestedAMP = mapAnythingUseAMPPreference()
        let safeAMP = requestedAMP && device == "cuda"
        let minibatchSize = mapAnythingMinibatchSizePreference()
        let maxPoints = mapAnythingMaxPointsPreference(preset: preset)
        let cameraType = mapAnythingCameraTypePreference(preset: preset)
        let sharedCamera = mapAnythingSharedCameraPreference(input: input)
        let hardwareTier = hardwareProfile.tier

        let tunedDirectViewLimit = autoTune?.mapAnythingDirectViewLimit ?? {
            switch hardwareTier {
            case .low:
                return 0
            case .mid:
                return 6
            case .high:
                return 8
            }
        }()
        // An explicit MapAnything override is a request to use MapAnything's
        // native output when the input is within the established safe direct
        // solve ceiling. Auto-tuning may retain conservative memory settings,
        // but must not silently turn that request into a COLMAP refinement.
        let directViewLimit = explicitlyRequested ? max(tunedDirectViewLimit, 8) : tunedDirectViewLimit
        let anchorMaxViews = mapAnythingAnchorMaxViewsPreference(autoTune: autoTune, hardwareTier: hardwareTier)
        let seedWindowSize = mapAnythingWindowSizePreference(autoTune: autoTune, hardwareTier: hardwareTier)
        let windowOverlap = mapAnythingWindowOverlapPreference(autoTune: autoTune, hardwareTier: hardwareTier)

        let directAllowed = directViewLimit > 0 && selectedFrameCount >= 2 && selectedFrameCount <= directViewLimit
        return MapAnythingExecutionPlan(
            mode: directAllowed ? .direct : .seedRefine,
            device: device,
            resolution: resolution,
            memoryEfficientInference: memoryEfficientInference,
            useAMP: safeAMP,
            minibatchSize: minibatchSize,
            maxPoints: maxPoints,
            cameraType: cameraType,
            sharedCamera: sharedCamera,
            anchorMaxViews: max(2, min(selectedFrameCount, anchorMaxViews)),
            windowSize: directAllowed ? max(2, selectedFrameCount) : max(2, min(seedWindowSize, max(2, selectedFrameCount))),
            windowOverlap: directAllowed ? 0 : min(windowOverlap, max(0, min(seedWindowSize, max(2, selectedFrameCount)) - 1)),
            directViewLimit: directViewLimit,
            directAllowed: directAllowed
        )
    }

    func inferPreparedMapAnythingMode(paths: ProjectPaths) -> MapAnythingRunMode? {
        let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        if sparseModelFilesExist(at: paths.colmapSeedModelURL) {
            return .seedRefine
        }
        if sparseModelFilesExist(at: sparseZero) {
            return .direct
        }
        return nil
    }

    func vggtDevicePreference() -> String {
        let env = runtimeEnvironment
        if let value = env["EASYSPLAT_VGGT_DEVICE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "mps"
    }

    func vggtImageLoadResolutionPreference(preset: PresetSpec) -> Int {
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_VGGT_RESOLUTION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 518
    }

    func vggtDirectMinimumSparsePointsPreference(
        selectedFrameCount: Int,
        mode: CaptureMode,
        maxPoints: Int? = nil
    ) -> Int {
        let perFrame = mode == .room ? 300 : 500
        let floor = mode == .room ? 4_000 : 6_000
        let minimumPointCount = max(floor, max(1, selectedFrameCount) * perFrame)
        guard let maxPoints, maxPoints > 0 else {
            return minimumPointCount
        }
        return min(minimumPointCount, maxPoints)
    }

    func vggtDirectQualityFailureReason(
        score: ReconstructionScore,
        selectedFrameCount: Int,
        mode: CaptureMode,
        maxPoints: Int? = nil
    ) -> String? {
        guard ReconstructionScorer.isAcceptable(score, mode: mode) else {
            return "below the general quality bar"
        }
        guard let pointCount = score.pointCount else { return "sparse model did not report sparse point count" }
        let minimumPointCount = vggtDirectMinimumSparsePointsPreference(
            selectedFrameCount: selectedFrameCount,
            mode: mode,
            maxPoints: maxPoints
        )
        if pointCount < minimumPointCount {
            return "sparse point count \(pointCount) below direct minimum \(minimumPointCount)"
        }
        let hasTrackMetrics = score.observationCount != nil || score.meanTrackLength != nil
        if hasTrackMetrics,
           let failureReason = directSparseQualityFailureReason(
               score: score,
               mode: mode,
               minimumTrackLength: vggtDirectMinimumMeanTrackLengthPreference(mode: mode)
           ) {
            return failureReason
        }
        return nil
    }

    func vggtConfidenceThresholdPreference() -> Double {
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_VGGT_CONF_THRES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0 {
            return override
        }
        return 5.0
    }

    func vggtMaxPointsPreference(preset: PresetSpec) -> Int {
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
        if let value = env["EASYSPLAT_VGGT_CAMERA_TYPE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "SIMPLE_PINHOLE"
    }

    func vggtVisibilityThresholdPreference() -> Double {
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_VGGT_VIS_THRESH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0 {
            return override
        }
        return 0.2
    }

    func vggtQueryFrameCountPreference() -> Int {
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_VGGT_QUERY_FRAMES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override > 0 {
            return override
        }
        return 8
    }

    func vggtMaxQueryPointsPreference() -> Int {
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
        if let value = env["EASYSPLAT_VGGT_KEYPOINT_EXTRACTOR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "aliked+sp"
    }

    func vggtBaMaxFramesPreference() -> Int? {
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
        if let value = env["EASYSPLAT_FASTVGGT_DTYPE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "auto"
    }

    func fastvggtMergingPreference() -> Int {
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_FASTVGGT_MERGING"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw) {
            return override
        }
        return 0
    }

    func fastvggtMergeRatioPreference() -> Double {
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_FASTVGGT_MERGE_RATIO"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw) {
            return override
        }
        return 0.9
    }

    func fastvggtConfidenceThresholdPreference() -> Double {
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
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
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Int(raw),
           override >= 1_000 {
            return override
        }
        return 25_000
    }

    func fastvggtCoverageOverlapPreference() -> Double {
        let env = runtimeEnvironment
        if let raw = env["EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let override = Double(raw),
           override > 0,
           override < 1 {
            return override
        }
        return 0.35
    }

    func fastvggtCoverageMaxRoundsPreference() -> Int {
        let env = runtimeEnvironment
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
