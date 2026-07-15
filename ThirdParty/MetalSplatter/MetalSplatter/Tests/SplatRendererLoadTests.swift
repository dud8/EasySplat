import Metal
import SplatIO
import simd
import XCTest
@testable import MetalSplatter

final class SplatRendererLoadTests: XCTestCase {
    func testAddPropagatesCapacityFailure() throws {
        let renderer = try makeRenderer(maximumSplatCount: 1)
        let point = makePoint()
        try renderer.add(point)

        XCTAssertThrowsError(try renderer.add(point))
        XCTAssertEqual(renderer.splatCount, 1)
    }

    func testReadPLYDoesNotPublishPartialSplatWhenCapacityFails() throws {
        let renderer = try makeRenderer(maximumSplatCount: 1)
        let url = try makePLY(
            declaredPointCount: 2,
            body: """
            0 0 0 255 255 255 0 0 0 1 1 0 0 0
            1 1 1 255 255 255 0 0 0 1 1 0 0 0
            """
        )

        XCTAssertThrowsError(try renderer.readPLY(from: url))
        XCTAssertEqual(renderer.splatCount, 0)
    }

    func testReadPLYDoesNotPublishPointsFromMalformedFile() throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint())
        let originalCount = renderer.splatCount
        let url = try makePLY(
            declaredPointCount: 2,
            body: """
            0 0 0 255 255 255 0 0 0 1 1 0 0 0
            1 1 1 255 255 255 0 0 0 1 1 0 0
            """
        )

        XCTAssertThrowsError(try renderer.readPLY(from: url))
        XCTAssertEqual(renderer.splatCount, originalCount)
    }

    func testReadPLYPropagatesCooperativeCancellationWithoutPublishing() throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint())
        let originalCount = renderer.splatCount
        let url = try makePLY(
            declaredPointCount: 1,
            body: "0 0 0 255 255 255 0 0 0 1 1 0 0 0"
        )
        let probe = CancellationProbe()

        XCTAssertThrowsError(
            try renderer.readPLY(
                from: url,
                shouldCancel: { probe.cancelOnCheck() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(probe.wasChecked)
        XCTAssertEqual(renderer.splatCount, originalCount)
    }

    private func makeRenderer(maximumSplatCount: Int? = nil) throws -> SplatRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        return try SplatRenderer(
            device: device,
            colorFormat: .bgra8Unorm,
            depthFormat: .depth32Float_stencil8,
            stencilFormat: .depth32Float_stencil8,
            sampleCount: 1,
            maxViewCount: 1,
            maxSimultaneousRenders: 1,
            maximumSplatCount: maximumSplatCount
        )
    }

    private func makePoint() -> SplatScenePoint {
        SplatScenePoint(
            position: .zero,
            normal: .zero,
            color: .linearUInt8(255, 255, 255),
            opacity: 1,
            scale: .zero,
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }

    private func makePLY(declaredPointCount: Int, body: String) throws -> URL {
        let contents = """
        ply
        format ascii 1.0
        element vertex \(declaredPointCount)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test.ply")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checked = false

    var wasChecked: Bool {
        lock.withLock { checked }
    }

    func cancelOnCheck() -> Bool {
        lock.withLock {
            checked = true
            return true
        }
    }
}
