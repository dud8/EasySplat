import XCTest
@testable import EasySplatCore

final class RequestedRunOptionsTests: XCTestCase {
    func testDefaultsMatchPublicBetaAutomaticPolicy() throws {
        let options = RequestedRunOptions()

        XCTAssertEqual(options.capturePath, .automatic)
        XCTAssertEqual(options.detailProfile, .balanced)
        XCTAssertEqual(options.cameraGrouping, .automatic)
        XCTAssertEqual(options.lensProjection, .automatic)
        XCTAssertEqual(options.inputOrdering, .automatic)
        XCTAssertEqual(options.resourcePolicy, .automatic)
        XCTAssertEqual(options.photoSelection, .automatic)
        try assertJSONRoundTrip([options])
    }

    func testEveryRequestedOptionCaseRoundTrips() throws {
        try assertJSONRoundTrip([
            CapturePath.automatic,
            .orbit,
            .walkthrough,
            .largeArea,
        ])
        try assertJSONRoundTrip([
            DetailProfile.fast,
            .balanced,
            .highDetail,
        ])
        try assertJSONRoundTrip([
            CameraGrouping.automatic,
            .sameCameraAndLens,
            .mixedCamerasOrLenses,
        ])
        try assertJSONRoundTrip([
            LensProjection.automatic,
            .perspective,
            .fisheye,
        ])
        try assertJSONRoundTrip([
            InputOrdering.automatic,
            .continuous,
            .unordered,
        ])
        try assertJSONRoundTrip([
            ResourcePolicy.automatic,
            .conserveMemory,
            .maximumPerformance,
        ])
        try assertJSONRoundTrip([
            PhotoSelection.automatic,
            .useAllValidPhotos,
        ])
    }

    func testResolvedRunPlanRoundTripsBackendNeutralDecisions() throws {
        let plan = makeResolvedRunPlan()
        try assertJSONRoundTrip([plan])
    }

    private func assertJSONRoundTrip<Value: Codable & Equatable>(_ values: [Value]) throws {
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([Value].self, from: data), values)
    }
}

final class ProjectMetadataVersionTwoTests: XCTestCase {
    func testNewMetadataDefaultsToVersionTwoAndRequestedOptions() {
        let metadata = ProjectMetadata(
            title: "New project",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )

        XCTAssertEqual(ProjectMetadataStore.supportedFormatVersion, 2)
        XCTAssertEqual(metadata.formatVersion, 2)
        XCTAssertEqual(metadata.requestedRunOptions, RequestedRunOptions())
        XCTAssertNil(metadata.resolvedRunPlan)
        XCTAssertNil(metadata.geometryArtifact)
        XCTAssertNil(metadata.trainingArtifact)
    }
}

final class PipelineArtifactContractTests: XCTestCase {
    func testGeometryAndTrainingArtifactsRoundTripWithProjectRelativePaths() throws {
        let geometry = makeGeometryArtifact()
        let training = makeTrainingArtifact()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(GeometryArtifact.self, from: encoder.encode(geometry)),
            geometry
        )
        XCTAssertEqual(
            try decoder.decode(TrainingArtifact.self, from: encoder.encode(training)),
            training
        )
    }

    func testProcessBoundaryProtocolsCarryOnlyCurrentInputs() async throws {
        let projectURL = URL(fileURLWithPath: "/tmp/Test.easysplatproj", isDirectory: true)
        let selectedImages = [
            projectURL.appendingPathComponent("Frames/selected/frame_000001.jpg"),
            projectURL.appendingPathComponent("Frames/selected/frame_000002.jpg"),
        ]
        let options = RequestedRunOptions(capturePath: .orbit, detailProfile: .highDetail)
        let plan = makeResolvedRunPlan()
        let geometry = makeGeometryArtifact()
        let training = makeTrainingArtifact()
        let geometryRequest = GeometryRequest(
            projectURL: projectURL,
            selectedImages: selectedImages,
            requestedOptions: options,
            resolvedPlan: plan,
            events: { _ in }
        )
        let trainingRequest = TrainingRequest(
            projectURL: projectURL,
            canonicalGeometry: geometry,
            requestedOptions: options,
            resolvedPlan: plan,
            events: { _ in }
        )

        XCTAssertEqual(geometryRequest.projectURL, projectURL)
        XCTAssertEqual(geometryRequest.selectedImages, selectedImages)
        XCTAssertEqual(geometryRequest.requestedOptions, options)
        XCTAssertEqual(geometryRequest.resolvedPlan, plan)
        XCTAssertEqual(trainingRequest.projectURL, projectURL)
        XCTAssertEqual(trainingRequest.canonicalGeometry, geometry)
        XCTAssertEqual(trainingRequest.requestedOptions, options)
        XCTAssertEqual(trainingRequest.resolvedPlan, plan)
        let solvedGeometry = try await GeometrySolverStub(result: geometry).solve(geometryRequest)
        let trainedSplat = try await SplatTrainerStub(result: training).train(trainingRequest)
        XCTAssertEqual(solvedGeometry, geometry)
        XCTAssertEqual(trainedSplat, training)
    }
}

