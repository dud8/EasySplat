import Foundation

/// Turns user intent and measured hardware into the fixed contract used by every pipeline stage.
public enum RunPlanResolver {
    public static let minimumHighDetailMemoryGB = 24.0
    public static let minimumReconstructionImageCount = 3

    public enum ValidationError: Error, LocalizedError, Equatable {
        case continuousMultipleClipsUnsupported
        case fastDetailRequired
        case highDetailRequiresMoreMemory
        case noValidPhotos
        case insufficientValidPhotos(actual: Int, minimum: Int)
        case photoSelectionExceedsSafeLimit(selected: Int, maximum: Int)

        public var errorDescription: String? {
            switch self {
            case .continuousMultipleClipsUnsupported:
                return "Continuous sequence currently supports one video clip. Use Automatic or Unordered for separate clips."
            case .fastDetailRequired:
                return "This Mac supports the Fast detail profile. Choose Fast to stay within its memory limit."
            case .highDetailRequiresMoreMemory:
                return "High Detail requires a Mac with at least 24 GB of unified memory. Choose Balanced or Fast."
            case .noValidPhotos:
                return "This folder has no readable photos. Choose a folder with JPEG, PNG, HEIC, or HEIF images."
            case let .insufficientValidPhotos(actual, minimum):
                let noun = actual == 1 ? "photo" : "photos"
                return "This folder has \(actual) usable \(noun). Choose at least \(minimum) photos from different viewpoints."
            case let .photoSelectionExceedsSafeLimit(selected, maximum):
                return "This folder has \(selected) valid photos. This run can safely use up to \(maximum). Choose Automatic selection or a smaller folder."
            }
        }
    }

    public static func validate(
        requestedOptions: RequestedRunOptions,
        input: InputSpec
    ) throws {
        try validate(
            requestedOptions: requestedOptions,
            input: input,
            hardware: .detect()
        )
    }

    public static func validate(
        requestedOptions: RequestedRunOptions,
        input: InputSpec,
        hardware: HardwareProfile
    ) throws {
        if hardware.memoryGB <= 8.5, requestedOptions.detailProfile != .fast {
            throw ValidationError.fastDetailRequired
        }
        if hardware.memoryGB < minimumHighDetailMemoryGB,
           requestedOptions.detailProfile == .highDetail {
            throw ValidationError.highDetailRequiresMoreMemory
        }
        if !supports(inputOrdering: requestedOptions.inputOrdering, input: input) {
            throw ValidationError.continuousMultipleClipsUnsupported
        }
    }

    public static func supports(detail: DetailProfile, memoryGB: Double) -> Bool {
        if memoryGB <= 8.5 {
            return detail == .fast
        }
        return detail != .highDetail || memoryGB >= minimumHighDetailMemoryGB
    }

    public static func supports(resourcePolicy: ResourcePolicy, memoryGB: Double) -> Bool {
        resourcePolicy != .maximumPerformance || memoryGB > 16.5
    }

    public static func supports(inputOrdering: InputOrdering, input: InputSpec) -> Bool {
        guard inputOrdering == .continuous else { return true }
        return input.videoFiles.count <= 1 && !(input.hasVideos && input.hasPhotos)
    }

    public static func maximumValidPhotoCount(for resolvedPlan: ResolvedRunPlan) -> Int? {
        resolvedPlan.photoSelection == .useAllValidPhotos
            ? resolvedPlan.keyframeBudget
            : nil
    }

    public static func maximumValidPhotoCount(
        for resolvedPlan: ResolvedRunPlan,
        input: InputSpec
    ) -> Int? {
        guard resolvedPlan.photoSelection == .useAllValidPhotos else { return nil }
        return max(
            0,
            resolvedPlan.keyframeBudget - minimumReservedVideoFrameCount(
                keyframeBudget: resolvedPlan.keyframeBudget,
                videoCount: input.hasPhotos ? input.videoFiles.count : 0
            )
        )
    }

