#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class Da3LearnedPointInitializerTests: XCTestCase {
    func testMergeAppendsValidatedUntrackedPointsWithFreshIDs() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let learned = root.appendingPathComponent("learned_points3D.txt")
        let canonical = root.appendingPathComponent("points3D.txt")
        try """
        # learned points
        1 1.0 2.0 3.0 10 20 30 -1.0
        2 4.0 5.0 6.0 40 50 60 -1.0

        """.write(to: learned, atomically: true, encoding: .utf8)
        try """
        # classical points
        7 0 0 1 255 255 255 0.2 1 0 2 0

        """.write(to: canonical, atomically: true, encoding: .utf8)

        let count = try Da3LearnedPointInitializer.merge(
            learnedPointsURL: learned,
            into: canonical,
            expectedPointCount: 2,
            maximumPointCount: 10
        )

        XCTAssertEqual(count, 2)
        let rows = try String(contentsOf: canonical, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[1].hasPrefix("8 1.0 2.0 3.0 10 20 30 -1.0"))
        XCTAssertTrue(rows[2].hasPrefix("9 4.0 5.0 6.0 40 50 60 -1.0"))
    }

    func testValidationRejectsTracksNonSequentialIDsAndCountMismatch() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let learned = root.appendingPathComponent("learned_points3D.txt")

        for contents in [
            "2 1 2 3 10 20 30 -1\n",
            "1 1 2 3 10 20 30 -1 4 0\n",
            "1 nan 2 3 10 20 30 -1\n",
        ] {
            try contents.write(to: learned, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try Da3LearnedPointInitializer.validate(
                learnedPointsURL: learned,
                expectedPointCount: 1,
                maximumPointCount: 10
            ))
        }

        try "1 1 2 3 10 20 30 -1\n".write(to: learned, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Da3LearnedPointInitializer.validate(
            learnedPointsURL: learned,
            expectedPointCount: 2,
            maximumPointCount: 10
        ))
    }

    func testValidationRejectsCoordinatesThatOverflowNativeDistanceMath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let learned = root.appendingPathComponent("learned_points3D.txt")
        try "1 1e30 0 0 10 20 30 -1\n".write(
            to: learned,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try Da3LearnedPointInitializer.validate(
            learnedPointsURL: learned,
            expectedPointCount: 1,
            maximumPointCount: 1
        ))
    }

    func testValidationBindsTheExactInitializerBytes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let learned = root.appendingPathComponent("learned_points3D.txt")
        try "1 1 2 3 10 20 30 -1\n".write(
            to: learned,
            atomically: true,
            encoding: .utf8
        )
        let accepted = try Da3LearnedPointInitializer.inspect(
            learnedPointsURL: learned,
            expectedPointCount: 1,
            maximumPointCount: 1
        )
        try "1 9 8 7 10 20 30 -1\n".write(
            to: learned,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try Da3LearnedPointInitializer.validate(
            learnedPointsURL: learned,
            expectedPointCount: 1,
            maximumPointCount: 1,
            expectedSHA256: accepted.sha256
        )) { error in
            XCTAssertEqual(error as? Da3LearnedPointInitializer.Error, .digestMismatch)
        }
    }
}
#endif
