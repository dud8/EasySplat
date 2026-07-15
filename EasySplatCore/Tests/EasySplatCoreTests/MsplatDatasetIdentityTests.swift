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
        try identityOverlay.write(
            to: sparse.appendingPathComponent("easysplat_orientation.json")
        )

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
            "ea2d020cd66ae1154c8c0d0e8142d5ab5f08098a80e5e8aa5f7ab34b4768f8bb"
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
        try identityOverlay.write(
            to: sparse.appendingPathComponent("easysplat_orientation.json")
        )

        XCTAssertThrowsError(
            try MsplatDatasetIdentity.compute(
                imageFiles: [images.appendingPathComponent("a.jpg")],
                sparseDirectory: sparse
            )
        )
    }

    func testIdentityRequiresOrientationOverlay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(
            at: fixture.sparse.appendingPathComponent("easysplat_orientation.json")
        )

        XCTAssertThrowsError(
            try MsplatDatasetIdentity.compute(
                imageFiles: fixture.images,
                sparseDirectory: fixture.sparse
            )
        )
    }

    func testGeometryDigestChangesWithOrientationOverlay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identity = try MsplatDatasetIdentity.compute(
            imageFiles: fixture.images,
            sparseDirectory: fixture.sparse
        )
        try Data(
            #"{"schema_version":1,"source_to_canonical_wxyz":[0.7071067811865476,0,0,0.7071067811865476]}"#.utf8
        ).write(to: fixture.sparse.appendingPathComponent("easysplat_orientation.json"))

        let rotated = try MsplatDatasetIdentity.compute(
            imageFiles: fixture.images,
            sparseDirectory: fixture.sparse
        )

        XCTAssertEqual(identity.inputDigest, rotated.inputDigest)
        XCTAssertNotEqual(identity.geometryDigest, rotated.geometryDigest)
    }

    func testIdentityRejectsSymlinkedAndHardLinkedOrientationOverlay() throws {
        for collision in ["symlink", "hard-link"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let overlay = fixture.sparse.appendingPathComponent("easysplat_orientation.json")
            try FileManager.default.removeItem(at: overlay)
            let outside = fixture.root.appendingPathComponent("outside.json")
            try identityOverlay.write(to: outside)
            if collision == "symlink" {
                try FileManager.default.createSymbolicLink(at: overlay, withDestinationURL: outside)
            } else {
                XCTAssertEqual(link(outside.path, overlay.path), 0)
            }

            XCTAssertThrowsError(
                try MsplatDatasetIdentity.compute(
                    imageFiles: fixture.images,
                    sparseDirectory: fixture.sparse
                )
            )
        }
    }

    func testDirectoryIdentityRejectsUnsupportedHiddenAndUnsafeImageEntries() throws {
        for kind in ["unsupported", "hidden", "directory", "symlink", "hard-link"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let images = fixture.images[0].deletingLastPathComponent()
            switch kind {
            case "unsupported":
                try Data("notes".utf8).write(to: images.appendingPathComponent("notes.txt"))
            case "hidden":
                try Data("hidden".utf8).write(to: images.appendingPathComponent(".hidden.jpg"))
            case "directory":
                try FileManager.default.createDirectory(
                    at: images.appendingPathComponent("nested.jpg"),
                    withIntermediateDirectories: false
                )
            case "symlink":
                try FileManager.default.createSymbolicLink(
                    at: images.appendingPathComponent("linked.jpg"),
                    withDestinationURL: fixture.images[0]
                )
            case "hard-link":
                XCTAssertEqual(
                    link(
                        fixture.images[0].path,
                        images.appendingPathComponent("hard-linked.jpg").path
                    ),
                    0
                )
            default:
                XCTFail("Unhandled fixture kind")
            }

            XCTAssertThrowsError(
                try MsplatDatasetIdentity.compute(
                    imageDirectory: images,
                    sparseDirectory: fixture.sparse
                ),
                "Expected \(kind) image entry to be rejected"
            )
        }
    }

    func testDirectoryIdentityAcceptsOnlyPreparedImageFormatsCaseInsensitively() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let images = fixture.images[0].deletingLastPathComponent()
        let uppercase = images.appendingPathComponent("second.PNG")
        try Data("second".utf8).write(to: uppercase)

        let directoryIdentity = try MsplatDatasetIdentity.compute(
            imageDirectory: images,
            sparseDirectory: fixture.sparse
        )
        let explicitIdentity = try MsplatDatasetIdentity.compute(
            imageFiles: [fixture.images[0], uppercase],
            sparseDirectory: fixture.sparse
        )

        XCTAssertEqual(directoryIdentity, explicitIdentity)
    }

    func testIdentitySortsFilenamesByRawUTF8BytesLikeNativeTrainer() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let images = fixture.images[0].deletingLastPathComponent()
        try FileManager.default.removeItem(at: fixture.images[0])
        let composed = try XCTUnwrap(URL(string: images.absoluteString + "%C3%A9.jpg"))
        let decomposedWithSuffix = try XCTUnwrap(
            URL(string: images.absoluteString + "e%CC%81x.jpg")
        )
        try Data("A".utf8).write(to: composed)
        try Data("B".utf8).write(to: decomposedWithSuffix)
        XCTAssertTrue(composed.lastPathComponent < decomposedWithSuffix.lastPathComponent)
        XCTAssertTrue(
            decomposedWithSuffix.lastPathComponent.utf8.lexicographicallyPrecedes(
                composed.lastPathComponent.utf8
            )
        )

        let identity = try MsplatDatasetIdentity.compute(
            imageFiles: [composed, decomposedWithSuffix],
            sparseDirectory: fixture.sparse
        )

        XCTAssertEqual(
            identity.inputDigest,
            "87fd403871f19adcc3aed7af60bc86a52007e5cacf48cf43d717a085c42d973b"
        )
    }

    private var identityOverlay: Data {
        Data(#"{"schema_version":1,"source_to_canonical_wxyz":[1,0,0,0]}"#.utf8)
            + Data([0x0A])
    }

    private func makeFixture() throws -> (root: URL, images: [URL], sparse: URL) {
        let root = try TestFileBuilder.makeTempDir()
        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        let sparse = root.appendingPathComponent("sparse", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        let image = imagesDirectory.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: image)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data(name.utf8).write(to: sparse.appendingPathComponent(name))
        }
        try identityOverlay.write(
            to: sparse.appendingPathComponent("easysplat_orientation.json")
        )
        return (root, [image], sparse)
    }
}