private struct GeometrySolverStub: GeometrySolving {
    let result: GeometryArtifact

    func solve(_ request: GeometryRequest) async throws -> GeometryArtifact {
        request.events(.stageStarted(stage: .sfmMapping))
        return result
    }
}

private struct SplatTrainerStub: SplatTraining {
    let result: TrainingArtifact

    func train(_ request: TrainingRequest) async throws -> TrainingArtifact {
        request.events(.stageStarted(stage: .trainBrush))
        return result
    }
}

private func makeResolvedRunPlan() -> ResolvedRunPlan {
    ResolvedRunPlan(
        routeIdentifier: "geometry.apple-silicon.primary",
        modelIdentifier: "geometry-model-v1",
        memoryTier: "48gb",
        chunkSize: 12,
        keyframeBudget: 180,
        maximumImageDimension: 2048,
        cameraGrouping: .sameCameraAndLens,
        lensProjection: .perspective,
        refinementIterationLimit: 75,
        trainerIterationLimit: 30_000,
        plateauWindow: 1_500,
        requiredToolchainCapabilities: ["geometry-v2", "training-v2"],
        fallbackRouteIdentifiers: ["geometry.apple-silicon.fallback"]
    )
}

func makeGeometryArtifact(
    canonicalModelPath: String = "SfM/canonical/model"
) -> GeometryArtifact {
    GeometryArtifact(
        schemaVersion: 1,
        solverVersion: "solver-1.2.3",
        runtimeVersion: "runtime-3.12",
        modelVersion: "model-2026-07",
        inputDigest: "sha256:input",
        selectedFramesDigest: "sha256:selected-frames",
        orderedImageNames: ["frame_000001.jpg", "frame_000002.jpg"],
        orderedImageTimestamps: [0.0, 0.5],
        canonicalModelPath: canonicalModelPath,
        poseConvention: "worldToCamera",
        quaternionOrder: "wxyz",
        handedness: "rightHanded",
        scaleType: "metric",
        cameraModel: "PINHOLE",
        cameraGrouping: .sameCameraAndLens,
        registeredViewCount: 2,
        totalViewCount: 2,
        trackCount: 120,
        pointCount: 80,
        residualProvenance: "bundle-adjusted-observations",
        medianPixelResidual: 0.42,
        p90PixelResidual: 0.91,
        timings: ["solve": 3.25, "refine": 1.75],
        peakMemoryBytes: 2_147_483_648,
        modelHashes: ["geometry-model-v1": "sha256:model"],
        fallbackReason: nil
    )
}

func makeTrainingArtifact(
    checkpointPath: String? = "Training/checkpoints/final.ckpt",
    outputPath: String? = "Output/splat.ply"
) -> TrainingArtifact {
    TrainingArtifact(
        trainerVersion: "trainer-1.4.0",
        runtimeVersion: "runtime-3.12",
        geometryDigest: "sha256:geometry",
        detailProfile: .highDetail,
        iterationLimit: 30_000,
        plateauWindow: 1_500,
        deterministicSeed: 42,
        checkpointPath: checkpointPath,
        outputPath: outputPath,
        gaussianCount: 245_000,
        elapsedSeconds: 812.5,
        peakMemoryBytes: 4_294_967_296,
        completionStatus: "completed"
    )
}