    public static func minimumReservedVideoFrameCount(
        keyframeBudget: Int,
        videoCount: Int
    ) -> Int {
        guard keyframeBudget > 0, videoCount > 0 else { return 0 }
        return min(keyframeBudget, max(videoCount * 2, keyframeBudget / 4))
    }

    public static func validatePhotoSelection(
        validPhotoCount: Int,
        resolvedPlan: ResolvedRunPlan
    ) throws {
        try validatePhotoSelection(
            validPhotoCount: validPhotoCount,
            minimum: minimumReconstructionImageCount,
            maximum: maximumValidPhotoCount(for: resolvedPlan)
        )
    }

    public static func validatePhotoSelection(
        validPhotoCount: Int,
        resolvedPlan: ResolvedRunPlan,
        input: InputSpec
    ) throws {
        try validatePhotoSelection(
            validPhotoCount: validPhotoCount,
            minimum: input.hasVideos ? 0 : minimumReconstructionImageCount,
            maximum: maximumValidPhotoCount(for: resolvedPlan, input: input)
        )
    }

    private static func validatePhotoSelection(
        validPhotoCount: Int,
        minimum: Int,
        maximum: Int?
    ) throws {
        guard validPhotoCount >= 0 else {
            throw ValidationError.noValidPhotos
        }
        guard validPhotoCount > 0 || minimum == 0 else {
            throw ValidationError.noValidPhotos
        }
        guard validPhotoCount >= minimum else {
            throw ValidationError.insufficientValidPhotos(
                actual: validPhotoCount,
                minimum: minimum
            )
        }
        guard let maximum, validPhotoCount > maximum else { return }
        throw ValidationError.photoSelectionExceedsSafeLimit(
            selected: validPhotoCount,
            maximum: maximum
        )
    }

    public static func resolveForCurrentHardware(
        requestedOptions: RequestedRunOptions,
        input: InputSpec,
        developmentOverrides: DevelopmentOverrides = .none
    ) -> ResolvedRunPlan {
        resolve(
            requestedOptions: requestedOptions,
            input: input,
            hardware: .detect(),
            developmentOverrides: developmentOverrides
        )
    }

