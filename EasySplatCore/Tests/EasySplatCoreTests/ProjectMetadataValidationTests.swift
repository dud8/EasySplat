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
        XCTAssertEqual(ProjectMetadataStore.supportedFormatVersion, 33)
        // Format 31 is still readable (dataset-input migration); the retired
        // generation starts below the accepted floor.
        let retiredFormatVersion = (ProjectMetadataStore.acceptedFormatVersions.min() ?? 31) - 1

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

    func testCurrentFormatRoundTripsPendingPublicationIdentityForUnfinishedAttempt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let publicationID = UUID(uuidString: "5D173430-D3C9-47EC-B88E-F4AC706E3ADF")!
        let metadata = ProjectMetadata(
            title: "Pending publication",
            input: .video(files: []),
            state: PipelineState(stage: .exportSplat, lastError: nil),
            lastRunStartedAt: Date(timeIntervalSince1970: 1_725_000_000),
            pendingPublicationID: publicationID
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let firstBytes = try Data(contentsOf: url)
        let loaded = try ProjectMetadataStore.load(from: url)
        try ProjectMetadataStore.save(loaded, to: url)

        XCTAssertEqual(loaded.pendingPublicationID, publicationID)
        XCTAssertEqual(try Data(contentsOf: url), firstBytes)
    }

    func testSaveRejectsPendingPublicationIdentityForSuccessfulCompletion() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let publicationID = UUID(uuidString: "5D173430-D3C9-47EC-B88E-F4AC706E3ADF")!
        let metadata = ProjectMetadata(
            title: "Completed publication",
            input: .video(files: []),
            state: PipelineState(stage: .done, lastError: nil),
            pendingPublicationID: publicationID
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidPendingPublicationID = error else {
                return XCTFail("Expected invalid pending publication identity, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDoneRetrainAttemptsRetainPendingPublicationIdentity() throws {
        let publicationID = UUID(uuidString: "5D173430-D3C9-47EC-B88E-F4AC706E3ADF")!
        let cases: [(name: String, state: PipelineState, lastRunStartedAt: Date?)] = [
            (
                name: "interrupted",
                state: PipelineState(stage: .done, lastError: nil),
                lastRunStartedAt: Date(timeIntervalSince1970: 1_725_000_000)
            ),
            (
                name: "failed",
                state: PipelineState(stage: .done, lastError: "Publication failed."),
                lastRunStartedAt: nil
            ),
        ]

        for testCase in cases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("project.json")
            let metadata = ProjectMetadata(
                title: "\(testCase.name.capitalized) retrain",
                input: .video(files: []),
                state: testCase.state,
                lastRunStartedAt: testCase.lastRunStartedAt,
                pendingPublicationID: publicationID
            )

            try ProjectMetadataStore.save(metadata, to: url)
            let firstBytes = try Data(contentsOf: url)
            let loaded = try ProjectMetadataStore.load(from: url)
            XCTAssertEqual(
                loaded.pendingPublicationID,
                publicationID,
                "\(testCase.name) retrain lost its retry publication identity"
            )

            try ProjectMetadataStore.save(loaded, to: url)
            XCTAssertEqual(
                try Data(contentsOf: url),
                firstBytes,
                "\(testCase.name) retrain did not round-trip deterministically"
            )
        }
    }

    func testLoadAndSaveRejectAllZeroPendingPublicationIdentity() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "Invalid publication",
            input: .video(files: []),
            state: PipelineState(stage: .done, lastError: nil),
            lastRunStartedAt: Date(timeIntervalSince1970: 1_725_000_000),
            pendingPublicationID: UUID(
                uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            )
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidPendingPublicationID = error else {
                return XCTFail("Expected invalid pending publication identity, got \(error)")
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url, options: .atomic)
        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidPendingPublicationID = error else {
                return XCTFail("Expected invalid pending publication identity, got \(error)")
            }
        }
    }

    func testLoadAndSaveRejectAllZeroProjectIdentity() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            title: "Invalid project identity",
            input: .video(files: [])
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Project metadata contains an invalid project identity."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url, options: .atomic)
        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Project metadata contains an invalid project identity."
            )
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
