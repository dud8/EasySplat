import XCTest
@testable import EasySplatCore

final class ProjectMetadataValidationTests: XCTestCase {
    func testSnapshotRejectsLifecycleClaimWhenGeometrySidecarIsMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Missing geometry",
                input: .video(files: []),
                state: PipelineState(stage: .sfmMapping, lastError: nil)
            ),
            to: paths.metadataURL
        )

        XCTAssertThrowsError(
            try ProjectArtifactSnapshotStore.load(projectURL: root)
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactSnapshotError,
                .geometryRequiredByLifecycle
            )
        }
    }

    func testLoadRejectsUnknownCurrentFormatFields() throws {
        let retiredFields = [
            "preset",
            "completedSfmMapping",
            "shareMetrics",
            "autoTune",
            "outputs",
            "reconstruction",
            "geometryArtifact",
            "trainingArtifact",
            "futurePayload",
        ]
        for field in retiredFields {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("project.json")
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Strict schema", input: .video(files: [])),
                to: url
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
                    as? [String: Any]
            )
            object[field] = ["ignored": true]
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            XCTAssertThrowsError(
                try ProjectMetadataStore.load(from: url),
                "Current-format metadata must reject unknown field \(field)"
            )
        }
    }

    func testLoadRejectsPreviousFormatBeforeDecodingCanonicalGeometryState() throws {
        XCTAssertEqual(ProjectMetadataStore.supportedFormatVersion, 31)
        let retiredFormatVersion = ProjectMetadataStore.supportedFormatVersion - 1

        let metadata = makeMetadata()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(metadata)) as? [String: Any]
        )
        object["formatVersion"] = retiredFormatVersion
        object.removeValue(forKey: "viewerPreferences")
        object["geometryArtifact"] = ["retired": true]
        object["trainingArtifact"] = ["retired": true]

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

    func testSaveRejectsAbsoluteCheckpointArtifactPath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "Unsafe checkpoint",
            input: .photos(folder: "Originals/Photos"),
            photoInputReceipts: [makePhotoInputReceipt()],
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

    private func makeMetadata() -> ProjectMetadata {
        ProjectMetadata(
            title: "Artifact paths",
            input: .photos(folder: "Originals/Photos"),
            photoInputReceipts: [makePhotoInputReceipt()],
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
    }

    private func makePhotoInputReceipt() -> PhotoInputReceipt {
        PhotoInputReceipt(
            projectRelativePath: "Originals/Photos/photo-0000.jpg",
            safeDisplayName: "source.jpg",
            byteCount: 1,
            sha256: String(repeating: "a", count: 64),
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: 1,
            typeIdentifier: "public.jpeg",
            analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                sourceSHA256: String(repeating: "a", count: 64)
            ),
            retainedRank: 0
        )
    }

}
