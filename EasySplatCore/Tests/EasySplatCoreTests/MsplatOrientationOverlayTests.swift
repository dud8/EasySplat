import Darwin
import XCTest
@testable import EasySplatCore

final class MsplatOrientationOverlayTests: XCTestCase {
    func testBridgeEncodesOnlyClosedIdentityDocument() throws {
        XCTAssertEqual(
            try MsplatOrientationOverlay().encodedData(),
            Data(#"{"schema_version":1,"source_to_canonical_wxyz":[1,0,0,0]}"#.utf8)
                + Data([0x0A])
        )
    }

    func testWriterCreatesPrivateOrdinarySingleLinkFileAndReplacesStaleFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(MsplatOrientationOverlay.fileName)
        try Data("stale".utf8).write(to: destination)

        try MsplatOrientationOverlay.writeIdentity(to: root)

        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data(#"{"schema_version":1,"source_to_canonical_wxyz":[1,0,0,0]}"#.utf8)
                + Data([0x0A])
        )
        var status = stat()
        XCTAssertEqual(lstat(destination.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(status.st_nlink, 1)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasPrefix(".easysplat-orientation-") }
        )
    }

    func testWriterRejectsSymlinkWithoutChangingTargetOrLeavingPartialFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        let destination = root.appendingPathComponent(MsplatOrientationOverlay.fileName)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)

        XCTAssertThrowsError(try MsplatOrientationOverlay.writeIdentity(to: root))

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            outside.path
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [
            MsplatOrientationOverlay.fileName,
            "outside.json",
        ])
    }

    func testWriterRejectsDirectoryAndHardLinkCollisions() throws {
        for collision in ["directory", "hard-link"] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent(MsplatOrientationOverlay.fileName)
            if collision == "directory" {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            } else {
                let outside = root.appendingPathComponent("outside.json")
                try Data("outside".utf8).write(to: outside)
                XCTAssertEqual(link(outside.path, destination.path), 0)
            }

            XCTAssertThrowsError(try MsplatOrientationOverlay.writeIdentity(to: root))
        }
    }
}
