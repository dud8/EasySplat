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

    func testResolvedRunPlanPersistsRunSeedWithoutRetiredDeterministicKey() throws {
        let plan = makeResolvedRunPlan()
        let encoded = try JSONEncoder().encode(plan)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["runSeed"] as? NSNumber, NSNumber(value: 42))
        XCTAssertNil(object["deterministicSeed"])

        var retiredObject = object
        retiredObject.removeValue(forKey: "runSeed")
        retiredObject["deterministicSeed"] = 42
        let retiredData = try JSONSerialization.data(withJSONObject: retiredObject)
        XCTAssertThrowsError(try JSONDecoder().decode(ResolvedRunPlan.self, from: retiredData))
    }

    private func assertJSONRoundTrip<Value: Codable & Equatable>(_ values: [Value]) throws {
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([Value].self, from: data), values)
    }
}

final class ProjectMetadataVersionFourteenTests: XCTestCase {
    func testNewMetadataUsesVersionFourteenAndSuppliedRequestedOptions() {
        let metadata = ProjectMetadata(
            title: "New project",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )

        XCTAssertEqual(ProjectMetadataStore.supportedFormatVersion, 14)
        XCTAssertEqual(metadata.formatVersion, ProjectMetadataStore.supportedFormatVersion)
        XCTAssertEqual(
            metadata.requestedRunOptions,
            RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        XCTAssertNil(metadata.resolvedRunPlan)
        XCTAssertNil(metadata.geometryArtifact)
        XCTAssertNil(metadata.trainingArtifact)
    }
}

final class PipelineArtifactContractTests: XCTestCase {
    func testTrainingArtifactPersistsCameraOrderSeedWithoutRetiredDeterministicKey() throws {
        let training = makeTrainingArtifact()
        let encoded = try JSONEncoder().encode(training)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(TrainingArtifact.currentSchemaVersion, 5)
        XCTAssertEqual(object["schemaVersion"] as? NSNumber, NSNumber(value: 5))
        XCTAssertEqual(object["cameraOrderSeed"] as? NSNumber, NSNumber(value: 42))
        XCTAssertNil(object["deterministicSeed"])

        var retiredObject = object
        retiredObject.removeValue(forKey: "cameraOrderSeed")
        retiredObject["deterministicSeed"] = 42
        let retiredData = try JSONSerialization.data(withJSONObject: retiredObject)
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingArtifact.self, from: retiredData))
    }

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
        request.events(.stageStarted(stage: .trainSplat))
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
        trainerIterationLimit: 15_000,
        plateauWindow: 1_500,
        trainerMemoryBudgetBytes: 32_212_254_720,
        requiredToolchainCapabilities: ["geometry-v2", "training-v2"],
        fallbackRouteIdentifiers: ["geometry.apple-silicon.fallback"],
        baGlobalFramesRatio: 1.4,
        baGlobalPointsRatio: 1.4,
        baLocalMaxRefinements: 2,
        baGlobalMaxRefinements: 5
    )
}

func makeGeometryArtifact(
    sourceModelPath: String = "SfM/colmap/sparse/0"
) -> GeometryArtifact {
    GeometryArtifact(
        schemaVersion: GeometryArtifact.currentSchemaVersion,
        solverVersion: "solver-1.2.3",
        runtimeVersion: "runtime-3.12",
        modelVersion: "model-2026-07",
        inputDigest: "sha256:input",
        selectedFramesDigest: "sha256:selected-frames",
        orderedImageNames: ["frame_000001.jpg", "frame_000002.jpg"],
        orderedImageTimestamps: [0.0, 0.5],
        sourceModelPath: sourceModelPath,
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
        fallbackReason: nil,
        provenance: GeometryProvenance(
            toolchainVersion: "2.0.0",
            solver: GeometryComponentProvenance(
                identifier: "colmap",
                version: "4.1.0",
                revision: "fa8e3b3ff591552855f8ad2806723c80f963f69c",
                payloadSHA256: String(repeating: "a", count: 64)
            ),
            runtime: nil,
            model: nil
        ),
        pairGraph: .notEvaluated(),
        mapping: MappingArtifact(
            modelCount: 1,
            largestModelRegisteredViewCount: 2,
            secondLargestModelRegisteredViewCount: 0,
            unionRegisteredViewCount: 2,
            attemptCount: 1,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 1,
            incrementalCadence: IncrementalMappingCadenceArtifact(
                localMaxRefinements: 2,
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5
            ),
            fallbackReason: nil
        ),
        canonicalOrientation: .unresolved(
            openingViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
        )
    )
}

func makeTrainingArtifact(
    checkpointPath: String? = nil,
    outputPath: String? = "Output/splat.ply",
    completionStatus: TrainingCompletionStatus = .completed
) -> TrainingArtifact {
    TrainingArtifact(
        trainerVersion: "trainer-1.4.0",
        runtimeVersion: "native-metal-cli-v2",
        trainerBuildDigest: String(repeating: "a", count: 64),
        inputDigest: String(repeating: "b", count: 64),
        geometryDigest: String(repeating: "c", count: 64),
        detailProfile: .highDetail,
        iterationLimit: 15_000,
        plateauWindow: 1_500,
        cameraOrderSeed: 42,
        completedIteration: 15_000,
        checkpointPath: checkpointPath,
        checkpointDigest: checkpointPath == nil ? nil : String(repeating: "d", count: 64),
        outputPath: outputPath,
        outputSHA256: outputPath == nil ? nil : String(repeating: "e", count: 64),
        outputBytes: outputPath == nil ? nil : 1_024,
        gaussianCount: 245_000,
        elapsedSeconds: 812.5,
        peakMemoryBytes: 4_294_967_296,
        memoryBudgetBytes: 32_212_254_720,
        rasterFallbackCount: 0,
        rasterExactFallbackElapsedSeconds: 0,
        rasterExactBufferGrowthCount: 0,
        rasterExactBufferBytesAdded: 0,
        rasterReplayElapsedSeconds: 0,
        rasterPeakExactIntersectionCapacity: 0,
        droppedIntersectionCount: 0,
        completionStatus: completionStatus
    )
}
