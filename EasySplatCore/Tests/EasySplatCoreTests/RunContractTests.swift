import XCTest
@testable import EasySplatCore

final class RequestedRunOptionsTests: XCTestCase {
    func testDefaultsMatchAutomaticPolicy() throws {
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

    func testResolvedRunPlanPersistsStageWorkerBudgetWithoutRetiredCoupledLimit() throws {
        let plan = makeResolvedRunPlan()
        let encoded = try JSONEncoder().encode(plan)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let workers = try XCTUnwrap(object["geometryWorkerBudget"] as? [String: Any])

        XCTAssertEqual(workers["featureExtractionWorkers"] as? NSNumber, 12)
        XCTAssertEqual(workers["coupledMatchingWorkers"] as? NSNumber, 8)
        XCTAssertEqual(workers["vocabularyRetrievalWorkers"] as? NSNumber, 8)
        XCTAssertEqual(
            workers["maximumConcurrentVideoSourceAnalysisTasks"] as? NSNumber,
            4
        )
        XCTAssertNil(workers["videoAnalysisWorkerLimit"])
        XCTAssertNil(object["colmapThreadLimit"])

        var retiredObject = object
        retiredObject.removeValue(forKey: "geometryWorkerBudget")
        retiredObject["colmapThreadLimit"] = 6
        let retiredData = try JSONSerialization.data(withJSONObject: retiredObject)
        XCTAssertThrowsError(try JSONDecoder().decode(ResolvedRunPlan.self, from: retiredData))
    }

    func testGeometryWorkerBudgetDecodesLegacyPlanWithoutRetrievalBudget() throws {
        let legacy = Data("""
        {
          "featureExtractionWorkers": 12,
          "coupledMatchingWorkers": 8,
          "vocabularyRetrievalWorkers": 8,
          "maximumConcurrentVideoSourceAnalysisTasks": 4
        }
        """.utf8)
        let budget = try JSONDecoder().decode(GeometryWorkerBudget.self, from: legacy)
        XCTAssertEqual(
            budget.retrievalMemoryBudgetBytes,
            ColmapVocabularyRetrievalOptions.defaultMemoryBudgetBytes
        )
    }

    func testResolvedRunPlanGeneralValidationRejectsInvalidWorkerBudget() throws {
        var plan = makeResolvedRunPlan()
        plan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks = 0

        XCTAssertThrowsError(try plan.validate()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .invalidGeometryWorkerBudget
            )
        }
    }

    private func assertJSONRoundTrip<Value: Codable & Equatable>(_ values: [Value]) throws {
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([Value].self, from: data), values)
    }
}

final class ProjectMetadataCurrentVersionTests: XCTestCase {
    func testNewMetadataUsesCurrentVersionAndSuppliedRequestedOptions() {
        let metadata = ProjectMetadata(
            title: "New project",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )

        XCTAssertEqual(ProjectMetadataStore.supportedFormatVersion, 31)
        XCTAssertEqual(metadata.formatVersion, ProjectMetadataStore.supportedFormatVersion)
        XCTAssertEqual(
            metadata.requestedRunOptions,
            RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        XCTAssertNil(metadata.resolvedRunPlan)
    }
}

final class PipelineArtifactContractTests: XCTestCase {
    func testTrainingArtifactAcceptsALiveBudgetBelowTheResolvedMaximum() {
        let plan = makeResolvedRunPlan()
        var training = makeTrainingArtifact()
        training.memoryBudgetBytes = plan.trainerMemoryBudgetBytes / 2

        XCTAssertTrue(training.matchesResolvedTrainingPlan(
            plan,
            resourcePolicy: .automatic
        ))

        training.memoryBudgetBytes = 0
        XCTAssertFalse(training.matchesResolvedTrainingPlan(
            plan,
            resourcePolicy: .automatic
        ))
        training.memoryBudgetBytes = plan.trainerMemoryBudgetBytes + 1
        XCTAssertFalse(training.matchesResolvedTrainingPlan(
            plan,
            resourcePolicy: .automatic
        ))
        training.memoryBudgetBytes = plan.trainerMemoryBudgetBytes / 2
        training.cameraOrderSeed = plan.runSeed &+ 1
        XCTAssertFalse(training.matchesResolvedTrainingPlan(
            plan,
            resourcePolicy: .automatic
        ))
        training.cameraOrderSeed = plan.runSeed
        XCTAssertFalse(training.matchesResolvedTrainingPlan(
            plan,
            resourcePolicy: .conserveMemory
        ))
    }

