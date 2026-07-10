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
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .sfmMapping, attempt: 2, lastError: "boom", resumeToken: nil),
            reconstruction: ReconstructionSummary(
                mapper: "vggt",
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
        XCTAssertTrue(bundle.contains("Project title: DiagnosticProject"))
        XCTAssertTrue(bundle.contains("Project id: 11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(bundle.contains("Hardware: Mac mini M4 Max, 48 GB"))
        XCTAssertTrue(bundle.contains("## Reconstruction"))
        XCTAssertTrue(bundle.contains("Mapper: vggt"))
        XCTAssertTrue(bundle.contains("Registered: 18 / 20"))
        XCTAssertTrue(bundle.contains("Points: 14000"))
        XCTAssertTrue(bundle.contains("## Stage Timings"))
        XCTAssertTrue(bundle.contains("sfmFeatures: 30s"))
        XCTAssertTrue(bundle.contains("sfmMapping: 90s"))
        XCTAssertTrue(bundle.contains("Total: 120s"))
        XCTAssertTrue(bundle.contains("## Pipeline State"))
        XCTAssertTrue(bundle.contains("Last error: boom"))
    }

    func testIncludesAutoTuneSectionWhenPresent() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let snapshot = AutoTuneSnapshot(
            tier: "High",
            memoryGB: 48.0,
            cpuCount: 16,
            gpuWorkingSetGB: 32.0,
            mapAnythingResolution: 518,
            mapAnythingDirectViewLimit: 8,
            mapAnythingAnchorMaxViews: 64,
            mapAnythingWindowSize: 8,
            mapAnythingWindowOverlap: 2,
            vggtImageLoadResolution: 1280,
            vggtFixedResolution: 518,
            vggtMaxPoints: 150_000,
            vggtAllowed: true,
            colmapMaxNumFeatures: 10_000,
            colmapMaxNumMatches: 10_000,
            colmapSequentialOverlap: 12,
            colmapExhaustiveBlockSize: 25,
            threadCap: 8,
            colmapMaxImageSizeCap: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let metadata = ProjectMetadata(
            title: "TunedProject",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            autoTune: snapshot
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains("## Auto-tune"))
        XCTAssertTrue(bundle.contains("Tier: High"))
        XCTAssertTrue(bundle.contains("maxPoints=150000"))
    }

    func testEmbedsLogTailsWhenPresent() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "WithLogs",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try "first line\nsecond line\nthird line".write(to: paths.pipelineLogURL, atomically: true, encoding: .utf8)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains("## pipeline.log (tail)"))
        XCTAssertTrue(bundle.contains("third line"))
    }

    func testEmbedsGlobalMapperLogTailWhenPresent() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "WithGlobalMapperLog",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .draft)
            ),
            to: paths.metadataURL
        )
        try "global mapper failed here".write(to: paths.glomapLogURL, atomically: true, encoding: .utf8)

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertTrue(bundle.contains("## glomap.log (tail)"))
        XCTAssertTrue(bundle.contains("global mapper failed here"))
    }

    func testSkipsLogTailsForEmptyFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "EmptyLogs",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
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
            preset: PresetSpec(mode: .object, quality: .standard)
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
                preset: PresetSpec(mode: .object, quality: .standard),
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
            preset: PresetSpec(mode: .object, quality: .standard),
            notes: "secret location: 47.6,-122.3"
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        XCTAssertFalse(bundle.contains("secret location"), "Notes must not leak into the default diagnostic bundle.")
        XCTAssertFalse(bundle.contains("## Notes"))
    }

    func testMachineReadableJsonContainsPresetAndStageTimings() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "MachineDetailed",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .room, quality: .ultra),
            reconstruction: ReconstructionSummary(
                mapper: "vggt",
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
        let preset = parsed?["preset"] as? [String: Any]
        XCTAssertEqual(preset?["mode"] as? String, "room")
        XCTAssertEqual(preset?["quality"] as? String, "ultra")
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
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .sfmMapping, attempt: 1, lastError: "mapper exploded", resumeToken: nil),
            reconstruction: ReconstructionSummary(
                mapper: "global_mapper",
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
            mapper: "vggt",
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
                preset: PresetSpec(mode: .object, quality: .standard),
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
        XCTAssertNotNil(parsed?["projectId"])
        XCTAssertNotNil(parsed?["reconstruction"])
        XCTAssertEqual(
            parsed?["schemaVersion"] as? Int,
            ProjectDiagnosticBundle.machineReadableSchemaVersion,
            "JSON payload must carry the current schema version so downstream consumers can detect format changes."
        )
    }

    func testMachineReadableJsonMasksLegacyUnreliableReprojectionWithoutMutatingProject() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let legacyReconstruction = ReconstructionSummary(
            mapper: "global_mapper",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            registeredImages: 18,
            totalImages: 20,
            meanReprojectionError: 0.0003
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "LegacyGlobalMapper",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .standard),
                reconstruction: legacyReconstruction
            ),
            to: paths.metadataURL
        )

        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root))
        let parsed = try machineReadablePayload(from: bundle)
        let reconstruction = try XCTUnwrap(parsed["reconstruction"] as? [String: Any])
        XCTAssertNil(reconstruction["meanReprojectionError"])

        let persisted = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(persisted.reconstruction?.meanReprojectionError, 0.0003)
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
                preset: PresetSpec(mode: .object, quality: .standard),
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

    func testNotesAreIncludedOnlyWhenOptedIn() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "WithNotes",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            notes: "sunset capture"
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let bundle = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: root, includeNotes: true))
        XCTAssertTrue(bundle.contains("## Notes"))
        XCTAssertTrue(bundle.contains("sunset capture"))
    }

    func testHomePathSanitizerReplacesHome() {
        let sanitizer = HomePathSanitizer(homePath: "/Users/example")
        XCTAssertEqual(sanitizer.sanitize("/Users/example/Documents/foo"), "~/Documents/foo")
        XCTAssertEqual(sanitizer.sanitize("/var/tmp/x"), "/var/tmp/x")
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
