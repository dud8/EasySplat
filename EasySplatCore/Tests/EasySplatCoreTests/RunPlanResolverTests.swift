import Foundation
import XCTest
@testable import EasySplatCore

final class RunPlanResolverTests: XCTestCase {
    func testPlanWrittenBeforeTopologyFieldsRemainsDecodable() throws {
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

        let plan = try JSONDecoder().decode(ResolvedRunPlan.self, from: Data(json.utf8))

        XCTAssertEqual(plan.capturePath, .automatic)
        XCTAssertEqual(plan.inputOrdering, .automatic)
        XCTAssertEqual(plan.photoSelection, .automatic)
        XCTAssertEqual(plan.pairingPolicy, .unorderedRetrieval)
        XCTAssertEqual(plan.sequentialOverlap, 10)
        XCTAssertEqual(plan.deterministicSeed, 42)
    }

    func testDefaultBalancedPhotoPlanUsesAnchoredBaseThenColmapFallback() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.routeIdentifier, SfmBackend.da3.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "DA3-BASE")
        XCTAssertEqual(plan.memoryTier, "performance")
        XCTAssertEqual(plan.chunkSize, 8)
        XCTAssertEqual(plan.keyframeBudget, 250)
        XCTAssertEqual(plan.maximumImageDimension, 1_600)
        XCTAssertEqual(plan.capturePath, .automatic)
        XCTAssertEqual(plan.inputOrdering, .unordered)
        XCTAssertEqual(plan.pairingPolicy, .unorderedRetrieval)
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
        XCTAssertEqual(plan.lensProjection, .automatic)
        XCTAssertEqual(plan.trainerIterationLimit, 7_000)
        XCTAssertEqual(plan.plateauWindow, 800)
        XCTAssertEqual(plan.deterministicSeed, 42)
        XCTAssertEqual(
            plan.requiredToolchainCapabilities,
            [
                "geometry.colmap",
                "geometry.da3.base",
                "geometry.da3.runtime",
                "geometry.da3.small",
                "runtime.core",
                "training.msplat",
            ]
        )
        XCTAssertEqual(plan.fallbackRouteIdentifiers, [SfmBackend.colmap.rawValue])
    }

    func testLowMemoryAndConserveMemoryProactivelyChooseSmallAndBoundBudgets() {
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
            XCTAssertEqual(plan.modelIdentifier, "DA3-SMALL")
            XCTAssertEqual(plan.chunkSize, 4)
            XCTAssertLessThan(plan.keyframeBudget, automatic48GB.keyframeBudget)
            XCTAssertLessThan(plan.maximumImageDimension, automatic48GB.maximumImageDimension)
        }
    }

    func testFastUsesSmallLearnedGeometryEvenOnLargeMemoryMac() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .fast),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 64, cpuCount: 16, gpuWorkingSetGB: 48),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.routeIdentifier, SfmBackend.da3.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "DA3-SMALL")
        XCTAssertEqual(plan.fallbackRouteIdentifiers, [SfmBackend.colmap.rawValue])
        XCTAssertEqual(plan.cameraGrouping, .sameCameraAndLens)
        XCTAssertEqual(plan.lensProjection, .automatic)
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
        XCTAssertEqual(constrained.modelIdentifier, "DA3-SMALL")
        XCTAssertEqual(constrained.chunkSize, 4)
        XCTAssertEqual(performance.memoryTier, "performance")
        XCTAssertEqual(performance.modelIdentifier, "DA3-BASE")
        XCTAssertEqual(performance.chunkSize, 10)
        XCTAssertGreaterThan(performance.keyframeBudget, constrained.keyframeBudget)
        XCTAssertGreaterThan(performance.maximumImageDimension, constrained.maximumImageDimension)
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
        XCTAssertLessThan(orbit.sequentialOverlap, largeArea.sequentialOverlap)
    }

    func testAutomaticOrderingDoesNotPretendSeparateClipsAreOneContinuousCapture() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .video(files: ["/tmp/first.mov", "/tmp/second.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.inputOrdering, .unordered)
        XCTAssertEqual(plan.pairingPolicy, .unorderedRetrieval)
        XCTAssertEqual(plan.sequentialOverlap, 0)
        XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)
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
        XCTAssertEqual(plan.lensProjection, .automatic)
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
            [.core, .colmap, .da3Runtime, .msplat, .da3Base, .da3Small]
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
            preset: PresetSpec(mode: .room, quality: .draft),
            requestedRunOptions: options
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = TestToolchains.toolchainPaths(root: root)
        let runner = PipelineRunner(
            projectURL: projectURL,
            config: .init(
                toolchain: toolchain,
                preset: metadata.preset,
                developmentOverrides: .init(stopAfterStage: .importInput, benchmarkSeed: 7)
            )
        )

        try await runner.run { _ in }

        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        let plan = try XCTUnwrap(saved.resolvedRunPlan)
        XCTAssertEqual(plan.capturePath, .largeArea)
        XCTAssertEqual(plan.routeIdentifier, SfmBackend.da3.rawValue)
        XCTAssertEqual(plan.modelIdentifier, "DA3-SMALL")
        XCTAssertEqual(plan.photoSelection, .useAllValidPhotos)
        XCTAssertEqual(plan.deterministicSeed, 7)
        XCTAssertEqual(saved.state.stage, .importInput)
        XCTAssertNil(saved.lastRunStartedAt)
    }
}