    func testTrainingArtifactPersistsCameraOrderSeedWithoutRetiredDeterministicKey() throws {
        let training = makeTrainingArtifact()
        let encoded = try JSONEncoder().encode(training)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(TrainingArtifact.currentSchemaVersion, 7)
        XCTAssertEqual(object["schemaVersion"] as? NSNumber, NSNumber(value: 7))
        XCTAssertEqual(object["cameraOrderSeed"] as? NSNumber, NSNumber(value: 42))
        let admission = try XCTUnwrap(object["resourceAdmission"] as? [String: Any])
        XCTAssertEqual(admission["schema_version"] as? NSNumber, NSNumber(value: 2))
        XCTAssertNil(object["deterministicSeed"])

        var retiredObject = object
        retiredObject.removeValue(forKey: "cameraOrderSeed")
        retiredObject["deterministicSeed"] = 42
        let retiredData = try JSONSerialization.data(withJSONObject: retiredObject)
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingArtifact.self, from: retiredData))

        var missingAdmission = object
        missingAdmission.removeValue(forKey: "resourceAdmission")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TrainingArtifact.self,
                from: JSONSerialization.data(withJSONObject: missingAdmission)
            )
        )
    }

    func testGeometryAndTrainingArtifactsRoundTripWithProjectRelativePaths() throws {
        let geometry = makeGeometryArtifact()
        let training = makeTrainingArtifact()

        XCTAssertEqual(GeometryArtifact.currentSchemaVersion, 35)
        XCTAssertEqual(GeometryWorkerExecutionArtifact.currentSchemaVersion, 13)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(GeometryArtifact.self, from: encoder.encode(geometry)),
            geometry
        )
        let geometryDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(geometry))
                as? [String: Any]
        )
        XCTAssertNotNil(geometryDocument["observationCount"])
        XCTAssertNil(geometryDocument["trackCount"])
        XCTAssertNil(geometryDocument["fallbackReason"])
        XCTAssertEqual(
            try decoder.decode(TrainingArtifact.self, from: encoder.encode(training)),
            training
        )

        var retiredGeometry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(geometry)) as? [String: Any]
        )
        retiredGeometry.removeValue(forKey: "conditioning")
        XCTAssertThrowsError(
            try decoder.decode(
                GeometryArtifact.self,
                from: JSONSerialization.data(withJSONObject: retiredGeometry)
            )
        )
    }

    func testGeometryPersistsTheExactCanonicalColmapRuntimeClosureShape() throws {
        let geometry = makeGeometryArtifact()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(geometry))
                as? [String: Any]
        )
        let worker = try XCTUnwrap(object["workerExecution"] as? [String: Any])
        let closure = try XCTUnwrap(
            worker["colmapRuntimeClosure"] as? [String: Any]
        )
        let components = try XCTUnwrap(
            closure["components"] as? [[String: Any]]
        )

        XCTAssertEqual(Set(closure.keys), ["components", "closureSHA256"])
        XCTAssertEqual(
            components.compactMap { $0["toolchainRelativePath"] as? String },
            ColmapRuntimeClosureEvidence.canonicalToolchainRelativePaths
        )
        XCTAssertTrue(components.allSatisfy {
            Set($0.keys) == ["toolchainRelativePath", "sha256"]
        })
        XCTAssertEqual(
            closure["closureSHA256"] as? String,
            geometry.provenance.solver.payloadSHA256
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
        geometryBackend: .colmap,
        modelIdentifier: "none",
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
        geometryWorkerBudget: GeometryWorkerBudget(
            featureExtractionWorkers: 12,
            coupledMatchingWorkers: 8,
            vocabularyRetrievalWorkers: 8,
            maximumConcurrentVideoSourceAnalysisTasks: 4
        ),
        requiredToolchainCapabilities: ["geometry.colmap", "runtime.core", "training.msplat"],
        baGlobalFramesRatio: 1.4,
        baGlobalPointsRatio: 1.4,
        baLocalMaxRefinements: 2,
        baGlobalMaxRefinements: 5
    )
}

