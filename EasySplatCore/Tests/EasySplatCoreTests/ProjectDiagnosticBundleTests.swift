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

        let metadata = ProjectMetadata(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "DiagnosticProject",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .sfmMapping, lastError: "boom"),
            reconstruction: ReconstructionSummary(
                mapper: "point_triangulator+bundle_adjuster",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
                registeredImages: 18,
                totalImages: 20,
                meanReprojectionError: 0.85,
                pointCount: 14_000,
                observationCount: 56_000,
                meanTrackLength: 4.0
            ),
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 30),
                .init(stage: .sfmMapping, startedAt: Date(timeIntervalSince1970: 1_700_000_030), durationSeconds: 90)
            ]
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
        XCTAssertTrue(bundle.contains("Mapper: point_triangulator+bundle_adjuster"))
        XCTAssertTrue(bundle.contains("Registered: 18 / 20"))
        XCTAssertTrue(bundle.contains("Points: 14000"))
        XCTAssertTrue(bundle.contains("## Stage Timings"))
        XCTAssertTrue(bundle.contains("sfmFeatures: 30s"))
        XCTAssertTrue(bundle.contains("sfmMapping: 90s"))
        XCTAssertTrue(bundle.contains("Total: 120s"))
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
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try "first line\nsecond line\nthird line".write(to: paths.pipelineLogURL, atomically: true, encoding: .utf8)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains("## pipeline.log (tail)"))
        XCTAssertTrue(bundle.contains("third line"))
    }

    func testSkipsSymlinkedLogTailWithoutReadingExternalContents() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "SymlinkedLog",
                input: .photos(folder: "/tmp/photos"),
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "SymlinkedLogsDirectory",
                input: .photos(folder: "/tmp/photos"),
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "HardLinkedLog",
                input: .photos(folder: "/tmp/photos"),
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "FIFOLog",
                input: .photos(folder: "/tmp/photos"),
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
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Privacy",
                input: .photos(folder: "/tmp/photos"),
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
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            notes: "secret location: 47.6,-122.3"
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertFalse(bundle.contains("secret location"), "Notes must not leak into the default diagnostic bundle.")
        XCTAssertFalse(bundle.contains("## Notes"))
    }

    func testMachineReadableJsonContainsRequestedOptionsAndStageTimings() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "MachineDetailed",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .highDetail),
            reconstruction: ReconstructionSummary(
                mapper: "colmap",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                registeredImages: 1,
                totalImages: 1
            ),
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 12)
            ]
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        guard let start = bundle.range(of: "```json\n"),
              let end = bundle.range(of: "\n```", range: start.upperBound..<bundle.endIndex) else {
            return XCTFail("JSON fence missing")
        }
        let json = String(bundle[start.upperBound..<end.lowerBound])
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any]
        let options = parsed?["requestedRunOptions"] as? [String: Any]
        XCTAssertEqual(options?["capturePath"] as? String, "walkthrough")
        XCTAssertEqual(options?["detailProfile"] as? String, "highDetail")
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
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .sfmMapping, lastError: "mapper exploded"),
            reconstruction: ReconstructionSummary(
                mapper: "colmap",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                registeredImages: 1,
                totalImages: 2
            ),
            lastFailureAt: failureDate
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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

    func testIncludesMachineReadableJsonSectionWhenMetricsExist() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let reconstruction = ReconstructionSummary(
            mapper: "colmap",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            registeredImages: 18,
            totalImages: 20,
            meanReprojectionError: 0.7,
            pointCount: 5_000
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Machine",
                input: .photos(folder: "/tmp/photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
                reconstruction: reconstruction
            ),
            to: paths.metadataURL
        )

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

    func testMachineReadableJsonKeepsReliableReprojection() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "ReliableColmap",
                input: .photos(folder: "/tmp/photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
                reconstruction: ReconstructionSummary(
                    mapper: "colmap",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    registeredImages: 18,
                    totalImages: 20,
                    meanReprojectionError: 0.85
                )
            ),
            to: paths.metadataURL
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        let parsed = try machineReadablePayload(from: bundle)
        let reconstruction = try XCTUnwrap(parsed["reconstruction"] as? [String: Any])
        XCTAssertEqual(reconstruction["meanReprojectionError"] as? Double, 0.85)
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
            activeIncrementalCadence: .conservative
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Private Recovery",
                input: .photos(folder: "/tmp/photos"),
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
                mode: .sameScheduleExact,
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
        geometry.registeredViewCount = 18
        geometry.totalViewCount = 20
        geometry.mapping = MappingArtifact(
            modelCount: 2,
            largestModelRegisteredViewCount: 18,
            secondLargestModelRegisteredViewCount: 5,
            unionRegisteredViewCount: 20,
            attemptCount: 3,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 4,
            incrementalCadence: IncrementalMappingCadenceArtifact(
                localMaxRefinements: 2,
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5
            ),
            fallbackReason: "Retry for Private Site at \(NSHomeDirectory())/private/input.mov"
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Private Site",
                input: .photos(folder: "/tmp/photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced),
                geometryArtifact: geometry,
                reconstruction: ReconstructionSummary(
                    mapper: "colmap",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    registeredImages: 18,
                    totalImages: 20
                )
            ),
            to: paths.metadataURL
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))

        XCTAssertTrue(bundle.contains("Models: 2 (largest 18, second 5)"))
        XCTAssertTrue(bundle.contains("Union registered: 20"))
        XCTAssertTrue(bundle.contains("Mapping attempts: 3"))
        XCTAssertTrue(bundle.contains("Accepted refinement: Incremental global (4 invocations)"))
        XCTAssertTrue(bundle.contains("Bundle adjustment: local 2, global 1.4× frames / 1.4× points, up to 5 refinements"))
        XCTAssertTrue(bundle.contains("Mapping fallback: Retry for <redacted> at ~/private/input.mov"))
        XCTAssertFalse(bundle.contains("Private Site"))
        XCTAssertFalse(bundle.contains(NSHomeDirectory()))

        let payload = try machineReadablePayload(from: bundle)
        XCTAssertEqual(
            payload["schemaVersion"] as? Int,
            ProjectDiagnosticBundle.machineReadableSchemaVersion
        )
        let mapping = try XCTUnwrap(payload["mapping"] as? [String: Any])
        XCTAssertEqual(mapping["modelCount"] as? Int, 2)
        XCTAssertEqual(mapping["largestModelRegisteredViewCount"] as? Int, 18)
        XCTAssertEqual(mapping["secondLargestModelRegisteredViewCount"] as? Int, 5)
        XCTAssertEqual(mapping["unionRegisteredViewCount"] as? Int, 20)
        XCTAssertEqual(mapping["attemptCount"] as? Int, 3)
        XCTAssertEqual(mapping["acceptedRefinementKind"] as? String, "incrementalGlobal")
        XCTAssertEqual(mapping["acceptedRefinementInvocationCount"] as? Int, 4)
        let cadence = try XCTUnwrap(mapping["incrementalCadence"] as? [String: Any])
        XCTAssertEqual(cadence["localMaxRefinements"] as? Int, 2)
        XCTAssertEqual(cadence["globalFramesRatio"] as? Double, 1.4)
        XCTAssertEqual(cadence["globalPointsRatio"] as? Double, 1.4)
        XCTAssertEqual(cadence["globalMaxRefinements"] as? Int, 5)
        XCTAssertEqual(
            mapping["fallbackReason"] as? String,
            "Retry for <redacted> at ~/private/input.mov"
        )
        XCTAssertEqual(Set(mapping.keys), [
            "modelCount",
            "largestModelRegisteredViewCount",
            "secondLargestModelRegisteredViewCount",
            "unionRegisteredViewCount",
            "attemptCount",
            "acceptedRefinementKind",
            "acceptedRefinementInvocationCount",
            "incrementalCadence",
            "fallbackReason",
        ])
    }

    func testOmitsMappingFallbackLineWhenNoFallbackWasNeeded() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let geometry = makeGeometryArtifact()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Direct Mapping",
                input: .photos(folder: "/tmp/photos"),
                geometryArtifact: geometry,
                reconstruction: ReconstructionSummary(
                    mapper: "colmap",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    registeredImages: 2,
                    totalImages: 2
                )
            ),
            to: paths.metadataURL
        )

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
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            notes: "sunset capture"
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root, includeNotes: true))
        XCTAssertTrue(bundle.contains("## Notes"))
        XCTAssertTrue(bundle.contains("sunset capture"))
    }

    func testExcludesUnlistedPrivateLog() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "PrivateLog",
                input: .photos(folder: "/tmp/photos"),
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

    func testHomePathSanitizerReplacesHome() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        XCTAssertEqual(sanitizer.sanitize("/Users/example/Documents/foo"), "~/Documents/foo")
        XCTAssertEqual(sanitizer.sanitize("/var/tmp/x"), "/var/tmp/x")
    }

    func testSanitizerRedactsRemovableVolumeNamesAndURLCredentials() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        let input = "source=/Volumes/Client Drive/House/input.mov url=https://alice:secret@example.com/file"
        let sanitized = sanitizer.sanitize(input)

        XCTAssertFalse(sanitized.contains("Client Drive"))
        XCTAssertFalse(sanitized.contains("alice"))
        XCTAssertFalse(sanitized.contains("secret"))
        XCTAssertTrue(sanitized.contains("/Volumes/<redacted>/House/input.mov"))
        XCTAssertTrue(sanitized.contains("https://example.com/file"))
        XCTAssertEqual(sanitizer.sanitize("/Volumes/Client Drive"), "/Volumes/<redacted>")
    }

    func testDiagnosticsRedactProjectIdentityFromErrorsAndLogs() throws {
        let root = try TestFileBuilder.makeTempDir().appendingPathComponent("123 Main St.easysplatproj")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let identifier = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        try ProjectMetadataStore.save(
            ProjectMetadata(
                id: identifier,
                title: "123 Main St",
                input: .photos(folder: "/tmp/photos"),
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

    func testSharingSanitizerRedactsProjectIdentityPathsAndCredentials() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Client House.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let identifier = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        try ProjectMetadataStore.save(
            ProjectMetadata(
                id: identifier,
                title: "Client House",
                input: .photos(folder: "/tmp/photos"),
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
        XCTAssertTrue(sanitized.contains("~/Documents/input.mov"))
        XCTAssertTrue(sanitized.contains("/Volumes/<redacted>/House/input.mov"))
        XCTAssertTrue(sanitized.contains("https://example.com/file"))
    }

    private func machineReadablePayload(from bundle: String) throws -> [String: Any] {
        let start = try XCTUnwrap(bundle.range(of: "```json\n"))
        let end = try XCTUnwrap(bundle.range(of: "\n```", range: start.upperBound..<bundle.endIndex))
        let json = String(bundle[start.upperBound..<end.lowerBound])
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any]
        )
    }
}
