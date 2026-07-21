import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryModelSnapshotTests: XCTestCase {
    func testCapturesHashesAndAcceptsUnchangedModel() throws {
        let fixture = try makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = try GeometryModelSnapshot.capture(in: fixture.model)

        XCTAssertEqual(
            Set(snapshot.modelHashes.keys),
            ["cameras.txt", "images.txt", "points3D.txt"]
        )
        XCTAssertTrue(snapshot.modelHashes.values.allSatisfy(GeometryArtifactStore.isSHA256))
        XCTAssertNoThrow(try GeometryModelSnapshot.validate(snapshot, at: fixture.model))
    }

    func testRejectsSameInodeSameSizeMutation() throws {
        let fixture = try makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try GeometryModelSnapshot.capture(in: fixture.model)
        let imagesURL = fixture.model.appendingPathComponent("images.txt")
        var changed = try Data(contentsOf: imagesURL)
        changed[changed.startIndex] ^= 1
        let handle = try FileHandle(forWritingTo: imagesURL)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        try handle.close()

        XCTAssertThrowsError(try GeometryModelSnapshot.validate(snapshot, at: fixture.model)) {
            XCTAssertEqual($0 as? GeometryModelSnapshot.Error, .modelChanged)
        }
    }

    func testRejectsInodeReplacementWithIdenticalBytes() throws {
        let fixture = try makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try GeometryModelSnapshot.capture(in: fixture.model)
        let imagesURL = fixture.model.appendingPathComponent("images.txt")
        let replacement = fixture.model.appendingPathComponent("replacement.txt")
        try Data(contentsOf: imagesURL).write(to: replacement)
        try FileManager.default.removeItem(at: imagesURL)
        try FileManager.default.moveItem(at: replacement, to: imagesURL)

        XCTAssertThrowsError(try GeometryModelSnapshot.validate(snapshot, at: fixture.model)) {
            XCTAssertEqual($0 as? GeometryModelSnapshot.Error, .modelChanged)
        }
    }

    func testRejectsSymlinkedRequiredFile() throws {
        let fixture = try makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cameras = fixture.model.appendingPathComponent("cameras.txt")
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try FileManager.default.moveItem(at: cameras, to: outside)
        XCTAssertEqual(symlink(outside.path, cameras.path), 0)

        XCTAssertThrowsError(try GeometryModelSnapshot.capture(in: fixture.model)) {
            XCTAssertEqual($0 as? GeometryModelSnapshot.Error, .unsafeModel)
        }
    }

    func testCaptureChecksCancellationWhileHashingLargeModelFile() throws {
        let fixture = try makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data(repeating: UInt8(ascii: "#"), count: 5 * 1_024 * 1_024).write(
            to: fixture.model.appendingPathComponent("cameras.txt"),
            options: [.atomic]
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try GeometryModelSnapshot.capture(
            in: fixture.model,
            checkCancellation: {
                cancellationChecks += 1
                throw CancellationError()
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(cancellationChecks, 1)
    }

    private func makeModel() throws -> (root: URL, model: URL) {
        let root = try TestFileBuilder.makeTempDir()
        let model = root.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("1 PINHOLE 100 80 50 50 50 40\n".utf8).write(
            to: model.appendingPathComponent("cameras.txt")
        )
        try Data("1 1 0 0 0 0 0 0 1 frame.jpg\n50 40 1\n".utf8).write(
            to: model.appendingPathComponent("images.txt")
        )
        try Data("1 0 0 1 255 255 255 0 1 0\n".utf8).write(
            to: model.appendingPathComponent("points3D.txt")
        )
        return (root, model)
    }
}
