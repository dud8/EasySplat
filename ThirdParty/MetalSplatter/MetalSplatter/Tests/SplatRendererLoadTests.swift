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

    func testAddRejectsNonFiniteHigherOrderCoefficientWithoutPublishing() throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint())
        let originalSplats = bufferIdentity(renderer.splatBuffer.buffer)
        let originalOrder = bufferIdentity(renderer.orderBuffer.buffer)

        XCTAssertThrowsError(try renderer.add(makeSH3Point(restValue: .nan)))

        XCTAssertEqual(renderer.splatCount, 1)
        XCTAssertEqual(bufferIdentity(renderer.splatBuffer.buffer), originalSplats)
        XCTAssertEqual(bufferIdentity(renderer.orderBuffer.buffer), originalOrder)
    }

    func testAddRejectsHigherOrderCoefficientThatOverflowsFloat16WithoutPublishing() throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint())
        let originalSplats = bufferIdentity(renderer.splatBuffer.buffer)
        let originalOrder = bufferIdentity(renderer.orderBuffer.buffer)

        XCTAssertThrowsError(try renderer.add(makeSH3Point(restValue: 70_000)))

        XCTAssertEqual(renderer.splatCount, 1)
        XCTAssertEqual(bufferIdentity(renderer.splatBuffer.buffer), originalSplats)
        XCTAssertEqual(bufferIdentity(renderer.orderBuffer.buffer), originalOrder)
    }

    func testReadPLYRejectsUnrepresentableHigherOrderCoefficientWithoutPublishing() throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint())
        let originalSplats = bufferIdentity(renderer.splatBuffer.buffer)
        let originalOrder = bufferIdentity(renderer.orderBuffer.buffer)
        let url = try makeSphericalHarmonicPLY(restValue: "70000")

        XCTAssertThrowsError(try renderer.readPLY(from: url))

        XCTAssertEqual(renderer.splatCount, 1)
        XCTAssertEqual(bufferIdentity(renderer.splatBuffer.buffer), originalSplats)
        XCTAssertEqual(bufferIdentity(renderer.orderBuffer.buffer), originalOrder)
    }

    func testAddRejectsUnencodableGeometryWithoutPublishing() throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint())
        let originalSplats = bufferIdentity(renderer.splatBuffer.buffer)
        let originalOrder = bufferIdentity(renderer.orderBuffer.buffer)

        var overflowingScale = makePoint()
        overflowingScale.scale.x = 100
        XCTAssertThrowsError(try renderer.add(overflowingScale))

        var unrepresentableCovariance = makePoint()
        unrepresentableCovariance.scale.x = log(sqrt(66_000))
        XCTAssertThrowsError(try renderer.add(unrepresentableCovariance))

        for magnitude: Float in [0, 1e-10] {
            var degenerateRotation = makePoint()
            degenerateRotation.rotation = simd_quatf(real: magnitude, imag: .zero)
            XCTAssertThrowsError(try renderer.add(degenerateRotation))
        }

        XCTAssertEqual(renderer.splatCount, 1)
        XCTAssertEqual(bufferIdentity(renderer.splatBuffer.buffer), originalSplats)
        XCTAssertEqual(bufferIdentity(renderer.orderBuffer.buffer), originalOrder)
    }

    func testAddAcceptsLargestRepresentableCovarianceBoundary() throws {
        let renderer = try makeRenderer()
        var point = makePoint()
        point.scale = SIMD3<Float>(repeating: log(sqrt(65_000)))

        try renderer.add(point)

        XCTAssertEqual(renderer.splatCount, 1)
        let encoded = renderer.splatBuffer.values[0]
        XCTAssertTrue(encoded.covA.x.isFinite)
        XCTAssertTrue(encoded.covA.y.isFinite)
        XCTAssertTrue(encoded.covA.z.isFinite)
        XCTAssertTrue(encoded.covB.x.isFinite)
        XCTAssertTrue(encoded.covB.y.isFinite)
        XCTAssertTrue(encoded.covB.z.isFinite)
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

    private func makeSH3Point(restValue: Float) -> SplatScenePoint {
        SplatScenePoint(
            position: .zero,
            normal: .zero,
            color: .sphericalHarmonic(0, 0, 0, Array(repeating: restValue, count: 45)),
            opacity: 1,
            scale: .zero,
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }

    private func bufferIdentity(_ buffer: MTLBuffer) -> ObjectIdentifier {
        ObjectIdentifier(buffer as AnyObject)
    }

    private func makeSphericalHarmonicPLY(restValue: String) throws -> URL {
        let restProperties = (0..<45).map { "property float f_rest_\($0)" }.joined(separator: "\n")
        let restValues = Array(repeating: restValue, count: 45).joined(separator: " ")
        let contents = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        \(restProperties)
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 0 0 0 \(restValues) 0 0 0 1 1 0 0 0
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sh3-test.ply")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
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
