import Darwin
import XCTest
@testable import EasySplatCore

final class ProjectDiagnosticBundleTests: XCTestCase {
    func testReturnsNilForUnreadableProject() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Intentionally do not create project.json.
        XCTAssertNil(ProjectDiagnosticBundle.build(projectURL: root))
    }

    func testIncludesHeaderAndReconstructionMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let geometry = makeGeometryArtifact()
        let metadata = ProjectMetadata(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "DiagnosticProject",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            resolvedRunPlan: makeResolvedRunPlan(for: geometry),
            state: PipelineState(stage: .sfmMapping, lastError: "boom"),
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 30),
                .init(stage: .sfmMapping, startedAt: Date(timeIntervalSince1970: 1_700_000_030), durationSeconds: 90)
            ],
            createToViewerReadySeconds: 150
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)
        let persistedGeometry = try persistGeometrySidecar(geometry, paths: paths)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(
            projectURL: root,
            hardwareLine: "Mac mini M4 Max, 48 GB",
            now: Date(timeIntervalSince1970: 1_700_000_200)
        ))

        XCTAssertTrue(bundle.contains("# EasySplat Diagnostic Bundle"))
        XCTAssertFalse(bundle.contains("DiagnosticProject"))
        XCTAssertFalse(bundle.contains("11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(bundle.contains("Hardware: Mac mini M4 Max, 48 GB"))
        XCTAssertTrue(bundle.contains("## Reconstruction"))
        XCTAssertTrue(bundle.contains("Solver: \(persistedGeometry.solverVersion)"))
        XCTAssertTrue(bundle.contains("Registered: \(persistedGeometry.registeredViewCount) / \(persistedGeometry.totalViewCount)"))
        XCTAssertTrue(bundle.contains("Points: \(persistedGeometry.pointCount)"))
        XCTAssertTrue(bundle.contains("## Stage Timings"))
        XCTAssertTrue(bundle.contains("sfmFeatures: 30s"))
        XCTAssertTrue(bundle.contains("sfmMapping: 90s"))
        XCTAssertTrue(bundle.contains("Create-to-viewer-ready: 150s"))
        XCTAssertTrue(bundle.contains("Stage total: 120s"))
        XCTAssertTrue(bundle.contains("## Pipeline State"))
        XCTAssertTrue(bundle.contains("Last error: boom"))
    }

    func testEmbedsLogTailsWhenPresent() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "WithLogs",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)
        try "first line\nsecond line\nthird line".write(to: paths.pipelineLogURL, atomically: true, encoding: .utf8)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains("## pipeline.log (tail)"))
        XCTAssertTrue(bundle.contains("third line"))
    }

    func testDiagnosticsReportNoSubjectArtifactAndTailIsolationLog() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "NoSubjectArtifact",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced
                )
            ),
            to: paths.metadataURL
        )
        try "isolation completed without a subject\n".write(
            to: paths.isolationLogURL,
            atomically: true,
            encoding: .utf8
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertTrue(bundle.contains("## Subject Isolation\nStatus: no artifact"))
        XCTAssertTrue(bundle.contains("## isolation.log (tail)"))
        XCTAssertTrue(bundle.contains("isolation completed without a subject"))
    }

    func testDiagnosticsReportValidSubjectArtifactWithoutMaskIdentityOrAnchor() throws {
        let fixture = try makeSubjectIsolationFixture()
        defer { fixture.cleanup() }
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                id: fixture.projectID,
                title: "ValidSubjectArtifact",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced
                )
            ),
            to: fixture.paths.metadataURL
        )
        let artifact = try fixture.makeArtifact()
        _ = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: fixture.root))

        XCTAssertTrue(bundle.contains("## Subject Isolation\nStatus: valid"))
        XCTAssertTrue(bundle.contains("Variant: subject"))
        XCTAssertTrue(bundle.contains("Mask views: 3 · selected: 2 · held out: 1"))
        XCTAssertTrue(bundle.contains("Vision request revision: 1 · policy revision: 1"))
        XCTAssertFalse(bundle.contains("frame-0.png"))
        XCTAssertFalse(bundle.contains("frame-1.png"))
        XCTAssertFalse(bundle.contains("normalizedX"))
        XCTAssertFalse(bundle.contains("normalizedY"))
        XCTAssertFalse(bundle.contains("Output/isolated.ply"))
        XCTAssertFalse(bundle.contains("Isolation/masks"))
    }

    func testDiagnosticsReportStaleAndInvalidSubjectArtifacts() throws {
        let staleFixture = try makeSubjectIsolationFixture()
        defer { staleFixture.cleanup() }
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                id: staleFixture.projectID,
                title: "StaleSubjectArtifact",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced
                )
            ),
            to: staleFixture.paths.metadataURL
        )
        _ = try SubjectIsolationArtifactStore.publish(
            staleFixture.makeArtifact(),
            stagedOutputURL: staleFixture.stagedOutputURL,
            stagedMasksURL: staleFixture.stagedMasksURL,
            paths: staleFixture.paths
        )
        try TestFileBuilder.writeMinimalPly(
            at: staleFixture.paths.outputSplatURL,
            vertexCount: 2
        )

        let staleBundle = try XCTUnwrap(
            ProjectDiagnosticBundle.build(projectURL: staleFixture.root)
        )
        XCTAssertTrue(
            staleBundle.contains("## Subject Isolation\nStatus: stale (source output)")
        )

        let invalidRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: invalidRoot) }
        let invalidPaths = ProjectPaths(root: invalidRoot)
        try invalidPaths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "InvalidSubjectArtifact",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced
                )
            ),
            to: invalidPaths.metadataURL
        )
        try TestFileBuilder.writeMinimalPly(at: invalidPaths.isolatedOutputURL)

        let invalidBundle = try XCTUnwrap(
            ProjectDiagnosticBundle.build(projectURL: invalidRoot)
        )
        XCTAssertTrue(invalidBundle.contains("## Subject Isolation\nStatus: invalid"))
    }

    func testSkipsSymlinkedLogTailWithoutReadingExternalContents() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "SymlinkedLog",
            input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: paths.metadataURL
        )
        let marker = "external-symlink-log-secret"
        let outsideLog = parent.appendingPathComponent("outside.log")
        try marker.write(to: outsideLog, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: paths.pipelineLogURL, withDestinationURL: outsideLog)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertFalse(bundle.contains(marker))
        XCTAssertFalse(bundle.contains("## pipeline.log (tail)"))
        XCTAssertEqual(try String(contentsOf: outsideLog, encoding: .utf8), marker)
    }

    func testSkipsLogTailInsideSymlinkedLogsDirectory() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "SymlinkedLogsDirectory",
            input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: paths.metadataURL
        )
        try FileManager.default.removeItem(at: paths.logsURL)
        let outsideLogs = parent.appendingPathComponent("OutsideLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideLogs, withIntermediateDirectories: true)
        let marker = "external-parent-symlink-log-secret"
        try marker.write(
            to: outsideLogs.appendingPathComponent("pipeline.log"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: paths.logsURL,
            withDestinationURL: outsideLogs
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertFalse(bundle.contains(marker))
        XCTAssertFalse(bundle.contains("## pipeline.log (tail)"))
    }

    func testSkipsMultiplyLinkedLogTailWithoutReadingExternalContents() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "HardLinkedLog",
            input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: paths.metadataURL
        )
        let marker = "external-hardlink-log-secret"
        let outsideLog = parent.appendingPathComponent("outside.log")
        try marker.write(to: outsideLog, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: outsideLog, to: paths.pipelineLogURL)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertFalse(bundle.contains(marker))
        XCTAssertFalse(bundle.contains("## pipeline.log (tail)"))
        XCTAssertEqual(try String(contentsOf: outsideLog, encoding: .utf8), marker)
    }

    func testSkipsFIFOLogTail() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "FIFOLog",
            input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: paths.metadataURL
        )
        XCTAssertEqual(Darwin.mkfifo(paths.pipelineLogURL.path, mode_t(S_IRUSR | S_IWUSR)), 0)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertFalse(bundle.contains("## pipeline.log (tail)"))
    }

    func testSkipsLogTailsForEmptyFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "EmptyLogs",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)
        try "".write(to: paths.pipelineLogURL, atomically: true, encoding: .utf8)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertFalse(bundle.contains("## pipeline.log"))
    }

    func testLogTailIsBoundedByByteLimitOnLargeFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "BigLog",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)

        // Write a multi-megabyte log so a naive String(contentsOf:) would burn through memory.
        let unitLine = String(repeating: "A", count: 256) + "\n"
        let totalLines = 5_000 // ~1.25 MB
        var data = Data()
        for index in 0..<totalLines {
            let line = "\(index) \(unitLine)"
            data.append(line.data(using: .utf8)!)
        }
        try data.write(to: paths.pipelineLogURL, options: .atomic)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(
            projectURL: root,
            tailLineLimit: 50,
            tailByteLimit: 8 * 1024
        ))
        XCTAssertTrue(bundle.contains("## pipeline.log (tail)"))
        XCTAssertLessThan(bundle.utf8.count, 64 * 1024, "Diagnostic bundle should not balloon for large logs.")
        XCTAssertTrue(bundle.contains("\(totalLines - 1)"), "Tail must include the latest log line.")
    }

    func testHeaderRecordsNotesPrivacyState() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "Privacy",
            input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
                notes: "private"
            ),
            to: paths.metadataURL
        )
        let defaultBundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(defaultBundle.contains("Privacy: notes excluded by default"))
        let optedInBundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root, includeNotes: true))
        XCTAssertTrue(optedInBundle.contains("Privacy: notes opted in"))
    }

    func testNotesAreExcludedByDefault() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "PrivateNotes",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            notes: "secret location: 47.6,-122.3"
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertFalse(bundle.contains("secret location"), "Notes must not leak into the default diagnostic bundle.")
        XCTAssertFalse(bundle.contains("## Notes"))
    }

    func testMachineReadableJsonContainsRequestedOptionsAndStageTimings() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let requestedOptions = RequestedRunOptions(
            capturePath: .walkthrough,
            detailProfile: .highDetail
        )
        let resolvedPlan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: .photos(folder: "Originals/Photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let metadata = ProjectMetadata(
            title: "MachineDetailed",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: requestedOptions,
            resolvedRunPlan: resolvedPlan,
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 12)
            ],
            createToViewerReadySeconds: 44
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(
            bundle.contains("Geometry workers: extract 12 · match 8 · retrieve 8")
        )
        XCTAssertTrue(
            bundle.contains("Video source analysis: up to 1 clip at once")
        )
        guard let start = bundle.range(of: "```json\n"),
              let end = bundle.range(of: "\n```", range: start.upperBound..<bundle.endIndex) else {
            return XCTFail("JSON fence missing")
        }
        let json = String(bundle[start.upperBound..<end.lowerBound])
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any]
        let options = parsed?["requestedRunOptions"] as? [String: Any]
        XCTAssertEqual(options?["capturePath"] as? String, "walkthrough")
        XCTAssertEqual(options?["detailProfile"] as? String, "highDetail")
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 19)
        XCTAssertEqual(parsed?["createToViewerReadySeconds"] as? Double, 44)
        XCTAssertNil(parsed?["resolvedGeometryWorkers"])
        let workers = parsed?["resolvedGeometryExecutionBudget"] as? [String: Any]
        XCTAssertEqual(workers?["featureExtractionWorkers"] as? Int, 12)
        XCTAssertEqual(workers?["coupledMatchingWorkers"] as? Int, 8)
        XCTAssertEqual(workers?["vocabularyRetrievalWorkers"] as? Int, 8)
        XCTAssertEqual(workers?["maximumConcurrentVideoSourceAnalysisTasks"] as? Int, 1)
        let timings = parsed?["stageTimings"] as? [[String: Any]]
        XCTAssertEqual(timings?.count, 1)
        XCTAssertEqual(timings?.first?["stage"] as? String, "sfmFeatures")
    }

    func testDiagnosticsIncludeLastFailureAtInStateAndJson() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let failureDate = Date(timeIntervalSince1970: 1_700_000_123)
        let metadata = ProjectMetadata(
            title: "FailureTimestamp",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .sfmMapping, lastError: "mapper exploded"),
            lastFailureAt: failureDate
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains("Last failure: 2023-11-14T22:15:23Z"))

        guard let start = bundle.range(of: "```json\n"),
              let end = bundle.range(of: "\n```", range: start.upperBound..<bundle.endIndex) else {
            XCTFail("JSON fence missing")
            return
        }
        let json = String(bundle[start.upperBound..<end.lowerBound])
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any]
        XCTAssertEqual(parsed?["lastFailureAt"] as? String, "2023-11-14T22:15:23Z")
    }

    func testDiagnosticsPreserveRejectedRetrievalEvidenceWithoutImageNames() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Private Retrieval.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let requested = RequestedRunOptions(
            detailProfile: .highDetail,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: .photos(folder: "Originals/Photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "Private Retrieval",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: requested,
                resolvedRunPlan: plan,
                state: PipelineState(
                    stage: .sfmMatching,
                    lastError: "Capture connection failed"
                ),
                lastFailureAt: Date(timeIntervalSince1970: 1_700_000_123)
            ),
            to: paths.metadataURL
        )
        let imageNames = (0..<251).map {
            String(format: "private_client_frame_%03d.jpg", $0)
        }
        let retrieval = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: imageNames,
            queryStride: 1,
            candidateCount: 80,
            returnedNeighborCount: 32,
            minimumFrameSeparation: 0,
            queryOutcomes: imageNames.map {
                PairGraphRetrievalQueryOutcome(
                    queryImageName: $0,
                    status: .noRankedNeighbors,
                    rankedNeighborImageNames: []
                )
            },
            directedPairLines: []
        )
        let workers = plan.geometryWorkerBudget.vocabularyRetrievalWorkers
        let environment = [
            "OMP_NUM_THREADS": "\(workers)",
            "OPENBLAS_NUM_THREADS": "\(workers)",
            "MKL_NUM_THREADS": "\(workers)",
        ]
        let invocation = ColmapWorkerInvocationEvidence(
            command: .localVocabularyRetriever,
            mappingAttemptOrdinal: nil,
            threadPolicy: .bounded,
            argvWorkerCount: workers,
            explicitThreadEnvironment: environment,
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: environment,
            pairExecution: ColmapPairWorkerExecutionEvidence(
                attemptOrdinal: 1,
                descriptorMatcher: .faiss,
                pairListDigest: nil,
                retrievalRequestDigest: PairGraphEvidenceStore.retrievalRequestDigest(retrieval),
                retrievalOutputDigest: retrieval.outputDigest
            ),
            exitStatus: 0,
            succeeded: true
        )
        var worker = GeometryWorkerExecutionArtifact(
            colmapRuntimeClosure: makeColmapRuntimeClosureEvidence(),
            resolvedBudget: plan.geometryWorkerBudget,
            featureExtractionInvocations: [],
            matchingInvocations: [],
            vocabularyRetrievalInvocations: [],
            mappingAndRefinementInvocations: [],
            videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: 0,
                startedAnalysisTaskCount: 0,
                peakInFlightAnalysisTaskCount: 0
            )
        )
        worker.rejectedVocabularyRetrievalInvocations = [
            RejectedVocabularyRetrievalExecutionEvidence(
                retrievalAttemptOrdinal: 1,
                pairingPolicy: .unorderedRetrieval,
                planBinding: PairGraphPlanBinding(plan),
                recoveryLevel: .maximum,
                imageNames: imageNames,
                groups: [ColmapPairGroup(imageNames: imageNames, isVideo: false)],
                invocation: invocation,
                retrieval: retrieval,
                durationSeconds: 1.25
            )
        ]
        _ = try GeometryWorkerExecutionArtifactStore.save(
            worker,
            to: paths.workerExecutionURL,
            expectedBudget: plan.geometryWorkerBudget,
            projectPaths: paths
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertFalse(bundle.contains("private_client_frame_000.jpg"))
        let payload = try machineReadablePayload(from: bundle)
        let rejected = try XCTUnwrap(
            payload["rejectedVocabularyRetrievalAttempts"] as? [[String: Any]]
        )
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected[0]["retrievalAttemptOrdinal"] as? Int, 1)
        XCTAssertEqual(rejected[0]["pairAttemptOrdinal"] as? Int, 1)
        XCTAssertEqual(rejected[0]["pairingPolicy"] as? String, "unorderedRetrieval")
        XCTAssertEqual(rejected[0]["recoveryLevel"] as? String, "maximum")
        XCTAssertEqual(rejected[0]["selectedViewCount"] as? Int, 251)
        XCTAssertEqual(rejected[0]["queryCount"] as? Int, 251)
        XCTAssertEqual(rejected[0]["noRankedNeighborQueryCount"] as? Int, 251)
        XCTAssertEqual(rejected[0]["candidateCount"] as? Int, 80)
        XCTAssertEqual(rejected[0]["returnedNeighborCount"] as? Int, 32)
        XCTAssertEqual(rejected[0]["durationSeconds"] as? Double, 1.25)
        XCTAssertEqual(
            rejected[0]["retrievalRequestDigest"] as? String,
            PairGraphEvidenceStore.retrievalRequestDigest(retrieval)
        )
        XCTAssertEqual(
            rejected[0]["retrievalOutputDigest"] as? String,
            retrieval.outputDigest
        )
        XCTAssertNil(rejected[0]["imageNames"])
        XCTAssertNil(rejected[0]["queryImageNames"])
        XCTAssertNil(rejected[0]["invocation"])
    }

    func testIncludesMachineReadableJsonSectionWhenMetricsExist() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let geometry = makeGeometryArtifact()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "Machine",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
                resolvedRunPlan: makeResolvedRunPlan(for: geometry)
            ),
            to: paths.metadataURL
        )
        _ = try persistGeometrySidecar(geometry, paths: paths)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains("## Metrics (machine readable)"))
        // The JSON block must be parseable round-trip.
        guard let start = bundle.range(of: "```json\n"),
              let end = bundle.range(of: "\n```", range: start.upperBound..<bundle.endIndex) else {
            XCTFail("JSON fence missing")
            return
        }
        let json = String(bundle[start.upperBound..<end.lowerBound])
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any]
        XCTAssertNil(parsed?["projectId"])
        XCTAssertNotNil(parsed?["reconstruction"])
        XCTAssertEqual(
            parsed?["schemaVersion"] as? Int,
            ProjectDiagnosticBundle.machineReadableSchemaVersion,
            "JSON payload must carry the current schema version so downstream consumers can detect format changes."
        )
    }

    func testDiagnosticsIncludePathFreeTrainingResourceAdmission() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        var training = makeTrainingArtifact(
            checkpointPath: "Training/checkpoints/msplat",
            outputPath: nil,
            completionStatus: .checkpointed
        )
        training.completedIteration = 500
        training.elapsedSeconds = nil
        training.memoryBudgetBytes = 8 * 1_073_741_824
        let geometry = makeGeometryArtifact()
        let options = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .highDetail
        )
        let metadata = ProjectMetadata(
            title: "Training resource evidence",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: options,
            resolvedRunPlan: makeResolvedRunPlan(for: geometry, requestedOptions: options),
            state: PipelineState(stage: .trainSplat, lastError: nil)
        )
        let plan = try XCTUnwrap(metadata.resolvedRunPlan)
        training.iterationLimit = plan.trainerIterationLimit
        training.plateauWindow = plan.plateauWindow
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)
        let persistedGeometry = try persistGeometrySidecar(geometry, paths: paths)
        training.datasetDerivation.sourceSelectedFramesDigest =
            persistedGeometry.selectedFramesDigest
        training.datasetDerivation.sourceGeometryManifestSHA256 =
            try GeometryArtifactStore.manifestDigest(
                matching: persistedGeometry,
                at: paths.geometryManifestURL
            )
        try TrainingArtifactStore.persist(training, paths: paths)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains(
            "Training memory: \(training.memoryBudgetBytes) bytes budgeted of "
                + "\(training.resourceAdmission.allowedTrainerBytes) bytes admitted"
        ))
        let payload = try machineReadablePayload(from: bundle)
        let resource = try XCTUnwrap(payload["trainingResource"] as? [String: Any])
        XCTAssertEqual(resource["schema_version"] as? NSNumber, NSNumber(value: 2))
        XCTAssertEqual(
            resource["memory_budget_bytes"] as? NSNumber,
            NSNumber(value: training.memoryBudgetBytes)
        )
        let admission = try XCTUnwrap(resource["admission"] as? [String: Any])
        XCTAssertEqual(
            admission["allowed_trainer_bytes"] as? NSNumber,
            NSNumber(value: training.resourceAdmission.allowedTrainerBytes)
        )
        XCTAssertNil(resource["projectPath"])
        XCTAssertNil(resource["projectTitle"])
    }

    func testMachineReadableJsonKeepsReliableReprojection() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let geometry = makeGeometryArtifact()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "ReliableColmap",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
                resolvedRunPlan: makeResolvedRunPlan(for: geometry)
            ),
            to: paths.metadataURL
        )
        let persistedGeometry = try persistGeometrySidecar(geometry, paths: paths)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        let parsed = try machineReadablePayload(from: bundle)
        let reconstruction = try XCTUnwrap(parsed["reconstruction"] as? [String: Any])
        XCTAssertEqual(
            reconstruction["medianPixelResidual"] as? Double,
            persistedGeometry.medianPixelResidual
        )
        XCTAssertEqual(
            reconstruction["p90PixelResidual"] as? Double,
            persistedGeometry.p90PixelResidual
        )
    }

    func testIncludesRecoveryFactsWithoutSelectedFrameIdentity() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Private Recovery.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let privateFrameName = "client-address-frame.jpg"
        let imageNames = [
            privateFrameName,
            "client-address-frame-2.jpg",
            "client-address-frame-3.jpg",
        ]
        for (index, imageName) in imageNames.enumerated() {
            try Data("frame-\(index)".utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(imageName)
            )
        }
        let selectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: imageNames,
            projectPaths: paths
        )
        let recovery = GeometryRecoveryState(
            selectedFramesDigest: selectedFramesDigest,
            orderedImageNames: imageNames,
            activeBackend: .colmap,
            mappingAttemptCount: 2,
            mappingFallbackReasons: [
                "interrupted mapping resumed",
                "exact descriptor matching",
            ],
            pendingPairRecoveryLevel: .normal,
            colmapComputeMode: .cpu,
            plannedIncrementalCadence: .orderedFast,
            activeIncrementalCadence: .balancedGlobal,
            cadenceFallbackTrigger: .lowReconstructionQuality,
            acceptedPairAttemptOrdinal: 1,
            pairListDigest: String(repeating: "a", count: 64),
            matchingDatabaseDigest: String(repeating: "b", count: 64)
        )
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "Private Recovery",
            input: .photos(folder: "Originals/Photos"),
                geometryRecovery: recovery,
                state: PipelineState(stage: .sfmMatching, lastError: nil)
            ),
            to: paths.metadataURL
        )
        let plan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
        let attempts = [
            PairGraphAttemptEvidence(
                artifact: PairMatchingAttemptArtifact(
                    attemptNumber: 1,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .rejected,
                    scheduledPairCount: 3,
                    attemptedPairCount: 3,
                    rawMatchedPairCount: 2,
                    spatiallyVerifiedPairCount: 1,
                    durationSeconds: 1
                ),
                scheduledPairs: plan.pairs
            ),
            PairGraphAttemptEvidence(
                artifact: PairMatchingAttemptArtifact(
                    attemptNumber: 2,
                    matcher: .exact,
                    recoveryLevel: .normal,
                    outcome: .rejected,
                    exactRecoveryReason: .faissGeometryRejectedAfterRetries,
                    scheduledPairCount: 3,
                    attemptedPairCount: 3,
                    rawMatchedPairCount: 2,
                    spatiallyVerifiedPairCount: 1,
                    durationSeconds: 2
                ),
                scheduledPairs: plan.pairs
            ),
        ]
        try PairGraphRecoveryStore.save(
            PairGraphRecoveryState(
                selectedFramesDigest: selectedFramesDigest,
                imageNames: imageNames,
                pairingPolicy: .unorderedRetrieval,
                mode: .terminalExact,
                exactRecoveryReason: .faissGeometryRejectedAfterRetries,
                computeMode: .cpu,
                activeRecoveryLevel: .normal,
                activePlan: plan,
                attempts: attempts,
                matchingDurationSeconds: 3,
                fallbackReasons: [
                    "interrupted mapping resumed",
                    "exact descriptor matching",
                ]
            ),
            to: paths.pairGraphRecoveryURL,
            projectPaths: paths
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertTrue(bundle.contains("Recovery backend: colmap"))
        XCTAssertTrue(bundle.contains("Recovery mapping attempts: 2"))
        XCTAssertTrue(bundle.contains("Recovery compute: cpu"))
        XCTAssertTrue(bundle.contains("Pending pair recovery: normal"))
        XCTAssertTrue(bundle.contains("Recovery cadence retry: lowReconstructionQuality"))
        XCTAssertTrue(bundle.contains("Recovery pair attempt: 1"))
        XCTAssertTrue(bundle.contains("Recovery reason: interrupted mapping resumed"))
        XCTAssertTrue(bundle.contains("Matching attempts: 2"))
        XCTAssertTrue(bundle.contains("Matching time: 3.00s"))
        XCTAssertTrue(bundle.contains("Matching attempt 2: exact, rejected"))
        XCTAssertFalse(bundle.contains(privateFrameName))
        XCTAssertFalse(bundle.contains(selectedFramesDigest))
        let payload = try machineReadablePayload(from: bundle)
        let machineRecovery = try XCTUnwrap(
            payload["geometryRecovery"] as? [String: Any]
        )
        XCTAssertEqual(machineRecovery["activeBackend"] as? String, "colmap")
        XCTAssertEqual(machineRecovery["mappingAttemptCount"] as? Int, 2)
        XCTAssertEqual(machineRecovery["colmapComputeMode"] as? String, "cpu")
        XCTAssertEqual(machineRecovery["pendingPairRecoveryLevel"] as? String, "normal")
        let plannedCadence = try XCTUnwrap(
            machineRecovery["plannedIncrementalCadence"] as? [String: Any]
        )
        XCTAssertEqual(plannedCadence["localMaxRefinements"] as? Int, 1)
        XCTAssertEqual(plannedCadence["globalFramesRatio"] as? Double, 4)
        XCTAssertEqual(plannedCadence["globalPointsRatio"] as? Double, 4)
        XCTAssertEqual(plannedCadence["globalMaxRefinements"] as? Int, 5)
        let activeCadence = try XCTUnwrap(
            machineRecovery["activeIncrementalCadence"] as? [String: Any]
        )
        XCTAssertEqual(activeCadence["localMaxRefinements"] as? Int, 2)
        XCTAssertEqual(activeCadence["globalFramesRatio"] as? Double, 1.4)
        XCTAssertEqual(activeCadence["globalPointsRatio"] as? Double, 1.4)
        XCTAssertEqual(activeCadence["globalMaxRefinements"] as? Int, 5)
        XCTAssertEqual(
            machineRecovery["cadenceFallbackTrigger"] as? String,
            "lowReconstructionQuality"
        )
        XCTAssertEqual(machineRecovery["acceptedPairAttemptOrdinal"] as? Int, 1)
        XCTAssertEqual(
            machineRecovery["pairListDigest"] as? String,
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            machineRecovery["matchingDatabaseDigest"] as? String,
            String(repeating: "b", count: 64)
        )
        XCTAssertNil(machineRecovery["orderedImageNames"])
        XCTAssertNil(machineRecovery["selectedFramesDigest"])
        let pairRecovery = try XCTUnwrap(
            payload["pairMatchingRecovery"] as? [String: Any]
        )
        XCTAssertEqual(pairRecovery["matchingDurationSeconds"] as? Double, 3)
        let matcherAttempts = try XCTUnwrap(
            pairRecovery["attempts"] as? [[String: Any]]
        )
        XCTAssertEqual(matcherAttempts.count, 2)
        XCTAssertEqual(matcherAttempts[0]["matcher"] as? String, "faiss")
        XCTAssertEqual(matcherAttempts[0]["outcome"] as? String, "rejected")
        XCTAssertEqual(matcherAttempts[1]["matcher"] as? String, "exact")
        XCTAssertEqual(matcherAttempts[1]["outcome"] as? String, "rejected")
    }

    func testIncludesSanitizedMappingEvidenceInReconstructionAndMachineReadableMetrics() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Private Site.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        var geometry = makeGeometryArtifact()
        var rejectedMapper = geometry.workerExecution.mappingAndRefinementInvocations[0]
        rejectedMapper.mapperExecution?.evaluation = ColmapMapperEvaluationEvidence(
            status: .rejected,
            fallbackTrigger: .lowReconstructionQuality
        )
        var acceptedMapper = rejectedMapper
        acceptedMapper.mappingAttemptOrdinal = 2
        acceptedMapper.mapperExecution?.incrementalCadence = .frequentGlobal
        acceptedMapper.mapperExecution?.evaluation = ColmapMapperEvaluationEvidence(
            status: .accepted,
            fallbackTrigger: nil
        )
        var analyzer = geometry.workerExecution.mappingAndRefinementInvocations[1]
        analyzer.mappingAttemptOrdinal = 2
        geometry.workerExecution.mappingAndRefinementInvocations = [
            rejectedMapper,
            acceptedMapper,
            analyzer,
        ]
        geometry.mapping = MappingArtifact(
            modelCount: 1,
            largestModelRegisteredViewCount: 2,
            secondLargestModelRegisteredViewCount: 0,
            unionRegisteredViewCount: 2,
            attemptCount: 2,
            acceptedMappingAttemptOrdinal: 2,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 1,
            plannedIncrementalCadence: .balancedGlobal,
            incrementalCadence: .frequentGlobal,
            cadenceFallbackTrigger: .lowReconstructionQuality,
            canonicalModelPublication: directTextPublication(geometry.modelHashes),
            fallbackReason: "Retry for Private Site at \(NSHomeDirectory())/private/input.mov"
        )
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "Private Site",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced),
                resolvedRunPlan: makeResolvedRunPlan(for: geometry)
            ),
            to: paths.metadataURL
        )
        geometry = try persistGeometrySidecar(geometry, paths: paths)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertTrue(bundle.contains("Models: 1 (largest 4, second 0)"))
        XCTAssertTrue(bundle.contains("Union registered: 4"))
        XCTAssertTrue(bundle.contains("Mapping attempts: 2"))
        XCTAssertTrue(bundle.contains("Accepted mapping attempt: 2"))
        XCTAssertTrue(bundle.contains("Accepted refinement: Incremental global (1 invocation)"))
        XCTAssertTrue(bundle.contains("Bundle adjustment plan: local 2, global 1.4× frames / 1.4× points, up to 5 refinements"))
        XCTAssertTrue(bundle.contains("Bundle adjustment accepted: local 2, global 1.1× frames / 1.1× points, up to 5 refinements"))
        XCTAssertTrue(bundle.contains("Bundle adjustment retry trigger: lowReconstructionQuality"))
        XCTAssertTrue(bundle.contains("Mapping fallback: Retry for <redacted> at <local-path>"))
        XCTAssertTrue(
            bundle.contains(
                "Camera grouping: allSelectedImagesShared · 4 images · 4 → 1 cameras"
            )
        )
        XCTAssertFalse(bundle.contains("Private Site"))
        XCTAssertFalse(bundle.contains(NSHomeDirectory()))

        let payload = try machineReadablePayload(from: bundle)
        XCTAssertEqual(
            payload["schemaVersion"] as? Int,
            19
        )
        let reconstruction = try XCTUnwrap(
            payload["reconstruction"] as? [String: Any]
        )
        XCTAssertEqual(reconstruction["registeredViewCount"] as? Int, 4)
        XCTAssertEqual(reconstruction["totalViewCount"] as? Int, 4)
        XCTAssertEqual(
            reconstruction["observationCount"] as? Int,
            geometry.observationCount
        )
        XCTAssertEqual(
            reconstruction["medianPixelResidual"] as? Double,
            geometry.medianPixelResidual
        )
        let mapping = try XCTUnwrap(payload["mapping"] as? [String: Any])
        let cameraGrouping = try XCTUnwrap(
            payload["cameraGrouping"] as? [String: Any]
        )
        XCTAssertEqual(cameraGrouping["mode"] as? String, "allSelectedImagesShared")
        XCTAssertEqual(cameraGrouping["cameraCountBefore"] as? Int, 4)
        XCTAssertEqual(cameraGrouping["cameraCountAfter"] as? Int, 1)
        XCTAssertEqual(cameraGrouping["groupedVideoSourceCount"] as? Int, 0)
        XCTAssertEqual(
            (cameraGrouping["groups"] as? [[String: Any]])?.first?["memberCount"] as? Int,
            4
        )
        XCTAssertEqual(mapping["modelCount"] as? Int, 1)
        XCTAssertEqual(mapping["largestModelRegisteredViewCount"] as? Int, 4)
        XCTAssertEqual(mapping["secondLargestModelRegisteredViewCount"] as? Int, 0)
        XCTAssertEqual(mapping["unionRegisteredViewCount"] as? Int, 4)
        XCTAssertEqual(mapping["attemptCount"] as? Int, 2)
        XCTAssertEqual(mapping["acceptedMappingAttemptOrdinal"] as? Int, 2)
        XCTAssertEqual(mapping["acceptedRefinementKind"] as? String, "incrementalGlobal")
        XCTAssertEqual(mapping["acceptedRefinementInvocationCount"] as? Int, 1)
        let cadence = try XCTUnwrap(mapping["incrementalCadence"] as? [String: Any])
        XCTAssertEqual(cadence["localMaxRefinements"] as? Int, 2)
        XCTAssertEqual(cadence["globalFramesRatio"] as? Double, 1.1)
        XCTAssertEqual(cadence["globalPointsRatio"] as? Double, 1.1)
        XCTAssertEqual(cadence["globalMaxRefinements"] as? Int, 5)
        let plannedCadence = try XCTUnwrap(
            mapping["plannedIncrementalCadence"] as? [String: Any]
        )
        XCTAssertEqual(
            plannedCadence["localMaxRefinements"] as? Int,
            cadence["localMaxRefinements"] as? Int
        )
        XCTAssertEqual(plannedCadence["globalFramesRatio"] as? Double, 1.4)
        XCTAssertEqual(plannedCadence["globalPointsRatio"] as? Double, 1.4)
        XCTAssertEqual(
            plannedCadence["globalMaxRefinements"] as? Int,
            cadence["globalMaxRefinements"] as? Int
        )
        XCTAssertEqual(
            mapping["fallbackReason"] as? String,
            "Retry for <redacted> at <local-path>"
        )
        XCTAssertEqual(Set(mapping.keys), [
            "modelCount",
            "largestModelRegisteredViewCount",
            "secondLargestModelRegisteredViewCount",
            "unionRegisteredViewCount",
            "attemptCount",
            "acceptedMappingAttemptOrdinal",
            "acceptedRefinementKind",
            "acceptedRefinementInvocationCount",
            "plannedIncrementalCadence",
            "incrementalCadence",
            "cadenceFallbackTrigger",
            "fallbackReason",
        ])
    }

    func testOmitsMappingFallbackLineWhenNoFallbackWasNeeded() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let geometry = makeGeometryArtifact()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "Direct Mapping",
            input: .photos(folder: "Originals/Photos"),
                resolvedRunPlan: makeResolvedRunPlan(for: geometry)
            ),
            to: paths.metadataURL
        )
        _ = try persistGeometrySidecar(geometry, paths: paths)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertFalse(bundle.contains("Mapping fallback:"))
        let mapping = try XCTUnwrap(
            try machineReadablePayload(from: bundle)["mapping"] as? [String: Any]
        )
        XCTAssertNil(mapping["fallbackReason"])
    }

    func testNotesAreIncludedOnlyWhenOptedIn() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "WithNotes",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            notes: "sunset capture"
        )
        try saveControlledPhotoMetadata(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root, includeNotes: true))
        XCTAssertTrue(bundle.contains("## Notes"))
        XCTAssertTrue(bundle.contains("sunset capture"))
    }

    func testExcludesUnlistedPrivateLog() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "PrivateLog",
            input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: paths.metadataURL
        )
        try "private-share-service-marker".write(
            to: paths.logsURL.appendingPathComponent("private_debug.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertFalse(bundle.contains("private-share-service-marker"))
        XCTAssertFalse(bundle.contains("private_debug.jsonl"))
    }

    func testHomePathSanitizerRedactsEntirePathWithoutRevealingDescendants() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "Could not read /Users/example/Clients/Acme/secret.mov; retry later."

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(sanitized, "Could not read <local-path>; retry later.")
        XCTAssertFalse(sanitized.contains("Clients"))
        XCTAssertFalse(sanitized.contains("Acme"))
        XCTAssertFalse(sanitized.contains("secret.mov"))
        XCTAssertEqual(
            sanitizer.sanitize("Mapper retry 2 of 3: no model registered."),
            "Mapper retry 2 of 3: no model registered."
        )
    }

    func testSanitizerRedactsPathBeforeOverlappingSensitiveValue() {
        let sanitizer = HomePathSanitizer(
            homePath: "/Users/example",
            sensitiveValues: ["example"]
        )

        let sanitized = sanitizer.sanitize(
            "Could not read /Users/example/Clients/secret.mov; retry later."
        )

        XCTAssertEqual(sanitized, "Could not read <local-path>; retry later.")
        for component in ["Users", "example", "Clients", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked path component: \(component)")
        }
    }

    func testSanitizerRedactsAbsoluteTemporaryPaths() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")

        let privateTemporary = sanitizer.sanitize(
            "source=/private/tmp/Client/secret.mov status=failed"
        )
        let varTemporary = sanitizer.sanitize("/var/tmp/x")

        XCTAssertEqual(privateTemporary, "source=<local-path> status=failed")
        XCTAssertEqual(varTemporary, "<local-path>")
        for component in ["private", "tmp", "Client", "secret.mov"] {
            XCTAssertFalse(
                privateTemporary.contains(component),
                "Leaked private temporary-path component: \(component)"
            )
        }
        for component in ["var", "tmp", "x"] {
            XCTAssertFalse(
                varTemporary.contains(component),
                "Leaked var temporary-path component: \(component)"
            )
        }
    }

    func testSanitizerRedactsPathInTruncatedEscapedJSONString() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = #"{"message":"failed to read \/Users\/example\/Clients\/secret.mov"#

        let sanitized = sanitizer.sanitize(input)

        XCTAssertTrue(sanitized.contains("failed to read"))
        XCTAssertTrue(sanitized.contains("<local-path>"))
        for component in ["Users", "example", "Clients", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked escaped path component: \(component)")
        }
    }

    func testSanitizerRedactsEntireMountedVolumePathAndURLCredentials() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "source=/Volumes/Client Drive/House/input.mov url=https://alice:secret@example.com/file"
        let sanitized = sanitizer.sanitize(input)

        XCTAssertFalse(sanitized.contains("Client Drive"))
        XCTAssertFalse(sanitized.contains("House"))
        XCTAssertFalse(sanitized.contains("input.mov"))
        XCTAssertFalse(sanitized.contains("alice"))
        XCTAssertFalse(sanitized.contains("secret"))
        XCTAssertTrue(sanitized.contains("source=<local-path>"))
        XCTAssertTrue(sanitized.contains("https://example.com/file"))
        XCTAssertEqual(sanitizer.sanitize("/Volumes/Client Drive"), "<local-path>")
    }

    func testSanitizerRedactsSemanticValuesInsideEscapedJSONStrings() throws {
        let projectID = "33333333-3333-3333-3333-333333333333"
        let sanitizer = HomePathSanitizer(
            homePath: "/Users/example",
            sensitiveValues: ["Client House", projectID]
        )
        let input = #"{"attempt":2,"home":"\/Users\/example\/Clients\/Acme\/secret.mov","mounted":"\/Volumes\/Client Drive\/House\/input.mov","projectID":"33333333\u002D3333\u002D3333\u002D3333\u002D333333333333","projectTitle":"Client\u0020House","status":"retrying"}"#

        let sanitized = sanitizer.sanitize(input)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sanitized.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["attempt"] as? Int, 2)
        XCTAssertEqual(payload["status"] as? String, "retrying")
        XCTAssertEqual(payload["home"] as? String, "<local-path>")
        XCTAssertEqual(payload["mounted"] as? String, "<local-path>")
        XCTAssertEqual(payload["projectID"] as? String, "<redacted>")
        XCTAssertEqual(payload["projectTitle"] as? String, "<redacted>")
        XCTAssertEqual(
            Set(payload.keys),
            ["attempt", "home", "mounted", "projectID", "projectTitle", "status"]
        )
        XCTAssertFalse(sanitized.contains("Clients"))
        XCTAssertFalse(sanitized.contains("Client Drive"))
        XCTAssertFalse(sanitized.contains("Client House"))
        XCTAssertFalse(sanitized.contains(projectID))
    }

    func testSanitizerRedactsQuotedPathsContainingSpacesQuotesAndPunctuation() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = #"Import failed for '/Users/example/Client Work/Scene "Final", take #2.mov'; retry is available."#

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(
            sanitized,
            "Import failed for '<local-path>'; retry is available."
        )
        XCTAssertFalse(sanitized.contains("Client Work"))
        XCTAssertFalse(sanitized.contains("Scene"))
        XCTAssertFalse(sanitized.contains("Final"))
        XCTAssertFalse(sanitized.contains("#2.mov"))
    }

    func testSanitizerRedactsUnquotedHomePathsContainingSpaces() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "source=/Users/example/Client Work/Scene Final.mov status=failed"

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(sanitized, "source=<local-path> status=failed")
        XCTAssertFalse(sanitized.contains("Client Work"))
        XCTAssertFalse(sanitized.contains("Scene Final.mov"))
    }

    func testSanitizerRecognizesLocalPathsAfterDiagnosticPunctuation() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let cases = [
            ("failed:/Users/example/Clients/secret.mov", "failed:<local-path>"),
            ("failed./Users/example/Clients/secret.mov", "failed.<local-path>"),
            ("failed_/Users/example/Clients/secret.mov", "failed_<local-path>"),
            ("url:file:///Users/example/Clients/secret.mov", "url:<local-path>"),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(sanitizer.sanitize(input), expected, "Input: \(input)")
        }

        let publicText = "ratio=1/2 docs=https://example.com/v1/models ipv6=https://[2001:db8::1]/v1/models"
        XCTAssertEqual(sanitizer.sanitize(publicText), publicText)
    }

    func testSanitizerRedactsDoubleSlashMacOSAbsolutePathAlias() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "source=//Users/example/Clients/secret.mov status=failed"

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(sanitized, "source=<local-path> status=failed")
        for component in ["Users", "example", "Clients", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked path component: \(component)")
        }
    }

    func testSanitizerRedactsUnquotedPathContainingApostrophe() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "source=/Users/example/Bob's Files/secret.mov status=failed"

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(sanitized, "source=<local-path> status=failed")
        for component in ["Bob", "Files", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked path component: \(component)")
        }
    }

    func testSanitizerRedactsUnquotedPathContainingApostropheBeforeSpace() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "source=/Users/example/Bob' Files/secret.mov status=failed"

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(sanitized, "source=<local-path> status=failed")
        for component in ["Bob", "Files", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked path component: \(component)")
        }
    }

    func testSanitizerRedactsCompleteSingleQuotedPathContainingApostrophes() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "Import failed for '/Users/example/Bob's Files/secret.mov'; retry is available."
        let punctuatedApostrophe = "Import failed for '/Users/example/Clients'; Archive/secret.mov'; retry is available."

        let sanitized = sanitizer.sanitize(input)
        let sanitizedPunctuation = sanitizer.sanitize(punctuatedApostrophe)

        XCTAssertEqual(sanitized, "Import failed for '<local-path>'; retry is available.")
        XCTAssertEqual(sanitizedPunctuation, "Import failed for '<local-path>'; retry is available.")
        for component in ["Bob", "Files", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked path component: \(component)")
        }
        for component in ["Clients", "Archive", "secret.mov"] {
            XCTAssertFalse(
                sanitizedPunctuation.contains(component),
                "Leaked punctuated path component: \(component)"
            )
        }
    }

    func testSanitizerClosesQuotedPathBeforeOrdinaryProse() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "Could not open '/Users/example/secret.mov' because permission was denied."

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "Could not open '<local-path>' because permission was denied."
        )
    }

    func testSanitizerUsesFirstValidQuotedPathCloseBeforePossessiveProse() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "Could not open '/Users/example/secret.mov' because users' permissions changed."

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "Could not open '<local-path>' because users' permissions changed."
        )
    }

    func testSanitizerPreservesFieldsAfterUnclosedQuotedPath() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "source='/Users/example/secret.mov status=failed"

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "source='<local-path> status=failed"
        )
    }

    func testSanitizerTreatsCRLFCharacterAsPathTerminator() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "path=/Users/example/secret.mov\r\nPermission denied"

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "path=<local-path>\r\nPermission denied"
        )
    }

    func testSanitizerRedactsSingleSlashFileURIAndPreservesProse() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "Could not open file:/Users/example/Clients/secret.mov because permission was denied."

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(
            sanitized,
            "Could not open <local-path> because permission was denied."
        )
        for component in ["Users", "example", "Clients", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked file URI component: \(component)")
        }
    }

    func testSanitizerTreatsDecodedJSONStringPathCharactersAsSemanticContent() throws {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let privatePath = "/Users/example/Client;Secret\nPipe|Tick`Angles<Hidden>Quote\"/secret.mov"
        let inputData = try JSONSerialization.data(
            withJSONObject: ["path": privatePath, "status": "failed"],
            options: [.sortedKeys]
        )
        let input = try XCTUnwrap(String(data: inputData, encoding: .utf8))

        let sanitized = sanitizer.sanitize(input)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sanitized.utf8)) as? [String: String]
        )

        XCTAssertEqual(payload, ["path": "<local-path>", "status": "failed"])
        for component in ["Client", "Secret", "Pipe", "Tick", "Angles", "Hidden", "Quote", "secret.mov"] {
            XCTAssertFalse(sanitized.contains(component), "Leaked path component: \(component)")
        }
    }

    func testSanitizerDecodesPathSeparatorsInTruncatedJSONStringTail() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let pathInput = #"{"message":"failed \u002FUsers\u002Fexample\u002FClients\u002Fsecret.mov"#

        let sanitizedPath = sanitizer.sanitize(pathInput)

        XCTAssertTrue(sanitizedPath.contains("failed"))
        XCTAssertTrue(sanitizedPath.contains("<local-path>"))
        for component in ["Users", "example", "Clients", "secret.mov"] {
            XCTAssertFalse(sanitizedPath.contains(component), "Leaked escaped path component: \(component)")
        }
    }

    func testSanitizerDecodesSensitiveUnicodeEscapesInTruncatedJSONStringTail() {
        let projectID = "33333333-3333-3333-3333-333333333333"
        let sanitizer = HomePathSanitizer(
            homePath: "/Users/example",
            sensitiveValues: [projectID, "😀"]
        )
        let input = #"{"message":"project 33333333\u002D3333\u002D3333\u002D3333\u002D333333333333 \uD83D\uDE00 unavailable"#

        let sanitized = sanitizer.sanitize(input)

        XCTAssertTrue(sanitized.contains("project <redacted> <redacted> unavailable"))
        XCTAssertFalse(sanitized.contains(projectID))
    }

    func testSanitizerDoesNotDecodeUnmatchedSurrogateInTruncatedJSONStringTail() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = #"{"message":"value \uD800 remains"#

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(sanitized, input)
    }

    func testSanitizerRedactsEscapedPathInsideMalformedClosedJSONString() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = #"{"message":"failed \u002FUsers\u002Fexample\u002FClients\u002Fsecret.mov\q"}"#

        let sanitized = sanitizer.sanitize(input)

        XCTAssertTrue(sanitized.contains("failed"))
        XCTAssertTrue(sanitized.contains("<local-path>"))
        for component in ["Users", "example", "Clients", "secret.mov"] {
            XCTAssertFalse(
                sanitized.contains(component),
                "Leaked malformed escaped path component: \(component)"
            )
        }
    }

    func testSanitizerScannerWorkRemainsLinearForLongWhitespaceAndJSON() {
        let sanitizer = HomePathSanitizer(
            homePath: "/Users/example",
            sensitiveValues: ["Client House"]
        )
        let smallInput = "source=/Users/example/input.mov"
            + String(repeating: " ", count: 8_192)
            + "status=failed "
            + String(repeating: #"{"value":"safe"}"#, count: 128)
        let largeInput = "source=/Users/example/input.mov"
            + String(repeating: " ", count: 32_768)
            + "status=failed "
            + String(repeating: #"{"value":"safe"}"#, count: 512)
        var smallMetrics = HomePathSanitizer.ScanMetrics()
        var largeMetrics = HomePathSanitizer.ScanMetrics()

        let smallOutput = sanitizer.sanitize(smallInput, metrics: &smallMetrics)
        let largeOutput = sanitizer.sanitize(largeInput, metrics: &largeMetrics)

        XCTAssertTrue(smallOutput.hasPrefix("source=<local-path>"))
        XCTAssertTrue(largeOutput.hasPrefix("source=<local-path>"))
        XCTAssertLessThanOrEqual(
            largeMetrics.characterVisits,
            smallMetrics.characterVisits * 5,
            "A 4× input must not trigger superlinear scanner work."
        )
        XCTAssertLessThanOrEqual(
            largeMetrics.characterVisits,
            largeInput.count * 12,
            "Each pass must perform only a bounded number of visits per character."
        )
    }

    func testSanitizerPreservesExplanationAndNetworkURLsAfterLocalPath() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "Failed to read /Users/example/x, see https://help.example.com/docs"

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "Failed to read <local-path>, see https://help.example.com/docs"
        )
        XCTAssertEqual(
            sanitizer.sanitize("endpoint=https://[2001:db8::1]/v1/models"),
            "endpoint=https://[2001:db8::1]/v1/models"
        )
        XCTAssertEqual(
            sanitizer.sanitize("endpoint=https://alice:secret@[2001:db8::1]/v1/models"),
            "endpoint=https://[2001:db8::1]/v1/models"
        )
    }

    func testSanitizerRedactsSensitiveNetworkURLQueryValues() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "endpoint=https://alice:credential@example.com/download"
            + "?file=scene.ply"
            + "&access_token=access-value"
            + "&TOKEN=token-value"
            + "&api_key=api-value"
            + "&key=key-value"
            + "&password=password-value"
            + "&secret=secret-value"
            + "&signature=signature-value"
            + "&authorization=authorization-value"
            + "&auth=auth-value"
            + "&code=code-value"
            + "&page=2#result"
        let expected = "endpoint=https://example.com/download"
            + "?file=scene.ply"
            + "&access_token=<redacted>"
            + "&TOKEN=<redacted>"
            + "&api_key=<redacted>"
            + "&key=<redacted>"
            + "&password=<redacted>"
            + "&secret=<redacted>"
            + "&signature=<redacted>"
            + "&authorization=<redacted>"
            + "&auth=<redacted>"
            + "&code=<redacted>"
            + "&page=2#result"

        let sanitized = sanitizer.sanitize(input)

        XCTAssertEqual(sanitized, expected)
        for value in [
            "credential", "access-value", "token-value", "api-value",
            "key-value", "password-value", "secret-value", "signature-value",
            "authorization-value", "auth-value", "code-value",
        ] {
            XCTAssertFalse(sanitized.contains(value), "Leaked URL credential: \(value)")
        }
    }

    func testSanitizerRedactsPercentEncodedSensitiveQueryKeyAndKeepsHarmlessQuery() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "https://example.com/download?%61ccess_token=secret&page=2&sort=newest"

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "https://example.com/download?%61ccess_token=<redacted>&page=2&sort=newest"
        )
    }

    func testSanitizerRedactsSensitiveQueryAfterSemicolonDelimiter() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "https://example.com/download?page=2;access_token=secret;sort=newest"

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "https://example.com/download?page=2;access_token=<redacted>;sort=newest"
        )
    }

    func testSanitizerPreservesSentencePunctuationAfterSensitiveURLQuery() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "Open (https://example.com/download?access_token=secret). Continue."

        XCTAssertEqual(
            sanitizer.sanitize(input),
            "Open (https://example.com/download?access_token=<redacted>). Continue."
        )
    }

    func testSanitizerSensitiveQueryScanningRemainsLinear() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let smallInput = "endpoint=https://example.com/download?"
            + Array(repeating: "page=2;access_token=secret", count: 128).joined(separator: "&")
            + "). Continue."
        let largeInput = "endpoint=https://example.com/download?"
            + Array(repeating: "page=2;access_token=secret", count: 512).joined(separator: "&")
            + "). Continue."
        var smallMetrics = HomePathSanitizer.ScanMetrics()
        var largeMetrics = HomePathSanitizer.ScanMetrics()

        let smallOutput = sanitizer.sanitize(smallInput, metrics: &smallMetrics)
        let largeOutput = sanitizer.sanitize(largeInput, metrics: &largeMetrics)

        XCTAssertFalse(smallOutput.contains("access_token=secret"))
        XCTAssertFalse(largeOutput.contains("access_token=secret"))
        XCTAssertTrue(smallOutput.hasSuffix("). Continue."))
        XCTAssertTrue(largeOutput.hasSuffix("). Continue."))
        XCTAssertLessThanOrEqual(
            largeMetrics.characterVisits,
            smallMetrics.characterVisits * 5,
            "A 4× query must not trigger superlinear scanner work."
        )
        XCTAssertLessThanOrEqual(
            largeMetrics.characterVisits,
            largeInput.count * 12,
            "Query sanitization must perform bounded work per character."
        )
    }

    func testDiagnosticsRedactProjectIdentityFromErrorsAndLogs() throws {
        let root = try TestFileBuilder.makeTempDir().appendingPathComponent("123 Main St.easysplatproj")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let identifier = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                id: identifier,
                title: "123 Main St",
            input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced),
                state: PipelineState(
                    stage: .sfmMapping,
                    lastError: "Failed 123 Main St / \(identifier.uuidString)"
                )
            ),
            to: paths.metadataURL
        )
        try "project=123 Main St id=\(identifier.uuidString)".write(
            to: paths.pipelineLogURL,
            atomically: true,
            encoding: .utf8
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertFalse(bundle.contains("123 Main St"))
        XCTAssertFalse(bundle.contains(identifier.uuidString))
    }

    func testDiagnosticsRedactPunctuatedProjectBundleNameFromErrorsAndLogs() throws {
        let bundleName = #"Client "West", #7.easysplatproj"#
        let lowercasedBundleName = bundleName.lowercased()
        let encodedBundleName = try XCTUnwrap(
            bundleName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        )
        let parent = try TestFileBuilder.makeTempDir()
        let root = parent.appendingPathComponent(bundleName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                title: "Neutral title",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .walkthrough,
                    detailProfile: .balanced
                ),
                state: PipelineState(
                    stage: .sfmMapping,
                    lastError: "Could not reopen \(lowercasedBundleName); write access was lost."
                )
            ),
            to: paths.metadataURL
        )
        try "Recovery for \(encodedBundleName) is still available.".write(
            to: paths.pipelineLogURL,
            atomically: true,
            encoding: .utf8
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertFalse(bundle.contains(bundleName))
        XCTAssertFalse(bundle.localizedCaseInsensitiveContains("client \"west\""))
        XCTAssertFalse(bundle.contains(encodedBundleName))
        XCTAssertFalse(bundle.localizedCaseInsensitiveContains("#7.easysplatproj"))
        XCTAssertTrue(bundle.contains("Could not reopen <redacted>; write access was lost."))
        XCTAssertTrue(bundle.contains("Recovery for <redacted> is still available."))
    }

    func testSharingSanitizerRedactsProjectIdentityPathsAndCredentials() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Client House.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let identifier = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        try saveControlledPhotoMetadata(
            ProjectMetadata(
                id: identifier,
                title: "Client House",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced)
            ),
            to: paths.metadataURL
        )
        let raw = """
        project=Client House id=\(identifier.uuidString)
        home=\(NSHomeDirectory())/Documents/input.mov
        media=/Volumes/Client Drive/House/input.mov
        url=https://alice:secret@example.com/file
        """

        let sanitized = ProjectDiagnosticBundle.sanitizeForSharing(
            raw,
            projectURL: root
        )

        XCTAssertFalse(sanitized.contains("Client House"))
        XCTAssertFalse(sanitized.contains(identifier.uuidString))
        XCTAssertFalse(sanitized.contains(NSHomeDirectory()))
        XCTAssertFalse(sanitized.contains("Client Drive"))
        XCTAssertFalse(sanitized.contains("alice"))
        XCTAssertFalse(sanitized.contains("secret"))
        XCTAssertTrue(sanitized.contains("home=<local-path>"))
        XCTAssertTrue(sanitized.contains("media=<local-path>"))
        XCTAssertTrue(sanitized.contains("https://example.com/file"))
    }

    private func saveControlledPhotoMetadata(
        _ metadata: ProjectMetadata,
        to metadataURL: URL
    ) throws {
        let paths = ProjectPaths(root: metadataURL.deletingLastPathComponent())
        let controlled = try TestFileBuilder.bindingControlledPhotoInput(
            to: metadata,
            paths: paths
        )
        let plan = controlled.resolvedRunPlan ?? RunPlanResolver.resolve(
            requestedOptions: controlled.requestedRunOptions,
            input: controlled.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let strategy: PhotoSelectionStrategy
        switch (plan.photoSelection, plan.inputOrdering) {
        case (.automatic, .continuous):
            strategy = .continuousEvenSpacing
        case (.automatic, .unordered):
            strategy = .visualDiversity
        case (.useAllValidPhotos, .continuous), (.useAllValidPhotos, .unordered):
            strategy = .useAll
        case (_, .automatic):
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let receipts = try XCTUnwrap(controlled.photoInputReceipts)
        let artifact = PhotoSelectionArtifact(
            strategy: strategy,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: plan.inputOrdering,
            requestedPhotoSelection: plan.photoSelection,
            admissionCapacity: receipts.count,
            discoveredCount: receipts.count,
            acceptedCount: receipts.count,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: receipts.enumerated().map { index, receipt in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: index,
                    evidence: receipt.analysisEvidence,
                    retainedRank: receipt.retainedRank
                )
            },
            retainedSourceSHA256s: receipts.sorted {
                $0.retainedRank < $1.retainedRank
            }.map(\.source.sha256),
            canonicalRetainedSourceSHA256s: receipts.map(\.source.sha256)
        )
        let file = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        var selectionBound = controlled
        selectionBound.resolvedRunPlan = plan
        selectionBound.photoSelectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: file.byteCount,
            sha256: file.sha256,
            artifactSchemaVersion: artifact.schemaVersion,
            analysisRecipeVersion: artifact.analysisRecipeVersion,
            analysisRecipeSHA256: artifact.analysisRecipeSHA256,
            selectorPolicyVersion: artifact.selectorPolicyVersion,
            selectorPolicySHA256: artifact.selectorPolicySHA256
        )
        try PhotoInputReceiptValidator.validateFiles(
            metadata: selectionBound,
            paths: paths
        )
        try ProjectMetadataStore.save(selectionBound, to: metadataURL)
    }

    private func persistGeometrySidecar(
        _ proposedArtifact: GeometryArtifact,
        paths: ProjectPaths
    ) throws -> GeometryArtifact {
        let imageNames = [
            "frame_000001.jpg",
            "frame_000002.jpg",
            "frame_000003.jpg",
            "frame_000004.jpg",
        ]
        for (index, imageName) in imageNames.enumerated() {
            try Data("selected frame \(index + 1)".utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(imageName),
                options: [.atomic]
            )
        }

        let modelURL = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelURL,
            withIntermediateDirectories: true
        )
        let points: [(x: Double, y: Double, z: Double)] = (0..<20).map { index in
            let x = Double(index % 5 - 2) * 0.5
            let y = Double(index / 5 - 2) * 0.5
            return (
                x: x,
                y: y,
                z: 10.0
            )
        }
        var tracks = Array(repeating: [String](), count: points.count)
        let cameraCenters: [(x: Double, y: Double, z: Double)] = [
            (-2, 0, 0),
            (2, 0, 0),
            (0, -2, 0),
            (0, 0, -2),
        ]
        let imageRows = imageNames.enumerated().flatMap { offset, imageName -> [String] in
            let imageID = offset + 1
            let center = cameraCenters[offset]
            let observations = points.enumerated().map { pointIndex, point in
                tracks[pointIndex].append("\(imageID) \(pointIndex)")
                let cameraZ = point.z - center.z
                let x = 500 * (point.x - center.x) / cameraZ + 320
                let y = 500 * (point.y - center.y) / cameraZ + 240
                return "\(x) \(y) \(pointIndex + 1)"
            }.joined(separator: " ")
            return [
                "\(imageID) 1 0 0 0 \(-center.x) \(-center.y) \(-center.z) 1 \(imageName)",
                observations,
            ]
        }.joined(separator: "\n") + "\n"
        let pointRows = points.enumerated().map { index, point in
            "\(index + 1) \(point.x) \(point.y) \(point.z) 255 255 255 0 "
                + tracks[index].joined(separator: " ")
        }.joined(separator: "\n") + "\n"
        let modelContents = [
            "cameras.txt": "1 PINHOLE 640 480 500 500 320 240\n",
            "images.txt": imageRows,
            "points3D.txt": pointRows,
        ]
        var modelHashes: [String: String] = [:]
        for (name, contents) in modelContents {
            let url = modelURL.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url, options: [.atomic])
            modelHashes[name] = try GeometryArtifactStore.sha256(of: url)
        }

        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        var artifact = proposedArtifact
        artifact.modelVersion = "none"
        artifact.poseConvention = "world-to-camera"
        artifact.handedness = "right-handed"
        artifact.scaleType = "arbitrary-sim3"
        artifact.residualProvenance = "colmap-text-tracks-v1"
        artifact.timings["orientation_estimation_seconds"] = 0
        artifact.inputDigest = try GeometryArtifactStore.inputDigest(projectPaths: paths)
        artifact.selectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: imageNames,
            projectPaths: paths
        )
        artifact.orderedImageNames = imageNames
        artifact.orderedImageTimestamps = imageNames.indices.map(Double.init)
        artifact.registeredViewCount = imageNames.count
        artifact.totalViewCount = imageNames.count
        artifact.pointCount = points.count
        artifact.observationCount = points.count * imageNames.count
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
                ),
            ]
        )
        if var measurement = artifact.pairGraph.measurement {
            let pairCount = imageNames.count * (imageNames.count - 1) / 2
            measurement.scheduledPairCount = pairCount
            measurement.attemptedPairCount = pairCount
            measurement.rawMatchedPairCount = pairCount
            measurement.spatiallyVerifiedPairCount = pairCount
            measurement.localPairCount = pairCount
            measurement.componentViewCounts = [imageNames.count]
            measurement.largestBiconnectedBlockViewCount = imageNames.count
            measurement.degreeP10 = imageNames.count - 1
            measurement.degreeMedian = imageNames.count - 1
            measurement.degreeP90 = imageNames.count - 1
            measurement.matcherAttempts[0].scheduledPairCount = pairCount
            measurement.matcherAttempts[0].attemptedPairCount = pairCount
            measurement.matcherAttempts[0].rawMatchedPairCount = pairCount
            measurement.matcherAttempts[0].spatiallyVerifiedPairCount = pairCount
            artifact.pairGraph.measurement = measurement
            artifact.workerExecution.matchingInvocations[0]
                .pairExecution?.scheduledPairCount = pairCount
        }
        artifact.mapping.largestModelRegisteredViewCount = imageNames.count
        artifact.mapping.unionRegisteredViewCount = imageNames.count
        artifact.modelHashes = modelHashes
        artifact.mapping.canonicalModelPublication = directTextPublication(modelHashes)
        let analysis = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: modelURL,
            maximumRayPairEvaluations:
                GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
        )
        artifact.medianPixelResidual = max(0, analysis.residuals.medianPixelResidual)
        artifact.p90PixelResidual = max(
            artifact.medianPixelResidual,
            analysis.residuals.p90PixelResidual
        )
        artifact.conditioning = GeometryConditioningArtifact(
            sourceModelClosureSHA256: try XCTUnwrap(
                GeometryArtifactStore.modelClosureDigest(
                    modelHashes,
                    expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
                )
            ),
            measurement: analysis.measurement
        )
        _ = try GeometryWorkerExecutionArtifactStore.save(
            artifact.workerExecution,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            expectedBudget: artifact.workerExecution.resolvedBudget,
            projectPaths: paths
        )
        try GeometryArtifactStore.persist(
            artifact,
            metadata: &metadata,
            paths: paths,
            measuredAnalysis: analysis
        )
        return artifact
    }

    private func machineReadablePayload(from bundle: String) throws -> [String: Any] {
        let start = try XCTUnwrap(bundle.range(of: "```json\n"))
        let end = try XCTUnwrap(bundle.range(of: "\n```", range: start.upperBound..<bundle.endIndex))
        let json = String(bundle[start.upperBound..<end.lowerBound])
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any]
        )
    }

    private func makeResolvedRunPlan(
        for geometry: GeometryArtifact,
        requestedOptions: RequestedRunOptions = RequestedRunOptions(
            capturePath: .walkthrough,
            detailProfile: .balanced
        )
    ) -> ResolvedRunPlan {
        var plan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: .photos(folder: "Originals/Photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        plan.geometryWorkerBudget = geometry.workerExecution.resolvedBudget
        plan.cameraGrouping = geometry.cameraGrouping
        plan.cameraInitializationRecipe = geometry.cameraInitializationReceipt.recipe
        if let cadence = geometry.mapping.plannedIncrementalCadence {
            plan.baLocalMaxRefinements = cadence.localMaxRefinements
            plan.baGlobalFramesRatio = cadence.globalFramesRatio
            plan.baGlobalPointsRatio = cadence.globalPointsRatio
            plan.baGlobalMaxRefinements = cadence.globalMaxRefinements
        }
        return plan
    }
}
