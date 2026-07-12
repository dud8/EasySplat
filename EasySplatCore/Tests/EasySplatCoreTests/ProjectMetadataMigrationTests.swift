import XCTest
@testable import EasySplatCore

final class ProjectMetadataMigrationTests: XCTestCase {
    func testLoadMigratesLiteralV1ObjectDraftAndPreservesLegacyFields() throws {
        let fixture = try writeFixture(Self.objectDraftFixture)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let loaded = try ProjectMetadataStore.load(from: fixture.url)

        XCTAssertEqual(loaded.formatVersion, 2)
        XCTAssertEqual(loaded.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(loaded.title, "Legacy object")
        XCTAssertEqual(loaded.createdAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(loaded.input.photosFolder, "/tmp/photos")
        XCTAssertEqual(loaded.preset.mode, .object)
        XCTAssertEqual(loaded.preset.quality, .draft)
        XCTAssertEqual(loaded.state.stage, .trainSplat)
        XCTAssertEqual(loaded.outputs?.splatPlyPath, "Output/legacy.ply")
        XCTAssertEqual(loaded.outputs?.colmapModelPath, "SfM/colmap/sparse/0")
        XCTAssertEqual(loaded.checkpoint?.stage, .trainSplat)
        XCTAssertEqual(loaded.checkpoint?.message, "training")
        XCTAssertEqual(loaded.completedSfmMapping?.mapper, "colmap")
        XCTAssertEqual(loaded.completedSfmMapping?.sparsePath, "SfM/colmap/sparse/0")
        XCTAssertEqual(loaded.completedSfmMapping?.registeredImages, 19)
        XCTAssertEqual(loaded.recoveryPromptSuppressed, true)
        XCTAssertEqual(loaded.lastRunStartedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(loaded.shareMetrics?.shareClickedCount, 3)
        XCTAssertEqual(loaded.shareMetrics?.shareCompletedCount, 2)
        XCTAssertEqual(loaded.shareMetrics?.lastShareService, "AirDrop")
        XCTAssertEqual(loaded.autoTune?.tier, "High")
        XCTAssertEqual(loaded.autoTune?.memoryGB, 48)
        XCTAssertEqual(loaded.stageTimings?.first?.stage, .sfmMapping)
        XCTAssertEqual(loaded.stageTimings?.first?.durationSeconds, 12.5)
        XCTAssertEqual(loaded.notes, "Keep this note")
        XCTAssertEqual(loaded.lastOpenedAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(loaded.lastFailureAt, Date(timeIntervalSince1970: 40))
        XCTAssertEqual(
            loaded.requestedRunOptions,
            RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        XCTAssertNil(loaded.resolvedRunPlan)
        XCTAssertNil(loaded.geometryArtifact)
        XCTAssertNil(loaded.trainingArtifact)
    }

    func testLoadMigratesLiteralV1RoomUltra() throws {
        let fixture = try writeFixture(Self.roomUltraFixture)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let loaded = try ProjectMetadataStore.load(from: fixture.url)

        XCTAssertEqual(loaded.formatVersion, 2)
        XCTAssertEqual(
            loaded.requestedRunOptions,
            RequestedRunOptions(capturePath: .walkthrough, detailProfile: .highDetail)
        )
    }

    func testLegacyBrushCheckpointDetailsDecodeAsSplatAndEncodeWithoutBrushName() throws {
        let legacy = Data(#"{"trainBrush":{"_0":{"latestExportStep":5000,"latestExportPath":"Training/export_05000.ply","progressStep":5200,"progressTotal":40000,"stepsPerSecond":3.5,"resumeSnapshotPath":"Training/latest_snapshot.ply","trainingBackend":"brush"}}}"#.utf8)

        let decoded = try JSONDecoder().decode(PipelineCheckpointDetails.self, from: legacy)

        guard case .trainSplat(let details) = decoded else {
            return XCTFail("Expected legacy Brush details to migrate to trainSplat")
        }
        XCTAssertEqual(details.progressStep, 5_200)
        XCTAssertEqual(details.progressTotal, 40_000)
        XCTAssertEqual(details.trainingBackend, .brush)
        let encoded = try JSONEncoder().encode(decoded)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("trainSplat"))
        XCTAssertFalse(text.contains("trainBrush"))
    }

    func testLoadingV1DoesNotRewriteBytesUntilNormalSave() throws {
        let original = Data(Self.objectDraftFixture.utf8)
        let fixture = try writeFixture(Self.objectDraftFixture)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let loaded = try ProjectMetadataStore.load(from: fixture.url)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)

        try ProjectMetadataStore.save(loaded, to: fixture.url)

        let saved = try Data(contentsOf: fixture.url)
        XCTAssertNotEqual(saved, original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        let options = try XCTUnwrap(object["requestedRunOptions"] as? [String: Any])
        XCTAssertEqual(options["capturePath"] as? String, "orbit")
        XCTAssertEqual(options["detailProfile"] as? String, "fast")
        XCTAssertEqual(options["cameraGrouping"] as? String, "automatic")
        XCTAssertEqual(options["lensProjection"] as? String, "automatic")
        XCTAssertEqual(options["inputOrdering"] as? String, "automatic")
        XCTAssertEqual(options["resourcePolicy"] as? String, "automatic")
        XCTAssertEqual(options["photoSelection"] as? String, "automatic")
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["stage"] as? String, "trainSplat")
        let checkpoint = try XCTUnwrap(object["checkpoint"] as? [String: Any])
        XCTAssertEqual(checkpoint["stage"] as? String, "trainSplat")
        let outputs = try XCTUnwrap(object["outputs"] as? [String: Any])
        XCTAssertEqual(outputs["splatPlyPath"] as? String, "Output/legacy.ply")
        XCTAssertEqual(outputs["colmapModelPath"] as? String, "SfM/colmap/sparse/0")
        XCTAssertEqual(object["notes"] as? String, "Keep this note")
        XCTAssertNil(object["shareMetrics"])
        XCTAssertNil(object["autoTune"])
        XCTAssertNil(object["lastOpenedAt"])
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("trainBrush"))

        let reloaded = try ProjectMetadataStore.load(from: fixture.url)
        XCTAssertEqual(reloaded.outputs?.splatPlyPath, "Output/legacy.ply")
        XCTAssertEqual(reloaded.outputs?.colmapModelPath, "SfM/colmap/sparse/0")
        XCTAssertEqual(reloaded.notes, "Keep this note")
        XCTAssertNil(reloaded.shareMetrics)
        XCTAssertNil(reloaded.autoTune)
        XCTAssertNil(reloaded.lastOpenedAt)
    }

    func testLoadRejectsAbsoluteGeometryArtifactPathWithSpecificError() throws {
        let metadata = makeMetadata(geometry: makeGeometryArtifact(canonicalModelPath: "/tmp/model"))
        let fixture = try writeMetadataWithoutStoreValidation(metadata)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: fixture.url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidArtifactPath(let field, let path) = error else {
                return XCTFail("Expected invalidArtifactPath, got \(error)")
            }
            XCTAssertEqual(field, "geometryArtifact.canonicalModelPath")
            XCTAssertEqual(path, "/tmp/model")
        }
    }

    func testLoadRejectsTraversalTrainingArtifactPathWithSpecificError() throws {
        let metadata = makeMetadata(
            training: makeTrainingArtifact(checkpointPath: "../outside.ckpt")
        )
        let fixture = try writeMetadataWithoutStoreValidation(metadata)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: fixture.url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidArtifactPath(let field, let path) = error else {
                return XCTFail("Expected invalidArtifactPath, got \(error)")
            }
            XCTAssertEqual(field, "trainingArtifact.checkpointPath")
            XCTAssertEqual(path, "../outside.ckpt")
        }
    }

    private func makeMetadata(
        geometry: GeometryArtifact = makeGeometryArtifact(),
        training: TrainingArtifact = makeTrainingArtifact()
    ) -> ProjectMetadata {
        ProjectMetadata(
            title: "Artifact paths",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            geometryArtifact: geometry,
            trainingArtifact: training
        )
    }

    private func writeFixture(_ json: String) throws -> (root: URL, url: URL) {
        let root = try TestFileBuilder.makeTempDir()
        let url = root.appendingPathComponent("project.json")
        try Data(json.utf8).write(to: url)
        return (root, url)
    }

    private func writeMetadataWithoutStoreValidation(
        _ metadata: ProjectMetadata
    ) throws -> (root: URL, url: URL) {
        let root = try TestFileBuilder.makeTempDir()
        let url = root.appendingPathComponent("project.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url)
        return (root, url)
    }

    private static let objectDraftFixture = """
    {
      "formatVersion": 1,
      "id": "11111111-1111-1111-1111-111111111111",
      "createdAt": "1970-01-01T00:00:00Z",
      "title": "Legacy object",
      "input": {"photos": {"folder": "/tmp/photos"}},
      "preset": {"mode": "object", "quality": "draft"},
      "state": {"stage": "trainBrush", "attempt": 1, "lastError": null, "resumeToken": "resume"},
      "outputs": {"splatPlyPath": "Output/legacy.ply", "colmapModelPath": "SfM/colmap/sparse/0"},
      "checkpoint": {
        "stage": "trainBrush",
        "updatedAt": "1970-01-01T00:00:20Z",
        "progressFraction": 0.4,
        "message": "training"
      },
      "completedSfmMapping": {
        "mapper": "colmap",
        "sparsePath": "SfM/colmap/sparse/0",
        "registeredImages": 19
      },
      "recoveryPromptSuppressed": true,
      "lastRunStartedAt": "1970-01-01T00:00:10Z",
      "shareMetrics": {
        "shareClickedCount": 3,
        "shareCompletedCount": 2,
        "lastShareService": "AirDrop",
        "lastSharedAt": "1970-01-01T00:00:25Z"
      },
      "reconstruction": {
        "mapper": "colmap",
        "capturedAt": "1970-01-01T00:00:21Z",
        "registeredImages": 19,
        "totalImages": 20,
        "meanReprojectionError": 0.7,
        "pointCount": 120,
        "observationCount": 480,
        "meanTrackLength": 4
      },
      "stageTimings": [
        {"stage": "sfmMapping", "startedAt": "1970-01-01T00:00:05Z", "durationSeconds": 12.5}
      ],
      "autoTune": {
        "tier": "High",
        "memoryGB": 48,
        "cpuCount": 16,
        "gpuWorkingSetGB": 32,
        "mapAnythingResolution": 518,
        "mapAnythingDirectViewLimit": 8,
        "mapAnythingAnchorMaxViews": 64,
        "mapAnythingWindowSize": 8,
        "mapAnythingWindowOverlap": 2,
        "vggtImageLoadResolution": 1280,
        "vggtFixedResolution": 518,
        "vggtMaxPoints": 150000,
        "vggtAllowed": true,
        "colmapMaxNumFeatures": 10000,
        "colmapMaxNumMatches": 10000,
        "colmapSequentialOverlap": 12,
        "colmapExhaustiveBlockSize": 25,
        "threadCap": 8,
        "colmapMaxImageSizeCap": 2048,
        "capturedAt": "1970-01-01T00:00:15Z"
      },
      "notes": "Keep this note",
      "lastOpenedAt": "1970-01-01T00:00:30Z",
      "lastFailureAt": "1970-01-01T00:00:40Z"
    }
    """

    private static let roomUltraFixture = """
    {
      "formatVersion": 1,
      "id": "22222222-2222-2222-2222-222222222222",
      "createdAt": "1970-01-01T00:00:00Z",
      "title": "Legacy room",
      "input": {"photos": {"folder": "/tmp/room"}},
      "preset": {"mode": "room", "quality": "ultra"},
      "state": {"stage": "importInput", "attempt": 0, "lastError": null, "resumeToken": null}
    }
    """
}
