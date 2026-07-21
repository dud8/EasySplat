#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapCameraGroupingStoreTests: XCTestCase {
    private enum ProbeError: Error, Equatable {
        case cancelled
    }

    func testVideoSourceGroupingCoalescesTwoHundredFiftyFrameCamerasIntoFourStableGroups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let names = (0..<250).map { String(format: "frame_%04d.jpg", $0) }
        let evidence = names.enumerated().map { index, name in
            ColmapSelectedImageCameraEvidence(
                imageName: name,
                sourceGroupID: String(format: "video_%03d", index % 4),
                isVideo: true
            )
        }
        let first = directory.appendingPathComponent("first.db")
        let second = directory.appendingPathComponent("second.db")
        try makeDatabase(at: first, imageNames: names, insertionOrder: names)
        try makeDatabase(at: second, imageNames: names, insertionOrder: names.reversed())

        XCTAssertEqual(try rowCount("cameras", in: first), 250)
        XCTAssertEqual(try rowCount("cameras", in: second), 250)

        let firstReceipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: first,
            selectedImages: evidence,
            mode: .videoSourceGroups
        )
        let secondReceipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: second,
            selectedImages: Array(evidence.reversed()),
            mode: .videoSourceGroups
        )

        XCTAssertEqual(firstReceipt, secondReceipt)
        XCTAssertEqual(firstReceipt.cameraCountBefore, 250)
        XCTAssertEqual(firstReceipt.cameraCountAfter, 4)
        XCTAssertEqual(firstReceipt.groupedVideoSourceCount, 4)
        XCTAssertEqual(firstReceipt.groups.map(\.memberCount), [63, 63, 62, 62])
        XCTAssertEqual(try rowCount("cameras", in: first), 4)
        XCTAssertEqual(try rowCount("cameras", in: second), 4)
    }

    func testVideoSourceGroupingLeavesAutomaticPhotoCamerasUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("mixed.db")
        let names = [
            "clip-a-1.jpg", "clip-a-2.jpg",
            "clip-b-1.jpg", "clip-b-2.jpg",
            "photo-exif.jpg", "photo-no-exif.jpg",
        ]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names)
        let photoAssignmentsBefore = try cameraIDsByImageName(in: database)
            .filter { $0.key.hasPrefix("photo-") }
        let evidence = [
            ColmapSelectedImageCameraEvidence(
                imageName: "photo-no-exif.jpg",
                sourceGroupID: "photos",
                isVideo: false
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "clip-b-2.jpg",
                sourceGroupID: "video_001",
                isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "clip-a-2.jpg",
                sourceGroupID: "video_000",
                isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "photo-exif.jpg",
                sourceGroupID: "photos",
                isVideo: false
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "clip-a-1.jpg",
                sourceGroupID: "video_000",
                isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "clip-b-1.jpg",
                sourceGroupID: "video_001",
                isVideo: true
            ),
        ]

        let receipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: database,
            selectedImages: evidence,
            mode: .videoSourceGroups
        )

        XCTAssertEqual(receipt.cameraCountBefore, 6)
        XCTAssertEqual(receipt.cameraCountAfter, 4)
        XCTAssertEqual(receipt.groupedVideoSourceCount, 2)
        XCTAssertEqual(receipt.groups.map(\.sourceGroupID), ["video_000", "video_001"])
        XCTAssertEqual(receipt.groups.map(\.memberCount), [2, 2])
        let assignments = try cameraIDsByImageName(in: database)
        XCTAssertEqual(assignments["clip-a-1.jpg"], assignments["clip-a-2.jpg"])
        XCTAssertEqual(assignments["clip-b-1.jpg"], assignments["clip-b-2.jpg"])
        XCTAssertNotEqual(assignments["clip-a-1.jpg"], assignments["clip-b-1.jpg"])
        XCTAssertEqual(
            assignments.filter { $0.key.hasPrefix("photo-") },
            photoAssignmentsBefore
        )
    }

    func testPreserveExistingValidatesPhotosWithoutChangingCameraAssignments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("photos.db")
        let names = ["kitchen.jpg", "hallway.jpg", "front.jpg"]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names.reversed())
        let before = try ColmapDatabaseDigester.digests(at: database)
        let assignmentsBefore = try cameraIDsByImageName(in: database)
        let evidence = names.reversed().map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0,
                sourceGroupID: "photos",
                isVideo: false
            )
        }

        let receipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: database,
            selectedImages: evidence,
            mode: .preserveExisting
        )

        XCTAssertEqual(receipt.cameraCountBefore, 3)
        XCTAssertEqual(receipt.cameraCountAfter, 3)
        XCTAssertEqual(receipt.groupedVideoSourceCount, 0)
        XCTAssertEqual(receipt.groups, [])
        XCTAssertEqual(try cameraIDsByImageName(in: database), assignmentsBefore)
        XCTAssertEqual(try ColmapDatabaseDigester.digests(at: database), before)
    }

    func testVerifyBindsReceiptModeGroupsAndLiveAssignments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("verify.db")
        let names = ["a-1.jpg", "a-2.jpg", "b-1.jpg", "b-2.jpg"]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names)
        let evidence = [
            ColmapSelectedImageCameraEvidence(
                imageName: "a-1.jpg", sourceGroupID: "video_000", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "a-2.jpg", sourceGroupID: "video_000", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "b-1.jpg", sourceGroupID: "video_001", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "b-2.jpg", sourceGroupID: "video_001", isVideo: true
            ),
        ]
        let receipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: database,
            selectedImages: evidence,
            mode: .videoSourceGroups
        )

        XCTAssertEqual(
            try ColmapCameraGroupingStore.verify(
                databaseURL: database,
                selectedImages: evidence,
                expectedMode: .videoSourceGroups,
                expectedReceipt: receipt
            ),
            receipt
        )
        XCTAssertThrowsError(try ColmapCameraGroupingStore.verify(
            databaseURL: database,
            selectedImages: evidence,
            expectedMode: .allSelectedImagesShared,
            expectedReceipt: receipt
        )) { error in
            XCTAssertEqual(
                error as? ColmapCameraGroupingStoreError,
                .receiptMismatch
            )
        }

        try updateImageCamera(cameraID: 3, imageName: "a-2.jpg", in: database)
        XCTAssertThrowsError(try ColmapCameraGroupingStore.verify(
            databaseURL: database,
            selectedImages: evidence,
            expectedMode: .videoSourceGroups,
            expectedReceipt: receipt
        )) { error in
            XCTAssertEqual(
                error as? ColmapCameraGroupingStoreError,
                .invalidCameraRelation(imageName: "a-2.jpg")
            )
        }
    }

    func testAllSelectedImagesSharedReportsIncludedVideoSources() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("shared.db")
        let names = ["clip-a.jpg", "clip-b.jpg", "photo.jpg"]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names)
        let evidence = [
            ColmapSelectedImageCameraEvidence(
                imageName: "clip-b.jpg",
                sourceGroupID: "video_001",
                isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "photo.jpg",
                sourceGroupID: "photos",
                isVideo: false
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "clip-a.jpg",
                sourceGroupID: "video_000",
                isVideo: true
            ),
        ]

        let receipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: database,
            selectedImages: evidence,
            mode: .allSelectedImagesShared
        )

        XCTAssertEqual(receipt.cameraCountBefore, 3)
        XCTAssertEqual(receipt.cameraCountAfter, 1)
        XCTAssertEqual(receipt.groupedVideoSourceCount, 2)
        XCTAssertEqual(receipt.groups, [
            ColmapCameraGroupReceipt(
                sourceGroupID: "all-selected-images",
                memberCount: 3,
                canonicalCameraID: 1
            )
        ])
        XCTAssertEqual(Set(try cameraIDsByImageName(in: database).values), [1])
        XCTAssertEqual(
            try cameraRelationsByImageName(in: database),
            Dictionary(uniqueKeysWithValues: names.map { ($0, [1, 1, 1, 1, 1]) })
        )
        XCTAssertEqual(try rowCount("rigs", in: database), 1)
        XCTAssertEqual(try rowCount("rig_sensors", in: database), 0)
        XCTAssertEqual(try rowCount("frames", in: database), names.count)
    }

    func testAllSelectedImagesSharedRollsBackEveryCameraCompatibilityMismatch() throws {
        enum Mismatch: String, CaseIterable {
            case model
            case dimensions
            case parameters
            case priorFocalLength
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["first.jpg", "second.jpg"]
        let evidence = names.map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0,
                sourceGroupID: "photos",
                isVideo: false
            )
        }

        for mismatch in Mismatch.allCases {
            let database = directory.appendingPathComponent("\(mismatch.rawValue).db")
            try makeDatabase(at: database, imageNames: names, insertionOrder: names)
            switch mismatch {
            case .model:
                try updateCameraColumn("model = 2", cameraID: 2, in: database)
            case .dimensions:
                try updateCameraColumn("width = 2048", cameraID: 2, in: database)
            case .parameters:
                try updateCameraParameters(
                    cameraParameters([1001, 1000, 960, 540]),
                    cameraID: 2,
                    in: database
                )
            case .priorFocalLength:
                try updateCameraColumn("prior_focal_length = 1", cameraID: 2, in: database)
            }
            let before = try ColmapDatabaseDigester.digests(at: database)

            XCTAssertThrowsError(
                try ColmapCameraGroupingStore.normalize(
                    databaseURL: database,
                    selectedImages: evidence,
                    mode: .allSelectedImagesShared
                ),
                "\(mismatch.rawValue)"
            ) { error in
                XCTAssertEqual(
                    error as? ColmapCameraGroupingStoreError,
                    .incompatibleCameras(
                        sourceGroupID: "all-selected-images",
                        canonicalCameraID: 1,
                        incompatibleCameraID: 2
                    )
                )
            }
            XCTAssertEqual(try ColmapDatabaseDigester.digests(at: database), before)
            XCTAssertEqual(try rowCount("cameras", in: database), 2)
        }
    }

    func testCancellationAfterCameraUpdatesRollsBackEveryTable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("cancelled.db")
        let names = ["one.jpg", "two.jpg", "three.jpg", "four.jpg"]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names)
        let evidence = names.map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0,
                sourceGroupID: "video_000",
                isVideo: true
            )
        }
        let before = try ColmapDatabaseDigester.digests(at: database)
        var checks = 0

        XCTAssertThrowsError(
            try ColmapCameraGroupingStore.normalize(
                databaseURL: database,
                selectedImages: evidence,
                mode: .videoSourceGroups,
                checkCancellation: {
                    checks += 1
                    if checks == 17 { throw ProbeError.cancelled }
                }
            )
        ) { error in
            XCTAssertEqual(error as? ProbeError, .cancelled)
        }
        XCTAssertEqual(checks, 17)
        XCTAssertEqual(try ColmapDatabaseDigester.digests(at: database), before)
        XCTAssertEqual(try rowCount("cameras", in: database), 4)
        XCTAssertEqual(
            try cameraIDsByImageName(in: database),
            ["one.jpg": 1, "two.jpg": 2, "three.jpg": 3, "four.jpg": 4]
        )
    }

    func testVideoSourceGroupingRejectsCameraAlreadySharedAcrossSourcesWithoutChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("cross-source.db")
        let names = ["a-1.jpg", "a-2.jpg", "b-1.jpg", "b-2.jpg"]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names)
        try rebindImage(cameraID: 1, rigID: 1, imageName: "b-1.jpg", in: database)
        let evidence = [
            ColmapSelectedImageCameraEvidence(
                imageName: "a-1.jpg", sourceGroupID: "video_000", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "a-2.jpg", sourceGroupID: "video_000", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "b-1.jpg", sourceGroupID: "video_001", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "b-2.jpg", sourceGroupID: "video_001", isVideo: true
            ),
        ]
        let before = try ColmapDatabaseDigester.digests(at: database)

        XCTAssertThrowsError(
            try ColmapCameraGroupingStore.normalize(
                databaseURL: database,
                selectedImages: evidence,
                mode: .videoSourceGroups
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapCameraGroupingStoreError,
                .cameraSharedAcrossSourceGroups(cameraID: 1)
            )
        }
        XCTAssertEqual(try ColmapDatabaseDigester.digests(at: database), before)
    }

    func testDatabaseImageSetMismatchRollsBackWithoutTouchingRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("mismatch.db")
        let names = ["first.jpg", "second.jpg"]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names)
        let before = try ColmapDatabaseDigester.digests(at: database)
        let evidence = [
            ColmapSelectedImageCameraEvidence(
                imageName: "first.jpg", sourceGroupID: "video_000", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "unknown.jpg", sourceGroupID: "video_000", isVideo: true
            ),
        ]

        XCTAssertThrowsError(
            try ColmapCameraGroupingStore.normalize(
                databaseURL: database,
                selectedImages: evidence,
                mode: .videoSourceGroups
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapCameraGroupingStoreError,
                .databaseImageSetMismatch(
                    expected: ["first.jpg", "unknown.jpg"],
                    actual: names
                )
            )
        }
        XCTAssertEqual(try ColmapDatabaseDigester.digests(at: database), before)
    }

    func testSuccessfulGroupingPreservesFeaturesMatchesAndExistingOrphanCamera() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("preservation.db")
        let names = ["a-1.jpg", "a-2.jpg", "b-1.jpg", "b-2.jpg"]
        try makeDatabase(at: database, imageNames: names, insertionOrder: names)
        try insertOrphanCamera(cameraID: 999, in: database)
        let evidence = [
            ColmapSelectedImageCameraEvidence(
                imageName: "a-1.jpg", sourceGroupID: "video_000", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "a-2.jpg", sourceGroupID: "video_000", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "b-1.jpg", sourceGroupID: "video_001", isVideo: true
            ),
            ColmapSelectedImageCameraEvidence(
                imageName: "b-2.jpg", sourceGroupID: "video_001", isVideo: true
            ),
        ]
        let keypointsBefore = try payloadRows(table: "keypoints", key: "image_id", in: database)
        let descriptorsBefore = try payloadRows(
            table: "descriptors", key: "image_id", in: database
        )
        let matchingDigestBefore = try ColmapDatabaseDigester.digests(at: database).matching

        let receipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: database,
            selectedImages: evidence,
            mode: .videoSourceGroups
        )

        XCTAssertEqual(receipt.cameraCountBefore, 5)
        XCTAssertEqual(receipt.cameraCountAfter, 3)
        XCTAssertEqual(
            try cameraIDs(in: database),
            [1, 3, 999],
            "Only cameras made unreachable by this normalization may be deleted"
        )
        XCTAssertEqual(
            try payloadRows(table: "keypoints", key: "image_id", in: database),
            keypointsBefore
        )
        XCTAssertEqual(
            try payloadRows(table: "descriptors", key: "image_id", in: database),
            descriptorsBefore
        )
        XCTAssertEqual(
            try ColmapDatabaseDigester.digests(at: database).matching,
            matchingDigestBefore
        )
        XCTAssertEqual(try rowCount("keypoints", in: database), 4)
        XCTAssertEqual(try rowCount("descriptors", in: database), 4)
        XCTAssertEqual(try rowCount("matches", in: database), 1)
        XCTAssertEqual(try rowCount("two_view_geometries", in: database), 1)
    }

    func testMalformedCameraSchemaIsRejectedBeforeAnyMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("malformed.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            return XCTFail("Could not create malformed schema fixture")
        }
        try executeScript(
            """
            CREATE TABLE cameras(
                camera_id INTEGER PRIMARY KEY NOT NULL,
                model INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                prior_focal_length INTEGER NOT NULL
            );
            CREATE TABLE images(
                image_id INTEGER PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                camera_id INTEGER NOT NULL
            );
            INSERT INTO cameras VALUES (1, 1, 1920, 1080, 0);
            INSERT INTO images VALUES (1, 'frame.jpg', 1);
            """,
            in: database
        )
        sqlite3_close(database)
        let before = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(
            try ColmapCameraGroupingStore.normalize(
                databaseURL: databaseURL,
                selectedImages: [ColmapSelectedImageCameraEvidence(
                    imageName: "frame.jpg",
                    sourceGroupID: "video_000",
                    isVideo: true
                )],
                mode: .videoSourceGroups
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapCameraGroupingStoreError,
                .unsafeSchema(table: "cameras")
            )
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
    }

    func testMissingRelationalUniqueIndexIsRejectedBeforeAnyMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("missing-index.db")
        let names = ["first.jpg", "second.jpg"]
        try makeDatabase(at: databaseURL, imageNames: names, insertionOrder: names)
        try executeScript("DROP INDEX rig_ref_sensor_assignment;", at: databaseURL)
        let before = try ColmapDatabaseDigester.digests(at: databaseURL)
        let beforeRelations = try cameraRelationsByImageName(in: databaseURL)

        XCTAssertThrowsError(try ColmapCameraGroupingStore.normalize(
            databaseURL: databaseURL,
            selectedImages: names.map {
                ColmapSelectedImageCameraEvidence(
                    imageName: $0,
                    sourceGroupID: "video_000",
                    isVideo: true
                )
            },
            mode: .videoSourceGroups
        )) { error in
            XCTAssertEqual(
                error as? ColmapCameraGroupingStoreError,
                .unsafeSchema(table: "rigs")
            )
        }
        XCTAssertEqual(try ColmapDatabaseDigester.digests(at: databaseURL), before)
        XCTAssertEqual(try cameraRelationsByImageName(in: databaseURL), beforeRelations)
    }

    func testMalformedCameraParametersAndPriorFocalFlagAreRejectedWithoutChanges() throws {
        enum Malformation: String, CaseIterable {
            case parameterCount
            case nonfiniteParameter
            case priorFocalFlag
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["first.jpg", "second.jpg"]
        let evidence = names.map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0, sourceGroupID: "video_000", isVideo: true
            )
        }

        for malformation in Malformation.allCases {
            let database = directory.appendingPathComponent("\(malformation.rawValue).db")
            try makeDatabase(at: database, imageNames: names, insertionOrder: names)
            switch malformation {
            case .parameterCount:
                try updateCameraParameters(
                    cameraParameters([1000]),
                    cameraID: 2,
                    in: database
                )
            case .nonfiniteParameter:
                try updateCameraParameters(
                    cameraParameters([1000, .nan, 960, 540]),
                    cameraID: 2,
                    in: database
                )
            case .priorFocalFlag:
                try updateCameraColumn("prior_focal_length = 2", cameraID: 2, in: database)
            }
            let before = try ColmapDatabaseDigester.digests(at: database)

            XCTAssertThrowsError(
                try ColmapCameraGroupingStore.normalize(
                    databaseURL: database,
                    selectedImages: evidence,
                    mode: .videoSourceGroups
                )
            ) { error in
                XCTAssertEqual(
                    error as? ColmapCameraGroupingStoreError,
                    .invalidCameraRecord(cameraID: 2),
                    malformation.rawValue
                )
            }
            XCTAssertEqual(try ColmapDatabaseDigester.digests(at: database), before)
        }
    }

    func testPinnedColmapEUCMAndEquirectangularModelsUseTheirExactParameterContracts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["first.jpg", "second.jpg"]
        let evidence = names.map {
            ColmapSelectedImageCameraEvidence(
                imageName: $0,
                sourceGroupID: "video_000",
                isVideo: true
            )
        }
        let contracts: [(model: Int, parameters: [Double])] = [
            (16, [1000, 1000, 960, 540, 0.5, 1]),
            (17, [1920, 1080]),
        ]

        for contract in contracts {
            let database = directory.appendingPathComponent("model-\(contract.model).db")
            try makeDatabase(at: database, imageNames: names, insertionOrder: names)
            for cameraID in 1...2 {
                try updateCameraColumn(
                    "model = \(contract.model)",
                    cameraID: Int64(cameraID),
                    in: database
                )
                try updateCameraParameters(
                    cameraParameters(contract.parameters),
                    cameraID: Int64(cameraID),
                    in: database
                )
            }

            let receipt = try ColmapCameraGroupingStore.normalize(
                databaseURL: database,
                selectedImages: evidence,
                mode: .videoSourceGroups
            )

            XCTAssertEqual(receipt.cameraCountAfter, 1, "model \(contract.model)")
        }
    }

    func testLiveWALWriterPreventsGroupingWithoutChangingCommittedRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("locked.db")
        let names = ["first.jpg", "second.jpg"]
        try makeDatabase(at: databaseURL, imageNames: names, insertionOrder: names)
        let before = try ColmapDatabaseDigester.digests(at: databaseURL)
        var writer: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, let writer else {
            return XCTFail("Could not open WAL writer fixture")
        }
        defer { sqlite3_close(writer) }
        try executeScript("PRAGMA journal_mode = WAL;", in: writer)
        try executeScript("BEGIN IMMEDIATE TRANSACTION;", in: writer)
        var writerIsOpen = true
        defer {
            if writerIsOpen { sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil) }
        }

        XCTAssertThrowsError(
            try ColmapCameraGroupingStore.normalize(
                databaseURL: databaseURL,
                selectedImages: names.map {
                    ColmapSelectedImageCameraEvidence(
                        imageName: $0, sourceGroupID: "video_000", isVideo: true
                    )
                },
                mode: .videoSourceGroups
            )
        ) { error in
            guard case let .databaseOperationFailed(operation, code, _) =
                error as? ColmapCameraGroupingStoreError else {
                return XCTFail("Expected the live writer to block the transaction")
            }
            XCTAssertEqual(operation, "begin camera grouping")
            XCTAssertEqual(code, SQLITE_BUSY)
        }
        try executeScript("ROLLBACK;", in: writer)
        writerIsOpen = false
        XCTAssertEqual(try ColmapDatabaseDigester.digests(at: databaseURL), before)
    }

    private func makeDatabase<S: Sequence>(
        at url: URL,
        imageNames: [String],
        insertionOrder: S
    ) throws where S.Element == String {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 1)
        }
        defer { sqlite3_close(database) }
        try executeScript(
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
                prior_qw REAL,
                prior_qx REAL,
                prior_qy REAL,
                prior_qz REAL,
                prior_tx REAL,
                prior_ty REAL,
                prior_tz REAL,
                CONSTRAINT image_name_unique UNIQUE(name),
                FOREIGN KEY(camera_id) REFERENCES cameras(camera_id)
            );
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
                data BLOB
            );
            CREATE TABLE descriptors(
                image_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
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
            """,
            in: database
        )
        let idsByName = Dictionary(uniqueKeysWithValues: imageNames.enumerated().map {
            ($0.element, Int64($0.offset + 1))
        })
        let params = cameraParameters([1000, 1000, 960, 540])
        for name in insertionOrder {
            let cameraID = try XCTUnwrap(idsByName[name])
            try execute(
                "INSERT INTO cameras(camera_id, model, width, height, params, prior_focal_length) "
                    + "VALUES (?, 1, 1920, 1080, ?, 0);",
                bindings: [.integer(cameraID), .blob(params)],
                in: database
            )
            try execute(
                "INSERT INTO images(image_id, name, camera_id) VALUES (?, ?, ?);",
                bindings: [.integer(cameraID), .text(name), .integer(cameraID)],
                in: database
            )
            try execute(
                "INSERT INTO rigs(rig_id, ref_sensor_id, ref_sensor_type) VALUES (?, ?, 0);",
                bindings: [.integer(cameraID), .integer(cameraID)],
                in: database
            )
            try execute(
                "INSERT INTO frames(frame_id, rig_id) VALUES (?, ?);",
                bindings: [.integer(cameraID), .integer(cameraID)],
                in: database
            )
            try execute(
                "INSERT INTO frame_data(frame_id, data_id, sensor_id, sensor_type) "
                    + "VALUES (?, ?, ?, 0);",
                bindings: [
                    .integer(cameraID),
                    .integer(cameraID),
                    .integer(cameraID),
                ],
                in: database
            )
            try execute(
                "INSERT INTO pose_priors(pose_prior_id, corr_data_id, corr_sensor_id, "
                    + "corr_sensor_type, coordinate_system) VALUES (?, ?, ?, 0, 0);",
                bindings: [
                    .integer(cameraID),
                    .integer(cameraID),
                    .integer(cameraID),
                ],
                in: database
            )
            try execute(
                "INSERT INTO keypoints(image_id, rows, cols, data) VALUES (?, 1, 2, ?);",
                bindings: [.integer(cameraID), .blob(Data([UInt8(truncatingIfNeeded: cameraID), 0x41]))],
                in: database
            )
            try execute(
                "INSERT INTO descriptors(image_id, rows, cols, data) VALUES (?, 1, 4, ?);",
                bindings: [.integer(cameraID), .blob(Data([0x10, UInt8(truncatingIfNeeded: cameraID), 0x20, 0x30]))],
                in: database
            )
        }
        if imageNames.count >= 2 {
            try execute(
                "INSERT INTO matches(pair_id, rows, cols, data) VALUES (2147483649, 1, 2, ?);",
                bindings: [.blob(Data([0, 0, 0, 0, 1, 0, 0, 0]))],
                in: database
            )
            try execute(
                "INSERT INTO two_view_geometries(pair_id, rows, cols, data, config) "
                    + "VALUES (2147483649, 1, 2, ?, 2);",
                bindings: [.blob(Data([0, 0, 0, 0, 1, 0, 0, 0]))],
                in: database
            )
        }
    }

    private func cameraParameters(_ values: [Double]) -> Data {
        values.reduce(into: Data()) { data, value in
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
    }

    private func updateCameraColumn(
        _ assignment: String,
        cameraID: Int64,
        in url: URL
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 4)
        }
        defer { sqlite3_close(database) }
        try execute(
            "UPDATE cameras SET \(assignment) WHERE camera_id = ?;",
            bindings: [.integer(cameraID)],
            in: database
        )
    }

    private func updateCameraParameters(_ parameters: Data, cameraID: Int64, in url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 5)
        }
        defer { sqlite3_close(database) }
        try execute(
            "UPDATE cameras SET params = ? WHERE camera_id = ?;",
            bindings: [.blob(parameters), .integer(cameraID)],
            in: database
        )
    }

    private func updateImageCamera(cameraID: Int64, imageName: String, in url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 6)
        }
        defer { sqlite3_close(database) }
        try execute(
            "UPDATE images SET camera_id = ? WHERE name = ?;",
            bindings: [.integer(cameraID), .text(imageName)],
            in: database
        )
    }

    private func rebindImage(
        cameraID: Int64,
        rigID: Int64,
        imageName: String,
        in url: URL
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 8)
        }
        defer { sqlite3_close(database) }
        try executeScript("BEGIN IMMEDIATE TRANSACTION;", in: database)
        do {
            try execute(
                "UPDATE images SET camera_id = ? WHERE name = ?;",
                bindings: [.integer(cameraID), .text(imageName)],
                in: database
            )
            try execute(
                "UPDATE frame_data SET sensor_id = ? WHERE data_id = "
                    + "(SELECT image_id FROM images WHERE name = ?);",
                bindings: [.integer(cameraID), .text(imageName)],
                in: database
            )
            try execute(
                "UPDATE frames SET rig_id = ? WHERE frame_id = "
                    + "(SELECT frame_id FROM frame_data WHERE data_id = "
                    + "(SELECT image_id FROM images WHERE name = ?));",
                bindings: [.integer(rigID), .text(imageName)],
                in: database
            )
            try execute(
                "UPDATE pose_priors SET corr_sensor_id = ? WHERE corr_data_id = "
                    + "(SELECT image_id FROM images WHERE name = ?);",
                bindings: [.integer(cameraID), .text(imageName)],
                in: database
            )
            try executeScript("COMMIT;", in: database)
        } catch {
            try? executeScript("ROLLBACK;", in: database)
            throw error
        }
    }

    private func insertOrphanCamera(cameraID: Int64, in url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 7)
        }
        defer { sqlite3_close(database) }
        try execute(
            "INSERT INTO cameras(camera_id, model, width, height, params, prior_focal_length) "
                + "VALUES (?, 1, 1920, 1080, ?, 0);",
            bindings: [
                .integer(cameraID),
                .blob(cameraParameters([1000, 1000, 960, 540])),
            ],
            in: database
        )
    }

    private enum Binding {
        case integer(Int64)
        case text(String)
        case blob(Data)
    }

    private func executeScript(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "ColmapCameraGroupingStoreTests",
                code: Int(result),
                userInfo: [
                    NSLocalizedDescriptionKey: message.map { String(cString: $0) }
                        ?? String(cString: sqlite3_errmsg(database))
                ]
            )
        }
    }

    private func executeScript(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 9)
        }
        defer { sqlite3_close(database) }
        try executeScript(sql, in: database)
    }

    private func execute(
        _ sql: String,
        bindings: [Binding] = [],
        in database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, transient)
                }
            case .blob(let value):
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                }
            }
            guard result == SQLITE_OK else { throw sqliteError(database) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func rowCount(_ table: String, in url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 2)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM \(table);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func cameraIDsByImageName(in url: URL) throws -> [String: Int64] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name, camera_id FROM images ORDER BY image_id;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: Int64] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else {
                throw sqliteError(database)
            }
            result[String(cString: name)] = sqlite3_column_int64(statement, 1)
        }
        return result
    }

    private func cameraIDs(in url: URL) throws -> [Int64] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 8)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT camera_id FROM cameras ORDER BY camera_id;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        var result: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(sqlite3_column_int64(statement, 0))
        }
        return result
    }

    private func cameraRelationsByImageName(in url: URL) throws -> [String: [Int64]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 11)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql =
            "SELECT i.name, i.camera_id, fd.sensor_id, f.rig_id, r.ref_sensor_id, "
            + "p.corr_sensor_id FROM images i "
            + "JOIN frame_data fd ON fd.data_id = i.image_id AND fd.sensor_type = 0 "
            + "JOIN frames f ON f.frame_id = fd.frame_id "
            + "JOIN rigs r ON r.rig_id = f.rig_id "
            + "JOIN pose_priors p ON p.corr_data_id = i.image_id "
            + "AND p.corr_sensor_type = 0 ORDER BY i.name;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: [Int64]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else {
                throw sqliteError(database)
            }
            result[String(cString: name)] = (1...5).map {
                sqlite3_column_int64(statement, Int32($0))
            }
        }
        return result
    }

    private func payloadRows(table: String, key: String, in url: URL) throws -> [String] {
        let allowed = ["keypoints": "image_id", "descriptors": "image_id"]
        guard allowed[table] == key else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 9)
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapCameraGroupingStoreTests", code: 10)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT \(key), rows, cols, hex(data) FROM \(table) ORDER BY \(key);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hex = sqlite3_column_text(statement, 3) else {
                throw sqliteError(database)
            }
            result.append(
                "\(sqlite3_column_int64(statement, 0)):"
                    + "\(sqlite3_column_int64(statement, 1)):"
                    + "\(sqlite3_column_int64(statement, 2)):"
                    + String(cString: hex)
            )
        }
        return result
    }

    private func sqliteError(_ database: OpaquePointer) -> NSError {
        NSError(
            domain: "ColmapCameraGroupingStoreTests",
            code: Int(sqlite3_extended_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }
}
#endif
