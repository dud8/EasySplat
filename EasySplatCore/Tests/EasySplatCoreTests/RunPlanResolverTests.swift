import Foundation
import XCTest
@testable import EasySplatCore

final class RunPlanResolverTests: XCTestCase {
    func testIncompleteRunPlanIsRejected() throws {
        let json = """
        {
          "routeIdentifier": "da3",
          "modelIdentifier": "DA3-BASE",
          "memoryTier": "performance",
          "chunkSize": 8,
          "keyframeBudget": 250,
          "maximumImageDimension": 1600,
          "cameraGrouping": "automatic",
          "lensProjection": "automatic",
          "refinementIterationLimit": 75,
          "trainerIterationLimit": 7000,
          "plateauWindow": 800,
          "requiredToolchainCapabilities": ["geometry.da3.base"],
          "fallbackRouteIdentifiers": ["colmap"]
        }
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(ResolvedRunPlan.self, from: Data(json.utf8))
        )
    }

    func testDefaultBalancedPhotoPlanUsesClassicalGeometryWithoutLearnedModels() throws {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.routeIdentifier, SfmBackend.colmap.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.memoryTier, "performance")
        XCTAssertEqual(plan.chunkSize, 0)
        XCTAssertEqual(plan.geometryProcessResolution, 0)
        XCTAssertEqual(plan.analysisFrameRate, 0)
        XCTAssertEqual(plan.keyframeBudget, 250)
        XCTAssertEqual(plan.maximumImageDimension, 1_600)
        XCTAssertEqual(plan.colmapMaximumImageDimension, 1_024)
        XCTAssertEqual(plan.capturePath, .automatic)
        XCTAssertEqual(plan.inputOrdering, .unordered)
        XCTAssertEqual(plan.pairingPolicy, .unorderedRetrieval)
        XCTAssertEqual(plan.temporalPairing, .none)
        XCTAssertEqual(plan.temporalOffsets, [])
        XCTAssertEqual(plan.retrievalEngine, .localSiftVocabularyV1)
        XCTAssertEqual(plan.retrievalCandidateCount, 20)
        XCTAssertEqual(plan.retrievalNeighborCount, 8)
        XCTAssertEqual(plan.retrievalQueryStride, 1)
        XCTAssertEqual(plan.normalDescriptorMatcher, .faiss)
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
        XCTAssertEqual(plan.lensProjection, .automatic)
        XCTAssertEqual(plan.trainerIterationLimit, 7_000)
        XCTAssertEqual(plan.plateauWindow, 800)
        XCTAssertEqual(plan.trainerMemoryBudgetBytes, 34_789_235_097)
        XCTAssertEqual(plan.colmapMaximumFeatureCount, 10_000)
        XCTAssertEqual(plan.colmapMaximumMatchCount, 10_000)
        XCTAssertEqual(plan.colmapThreadLimit, 8)
        XCTAssertEqual(plan.baGlobalFramesRatio, 1.1)
        XCTAssertEqual(plan.baGlobalPointsRatio, 1.1)
        XCTAssertEqual(plan.baGlobalMaxRefinements, 5)
        XCTAssertEqual(plan.deterministicSeed, 42)
        XCTAssertEqual(
            plan.requiredToolchainCapabilities,
            [
                "geometry.colmap",
                "runtime.core",
                "training.msplat",
            ]
        )
        XCTAssertEqual(plan.fallbackRouteIdentifiers, [])
        XCTAssertEqual(
            try plan.toolchainCapabilityRequest().capabilities,
            [.core, .colmap, .msplat]
        )
    }

    func testOrderedPlansUseLessFrequentGlobalBundleAdjustment() {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)

        for capturePath in [
            CapturePath.automatic,
            .orbit,
            .walkthrough,
            .largeArea,
        ] {
            let plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(
                    capturePath: capturePath,
                    inputOrdering: .continuous
                ),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: hardware,
                developmentOverrides: .none
            )

            XCTAssertEqual(plan.baGlobalFramesRatio, 1.4, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baGlobalPointsRatio, 1.4, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baGlobalMaxRefinements, 5, "capture path: \(capturePath)")
        }
    }

    func testLowMemoryAndConserveMemoryBoundClassicalBudgets() {
        let automatic8GB = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 6),
            developmentOverrides: .none
        )
        let automatic48GB = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let conserved48GB = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                detailProfile: .balanced,
                resourcePolicy: .conserveMemory
            ),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        for plan in [automatic8GB, conserved48GB] {
            XCTAssertEqual(plan.memoryTier, "constrained")
            XCTAssertEqual(plan.modelIdentifier, "none")
            XCTAssertEqual(plan.chunkSize, 0)
            XCTAssertEqual(plan.geometryProcessResolution, 0)
            XCTAssertEqual(plan.analysisFrameRate, 3)
            XCTAssertLessThan(plan.keyframeBudget, automatic48GB.keyframeBudget)
            XCTAssertLessThan(plan.maximumImageDimension, automatic48GB.maximumImageDimension)
            XCTAssertEqual(plan.colmapMaximumImageDimension, 1_024)
            XCTAssertEqual(plan.colmapMaximumFeatureCount, 4_096)
            XCTAssertEqual(plan.colmapMaximumMatchCount, 4_096)
            XCTAssertEqual(plan.colmapThreadLimit, 4)
        }
    }

    func testFastDefaultsToClassicalGeometryEvenOnLargeMemoryMac() throws {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .fast),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 64, cpuCount: 16, gpuWorkingSetGB: 48),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.routeIdentifier, SfmBackend.colmap.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.fallbackRouteIdentifiers, [])
        XCTAssertEqual(plan.cameraGrouping, .sameCameraAndLens)
        XCTAssertEqual(plan.lensProjection, .automatic)
        XCTAssertEqual(
            try plan.toolchainCapabilityRequest().capabilities,
            [.core, .colmap, .msplat]
        )
    }

    func testExplicitDa3CandidateUsesOneMeasuredCoherentBatch() throws {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )

        XCTAssertEqual(plan.routeIdentifier, SfmBackend.da3.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "DA3-BASE")
        XCTAssertEqual(plan.keyframeBudget, 29)
        XCTAssertEqual(plan.chunkSize, 29)
        XCTAssertEqual(plan.geometryProcessResolution, 336)
        XCTAssertEqual(plan.fallbackRouteIdentifiers, [])
        XCTAssertEqual(
            try plan.toolchainCapabilityRequest().capabilities,
            [.core, .colmap, .da3Runtime, .msplat, .da3Base, .da3Small]
        )
    }

    func testDA3CapturePathChangeInvalidatesVideoFrameSelection() {
        let input = InputSpec.video(files: ["/tmp/clip.mov"])
        let hardware = HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        )
        let automatic = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                capturePath: .automatic,
                detailProfile: .balanced
            ),
            input: input,
            hardware: hardware,
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        let orbit = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            input: input,
            hardware: hardware,
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )

        XCTAssertEqual(automatic.keyframeBudget, orbit.keyframeBudget)
        XCTAssertEqual(automatic.analysisFrameRate, orbit.analysisFrameRate)
        XCTAssertEqual(automatic.maximumImageDimension, orbit.maximumImageDimension)
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: input,
                previousPlan: automatic,
                currentPlan: orbit
            ),
            .importInput
        )
    }

    func testMaximumPerformanceNeverOverridesSixteenGBSafetyBoundary() {
        let constrained = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                detailProfile: .highDetail,
                resourcePolicy: .maximumPerformance
            ),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12),
            developmentOverrides: .none
        )
        let performance = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                detailProfile: .highDetail,
                resourcePolicy: .maximumPerformance
            ),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 24, cpuCount: 12, gpuWorkingSetGB: 18),
            developmentOverrides: .none
        )

        XCTAssertEqual(constrained.memoryTier, "constrained")
        XCTAssertEqual(constrained.modelIdentifier, "none")
        XCTAssertEqual(constrained.chunkSize, 0)
        XCTAssertEqual(performance.memoryTier, "performance")
        XCTAssertEqual(performance.modelIdentifier, "none")
        XCTAssertEqual(performance.chunkSize, 0)
        XCTAssertGreaterThan(performance.keyframeBudget, constrained.keyframeBudget)
        XCTAssertGreaterThan(performance.maximumImageDimension, constrained.maximumImageDimension)
        XCTAssertEqual(performance.colmapMaximumFeatureCount, 12_000)
        XCTAssertEqual(performance.colmapMaximumMatchCount, 12_000)
        XCTAssertEqual(performance.colmapThreadLimit, 10)
    }

    func testHighDetailRequiresTheFullNominalTwentyFourGBTier() {
        for memoryGB in [18.0, 23.0, 23.9] {
            XCTAssertFalse(RunPlanResolver.supports(detail: .highDetail, memoryGB: memoryGB))
            XCTAssertThrowsError(try RunPlanResolver.validate(
                requestedOptions: RequestedRunOptions(detailProfile: .highDetail),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(memoryGB: memoryGB, cpuCount: 12, gpuWorkingSetGB: 16)
            )) { error in
                XCTAssertEqual(error as? RunPlanResolver.ValidationError, .highDetailRequiresMoreMemory)
            }
        }

        XCTAssertTrue(RunPlanResolver.supports(detail: .highDetail, memoryGB: 24))
        for memoryGB in [18.0, 23.0] {
            let balancedPlan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(detailProfile: .balanced),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(memoryGB: memoryGB, cpuCount: 12, gpuWorkingSetGB: 14),
                developmentOverrides: .none
            )
            XCTAssertEqual(balancedPlan.modelIdentifier, "none")
        }
        let defensivePlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                detailProfile: .highDetail,
                resourcePolicy: .maximumPerformance
            ),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 18, cpuCount: 12, gpuWorkingSetGB: 14),
            developmentOverrides: .none
        )
        XCTAssertEqual(defensivePlan.modelIdentifier, "none")
    }

    func testMaximumPerformanceIsUnavailableThroughTheConstrainedMemoryBoundary() {
        XCTAssertFalse(RunPlanResolver.supports(resourcePolicy: .maximumPerformance, memoryGB: 8))
        XCTAssertFalse(RunPlanResolver.supports(resourcePolicy: .maximumPerformance, memoryGB: 16))
        XCTAssertFalse(RunPlanResolver.supports(resourcePolicy: .maximumPerformance, memoryGB: 16.5))
        XCTAssertTrue(RunPlanResolver.supports(resourcePolicy: .maximumPerformance, memoryGB: 24))

        XCTAssertTrue(RunPlanResolver.supports(resourcePolicy: .automatic, memoryGB: 8))
        XCTAssertTrue(RunPlanResolver.supports(resourcePolicy: .conserveMemory, memoryGB: 8))

        let hardware = HardwareProfile(memoryGB: 16.5, cpuCount: 10, gpuWorkingSetGB: 16.5)
        let automatic = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(resourcePolicy: .automatic),
            input: .video(files: ["/tmp/one.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let maximum = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(resourcePolicy: .maximumPerformance),
            input: .video(files: ["/tmp/one.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        XCTAssertEqual(maximum, automatic)
        XCTAssertEqual(automatic.trainerMemoryBudgetBytes, 12 * 1_073_741_824)
    }

    func testContinuousOrderingIsUnavailableForSeparateClipsAndMixedInput() {
        XCTAssertTrue(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .video(files: ["/tmp/one.mov"])
        ))
        XCTAssertTrue(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .photos(folder: "/tmp/photos")
        ))
        XCTAssertFalse(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"])
        ))
        XCTAssertFalse(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .mixed(videos: ["/tmp/one.mov"], photosFolder: "/tmp/photos")
        ))
    }

    func testHardwareValidationRejectsUnsafeDetailProfilesBeforeProjectCreation() {
        XCTAssertThrowsError(try RunPlanResolver.validate(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 6)
        )) { error in
            XCTAssertEqual(error as? RunPlanResolver.ValidationError, .fastDetailRequired)
        }
        XCTAssertThrowsError(try RunPlanResolver.validate(
            requestedOptions: RequestedRunOptions(detailProfile: .highDetail),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12)
        )) { error in
            XCTAssertEqual(error as? RunPlanResolver.ValidationError, .highDetailRequiresMoreMemory)
        }
        XCTAssertNoThrow(try RunPlanResolver.validate(
            requestedOptions: RequestedRunOptions(detailProfile: .highDetail),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 24, cpuCount: 12, gpuWorkingSetGB: 18)
        ))
    }

    func testCapturePathChangesOrderedPairingAndKeyframePolicy() {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let orbit = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(capturePath: .orbit),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let walkthrough = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(capturePath: .walkthrough),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let largeArea = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(capturePath: .largeArea),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )

        XCTAssertEqual(orbit.pairingPolicy, .orderedOrbit)
        XCTAssertEqual(walkthrough.pairingPolicy, .orderedWalkthrough)
        XCTAssertEqual(largeArea.pairingPolicy, .orderedLargeArea)
        XCTAssertLessThan(orbit.keyframeBudget, walkthrough.keyframeBudget)
        XCTAssertGreaterThan(largeArea.keyframeBudget, walkthrough.keyframeBudget)
        XCTAssertEqual(orbit.temporalPairing, .multiscale)
        XCTAssertEqual(orbit.temporalOffsets, [1, 2, 4, 8, 16, 32, 64, 128])
        XCTAssertEqual(orbit.retrievalQueryStride, 5)
        XCTAssertEqual(orbit.retrievalNeighborCount, 2)
        XCTAssertEqual(walkthrough.temporalPairing, .linear)
        XCTAssertEqual(walkthrough.temporalOffsets, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(walkthrough.retrievalQueryStride, 10)
        XCTAssertEqual(walkthrough.retrievalNeighborCount, 2)
        XCTAssertEqual(largeArea.temporalPairing, .multiscale)
        XCTAssertEqual(largeArea.temporalOffsets, [1, 2, 4, 8, 16, 32, 64, 128])
        XCTAssertEqual(largeArea.retrievalQueryStride, 10)
        XCTAssertEqual(largeArea.retrievalNeighborCount, 4)
    }

    func testAutomaticOrderingDoesNotPretendSeparateClipsAreOneContinuousCapture() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .video(files: ["/tmp/first.mov", "/tmp/second.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.inputOrdering, .unordered)
        XCTAssertEqual(plan.pairingPolicy, .segmentedMixed)
        XCTAssertEqual(plan.temporalPairing, .linear)
        XCTAssertEqual(plan.temporalOffsets, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(plan.retrievalCandidateCount, 20)
        XCTAssertEqual(plan.retrievalNeighborCount, 8)
        XCTAssertEqual(plan.retrievalQueryStride, 1)
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
        XCTAssertEqual(plan.baGlobalFramesRatio, 1.1)
        XCTAssertEqual(plan.baGlobalPointsRatio, 1.1)

        let mixedPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .mixed(videos: ["/tmp/clip.mov"], photosFolder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        XCTAssertEqual(mixedPlan.pairingPolicy, .segmentedMixed)
        XCTAssertEqual(mixedPlan.temporalPairing, .linear)
        XCTAssertEqual(mixedPlan.temporalOffsets, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(mixedPlan.baGlobalFramesRatio, 1.1)
        XCTAssertEqual(mixedPlan.baGlobalPointsRatio, 1.1)
    }

    func testAutomaticSingleVideoUsesNeutralContinuousPolicyWithoutInventingCaptureIntent() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.capturePath, .automatic)
        XCTAssertEqual(plan.inputOrdering, .continuous)
        XCTAssertEqual(plan.pairingPolicy, .orderedContinuous)
        XCTAssertEqual(plan.temporalPairing, .multiscale)
        XCTAssertEqual(plan.temporalOffsets, [1, 2, 4, 8, 16, 32, 64, 128])
        XCTAssertEqual(plan.retrievalCandidateCount, 20)
        XCTAssertEqual(plan.retrievalNeighborCount, 2)
        XCTAssertEqual(plan.retrievalQueryStride, 10)
        XCTAssertEqual(plan.lensProjection, .automatic)
    }

    func testExplicitUnorderedInputDisablesAllTemporalAssumptions() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .unordered),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.pairingPolicy, .unorderedRetrieval)
        XCTAssertEqual(plan.temporalPairing, .none)
        XCTAssertEqual(plan.temporalOffsets, [])
        XCTAssertEqual(plan.retrievalQueryStride, 1)
        XCTAssertEqual(plan.retrievalNeighborCount, 8)
    }

    func testExplicitCandidateRouteIsStrictAndBenchmarkSeedIsPersistedInPlan() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                cameraGrouping: .mixedCamerasOrLenses,
                lensProjection: .fisheye,
                inputOrdering: .continuous
            ),
            input: .mixed(videos: ["/tmp/clip.mov"], photosFolder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .colmap, benchmarkSeed: 99)
        )

        XCTAssertEqual(plan.routeIdentifier, SfmBackend.colmap.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.fallbackRouteIdentifiers, [])
        XCTAssertEqual(plan.requiredToolchainCapabilities, ["geometry.colmap", "runtime.core", "training.msplat"])
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
        XCTAssertEqual(plan.lensProjection, .fisheye)
        XCTAssertEqual(plan.inputOrdering, .continuous)
        XCTAssertEqual(plan.deterministicSeed, 99)
    }

    func testResolvedPlanConvertsEveryPersistedCapabilityToTypedInstallerRequest() throws {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        let request = try plan.toolchainCapabilityRequest()

        XCTAssertEqual(
            request.capabilities,
            [.core, .colmap, .msplat]
        )

        var corrupt = plan
        corrupt.requiredToolchainCapabilities.append("geometry.unknown")
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .unknownToolchainCapability("geometry.unknown")
            )
        }

        corrupt = plan
        corrupt.routeIdentifier = "geometry.unknown"
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .unknownRouteIdentifier("geometry.unknown")
            )
        }

        corrupt = plan
        corrupt.fallbackRouteIdentifiers = [SfmBackend.colmap.rawValue, "geometry.unknown"]
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .unknownRouteIdentifier("geometry.unknown")
            )
        }
    }

    func testResolvedPlanPersistsBeforeImportProcessCompletes() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Plan.easysplatproj", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source.appendingPathComponent("one.jpg"),
            size: 16,
            value: 32,
            utType: .jpeg
        ))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let options = RequestedRunOptions(
            capturePath: .largeArea,
            detailProfile: .fast,
            cameraGrouping: .sameCameraAndLens,
            lensProjection: .perspective,
            inputOrdering: .unordered,
            resourcePolicy: .conserveMemory,
            photoSelection: .useAllValidPhotos
        )
        let metadata = ProjectMetadata(
            title: "Plan",
            input: .photos(folder: source.path),
            requestedRunOptions: options
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = TestToolchains.toolchainPaths(root: root)
        let runner = PipelineRunner(
            projectURL: projectURL,
            config: .init(
                toolchain: toolchain,
                developmentOverrides: .init(stopAfterStage: .importInput, benchmarkSeed: 7)
            )
        )

        try await runner.run { _ in }

        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        let plan = try XCTUnwrap(saved.resolvedRunPlan)
        XCTAssertEqual(plan.capturePath, .largeArea)
        XCTAssertEqual(plan.routeIdentifier, SfmBackend.colmap.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.photoSelection, .useAllValidPhotos)
        XCTAssertEqual(plan.deterministicSeed, 7)
        XCTAssertEqual(saved.state.stage, .importInput)
        XCTAssertNil(saved.lastRunStartedAt)
    }

    func testUseAllValidPhotosExposesItsSafeLimitBeforeSetup() throws {
        let input = InputSpec.photos(folder: "/tmp/photos")
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                detailProfile: .fast,
                resourcePolicy: .conserveMemory,
                photoSelection: .useAllValidPhotos
            ),
            input: input,
            hardware: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12),
            developmentOverrides: .none
        )

        XCTAssertEqual(RunPlanResolver.maximumValidPhotoCount(for: plan), plan.keyframeBudget)
        XCTAssertNoThrow(
            try RunPlanResolver.validatePhotoSelection(
                validPhotoCount: plan.keyframeBudget,
                resolvedPlan: plan
            )
        )
        XCTAssertThrowsError(
            try RunPlanResolver.validatePhotoSelection(
                validPhotoCount: plan.keyframeBudget + 1,
                resolvedPlan: plan
            )
        ) { error in
            XCTAssertEqual(
                error as? RunPlanResolver.ValidationError,
                .photoSelectionExceedsSafeLimit(
                    selected: plan.keyframeBudget + 1,
                    maximum: plan.keyframeBudget
                )
            )
        }
    }

    func testMixedUseAllPhotoLimitReservesOneQuarterOfPlanForVideo() throws {
        let input = InputSpec.mixed(
            videos: ["/tmp/walkthrough.mov"],
            photosFolder: "/tmp/photos"
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                detailProfile: .fast,
                resourcePolicy: .conserveMemory,
                photoSelection: .useAllValidPhotos
            ),
            input: input,
            hardware: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12),
            developmentOverrides: .none
        )
        let maximum = try XCTUnwrap(
            RunPlanResolver.maximumValidPhotoCount(for: plan, input: input)
        )

        XCTAssertEqual(maximum, plan.keyframeBudget - max(2, plan.keyframeBudget / 4))
        XCTAssertNoThrow(try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: maximum,
            resolvedPlan: plan,
            input: input
        ))
        XCTAssertThrowsError(try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: maximum + 1,
            resolvedPlan: plan,
            input: input
        )) { error in
            XCTAssertEqual(
                error as? RunPlanResolver.ValidationError,
                .photoSelectionExceedsSafeLimit(selected: maximum + 1, maximum: maximum)
            )
        }
    }

    func testPhotoPreflightRejectsNoValidPhotos() {
        XCTAssertThrowsError(try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: 0,
            resolvedPlan: RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(),
                input: .photos(folder: "/tmp/photos"),
                hardware: HardwareProfile(memoryGB: 24, cpuCount: 12, gpuWorkingSetGB: 18),
                developmentOverrides: .none
            ),
            input: .photos(folder: "/tmp/photos")
        )) { error in
            XCTAssertEqual(error as? RunPlanResolver.ValidationError, .noValidPhotos)
        }
    }

    func testMixedInputAllowsNoValidPhotosWhenVideoRemains() {
        let input = InputSpec.mixed(
            videos: ["/tmp/walkthrough.mov"],
            photosFolder: "/tmp/photos"
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: input,
            hardware: HardwareProfile(memoryGB: 24, cpuCount: 12, gpuWorkingSetGB: 18),
            developmentOverrides: .none
        )

        XCTAssertNoThrow(try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: 0,
            resolvedPlan: plan,
            input: input
        ))
    }

    func testAutomaticPhotoSelectionHasNoPreflightPhotoLimit() throws {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(photoSelection: .automatic),
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 6),
            developmentOverrides: .none
        )

        XCTAssertNil(RunPlanResolver.maximumValidPhotoCount(for: plan))
        XCTAssertNoThrow(
            try RunPlanResolver.validatePhotoSelection(
                validPhotoCount: 50_000,
                resolvedPlan: plan
            )
        )
    }

    func testChangedRunPlanRestartsAtTheSafeFrameBoundary() {
        let options = RequestedRunOptions(detailProfile: .balanced)
        let video = InputSpec.video(files: ["/tmp/clip.mov"])
        let photos = InputSpec.photos(folder: "/tmp/photos")
        let oldPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: video,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let currentVideoPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: video,
            hardware: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12),
            developmentOverrides: .none
        )
        let currentPhotoPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: photos,
            hardware: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12),
            developmentOverrides: .none
        )

        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: video,
                previousPlan: oldPlan,
                currentPlan: currentVideoPlan
            ),
            .importInput
        )
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: photos,
                previousPlan: oldPlan,
                currentPlan: currentPhotoPlan
            ),
            .extractFrames
        )
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .importInput,
                input: photos,
                previousPlan: oldPlan,
                currentPlan: currentPhotoPlan
            ),
            .importInput
        )
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: currentVideoPlan
            ),
            .trainSplat
        )
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: video,
                previousPlan: nil,
                currentPlan: currentVideoPlan
            ),
            .trainSplat
        )

        var geometryPlan = currentVideoPlan
        geometryPlan.colmapMaximumFeatureCount += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: geometryPlan
            ),
            .selectFrames
        )

        var frameRatePlan = currentVideoPlan
        frameRatePlan.analysisFrameRate += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: frameRatePlan
            ),
            .importInput
        )

        var capturePathPlan = currentVideoPlan
        capturePathPlan.capturePath = .orbit
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: capturePathPlan
            ),
            .importInput
        )

        var geometryResolutionPlan = currentVideoPlan
        geometryResolutionPlan.colmapMaximumImageDimension -= 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .trainSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: geometryResolutionPlan
            ),
            .selectFrames
        )

        var trainingPlan = currentVideoPlan
        trainingPlan.trainerIterationLimit += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: trainingPlan
            ),
            .sfmMapping
        )

        var memoryPlan = currentVideoPlan
        memoryPlan.trainerMemoryBudgetBytes -= 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: memoryPlan
            ),
            .sfmMapping
        )

        var mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.baGlobalFramesRatio = 1.5
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmFeatures
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.baGlobalPointsRatio = 1.5
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmFeatures
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.baGlobalMaxRefinements = 4
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmFeatures
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.deterministicSeed = 43
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmFeatures
        )
    }
}
