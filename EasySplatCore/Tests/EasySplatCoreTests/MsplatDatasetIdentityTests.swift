import XCTest
@testable import EasySplatCore

final class MsplatDatasetIdentityTests: XCTestCase {
    func testIdentityMatchesNativeBigEndianFileContract() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("images", isDirectory: true)
        let sparse = root.appendingPathComponent("sparse", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: images.appendingPathComponent("a.jpg"))
        try Data("BC".utf8).write(to: images.appendingPathComponent("b.jpg"))
        try Data("cam".utf8).write(to: sparse.appendingPathComponent("cameras.bin"))
        try Data("images".utf8).write(to: sparse.appendingPathComponent("images.bin"))
        try Data("points".utf8).write(to: sparse.appendingPathComponent("points3D.bin"))

        let identity = try MsplatDatasetIdentity.compute(
            imageFiles: [
                images.appendingPathComponent("b.jpg"),
                images.appendingPathComponent("a.jpg"),
            ],
            sparseDirectory: sparse
        )

        XCTAssertEqual(
            identity.inputDigest,
            "0f218b05ca878d1b8cc8529e672499323edec00d5bdc7f5d0781c6cfcaa8d6d1"
        )
        XCTAssertEqual(
            identity.geometryDigest,
            "3227b10612da64031f50a27192e34d8e48e08a498a6b8f5974c6c5b464505a16"
        )
    }

    func testIdentityRejectsSymlinkedInputFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("images", isDirectory: true)
        let sparse = root.appendingPathComponent("sparse", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.jpg")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: images.appendingPathComponent("a.jpg"),
            withDestinationURL: outside
        )
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data(name.utf8).write(to: sparse.appendingPathComponent(name))
        }

        XCTAssertThrowsError(
            try MsplatDatasetIdentity.compute(
                imageFiles: [images.appendingPathComponent("a.jpg")],
                sparseDirectory: sparse
            )
        )
    }
}
