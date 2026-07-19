import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryArtifactStoreTests: XCTestCase {
    private var geometryWorkerBudget: GeometryWorkerBudget {
        GeometryWorkerBudget(
            featureExtractionWorkers: 12,
            coupledMatchingWorkers: 8,
            vocabularyRetrievalWorkers: 8,
            maximumConcurrentVideoSourceAnalysisTasks: 4
        )
    }

    private var resolvedRunPlan: ResolvedRunPlan {
        var plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        plan.geometryWorkerBudget = geometryWorkerBudget
        plan.cameraGrouping = .sameCameraAndLens
        return plan
    }

    func testCurrentSchemaPersistsObservationSemanticsWithoutRetiredTrackKey() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(makeArtifact(fixture: fixture))
            ) as? [String: Any]
        )

        XCTAssertEqual(GeometryArtifact.currentSchemaVersion, 35)
        XCTAssertEqual(object["schemaVersion"] as? Int, 35)
        XCTAssertEqual(object["observationCount"] as? Int, fixture.observationCount)
        XCTAssertNil(object["trackCount"])

        var retiredObject = object
        retiredObject["trackCount"] = retiredObject.removeValue(forKey: "observationCount")
        let retiredData = try JSONSerialization.data(withJSONObject: retiredObject)
        XCTAssertThrowsError(try JSONDecoder().decode(GeometryArtifact.self, from: retiredData))
    }

    func testValidateAcceptsCurrentTrustedCanonicalSnapshot() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let measured = try ColmapResidualAnalyzer.analyze(modelDirectory: model)
        let snapshot = try GeometryModelSnapshot.capture(in: model)

        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(
                makeArtifact(fixture: fixture),
                projectPaths: paths,
                measuredResiduals: measured,
                verifiedSourceSnapshot: snapshot
            )
        )
    }

    func testPersistReusesPublishedConditioningAnalysisBoundToCanonicalModel() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let analysis = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            maximumRayPairEvaluations:
                GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
        )
        var metadata = ProjectMetadata(
            title: "Published analysis",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            resolvedRunPlan: resolvedRunPlan
        )
        let artifact = makeArtifact(fixture: fixture)
        let metadataBeforePersist = metadata

        try GeometryArtifactStore.persist(
            artifact,
            metadata: &metadata,
            paths: paths,
            measuredResiduals: analysis.residuals,
            verifiedSourceSnapshot: analysis.modelSnapshot,
            measuredAnalysis: analysis
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(metadata),
            try encoder.encode(metadataBeforePersist)
        )
        XCTAssertEqual(
            try GeometryArtifactStore.manifestDigest(
                matching: artifact,
                at: paths.geometryManifestURL
            ).count,
            64
        )
    }

    func testPersistRejectsDa3ModelThatDoesNotMatchResolvedPlanBeforePublication() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        let smallRevision = "89abcdef0123456789abcdef0123456789abcdef"
        artifact.modelVersion = "DA3-SMALL@\(smallRevision)"
        artifact.provenance.runtime = GeometryComponentProvenance(
            identifier: "da3_mps",
            version: "main",
            revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
            payloadSHA256: String(repeating: "b", count: 64)
        )
        artifact.provenance.model = GeometryComponentProvenance(
            identifier: "DA3-SMALL",
            version: "apache-2.0-release",
            revision: smallRevision,
            payloadSHA256: String(repeating: "c", count: 64)
        )
        var basePlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        basePlan.geometryWorkerBudget = geometryWorkerBudget
        var metadata = ProjectMetadata(
            title: "Mismatched DA3 model",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            resolvedRunPlan: basePlan
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.persist(
                artifact,
                metadata: &metadata,
                paths: paths
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidRunPlanBinding
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
    }

    func testPersistRejectsPublishedAnalysisFromAnotherModelClosure() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("accepted"))
        let otherPaths = ProjectPaths(root: root.appendingPathComponent("other"))
        try paths.ensureDirectories()
        try otherPaths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        _ = try writeCanonicalModel(at: otherPaths, observationCount: 30)
        let otherModel = otherPaths.colmapSparseURL.appendingPathComponent(
            "0",
            isDirectory: true
        )
        let otherAnalysis = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: otherModel,
            maximumRayPairEvaluations:
                GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
        )
        var metadata = ProjectMetadata(
            title: "Mismatched analysis",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            resolvedRunPlan: resolvedRunPlan
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.persist(
                makeArtifact(fixture: fixture),
                metadata: &metadata,
                paths: paths,
                measuredAnalysis: otherAnalysis
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .modelHashMismatch("images.txt")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
    }

    func testValidateRejectsConditioningBoundToAnotherModelClosure() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        artifact.conditioning.sourceModelClosureSHA256 = String(repeating: "f", count: 64)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidConditioning)
        }
    }

    func testLoadRecomputesAndRejectsTamperedConditioningMeasurement() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let artifact = makeArtifact(fixture: fixture)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact))
                as? [String: Any]
        )
        var conditioning = try XCTUnwrap(object["conditioning"] as? [String: Any])
        var measurement = try XCTUnwrap(conditioning["measurement"] as? [String: Any])
        let ratio = try XCTUnwrap(measurement["cameraBaselineToMedianDepthRatio"] as? Double)
        measurement["cameraBaselineToMedianDepthRatio"] = ratio.nextUp
        conditioning["measurement"] = measurement
        object["conditioning"] = conditioning
        try JSONSerialization.data(withJSONObject: object).write(
            to: paths.geometryManifestURL,
            options: [.atomic]
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .conditioningMismatch)
        }
    }

    func testValidateRejectsMissingOrMismatchedCanonicalWorkerExecution() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let artifact = makeArtifact(fixture: fixture)
        let workerURL = GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths)

        try FileManager.default.removeItem(at: workerURL)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidWorkerExecution
            )
        }

        var differentWorkerExecution = artifact.workerExecution
        differentWorkerExecution.featureExtractionInvocations.append(
            try XCTUnwrap(
                differentWorkerExecution.featureExtractionInvocations.first
            )
        )
        _ = try GeometryWorkerExecutionArtifactStore.save(
            differentWorkerExecution,
            to: workerURL,
            expectedBudget: geometryWorkerBudget,
            projectPaths: paths
        )
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidWorkerExecution
            )
        }
    }

    func testValidateBindsWorkerEvidenceToTheAcceptedMappingAndPairGraph() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var incrementalWithoutMapper = makeArtifact(fixture: fixture)
        incrementalWithoutMapper.workerExecution.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.pointTriangulator),
            nativeAutoInvocation(.bundleAdjuster),
            nativeAutoInvocation(.modelAnalyzer),
        ]
        try saveCanonicalWorkerExecution(
            incrementalWithoutMapper.workerExecution,
            paths: paths
        )
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(incrementalWithoutMapper, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidWorkerExecution)
        }

        var retrievalWithoutVocabulary = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(retrievalWithoutVocabulary.pairGraph.measurement)
        measurement.pairingPolicy = .orderedOrbit
        measurement.localPairCount -= 1
        measurement.retrievalPairCount = 1
        retrievalWithoutVocabulary.pairGraph = .measured(
            measurement,
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: true
        )
        retrievalWithoutVocabulary.workerExecution.vocabularyRetrievalInvocations = []
        try saveCanonicalWorkerExecution(
            retrievalWithoutVocabulary.workerExecution,
            paths: paths
        )
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(retrievalWithoutVocabulary, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidWorkerExecution)
        }
    }

    func testValidateRejectsUsedVocabularyRetrievalThatWasNotScheduled() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        artifact.pairGraph = PairGraphArtifact(
            status: .measured,
            measurement: artifact.pairGraph.measurement,
            retrievalWasScheduled: false,
            usedLocalVocabularyRetrieval: true
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testValidateRejectsOmittedRetrievalRequiredByPairingPlan() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.pairingPolicy = .orderedOrbit
        artifact.pairGraph = .measured(
            measurement,
            retrievalWasScheduled: false,
            usedLocalVocabularyRetrieval: false
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testValidateRejectsOmittedRetrievalRequiredForShortCrossClipInput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        let measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        artifact.pairGraph = .measured(
            measurement,
            requiresCrossClipRetrieval: true,
            retrievalWasScheduled: false,
            usedLocalVocabularyRetrieval: false
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        let decoded = try JSONDecoder().decode(
            GeometryArtifact.self,
            from: JSONEncoder().encode(artifact)
        )
        XCTAssertTrue(decoded.pairGraph.requiresCrossClipRetrieval)
    }

    func testValidateRejectsCrossClipRetrievalFactForUnorderedPairing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.pairingPolicy = .unorderedRetrieval
        artifact.pairGraph = .measured(
            measurement,
            requiresCrossClipRetrieval: true,
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: false
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testPersistBindsVideoSourceAnalysisEvidenceToMetadataInput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        artifact.workerExecution.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: 0,
            startedAnalysisTaskCount: 0,
            peakInFlightAnalysisTaskCount: 0
        )
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)
        var metadata = ProjectMetadata(
            title: "Video evidence mismatch",
            input: .video(files: ["/tmp/capture.mov"]),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            resolvedRunPlan: resolvedRunPlan
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.persist(artifact, metadata: &metadata, paths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidWorkerExecution)
        }

        artifact.workerExecution.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: 1,
            startedAnalysisTaskCount: 1,
            peakInFlightAnalysisTaskCount: 1
        )
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)
        metadata.input = .photos(folder: "/tmp/photos")
        XCTAssertThrowsError(
            try GeometryArtifactStore.persist(artifact, metadata: &metadata, paths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidWorkerExecution)
        }
    }

    func testLoadBindsResumedWorkerEvidenceToPersistedMetadataInput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let artifact = makeArtifact(fixture: fixture)
        let requestedOptions = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced
        )
        var videoPlan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: .video(files: ["Originals/video-0000.mov"]),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        videoPlan.geometryWorkerBudget = geometryWorkerBudget
        let videoBytes = Data("test-video".utf8)
        let videoSHA256 = SHA256.hash(data: videoBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let clipIdentity = try XCTUnwrap(VideoClipIdentityResolver.resolve(
            sourceSHA256s: [videoSHA256],
            pairingPolicy: videoPlan.pairingPolicy
        ).first)
        let video = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: videoBytes,
            analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: videoPlan),
            clipGroupID: clipIdentity.groupID
        )
        let metadata = ProjectMetadata(
            title: "Resumed video evidence mismatch",
            input: .video(files: [video.receipt.projectRelativePath]),
            videoInputReceipts: [video.receipt],
            requestedRunOptions: requestedOptions,
            resolvedRunPlan: videoPlan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try JSONEncoder().encode(artifact).write(
            to: paths.geometryManifestURL,
            options: [.atomic]
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidWorkerExecution)
        }
    }

    func testValidateRejectsInvalidTimingEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        for timings in [
            [:],
            ["  ": 1],
            ["sfmMapping": -0.01],
            ["sfmMapping": Double.nan],
            ["sfmMapping": 1],
            ["sfmMapping": 1, "orientation_seconds": 0.01],
        ] {
            var artifact = makeArtifact(fixture: fixture)
            artifact.timings = timings
            XCTAssertThrowsError(
                try GeometryArtifactStore.validate(artifact, projectPaths: paths)
            ) { error in
                XCTAssertEqual(
                    error as? GeometryArtifactStore.Error,
                    .invalidTimings
                )
            }
        }
    }

    func testLoadRejectsPreviousSchemaBeforeDecodingItsPayload() throws {
        let baselineSchemaVersion = GeometryArtifact.currentSchemaVersion - 1

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(makeArtifact(fixture: fixture))
            ) as? [String: Any]
        )
        object["schemaVersion"] = baselineSchemaVersion
        object.removeValue(forKey: "mapping")
        try JSONSerialization.data(withJSONObject: object).write(
            to: paths.geometryManifestURL
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidSchema(baselineSchemaVersion)
            )
        }
    }

    func testPersistsRelativeMeasuredArtifactOnlyToSidecar() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Measured",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            resolvedRunPlan: resolvedRunPlan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let artifact = makeArtifact(fixture: fixture)

        try GeometryArtifactStore.persist(artifact, metadata: &metadata, paths: paths)

        XCTAssertEqual(
            try GeometryArtifactStore.load(from: paths.geometryManifestURL, projectPaths: paths),
            artifact
        )
        let persistedMetadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.metadataURL))
                as? [String: Any]
        )
        XCTAssertNil(persistedMetadata["geometryArtifact"])
        XCTAssertNil(persistedMetadata["trainingArtifact"])
        let snapshot = try ProjectArtifactSnapshotStore.load(projectURL: root)
        XCTAssertEqual(snapshot.geometryArtifact, artifact)
        XCTAssertNil(snapshot.trainingArtifact)
        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.geometryManifestURL))
                as? [String: Any]
        )
        XCTAssertEqual(
            (sidecar["pairGraph"] as? [String: Any])?["status"] as? String,
            "measured"
        )
        XCTAssertNil((sidecar["pairGraph"] as? [String: Any])?["mappingAttemptNumber"])
        XCTAssertNil((sidecar["pairGraph"] as? [String: Any])?["bundleAdjustmentCycleCount"])
        XCTAssertEqual((sidecar["mapping"] as? [String: Any])?["modelCount"] as? Int, 1)
        XCTAssertEqual(
            (sidecar["mapping"] as? [String: Any])?["acceptedRefinementKind"] as? String,
            "incrementalGlobal"
        )
        XCTAssertEqual(
            (sidecar["canonicalOrientation"] as? [String: Any])?["status"] as? String,
            "unresolved"
        )
    }

    func testQuickSnapshotDoesNotRehashCanonicalModel() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Quick snapshot",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            resolvedRunPlan: resolvedRunPlan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let artifact = makeArtifact(fixture: fixture)
        try GeometryArtifactStore.persist(artifact, metadata: &metadata, paths: paths)
        try FileManager.default.removeItem(at: paths.colmapSparseModelURL)

        XCTAssertEqual(
            try ProjectArtifactSnapshotStore.load(
                projectURL: root,
                validationDepth: .quick
            ).geometryArtifact,
            artifact
        )
        XCTAssertThrowsError(
            try ProjectArtifactSnapshotStore.load(projectURL: root)
        )
    }

    func testLoadRejectsSymlinkedGeometryManifest() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = ProjectPaths(
            root: parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let outside = parent.appendingPathComponent("outside-geometry.json")
        try JSONEncoder().encode(makeArtifact(fixture: fixture)).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.geometryManifestURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        )
    }

    func testLoadRejectsOversizedOtherwiseDecodableGeometryManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(makeArtifact(fixture: fixture))
            ) as? [String: Any]
        )
        object["ignoredPadding"] = String(repeating: "x", count: 1_048_576)
        let oversized = try JSONSerialization.data(withJSONObject: object)
        XCTAssertGreaterThan(oversized.count, 1_048_576)
        try oversized.write(to: paths.geometryManifestURL)

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        )
    }

    func testLoadRejectsNonRegularGeometryManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.geometryManifestURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        )
    }

    func testPersistRejectsSymlinkedPreviousManifestWithoutTouchingTarget() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = ProjectPaths(
            root: parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Measured",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            resolvedRunPlan: resolvedRunPlan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let outside = parent.appendingPathComponent("outside-geometry.json")
        let sentinel = Data("do not replace".utf8)
        try sentinel.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.geometryManifestURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.persist(
                makeArtifact(fixture: fixture),
                metadata: &metadata,
                paths: paths
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    func testPersistReplacesPreviousManifestWithoutRewritingMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Measured",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            resolvedRunPlan: resolvedRunPlan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let originalMetadata = try Data(contentsOf: paths.metadataURL)
        let previousManifest = Data("previous manifest bytes".utf8)
        try previousManifest.write(to: paths.geometryManifestURL)

        try GeometryArtifactStore.persist(
            makeArtifact(fixture: fixture),
            metadata: &metadata,
            paths: paths
        )

        XCTAssertNotEqual(try Data(contentsOf: paths.geometryManifestURL), previousManifest)
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), originalMetadata)
    }

    func testRejectsEscapingCanonicalPathAndPlaceholderResidualProvenance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var escaping = makeArtifact(fixture: fixture)
        escaping.sourceModelPath = "../outside"
        XCTAssertThrowsError(try GeometryArtifactStore.validate(escaping, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidSourceModelPath)
        }

        let alternate = try paths.resolveProjectRelativePath("SfM/alternate")
        try FileManager.default.copyItem(
            at: paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true),
            to: alternate
        )
        var inBundleButNotCanonical = makeArtifact(fixture: fixture)
        inBundleButNotCanonical.sourceModelPath = "SfM/alternate"
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(inBundleButNotCanonical, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidSourceModelPath)
        }

        var placeholder = makeArtifact(fixture: fixture)
        placeholder.residualProvenance = "mapper-summary"
        XCTAssertThrowsError(try GeometryArtifactStore.validate(placeholder, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidResiduals)
        }

        var unmeasuredMemory = makeArtifact(fixture: fixture)
        unmeasuredMemory.peakMemoryBytes = 0
        XCTAssertThrowsError(try GeometryArtifactStore.validate(unmeasuredMemory, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPeakMemory)
        }
    }

    func testRejectsCanonicalModelWhoseContentsNoLongerMatchManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let artifact = makeArtifact(fixture: fixture)

        try "tampered\n".write(
            to: paths.colmapSparseURL.appendingPathComponent("0/images.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .modelHashMismatch("images.txt")
            )
        }
    }

    func testRejectsHardLinkedCanonicalModelFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let artifact = makeArtifact(fixture: fixture)
        let imagesURL = paths.colmapSparseURL.appendingPathComponent("0/images.txt")
        let externalURL = root.appendingPathComponent("hardlinked-images.txt")
        try FileManager.default.moveItem(at: imagesURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, imagesURL.path), 0)

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .modelHashMismatch("images.txt")
            )
        }
    }

    func testSelectedFramesDigestRejectsHardLinkedFrame() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        _ = try writeCanonicalModel(at: paths)
        let frameURL = paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg")
        let externalURL = root.appendingPathComponent("hardlinked-frame.jpg")
        try FileManager.default.moveItem(at: frameURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, frameURL.path), 0)

        XCTAssertThrowsError(
            try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: ["frame_000001.jpg"],
                projectPaths: paths
            )
        )
    }

    func testInputDigestRejectsHardLinkedOriginal() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        _ = try writeCanonicalModel(at: paths)
        let inputURL = paths.originalsURL.appendingPathComponent("source.jpg")
        let externalURL = root.appendingPathComponent("hardlinked-input.jpg")
        try FileManager.default.moveItem(at: inputURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, inputURL.path), 0)

        XCTAssertThrowsError(try GeometryArtifactStore.inputDigest(projectPaths: paths))
    }

    func testRejectsLearnedInitializerChangedAfterGeometryAcceptance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths, observationCount: 20)
        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent("learned_points3D.txt")
        try FileManager.default.createDirectory(
            at: paths.colmapSeedModelURL,
            withIntermediateDirectories: true
        )
        try "1 1 2 3 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )
        let digest = try GeometryArtifactStore.sha256(of: learnedURL)
        var artifact = makeArtifact(fixture: fixture)
        artifact.modelVersion = "DA3-SMALL@89abcdef0123456789abcdef0123456789abcdef"
        artifact.provenance.runtime = GeometryComponentProvenance(
            identifier: "da3_mps",
            version: "main",
            revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
            payloadSHA256: String(repeating: "b", count: 64)
        )
        artifact.provenance.model = GeometryComponentProvenance(
            identifier: "DA3-SMALL",
            version: "apache-2.0-release",
            revision: "89abcdef0123456789abcdef0123456789abcdef",
            payloadSHA256: String(repeating: "c", count: 64)
        )
        artifact.learnedPointInitializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: digest,
            pointCount: 1
        )
        artifact.mapping.acceptedRefinementKind = .seededBundleAdjustment
        artifact.mapping.plannedIncrementalCadence = nil
        artifact.mapping.incrementalCadence = nil
        artifact.mapping.cadenceFallbackTrigger = nil
        artifact.workerExecution.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.pointTriangulator),
            nativeAutoInvocation(.bundleAdjuster),
            nativeAutoInvocation(.modelAnalyzer),
        ]
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)
        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))

        var fabricatedInvocationCount = artifact
        fabricatedInvocationCount.mapping.acceptedRefinementInvocationCount = 2
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedInvocationCount, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }

        var fabricatedIncrementalRoute = artifact
        fabricatedIncrementalRoute.mapping.acceptedRefinementKind = .incrementalGlobal
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedIncrementalRoute, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }

        try "1 9 8 7 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .learnedInitializerDigestMismatch
            )
        }
    }

    func testRejectsResidualsAndFrameDigestsThatDoNotMatchHashedArtifacts() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var fabricatedResiduals = makeArtifact(fixture: fixture)
        fabricatedResiduals.medianPixelResidual = 0.1
        fabricatedResiduals.p90PixelResidual = 0.1
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedResiduals, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .measuredResidualMismatch)
        }

        var fabricatedCameraModel = makeArtifact(fixture: fixture)
        fabricatedCameraModel.cameraModel = "OPENCV_FISHEYE"
        fabricatedCameraModel.cameraInitializationReceipt.cameraModel = "OPENCV_FISHEYE"
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedCameraModel, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .measuredResidualMismatch)
        }

        var staleFrames = makeArtifact(fixture: fixture)
        staleFrames.selectedFramesDigest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(staleFrames, projectPaths: paths)
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .artifactDigestMismatch("selected frames")
            )
        }
    }

    func testCurrentSchemaRequiresCompleteToolchainProvenance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths, observationCount: 20)

        var artifact = makeArtifact(fixture: fixture)
        artifact.provenance.solver.identifier = ""
        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidProvenance)
        }

        artifact = makeArtifact(fixture: fixture)
        let modelRevision = "89abcdef0123456789abcdef0123456789abcdef"
        artifact.modelVersion = "DA3-SMALL@\(modelRevision)"
        artifact.provenance = GeometryProvenance(
            toolchainVersion: "2.0.0",
            solver: GeometryComponentProvenance(
                identifier: "colmap",
                version: "4.1.1",
                revision: "a0d785fba74b2664f31edc4a29026a8b27c00f67",
                payloadSHA256: artifact.workerExecution.colmapRuntimeClosure.closureSHA256
            ),
            runtime: GeometryComponentProvenance(
                identifier: "da3_mps",
                version: "main",
                revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
                payloadSHA256: String(repeating: "b", count: 64)
            ),
            model: GeometryComponentProvenance(
                identifier: "DA3-SMALL",
                version: "apache-2.0-release",
                revision: modelRevision,
                payloadSHA256: String(repeating: "c", count: 64)
            )
        )
        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent("learned_points3D.txt")
        try FileManager.default.createDirectory(
            at: paths.colmapSeedModelURL,
            withIntermediateDirectories: true
        )
        try "1 1 2 3 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )
        artifact.learnedPointInitializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: try GeometryArtifactStore.sha256(of: learnedURL),
            pointCount: 1
        )
        artifact.mapping.acceptedRefinementKind = .seededBundleAdjustment
        artifact.mapping.plannedIncrementalCadence = nil
        artifact.mapping.incrementalCadence = nil
        artifact.mapping.cadenceFallbackTrigger = nil
        artifact.workerExecution.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.pointTriangulator),
            nativeAutoInvocation(.bundleAdjuster),
            nativeAutoInvocation(.modelAnalyzer),
        ]
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))
    }

    func testRejectsRetiredGeometrySchema() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        artifact.schemaVersion = 1

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidSchema(1))
        }
    }

    func testRejectsCameraGroupingReceiptThatDoesNotCoverSelectedViews() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        artifact.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
            mode: .allSelectedImagesShared,
            cameraCountBefore: 3,
            cameraCountAfter: 1,
            groupedVideoSourceCount: 1,
            groups: [
                ColmapCameraGroupReceipt(
                    sourceGroupID: "all-selected-images",
                    memberCount: 2,
                    canonicalCameraID: 1
                )
            ]
        )
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidCameraGrouping
            )
        }
    }

    func testLoadRejectsFutureSchemaBeforeDecodingItsPayload() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let futureSchemaVersion = GeometryArtifact.currentSchemaVersion + 1
        let payload = #"{"schemaVersion":\#(futureSchemaVersion),"futurePayload":true}"#
        try Data(payload.utf8)
            .write(to: paths.geometryManifestURL)

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidSchema(futureSchemaVersion)
            )
        }
    }

    func testAcceptsMeasuredPairGraphAndExplicitUnresolvedOrientation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        var artifact = makeDescriptorlessMeasuredArtifact(fixture: fixture)
        artifact.canonicalOrientation = CanonicalOrientationArtifact(
            status: .unresolved,
            method: nil,
            sourceToCanonicalQuaternionWXYZ: nil,
            evidence: nil,
            canonicalOpeningViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
        )

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))

        artifact.mapping.largestModelRegisteredViewCount = 10
        artifact.mapping.secondLargestModelRegisteredViewCount = 9
        artifact.mapping.unionRegisteredViewCount = 10
        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths),
            "An unanalyzable model can be larger than the accepted model without erasing it from mapping evidence."
        )

        var disconnected = artifact
        disconnected.pairGraph.measurement?.connectedComponentCount = 3
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(disconnected, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        var failedAcceptedAttempt = artifact
        failedAcceptedAttempt.pairGraph.measurement?.matcherAttempts[0].outcome = .failed
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(failedAcceptedAttempt, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testResolvedOrientationKeepsAcceptedSourceModelImmutable() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths, imageCount: 8)
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let sourceMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: model)
        let sourceSnapshot = try GeometryModelSnapshot.capture(in: model)
        let sourceBytes = try Dictionary(uniqueKeysWithValues: sourceSnapshot.modelHashes.keys.map {
            ($0, try Data(contentsOf: model.appendingPathComponent($0)))
        })

        let imageNames = (1...8).map { String(format: "frame_%06d.jpg", $0) }
        var artifact = makeArtifact(fixture: fixture)
        artifact.orderedImageNames = imageNames
        artifact.orderedImageTimestamps = Array(repeating: nil, count: imageNames.count)
        artifact.registeredViewCount = imageNames.count
        artifact.totalViewCount = imageNames.count
        artifact.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
            mode: .allSelectedImagesShared,
            cameraCountBefore: imageNames.count,
            cameraCountAfter: 1,
            groupedVideoSourceCount: 0,
            groups: [ColmapCameraGroupReceipt(
                sourceGroupID: "all-selected-images",
                memberCount: imageNames.count,
                canonicalCameraID: 1
            )]
        )
        artifact.observationCount = sourceMeasurement.observationCount
        artifact.pointCount = sourceMeasurement.pointCount
        artifact.medianPixelResidual = sourceMeasurement.medianPixelResidual
        artifact.p90PixelResidual = sourceMeasurement.p90PixelResidual
        artifact.modelHashes = sourceSnapshot.modelHashes
        artifact.canonicalOrientation = resolvedOrientationSolution().artifact
        artifact.pairGraph = .measured(PairGraphMeasurement(
            scheduledPairCount: 28,
            attemptedPairCount: 28,
            rawMatchedPairCount: 28,
            spatiallyVerifiedPairCount: 28,
            localPairCount: 28,
            retrievalPairCount: 0,
            loopRevisitPairCount: 0,
            connectedComponentCount: 1,
            isolatedViewCount: 0,
            descriptorlessViewCount: 0,
            componentViewCounts: [8],
            articulationViewCount: 0,
            biconnectedBlockCount: 1,
            largestBiconnectedBlockViewCount: 8,
            secondLargestBiconnectedBlockViewCount: 0,
            degreeP10: 7,
            degreeMedian: 7,
            degreeP90: 7,
            matcherAttempts: [PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: 28,
                attemptedPairCount: 28,
                rawMatchedPairCount: 28,
                spatiallyVerifiedPairCount: 28,
                durationSeconds: 0.01
            )],
            pairListDigest: String(repeating: "d", count: 64),
            featureDatabaseDigest: String(repeating: "e", count: 64),
            matchingDatabaseDigest: String(repeating: "f", count: 64),
            matchingDurationSeconds: 0.01
        ))
        artifact.mapping.largestModelRegisteredViewCount = 8
        artifact.mapping.unionRegisteredViewCount = 8
        try bindAcceptedMatcherWorker(to: &artifact, paths: paths)

        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(
                artifact,
                projectPaths: paths,
                measuredResiduals: sourceMeasurement,
                verifiedSourceSnapshot: sourceSnapshot
            )
        )
        XCTAssertEqual(
            try Dictionary(uniqueKeysWithValues: sourceSnapshot.modelHashes.keys.map {
                ($0, try Data(contentsOf: model.appendingPathComponent($0)))
            }),
            sourceBytes
        )
    }

    func testMeasuredPairGraphAllowsOnlyDescriptorlessUnregisteredViews() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        var artifact = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))

        artifact.registeredViewCount = 10
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        artifact.registeredViewCount = 9
        artifact.pairGraph.measurement?.descriptorlessViewCount = .min
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testMeasuredPairGraphValidatesSingleAndMultipleBiconnectedBlocks() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        let multipleBlocks = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        XCTAssertNoThrow(try GeometryArtifactStore.validate(multipleBlocks, projectPaths: paths))

        var singleBlock = multipleBlocks
        singleBlock.pairGraph.measurement?.rawMatchedPairCount = 9
        singleBlock.pairGraph.measurement?.spatiallyVerifiedPairCount = 9
        singleBlock.pairGraph.measurement?.matcherAttempts[0].rawMatchedPairCount = 9
        singleBlock.pairGraph.measurement?.matcherAttempts[0].spatiallyVerifiedPairCount = 9
        singleBlock.pairGraph.measurement?.articulationViewCount = 0
        singleBlock.pairGraph.measurement?.biconnectedBlockCount = 1
        singleBlock.pairGraph.measurement?.largestBiconnectedBlockViewCount = 9
        singleBlock.pairGraph.measurement?.secondLargestBiconnectedBlockViewCount = 0

        XCTAssertNoThrow(try GeometryArtifactStore.validate(singleBlock, projectPaths: paths))

        singleBlock.pairGraph.measurement?.largestBiconnectedBlockViewCount = 8
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(singleBlock, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        var multipleWithoutArticulation = multipleBlocks
        multipleWithoutArticulation.pairGraph.measurement?.articulationViewCount = 0
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(multipleWithoutArticulation, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testMappingArtifactAcceptsOverlappingModelsAndDetailedRecovery() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        var artifact = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        artifact.mapping = MappingArtifact(
            modelCount: 3,
            largestModelRegisteredViewCount: 9,
            secondLargestModelRegisteredViewCount: 8,
            unionRegisteredViewCount: 9,
            attemptCount: 2,
            acceptedMappingAttemptOrdinal: 1,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 0,
            incrementalCadence: IncrementalMappingCadenceArtifact(
                localMaxRefinements: 2,
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5
            ),
            canonicalModelPublication: artifact.mapping.canonicalModelPublication,
            fallbackReason: "normal graph missed coverage; denser graph accepted"
        )

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))
    }

    func testMappingArtifactAcceptsPlannedCadenceAndTheTwoLegalFallbackTransitions() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        let unchanged = try artifactWithCadence(
            fixture: fixture,
            paths: paths,
            planned: .balancedGlobal,
            accepted: .balancedGlobal,
            trigger: nil
        )
        XCTAssertNoThrow(try GeometryArtifactStore.validate(unchanged, projectPaths: paths))

        let orderedFallback = try artifactWithCadence(
            fixture: fixture,
            paths: paths,
            planned: .orderedFast,
            accepted: .balancedGlobal,
            trigger: .insufficientViewSupport
        )
        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(orderedFallback, projectPaths: paths)
        )

        let balancedFallback = try artifactWithCadence(
            fixture: fixture,
            paths: paths,
            planned: .balancedGlobal,
            accepted: .frequentGlobal,
            trigger: .insufficientViewSupport
        )
        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(balancedFallback, projectPaths: paths)
        )
    }

    func testMappingArtifactRejectsCadenceTriggerWithoutATransition() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = try artifactWithCadence(
            fixture: fixture,
            paths: paths,
            planned: .balancedGlobal,
            accepted: .balancedGlobal,
            trigger: nil
        )
        artifact.mapping.cadenceFallbackTrigger = .insufficientViewSupport

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }
    }

    func testMappingArtifactRejectsCadenceTransitionWithoutATrigger() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = try artifactWithCadence(
            fixture: fixture,
            paths: paths,
            planned: .orderedFast,
            accepted: .balancedGlobal,
            trigger: .insufficientViewSupport
        )
        artifact.mapping.cadenceFallbackTrigger = nil

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }
    }

    func testMappingArtifactRejectsSkippingTheBalancedCadenceStep() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = try artifactWithCadence(
            fixture: fixture,
            paths: paths,
            planned: .orderedFast,
            accepted: .balancedGlobal,
            trigger: .insufficientViewSupport
        )
        artifact.mapping.incrementalCadence = .frequentGlobal
        if let acceptedMapperIndex = artifact.workerExecution
            .mappingAndRefinementInvocations.lastIndex(where: { $0.command == .mapper }) {
            artifact.workerExecution.mappingAndRefinementInvocations[acceptedMapperIndex]
                .mapperExecution?.incrementalCadence = .frequentGlobal
        }
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }
    }

    func testMappingArtifactRejectsFabricatedCountsAndFallbacks() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let baseline = makeArtifact(fixture: fixture)

        var invalidMappings: [MappingArtifact] = []
        for mutate in [
            { (mapping: inout MappingArtifact) in mapping.modelCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.largestModelRegisteredViewCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.largestModelRegisteredViewCount = 2 },
            { (mapping: inout MappingArtifact) in mapping.secondLargestModelRegisteredViewCount = 1 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 2 },
            { (mapping: inout MappingArtifact) in mapping.attemptCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.acceptedRefinementInvocationCount = -1 },
            { (mapping: inout MappingArtifact) in mapping.incrementalCadence = nil },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.localMaxRefinements = 0
            },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.globalFramesRatio = 1
            },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.globalPointsRatio = .infinity
            },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.globalMaxRefinements = 0
            },
            { (mapping: inout MappingArtifact) in
                mapping.attemptCount = 2
                mapping.fallbackReason = nil
            },
            { (mapping: inout MappingArtifact) in mapping.fallbackReason = "  " },
            { (mapping: inout MappingArtifact) in mapping.fallbackReason = " recovery" },
            { (mapping: inout MappingArtifact) in mapping.fallbackReason = "bad\nreason" },
            { (mapping: inout MappingArtifact) in
                mapping.fallbackReason = String(repeating: "x", count: 4_097)
            },
            { (mapping: inout MappingArtifact) in
                mapping.acceptedRefinementKind = .seededBundleAdjustment
            },
        ] {
            var mapping = baseline.mapping
            mutate(&mapping)
            invalidMappings.append(mapping)
        }

        for mapping in invalidMappings {
            var artifact = baseline
            artifact.mapping = mapping
            XCTAssertThrowsError(
                try GeometryArtifactStore.validate(artifact, projectPaths: paths)
            ) { error in
                XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
            }
        }
    }

    func testConvertedPublicationBindsRetainedBinaryCandidateAndConverterOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let canonicalModel = paths.colmapSparseURL.appendingPathComponent(
            "0",
            isDirectory: true
        )
        var binaryHashes: [String: String] = [:]
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            let data = Data("binary \(name)".utf8)
            let url = canonicalModel.appendingPathComponent(name)
            try data.write(to: url)
            binaryHashes[name] = try GeometryArtifactStore.sha256(of: url)
        }
        let sourceDigest = try XCTUnwrap(GeometryArtifactStore.modelClosureDigest(
            binaryHashes,
            expectedNames: ["cameras.bin", "images.bin", "points3D.bin"]
        ))
        let candidatePath = "SfM/colmap/sparse/0"
        var artifact = makeArtifact(fixture: fixture)
        let conversionEvidence = ColmapModelConversionWorkerEvidence(
            executableComponentPath: "bin/colmap",
            executableSHA256: try XCTUnwrap(
                artifact.workerExecution.colmapRuntimeClosure.sha256(for: "bin/colmap")
            ),
            candidateProjectRelativePath: candidatePath,
            inputProjectRelativePath:
                "SfM/colmap/sparse/.text-model-00000000-0000-0000-0000-000000000000/binary",
            outputProjectRelativePath:
                "SfM/colmap/sparse/.text-model-00000000-0000-0000-0000-000000000000/text",
            sourceModelDigest: sourceDigest,
            convertedModelDigest: GeometryArtifactStore.modelClosureDigest(
                fixture.modelHashes,
                expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
            ),
            candidateIdentitySHA256: try XCTUnwrap(
                GeometryArtifactStore.modelCandidateIdentity(
                    mappingAttemptOrdinal: 1,
                    candidateProjectRelativePath: candidatePath,
                    sourceModelDigest: sourceDigest
                )
            )
        )
        artifact.mapping.canonicalModelPublication = CanonicalModelPublicationArtifact(
            kind: .convertedFromBinary,
            sourceModelHashes: binaryHashes,
            conversion: CanonicalModelConversionArtifact(
                invocationOrdinal: 1,
                workerEvidence: conversionEvidence
            )
        )
        artifact.workerExecution.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(
                .modelConverter,
                modelConversion: conversionEvidence
            )
        )
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))

        try Data("different candidate".utf8).write(
            to: canonicalModel.appendingPathComponent("images.bin"),
            options: [.atomic]
        )
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }
    }

    func testConvertedPublicationRejectsConverterDigestOutsideSignedSolverProvenance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let canonicalModel = paths.colmapSparseURL.appendingPathComponent(
            "0",
            isDirectory: true
        )
        var binaryHashes: [String: String] = [:]
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            let url = canonicalModel.appendingPathComponent(name)
            try Data("binary \(name)".utf8).write(to: url)
            binaryHashes[name] = try GeometryArtifactStore.sha256(of: url)
        }
        let sourceDigest = try XCTUnwrap(GeometryArtifactStore.modelClosureDigest(
            binaryHashes,
            expectedNames: ["cameras.bin", "images.bin", "points3D.bin"]
        ))
        let candidatePath = "SfM/colmap/sparse/0"
        let conversionEvidence = ColmapModelConversionWorkerEvidence(
            executableComponentPath: "bin/colmap",
            executableSHA256: String(repeating: "f", count: 64),
            candidateProjectRelativePath: candidatePath,
            inputProjectRelativePath:
                "SfM/colmap/sparse/.text-model-00000000-0000-0000-0000-000000000000/binary",
            outputProjectRelativePath:
                "SfM/colmap/sparse/.text-model-00000000-0000-0000-0000-000000000000/text",
            sourceModelDigest: sourceDigest,
            convertedModelDigest: GeometryArtifactStore.modelClosureDigest(
                fixture.modelHashes,
                expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
            ),
            candidateIdentitySHA256: try XCTUnwrap(
                GeometryArtifactStore.modelCandidateIdentity(
                    mappingAttemptOrdinal: 1,
                    candidateProjectRelativePath: candidatePath,
                    sourceModelDigest: sourceDigest
                )
            )
        )
        var artifact = makeArtifact(fixture: fixture)
        artifact.mapping.canonicalModelPublication = CanonicalModelPublicationArtifact(
            kind: .convertedFromBinary,
            sourceModelHashes: binaryHashes,
            conversion: CanonicalModelConversionArtifact(
                invocationOrdinal: 1,
                workerEvidence: conversionEvidence
            )
        )
        artifact.workerExecution.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.modelConverter, modelConversion: conversionEvidence)
        )
        XCTAssertThrowsError(
            try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)
        ) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .incompleteStage
            )
        }
    }

    func testMappingArtifactRejectsInvalidMultipleModelEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        let baseline = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        for mutate in [
            { (mapping: inout MappingArtifact) in mapping.secondLargestModelRegisteredViewCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.secondLargestModelRegisteredViewCount = 10 },
            { (mapping: inout MappingArtifact) in mapping.modelCount = 10 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 8 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 11 },
            { (mapping: inout MappingArtifact) in
                mapping.largestModelRegisteredViewCount = 10
                mapping.secondLargestModelRegisteredViewCount = 8
                mapping.unionRegisteredViewCount = 10
            },
        ] {
            var artifact = baseline
            mutate(&artifact.mapping)
            XCTAssertThrowsError(
                try GeometryArtifactStore.validate(artifact, projectPaths: paths)
            ) { error in
                XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
            }
        }
    }

    func testRejectsPairGraphThatContradictsAcceptedRefinementRoute() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)

        var incremental = makeDescriptorlessMeasuredArtifact(fixture: fixture)
        incremental.pairGraph = .notEvaluated()
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(incremental, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }

        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent(
            "learned_points3D.txt"
        )
        try FileManager.default.createDirectory(
            at: learnedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "1 1 2 3 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )
        var seeded = makeDescriptorlessMeasuredArtifact(fixture: fixture)
        seeded.modelVersion = "DA3-SMALL@89abcdef0123456789abcdef0123456789abcdef"
        seeded.provenance.runtime = GeometryComponentProvenance(
            identifier: "da3_mps",
            version: "main",
            revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
            payloadSHA256: String(repeating: "b", count: 64)
        )
        seeded.provenance.model = GeometryComponentProvenance(
            identifier: "DA3-SMALL",
            version: "apache-2.0-release",
            revision: "89abcdef0123456789abcdef0123456789abcdef",
            payloadSHA256: String(repeating: "c", count: 64)
        )
        seeded.learnedPointInitializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: try GeometryArtifactStore.sha256(of: learnedURL),
            pointCount: 1
        )
        seeded.mapping = MappingArtifact(
            modelCount: 1,
            largestModelRegisteredViewCount: 9,
            secondLargestModelRegisteredViewCount: 0,
            unionRegisteredViewCount: 9,
            attemptCount: 1,
            acceptedMappingAttemptOrdinal: 1,
            acceptedRefinementKind: .seededBundleAdjustment,
            acceptedRefinementInvocationCount: 1,
            incrementalCadence: nil,
            canonicalModelPublication: seeded.mapping.canonicalModelPublication,
            fallbackReason: nil
        )
        seeded.workerExecution.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.pointTriangulator),
            nativeAutoInvocation(.bundleAdjuster),
            nativeAutoInvocation(.modelAnalyzer),
        ]
        try saveCanonicalWorkerExecution(seeded.workerExecution, paths: paths)
        seeded.pairGraph = .notEvaluated()
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(seeded, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }
    }

    func testRejectsFabricatedPairAndOrientationEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var fabricatedPairGraph = makeArtifact(fixture: fixture)
        fabricatedPairGraph.pairGraph = PairGraphArtifact(
            status: .notEvaluated,
            measurement: PairGraphMeasurement(
                scheduledPairCount: 0,
                attemptedPairCount: 0,
                rawMatchedPairCount: 0,
                spatiallyVerifiedPairCount: 0,
                localPairCount: 0,
                retrievalPairCount: 0,
                loopRevisitPairCount: 0,
                connectedComponentCount: 1,
                isolatedViewCount: 1,
                componentViewCounts: [1],
                articulationViewCount: 0,
                biconnectedBlockCount: 0,
                largestBiconnectedBlockViewCount: 0,
                secondLargestBiconnectedBlockViewCount: 0,
                degreeP10: 0,
                degreeMedian: 0,
                degreeP90: 0,
                matcherAttempts: [],
                pairListDigest: String(repeating: "d", count: 64),
                featureDatabaseDigest: String(repeating: "e", count: 64),
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                matchingDurationSeconds: 0
            ),
        )
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedPairGraph, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        var overflowingPairGraph = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(overflowingPairGraph.pairGraph.measurement)
        measurement.componentViewCounts = [Int.max, 1]
        measurement.connectedComponentCount = 2
        measurement.isolatedViewCount = 1
        overflowingPairGraph.pairGraph = .measured(measurement)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(overflowingPairGraph, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        var fabricatedOrientation = makeArtifact(fixture: fixture)
        fabricatedOrientation.canonicalOrientation.sourceToCanonicalQuaternionWXYZ =
            CanonicalQuaternionWXYZ(w: 1, x: 0, y: 0, z: 0)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedOrientation, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidCanonicalOrientation)
        }
    }

    func testRejectsOverflowingPairRoleCounts() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.scheduledPairCount = Int.max
        measurement.localPairCount = Int.max
        measurement.retrievalPairCount = Int.max
        measurement.loopRevisitPairCount = 0
        measurement.matcherAttempts[0].scheduledPairCount = Int.max
        artifact.pairGraph = .measured(measurement)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testRejectsExactSwitchAfterCompletedNondensestFaissAttempt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.pairingPolicy = .orderedContinuous
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            exactRecoveryReason: .faissCrash,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        ))
        measurement.matchingDurationSeconds = 0.02
        artifact.pairGraph = .measured(measurement)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testAllowsExactSwitchAfterFailedFaissAttempt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.pairingPolicy = .orderedContinuous
        measurement.matcherAttempts[0].outcome = .failed
        measurement.matcherAttempts[0].attemptedPairCount = 0
        measurement.matcherAttempts[0].rawMatchedPairCount = 0
        measurement.matcherAttempts[0].spatiallyVerifiedPairCount = 0
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            exactRecoveryReason: .faissCrash,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        ))
        measurement.matchingDurationSeconds = 0.02
        artifact.pairGraph = .measured(measurement)
        try bindAcceptedMatcherWorker(to: &artifact, paths: paths)

        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        )
    }

    func testRejectsPartialGraphRejectedAttemptBeforeAcceptedExactAttempt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.matcherAttempts[0].outcome = .rejected
        measurement.matcherAttempts[0].attemptedPairCount = 2
        measurement.matcherAttempts[0].rawMatchedPairCount = 2
        measurement.matcherAttempts[0].spatiallyVerifiedPairCount = 1
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        ))
        measurement.matchingDurationSeconds = 0.02
        artifact.pairGraph = .measured(measurement)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testRejectsCompletedExactSwitchForIncompleteSmallUnorderedSchedule() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.scheduledPairCount = 2
        measurement.attemptedPairCount = 2
        measurement.rawMatchedPairCount = 2
        measurement.spatiallyVerifiedPairCount = 2
        measurement.localPairCount = 2
        measurement.matcherAttempts[0].scheduledPairCount = 2
        measurement.matcherAttempts[0].attemptedPairCount = 2
        measurement.matcherAttempts[0].rawMatchedPairCount = 2
        measurement.matcherAttempts[0].spatiallyVerifiedPairCount = 2
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            scheduledPairCount: 2,
            attemptedPairCount: 2,
            rawMatchedPairCount: 2,
            spatiallyVerifiedPairCount: 2,
            durationSeconds: 0.01
        ))
        measurement.matchingDurationSeconds = 0.02
        artifact.pairGraph = .measured(measurement)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testRejectsExactSwitchAfterCompletedExhaustiveSmallUnorderedSchedule() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        ))
        measurement.matchingDurationSeconds = 0.02
        artifact.pairGraph = .measured(measurement)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testRejectsSecondExactAttemptAfterRejectedExactRetry() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.matcherAttempts[0].outcome = .rejected
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .rejected,
            exactRecoveryReason: .faissGeometryRejectedAfterRetries,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        ))
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 3,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            exactRecoveryReason: .faissGeometryRejectedAfterRetries,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        ))
        measurement.matchingDurationSeconds = 0.03
        artifact.pairGraph = .measured(measurement)
        try bindAcceptedMatcherWorker(to: &artifact, paths: paths)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testRejectsDifferentScheduleSizeAfterRejectedExactRetry() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.matcherAttempts[0].outcome = .rejected
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .rejected,
            scheduledPairCount: 3,
            attemptedPairCount: 3,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            durationSeconds: 0.01
        ))
        measurement.matcherAttempts.append(PairMatchingAttemptArtifact(
            attemptNumber: 3,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            scheduledPairCount: 2,
            attemptedPairCount: 2,
            rawMatchedPairCount: 2,
            spatiallyVerifiedPairCount: 2,
            durationSeconds: 0.01
        ))
        measurement.scheduledPairCount = 2
        measurement.attemptedPairCount = 2
        measurement.rawMatchedPairCount = 2
        measurement.spatiallyVerifiedPairCount = 2
        measurement.localPairCount = 2
        measurement.articulationViewCount = 1
        measurement.biconnectedBlockCount = 2
        measurement.largestBiconnectedBlockViewCount = 2
        measurement.secondLargestBiconnectedBlockViewCount = 2
        measurement.degreeP10 = 1
        measurement.degreeMedian = 1
        measurement.degreeP90 = 2
        measurement.matchingDurationSeconds = 0.03
        artifact.pairGraph = .measured(measurement)

        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testRejectsExactSwitchAfterCompletedMaximumRecoveryLevel() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        var measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        measurement.pairingPolicy = .orderedContinuous
        measurement.matcherAttempts = [
            PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .failed,
                scheduledPairCount: 1,
                attemptedPairCount: 0,
                rawMatchedPairCount: 0,
                spatiallyVerifiedPairCount: 0,
                durationSeconds: 0.01
            ),
            PairMatchingAttemptArtifact(
                attemptNumber: 2,
                matcher: .faiss,
                recoveryLevel: .expanded,
                outcome: .failed,
                scheduledPairCount: 2,
                attemptedPairCount: 0,
                rawMatchedPairCount: 0,
                spatiallyVerifiedPairCount: 0,
                durationSeconds: 0.01
            ),
            PairMatchingAttemptArtifact(
                attemptNumber: 3,
                matcher: .faiss,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairCount: 3,
                attemptedPairCount: 3,
                rawMatchedPairCount: 3,
                spatiallyVerifiedPairCount: 3,
                durationSeconds: 0.01
            ),
            PairMatchingAttemptArtifact(
                attemptNumber: 4,
                matcher: .exact,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairCount: 3,
                attemptedPairCount: 3,
                rawMatchedPairCount: 3,
                spatiallyVerifiedPairCount: 3,
                durationSeconds: 0.01
            ),
        ]
        measurement.matchingDurationSeconds = 0.04
        artifact.pairGraph = .measured(measurement)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    private typealias Fixture = (
        modelHashes: [String: String],
        inputDigest: String,
        selectedFramesDigest: String,
        pointCount: Int,
        observationCount: Int,
        conditioning: GeometryConditioningArtifact
    )

    private func artifactWithCadence(
        fixture: Fixture,
        paths: ProjectPaths,
        planned: IncrementalMappingCadenceArtifact,
        accepted: IncrementalMappingCadenceArtifact,
        trigger: MappingCadenceFallbackTrigger?
    ) throws -> GeometryArtifact {
        var artifact = makeArtifact(fixture: fixture)
        artifact.mapping.plannedIncrementalCadence = planned
        artifact.mapping.incrementalCadence = accepted
        artifact.mapping.cadenceFallbackTrigger = trigger

        let pairGraph = try XCTUnwrap(artifact.pairGraph.measurement)
        func mapperExecution(
            cadence: IncrementalMappingCadenceArtifact,
            evaluation: ColmapMapperEvaluationEvidence
        ) -> ColmapMapperWorkerExecutionEvidence {
            ColmapMapperWorkerExecutionEvidence(
                incrementalCadence: cadence,
                globalMaxNumIterations: 75,
                randomSeed: 42,
                refineFocalLength: true,
                minimumPairInlierCount: 15,
                pairGraphAttemptOrdinal: 1,
                pairListDigest: pairGraph.pairListDigest,
                descriptorMatcher: .faiss,
                matchingDatabaseDigest: pairGraph.matchingDatabaseDigest,
                evaluation: evaluation
            )
        }

        let mapperIndex = try XCTUnwrap(
            artifact.workerExecution.mappingAndRefinementInvocations.firstIndex {
                $0.command == .mapper
            }
        )
        let analyzerIndex = try XCTUnwrap(
            artifact.workerExecution.mappingAndRefinementInvocations.firstIndex {
                $0.command == .modelAnalyzer
            }
        )
        var firstMapper = artifact.workerExecution
            .mappingAndRefinementInvocations[mapperIndex]
        var analyzer = artifact.workerExecution
            .mappingAndRefinementInvocations[analyzerIndex]

        if planned == accepted {
            artifact.mapping.attemptCount = 1
            artifact.mapping.acceptedMappingAttemptOrdinal = 1
            artifact.mapping.fallbackReason = nil
            firstMapper.mappingAttemptOrdinal = 1
            firstMapper.mapperExecution = mapperExecution(
                cadence: accepted,
                evaluation: ColmapMapperEvaluationEvidence(
                    status: .accepted,
                    fallbackTrigger: nil
                )
            )
            analyzer.mappingAttemptOrdinal = 1
            artifact.workerExecution.mappingAndRefinementInvocations = [
                firstMapper,
                analyzer,
            ]
            try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)
            return artifact
        }

        artifact.mapping.attemptCount = 2
        artifact.mapping.acceptedMappingAttemptOrdinal = 2
        artifact.mapping.fallbackReason = "Mapper quality gate retried with a denser cadence."
        firstMapper.mappingAttemptOrdinal = 1
        firstMapper.mapperExecution = mapperExecution(
            cadence: planned,
            evaluation: ColmapMapperEvaluationEvidence(
                status: .rejected,
                fallbackTrigger: trigger
            )
        )
        var acceptedMapper = firstMapper
        acceptedMapper.mappingAttemptOrdinal = 2
        acceptedMapper.mapperExecution = mapperExecution(
            cadence: accepted,
            evaluation: ColmapMapperEvaluationEvidence(
                status: .accepted,
                fallbackTrigger: nil
            )
        )
        analyzer.mappingAttemptOrdinal = 2
        artifact.workerExecution.mappingAndRefinementInvocations = [
            firstMapper,
            acceptedMapper,
            analyzer,
        ]
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)
        return artifact
    }

    private func makeArtifact(fixture: Fixture) -> GeometryArtifact {
        let imageNames = (1...3).map { String(format: "frame_%06d.jpg", $0) }
        let runtimeClosure = makeColmapRuntimeClosureEvidence()
        return GeometryArtifact(
            schemaVersion: GeometryArtifact.currentSchemaVersion,
            solverVersion: "colmap; COLMAP 4.1.1",
            runtimeVersion: "easysplat-core-v2",
            modelVersion: "none",
            inputDigest: fixture.inputDigest,
            selectedFramesDigest: fixture.selectedFramesDigest,
            orderedImageNames: imageNames,
            orderedImageTimestamps: Array(repeating: nil, count: imageNames.count),
            sourceModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: "SIMPLE_PINHOLE",
            cameraGrouping: .sameCameraAndLens,
            cameraGroupingReceipt: ColmapCameraGroupingReceipt(
                mode: .allSelectedImagesShared,
                cameraCountBefore: imageNames.count,
                cameraCountAfter: 1,
                groupedVideoSourceCount: 0,
                groups: [
                    ColmapCameraGroupReceipt(
                        sourceGroupID: "all-selected-images",
                        memberCount: imageNames.count,
                        canonicalCameraID: 1
                    )
                ]
            ),
            cameraInitializationReceipt: ColmapCameraInitializationReceipt(
                recipe: .colmapAutomatic,
                cameraModel: "SIMPLE_PINHOLE",
                singleCamera: true,
                pixelWidth: nil,
                pixelHeight: nil,
                diagonalFieldOfViewDegrees: nil,
                cameraParameters: nil,
                priorFocalLength: false
            ),
            featureDatabaseDigest: String(repeating: "e", count: 64),
            registeredViewCount: imageNames.count,
            totalViewCount: imageNames.count,
            observationCount: fixture.observationCount,
            pointCount: fixture.pointCount,
            residualProvenance: "colmap-text-tracks-v1",
            medianPixelResidual: 0,
            p90PixelResidual: 0,
            conditioning: fixture.conditioning,
            timings: [
                "sfmMapping": 1.5,
                "orientation_estimation_seconds": 0.001,
            ],
            peakMemoryBytes: 1_024,
            modelHashes: fixture.modelHashes,
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
                resolvedBudget: geometryWorkerBudget,
                pairExecution: defaultPairExecution(),
                colmapRuntimeClosure: runtimeClosure
            ),
            pairGraph: .measured(PairGraphMeasurement(
                scheduledPairCount: 3,
                attemptedPairCount: 3,
                rawMatchedPairCount: 3,
                spatiallyVerifiedPairCount: 3,
                localPairCount: 3,
                retrievalPairCount: 0,
                loopRevisitPairCount: 0,
                connectedComponentCount: 1,
                isolatedViewCount: 0,
                descriptorlessViewCount: 0,
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
                pairListDigest: String(repeating: "d", count: 64),
                featureDatabaseDigest: String(repeating: "e", count: 64),
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                matchingDurationSeconds: 0.01
            )),
            mapping: MappingArtifact(
                modelCount: 1,
                largestModelRegisteredViewCount: imageNames.count,
                secondLargestModelRegisteredViewCount: 0,
                unionRegisteredViewCount: imageNames.count,
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
                canonicalModelPublication: directTextPublication(fixture.modelHashes),
                fallbackReason: nil
            ),
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
            )
        )
    }

    private func nativeAutoInvocation(
        _ command: ColmapWorkerCommandIdentity,
        modelConversion: ColmapModelConversionWorkerEvidence? = nil
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
            modelConversion: modelConversion,
            exitStatus: 0,
            succeeded: true
        )
    }

    private func saveCanonicalWorkerExecution(
        _ artifact: GeometryWorkerExecutionArtifact,
        paths: ProjectPaths
    ) throws {
        _ = try GeometryWorkerExecutionArtifactStore.save(
            artifact,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            expectedBudget: geometryWorkerBudget,
            projectPaths: paths
        )
    }

    private func defaultPairExecution(
        attemptOrdinal: Int = 1,
        matcher: DescriptorMatcher = .faiss,
        scheduledPairCount: Int = 3,
        pairListDigest: String = String(repeating: "d", count: 64),
        exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil
    ) -> ColmapPairWorkerExecutionEvidence {
        ColmapPairWorkerExecutionEvidence(
            attemptOrdinal: attemptOrdinal,
            descriptorMatcher: matcher,
            scheduledPairCount: scheduledPairCount,
            pairListDigest: pairListDigest,
            exactRecoveryReason: exactRecoveryReason
        )
    }

    private func bindAcceptedMatcherWorker(
        to artifact: inout GeometryArtifact,
        paths: ProjectPaths
    ) throws {
        let measurement = try XCTUnwrap(artifact.pairGraph.measurement)
        _ = try XCTUnwrap(measurement.matcherAttempts.last)
        let workers = artifact.workerExecution.resolvedBudget.coupledMatchingWorkers
        let environment = [
            "OMP_NUM_THREADS": "\(workers)",
            "OPENBLAS_NUM_THREADS": "\(workers)",
            "MKL_NUM_THREADS": "\(workers)",
        ]
        artifact.workerExecution.matchingInvocations = measurement.matcherAttempts.map { attempt in
            ColmapWorkerInvocationEvidence(
                command: .matchesImporter,
                mappingAttemptOrdinal: nil,
                threadPolicy: .bounded,
                argvWorkerCount: workers,
                explicitThreadEnvironment: environment,
                removedThreadEnvironmentKeysSHA256:
                    GeometryWorkerExecutionArtifact
                        .canonicalRemovedThreadEnvironmentKeysSHA256,
                effectiveSanitizedThreadEnvironment: environment,
                pairExecution: defaultPairExecution(
                    attemptOrdinal: attempt.attemptNumber,
                    matcher: attempt.matcher,
                    scheduledPairCount: attempt.scheduledPairCount,
                    pairListDigest: measurement.pairListDigest,
                    exactRecoveryReason: attempt.exactRecoveryReason
                ),
                exitStatus: attempt.outcome == .failed ? 1 : 0,
                succeeded: attempt.outcome != .failed
            )
        }
        let acceptedAttempt = try XCTUnwrap(measurement.matcherAttempts.last)
        let mapperIndex = try XCTUnwrap(
            artifact.workerExecution.mappingAndRefinementInvocations.lastIndex {
                $0.command == .mapper
            }
        )
        artifact.workerExecution.mappingAndRefinementInvocations[mapperIndex]
            .mapperExecution?.pairGraphAttemptOrdinal = acceptedAttempt.attemptNumber
        artifact.workerExecution.mappingAndRefinementInvocations[mapperIndex]
            .mapperExecution?.pairListDigest = measurement.pairListDigest
        artifact.workerExecution.mappingAndRefinementInvocations[mapperIndex]
            .mapperExecution?.descriptorMatcher = acceptedAttempt.matcher
        artifact.workerExecution.mappingAndRefinementInvocations[mapperIndex]
            .mapperExecution?.matchingDatabaseDigest = measurement.matchingDatabaseDigest
        try saveCanonicalWorkerExecution(artifact.workerExecution, paths: paths)
    }

    private func makeDescriptorlessMeasuredArtifact(
        fixture: Fixture
    ) -> GeometryArtifact {
        let imageNames = (1...10).map { String(format: "frame_%06d.jpg", $0) }
        var artifact = makeArtifact(fixture: fixture)
        artifact.orderedImageNames = imageNames
        artifact.orderedImageTimestamps = Array(repeating: nil, count: imageNames.count)
        artifact.registeredViewCount = 9
        artifact.totalViewCount = 10
        artifact.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
            mode: .allSelectedImagesShared,
            cameraCountBefore: imageNames.count,
            cameraCountAfter: 1,
            groupedVideoSourceCount: 0,
            groups: [
                ColmapCameraGroupReceipt(
                    sourceGroupID: "all-selected-images",
                    memberCount: imageNames.count,
                    canonicalCameraID: 1
                )
            ]
        )
        artifact.observationCount = fixture.observationCount
        artifact.pointCount = fixture.pointCount
        artifact.pairGraph = .measured(
            PairGraphMeasurement(
                scheduledPairCount: 9,
                attemptedPairCount: 9,
                rawMatchedPairCount: 8,
                spatiallyVerifiedPairCount: 8,
                localPairCount: 9,
                retrievalPairCount: 0,
                loopRevisitPairCount: 0,
                connectedComponentCount: 2,
                isolatedViewCount: 1,
                descriptorlessViewCount: 1,
                componentViewCounts: [9, 1],
                articulationViewCount: 7,
                biconnectedBlockCount: 8,
                largestBiconnectedBlockViewCount: 2,
                secondLargestBiconnectedBlockViewCount: 2,
                degreeP10: 0,
                degreeMedian: 2,
                degreeP90: 2,
                matcherAttempts: [PairMatchingAttemptArtifact(
                    attemptNumber: 1,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .completed,
                    scheduledPairCount: 9,
                    attemptedPairCount: 9,
                    rawMatchedPairCount: 8,
                    spatiallyVerifiedPairCount: 8,
                    durationSeconds: 0.01
                )],
                pairListDigest: String(repeating: "d", count: 64),
                featureDatabaseDigest: String(repeating: "e", count: 64),
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                matchingDurationSeconds: 0.01
            ),
        )
        artifact.workerExecution.matchingInvocations[0].pairExecution =
            defaultPairExecution(scheduledPairCount: 9)
        artifact.mapping = MappingArtifact(
            modelCount: 2,
            largestModelRegisteredViewCount: 9,
            secondLargestModelRegisteredViewCount: 8,
            unionRegisteredViewCount: 9,
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
            canonicalModelPublication: artifact.mapping.canonicalModelPublication,
            fallbackReason: nil
        )
        return artifact
    }

    private func writeCanonicalModel(
        at paths: ProjectPaths,
        observationCount: Int = 25,
        imageCount: Int = 3
    ) throws -> Fixture {
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let imageNames = (1...imageCount).map { String(format: "frame_%06d.jpg", $0) }
        let points = (0..<observationCount).map { index -> (x: Double, y: Double, z: Double) in
            let rowCount = Int(ceil(Double(observationCount) / 5))
            return (
                x: Double(index % 5 - 2) * 0.75,
                y: (Double(index / 5) - Double(rowCount - 1) / 2) * 0.75,
                z: 12
            )
        }
        var pointTracks = Array(repeating: [String](), count: points.count)
        let images = imageNames.enumerated().flatMap { offset, name -> [String] in
            let imageID = offset + 1
            let centerX = (Double(offset) - Double(imageCount - 1) / 2) * 2
            let observations = points.enumerated().map { pointIndex, point in
                let cameraX = point.x - centerX
                let x = 500 * cameraX / point.z + 320
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
        }.joined(separator: "\n")
        let contents = [
            "cameras.txt": "1 SIMPLE_PINHOLE 640 480 500 320 240\n",
            "images.txt": images,
            "points3D.txt": pointRows + "\n",
        ]
        var hashes: [String: String] = [:]
        for (name, contents) in contents {
            let data = Data(contents.utf8)
            try data.write(to: model.appendingPathComponent(name), options: [.atomic])
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        try Data("original input".utf8).write(
            to: paths.originalsURL.appendingPathComponent("source.jpg"),
            options: [.atomic]
        )
        for (offset, imageName) in imageNames.enumerated() {
            try Data("selected frame \(offset + 1)".utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(imageName),
                options: [.atomic]
            )
        }
        let workerExecution = makeGeometryWorkerExecutionArtifact(
            resolvedBudget: geometryWorkerBudget,
            pairExecution: defaultPairExecution()
        )
        _ = try GeometryWorkerExecutionArtifactStore.save(
            workerExecution,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            expectedBudget: geometryWorkerBudget,
            projectPaths: paths
        )
        let analysis = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            maximumRayPairEvaluations:
                GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
        )
        let sourceModelClosureSHA256 = try XCTUnwrap(
            GeometryArtifactStore.modelClosureDigest(
                hashes,
                expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
            )
        )
        return (
            modelHashes: hashes,
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            pointCount: observationCount,
            observationCount: observationCount * imageNames.count,
            conditioning: GeometryConditioningArtifact(
                sourceModelClosureSHA256: sourceModelClosureSHA256,
                measurement: analysis.measurement
            )
        )
    }

    private func resolvedOrientationSolution() -> CanonicalOrientationSolution {
        let rotation = OrientationMatrix3(
            rows: OrientationVector3(x: 0, y: -1, z: 0),
            OrientationVector3(x: 1, y: 0, z: 0),
            OrientationVector3(x: 0, y: 0, z: 1)
        )
        return CanonicalOrientationSolution(
            artifact: CanonicalOrientationArtifact(
                status: .verified,
                method: .cameraRightNullspace,
                sourceToCanonicalQuaternionWXYZ: rotation.canonicalQuaternion(),
                evidence: CanonicalOrientationEvidence(
                    supportCount: 8,
                    eigenvalue0: 0.001,
                    eigenvalue1: 0.1,
                    eigenvalue2: 0.899,
                    eigengap: 100,
                    medianResidualDegrees: 0,
                    p90ResidualDegrees: 0,
                    medianAbsoluteImageUpAgreement: 1,
                    signAgreement: 1,
                    bootstrapP95VariationDegrees: 0,
                    trajectoryPlaneAgreementDegrees: nil
                ),
                canonicalOpeningViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
            ),
            sourceToCanonical: rotation
        )
    }

    private func writeDescriptorlessGeometryFixture(
        at paths: ProjectPaths
    ) throws -> Fixture {
        let fixture = try writeCanonicalModel(
            at: paths,
            observationCount: 25,
            imageCount: 9
        )
        let workerExecution = makeGeometryWorkerExecutionArtifact(
            resolvedBudget: geometryWorkerBudget,
            pairExecution: defaultPairExecution(scheduledPairCount: 9)
        )
        try saveCanonicalWorkerExecution(workerExecution, paths: paths)
        let selectedImageNames = (1...10).map { String(format: "frame_%06d.jpg", $0) }
        try Data("frame_000010.jpg".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent("frame_000010.jpg"),
            options: [.atomic]
        )
        return (
            modelHashes: fixture.modelHashes,
            inputDigest: fixture.inputDigest,
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: selectedImageNames,
                projectPaths: paths
            ),
            pointCount: fixture.pointCount,
            observationCount: fixture.observationCount,
            conditioning: fixture.conditioning
        )
    }
}
