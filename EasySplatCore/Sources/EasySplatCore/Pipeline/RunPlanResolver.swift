import Foundation

/// Turns user intent and measured hardware into the fixed contract used by every pipeline stage.
public enum RunPlanResolver {
    public static let minimumHighDetailMemoryGB = 24.0
    public static let minimumReconstructionImageCount = 3

    public enum ValidationError: Error, LocalizedError, Equatable {
        case continuousMixedInputUnsupported
        case fastDetailRequired
        case highDetailRequiresMoreMemory
        case noValidPhotos
        case insufficientValidPhotos(actual: Int, minimum: Int)
        case photoSelectionExceedsSafeLimit(selected: Int, maximum: Int)

        public var errorDescription: String? {
            switch self {
            case .continuousMixedInputUnsupported:
                return "Continuous sequence can't combine videos and photos. Use Automatic or Unordered."
            case .fastDetailRequired:
                return "This Mac supports the Fast detail profile. Choose Fast to stay within its memory limit."
            case .highDetailRequiresMoreMemory:
                return "High Detail requires a Mac with at least 24 GB of unified memory. Choose Balanced or Fast."
            case .noValidPhotos:
                return "This folder has no readable photos. Choose JPEG, PNG, HEIC, HEIF, or a RAW format supported by macOS."
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
            throw ValidationError.continuousMixedInputUnsupported
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
        return !(input.hasVideos && input.hasPhotos)
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
        if !input.hasVideos {
            var inputRelevantPreviousPlan = previousPlan
            inputRelevantPreviousPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks =
                currentPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks
            if inputRelevantPreviousPlan == currentPlan {
                return lastCompletedStage
            }
        }
        let videoSourceAnalysisChanged = input.hasVideos
            && previousPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks
                != currentPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks
        let framePreparationChanged = previousPlan.keyframeBudget != currentPlan.keyframeBudget
            || previousPlan.maximumImageDimension != currentPlan.maximumImageDimension
            || previousPlan.analysisFrameRate != currentPlan.analysisFrameRate
            || videoSourceAnalysisChanged
            || previousPlan.photoSelection != currentPlan.photoSelection
            || previousPlan.capturePath != currentPlan.capturePath
        let geometryChanged = previousPlan.geometryBackend != currentPlan.geometryBackend
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
            || previousPlan.geometryWorkerBudget.featureExtractionWorkers
                != currentPlan.geometryWorkerBudget.featureExtractionWorkers
            || previousPlan.requiredToolchainCapabilities != currentPlan.requiredToolchainCapabilities
            || previousPlan.inputOrdering != currentPlan.inputOrdering
        let mappingPolicyChanged = previousPlan.baGlobalFramesRatio != currentPlan.baGlobalFramesRatio
            || previousPlan.baGlobalPointsRatio != currentPlan.baGlobalPointsRatio
            || previousPlan.baLocalMaxRefinements != currentPlan.baLocalMaxRefinements
            || previousPlan.baGlobalMaxRefinements != currentPlan.baGlobalMaxRefinements
            || previousPlan.baLocalMaxNumIterations != currentPlan.baLocalMaxNumIterations
            || previousPlan.baLocalFunctionTolerance != currentPlan.baLocalFunctionTolerance
            || previousPlan.baGlobalFunctionTolerance != currentPlan.baGlobalFunctionTolerance
            || previousPlan.baLocalImageCount != currentPlan.baLocalImageCount
        let matchingPolicyChanged = previousPlan.pairingPolicy != currentPlan.pairingPolicy
            || previousPlan.temporalPairing != currentPlan.temporalPairing
            || previousPlan.temporalOffsets != currentPlan.temporalOffsets
            || previousPlan.retrievalEngine != currentPlan.retrievalEngine
            || previousPlan.retrievalCandidateCount != currentPlan.retrievalCandidateCount
            || previousPlan.retrievalNeighborCount != currentPlan.retrievalNeighborCount
            || previousPlan.retrievalQueryStride != currentPlan.retrievalQueryStride
            || previousPlan.requiresCrossClipRetrieval
                != currentPlan.requiresCrossClipRetrieval
            || previousPlan.normalDescriptorMatcher != currentPlan.normalDescriptorMatcher
            || previousPlan.runSeed != currentPlan.runSeed
            || previousPlan.geometryWorkerBudget.coupledMatchingWorkers
                != currentPlan.geometryWorkerBudget.coupledMatchingWorkers
            || previousPlan.geometryWorkerBudget.vocabularyRetrievalWorkers
                != currentPlan.geometryWorkerBudget.vocabularyRetrievalWorkers
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

    /// The most posed images a dataset import may carry. Enforced at
    /// preflight with user-facing copy; re-clamped here so the resolved
    /// keyframe budget can never exceed it.
    public static let maximumDatasetImageCount = 1_000

    /// Ceiling on any single dataset image dimension, enforced at preflight.
    /// Keeps training-side pixel bounds and memory budgets meaningful.
    public static let maximumDatasetImagePixelDimension = 8_192

    /// Dataset facts the resolver needs without coupling to receipt storage.
    public struct DatasetImportContext: Sendable, Equatable {
        public let route: DatasetGeometryRoute
        public let imageCount: Int
        /// Largest single dimension across the dataset's images. Dataset
        /// pixels are never resized (imported calibration describes the
        /// original pixel grid), so the plan's image-dimension bound must
        /// admit them or training-prep validation would reject the run late.
        public let maximumImagePixelDimension: Int?

        public init(route: DatasetGeometryRoute, imageCount: Int, maximumImagePixelDimension: Int? = nil) {
            self.route = route
            self.imageCount = imageCount
            self.maximumImagePixelDimension = maximumImagePixelDimension
        }
    }

    public static func resolve(
        requestedOptions options: RequestedRunOptions,
        input: InputSpec,
        hardware: HardwareProfile,
        developmentOverrides: DevelopmentOverrides,
        trainingMemoryRetryBudgetBytes: Int64? = nil,
        datasetImport: DatasetImportContext? = nil
    ) -> ResolvedRunPlan {
        // Dataset imports made the pose/pairing decisions at capture time:
        // the capture-path knob is inert and ordering is canonically
        // unordered regardless of any stale request.
        let capturePath = input.isDataset ? .automatic : options.capturePath
        let inputOrdering = resolvedInputOrdering(options.inputOrdering, input: input)
        let pairingPolicy = resolvedPairingPolicy(
            capturePath: capturePath,
            requestedInputOrdering: options.inputOrdering,
            resolvedInputOrdering: inputOrdering,
            input: input
        )
        let pairingConfiguration = pairingConfiguration(for: pairingPolicy)
        let requiresCrossClipRetrieval = Self.requiresCrossClipRetrieval(
            requestedInputOrdering: options.inputOrdering,
            input: input
        )
        let baGlobalRatio: Double
        let baLocalMaxRefinements: Int
        switch pairingPolicy {
        case .unorderedRetrieval, .segmentedMixed:
            baGlobalRatio = 1.4
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
        let cameraGrouping = resolvedCameraGrouping(options.cameraGrouping, input: input)
        let lensProjection = options.lensProjection
        let route: SfmBackend
        if input.isDataset, datasetImport != nil {
            route = .importedPoses
        } else {
            route = developmentOverrides.candidateRoute ?? .colmap
        }
        let model = resolvedModel(route: route, memoryTier: memoryTier)
        let keyframeBudget: Int
        if let datasetImport, input.isDataset {
            // Every posed image must survive selection; the budget IS the
            // reconciled image count, bounded by the admission ceiling.
            keyframeBudget = min(max(datasetImport.imageCount, 1), maximumDatasetImageCount)
        } else if route == .da3 {
            keyframeBudget = 29
        } else {
            keyframeBudget = resolvedKeyframeBudget(
                detail: options.detailProfile,
                capturePath: capturePath,
                memoryTier: memoryTier,
                resourcePolicy: options.resourcePolicy
            )
        }
        var maximumImageDimension = resolvedMaximumImageDimension(
            detail: options.detailProfile,
            memoryTier: memoryTier,
            resourcePolicy: options.resourcePolicy
        )
        if input.isDataset, let datasetDimension = datasetImport?.maximumImagePixelDimension {
            // Dataset images pass through unscaled; the bound is a validation
            // ceiling for them, not a resize target.
            maximumImageDimension = min(
                max(maximumImageDimension, datasetDimension),
                maximumDatasetImagePixelDimension
            )
        }
        let colmapMaximumImageDimension = min(
            maximumImageDimension,
            resolvedColmapMaximumImageDimension(
                detail: options.detailProfile,
                memoryTier: memoryTier
            )
        )
        let trainerBudget = trainerBudget(for: options.detailProfile, memoryTier: memoryTier)
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
        let colmapBudget = resolvedColmapBudget(
            memoryTier: memoryTier,
            resourcePolicy: options.resourcePolicy
        )
        var geometryWorkerBudget = resolvedGeometryWorkerBudget(
            memoryGB: hardware.memoryGB,
            resourcePolicy: options.resourcePolicy,
            cpuCount: hardware.cpuCount
        )
        // Photo-only projects never launch video analysis. Resolve that unused
        // dimension to one worker so hardware changes cannot invalidate otherwise
        // reusable photo geometry.
        if !input.hasVideos {
            geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks = 1
        }

        return ResolvedRunPlan(
            geometryBackend: route,
            datasetGeometryRoute: input.isDataset ? datasetImport?.route : nil,
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
            cameraInitializationRecipe: ColmapCameraInitializationRecipe.resolve(
                lensProjection: lensProjection,
                cameraGrouping: cameraGrouping
            ),
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
            geometryWorkerBudget: geometryWorkerBudget,
            requiredToolchainCapabilities: requiredCapabilities(route: route, model: model),
            capturePath: capturePath,
            inputOrdering: inputOrdering,
            photoSelection: input.isDataset ? .useAllValidPhotos : options.photoSelection,
            pairingPolicy: pairingPolicy,
            temporalPairing: pairingConfiguration.temporalPairing,
            temporalOffsets: pairingConfiguration.temporalOffsets,
            retrievalEngine: .localSiftVocabularyV2,
            retrievalCandidateCount: pairingConfiguration.retrievalCandidateCount,
            retrievalNeighborCount: pairingConfiguration.retrievalNeighborCount,
            retrievalQueryStride: pairingConfiguration.retrievalQueryStride,
            requiresCrossClipRetrieval: requiresCrossClipRetrieval,
            normalDescriptorMatcher: .faiss,
            baGlobalFramesRatio: baGlobalRatio,
            baGlobalPointsRatio: baGlobalRatio,
            baLocalMaxRefinements: baLocalMaxRefinements,
            baGlobalMaxRefinements: 5,
            baLocalMaxNumIterations: 10,
            baLocalFunctionTolerance: 0.001,
            baGlobalFunctionTolerance: 0.000_001,
            baLocalImageCount: 6,
            runSeed: UInt64(max(0, developmentOverrides.benchmarkSeed ?? 42))
        )
    }

    private enum MemoryTier: String {
        case constrained
        case standard
        case performance
    }

    private static func resolvedInputOrdering(_ requested: InputOrdering, input: InputSpec) -> InputOrdering {
        // Datasets are canonically unordered regardless of any stale request:
        // pairing for imported poses must never assume capture continuity.
        if input.isDataset { return .unordered }
        guard requested == .automatic else { return requested }
        switch input {
        case .video(let files):
            return files.count == 1 ? .continuous : .unordered
        case .photos, .mixed, .dataset:
            return .unordered
        }
    }

    static func requiresCrossClipRetrieval(
        requestedInputOrdering: InputOrdering,
        input: InputSpec
    ) -> Bool {
        input.videoFiles.count > 1
            && !input.hasPhotos
            && requestedInputOrdering != .unordered
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
        if input.hasVideos && input.hasPhotos {
            return .segmentedMixed
        }
        if input.videoFiles.count > 1,
           requestedInputOrdering != .continuous {
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

    private static func resolvedModel(route: SfmBackend, memoryTier: MemoryTier) -> String {
        guard route == .da3 else { return "none" }
        return memoryTier == .constrained ? "DA3-SMALL" : "DA3-BASE"
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
        } else {
            // Fast stays a quick preview on every machine; only the quality
            // tiers spend the extra headroom on more keyframes.
            let tierScale = memoryTier == .performance && detail != .fast ? 1.4 : 1.0
            let policyScale = resourcePolicy == .maximumPerformance ? 1.2 : 1.0
            resourceScale = tierScale * policyScale
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
        let tierBase = memoryTier == .performance && detail == .balanced ? 1_920 : base
        guard resourcePolicy == .maximumPerformance else { return tierBase }
        return Int((Double(tierBase) * 1.125).rounded())
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

    // Persisted training manifests are validated against this closed set: every
    // tier-resolved tuple plus the fixed pre-tier values, so projects trained
    // before budgets scaled with hardware still load.
    static func sanctionedTrainerBudgets(
        for detail: DetailProfile
    ) -> [(iterations: Int, plateau: Int)] {
        let tiers: [MemoryTier] = [.constrained, .standard, .performance]
        var budgets = tiers.map { trainerBudget(for: detail, memoryTier: $0) }
        switch detail {
        case .fast:
            break
        case .balanced:
            budgets.append((7_000, 800))
        case .highDetail:
            budgets.append((15_000, 1_500))
        }
        return budgets
    }

    // Iteration limits are ceilings, not targets: the trainer's plateau detector is
    // the intended stop, and densification runs until iterationLimit / 2, so the
    // ceiling also bounds how far the gaussian count can grow.
    private static func trainerBudget(
        for detail: DetailProfile,
        memoryTier: MemoryTier
    ) -> (iterations: Int, plateau: Int) {
        switch (detail, memoryTier) {
        case (.fast, _): return (3_000, 400)
        case (.balanced, .constrained): return (12_000, 1_200)
        case (.balanced, .standard): return (20_000, 1_600)
        case (.balanced, .performance): return (30_000, 2_000)
        case (.highDetail, .constrained): return (20_000, 1_600)
        case (.highDetail, .standard): return (30_000, 2_000)
        case (.highDetail, .performance): return (40_000, 2_500)
        }
    }

    private static func resolvedColmapBudget(
        memoryTier: MemoryTier,
        resourcePolicy: ResourcePolicy
    ) -> (features: Int, matches: Int) {
        let values: (features: Int, matches: Int)
        switch memoryTier {
        case .constrained:
            values = (4_096, 4_096)
        case .standard:
            values = (8_192, 8_192)
        case .performance where resourcePolicy == .maximumPerformance:
            values = (12_000, 12_000)
        case .performance:
            values = (10_000, 10_000)
        }
        return values
    }

    private static func resolvedGeometryWorkerBudget(
        memoryGB: Double,
        resourcePolicy: ResourcePolicy,
        cpuCount: Int
    ) -> GeometryWorkerBudget {
        let logicalCPUs = max(1, cpuCount)
        let halfLogicalCPUs = max(1, logicalCPUs / 2)
        let caps: (
            extraction: Int,
            matching: Int,
            retrieval: Int,
            videoSourceAnalysis: Int
        )
        if resourcePolicy == .conserveMemory || memoryGB <= 8.5 {
            caps = (4, 4, 4, 2)
        } else if memoryGB <= 16.5 {
            // Extraction and matching are sequential stages. Measurements on the
            // constrained lane put these Pareto points well below its memory gate.
            caps = (12, 6, 6, 2)
        } else if resourcePolicy == .maximumPerformance {
            caps = (16, 8, 8, 4)
        } else if memoryGB <= 32 {
            caps = (12, 6, 6, 3)
        } else {
            caps = (12, 8, 8, 4)
        }

        return GeometryWorkerBudget(
            featureExtractionWorkers: min(logicalCPUs, caps.extraction),
            coupledMatchingWorkers: min(halfLogicalCPUs, caps.matching),
            vocabularyRetrievalWorkers: min(halfLogicalCPUs, caps.retrieval),
            maximumConcurrentVideoSourceAnalysisTasks: min(logicalCPUs, caps.videoSourceAnalysis),
            retrievalMemoryBudgetBytes: resolvedRetrievalMemoryBudget(
                memoryGB: memoryGB,
                resourcePolicy: resourcePolicy
            )
        )
    }

    /// Sizes the vocabulary retriever's memory ceiling to installed RAM. The
    /// native tool otherwise falls back to a fixed 2 GiB default, which a denser
    /// recovery retry can exceed on machines with far more memory to spare.
    private static func resolvedRetrievalMemoryBudget(
        memoryGB: Double,
        resourcePolicy: ResourcePolicy
    ) -> Int64 {
        guard memoryGB.isFinite, memoryGB > 0 else {
            return ColmapVocabularyRetrievalOptions.defaultMemoryBudgetBytes
        }
        let bytesPerGibibyte = 1_073_741_824.0
        let physicalBytesValue = (memoryGB * bytesPerGibibyte).rounded()
        let physicalMemoryBytes = physicalBytesValue >= Double(UInt64.max)
            ? UInt64.max
            : UInt64(physicalBytesValue)
        // Reuse the trainer's RAM-headroom and policy-fraction sizing, but ignore
        // the Metal working set: vocabulary retrieval runs entirely on the CPU, so
        // passing no Metal budget makes `resolve` fall back to physical headroom.
        let scaledBudget = TrainingMemoryBudget.resolve(
            physicalMemoryBytes: physicalMemoryBytes,
            recommendedMetalWorkingSetBytes: nil,
            resourcePolicy: resourcePolicy
        )
        let floored = max(scaledBudget, ColmapVocabularyRetrievalOptions.minimumMemoryBudgetBytes)
        return min(floored, ColmapVocabularyRetrievalOptions.maximumMemoryBudgetBytes)
    }

    private static func requiredCapabilities(route: SfmBackend, model: String) -> [String] {
        switch route {
        case .colmap, .importedPoses:
            // Imported poses still use COLMAP for features, matching,
            // triangulation, and undistortion.
            return ["geometry.colmap", "runtime.core", "training.msplat"]
        case .da3:
            let modelCapability = model == "DA3-SMALL"
                ? "geometry.da3.small"
                : "geometry.da3.base"
            return [
                modelCapability,
                "geometry.colmap",
                "geometry.da3.runtime",
                "runtime.core",
                "training.msplat",
            ].sorted()
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