    public static func safeResumeStage(
        _ lastCompletedStage: PipelineStage?,
        input: InputSpec,
        previousPlan: ResolvedRunPlan?,
        currentPlan: ResolvedRunPlan
    ) -> PipelineStage? {
        guard let lastCompletedStage,
              let previousPlan,
              previousPlan != currentPlan else {
            return lastCompletedStage
        }
        let framePreparationChanged = previousPlan.keyframeBudget != currentPlan.keyframeBudget
            || previousPlan.maximumImageDimension != currentPlan.maximumImageDimension
            || previousPlan.analysisFrameRate != currentPlan.analysisFrameRate
            || previousPlan.photoSelection != currentPlan.photoSelection
            || previousPlan.capturePath != currentPlan.capturePath
        let geometryChanged = previousPlan.routeIdentifier != currentPlan.routeIdentifier
            || previousPlan.modelIdentifier != currentPlan.modelIdentifier
            || previousPlan.memoryTier != currentPlan.memoryTier
            || previousPlan.chunkSize != currentPlan.chunkSize
            || previousPlan.geometryProcessResolution != currentPlan.geometryProcessResolution
            || previousPlan.colmapMaximumImageDimension != currentPlan.colmapMaximumImageDimension
            || previousPlan.cameraGrouping != currentPlan.cameraGrouping
            || previousPlan.lensProjection != currentPlan.lensProjection
            || previousPlan.refinementIterationLimit != currentPlan.refinementIterationLimit
            || previousPlan.colmapMaximumFeatureCount != currentPlan.colmapMaximumFeatureCount
            || previousPlan.colmapMaximumMatchCount != currentPlan.colmapMaximumMatchCount
            || previousPlan.colmapThreadLimit != currentPlan.colmapThreadLimit
            || previousPlan.requiredToolchainCapabilities != currentPlan.requiredToolchainCapabilities
            || previousPlan.fallbackRouteIdentifiers != currentPlan.fallbackRouteIdentifiers
            || previousPlan.inputOrdering != currentPlan.inputOrdering
        let mappingPolicyChanged = previousPlan.baGlobalFramesRatio != currentPlan.baGlobalFramesRatio
            || previousPlan.baGlobalPointsRatio != currentPlan.baGlobalPointsRatio
            || previousPlan.baLocalMaxRefinements != currentPlan.baLocalMaxRefinements
            || previousPlan.baGlobalMaxRefinements != currentPlan.baGlobalMaxRefinements
            || previousPlan.baLocalMaxNumIterations != currentPlan.baLocalMaxNumIterations
            || previousPlan.baLocalFunctionTolerance != currentPlan.baLocalFunctionTolerance
            || previousPlan.baGlobalFunctionTolerance != currentPlan.baGlobalFunctionTolerance
            || previousPlan.baLocalImageCount != currentPlan.baLocalImageCount
            || previousPlan.deterministicSeed != currentPlan.deterministicSeed
        let matchingPolicyChanged = previousPlan.pairingPolicy != currentPlan.pairingPolicy
            || previousPlan.temporalPairing != currentPlan.temporalPairing
            || previousPlan.temporalOffsets != currentPlan.temporalOffsets
            || previousPlan.retrievalEngine != currentPlan.retrievalEngine
            || previousPlan.retrievalCandidateCount != currentPlan.retrievalCandidateCount
            || previousPlan.retrievalNeighborCount != currentPlan.retrievalNeighborCount
            || previousPlan.retrievalQueryStride != currentPlan.retrievalQueryStride
            || previousPlan.normalDescriptorMatcher != currentPlan.normalDescriptorMatcher
        let safeBoundary: PipelineStage
        if framePreparationChanged {
            safeBoundary = input.hasVideos ? .importInput : .extractFrames
        } else if geometryChanged {
            safeBoundary = .selectFrames
        } else if matchingPolicyChanged {
            safeBoundary = .sfmFeatures
        } else if mappingPolicyChanged {
            safeBoundary = .sfmMatching
        } else {
            safeBoundary = .sfmMapping
        }
        let stages = PipelineStage.allCases
        let completedIndex = stages.firstIndex(of: lastCompletedStage) ?? 0
        let boundaryIndex = stages.firstIndex(of: safeBoundary) ?? 0
        return completedIndex < boundaryIndex ? lastCompletedStage : safeBoundary
    }

