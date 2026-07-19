#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapFeatureEvidenceStoreTests: XCTestCase {
    func testSharedFisheyeEvidenceVerifiesExactCameraSeedSemantics() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        let receipt = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 408, height: 408)
        )
        let parameterHex = try XCTUnwrap(receipt.littleEndianParameterData)
            .map { String(format: "%02x", $0) }
            .joined()
        let canonicalCamera = """
            UPDATE cameras SET model = 5, width = 408, height = 408,
                params = X'\(parameterHex)', prior_focal_length = 1
                WHERE camera_id = 1;
            """
        try execute(canonicalCamera, at: fixture.paths.colmapDatabaseURL)

        func saveEvidence() throws {
            try ColmapFeatureEvidenceStore.save(
                ColmapFeatureEvidence(
                    selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                        orderedImageNames: names,
                        projectPaths: fixture.paths
                    ),
                    imageNames: names,
                    featureDatabaseDigest: try ColmapDatabaseDigester
                        .digests(at: fixture.paths.colmapDatabaseURL).feature,
                    cameraGroupingReceipt: .fixture(
                        mode: .allSelectedImagesShared,
                        imageCount: names.count
                    ),
                    cameraInitializationReceipt: receipt
                ),
                to: fixture.paths.colmapFeatureEvidenceURL,
                projectPaths: fixture.paths
            )
        }

        func verify() throws {
            _ = try ColmapFeatureEvidenceStore.loadVerified(
                from: fixture.paths.colmapFeatureEvidenceURL,
                expectedImageNames: names,
                expectedCameraEvidence: cameraEvidence(for: names),
                expectedCameraGroupingMode: .allSelectedImagesShared,
                expectedCameraInitializationReceipt: receipt,
                databaseURL: fixture.paths.colmapDatabaseURL,
                projectPaths: fixture.paths
            )
        }

        try saveEvidence()
        XCTAssertNoThrow(try verify())

        let corruptions = [
            "UPDATE cameras SET model = 4 WHERE camera_id = 1;",
            "UPDATE cameras SET width = 409 WHERE camera_id = 1;",
            "UPDATE cameras SET params = zeroblob(64) WHERE camera_id = 1;",
            "UPDATE cameras SET prior_focal_length = 0 WHERE camera_id = 1;",
        ]
        for corruption in corruptions {
            try execute(corruption, at: fixture.paths.colmapDatabaseURL)
            try saveEvidence()
            XCTAssertThrowsError(try verify(), "Expected rejection for \(corruption)")
            try execute(canonicalCamera, at: fixture.paths.colmapDatabaseURL)
        }
    }

    func testSharedFisheyeEvidenceRejectsCameraMutationAfterDigestInSameSnapshot() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        let receipt = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 408, height: 408)
        )
        let parameterHex = try XCTUnwrap(receipt.littleEndianParameterData)
            .map { String(format: "%02x", $0) }
            .joined()
        try execute(
            "UPDATE cameras SET model=5,width=408,height=408,params=X'\(parameterHex)',prior_focal_length=1 WHERE camera_id=1;",
            at: fixture.paths.colmapDatabaseURL
        )
        try ColmapFeatureEvidenceStore.save(
            ColmapFeatureEvidence(
                selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                    orderedImageNames: names,
                    projectPaths: fixture.paths
                ),
                imageNames: names,
                featureDatabaseDigest: try ColmapDatabaseDigester
                    .digests(at: fixture.paths.colmapDatabaseURL).feature,
                cameraGroupingReceipt: .fixture(
                    mode: .allSelectedImagesShared,
                    imageCount: names.count
                ),
                cameraInitializationReceipt: receipt
            ),
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.paths.colmapDatabaseURL.path, &writer), SQLITE_OK)
        let openedWriter = try XCTUnwrap(writer)
        defer { sqlite3_close(openedWriter) }
        XCTAssertEqual(
            sqlite3_exec(openedWriter, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil),
            SQLITE_OK
        )

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerifiedForTesting(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence(for: names),
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: receipt,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ) { checkpoint in
            guard checkpoint == .afterDigestVerification else { return }
            XCTAssertEqual(
                sqlite3_exec(
                    openedWriter,
                    "UPDATE cameras SET prior_focal_length=0 WHERE camera_id=1;",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
        })
    }

    func testVerifiedEvidenceRejectsIdentityDigestAndGroupingFromDifferentSnapshots() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.paths.colmapDatabaseURL.path, &writer), SQLITE_OK)
        let openedWriter = try XCTUnwrap(writer)
        defer { sqlite3_close(openedWriter) }
        XCTAssertEqual(
            sqlite3_exec(
                openedWriter,
                "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        let stateB = """
            UPDATE images SET name = 'temporary.jpg' WHERE image_id = 1;
            UPDATE images SET name = 'a.jpg' WHERE image_id = 2;
            UPDATE images SET name = 'b.jpg' WHERE image_id = 1;
            UPDATE descriptors SET data = X'09' WHERE image_id = 1;
            """
        let stateC = """
            UPDATE images SET name = 'temporary.jpg' WHERE image_id = 1;
            UPDATE images SET name = 'b.jpg' WHERE image_id = 2;
            UPDATE images SET name = 'a.jpg' WHERE image_id = 1;
            UPDATE descriptors SET data = X'01' WHERE image_id = 1;
            """
        XCTAssertEqual(sqlite3_exec(openedWriter, stateB, nil, nil, nil), SQLITE_OK)
        let stateBDigest = try ColmapDatabaseDigester
            .digests(at: fixture.paths.colmapDatabaseURL).feature
        XCTAssertEqual(sqlite3_exec(openedWriter, stateC, nil, nil, nil), SQLITE_OK)
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: names,
                projectPaths: fixture.paths
            ),
            imageNames: names,
            featureDatabaseDigest: stateBDigest,
            cameraGroupingReceipt: .fixture(
                mode: .allSelectedImagesShared,
                imageCount: names.count
            ),
            cameraInitializationReceipt: .automaticSharedSimpleRadial
        )
        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        var checkpoints: [ColmapFeatureEvidenceDatabaseVerificationCheckpoint] = []

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerifiedForTesting(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence(for: names),
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ) { checkpoint in
            checkpoints.append(checkpoint)
            let sql = checkpoint == .afterIdentityVerification ? stateB : stateC
            XCTAssertEqual(sqlite3_exec(openedWriter, sql, nil, nil, nil), SQLITE_OK)
        })
        XCTAssertEqual(
            checkpoints,
            [.afterIdentityVerification, .afterDigestVerification]
        )
    }

    func testVerifiedEvidenceRejectsWALCommitAfterIdentityCheck() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]

        var writer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(fixture.paths.colmapDatabaseURL.path, &writer),
            SQLITE_OK
        )
        let openedWriter = try XCTUnwrap(writer)
        defer { sqlite3_close(openedWriter) }
        XCTAssertEqual(
            sqlite3_exec(
                openedWriter,
                "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        let evidence = try saveCurrentEvidence(
            imageNames: names,
            projectPaths: fixture.paths
        )
        var committedMutation = false

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerifiedForTesting(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence(for: names),
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ) { checkpoint in
            guard checkpoint == .afterIdentityVerification else { return }
            XCTAssertEqual(
                sqlite3_exec(
                    openedWriter,
                    "UPDATE descriptors SET data = X'09' WHERE image_id = 1;",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
            committedMutation = true
        }) { error in
            XCTAssertEqual(
                error as? ColmapFeatureDatabaseIdentityError,
                .unsafeDatabase
            )
        }

        XCTAssertTrue(committedMutation)
        XCTAssertNotEqual(
            try ColmapDatabaseDigester.digests(at: fixture.paths.colmapDatabaseURL).feature,
            evidence.featureDatabaseDigest
        )
    }

    func testVerifiedEvidenceRollbackAfterCheckpointThrowReleasesWriter() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        _ = try saveCurrentEvidence(imageNames: names, projectPaths: fixture.paths)
        struct CheckpointFailure: Error {}

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerifiedForTesting(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence(for: names),
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ) { checkpoint in
            if checkpoint == .afterIdentityVerification {
                throw CheckpointFailure()
            }
        }) { error in
            XCTAssertTrue(error is CheckpointFailure)
        }

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.paths.colmapDatabaseURL.path, &writer), SQLITE_OK)
        let openedWriter = try XCTUnwrap(writer)
        defer { sqlite3_close(openedWriter) }
        XCTAssertEqual(sqlite3_busy_timeout(openedWriter, 100), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                openedWriter,
                "UPDATE descriptors SET data = X'09' WHERE image_id = 1;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
    }

    func testStoreAcceptsCanonicalMissingPathThroughPrivateTemporaryAlias() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/EasySplat-FeatureEvidence-\(UUID().uuidString).easysplatproj",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg"],
            featureDatabaseDigest: String(repeating: "b", count: 64),
            cameraGroupingReceipt: .fixture(
                mode: .allSelectedImagesShared,
                imageCount: 2
            ),
            cameraInitializationReceipt: .automaticSharedSimpleRadial
        )

        XCTAssertNoThrow(try ColmapFeatureEvidenceStore.save(
            evidence,
            to: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        ))
    }

    func testStoreRejectsCameraGroupingReceiptThatDoesNotCoverSelectedImages() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/EasySplat-FeatureEvidence-\(UUID().uuidString).easysplatproj",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg"],
            featureDatabaseDigest: String(repeating: "b", count: 64),
            cameraGroupingReceipt: ColmapCameraGroupingReceipt(
                mode: .allSelectedImagesShared,
                cameraCountBefore: 2,
                cameraCountAfter: 1,
                groupedVideoSourceCount: 0,
                groups: [
                    ColmapCameraGroupReceipt(
                        sourceGroupID: "all-selected-images",
                        memberCount: 1,
                        canonicalCameraID: 1
                    )
                ]
            ),
            cameraInitializationReceipt: .automaticSharedSimpleRadial
        )

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.save(
            evidence,
            to: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        ))
    }

    func testVerifiedEvidenceRejectsChangedFrameOrDescriptorBytes() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        let cameraEvidence = names.map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0,
                sourceGroupID: "photos",
                isVideo: false
            )
        }
        let selectedDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: names,
            projectPaths: fixture.paths
        )
        let featureDigest = try ColmapDatabaseDigester
            .digests(at: fixture.paths.colmapDatabaseURL).feature
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: selectedDigest,
            imageNames: names,
            featureDatabaseDigest: featureDigest,
            cameraGroupingReceipt: .fixture(
                mode: .allSelectedImagesShared,
                imageCount: names.count
            ),
            cameraInitializationReceipt: .automaticSharedSimpleRadial
        )
        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )

        XCTAssertEqual(
            try ColmapFeatureEvidenceStore.loadVerified(
                from: fixture.paths.colmapFeatureEvidenceURL,
                expectedImageNames: names,
                expectedCameraEvidence: cameraEvidence,
                expectedCameraGroupingMode: .allSelectedImagesShared,
                expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
                databaseURL: fixture.paths.colmapDatabaseURL,
                projectPaths: fixture.paths
            ),
            evidence
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerified(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence,
            expectedCameraGroupingMode: .preserveExisting,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ))

        try Data("changed-a".utf8).write(
            to: fixture.paths.framesSelectedURL.appendingPathComponent("a.jpg"),
            options: [.atomic]
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerified(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence,
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ))

        try Data("a".utf8).write(
            to: fixture.paths.framesSelectedURL.appendingPathComponent("a.jpg"),
            options: [.atomic]
        )
        try execute(
            "UPDATE descriptors SET data = X'09' WHERE image_id = 1;",
            at: fixture.paths.colmapDatabaseURL
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerified(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence,
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ))
    }

    func testVerifiedCameraGroupingEvidenceSurvivesMovingProjectBundle() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        let cameraEvidence = names.map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0,
                sourceGroupID: "photos",
                isVideo: false
            )
        }
        let selectedDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: names,
            projectPaths: fixture.paths
        )
        let featureDigest = try ColmapDatabaseDigester
            .digests(at: fixture.paths.colmapDatabaseURL).feature
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: selectedDigest,
            imageNames: names,
            featureDatabaseDigest: featureDigest,
            cameraGroupingReceipt: .fixture(
                mode: .allSelectedImagesShared,
                imageCount: names.count
            ),
            cameraInitializationReceipt: .automaticSharedSimpleRadial
        )
        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )

        let movedRoot = fixture.root.appendingPathComponent(
            "Moved.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.paths.root, to: movedRoot)
        let movedPaths = ProjectPaths(root: movedRoot)

        XCTAssertEqual(
            try ColmapFeatureEvidenceStore.loadVerified(
                from: movedPaths.colmapFeatureEvidenceURL,
                expectedImageNames: names,
                expectedCameraEvidence: cameraEvidence,
                expectedCameraGroupingMode: .allSelectedImagesShared,
                expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
                databaseURL: movedPaths.colmapDatabaseURL,
                projectPaths: movedPaths
            ),
            evidence
        )
    }

    func testVerifiedEvidenceRejectsSwappedLexicalImageIDsWithoutMutatingDatabase() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        try execute(
            """
            UPDATE images SET name = 'temporary.jpg' WHERE image_id = 1;
            UPDATE images SET name = 'a.jpg' WHERE image_id = 2;
            UPDATE images SET name = 'b.jpg' WHERE image_id = 1;
            """,
            at: fixture.paths.colmapDatabaseURL
        )
        let evidence = try saveCurrentEvidence(
            imageNames: names,
            projectPaths: fixture.paths
        )
        let before = try ColmapDatabaseDigester.digests(
            at: fixture.paths.colmapDatabaseURL
        )

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerified(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence(for: names),
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        )) { error in
            guard case let .unstableImageID(imageName, expected, actual) =
                error as? ColmapFeatureDatabaseIdentityError else {
                return XCTFail("Expected deterministic image-ID rejection, got \(error)")
            }
            XCTAssertEqual(imageName, "a.jpg")
            XCTAssertEqual(expected, 1)
            XCTAssertEqual(actual, 2)
        }

        XCTAssertEqual(
            try ColmapDatabaseDigester.digests(at: fixture.paths.colmapDatabaseURL),
            before
        )
        XCTAssertEqual(evidence.imageNames, names)
    }

    func testVerifiedEvidenceRejectsSwappedFrameRelationshipsWithoutMutatingDatabase() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        try execute(
            """
            UPDATE frame_data SET frame_id = 3 WHERE data_id = 1;
            UPDATE frame_data SET frame_id = 1 WHERE data_id = 2;
            UPDATE frame_data SET frame_id = 2 WHERE data_id = 1;
            """,
            at: fixture.paths.colmapDatabaseURL
        )
        _ = try saveCurrentEvidence(
            imageNames: names,
            projectPaths: fixture.paths
        )
        let before = try ColmapDatabaseDigester.digests(
            at: fixture.paths.colmapDatabaseURL
        )

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerified(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            expectedCameraEvidence: cameraEvidence(for: names),
            expectedCameraGroupingMode: .allSelectedImagesShared,
            expectedCameraInitializationReceipt: .automaticSharedSimpleRadial,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        )) { error in
            guard case let .unstableFrameID(imageName, expected) =
                error as? ColmapFeatureDatabaseIdentityError else {
                return XCTFail("Expected deterministic frame-ID rejection, got \(error)")
            }
            XCTAssertEqual(imageName, "a.jpg")
            XCTAssertEqual(expected, 1)
        }

        XCTAssertEqual(
            try ColmapDatabaseDigester.digests(at: fixture.paths.colmapDatabaseURL),
            before
        )
    }

    func testStoreRejectsNoncanonicalAndSymlinkedEvidencePaths() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg"],
            featureDatabaseDigest: String(repeating: "b", count: 64),
            cameraGroupingReceipt: .fixture(
                mode: .allSelectedImagesShared,
                imageCount: 2
            ),
            cameraInitializationReceipt: .automaticSharedSimpleRadial
        )
        let outside = fixture.paths.root.appendingPathComponent("outside.json")

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.save(
            evidence,
            to: outside,
            projectPaths: fixture.paths
        ))

        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        let externalAlias = fixture.root.appendingPathComponent("feature-evidence-alias.json")
        try FileManager.default.createSymbolicLink(
            at: externalAlias,
            withDestinationURL: fixture.paths.colmapFeatureEvidenceURL
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.save(
            evidence,
            to: externalAlias,
            projectPaths: fixture.paths
        ))
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: externalAlias.path)
        )

        try Data("{}".utf8).write(to: outside)
        try FileManager.default.removeItem(at: fixture.paths.colmapFeatureEvidenceURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.colmapFeatureEvidenceURL,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.load(
            from: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    private func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        try Data("a".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent("a.jpg")
        )
        try Data("b".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent("b.jpg")
        )
        try execute(
            """
            CREATE TABLE cameras(
                camera_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                model INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                params BLOB,
                prior_focal_length INTEGER NOT NULL
            );
            CREATE TABLE images(
                image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL UNIQUE,
                camera_id INTEGER NOT NULL,
                FOREIGN KEY(camera_id) REFERENCES cameras(camera_id)
            );
            CREATE UNIQUE INDEX index_name ON images(name);
            CREATE TABLE rigs(
                rig_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ref_sensor_id INTEGER NOT NULL,
                ref_sensor_type INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX rig_ref_sensor_assignment
                ON rigs(ref_sensor_id, ref_sensor_type);
            CREATE TABLE rig_sensors(
                rig_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL,
                sensor_from_rig BLOB,
                FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX rig_sensor_assignment
                ON rig_sensors(sensor_id, sensor_type);
            CREATE TABLE frames(
                frame_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                rig_id INTEGER NOT NULL,
                FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
            );
            CREATE TABLE frame_data(
                frame_id INTEGER NOT NULL,
                data_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL,
                FOREIGN KEY(frame_id) REFERENCES frames(frame_id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX frame_sensor_assignment
                ON frame_data(data_id, sensor_type);
            CREATE TABLE pose_priors(
                pose_prior_id INTEGER PRIMARY KEY NOT NULL,
                corr_data_id INTEGER NOT NULL,
                corr_sensor_id INTEGER NOT NULL,
                corr_sensor_type INTEGER NOT NULL,
                position BLOB,
                position_covariance BLOB,
                gravity BLOB,
                coordinate_system INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX pose_prior_data_assignment
                ON pose_priors(corr_data_id, corr_sensor_id, corr_sensor_type);
            CREATE TABLE keypoints(
                image_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
            );
            CREATE TABLE descriptors(
                image_id INTEGER PRIMARY KEY NOT NULL,
                type INTEGER NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
            );
            CREATE TABLE matches(
                pair_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            CREATE TABLE two_view_geometries(
                pair_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                config INTEGER NOT NULL,
                F BLOB,
                E BLOB,
                H BLOB,
                qvec BLOB,
                tvec BLOB
            );
            INSERT INTO cameras VALUES (
                1, 1, 1920, 1080,
                X'0000000000408F400000000000408F40000000000000A0400000000000E08040',
                0
            );
            INSERT INTO images VALUES (1, 'a.jpg', 1), (2, 'b.jpg', 1);
            INSERT INTO rigs VALUES (1, 1, 0);
            INSERT INTO frames VALUES (1, 1), (2, 1);
            INSERT INTO frame_data VALUES (1, 1, 1, 0), (2, 2, 1, 0);
            INSERT INTO pose_priors(
                pose_prior_id,
                corr_data_id,
                corr_sensor_id,
                corr_sensor_type,
                coordinate_system
            ) VALUES (1, 1, 1, 0, 0), (2, 2, 1, 0, 0);
            INSERT INTO keypoints VALUES (1, 1, 4, X'01'), (2, 1, 4, X'02');
            INSERT INTO descriptors VALUES (1, 0, 1, 128, X'01'), (2, 0, 1, 128, X'02');
            """,
            at: paths.colmapDatabaseURL
        )
        return (root, paths)
    }

    private func cameraEvidence(
        for imageNames: [String]
    ) -> [ColmapSelectedImageCameraEvidence] {
        imageNames.map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0,
                sourceGroupID: "photos",
                isVideo: false
            )
        }
    }

    @discardableResult
    private func saveCurrentEvidence(
        imageNames: [String],
        projectPaths: ProjectPaths
    ) throws -> ColmapFeatureEvidence {
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: projectPaths
            ),
            imageNames: imageNames,
            featureDatabaseDigest: try ColmapDatabaseDigester
                .digests(at: projectPaths.colmapDatabaseURL).feature,
            cameraGroupingReceipt: .fixture(
                mode: .allSelectedImagesShared,
                imageCount: imageNames.count
            ),
            cameraInitializationReceipt: .automaticSharedSimpleRadial
        )
        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: projectPaths.colmapFeatureEvidenceURL,
            projectPaths: projectPaths
        )
        return evidence
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) }
        sqlite3_free(message)
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail ?? "SQLite failure"]
            )
        }
    }
}

private extension ColmapCameraGroupingReceipt {
    static func fixture(
        mode: ColmapCameraGroupingMode,
        imageCount: Int
    ) -> Self {
        Self(
            mode: mode,
            cameraCountBefore: imageCount,
            cameraCountAfter: mode == .allSelectedImagesShared ? 1 : imageCount,
            groupedVideoSourceCount: 0,
            groups: mode == .allSelectedImagesShared
                ? [ColmapCameraGroupReceipt(
                    sourceGroupID: "all-selected-images",
                    memberCount: imageCount,
                    canonicalCameraID: 1
                )]
                : []
        )
    }
}
#endif
