import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class RunPlanResolverTests: XCTestCase {
    func testGeometryWorkerBudgetSeparatesStagesAcrossHardwarePolicies() {
        struct Fixture {
            let memoryGB: Double
            let cpuCount: Int
            let resourcePolicy: ResourcePolicy
            let expected: GeometryWorkerBudget
        }

        let fixtures = [
            Fixture(
                memoryGB: 8,
                cpuCount: 8,
                resourcePolicy: .automatic,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 4,
                    coupledMatchingWorkers: 4,
                    vocabularyRetrievalWorkers: 4,
                    maximumConcurrentVideoSourceAnalysisTasks: 2
                )
            ),
            Fixture(
                memoryGB: 16,
                cpuCount: 10,
                resourcePolicy: .automatic,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 10,
                    coupledMatchingWorkers: 5,
                    vocabularyRetrievalWorkers: 5,
                    maximumConcurrentVideoSourceAnalysisTasks: 2
                )
            ),
            Fixture(
                memoryGB: 16,
                cpuCount: 12,
                resourcePolicy: .automatic,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 12,
                    coupledMatchingWorkers: 6,
                    vocabularyRetrievalWorkers: 6,
                    maximumConcurrentVideoSourceAnalysisTasks: 2
                )
            ),
            Fixture(
                memoryGB: 16,
                cpuCount: 12,
                resourcePolicy: .maximumPerformance,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 12,
                    coupledMatchingWorkers: 6,
                    vocabularyRetrievalWorkers: 6,
                    maximumConcurrentVideoSourceAnalysisTasks: 2
                )
            ),
            Fixture(
                memoryGB: 24,
                cpuCount: 12,
                resourcePolicy: .automatic,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 12,
                    coupledMatchingWorkers: 6,
                    vocabularyRetrievalWorkers: 6,
                    maximumConcurrentVideoSourceAnalysisTasks: 3
                )
            ),
            Fixture(
                memoryGB: 48,
                cpuCount: 16,
                resourcePolicy: .automatic,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 12,
                    coupledMatchingWorkers: 8,
                    vocabularyRetrievalWorkers: 8,
                    maximumConcurrentVideoSourceAnalysisTasks: 4
                )
            ),
            Fixture(
                memoryGB: 48,
                cpuCount: 16,
                resourcePolicy: .maximumPerformance,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 16,
                    coupledMatchingWorkers: 8,
                    vocabularyRetrievalWorkers: 8,
                    maximumConcurrentVideoSourceAnalysisTasks: 4
                )
            ),
            Fixture(
                memoryGB: 48,
                cpuCount: 16,
                resourcePolicy: .conserveMemory,
                expected: GeometryWorkerBudget(
                    featureExtractionWorkers: 4,
                    coupledMatchingWorkers: 4,
                    vocabularyRetrievalWorkers: 4,
                    maximumConcurrentVideoSourceAnalysisTasks: 2
                )
            ),
        ]

        for fixture in fixtures {
            let plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(
                    detailProfile: .balanced,
                    resourcePolicy: fixture.resourcePolicy
                ),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(
                    memoryGB: fixture.memoryGB,
                    cpuCount: fixture.cpuCount,
                    gpuWorkingSetGB: nil
                ),
                developmentOverrides: .none
            )

            let budget = plan.geometryWorkerBudget
            let context = "\(fixture.memoryGB) GB, \(fixture.cpuCount) CPUs, \(fixture.resourcePolicy)"
            XCTAssertEqual(budget.featureExtractionWorkers, fixture.expected.featureExtractionWorkers, context)
            XCTAssertEqual(budget.coupledMatchingWorkers, fixture.expected.coupledMatchingWorkers, context)
            XCTAssertEqual(budget.vocabularyRetrievalWorkers, fixture.expected.vocabularyRetrievalWorkers, context)
            XCTAssertEqual(
                budget.maximumConcurrentVideoSourceAnalysisTasks,
                fixture.expected.maximumConcurrentVideoSourceAnalysisTasks,
                context
            )
        }
    }

    func testRetrievalMemoryBudgetScalesWithInstalledRAM() {
        func resolvedRetrievalBudget(memoryGB: Double, policy: ResourcePolicy) -> Int64 {
            RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(detailProfile: .balanced, resourcePolicy: policy),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(memoryGB: memoryGB, cpuCount: 16, gpuWorkingSetGB: nil),
                developmentOverrides: .none
            ).geometryWorkerBudget.retrievalMemoryBudgetBytes
        }

        let lowerBound = ColmapVocabularyRetrievalOptions.minimumMemoryBudgetBytes
        let upperBound = ColmapVocabularyRetrievalOptions.maximumMemoryBudgetBytes
        let failedDefault = ColmapVocabularyRetrievalOptions.defaultMemoryBudgetBytes

        for memoryGB in [16.0, 48.0, 64.0] {
            let budget = resolvedRetrievalBudget(memoryGB: memoryGB, policy: .automatic)
            XCTAssertGreaterThanOrEqual(budget, lowerBound, "\(memoryGB) GB budget below the tool floor")
            XCTAssertLessThanOrEqual(budget, upperBound, "\(memoryGB) GB budget above the tool ceiling")
            // The reported failure hard-capped retrieval at the 2 GiB default; a
            // machine-scaled budget must clear it comfortably on any modern Mac.
            XCTAssertGreaterThan(
                budget, failedDefault,
                "\(memoryGB) GB should exceed the old fixed 2 GiB default"
            )
        }

        // More RAM never yields a smaller ceiling.
        XCTAssertGreaterThanOrEqual(
            resolvedRetrievalBudget(memoryGB: 64, policy: .automatic),
            resolvedRetrievalBudget(memoryGB: 16, policy: .automatic)
        )
    }

    func testIncompleteRunPlanIsRejected() throws {
        let json = """
        {
          "geometryBackend": "da3",
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
          "requiredToolchainCapabilities": ["geometry.da3.base"]
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

        XCTAssertEqual(plan.geometryBackend, .colmap)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.memoryTier, "performance")
        XCTAssertEqual(plan.chunkSize, 0)
        XCTAssertEqual(plan.geometryProcessResolution, 0)
        XCTAssertEqual(plan.analysisFrameRate, 0)
        XCTAssertEqual(plan.keyframeBudget, 350)
        XCTAssertEqual(plan.maximumImageDimension, 1_920)
        XCTAssertEqual(plan.colmapMaximumImageDimension, 1_232)
        XCTAssertEqual(plan.capturePath, .automatic)
        XCTAssertEqual(plan.inputOrdering, .unordered)
        XCTAssertEqual(plan.pairingPolicy, .unorderedRetrieval)
        XCTAssertEqual(plan.temporalPairing, .none)
        XCTAssertEqual(plan.temporalOffsets, [])
        XCTAssertEqual(plan.retrievalEngine, .localSiftVocabularyV2)
        XCTAssertEqual(plan.retrievalCandidateCount, 20)
        XCTAssertEqual(plan.retrievalNeighborCount, 8)
        XCTAssertEqual(plan.retrievalQueryStride, 1)
        XCTAssertEqual(plan.normalDescriptorMatcher, .faiss)
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
        XCTAssertEqual(plan.lensProjection, .automatic)
        XCTAssertEqual(plan.trainerIterationLimit, 30_000)
        XCTAssertEqual(plan.plateauWindow, 2_000)
        XCTAssertEqual(plan.trainerMemoryBudgetBytes, 34_789_235_097)
        XCTAssertEqual(plan.colmapMaximumFeatureCount, 10_000)
        XCTAssertEqual(plan.colmapMaximumMatchCount, 10_000)
        XCTAssertEqual(plan.geometryWorkerBudget.featureExtractionWorkers, 12)
        XCTAssertEqual(plan.geometryWorkerBudget.coupledMatchingWorkers, 8)
        XCTAssertEqual(plan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks, 1)
        XCTAssertEqual(plan.baGlobalFramesRatio, 1.4)
        XCTAssertEqual(plan.baGlobalPointsRatio, 1.4)
        XCTAssertEqual(plan.baLocalMaxRefinements, 2)
        XCTAssertEqual(plan.baGlobalMaxRefinements, 5)
        XCTAssertEqual(plan.baLocalMaxNumIterations, 10)
        XCTAssertEqual(plan.baLocalFunctionTolerance, 0.001)
        XCTAssertEqual(plan.baGlobalFunctionTolerance, 0.000_001)
        XCTAssertEqual(plan.baLocalImageCount, 6)
        XCTAssertEqual(plan.runSeed, 42)
        XCTAssertEqual(plan.incrementalMappingCadence, .balancedGlobal)
        XCTAssertEqual(
            plan.requiredToolchainCapabilities,
            [
                "geometry.colmap",
                "runtime.core",
                "training.msplat",
            ]
        )
        XCTAssertEqual(
            try plan.toolchainCapabilityRequest().capabilities,
            [.core, .colmap, .msplat]
        )
    }

    func testResolvedPlanPersistsOneTypedBackendWithoutAnArbitraryFallbackList() throws {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )

        XCTAssertEqual(object["geometryBackend"] as? String, SfmBackend.colmap.rawValue)
        XCTAssertNil(object["routeIdentifier"])
        XCTAssertNil(object["fallbackRouteIdentifiers"])
    }

    func testOrderedPlansUseMeasuredFastMappingCadence() {
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

            XCTAssertEqual(plan.baGlobalFramesRatio, 4, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baGlobalPointsRatio, 4, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baLocalMaxRefinements, 1, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baGlobalMaxRefinements, 5, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baLocalMaxNumIterations, 10, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baLocalFunctionTolerance, 0.001, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baGlobalFunctionTolerance, 0.000_001, "capture path: \(capturePath)")
            XCTAssertEqual(plan.baLocalImageCount, 6, "capture path: \(capturePath)")
            XCTAssertEqual(
                plan.incrementalMappingCadence,
                .orderedFast,
                "capture path: \(capturePath)"
            )
        }
    }

    func testNamedIncrementalMappingCadencesPreserveMeasuredPolicies() {
        let cases: [(IncrementalMappingCadenceArtifact, Double, Int)] = [
            (.orderedFast, 4, 1),
            (.balancedGlobal, 1.4, 2),
            (.frequentGlobal, 1.1, 2),
        ]

        for (cadence, expectedGlobalRatio, expectedLocalRefinements) in cases {
            XCTAssertEqual(cadence.globalFramesRatio, expectedGlobalRatio)
            XCTAssertEqual(cadence.globalPointsRatio, expectedGlobalRatio)
            XCTAssertEqual(cadence.localMaxRefinements, expectedLocalRefinements)
            XCTAssertEqual(cadence.globalMaxRefinements, 5)
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
            XCTAssertEqual(plan.geometryWorkerBudget.coupledMatchingWorkers, 4)
        }
    }

    func testTrainerBudgetScalesWithMemoryTier() {
        let cases: [(DetailProfile, ResourcePolicy, Double, String, Int, Int)] = [
            (.fast, .automatic, 8, "constrained", 3_000, 400),
            (.fast, .automatic, 48, "performance", 3_000, 400),
            (.balanced, .automatic, 16, "constrained", 12_000, 1_200),
            (.balanced, .automatic, 24, "standard", 20_000, 1_600),
            (.balanced, .automatic, 48, "performance", 30_000, 2_000),
            (.highDetail, .conserveMemory, 48, "constrained", 20_000, 1_600),
            (.highDetail, .automatic, 24, "standard", 30_000, 2_000),
            (.highDetail, .automatic, 48, "performance", 40_000, 2_500),
        ]

        for (detail, resourcePolicy, memoryGB, memoryTier, iterations, plateau) in cases {
            let plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(
                    detailProfile: detail,
                    resourcePolicy: resourcePolicy
                ),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(memoryGB: memoryGB, cpuCount: 16, gpuWorkingSetGB: 12),
                developmentOverrides: .none
            )

            let caseName = "\(detail), \(resourcePolicy), \(memoryGB) GB"
            XCTAssertEqual(plan.memoryTier, memoryTier, caseName)
            XCTAssertEqual(plan.trainerIterationLimit, iterations, caseName)
            XCTAssertEqual(plan.plateauWindow, plateau, caseName)
        }
    }

    func testColmapImageDimensionFollowsDetailAndMemoryTier() {
        let cases: [(DetailProfile, ResourcePolicy, Double, String, Int)] = [
            (.fast, .automatic, 8, "constrained", 960),
            (.fast, .automatic, 24, "standard", 1_024),
            (.fast, .automatic, 48, "performance", 1_024),
            (.balanced, .automatic, 16, "constrained", 1_024),
            (.balanced, .automatic, 24, "standard", 1_024),
            (.balanced, .automatic, 48, "performance", 1_232),
            (.highDetail, .conserveMemory, 48, "constrained", 1_280),
            (.highDetail, .automatic, 24, "standard", 1_280),
            (.highDetail, .automatic, 48, "performance", 1_280),
        ]

        for (detail, resourcePolicy, memoryGB, memoryTier, expected) in cases {
            let plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(
                    detailProfile: detail,
                    resourcePolicy: resourcePolicy
                ),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(memoryGB: memoryGB, cpuCount: 16, gpuWorkingSetGB: 12),
                developmentOverrides: .none
            )

            let caseName = "\(detail), \(resourcePolicy), \(memoryGB) GB"
            XCTAssertEqual(plan.memoryTier, memoryTier, caseName)
            XCTAssertEqual(plan.colmapMaximumImageDimension, expected, caseName)
        }
    }

    func testFastDefaultsToClassicalGeometryEvenOnLargeMemoryMac() throws {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .fast),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 64, cpuCount: 16, gpuWorkingSetGB: 48),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.geometryBackend, .colmap)
        XCTAssertEqual(plan.modelIdentifier, "none")
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

        XCTAssertEqual(plan.geometryBackend, .da3)
        XCTAssertEqual(plan.modelIdentifier, "DA3-BASE")
        XCTAssertEqual(plan.keyframeBudget, 29)
        XCTAssertEqual(plan.chunkSize, 29)
        XCTAssertEqual(plan.geometryProcessResolution, 336)
        XCTAssertEqual(
            try plan.toolchainCapabilityRequest().capabilities,
            [.core, .colmap, .da3Runtime, .msplat, .da3Base]
        )
    }

    func testExplicitDa3CandidateFailsClosedForIncompatibleCameraPolicies() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let cases: [(RequestedRunOptions, InputSpec, LensProjection)] = [
            (
                RequestedRunOptions(lensProjection: .fisheye),
                .video(files: ["/tmp/fisheye.mov"]),
                .fisheye
            ),
            (
                RequestedRunOptions(cameraGrouping: .mixedCamerasOrLenses),
                .photos(folder: "/tmp/mixed-cameras"),
                .automatic
            ),
            (
                RequestedRunOptions(
                    cameraGrouping: .sameCameraAndLens,
                    inputOrdering: .continuous
                ),
                .video(files: ["/tmp/first.mov", "/tmp/second.mov"]),
                .automatic
            ),
        ]

        for (options, input, expectedProjection) in cases {
            let plan = RunPlanResolver.resolve(
                requestedOptions: options,
                input: input,
                hardware: hardware,
                developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
            )

            XCTAssertEqual(plan.geometryBackend, .da3)
            XCTAssertEqual(plan.modelIdentifier, "DA3-BASE")
            XCTAssertEqual(plan.lensProjection, expectedProjection)
            XCTAssertThrowsError(try plan.validate()) { error in
                XCTAssertEqual(
                    error as? ResolvedRunPlanValidationError,
                    .incompatibleCameraPolicy
                )
            }
        }

        XCTAssertEqual(
            ResolvedCameraModelPolicy.model(
                detailProfile: .balanced,
                capturePath: .automatic,
                lensProjection: .fisheye
            ),
            "OPENCV_FISHEYE"
        )
    }

    func testDa3ModelIsSelectedProactivelyFromResolvedMemoryTier() throws {
        struct Fixture {
            let memoryGB: Double
            let resourcePolicy: ResourcePolicy
            let expectedModel: String
            let expectedCapability: ToolchainCapability
        }
        let fixtures = [
            Fixture(
                memoryGB: 16,
                resourcePolicy: .automatic,
                expectedModel: "DA3-SMALL",
                expectedCapability: .da3Small
            ),
            Fixture(
                memoryGB: 48,
                resourcePolicy: .conserveMemory,
                expectedModel: "DA3-SMALL",
                expectedCapability: .da3Small
            ),
            Fixture(
                memoryGB: 48,
                resourcePolicy: .automatic,
                expectedModel: "DA3-BASE",
                expectedCapability: .da3Base
            ),
        ]

        for fixture in fixtures {
            let plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(
                    detailProfile: .balanced,
                    resourcePolicy: fixture.resourcePolicy
                ),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(
                    memoryGB: fixture.memoryGB,
                    cpuCount: 16,
                    gpuWorkingSetGB: min(fixture.memoryGB, 36)
                ),
                developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
            )

            XCTAssertEqual(plan.modelIdentifier, fixture.expectedModel)
            XCTAssertNoThrow(try plan.validate())
            let capabilities = try plan.toolchainCapabilityRequest().capabilities
            XCTAssertTrue(capabilities.contains(fixture.expectedCapability))
            XCTAssertEqual(
                capabilities.filter { $0 == .da3Base || $0 == .da3Small },
                [fixture.expectedCapability]
            )
        }
    }

    func testPersistedPlanRejectsDa3WithIncompatibleCameraPolicies() {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let invalidPolicies: [(CameraGrouping, LensProjection)] = [
            (.sameCameraAndLens, .fisheye),
            (.mixedCamerasOrLenses, .automatic),
        ]

        for (cameraGrouping, lensProjection) in invalidPolicies {
            var plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: hardware,
                developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
            )
            plan.cameraGrouping = cameraGrouping
            plan.lensProjection = lensProjection

            XCTAssertThrowsError(try plan.validate())
        }

        var crossClipPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: hardware,
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        crossClipPlan.inputOrdering = .continuous
        crossClipPlan.pairingPolicy = .orderedContinuous
        crossClipPlan.temporalPairing = .multiscale
        crossClipPlan.temporalOffsets = [1, 2, 4, 8, 16, 32, 64, 128]
        crossClipPlan.requiresCrossClipRetrieval = true

        XCTAssertThrowsError(try crossClipPlan.validate())
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
        XCTAssertEqual(performance.geometryWorkerBudget.featureExtractionWorkers, 12)
        XCTAssertEqual(performance.geometryWorkerBudget.coupledMatchingWorkers, 6)
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

    func testContinuousOrderingSupportsMultipleClipsButRejectsMixedInput() {
        XCTAssertTrue(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .video(files: ["/tmp/one.mov"])
        ))
        XCTAssertTrue(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .photos(folder: "/tmp/photos")
        ))
        XCTAssertTrue(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"])
        ))
        XCTAssertTrue(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov", "/tmp/three.mov"])
        ))
        XCTAssertFalse(RunPlanResolver.supports(
            inputOrdering: .continuous,
            input: .mixed(videos: ["/tmp/one.mov"], photosFolder: "/tmp/photos")
        ))
    }

    func testMultipleVideoOrderingIntentSelectsDistinctPairingPolicies() {
        let input = InputSpec.video(files: ["/tmp/one.mov", "/tmp/two.mov"])
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)

        let automatic = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .automatic),
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        let continuous = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        let unordered = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .unordered),
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )

        XCTAssertEqual(automatic.inputOrdering, .unordered)
        XCTAssertEqual(automatic.pairingPolicy, .segmentedMixed)
        XCTAssertEqual(continuous.inputOrdering, .continuous)
        XCTAssertEqual(continuous.pairingPolicy, .orderedContinuous)
        XCTAssertEqual(unordered.inputOrdering, .unordered)
        XCTAssertEqual(unordered.pairingPolicy, .unorderedRetrieval)
    }

    func testResolvedPlanPersistsCrossClipRetrievalIntentOnlyWhenRequired() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let multipleVideos = InputSpec.video(files: ["/tmp/one.mov", "/tmp/two.mov"])
        let singleVideo = InputSpec.video(files: ["/tmp/one.mov"])
        let mixedInput = InputSpec.mixed(
            videos: ["/tmp/one.mov", "/tmp/two.mov"],
            photosFolder: "/tmp/photos"
        )
        let fixtures: [(RequestedRunOptions, InputSpec, Bool)] = [
            (RequestedRunOptions(inputOrdering: .continuous), multipleVideos, true),
            (RequestedRunOptions(inputOrdering: .automatic), multipleVideos, true),
            (RequestedRunOptions(inputOrdering: .unordered), multipleVideos, false),
            (RequestedRunOptions(inputOrdering: .continuous), singleVideo, false),
            (RequestedRunOptions(inputOrdering: .automatic), mixedInput, false),
        ]

        for (options, input, expected) in fixtures {
            let plan = RunPlanResolver.resolve(
                requestedOptions: options,
                input: input,
                hardware: hardware,
                developmentOverrides: .none
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                    as? [String: Any]
            )

            XCTAssertEqual(
                object["requiresCrossClipRetrieval"] as? Bool,
                expected,
                "options: \(options), input: \(input)"
            )
        }
    }

    func testExplicitContinuousThreeClipPlanUsesCaptureSpecificOrderedPolicies() {
        let input = InputSpec.video(files: [
            "/tmp/one.mov",
            "/tmp/two.mov",
            "/tmp/three.mov",
        ])
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let cases: [(CapturePath, ResolvedPairingPolicy, TemporalPairing)] = [
            (.automatic, .orderedContinuous, .multiscale),
            (.orbit, .orderedOrbit, .multiscale),
            (.walkthrough, .orderedWalkthrough, .linear),
            (.largeArea, .orderedLargeArea, .multiscale),
        ]

        for (capturePath, expectedPolicy, expectedTemporalPairing) in cases {
            let plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(
                    capturePath: capturePath,
                    inputOrdering: .continuous
                ),
                input: input,
                hardware: hardware,
                developmentOverrides: .none
            )

            XCTAssertEqual(plan.pairingPolicy, expectedPolicy, "capture path: \(capturePath)")
            XCTAssertEqual(
                plan.temporalPairing,
                expectedTemporalPairing,
                "capture path: \(capturePath)"
            )
        }
    }

    func testExplicitContinuousPlanMakesRuntimeIdentityOrderSensitive() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let options = RequestedRunOptions(inputOrdering: .continuous)
        let forwardPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: .video(files: ["Originals/one.mov", "Originals/two.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let reversePlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: .video(files: ["Originals/two.mov", "Originals/one.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let digestA = String(repeating: "1", count: 64)
        let digestB = String(repeating: "a", count: 64)
        let forward = multiClipMetadata(
            pathsAndDigests: [
                ("Originals/one.mov", digestA),
                ("Originals/two.mov", digestB),
            ],
            plan: forwardPlan
        )
        let reverse = multiClipMetadata(
            pathsAndDigests: [
                ("Originals/two.mov", digestB),
                ("Originals/one.mov", digestA),
            ],
            plan: reversePlan
        )

        let forwardIdentities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestA, digestB],
            pairingPolicy: forwardPlan.pairingPolicy
        )
        let reverseIdentities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestB, digestA],
            pairingPolicy: reversePlan.pairingPolicy
        )

        XCTAssertEqual(forwardIdentities.map(\.groupID), ["video_000", "video_001"])
        XCTAssertEqual(reverseIdentities.map(\.groupID), ["video_000", "video_001"])
        XCTAssertEqual(forwardIdentities.map(\.sourceSHA256), [digestA, digestB])
        XCTAssertEqual(reverseIdentities.map(\.sourceSHA256), [digestB, digestA])
        XCTAssertNotEqual(
            try RuntimeInputSnapshotLease.receiptDigest(metadata: forward),
            try RuntimeInputSnapshotLease.receiptDigest(metadata: reverse)
        )
    }

    func testExplicitContinuousTemporalPairsStayInsideClipGroupsWhileRetrievalSpansThem() throws {
        let firstClip = (0..<20).map { String(format: "a_%03d.jpg", $0) }
        let secondClip = (0..<20).map { String(format: "b_%03d.jpg", $0) }
        let imageNames = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let pairs = try PipelineRunner.baseColmapPairPlan(
            imageNames: imageNames,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let retrieval = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: imageNames,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        XCTAssertEqual(plan.pairingPolicy, .orderedContinuous)
        XCTAssertFalse(pairs.pairs.contains { pair in
            (firstClip.contains(pair.firstImageName) && secondClip.contains(pair.secondImageName))
                || (secondClip.contains(pair.firstImageName) && firstClip.contains(pair.secondImageName))
        })
        XCTAssertTrue(retrieval.queryImageNames.contains(firstClip[0]))
        XCTAssertTrue(retrieval.queryImageNames.contains(secondClip[0]))
        XCTAssertEqual(retrieval.minimumFrameSeparation, 0)

        let imageIndexByName = Dictionary(
            uniqueKeysWithValues: imageNames.enumerated().map { ($0.element, $0.offset) }
        )
        let retrievalOutcomes = try retrieval.queryImageNames.map { queryName in
            let queryIndex = try XCTUnwrap(imageIndexByName[queryName])
            let neighborIndex = queryIndex < firstClip.count
                ? queryIndex + firstClip.count
                : queryIndex - firstClip.count
            return PairGraphRetrievalQueryOutcome(
                queryImageName: queryName,
                status: .ranked,
                rankedNeighborImageNames: [imageNames[neighborIndex]]
            )
        }
        let directedPairLines = retrievalOutcomes
            .prefix(retrievalOutcomes.count / 2)
            .map { "\($0.queryImageName) \($0.rankedNeighborImageNames[0])" }
            .sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
        let produced = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: retrieval.queryImageNames,
            queryStride: plan.retrievalQueryStride,
            candidateCount: retrieval.candidateCount,
            returnedNeighborCount: retrieval.returnedNeighborCount,
            minimumFrameSeparation: retrieval.minimumFrameSeparation,
            candidatePolicy: retrieval.imageGroupContract?.policy,
            imageGroupListDigest: retrieval.imageGroupContract?.digest,
            imageGroupLines: retrieval.imageGroupContract?.canonicalLines,
            queryOutcomes: retrievalOutcomes,
            directedPairLines: directedPairLines
        )
        let parsed = try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(produced),
            engine: .localSiftVocabularyV2,
            queryStride: plan.retrievalQueryStride,
            request: retrieval,
            imageNames: imageNames,
            excluding: pairs
        )

        XCTAssertEqual(parsed.directedPairLines, directedPairLines)
        XCTAssertTrue(parsed.directedPairLines.allSatisfy { line in
            let names = line.split(separator: " ").map(String.init)
            return names.count == 2
                && firstClip.contains(names[0])
                && secondClip.contains(names[1])
        })
    }

    func testShortVideoRetrievalSchedulingDistinguishesInputTopology() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let names = (0..<40).map { String(format: "frame_%03d.jpg", $0) }
        let single = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let segmented = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .automatic),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let continuous = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        let singleGroup = [ColmapPairGroup(imageNames: names, isVideo: true)]
        let multiGroups = [
            ColmapPairGroup(imageNames: Array(names.prefix(20)), isVideo: true),
            ColmapPairGroup(imageNames: Array(names.suffix(20)), isVideo: true),
        ]

        XCTAssertFalse(single.requiresCrossClipRetrieval)
        XCTAssertNil(try PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: singleGroup,
            resolvedPlan: single,
            recoveryLevel: .normal
        ))
        XCTAssertTrue(segmented.requiresCrossClipRetrieval)
        let segmentedRequest = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: multiGroups,
            resolvedPlan: segmented,
            recoveryLevel: .normal
        ))
        XCTAssertEqual(segmentedRequest.queryImageNames, names)
        XCTAssertEqual(segmentedRequest.imageGroupContract?.policy, .crossGroupV1)
        XCTAssertTrue(continuous.requiresCrossClipRetrieval)
        XCTAssertNotNil(try PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: multiGroups,
            resolvedPlan: continuous,
            recoveryLevel: .normal
        ))
    }

    func testShortContinuousMulticlipRecoveryRetainsAConnectionPath() throws {
        let firstClip = (0..<20).map { String(format: "a_%03d.jpg", $0) }
        let secondClip = (0..<20).map { String(format: "b_%03d.jpg", $0) }
        let names = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        for level in [PipelineRunner.PairRecoveryLevel.normal, .expanded] {
            XCTAssertNotNil(try PipelineRunner.vocabularyRetrievalRequest(
                imageNames: names,
                groups: groups,
                resolvedPlan: plan,
                recoveryLevel: level
            ))
        }

        let maximumPlan = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .maximum
        )
        XCTAssertEqual(maximumPlan.pairs.count, names.count * (names.count - 1) / 2)
        XCTAssertTrue(maximumPlan.isConnected)
        XCTAssertNil(try PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .maximum
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
        XCTAssertTrue(plan.requiresCrossClipRetrieval)
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
        XCTAssertEqual(plan.baGlobalFramesRatio, 1.4)
        XCTAssertEqual(plan.baGlobalPointsRatio, 1.4)
        XCTAssertEqual(plan.baLocalMaxRefinements, 2)
        XCTAssertEqual(plan.incrementalMappingCadence, .balancedGlobal)

        let mixedPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .mixed(videos: ["/tmp/clip.mov"], photosFolder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        XCTAssertEqual(mixedPlan.pairingPolicy, .segmentedMixed)
        XCTAssertEqual(mixedPlan.temporalPairing, .linear)
        XCTAssertEqual(mixedPlan.temporalOffsets, [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(mixedPlan.requiresCrossClipRetrieval)
        XCTAssertEqual(mixedPlan.baGlobalFramesRatio, 1.4)
        XCTAssertEqual(mixedPlan.baGlobalPointsRatio, 1.4)
        XCTAssertEqual(mixedPlan.baLocalMaxRefinements, 2)
        XCTAssertEqual(mixedPlan.incrementalMappingCadence, .balancedGlobal)
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

        XCTAssertEqual(plan.geometryBackend, .colmap)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.requiredToolchainCapabilities, ["geometry.colmap", "runtime.core", "training.msplat"])
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
        XCTAssertEqual(plan.lensProjection, .fisheye)
        XCTAssertEqual(plan.inputOrdering, .continuous)
        XCTAssertEqual(plan.runSeed, 99)
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

        var encodedPlan = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )
        encodedPlan["geometryBackend"] = "geometry.unknown"
        let unknownBackendData = try JSONSerialization.data(withJSONObject: encodedPlan)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ResolvedRunPlan.self, from: unknownBackendData)
        )

        corrupt = plan
        corrupt.modelIdentifier = "DA3-BASE"
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest())

        corrupt = plan
        corrupt.requiredToolchainCapabilities.append("geometry.da3.small")
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest())

        corrupt = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        corrupt.requiredToolchainCapabilities.append("geometry.da3.small")
        corrupt.requiredToolchainCapabilities.sort()
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest())

        corrupt = plan
        corrupt.baLocalMaxRefinements = 0
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .invalidBundleAdjustmentConfiguration
            )
        }

        corrupt = plan
        corrupt.runSeed = UInt64(Int32.max) + 1
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .randomSeedOutOfRange
            )
        }

        corrupt = plan
        corrupt.requiresCrossClipRetrieval = true
        XCTAssertThrowsError(try corrupt.toolchainCapabilityRequest()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .invalidPairingConfiguration
            )
        }
    }

    func testResolvedPlanRejectsInvalidGeometryWorkerBudgets() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        var invalidPlans: [ResolvedRunPlan] = []

        var invalid = plan
        invalid.geometryWorkerBudget.featureExtractionWorkers = 0
        invalidPlans.append(invalid)

        invalid = plan
        invalid.geometryWorkerBudget.coupledMatchingWorkers = 65
        invalidPlans.append(invalid)

        invalid = plan
        invalid.geometryWorkerBudget.vocabularyRetrievalWorkers = 0
        invalidPlans.append(invalid)

        invalid = plan
        invalid.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks = 65
        invalidPlans.append(invalid)

        for invalidPlan in invalidPlans {
            XCTAssertThrowsError(try invalidPlan.toolchainCapabilityRequest()) { error in
                XCTAssertEqual(
                    error as? ResolvedRunPlanValidationError,
                    .invalidGeometryWorkerBudget
                )
            }
        }
    }

    func testResolvedPlanPersistsBeforeImportProcessCompletes() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePhotos = root.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: false
        )
        for index in 0..<3 {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: sourcePhotos.appendingPathComponent("photo-\(index).jpg"),
                size: 16,
                value: UInt8(32 + index * 32),
                utType: .jpeg
            ))
        }
        let projectURL = root.appendingPathComponent("Plan.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let options = RequestedRunOptions(
            capturePath: .largeArea,
            detailProfile: .fast,
            cameraGrouping: .sameCameraAndLens,
            lensProjection: .perspective,
            inputOrdering: .unordered,
            resourcePolicy: .conserveMemory,
            photoSelection: .useAllValidPhotos
        )
        let requestedInput = InputSpec.photos(folder: sourcePhotos.path)
        let admissionPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: requestedInput,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let prepared = try await PhotoInputPreflight.prepare(
            folder: sourcePhotos,
            stagingParent: root,
            photoSelection: admissionPlan.photoSelection,
            inputOrdering: admissionPlan.inputOrdering,
            keyframeBudget: admissionPlan.keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: 16,
                maximumTotalBytes: Int64(16) * 1_024 * 1_024,
                maximumSinglePhotoBytes: Int64(4) * 1_024 * 1_024,
                maximumPixelCount: Int64(1_024) * 1_024,
                maximumDecodedDimension: 128,
                maximumTraversalEntryCount: 32,
                maximumRecursionDepth: 4,
                minimumFreeSpaceReserveBytes: 0
            ),
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        XCTAssertEqual(prepared.photos.count, 3)
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        try adoption.adoptPhotos(prepared, into: paths)
        let metadata = ProjectMetadata(
            title: "Plan",
            input: adoption.input,
            photoInputReceipts: try XCTUnwrap(adoption.photoInputReceipts),
            photoSelectionReceipt: try XCTUnwrap(adoption.photoSelectionReceipt),
            requestedRunOptions: options,
            resolvedRunPlan: admissionPlan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
        let toolchainRoot = root.appendingPathComponent("Toolchain", isDirectory: true)
        let colmap = toolchainRoot.appendingPathComponent("bin/colmap")
        try TestFileBuilder.createExecutable(at: colmap)
        let openMPRuntime = toolchainRoot.appendingPathComponent("lib/libomp.dylib")
        try FileManager.default.createDirectory(
            at: openMPRuntime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture OpenMP runtime".utf8).write(to: openMPRuntime)
        let toolchain = TestToolchains.toolchainPaths(root: toolchainRoot, colmap: colmap)
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
        XCTAssertEqual(plan.geometryBackend, .colmap)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.photoSelection, .useAllValidPhotos)
        XCTAssertEqual(plan.runSeed, 7)
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

    func testNoValidPhotosGuidanceIncludesSupportedRawFormats() throws {
        let message = try XCTUnwrap(
            RunPlanResolver.ValidationError.noValidPhotos.errorDescription
        )

        XCTAssertEqual(
            message,
            "This folder has no readable photos. Choose JPEG, PNG, HEIC, HEIF, or a RAW format supported by macOS."
        )
        XCTAssertFalse(message.contains("TIFF"))
    }

    func testPhotoOnlyPreflightRequiresThreeUsableViews() {
        let input = InputSpec.photos(folder: "/tmp/photos")
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: input,
            hardware: HardwareProfile(memoryGB: 24, cpuCount: 12, gpuWorkingSetGB: 18),
            developmentOverrides: .none
        )

        XCTAssertThrowsError(try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: 2,
            resolvedPlan: plan,
            input: input
        )) { error in
            XCTAssertEqual(
                error as? RunPlanResolver.ValidationError,
                .insufficientValidPhotos(actual: 2, minimum: 3)
            )
        }
        XCTAssertNoThrow(try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: 3,
            resolvedPlan: plan,
            input: input
        ))
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
        XCTAssertNoThrow(try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: 2,
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
            .sfmMatching
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
            .sfmMatching
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.baLocalMaxRefinements = 2
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmMatching
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
            .sfmMatching
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.runSeed = 43
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
        mappingPolicyPlan.baLocalMaxNumIterations = 11
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmMatching
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.baLocalFunctionTolerance = 0.002
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmMatching
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.baGlobalFunctionTolerance = 0.000_002
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmMatching
        )

        mappingPolicyPlan = currentVideoPlan
        mappingPolicyPlan.baLocalImageCount = 7
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: mappingPolicyPlan
            ),
            .sfmMatching
        )

        var pairingPolicyPlan = currentVideoPlan
        pairingPolicyPlan.temporalOffsets = [1, 2, 4]
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: pairingPolicyPlan
            ),
            .sfmFeatures
        )

        pairingPolicyPlan = currentVideoPlan
        pairingPolicyPlan.requiresCrossClipRetrieval.toggle()
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: pairingPolicyPlan
            ),
            .sfmFeatures
        )

        var videoWorkersPlan = currentVideoPlan
        videoWorkersPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: videoWorkersPlan
            ),
            .importInput
        )

        var photoVideoWorkersPlan = currentPhotoPlan
        photoVideoWorkersPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: photos,
                previousPlan: currentPhotoPlan,
                currentPlan: photoVideoWorkersPlan
            ),
            .exportSplat
        )

        var extractionWorkersPlan = currentVideoPlan
        extractionWorkersPlan.geometryWorkerBudget.featureExtractionWorkers += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: extractionWorkersPlan
            ),
            .selectFrames
        )

        var matchingWorkersPlan = currentVideoPlan
        matchingWorkersPlan.geometryWorkerBudget.coupledMatchingWorkers += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: matchingWorkersPlan
            ),
            .sfmFeatures
        )

        var retrievalWorkersPlan = currentVideoPlan
        retrievalWorkersPlan.geometryWorkerBudget.vocabularyRetrievalWorkers += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .exportSplat,
                input: video,
                previousPlan: currentVideoPlan,
                currentPlan: retrievalWorkersPlan
            ),
            .sfmFeatures
        )
    }

    private func multiClipMetadata(
        pathsAndDigests: [(String, String)],
        plan: ResolvedRunPlan
    ) -> ProjectMetadata {
        ProjectMetadata(
            title: "Continuous clips",
            input: .video(files: pathsAndDigests.map(\.0)),
            videoInputReceipts: pathsAndDigests.enumerated().map { index, entry in
                let (path, digest) = entry
                return VideoInputReceipt(
                    projectRelativePath: path,
                    safeDisplayName: URL(fileURLWithPath: path).lastPathComponent,
                    byteCount: 1,
                    sha256: digest,
                    trackID: 1,
                    pixelWidth: 64,
                    pixelHeight: 48,
                    durationSeconds: 1,
                    nominalFrameRate: 30,
                    isHDR: false,
                    decodedFrameCount: 3,
                    transformA: 1,
                    transformB: 0,
                    transformC: 0,
                    transformD: 1,
                    transformTX: 0,
                    transformTY: 0,
                    clipGroupID: String(format: "video_%03d", index),
                    analysisPolicySHA256: VideoFrameAnalysisPolicy(
                        resolvedRunPlan: plan
                    ).sha256,
                    analysisArtifactPath: String(
                        format: "Frames/video-analysis-%04d.json",
                        index
                    ),
                    analysisArtifactByteCount: 1,
                    analysisArtifactSHA256: digest
                )
            },
            requestedRunOptions: RequestedRunOptions(inputOrdering: .continuous),
            resolvedRunPlan: plan
        )
    }
}
