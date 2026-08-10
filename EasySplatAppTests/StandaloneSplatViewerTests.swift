import XCTest
@testable import EasySplatApp

/// A splat opened from disk has no project manifest, so its scene bounds have to come
/// from the file. These cover that substitution, which is the whole reason the viewer
/// can accept a splat it did not produce.
final class StandaloneSplatViewerTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testBoundsAreDerivedFromTheFileWhenNoManifestExists() throws {
        let url = base.appendingPathComponent("scene.ply")
        try writePly(
            at: url,
            positions: [
                SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(1, 1, -1),
                SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(-1, 1, 1), SIMD3(1, 1, 1),
                SIMD3(0, 0, 0),
            ]
        )

        let configuration = try StandaloneSplatLoad.sceneConfiguration(for: url)

        let bounds = try XCTUnwrap(configuration.bounds)
        XCTAssertEqual(bounds.center.x, 0, accuracy: 0.5)
        XCTAssertEqual(bounds.center.y, 0, accuracy: 0.5)
        XCTAssertEqual(bounds.center.z, 0, accuracy: 0.5)
        XCTAssertGreaterThan(bounds.radius, 0.5)
        XCTAssertTrue(bounds.radius.isFinite)
        XCTAssertNil(configuration.validationError)
    }

    // Without a manifest there is no canonical orientation to honour, so the viewer must
    // fall back to its own framing rather than an upright the file cannot vouch for.
    func testForeignSplatClaimsNoOrientation() throws {
        let url = base.appendingPathComponent("scene.ply")
        try writePly(at: url, positions: [SIMD3(0, 0, 0), SIMD3(1, 1, 1)])

        let configuration = try StandaloneSplatLoad.sceneConfiguration(for: url)

        XCTAssertNil(configuration.openingDirection)
        XCTAssertFalse(configuration.isViewOnlyFlipActive)
    }

    func testFileWithNoGaussiansReportsItPlainly() throws {
        let url = base.appendingPathComponent("empty.ply")
        try writePly(at: url, positions: [])

        XCTAssertThrowsError(try StandaloneSplatLoad.sceneConfiguration(for: url)) { error in
            XCTAssertEqual(error as? StandaloneSplatLoadError, .noPlaceableGeometry)
        }
    }

    func testUnreadableFileSurfacesTheReaderFailureRatherThanEmptyBounds() throws {
        let url = base.appendingPathComponent("scene.ply")
        try Data("not a ply".utf8).write(to: url)

        XCTAssertThrowsError(try StandaloneSplatLoad.sceneConfiguration(for: url))
    }

    func testOnlyPlyIsOfferedForOpening() {
        XCTAssertTrue(SplatFileType.isViewable(URL(fileURLWithPath: "/tmp/a.ply")))
        XCTAssertTrue(SplatFileType.isViewable(URL(fileURLWithPath: "/tmp/a.PLY")))
        XCTAssertFalse(SplatFileType.isViewable(URL(fileURLWithPath: "/tmp/a.spz")))
        XCTAssertTrue(SplatFileType.isSplat(URL(fileURLWithPath: "/tmp/a.spz")))
        XCTAssertFalse(SplatFileType.isSplat(URL(fileURLWithPath: "/tmp/a.jpg")))
    }

    private func writePly(at url: URL, positions: [SIMD3<Float>]) throws {
        let body = positions.map { position in
            "\(position.x) \(position.y) \(position.z) 1 1 1 -4 -4 -4 4 1 0 0 0"
        }.joined(separator: "\n")
        let text = """
        ply
        format ascii 1.0
        element vertex \(positions.count)
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        \(body)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
