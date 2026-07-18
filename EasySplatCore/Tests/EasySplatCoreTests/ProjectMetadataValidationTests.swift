import XCTest
@testable import EasySplatCore

final class ProjectMetadataValidationTests: XCTestCase {
    func testLoadRejectsPreviousFormatBeforeDecodingCanonicalGeometryState() throws {
        XCTAssertEqual(ProjectMetadataStore.supportedFormatVersion, 17)
        let retiredFormatVersion = ProjectMetadataStore.supportedFormatVersion - 1

        let metadata = makeMetadata()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(metadata)) as? [String: Any]
        )
        object["formatVersion"] = retiredFormatVersion
        object.removeValue(forKey: "viewerPreferences")
        var geometry = try XCTUnwrap(object["geometryArtifact"] as? [String: Any])
        var orientation = try XCTUnwrap(
            geometry["canonicalOrientation"] as? [String: Any]
        )
        orientation["isViewOnlyFlipActive"] = true
        geometry["canonicalOrientation"] = orientation
        object["geometryArtifact"] = geometry

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(let version) = error else {
                return XCTFail("Expected envelope-first unsupported format, got \(error)")
            }
            XCTAssertEqual(version, retiredFormatVersion)
        }
    }

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
        let metadata = makeMetadata(geometry: makeGeometryArtifact(sourceModelPath: "/tmp/model"))
        let fixture = try writeMetadataWithoutStoreValidation(metadata)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: fixture.url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidArtifactPath(let field, let path) = error else {
                return XCTFail("Expected invalidArtifactPath, got \(error)")
            }
            XCTAssertEqual(field, "geometryArtifact.sourceModelPath")
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

    func testSaveAcceptsRawSeedLearnedInitializerPath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        var geometry = makeGeometryArtifact(
            sourceModelPath: "SfM/colmap/sparse/0"
        )
        geometry.learnedPointInitializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: String(repeating: "a", count: 64),
            pointCount: 1
        )
        let metadata = ProjectMetadata(
            title: "Raw learned initializer",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            resolvedRunPlan: makeResolvedRunPlan(for: geometry),
            geometryArtifact: geometry
        )

        XCTAssertNoThrow(try ProjectMetadataStore.save(metadata, to: url))
    }

    func testSaveRejectsNearSeedLearnedInitializerPaths() throws {
        for path in [
            "SfM/colmap/seed/1/learned_points3D.txt",
            "SfM/colmap/seed/0/other.txt",
            "SfM/colmap/sparse/0/learned_points3D.txt",
            "SfM/colmap/sparse/1/learned_points3D.txt",
            "SfM/colmap/sparse/0/other.txt",
        ] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            var geometry = makeGeometryArtifact(
                sourceModelPath: "SfM/colmap/sparse/0"
            )
            geometry.learnedPointInitializer = LearnedPointInitializerArtifact(
                path: path,
                sha256: String(repeating: "a", count: 64),
                pointCount: 1
            )
            let metadata = ProjectMetadata(
                title: "Near-seed learned initializer",
                input: .photos(folder: "/tmp/photos"),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced
                ),
                resolvedRunPlan: makeResolvedRunPlan(for: geometry),
                geometryArtifact: geometry
            )

            XCTAssertThrowsError(
                try ProjectMetadataStore.save(
                    metadata,
                    to: root.appendingPathComponent("project.json")
                )
            ) { error in
                guard case ProjectMetadataStore.LoadError.invalidArtifactNamespace(let field, let rejectedPath) = error else {
                    return XCTFail("Expected invalidArtifactNamespace for \(path), got \(error)")
                }
                XCTAssertEqual(field, "geometryArtifact.learnedPointInitializer.path")
                XCTAssertEqual(rejectedPath, path)
            }
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
            resolvedRunPlan: makeResolvedRunPlan(for: geometry),
            geometryArtifact: geometry,
            trainingArtifact: training
        )
    }

    private func makeResolvedRunPlan(
        for geometry: GeometryArtifact
    ) -> ResolvedRunPlan {
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
        plan.geometryWorkerBudget = geometry.workerExecution.resolvedBudget
        return plan
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