    public static func resolve(
        requestedOptions options: RequestedRunOptions,
        input: InputSpec,
        hardware: HardwareProfile,
        developmentOverrides: DevelopmentOverrides,
        trainingMemoryRetryBudgetBytes: Int64? = nil
    ) -> ResolvedRunPlan {
        let capturePath = options.capturePath
        let inputOrdering = resolvedInputOrdering(options.inputOrdering, input: input)
        let pairingPolicy = resolvedPairingPolicy(
            capturePath: capturePath,
            requestedInputOrdering: options.inputOrdering,
            resolvedInputOrdering: inputOrdering,
            input: input
        )
        let pairingConfiguration = pairingConfiguration(for: pairingPolicy)
        let baGlobalRatio: Double
        let baLocalMaxRefinements: Int
        switch pairingPolicy {
        case .unorderedRetrieval, .segmentedMixed:
            baGlobalRatio = 1.1
            baLocalMaxRefinements = 2
        case .orderedContinuous, .orderedOrbit, .orderedWalkthrough, .orderedLargeArea:
            baGlobalRatio = 4
            baLocalMaxRefinements = 1
        }
        let memoryTier = resolvedMemoryTier(
            resourcePolicy: options.resourcePolicy,
            detail: options.detailProfile,
            memoryGB: hardware.memoryGB
        )
        let route = developmentOverrides.candidateRoute ?? .colmap
        let model = resolvedModel(route: route)
        let keyframeBudget = route == .da3
            ? 29
            : resolvedKeyframeBudget(
                detail: options.detailProfile,
                capturePath: capturePath,
                memoryTier: memoryTier,
                resourcePolicy: options.resourcePolicy
            )
        let maximumImageDimension = resolvedMaximumImageDimension(
            detail: options.detailProfile,
            memoryTier: memoryTier,
            resourcePolicy: options.resourcePolicy
        )
        let colmapMaximumImageDimension = min(
            maximumImageDimension,
            resolvedColmapMaximumImageDimension(
                detail: options.detailProfile,
                memoryTier: memoryTier
            )
        )
        let trainerBudget = trainerBudget(for: options.detailProfile)
        let baseTrainingMemoryBudget = TrainingMemoryBudget.resolve(
            hardware: hardware,
            resourcePolicy: options.resourcePolicy
        )
        let maximumTrainingMemoryBudget = TrainingMemoryBudget.resolve(
            hardware: hardware,
            resourcePolicy: .maximumPerformance
        )
        let resolvedTrainingMemoryBudget = trainingMemoryRetryBudgetBytes
            .map { max(baseTrainingMemoryBudget, min($0, maximumTrainingMemoryBudget)) }
            ?? baseTrainingMemoryBudget
        let cameraGrouping = resolvedCameraGrouping(options.cameraGrouping, input: input)
        let lensProjection = options.lensProjection
        let colmapBudget = resolvedColmapBudget(
            memoryTier: memoryTier,
            resourcePolicy: options.resourcePolicy,
            cpuCount: hardware.cpuCount
        )

        return ResolvedRunPlan(
            routeIdentifier: route.rawValue,
            modelIdentifier: model,
            memoryTier: memoryTier.rawValue,
            chunkSize: route == .da3 ? 29 : 0,
            geometryProcessResolution: route == .da3 ? 336 : 0,
            analysisFrameRate: input.hasVideos
                ? resolvedAnalysisFrameRate(detail: options.detailProfile, capturePath: capturePath)
                : 0,
            keyframeBudget: keyframeBudget,
            maximumImageDimension: maximumImageDimension,
            colmapMaximumImageDimension: colmapMaximumImageDimension,
            cameraGrouping: cameraGrouping,
            lensProjection: lensProjection,
            refinementIterationLimit: resolvedRefinementLimit(
                detail: options.detailProfile,
                capturePath: capturePath,
                memoryTier: memoryTier
            ),
            trainerIterationLimit: trainerBudget.iterations,
            plateauWindow: trainerBudget.plateau,
            trainerMemoryBudgetBytes: resolvedTrainingMemoryBudget,
            colmapMaximumFeatureCount: colmapBudget.features,
            colmapMaximumMatchCount: colmapBudget.matches,
            colmapThreadLimit: colmapBudget.threads,
            requiredToolchainCapabilities: requiredCapabilities(route: route, model: model),
            fallbackRouteIdentifiers: [],
            capturePath: capturePath,
            inputOrdering: inputOrdering,
            photoSelection: options.photoSelection,
            pairingPolicy: pairingPolicy,
            temporalPairing: pairingConfiguration.temporalPairing,
            temporalOffsets: pairingConfiguration.temporalOffsets,
            retrievalEngine: .localSiftVocabularyV1,
            retrievalCandidateCount: pairingConfiguration.retrievalCandidateCount,
            retrievalNeighborCount: pairingConfiguration.retrievalNeighborCount,
            retrievalQueryStride: pairingConfiguration.retrievalQueryStride,
            normalDescriptorMatcher: .faiss,
            baGlobalFramesRatio: baGlobalRatio,
            baGlobalPointsRatio: baGlobalRatio,
            baLocalMaxRefinements: baLocalMaxRefinements,
            baGlobalMaxRefinements: 5,
            baLocalMaxNumIterations: 10,
            baLocalFunctionTolerance: 0.001,
            baGlobalFunctionTolerance: 0.000_001,
            baLocalImageCount: 6,
            deterministicSeed: UInt64(max(0, developmentOverrides.benchmarkSeed ?? 42))
        )
    }

    private enum MemoryTier: String {
        case constrained
        case standard
        case performance
    }