func makeGeometryArtifact(
    sourceModelPath: String = "SfM/colmap/sparse/0",
    workerBudget: GeometryWorkerBudget = GeometryWorkerBudget(
        featureExtractionWorkers: 12,
        coupledMatchingWorkers: 8,
        vocabularyRetrievalWorkers: 8,
        maximumConcurrentVideoSourceAnalysisTasks: 4
    )
) -> GeometryArtifact {
    let runtimeClosure = makeColmapRuntimeClosureEvidence()
    let modelHashes = canonicalTextModelHashes()
    return GeometryArtifact(
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
        cameraGroupingReceipt: ColmapCameraGroupingReceipt(
            mode: .allSelectedImagesShared,
            cameraCountBefore: 2,
            cameraCountAfter: 1,
            groupedVideoSourceCount: 0,
            groups: [
                ColmapCameraGroupReceipt(
                    sourceGroupID: "all-selected-images",
                    memberCount: 2,
                    canonicalCameraID: 1
                )
            ]
        ),
        cameraInitializationReceipt: ColmapCameraInitializationReceipt(
            recipe: .colmapAutomatic,
            cameraModel: "PINHOLE",
            singleCamera: true,
            pixelWidth: nil,
            pixelHeight: nil,
            diagonalFieldOfViewDegrees: nil,
            cameraParameters: nil,
            priorFocalLength: false
        ),
        featureDatabaseDigest: String(repeating: "e", count: 64),
        registeredViewCount: 2,
        totalViewCount: 2,
        observationCount: 120,
        pointCount: 80,
        residualProvenance: "bundle-adjusted-observations",
        medianPixelResidual: 0.42,
        p90PixelResidual: 0.91,
        conditioning: makeGeometryConditioningArtifact(
            modelHashes: modelHashes,
            registeredViewCount: 2,
            pointCount: 80,
            observationCount: 120
        ),
        timings: ["solve": 3.25, "refine": 1.75],
        peakMemoryBytes: 2_147_483_648,
        modelHashes: modelHashes,
        provenance: GeometryProvenance(
            toolchainVersion: "2.0.0",
            solver: GeometryComponentProvenance(
                identifier: "colmap",
                version: "4.1.1",
                revision: "a0d785fba74b2664f31edc4a29026a8b27c00f67",
                payloadSHA256: runtimeClosure.closureSHA256
            ),
            runtime: nil,
            model: nil
        ),
        workerExecution: makeGeometryWorkerExecutionArtifact(
            resolvedBudget: workerBudget,
            pairExecution: ColmapPairWorkerExecutionEvidence(
                attemptOrdinal: 1,
                descriptorMatcher: .faiss,
                scheduledPairCount: 1,
                pairListDigest: String(repeating: "d", count: 64)
            ),
            colmapRuntimeClosure: runtimeClosure
        ),
        pairGraph: .measured(PairGraphMeasurement(
            scheduledPairCount: 1,
            attemptedPairCount: 1,
            rawMatchedPairCount: 1,
            spatiallyVerifiedPairCount: 1,
            localPairCount: 1,
            retrievalPairCount: 0,
            loopRevisitPairCount: 0,
            connectedComponentCount: 1,
            isolatedViewCount: 0,
            componentViewCounts: [2],
            articulationViewCount: 0,
            biconnectedBlockCount: 1,
            largestBiconnectedBlockViewCount: 2,
            secondLargestBiconnectedBlockViewCount: 0,
            degreeP10: 1,
            degreeMedian: 1,
            degreeP90: 1,
            matcherAttempts: [
                PairMatchingAttemptArtifact(
                    attemptNumber: 1,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .completed,
                    scheduledPairCount: 1,
                    attemptedPairCount: 1,
                    rawMatchedPairCount: 1,
                    spatiallyVerifiedPairCount: 1,
                    durationSeconds: 0.01
                ),
            ],
            pairListDigest: String(repeating: "d", count: 64),
            featureDatabaseDigest: String(repeating: "e", count: 64),
            matchingDatabaseDigest: String(repeating: "f", count: 64),
            matchingDurationSeconds: 0.01
        )),
        mapping: MappingArtifact(
            modelCount: 1,
            largestModelRegisteredViewCount: 2,
            secondLargestModelRegisteredViewCount: 0,
            unionRegisteredViewCount: 2,
            attemptCount: 1,
            acceptedMappingAttemptOrdinal: 1,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 1,
            incrementalCadence: IncrementalMappingCadenceArtifact(
                localMaxRefinements: 2,
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5
            ),
            canonicalModelPublication: directTextPublication(),
            fallbackReason: nil
        ),
        canonicalOrientation: .unresolved(
            openingViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
        )
    )
}

