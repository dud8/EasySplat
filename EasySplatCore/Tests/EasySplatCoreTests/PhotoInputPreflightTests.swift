import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class PhotoInputPreflightTests: XCTestCase {
    func testInspectionHonorsTaskCancellation() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: root.appendingPathComponent("photo.jpg"),
            size: 16,
            value: 80,
            utType: .jpeg
        ))

        let task = Task<PhotoInputPreflight, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PhotoInputPreflight.inspect(folder: root)
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled inspection must stop before decoding or hashing photos.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testInspectionCountsOnlyDecodedUniquePhotos() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let first = root.appendingPathComponent("first.jpg")
        let duplicate = nested.appendingPathComponent("duplicate.jpg")
        let second = nested.appendingPathComponent("second.png")
        let corrupt = root.appendingPathComponent("corrupt.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: first, size: 16, value: 40, utType: .jpeg))
        try FileManager.default.copyItem(at: first, to: duplicate)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: second, size: 16, value: 180, utType: .png))
        try Data("not an image".utf8).write(to: corrupt)

        let result = try PhotoInputPreflight.inspect(folder: root)

        XCTAssertEqual(result.discoveredPhotoCount, 4)
        XCTAssertEqual(result.validPhotoCount, 2)
        XCTAssertEqual(result.unreadablePhotoCount, 1)
        XCTAssertEqual(result.duplicatePhotoCount, 1)
    }

    func testInspectionSkipsHiddenFilesAndProjectOutputFolders() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("project.json"))
        let output = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: root.appendingPathComponent("capture.jpg"),
            size: 16,
            value: 80,
            utType: .jpeg
        ))
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: output.appendingPathComponent("generated.jpg"),
            size: 16,
            value: 120,
            utType: .jpeg
        ))
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: root.appendingPathComponent(".hidden.jpg"),
            size: 16,
            value: 160,
            utType: .jpeg
        ))

        let result = try PhotoInputPreflight.inspect(folder: root)

        XCTAssertEqual(result.discoveredPhotoCount, 1)
        XCTAssertEqual(result.validPhotoCount, 1)
    }

    func testInspectionDoesNotFollowPhotoOrDirectorySymlinks() throws {
        let root = try TestFileBuilder.makeTempDir()
        let outside = try TestFileBuilder.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsidePhoto = outside.appendingPathComponent("outside.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: outsidePhoto,
            size: 16,
            value: 80,
            utType: .jpeg
        ))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.jpg"),
            withDestinationURL: outsidePhoto
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked Folder"),
            withDestinationURL: outside
        )

        let result = try PhotoInputPreflight.inspect(folder: root)

        XCTAssertEqual(result.discoveredPhotoCount, 0)
        XCTAssertEqual(result.validPhotoCount, 0)
    }
}