    private static func resolvedInputOrdering(_ requested: InputOrdering, input: InputSpec) -> InputOrdering {
        guard requested == .automatic else { return requested }
        switch input {
        case .video(let files):
            return files.count == 1 ? .continuous : .unordered
        case .photos, .mixed:
            return .unordered
        }
    }

    private static func resolvedCameraGrouping(
        _ requested: CameraGrouping,
        input: InputSpec
    ) -> CameraGrouping {
        guard requested == .automatic else { return requested }
        return input.videoFiles.count == 1 && !input.hasPhotos
            ? .sameCameraAndLens
            : .mixedCamerasOrLenses
    }

    private static func resolvedPairingPolicy(
        capturePath: CapturePath,
        requestedInputOrdering: InputOrdering,
        resolvedInputOrdering: InputOrdering,
        input: InputSpec
    ) -> ResolvedPairingPolicy {
        if requestedInputOrdering == .unordered {
            return .unorderedRetrieval
        }
        if input.videoFiles.count > 1 || (input.hasVideos && input.hasPhotos) {
            return .segmentedMixed
        }
        guard resolvedInputOrdering == .continuous else { return .unorderedRetrieval }
        switch capturePath {
        case .automatic:
            return .orderedContinuous
        case .walkthrough:
            return .orderedWalkthrough
        case .orbit:
            return .orderedOrbit
        case .largeArea:
            return .orderedLargeArea
        }
    }

    private static func resolvedMemoryTier(
        resourcePolicy: ResourcePolicy,
        detail: DetailProfile,
        memoryGB: Double
    ) -> MemoryTier {
        if memoryGB <= 16.5
            || (detail == .highDetail && memoryGB < minimumHighDetailMemoryGB) {
            return .constrained
        }
        switch resourcePolicy {
        case .conserveMemory:
            return .constrained
        case .maximumPerformance:
            return .performance
        case .automatic:
            return memoryGB <= 32 ? .standard : .performance
        }
    }

    private static func resolvedModel(route: SfmBackend) -> String {
        guard route == .da3 else { return "none" }
        return "DA3-BASE"
    }

    private static func resolvedKeyframeBudget(
        detail: DetailProfile,
        capturePath: CapturePath,
        memoryTier: MemoryTier,
        resourcePolicy: ResourcePolicy
    ) -> Int {
        let detailBase: Double = switch detail {
        case .fast: 120
        case .balanced: 250
        case .highDetail: 500
        }
        let captureScale: Double = switch capturePath {
        case .orbit: 0.8
        case .automatic, .walkthrough: 1.0
        case .largeArea: 1.5
        }
        let resourceScale: Double
        if memoryTier == .constrained {
            resourceScale = 0.64
        } else if resourcePolicy == .maximumPerformance {
            resourceScale = 1.2
        } else {
            resourceScale = 1.0
        }
        return max(30, Int((detailBase * captureScale * resourceScale).rounded()))
    }

    private static func resolvedMaximumImageDimension(
        detail: DetailProfile,
        memoryTier: MemoryTier,
        resourcePolicy: ResourcePolicy
    ) -> Int {
        let base: Int = switch detail {
        case .fast: 1_024
        case .balanced: 1_600
        case .highDetail: 2_048
        }
        if memoryTier == .constrained {
            let cap: Int = switch detail {
            case .fast: 960
            case .balanced: 1_280
            case .highDetail: 1_600
            }
            return min(base, cap)
        }
        guard resourcePolicy == .maximumPerformance else { return base }
        return Int((Double(base) * 1.125).rounded())
    }

    private static func resolvedAnalysisFrameRate(detail: DetailProfile, capturePath: CapturePath) -> Int {
        switch (detail, capturePath) {
        case (.fast, _): return 2
        case (.balanced, .largeArea): return 4
        case (.balanced, _): return 3
        case (.highDetail, .largeArea): return 4
        case (.highDetail, _): return 3
        }
    }