func makeGeometryConditioningArtifact(
    modelHashes: [String: String] = canonicalTextModelHashes(),
    registeredViewCount: Int = 2,
    pointCount: Int = 80,
    observationCount: Int = 120
) -> GeometryConditioningArtifact {
    GeometryConditioningArtifact(
        sourceModelClosureSHA256: GeometryArtifactStore.modelClosureDigest(
            modelHashes,
            expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
        )!,
        measurement: GeometryConditioningMeasurement(
            pointCount: pointCount,
            observationCount: observationCount,
            positiveDepthObservationCount: observationCount,
            stronglyMeasuredViewCount: registeredViewCount,
            registeredViewCount: registeredViewCount,
            perViewObservationMinimum: observationCount / registeredViewCount,
            perViewObservationP10: observationCount / registeredViewCount,
            perViewObservationMedian: Double(observationCount) / Double(registeredViewCount),
            perViewObservationP90: observationCount / registeredViewCount,
            distinctTrackLengthMinimum: 2,
            distinctTrackLengthP10: 2,
            distinctTrackLengthMedian: 2,
            distinctTrackLengthP90: registeredViewCount,
            pointsAtLeast1Point5Degrees: pointCount,
            pointsAtLeast2Degrees: pointCount,
            pointsAtLeast3Degrees: pointCount,
            observationsAtLeast1Point5Degrees: observationCount,
            observationsAtLeast2Degrees: observationCount,
            observationsAtLeast3Degrees: observationCount,
            medianObservedDepth: 10,
            cameraBaselineToMedianDepthRatio: 0.2,
            effectiveCameraCenterCount: registeredViewCount,
            largestCameraCenterClusterSize: 1,
            cameraCenterMergeToleranceToMedianDepthRatio: 1e-5,
            numericallyConditionedPointCount: pointCount,
            numericallyConditionedObservationCount: observationCount,
            adaptiveParallaxThresholdMedianDegrees: 0.05,
            adaptiveParallaxThresholdP90Degrees: 0.05,
            cameraCenterEigenvalues: [0, 0, 1],
            pointEigenvalues: [0, 0.4, 0.6],
            cameraPairEvaluationCount:
                registeredViewCount * (registeredViewCount - 1) / 2,
            rayPairEvaluationCount: pointCount
        )
    )
}

func makeColmapRuntimeClosureEvidence(
    executableSHA256: String = String(repeating: "a", count: 64),
    openMPSHA256: String = String(repeating: "b", count: 64)
) -> ColmapRuntimeClosureEvidence {
    let components = [
        ColmapRuntimeClosureEvidence.Component(
            toolchainRelativePath: "bin/colmap",
            sha256: executableSHA256
        ),
        ColmapRuntimeClosureEvidence.Component(
            toolchainRelativePath: "lib/libomp.dylib",
            sha256: openMPSHA256
        ),
    ]
    return ColmapRuntimeClosureEvidence(
        components: components,
        closureSHA256: try! XCTUnwrap(
            ColmapRuntimeClosureEvidence.closureDigest(for: components)
        )
    )
}

func canonicalTextModelHashes(_ character: Character = "a") -> [String: String] {
    let digest = String(repeating: String(character), count: 64)
    return [
        "cameras.txt": digest,
        "images.txt": digest,
        "points3D.txt": digest,
    ]
}

func directTextPublication(
    _ hashes: [String: String] = canonicalTextModelHashes()
) -> CanonicalModelPublicationArtifact {
    CanonicalModelPublicationArtifact(
        kind: .directText,
        sourceModelHashes: hashes,
        conversion: nil
    )
}

