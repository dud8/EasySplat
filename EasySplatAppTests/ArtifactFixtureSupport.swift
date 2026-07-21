import CryptoKit
import Foundation
@testable import EasySplatCore

/// Publishes the authenticated sidecars required by result-workspace tests.
/// The fixture uses a tiny three-view reconstruction while preserving the plan
/// under test. This keeps result-workspace tests honest about plan/artifact binding
/// without depending on the reconstruction pipeline.
func persistCompletedAppTestArtifacts(
    metadata suppliedMetadata: ProjectMetadata,
    paths: ProjectPaths,
    trainingArtifact suppliedTrainingArtifact: TrainingArtifact
) throws {
    var metadata = suppliedMetadata
    let plan = metadata.resolvedRunPlan ?? RunPlanResolver.resolve(
        requestedOptions: metadata.requestedRunOptions,
        input: metadata.input,
        hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
        developmentOverrides: .none
    )
    metadata.resolvedRunPlan = plan
    if suppliedTrainingArtifact.completionStatus == .completed,
       metadata.state.stage == .done,
       metadata.state.lastError == nil {
        metadata.checkpoint = nil
        metadata.lastRunStartedAt = nil
    }
    try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

    // Geometry artifacts authenticate imported bytes independently of project.json.
    // Several app tests intentionally use an empty logical input list, so provide a
    // private imported-byte fixture without rewriting the behavior under test.
    let importedInput = paths.originalsURL.appendingPathComponent("fixture.mov")
    if !FileManager.default.fileExists(atPath: importedInput.path) {
        try Data("authenticated app-test input".utf8).write(to: importedInput, options: .atomic)
    }

    let imageNames = (1...3).map { String(format: "frame_%06d.jpg", $0) }
    for (index, imageName) in imageNames.enumerated() {
        try Data("selected frame \(index + 1)".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent(imageName),
            options: .atomic
        )
    }

    let modelURL = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
    try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
    let pointCount = 25
    let points = (0..<pointCount).map { index -> (x: Double, y: Double, z: Double) in
        let rowCount = Int(ceil(Double(pointCount) / 5))
        return (
            Double(index % 5 - 2) * 0.75,
            (Double(index / 5) - Double(rowCount - 1) / 2) * 0.75,
            12
        )
    }
    var pointTracks = Array(repeating: [String](), count: points.count)
    let images = imageNames.enumerated().flatMap { offset, name -> [String] in
        let imageID = offset + 1
        let centerX = (Double(offset) - 1) * 2
        let observations = points.enumerated().map { pointIndex, point in
            let x = 500 * (point.x - centerX) / point.z + 320
            let y = 500 * point.y / point.z + 240
            pointTracks[pointIndex].append("\(imageID) \(pointIndex)")
            return "\(x) \(y) \(pointIndex + 1)"
        }.joined(separator: " ")
        return [
            "\(imageID) 1 0 0 0 \(-centerX) 0 0 1 \(name)",
            observations,
        ]
    }.joined(separator: "\n") + "\n"
    let pointRows = points.enumerated().map { index, point in
        "\(index + 1) \(point.x) \(point.y) \(point.z) 255 255 255 0 "
            + pointTracks[index].joined(separator: " ")
    }.joined(separator: "\n") + "\n"
    let usesSharedFisheye = plan.cameraInitializationRecipe
        == .sharedOpenCVFisheyeEquidistantDiagonal150V1
    let cameraModel = usesSharedFisheye ? "OPENCV_FISHEYE" : "SIMPLE_PINHOLE"
    let sharedFisheyeFocal = hypot(320.0, 240.0) / (75.0 * .pi / 180.0)
    let cameraLine = usesSharedFisheye
        ? "1 OPENCV_FISHEYE 640 480 \(sharedFisheyeFocal) \(sharedFisheyeFocal) 320 240 0 0 0 0\n"
        : "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
    let modelContents = [
        "cameras.txt": cameraLine,
        "images.txt": images,
        "points3D.txt": pointRows,
    ]
    var modelHashes: [String: String] = [:]
    for (name, contents) in modelContents {
        let data = Data(contents.utf8)
        try data.write(to: modelURL.appendingPathComponent(name), options: .atomic)
        modelHashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    let pairListDigest = String(repeating: "d", count: 64)
    let featureDatabaseDigest = String(repeating: "e", count: 64)
    let matchingDatabaseDigest = String(repeating: "f", count: 64)
    let runtimeComponents = [
        ColmapRuntimeClosureEvidence.Component(
            toolchainRelativePath: "bin/colmap",
            sha256: String(repeating: "a", count: 64)
        ),
        ColmapRuntimeClosureEvidence.Component(
            toolchainRelativePath: "lib/libomp.dylib",
            sha256: String(repeating: "b", count: 64)
        ),
    ]
    guard let runtimeDigest = ColmapRuntimeClosureEvidence.closureDigest(for: runtimeComponents),
          let modelClosureDigest = GeometryArtifactStore.modelClosureDigest(
            modelHashes,
            expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
          ) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let runtimeClosure = ColmapRuntimeClosureEvidence(
        components: runtimeComponents,
        closureSHA256: runtimeDigest
    )
    let workerEvidence = makeAppTestWorkerEvidence(
        plan: plan,
        runtimeClosure: runtimeClosure,
        pairListDigest: pairListDigest,
        matchingDatabaseDigest: matchingDatabaseDigest,
        videoSourceCount: metadata.input.videoFiles.count
    )
    _ = try GeometryWorkerExecutionArtifactStore.save(
        workerEvidence,
        to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
        expectedBudget: plan.geometryWorkerBudget,
        projectPaths: paths
    )
    let analysis = try ColmapResidualAnalyzer.analyzeConditioning(
        modelDirectory: modelURL,
        maximumRayPairEvaluations: GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
    )
    let measurement = analysis.residuals
    let retrievalWasScheduled = PairGraphRetrievalScheduling.isRequired(
        pairingPolicy: plan.pairingPolicy,
        selectedFrameCount: imageNames.count,
        requiresCrossClipRetrieval: plan.requiresCrossClipRetrieval
    )
    let pairGraph = PairGraphArtifact.measured(PairGraphMeasurement(
        pairingPolicy: plan.pairingPolicy,
        scheduledPairCount: 3,
        attemptedPairCount: 3,
        rawMatchedPairCount: 3,
        spatiallyVerifiedPairCount: 3,
        localPairCount: 3,
        retrievalPairCount: 0,
        loopRevisitPairCount: 0,
        connectedComponentCount: 1,
        isolatedViewCount: 0,
        componentViewCounts: [3],
        articulationViewCount: 0,
        biconnectedBlockCount: 1,
        largestBiconnectedBlockViewCount: 3,
        secondLargestBiconnectedBlockViewCount: 0,
        degreeP10: 2,
        degreeMedian: 2,
        degreeP90: 2,
        matcherAttempts: [PairMatchingAttemptArtifact(
            attemptNumber: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        )],
        pairListDigest: pairListDigest,
        featureDatabaseDigest: featureDatabaseDigest,
        matchingDatabaseDigest: matchingDatabaseDigest,
        matchingDurationSeconds: 0.01
    ), retrievalWasScheduled: retrievalWasScheduled)
    let publication = CanonicalModelPublicationArtifact(
        kind: .directText,
        sourceModelHashes: modelHashes,
        conversion: nil
    )
    let groupingReceipt: ColmapCameraGroupingReceipt
    switch plan.cameraGrouping {
    case .mixedCamerasOrLenses:
        if metadata.input.videoFiles.isEmpty {
            groupingReceipt = ColmapCameraGroupingReceipt(
                mode: .preserveExisting,
                cameraCountBefore: imageNames.count,
                cameraCountAfter: imageNames.count,
                groupedVideoSourceCount: 0,
                groups: []
            )
        } else {
            let videoCount = metadata.input.videoFiles.count
            let baseMemberCount = imageNames.count / videoCount
            let remainder = imageNames.count % videoCount
            let groups = (0..<videoCount).map { index in
                ColmapCameraGroupReceipt(
                    sourceGroupID: "video-\(index + 1)",
                    memberCount: baseMemberCount + (index < remainder ? 1 : 0),
                    canonicalCameraID: Int64(index + 1)
                )
            }
            groupingReceipt = ColmapCameraGroupingReceipt(
                mode: .videoSourceGroups,
                cameraCountBefore: imageNames.count,
                cameraCountAfter: groups.count,
                groupedVideoSourceCount: videoCount,
                groups: groups
            )
        }
    case .automatic, .sameCameraAndLens:
        groupingReceipt = ColmapCameraGroupingReceipt(
            mode: .allSelectedImagesShared,
            cameraCountBefore: imageNames.count,
            cameraCountAfter: 1,
            groupedVideoSourceCount: metadata.input.videoFiles.count,
            groups: [ColmapCameraGroupReceipt(
                sourceGroupID: "all-selected-images",
                memberCount: imageNames.count,
                canonicalCameraID: 1
            )]
        )
    }
    let initializationReceipt: ColmapCameraInitializationReceipt
    if usesSharedFisheye {
        initializationReceipt = try ColmapCameraInitializationReceipt.resolve(
            recipe: plan.cameraInitializationRecipe,
            cameraModel: cameraModel,
            singleCamera: true,
            uniformDimensions: SelectedImagePixelDimensions(width: 640, height: 480)
        )
    } else {
        initializationReceipt = ColmapCameraInitializationReceipt(
            recipe: plan.cameraInitializationRecipe,
            cameraModel: cameraModel,
            singleCamera: groupingReceipt.mode == .allSelectedImagesShared,
            pixelWidth: nil,
            pixelHeight: nil,
            diagonalFieldOfViewDegrees: nil,
            cameraParameters: nil,
            priorFocalLength: false
        )
    }
    let geometry = GeometryArtifact(
        schemaVersion: GeometryArtifact.currentSchemaVersion,
        solverVersion: "colmap; COLMAP 4.1.1",
        runtimeVersion: "easysplat-app-test",
        modelVersion: "none",
        inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
        selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: imageNames,
            projectPaths: paths
        ),
        orderedImageNames: imageNames,
        orderedImageTimestamps: [0, 0.5, 1],
        sourceModelPath: "SfM/colmap/sparse/0",
        poseConvention: "world-to-camera",
        quaternionOrder: "wxyz",
        handedness: "right-handed",
        scaleType: "arbitrary-sim3",
        cameraModel: cameraModel,
        cameraGrouping: plan.cameraGrouping,
        cameraGroupingReceipt: groupingReceipt,
        cameraInitializationReceipt: initializationReceipt,
        featureDatabaseDigest: featureDatabaseDigest,
        registeredViewCount: imageNames.count,
        totalViewCount: imageNames.count,
        observationCount: measurement.observationCount,
        pointCount: measurement.pointCount,
        residualProvenance: measurement.provenance,
        medianPixelResidual: measurement.medianPixelResidual,
        p90PixelResidual: measurement.p90PixelResidual,
        conditioning: GeometryConditioningArtifact(
            sourceModelClosureSHA256: modelClosureDigest,
            measurement: analysis.measurement
        ),
        timings: ["sfmMapping": 0.01, "orientation_estimation_seconds": 0.001],
        peakMemoryBytes: 1_024,
        modelHashes: modelHashes,
        provenance: GeometryProvenance(
            toolchainVersion: "2.0.0",
            solver: GeometryComponentProvenance(
                identifier: "colmap",
                version: "4.1.1",
                revision: String(repeating: "f", count: 40),
                payloadSHA256: runtimeDigest
            ),
            runtime: nil,
            model: nil
        ),
        workerExecution: workerEvidence,
        pairGraph: pairGraph,
        mapping: MappingArtifact(
            modelCount: 1,
            largestModelRegisteredViewCount: imageNames.count,
            secondLargestModelRegisteredViewCount: 0,
            unionRegisteredViewCount: imageNames.count,
            attemptCount: 1,
            acceptedMappingAttemptOrdinal: 1,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 1,
            incrementalCadence: plan.incrementalMappingCadence,
            canonicalModelPublication: publication,
            fallbackReason: nil
        ),
        canonicalOrientation: .unresolved(
            openingViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
        )
    )
    try GeometryArtifactStore.persist(geometry, metadata: &metadata, paths: paths)

    var trainingArtifact = suppliedTrainingArtifact
    let geometryManifestDigest = try GeometryArtifactStore.manifestDigest(
        matching: geometry,
        at: paths.geometryManifestURL
    )
    trainingArtifact.inputDigest = geometry.inputDigest
    trainingArtifact.geometryDigest = modelClosureDigest
    trainingArtifact.detailProfile = metadata.requestedRunOptions.detailProfile
    trainingArtifact.iterationLimit = plan.trainerIterationLimit
    trainingArtifact.plateauWindow = plan.plateauWindow
    trainingArtifact.cameraOrderSeed = plan.runSeed
    trainingArtifact.resourceAdmission = makeAppTestTrainingResourceAdmission(
        resourcePolicy: metadata.requestedRunOptions.resourcePolicy
    )
    trainingArtifact.memoryBudgetBytes = min(
        max(1, trainingArtifact.memoryBudgetBytes),
        plan.trainerMemoryBudgetBytes
    )
    trainingArtifact.datasetDerivation.sourceGeometryManifestSHA256 = geometryManifestDigest
    trainingArtifact.datasetDerivation.sourceSelectedFramesDigest = geometry.selectedFramesDigest
    trainingArtifact.datasetDerivation.registeredImageNames = imageNames
    trainingArtifact.datasetDerivation.datasetInputDigest = trainingArtifact.inputDigest
    trainingArtifact.datasetDerivation.datasetGeometryDigest = trainingArtifact.geometryDigest
    try TrainingArtifactStore.persist(trainingArtifact, paths: paths)
    _ = try ProjectArtifactSnapshotStore.load(projectURL: paths.root)
}