    private static func resolvedColmapMaximumImageDimension(
        detail: DetailProfile,
        memoryTier: MemoryTier
    ) -> Int {
        switch detail {
        case .fast:
            return 1_024
        case .balanced:
            return memoryTier == .performance ? 1_232 : 1_024
        case .highDetail:
            return 1_280
        }
    }

    private static func resolvedRefinementLimit(
        detail: DetailProfile,
        capturePath: CapturePath,
        memoryTier: MemoryTier
    ) -> Int {
        let base: Double = switch detail {
        case .fast: 40
        case .balanced: 75
        case .highDetail: 120
        }
        let captureScale = capturePath == .largeArea ? 1.25 : 1.0
        let memoryScale = memoryTier == .constrained ? 0.75 : 1.0
        return max(20, Int((base * captureScale * memoryScale).rounded()))
    }

    private static func trainerBudget(for detail: DetailProfile) -> (iterations: Int, plateau: Int) {
        switch detail {
        case .fast: return (3_000, 400)
        case .balanced: return (7_000, 800)
        case .highDetail: return (15_000, 1_500)
        }
    }

    private static func resolvedColmapBudget(
        memoryTier: MemoryTier,
        resourcePolicy: ResourcePolicy,
        cpuCount: Int
    ) -> (features: Int, matches: Int, threads: Int) {
        let values: (features: Int, matches: Int, threadCap: Int)
        switch memoryTier {
        case .constrained:
            values = (4_096, 4_096, 4)
        case .standard:
            values = (8_192, 8_192, 6)
        case .performance where resourcePolicy == .maximumPerformance:
            values = (12_000, 12_000, 10)
        case .performance:
            values = (10_000, 10_000, 8)
        }
        return (
            values.features,
            values.matches,
            min(max(1, cpuCount), values.threadCap)
        )
    }

    private static func requiredCapabilities(route: SfmBackend, model: String) -> [String] {
        switch route {
        case .colmap:
            return ["geometry.colmap", "runtime.core", "training.msplat"]
        case .da3:
            let modelCapability = model == "DA3-SMALL"
                ? "geometry.da3.small"
                : "geometry.da3.base"
            var capabilities = [
                modelCapability,
                "geometry.colmap",
                "geometry.da3.runtime",
                "runtime.core",
                "training.msplat",
            ]
            if model == "DA3-BASE" {
                capabilities.append("geometry.da3.small")
            }
            return capabilities.sorted()
        }
    }

    private struct PairingConfiguration {
        var temporalPairing: TemporalPairing
        var temporalOffsets: [Int]
        var retrievalCandidateCount: Int
        var retrievalNeighborCount: Int
        var retrievalQueryStride: Int
    }

    private static func pairingConfiguration(
        for policy: ResolvedPairingPolicy
    ) -> PairingConfiguration {
        switch policy {
        case .unorderedRetrieval:
            return PairingConfiguration(
                temporalPairing: .none,
                temporalOffsets: [],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 8,
                retrievalQueryStride: 1
            )
        case .segmentedMixed:
            return PairingConfiguration(
                temporalPairing: .linear,
                temporalOffsets: Array(1...6),
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 8,
                retrievalQueryStride: 1
            )
        case .orderedContinuous:
            return PairingConfiguration(
                temporalPairing: .multiscale,
                temporalOffsets: [1, 2, 4, 8, 16, 32, 64, 128],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 2,
                retrievalQueryStride: 10
            )
        case .orderedOrbit:
            return PairingConfiguration(
                temporalPairing: .multiscale,
                temporalOffsets: [1, 2, 4, 8, 16, 32, 64, 128],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 2,
                retrievalQueryStride: 5
            )
        case .orderedWalkthrough:
            return PairingConfiguration(
                temporalPairing: .linear,
                temporalOffsets: Array(1...6),
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 2,
                retrievalQueryStride: 10
            )
        case .orderedLargeArea:
            return PairingConfiguration(
                temporalPairing: .multiscale,
                temporalOffsets: [1, 2, 4, 8, 16, 32, 64, 128],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 4,
                retrievalQueryStride: 10
            )
        }
    }
}
