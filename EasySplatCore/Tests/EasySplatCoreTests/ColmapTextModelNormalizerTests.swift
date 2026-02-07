#if canImport(XCTest)
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
        let input = """
        # Image list with two lines per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        1 1 0 0 0 0 0 0 1 frame_000000.jpg

        2 1 0 0 0 0 0 0 2 frame_000001.jpg

        """
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

        try """
        # Image list with two lines of data per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        1 1 0 0 0 0 0 0 1 frame_b.jpg

        2 1 0 0 0 0 0 0 2 frame_a.jpg

        """.write(to: modelURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

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

    func testRemapSeedModelIDsToDatabaseNoOverlapReturnsFalse() throws {
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

        let changed = try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(seedModelURL: modelURL, databaseURL: dbURL)
        XCTAssertFalse(changed)
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
        for (imageID, name, cameraID) in rows {
            let sql = "INSERT INTO images (image_id, name, camera_id) VALUES (\(imageID), '\(name)', \(cameraID));"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "ColmapTextModelNormalizerTests", code: 3)
            }
        }
    }
}
#endif
