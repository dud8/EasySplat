#if canImport(XCTest)
import Foundation
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
}
#endif