private func makeAppTestWorkerEvidence(
    plan: ResolvedRunPlan,
    runtimeClosure: ColmapRuntimeClosureEvidence,
    pairListDigest: String,
    matchingDatabaseDigest: String,
    videoSourceCount: Int
) -> GeometryWorkerExecutionArtifact {
    func bounded(
        _ command: ColmapWorkerCommandIdentity,
        workers: Int,
        pairExecution: ColmapPairWorkerExecutionEvidence? = nil
    ) -> ColmapWorkerInvocationEvidence {
        let environment = [
            "OMP_NUM_THREADS": "\(workers)",
            "OPENBLAS_NUM_THREADS": "\(workers)",
            "MKL_NUM_THREADS": "\(workers)",
        ]
        return ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: nil,
            threadPolicy: .bounded,
            argvWorkerCount: workers,
            explicitThreadEnvironment: environment,
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: environment,
            pairExecution: pairExecution,
            exitStatus: 0,
            succeeded: true
        )
    }
    func native(
        _ command: ColmapWorkerCommandIdentity,
        mapperExecution: ColmapMapperWorkerExecutionEvidence? = nil
    ) -> ColmapWorkerInvocationEvidence {
        ColmapWorkerInvocationEvidence(
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
    let pairExecution = ColmapPairWorkerExecutionEvidence(
        attemptOrdinal: 1,
        descriptorMatcher: .faiss,
        scheduledPairCount: 3,
        pairListDigest: pairListDigest
    )
    let mapperExecution = ColmapMapperWorkerExecutionEvidence(
        incrementalCadence: plan.incrementalMappingCadence,
        globalMaxNumIterations: 75,
        randomSeed: Int32(plan.runSeed),
        refineFocalLength: true,
        minimumPairInlierCount: ColmapMappingPolicy.minimumPairInlierCount,
        pairGraphAttemptOrdinal: 1,
        pairListDigest: pairListDigest,
        descriptorMatcher: .faiss,
        matchingDatabaseDigest: matchingDatabaseDigest,
        evaluation: ColmapMapperEvaluationEvidence(status: .accepted, fallbackTrigger: nil)
    )
    return GeometryWorkerExecutionArtifact(
        colmapRuntimeClosure: runtimeClosure,
        resolvedBudget: plan.geometryWorkerBudget,
        featureExtractionInvocations: [bounded(
            .featureExtractor,
            workers: plan.geometryWorkerBudget.featureExtractionWorkers
        )],
        matchingInvocations: [bounded(
            .matchesImporter,
            workers: plan.geometryWorkerBudget.coupledMatchingWorkers,
            pairExecution: pairExecution
        )],
        vocabularyRetrievalInvocations: [],
        mappingAndRefinementInvocations: [
            native(.mapper, mapperExecution: mapperExecution),
            native(.modelAnalyzer),
        ],
        videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: videoSourceCount,
            startedAnalysisTaskCount: videoSourceCount,
            peakInFlightAnalysisTaskCount: videoSourceCount == 0 ? 0 : 1
        )
    )
}
