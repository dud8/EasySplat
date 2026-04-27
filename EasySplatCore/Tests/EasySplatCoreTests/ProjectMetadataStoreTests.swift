import XCTest
@testable import EasySplatCore

final class ProjectMetadataStoreTests: XCTestCase {
    func testRoundTripMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let state = PipelineState(stage: .sfmMatching, attempt: 2, lastError: "boom", resumeToken: "token")
        let output = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        let checkpoint = PipelineCheckpoint(
            stage: .trainBrush,
            updatedAt: Date(timeIntervalSince1970: 123460),
            progressFraction: 0.5,
            message: "heartbeat",
            details: .trainBrush(TrainBrushCheckpoint(
                latestExportStep: 1000,
                latestExportPath: "/tmp/export_01000.ply",
                progressStep: 1200,
                progressTotal: 40000,
                stepsPerSecond: 1.2,
                resumeSnapshotPath: "/tmp/latest_snapshot.ply"
            ))
        )
        let metadata = ProjectMetadata(
            formatVersion: 1,
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 123456),
            title: "Test",
            input: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos"),
            preset: PresetSpec(mode: .room, quality: .ultra),
            state: state,
            outputs: output,
            checkpoint: checkpoint,
            recoveryPromptSuppressed: true,
            lastRunStartedAt: Date(timeIntervalSince1970: 123499)
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.formatVersion, metadata.formatVersion)
        XCTAssertEqual(loaded.id, metadata.id)
        XCTAssertEqual(loaded.createdAt, metadata.createdAt)
        XCTAssertEqual(loaded.title, metadata.title)
        XCTAssertEqual(loaded.preset.mode, metadata.preset.mode)
        XCTAssertEqual(loaded.preset.quality, metadata.preset.quality)
        XCTAssertEqual(loaded.state.stage, metadata.state.stage)
        XCTAssertEqual(loaded.state.attempt, metadata.state.attempt)
        XCTAssertEqual(loaded.state.lastError, metadata.state.lastError)
        XCTAssertEqual(loaded.state.resumeToken, metadata.state.resumeToken)
        XCTAssertEqual(loaded.outputs?.splatPlyPath, metadata.outputs?.splatPlyPath)
        XCTAssertEqual(loaded.outputs?.colmapModelPath, metadata.outputs?.colmapModelPath)
        XCTAssertEqual(loaded.checkpoint?.stage, metadata.checkpoint?.stage)
        XCTAssertEqual(loaded.checkpoint?.message, metadata.checkpoint?.message)
        XCTAssertEqual(loaded.recoveryPromptSuppressed, true)
        XCTAssertEqual(loaded.lastRunStartedAt, Date(timeIntervalSince1970: 123499))
        if case let .trainBrush(details)? = loaded.checkpoint?.details {
            XCTAssertEqual(details.latestExportStep, 1000)
            XCTAssertEqual(details.progressTotal, 40_000)
        } else {
            XCTFail("Expected trainBrush checkpoint details")
        }
    }

    func testLoadRejectsFutureFormatVersion() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let future = """
        {
          "createdAt":"1970-01-01T00:00:00Z",
          "formatVersion":\(ProjectMetadataStore.supportedFormatVersion + 1),
          "id":"00000000-0000-0000-0000-000000000002",
          "input":{"photos":{"folder":"/tmp/photos"}},
          "preset":{"mode":"object","quality":"standard"},
          "state":{"attempt":0,"lastError":null,"resumeToken":null,"stage":"importInput"},
          "title":"Future"
        }
        """
        try future.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(let v) = error else {
                XCTFail("Expected unsupportedFormatVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
        }
    }

    /// Regression: a future EasySplat may rename or drop fields that today's strict
    /// ProjectMetadata decoder requires. The formatVersion check must fire BEFORE the
    /// strict decode, otherwise such projects throw a generic DecodingError and silently
    /// disappear from the listing instead of being surfaced as "needs app update".
    func testLoadRejectsFutureFormatVersionEvenWithMissingRequiredFields() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        // Intentionally omit `state`, `input`, `preset`, `title`, `id`, `createdAt`. Today's
        // strict decoder rejects this. The version check must still take precedence.
        let future = """
        {
          "formatVersion":\(ProjectMetadataStore.supportedFormatVersion + 1),
          "newRequiredFieldFromFuture":"hello"
        }
        """
        try future.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(let v) = error else {
                XCTFail("Expected unsupportedFormatVersion even with missing fields, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
        }
    }

    func testLoadLegacyMetadataWithoutCheckpoint() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let legacy = """
        {
          "createdAt":"1970-01-01T00:00:00Z",
          "formatVersion":1,
          "id":"00000000-0000-0000-0000-000000000001",
          "input":{"photos":{"folder":"/tmp/photos"}},
          "preset":{"mode":"object","quality":"standard"},
          "state":{"attempt":0,"lastError":null,"resumeToken":null,"stage":"importInput"},
          "title":"Legacy"
        }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try ProjectMetadataStore.load(from: url)
        XCTAssertNil(loaded.checkpoint)
        XCTAssertNil(loaded.recoveryPromptSuppressed)
        XCTAssertNil(loaded.lastRunStartedAt)
    }
}
