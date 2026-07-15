#if canImport(XCTest)
import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapTextModelNormalizerTests: XCTestCase {
    func testNormalizeAddsMissingPoints2DLines() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagesTxt = tempDir.appendingPathComponent("images.txt")
        let input = """
        # Image list with two lines per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        2 1 0 0 0 0 0 0 2 frame_000001.jpg
        """
        try input.write(to: imagesTxt, atomically: true, encoding: .utf8)

        let changed = try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt)
        XCTAssertTrue(changed)

        let output = try String(contentsOf: imagesTxt, encoding: .utf8)
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let nonComment = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") }
        XCTAssertGreaterThanOrEqual(nonComment.count, 4)
        let firstFour = Array(nonComment.prefix(4))
        XCTAssertFalse(firstFour[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(firstFour[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(firstFour[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(firstFour[3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testNormalizeIsIdempotentForValidFormat() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagesTxt = tempDir.appendingPathComponent("images.txt")
        let input = "# Image list with two lines per image:\n"
            + "#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n"
            + "1 1 0 0 0 0 0 0 1 frame_000000.jpg\n\n"
            + "2 1 0 0 0 0 0 0 2 frame_000001.jpg\n\n"
        try input.write(to: imagesTxt, atomically: true, encoding: .utf8)

        let changed = try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt)
        XCTAssertFalse(changed)

        let output = try String(contentsOf: imagesTxt, encoding: .utf8)
        XCTAssertEqual(output, input)
    }

    func testNormalizePreservesPoints2DLines() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagesTxt = tempDir.appendingPathComponent("images.txt")
        let input = """
        # Image list with two lines per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        12.3 45.6 1 7.8 9.0 2
        """
        try input.write(to: imagesTxt, atomically: true, encoding: .utf8)

        let changed = try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt)
        XCTAssertFalse(changed)

        let output = try String(contentsOf: imagesTxt, encoding: .utf8)
        XCTAssertEqual(output, input)
    }

    func testNormalizeRecognizesNumericOnlyImageName() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagesTxt = tempDir.appendingPathComponent("images.txt")
        let input = """
        1 1 0 0 0 0 0 0 1 000001
        2 1 0 0 0 0 0 0 1 000002
        """
        try input.write(to: imagesTxt, atomically: true, encoding: .utf8)

        XCTAssertTrue(try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt))
        let output = try String(contentsOf: imagesTxt, encoding: .utf8)
        XCTAssertEqual(output, "1 1 0 0 0 0 0 0 1 000001\n\n2 1 0 0 0 0 0 0 1 000002\n\n")
    }

    func testNormalizeDoesNotMistakeNumericPoints2DForPoseLine() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagesTxt = tempDir.appendingPathComponent("images.txt")
        let input = """
        1 1 0 0 0 0 0 0 1 000001
        10 1 0 0 0 0 0 0 1 2 3 4
        """
        try input.write(to: imagesTxt, atomically: true, encoding: .utf8)

        XCTAssertFalse(try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt))
        XCTAssertEqual(try String(contentsOf: imagesTxt, encoding: .utf8), input)
    }

    func testNormalizeRejectsSymlinkedImagesFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let externalURL = tempDir.appendingPathComponent("external-images.txt")
        try "1 1 0 0 0 0 0 0 1 frame.jpg\n".write(
            to: externalURL,
            atomically: true,
            encoding: .utf8
        )
        let imagesURL = tempDir.appendingPathComponent("images.txt")
        try FileManager.default.createSymbolicLink(
            at: imagesURL,
            withDestinationURL: externalURL
        )

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesURL)
        )
    }

    func testNormalizePreservesExistingCRLFBytesAcrossUTF8ChunkBoundary() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let imagesURL = tempDir.appendingPathComponent("images.txt")
        let firstPosePrefix = "1 1 0 0 0 0 0 0 1 frame_"
        let paddingCount = (4_095 - ("#".utf8.count + "\r\n".utf8.count + firstPosePrefix.utf8.count) % 4_096 + 4_096) % 4_096
        let comment = "#" + String(repeating: "x", count: paddingCount) + "\r\n"
        let firstPose = firstPosePrefix + "é one.jpg\r\n"
        let secondPose = "2 1 0 0 0 0 0 0 1 second image.jpg\r\n"
        let input = Data((comment + firstPose + secondPose).utf8)
        try input.write(to: imagesURL)

        XCTAssertTrue(try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesURL))

        let expected = Data((comment + firstPose + "\r\n" + secondPose + "\r\n").utf8)
        XCTAssertEqual(try Data(contentsOf: imagesURL), expected)
    }

    func testNormalizeValidInputDoesNotReplaceOrRewriteFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer {
            _ = Darwin.chmod(tempDir.path, S_IRWXU)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let imagesURL = tempDir.appendingPathComponent("images.txt")
        let input = Data("# keep\r\n1 1 0 0 0 0 0 0 1 café image.jpg\r\n  1.5\t2.5  -1  \r\n".utf8)
        try input.write(to: imagesURL)
        var before = stat()
        XCTAssertEqual(Darwin.lstat(imagesURL.path, &before), 0)
        XCTAssertEqual(Darwin.chmod(tempDir.path, S_IRUSR | S_IXUSR), 0)

        XCTAssertFalse(try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesURL))

        var after = stat()
        XCTAssertEqual(Darwin.lstat(imagesURL.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        XCTAssertEqual(try Data(contentsOf: imagesURL), input)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["images.txt"])
    }

    func testNormalizeCancellationLeavesOriginalFileUntouched() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let imagesURL = tempDir.appendingPathComponent("images.txt")
        let input = Data(
            ("1 1 0 0 0 0 0 0 1 first.jpg\n"
                + "2 1 0 0 0 0 0 0 1 second.jpg\n").utf8
        )
        try input.write(to: imagesURL)
        var reachedWritePass = false

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(
                at: imagesURL,
                checkCancellation: {
                    let entries = try FileManager.default.contentsOfDirectory(
                        atPath: tempDir.path
                    )
                    guard entries.contains(where: { $0.hasPrefix(".images.txt-normalize-") }) else {
                        return
                    }
                    reachedWritePass = true
                    throw CancellationError()
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertTrue(reachedWritePass)
        XCTAssertEqual(try Data(contentsOf: imagesURL), input)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["images.txt"])
    }

    func testRemapSeedModelIDsToDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(
            at: dbURL,
            rows: [
                (10, "frame_b.jpg", 20),
                (11, "frame_a.jpg", 21)
            ]
        )

        let modelURL = tempDir.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try """
        # Camera list with one line of data per camera:
        #   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]
        1 SIMPLE_PINHOLE 100 100 50 50 50
        2 SIMPLE_PINHOLE 100 100 50 50 50
        """.write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)

        try ("""
        # Image list with two lines of data per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        1 1 0 0 0 0 0 0 1 frame_b.jpg

        2 1 0 0 0 0 0 0 2 frame_a.jpg

        """ + "\n").write(to: modelURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        try """
        # 3D point list with one line of data per point:
        # POINT3D_ID X Y Z R G B ERROR TRACK[]
        1 0 0 0 255 255 255 0.0 1 0 2 0
        """.write(to: modelURL.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let changed = try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL)
        XCTAssertTrue(changed)

        let images = try String(contentsOf: modelURL.appendingPathComponent("images.txt"), encoding: .utf8)
        XCTAssertTrue(images.contains("10 1 0 0 0 0 0 0 20 frame_b.jpg"))
        XCTAssertTrue(images.contains("11 1 0 0 0 0 0 0 21 frame_a.jpg"))

        let cameras = try String(contentsOf: modelURL.appendingPathComponent("cameras.txt"), encoding: .utf8)
        XCTAssertTrue(cameras.contains("20 SIMPLE_PINHOLE"))
        XCTAssertTrue(cameras.contains("21 SIMPLE_PINHOLE"))

        let points = try String(contentsOf: modelURL.appendingPathComponent("points3D.txt"), encoding: .utf8)
        XCTAssertTrue(points.contains("10 0 11 0"))
    }

    func testRemapCancellationInterruptsEveryTextFileWithoutChangingModel() throws {
        for targetName in ["images.txt", "cameras.txt", "points3D.txt"] {
            let tempDir = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let dbURL = tempDir.appendingPathComponent("database.db")
            try createImagesDatabase(at: dbURL, rows: [(10, "a.jpg", 20)])
            let modelURL = try createModel(
                in: tempDir,
                cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
                images: ["1 1 0 0 0 0 0 0 1 a.jpg"],
                points: ["1 0 0 1 255 255 255 0.0 1 0"]
            )
            let original = try modelContents(at: modelURL)
            var reachedTarget = false

            XCTAssertThrowsError(
                try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                    seedModelURL: modelURL,
                    databaseURL: dbURL,
                    checkCancellation: {
                        let entries = try FileManager.default.contentsOfDirectory(
                            at: tempDir,
                            includingPropertiesForKeys: nil
                        )
                        guard let staging = entries.first(where: {
                            $0.lastPathComponent.hasPrefix(".seed-id-remap-")
                        }), FileManager.default.fileExists(
                            atPath: staging.appendingPathComponent(targetName).path
                        ) else { return }
                        reachedTarget = true
                        throw CancellationError()
                    }
                )
            ) { error in
                XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
            }

            XCTAssertTrue(reachedTarget, "Cancellation never reached \(targetName)")
            XCTAssertEqual(try modelContents(at: modelURL), original)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
                    .contains(where: { $0.hasPrefix(".seed-id-remap-") })
            )
        }
    }

    func testRemapSeedModelIDsToDatabaseNoOverlapThrowsWithoutModifyingModel() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(
            at: dbURL,
            rows: [
                (1, "other.jpg", 1)
            ]
        )

        let modelURL = tempDir.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 100 100 50 50 50\n".write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try "1 1 0 0 0 0 0 0 1 frame_a.jpg\n\n".write(to: modelURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try "1 0 0 0 255 255 255 0.0 1 0\n".write(to: modelURL.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let original = try modelContents(at: modelURL)
        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL)
        )
        XCTAssertEqual(try modelContents(at: modelURL), original)
    }

    func testRemapPreservesCompleteImageNamesWithSpacesUnicodeApostrophesAndDigits() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let names = ["front patio 001.jpg", "café d'été ②.heic", "000123"]
        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(
            at: dbURL,
            rows: [
                (10, names[0], 20),
                (11, names[1], 21),
                (12, names[2], 22)
            ]
        )
        let modelURL = try createModel(
            in: tempDir,
            cameras: [
                "1 SIMPLE_PINHOLE 100 100 50 50 50",
                "2 SIMPLE_PINHOLE 100 100 50 50 50",
                "3 SIMPLE_PINHOLE 100 100 50 50 50"
            ],
            images: [
                "1 1 0 0 0 0 0 0 1 \(names[0])",
                "2 1 0 0 0 0 0 0 2 \(names[1])",
                "3 1 0 0 0 0 0 0 3 \(names[2])"
            ],
            points: ["1 0 0 0 255 255 255 0.0 1 0 2 0 3 0"]
        )

        XCTAssertTrue(try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL))

        let images = try String(contentsOf: modelURL.appendingPathComponent("images.txt"), encoding: .utf8)
        let poseLines = images.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(
            poseLines,
            [
                "10 1 0 0 0 0 0 0 20 \(names[0])",
                "11 1 0 0 0 0 0 0 21 \(names[1])",
                "12 1 0 0 0 0 0 0 22 \(names[2])"
            ]
        )
    }

    func testRemapChangesOnlyIdentifierTokensAndPreservesWhitespaceAndUnicode() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let name = "front  café d'été 007.jpg"
        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(at: dbURL, rows: [(10, name, 20)])
        let modelURL = tempDir.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        let cameras = Data("# cameras\r\n\t1\tPINHOLE  100 100  50 50 50\r\n".utf8)
        let images = Data("# images\r\n\t1\t1  0 0 0\t0 0 0\t1\t\(name)\r\n  10.5\t20.25  1  \r\n".utf8)
        let points = Data("# points\r\n1  0 0 1  255 255 255 0.0\t1\t0\r\n".utf8)
        try cameras.write(to: modelURL.appendingPathComponent("cameras.txt"))
        try images.write(to: modelURL.appendingPathComponent("images.txt"))
        try points.write(to: modelURL.appendingPathComponent("points3D.txt"))

        XCTAssertTrue(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: modelURL,
                databaseURL: dbURL
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: modelURL.appendingPathComponent("cameras.txt")),
            Data("# cameras\r\n\t20\tPINHOLE  100 100  50 50 50\r\n".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: modelURL.appendingPathComponent("images.txt")),
            Data("# images\r\n\t10\t1  0 0 0\t0 0 0\t20\t\(name)\r\n  10.5\t20.25  1  \r\n".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: modelURL.appendingPathComponent("points3D.txt")),
            Data("# points\r\n1  0 0 1  255 255 255 0.0\t10\t0\r\n".utf8)
        )
    }

    func testRemapSuccessfulSwapDropsStaleBinaryAndExtraFiles() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(at: dbURL, rows: [(10, "frame.jpg", 20)])
        let modelURL = try createModel(
            in: tempDir,
            cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
            images: ["1 1 0 0 0 0 0 0 1 frame.jpg"],
            points: ["1 0 0 1 255 255 255 0.0 1 0"]
        )
        try Data("stale".utf8).write(to: modelURL.appendingPathComponent("cameras.bin"))
        try Data("stale".utf8).write(to: modelURL.appendingPathComponent("notes.json"))

        XCTAssertTrue(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: modelURL,
                databaseURL: dbURL
            )
        )

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: modelURL.path).sorted(),
            ["cameras.txt", "images.txt", "points3D.txt"]
        )
    }

    func testRemapLatePointFailureLeavesOriginalModelAndNoStagingDirectory() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(at: dbURL, rows: [(10, "frame.jpg", 20)])
        let modelURL = try createModel(
            in: tempDir,
            cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
            images: ["1 1 0 0 0 0 0 0 1 frame.jpg"],
            points: (1...10_000).map { "\($0) 0 0 1 255 255 255 0.0 1 0" }
                + ["10001 malformed"]
        )
        try Data("stale".utf8).write(to: modelURL.appendingPathComponent("notes.json"))
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: modelURL.path).sorted()
        let original = try modelContents(at: modelURL)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: modelURL,
                databaseURL: dbURL
            )
        )

        XCTAssertEqual(try modelContents(at: modelURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: modelURL.path).sorted(), originalNames)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
                .filter { $0.hasPrefix(".seed-id-remap-") }
                .isEmpty
        )
    }

    func testRemapRejectsHardLinkedModelFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(at: dbURL, rows: [(1, "frame.jpg", 1)])
        let modelURL = try createModel(
            in: tempDir,
            cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
            images: ["1 1 0 0 0 0 0 0 1 frame.jpg"],
            points: ["1 0 0 1 255 255 255 0.0 1 0"]
        )
        let pointsURL = modelURL.appendingPathComponent("points3D.txt")
        let externalURL = tempDir.appendingPathComponent("external-points3D.txt")
        try FileManager.default.moveItem(at: pointsURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, pointsURL.path), 0)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: modelURL,
                databaseURL: dbURL
            )
        )
    }

    func testRemapRejectsCamerasFileOverProductionLimitBeforeParsing() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(at: dbURL, rows: [(1, "frame.jpg", 1)])
        let modelURL = try createModel(
            in: tempDir,
            cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
            images: ["1 1 0 0 0 0 0 0 1 frame.jpg"],
            points: ["1 0 0 1 255 255 255 0.0 1 0"]
        )
        let camerasURL = modelURL.appendingPathComponent("cameras.txt")
        let handle = try FileHandle(forWritingTo: camerasURL)
        try handle.truncate(atOffset: UInt64(16 * 1_024 * 1_024 + 1))
        try handle.close()

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: modelURL,
                databaseURL: dbURL
            )
        ) { error in
            XCTAssertFalse(error is ColmapTextModelNormalizer.RemapError)
        }
    }

    func testRemapRejectsPartialImageMappingWithoutModifyingModel() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(at: dbURL, rows: [(10, "mapped.jpg", 20)])
        let modelURL = try createModel(
            in: tempDir,
            cameras: [
                "1 SIMPLE_PINHOLE 100 100 50 50 50",
                "2 SIMPLE_PINHOLE 100 100 50 50 50"
            ],
            images: [
                "1 1 0 0 0 0 0 0 1 mapped.jpg",
                "2 1 0 0 0 0 0 0 2 missing.jpg"
            ],
            points: ["1 0 0 0 255 255 255 0.0 1 0 2 0"]
        )
        let original = try modelContents(at: modelURL)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL)
        )
        XCTAssertEqual(try modelContents(at: modelURL), original)
    }

    func testRemapRejectsTargetImageIDCollisionWithoutModifyingModel() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabaseWithoutConstraints(
            at: dbURL,
            rows: [
                (10, "a.jpg", 20),
                (10, "b.jpg", 21)
            ]
        )
        let modelURL = try createModel(
            in: tempDir,
            cameras: [
                "1 SIMPLE_PINHOLE 100 100 50 50 50",
                "2 SIMPLE_PINHOLE 100 100 50 50 50"
            ],
            images: [
                "1 1 0 0 0 0 0 0 1 a.jpg",
                "2 1 0 0 0 0 0 0 2 b.jpg"
            ],
            points: ["1 0 0 0 255 255 255 0.0 1 0 2 0"]
        )
        let original = try modelContents(at: modelURL)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL)
        )
        XCTAssertEqual(try modelContents(at: modelURL), original)
    }

    func testRemapRejectsInconsistentCameraMappingWithoutModifyingModel() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(
            at: dbURL,
            rows: [
                (10, "a.jpg", 20),
                (11, "b.jpg", 21)
            ]
        )
        let modelURL = try createModel(
            in: tempDir,
            cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
            images: [
                "1 1 0 0 0 0 0 0 1 a.jpg",
                "2 1 0 0 0 0 0 0 1 b.jpg"
            ],
            points: ["1 0 0 0 255 255 255 0.0 1 0 2 0"]
        )
        let original = try modelContents(at: modelURL)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL)
        )
        XCTAssertEqual(try modelContents(at: modelURL), original)
    }

    func testRemapRejectsCameraIDCollisionWithoutModifyingModel() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(
            at: dbURL,
            rows: [
                (10, "a.jpg", 20),
                (11, "b.jpg", 20)
            ]
        )
        let modelURL = try createModel(
            in: tempDir,
            cameras: [
                "1 SIMPLE_PINHOLE 100 100 50 50 50",
                "2 SIMPLE_PINHOLE 100 100 50 50 50"
            ],
            images: [
                "1 1 0 0 0 0 0 0 1 a.jpg",
                "2 1 0 0 0 0 0 0 2 b.jpg"
            ],
            points: ["1 0 0 0 255 255 255 0.0 1 0 2 0"]
        )
        let original = try modelContents(at: modelURL)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL)
        )
        XCTAssertEqual(try modelContents(at: modelURL), original)
    }

    func testRemapPropagatesDatabaseOpenErrorWithoutModifyingModel() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let modelURL = try createModel(
            in: tempDir,
            cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
            images: ["1 1 0 0 0 0 0 0 1 a.jpg"],
            points: []
        )
        let original = try modelContents(at: modelURL)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: modelURL,
                databaseURL: tempDir.appendingPathComponent("missing/database.db")
            )
        )
        XCTAssertEqual(try modelContents(at: modelURL), original)
    }

    func testRemapRejectsZeroQuaternionWithoutModifyingModel() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("database.db")
        try createImagesDatabase(at: dbURL, rows: [(10, "a.jpg", 20)])
        let modelURL = try createModel(
            in: tempDir,
            cameras: ["1 SIMPLE_PINHOLE 100 100 50 50 50"],
            images: ["1 0 0 0 0 0 0 0 1 a.jpg"],
            points: []
        )
        let original = try modelContents(at: modelURL)

        XCTAssertThrowsError(
            try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: modelURL,
                databaseURL: dbURL
            )
        ) { error in
            XCTAssertEqual(error as? ColmapTextModelNormalizer.RemapError, .malformedImagesFile(1))
        }
        XCTAssertEqual(try modelContents(at: modelURL), original)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createModel(
        in root: URL,
        cameras: [String],
        images: [String],
        points: [String]
    ) throws -> URL {
        let modelURL = root.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try (cameras.joined(separator: "\n") + "\n").write(
            to: modelURL.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try (images.map { $0 + "\n" }.joined(separator: "\n") + "\n").write(
            to: modelURL.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try (points.joined(separator: "\n") + "\n").write(
            to: modelURL.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        return modelURL
    }

    private func modelContents(at modelURL: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["cameras.txt", "images.txt", "points3D.txt"].map { name in
            (name, try Data(contentsOf: modelURL.appendingPathComponent(name)))
        })
    }

    private func createImagesDatabase(at url: URL, rows: [(Int, String, Int)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "ColmapTextModelNormalizerTests", code: 1)
        }
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE images (
            image_id INTEGER PRIMARY KEY NOT NULL,
            name TEXT NOT NULL UNIQUE,
            camera_id INTEGER NOT NULL
        );
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ColmapTextModelNormalizerTests", code: 2)
        }
        try insert(rows: rows, into: db)
    }

    private func createImagesDatabaseWithoutConstraints(at url: URL, rows: [(Int, String, Int)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "ColmapTextModelNormalizerTests", code: 4)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(
            db,
            "CREATE TABLE images (image_id INTEGER NOT NULL, name TEXT NOT NULL, camera_id INTEGER NOT NULL);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "ColmapTextModelNormalizerTests", code: 5)
        }
        try insert(rows: rows, into: db)
    }

    private func insert(rows: [(Int, String, Int)], into db: OpaquePointer) throws {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO images (image_id, name, camera_id) VALUES (?, ?, ?);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "ColmapTextModelNormalizerTests", code: 6)
        }
        defer { sqlite3_finalize(statement) }
        for (imageID, name, cameraID) in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_int64(statement, 1, sqlite3_int64(imageID)) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, name, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_int64(statement, 3, sqlite3_int64(cameraID)) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "ColmapTextModelNormalizerTests", code: 7)
            }
        }
    }
}
#endif