func makeGeometryWorkerExecutionArtifact(
    resolvedBudget: GeometryWorkerBudget,
    videoSourceCount: Int = 0,
    pairExecution: ColmapPairWorkerExecutionEvidence? = nil,
    colmapRuntimeClosure: ColmapRuntimeClosureEvidence = makeColmapRuntimeClosureEvidence()
) -> GeometryWorkerExecutionArtifact {
    func boundedInvocation(
        _ command: ColmapWorkerCommandIdentity,
        workerCount: Int,
        pairExecution: ColmapPairWorkerExecutionEvidence? = nil
    ) -> ColmapWorkerInvocationEvidence {
        let environment = [
            "OMP_NUM_THREADS": "\(workerCount)",
            "OPENBLAS_NUM_THREADS": "\(workerCount)",
            "MKL_NUM_THREADS": "\(workerCount)",
        ]
        return ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: nil,
            threadPolicy: .bounded,
            argvWorkerCount: workerCount,
            explicitThreadEnvironment: environment,
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: environment,
            pairExecution: pairExecution,
            exitStatus: 0,
            succeeded: true
        )
    }

    func nativeInvocation(
        _ command: ColmapWorkerCommandIdentity
    ) -> ColmapWorkerInvocationEvidence {
        let mapperExecution = command == .mapper
            ? ColmapMapperWorkerExecutionEvidence(
                incrementalCadence: .balancedGlobal,
                globalMaxNumIterations: 75,
                randomSeed: 42,
                refineFocalLength: true,
                minimumPairInlierCount: 15,
                pairGraphAttemptOrdinal: pairExecution?.attemptOrdinal ?? 1,
                pairListDigest: pairExecution?.pairListDigest
                    ?? String(repeating: "d", count: 64),
                descriptorMatcher: pairExecution?.descriptorMatcher ?? .faiss,
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                evaluation: ColmapMapperEvaluationEvidence(
                    status: .accepted,
                    fallbackTrigger: nil
                )
            )
            : nil
        return ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: 1,
            threadPolicy: .nativeAuto,
            argvWorkerCount: nil,
            explicitThreadEnvironment: [:],
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: [:],
            mapperExecution: mapperExecution,
            exitStatus: 0,
            succeeded: true
        )
    }
    return GeometryWorkerExecutionArtifact(
        colmapRuntimeClosure: colmapRuntimeClosure,
        resolvedBudget: resolvedBudget,
        featureExtractionInvocations: [
            boundedInvocation(
                .featureExtractor,
                workerCount: resolvedBudget.featureExtractionWorkers
            ),
        ],
        matchingInvocations: [
            boundedInvocation(
                .matchesImporter,
                workerCount: resolvedBudget.coupledMatchingWorkers,
                pairExecution: pairExecution
            ),
        ],
        vocabularyRetrievalInvocations: [],
        mappingAndRefinementInvocations: [
            nativeInvocation(.mapper),
            nativeInvocation(.modelAnalyzer),
        ],
        videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: videoSourceCount,
            startedAnalysisTaskCount: videoSourceCount,
            peakInFlightAnalysisTaskCount: videoSourceCount == 0
                ? 0
                : min(videoSourceCount, resolvedBudget.maximumConcurrentVideoSourceAnalysisTasks)
        )
    )
}

func makeMsplatDatasetDerivation(
    inputDigest: String,
    geometryDigest: String,
    registeredImageNames: [String] = ["frame_000000.jpg"],
    preparationKind: MsplatDatasetPreparationKind = .direct,
    sourceGeometryManifestSHA256: String = String(repeating: "d", count: 64),
    sourceSelectedFramesDigest: String = String(repeating: "e", count: 64),
    maximumImageDimension: Int = 1_024
) -> MsplatDatasetDerivationArtifact {
    MsplatDatasetDerivationArtifact(
        sourceGeometryManifestSHA256: sourceGeometryManifestSHA256,
        sourceSelectedFramesDigest: sourceSelectedFramesDigest,
        preparationKind: preparationKind,
        maximumImageDimension: maximumImageDimension,
        toolchainVersion: "2.0.0",
        colmapProvenance: GeometryComponentProvenance(
            identifier: "colmap",
            version: "4.0.4",
            revision: String(repeating: "f", count: 40),
            payloadSHA256: String(repeating: "a", count: 64)
        ),
        registeredImageNames: registeredImageNames,
        datasetInputDigest: inputDigest,
        datasetGeometryDigest: geometryDigest
    )
}

func makeTrainingArtifact(
    checkpointPath: String? = nil,
    outputPath: String? = "Output/splat.ply",
    completionStatus: TrainingCompletionStatus = .completed
) -> TrainingArtifact {
    let inputDigest = String(repeating: "b", count: 64)
    let geometryDigest = String(repeating: "c", count: 64)
    return TrainingArtifact(
        trainerVersion: "trainer-1.4.0",
        runtimeVersion: "native-metal-cli-v2",
        trainerBuildDigest: String(repeating: "a", count: 64),
        inputDigest: inputDigest,
        geometryDigest: geometryDigest,
        datasetDerivation: makeMsplatDatasetDerivation(
            inputDigest: inputDigest,
            geometryDigest: geometryDigest
        ),
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
        resourceAdmission: makeTestTrainingResourceAdmission(),
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
