import Darwin
import XCTest
@testable import EasySplatCore

final class MsplatOrientationOverlayTests: XCTestCase {
    func testUnresolvedOrientationEncodesExactClosedIdentityDocument() throws {
        let overlay = try MsplatOrientationOverlay(
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
            )
        )

        XCTAssertEqual(
            try overlay.encodedData(),
            Data(#"{"schema_version":1,"source_to_canonical_wxyz":[1,0,0,0]}"#.utf8)
                + Data([0x0A])
        )
    }

    func testResolvedOrientationEncodesItsCanonicalQuaternionAndNoOtherFields() throws {
        let value = 1 / sqrt(2.0)
        let overlay = try MsplatOrientationOverlay(
            canonicalOrientation: orientation(
                status: .verified,
                quaternion: CanonicalQuaternionWXYZ(w: value, x: 0, y: 0, z: value)
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: overlay.encodedData()) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schema_version", "source_to_canonical_wxyz"])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        let quaternion = try XCTUnwrap(object["source_to_canonical_wxyz"] as? [Double])
        XCTAssertEqual(quaternion, [value, 0, 0, value])
    }

    func testAxisAlignedOrientationUsesItsCanonicalQuaternion() throws {
        let overlay = try MsplatOrientationOverlay(
            canonicalOrientation: orientation(
                status: .axisAlignedSignUnverified,
                quaternion: CanonicalQuaternionWXYZ(w: 0, x: 1, y: 0, z: 0)
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: overlay.encodedData()) as? [String: Any]
        )
        XCTAssertEqual(
            object["source_to_canonical_wxyz"] as? [Double],
            [0, 1, 0, 0]
        )
    }

    func testTinyPositiveWRemainsCanonicalRegardlessOfXYZSign() throws {
        let quaternion = CanonicalQuaternionWXYZ(w: 1e-16, x: -1, y: 0, z: 0)

        let overlay = try MsplatOrientationOverlay(
            canonicalOrientation: orientation(
                status: .verified,
                quaternion: quaternion
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: overlay.encodedData()) as? [String: Any]
        )

        XCTAssertEqual(
            object["source_to_canonical_wxyz"] as? [Double],
            [quaternion.w, quaternion.x, quaternion.y, quaternion.z]
        )
    }

    func testResolvedOrientationRejectsMissingNonfiniteNonunitAndNegativeQuaternion() throws {
        let invalid: [CanonicalQuaternionWXYZ?] = [
            nil,
            CanonicalQuaternionWXYZ(w: .nan, x: 0, y: 0, z: 0),
            CanonicalQuaternionWXYZ(w: 2, x: 0, y: 0, z: 0),
            CanonicalQuaternionWXYZ(w: -1, x: 0, y: 0, z: 0),
            CanonicalQuaternionWXYZ(w: -1e-16, x: 1, y: 0, z: 0),
            CanonicalQuaternionWXYZ(w: 0, x: -1, y: 0, z: 0),
        ]

        for quaternion in invalid {
            XCTAssertThrowsError(
                try MsplatOrientationOverlay(
                    canonicalOrientation: orientation(
                        status: .verified,
                        quaternion: quaternion
                    )
                )
            )
        }
    }

    func testEncodingIsDeterministic() throws {
        let value = 1 / sqrt(2.0)
        let artifact = orientation(
            status: .verified,
            quaternion: CanonicalQuaternionWXYZ(w: value, x: 0, y: value, z: 0)
        )

        let first = try MsplatOrientationOverlay(canonicalOrientation: artifact).encodedData()
        let second = try MsplatOrientationOverlay(canonicalOrientation: artifact).encodedData()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.last, 0x0A)
    }

    func testWriterCreatesPrivateOrdinarySingleLinkFileAndReplacesStaleFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(MsplatOrientationOverlay.fileName)
        try Data("stale".utf8).write(to: destination)

        try MsplatOrientationOverlay.write(
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
            ),
            to: root
        )

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

    func testWriterRejectsSymlinkWithoutChangingItsTargetOrLeavingPartialFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        let destination = root.appendingPathComponent(MsplatOrientationOverlay.fileName)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)

        XCTAssertThrowsError(
            try MsplatOrientationOverlay.write(
                canonicalOrientation: .unresolved(
                    openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
                ),
                to: root
            )
        )

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), outside.path)
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
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            } else {
                let outside = root.appendingPathComponent("outside.json")
                try Data("outside".utf8).write(to: outside)
                XCTAssertEqual(link(outside.path, destination.path), 0)
            }

            XCTAssertThrowsError(
                try MsplatOrientationOverlay.write(
                    canonicalOrientation: .unresolved(
                        openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
                    ),
                    to: root
                )
            )
        }
    }

    private func orientation(
        status: CanonicalOrientationStatus,
        quaternion: CanonicalQuaternionWXYZ?
    ) -> CanonicalOrientationArtifact {
        CanonicalOrientationArtifact(
            status: status,
            method: .cameraRightNullspace,
            sourceToCanonicalQuaternionWXYZ: quaternion,
            evidence: nil,
            canonicalOpeningViewDirection: CanonicalDirection(x: 0, y: 0, z: -1),
            isViewOnlyFlipActive: false
        )
    }
}
