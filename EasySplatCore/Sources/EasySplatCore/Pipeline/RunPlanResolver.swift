import Foundation

/// Turns user intent and measured hardware into the fixed contract used by every pipeline stage.
public enum RunPlanResolver {
    public enum ValidationError: Error, LocalizedError, Equatable {
        case continuousMultipleClipsUnsupported

        public var errorDescription: String? {
            switch self {
            case .continuousMultipleClipsUnsupported:
                return "Continuous sequence currently supports one video clip. Use Automatic or Unordered for separate clips."
            }
        }
    }

    public static func validate(requestedOptions: RequestedRunOptions, input: InputSpec) throws {
        guard requestedOptions.inputOrdering == .continuous else { return }
        if input.videoFiles.count > 1 || (input.hasVideos && input.hasPhotos) {
            throw ValidationError.continuousMultipleClipsUnsupported
        }
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

    static func resolve(
        requestedOptions options: RequestedRunOptions,
        input: InputSpec,
        hardware: HardwareProfile,
        developmentOverrides: DevelopmentOverrides
    ) -> ResolvedRunPlan {
        let capturePath = options.capturePath
        let inputOrdering = resolvedInputOrdering(options.inputOrdering, input: input)
        let pairingPolicy = resolvedPairingPolicy(
            capturePath: capturePath,
            inputOrdering: inputOrdering
        )
        let memoryTier = resolvedMemoryTier(
            resourcePolicy: options.resourcePolicy,
            memoryGB: hardware.memoryGB
        )
        let route = developmentOverrides.candidateRoute ?? .da3
        let model = resolvedModel(
            route: route,
            detail: options.detailProfile,
            resourcePolicy: options.resourcePolicy,
            memoryGB: hardware.memoryGB
        )
        let keyframeBudget = resolvedKeyframeBudget(
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
        let trainerBudget = trainerBudget(for: options.detailProfile)
        let cameraGrouping = resolvedCameraGrouping(options.cameraGrouping, input: input)
        let lensProjection = options.lensProjection

        return ResolvedRunPlan(
            routeIdentifier: route.rawValue,
            modelIdentifier: model,
            memoryTier: memoryTier.rawValue,
            chunkSize: resolvedChunkSize(
                memoryTier: memoryTier,
                resourcePolicy: options.resourcePolicy
            ),
            keyframeBudget: keyframeBudget,
            maximumImageDimension: maximumImageDimension,
            cameraGrouping: cameraGrouping,
            lensProjection: lensProjection,
            refinementIterationLimit: resolvedRefinementLimit(
                detail: options.detailProfile,
                capturePath: capturePath,
                memoryTier: memoryTier
            ),
            trainerIterationLimit: trainerBudget.iterations,
            plateauWindow: trainerBudget.plateau,
            requiredToolchainCapabilities: requiredCapabilities(route: route, model: model),
            fallbackRouteIdentifiers: developmentOverrides.candidateRoute == nil
                ? [SfmBackend.colmap.rawValue]
                : [],
            capturePath: capturePath,
            inputOrdering: inputOrdering,
            photoSelection: options.photoSelection,
            pairingPolicy: pairingPolicy,
            sequentialOverlap: sequentialOverlap(for: pairingPolicy),
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
        inputOrdering: InputOrdering
    ) -> ResolvedPairingPolicy {
        guard inputOrdering == .continuous else { return .unorderedRetrieval }
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
        memoryGB: Double
    ) -> MemoryTier {
        if memoryGB <= 16 { return .constrained }
        switch resourcePolicy {
        case .conserveMemory:
            return .constrained
        case .maximumPerformance:
            return .performance
        case .automatic:
            return memoryGB <= 32 ? .standard : .performance
        }
    }

    private static func resolvedModel(
        route: SfmBackend,
        detail: DetailProfile,
        resourcePolicy: ResourcePolicy,
        memoryGB: Double
    ) -> String {
        guard route == .da3 else { return "none" }
        if detail == .fast || resourcePolicy == .conserveMemory || memoryGB <= 16 {
            return "DA3-SMALL"
        }
        return "DA3-BASE"
    }

    private static func resolvedChunkSize(
        memoryTier: MemoryTier,
        resourcePolicy: ResourcePolicy
    ) -> Int {
        switch memoryTier {
        case .constrained:
            return 4
        case .standard:
            return 6
        case .performance:
            return resourcePolicy == .maximumPerformance ? 10 : 8
        }
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

    private static func sequentialOverlap(for policy: ResolvedPairingPolicy) -> Int {
        switch policy {
        case .unorderedRetrieval: return 0
        case .orderedContinuous: return 12
        case .orderedOrbit: return 12
        case .orderedWalkthrough: return 10
        case .orderedLargeArea: return 24
        }
    }
}
