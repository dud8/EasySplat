import XCTest
@testable import EasySplatCore

final class ProjectMetadataValidationTests: XCTestCase {
    func testLoadRejectsRetiredVersionTwoBeforeDecodingItsPayload() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        try Data(#"{"formatVersion":2,"title":false}"#.utf8).write(to: url)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(2) = error else {
                return XCTFail("Expected unsupportedFormatVersion(2), got \(error)")
            }
        }
    }

    func testLoadRejectsVersionOneBeforeDecodingItsPayload() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        try Data(#"{"formatVersion":1,"title":false}"#.utf8).write(to: url)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(1) = error else {
                return XCTFail("Expected unsupportedFormatVersion(1), got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains("Update EasySplat"))
        }
    }

    func testLoadRejectsUnknownOlderSchema() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        try Data(#"{"formatVersion":0}"#.utf8).write(to: url)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(0) = error else {
                return XCTFail("Expected unsupportedFormatVersion(0), got \(error)")
            }
        }
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

    func testLoadRejectsEmbeddedRetiredGeometryArtifactSchema() throws {
        var geometry = makeGeometryArtifact()
        geometry.schemaVersion = 2
        let fixture = try writeMetadataWithoutStoreValidation(makeMetadata(geometry: geometry))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: fixture.url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedGeometryArtifactSchema(2) = error else {
                return XCTFail("Expected unsupportedGeometryArtifactSchema(2), got \(error)")
            }
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

    func testSaveRejectsAbsoluteCheckpointArtifactPath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "Unsafe checkpoint",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            checkpoint: PipelineCheckpoint(
                stage: .sfmFeatures,
                updatedAt: Date(timeIntervalSince1970: 1),
                progressFraction: 0.5,
                message: "features",
                details: .sfmFeatures(SfmFeaturesCheckpoint(
                    databasePath: root.appendingPathComponent("SfM/colmap/database.db").path,
                    imageCount: 12
                ))
            )
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidArtifactPath(let field, let path) = error else {
                return XCTFail("Expected invalidArtifactPath, got \(error)")
            }
            XCTAssertEqual(field, "checkpoint.sfmFeatures.databasePath")
            XCTAssertTrue((path as NSString).isAbsolutePath)
        }
    }

    func testSaveRejectsOutputPathOutsideItsProjectNamespace() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "Unsafe output",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            outputs: OutputSpec(
                splatPlyPath: "Training/msplat/splat.ply",
                colmapModelPath: "SfM/colmap/sparse/0"
            )
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidArtifactNamespace(let field, let path) = error else {
                return XCTFail("Expected invalidArtifactNamespace, got \(error)")
            }
            XCTAssertEqual(field, "outputs.splatPlyPath")
            XCTAssertEqual(path, "Training/msplat/splat.ply")
        }
    }

    private func makeMetadata(
        geometry: GeometryArtifact = makeGeometryArtifact(),
        training: TrainingArtifact = makeTrainingArtifact()
    ) -> ProjectMetadata {
        ProjectMetadata(
            title: "Artifact paths",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            geometryArtifact: geometry,
            trainingArtifact: training
        )
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

}
