import Metal
import SplatIO
import simd
import XCTest
@testable import MetalSplatter

final class SplatRendererLoadTests: XCTestCase {
    func testViewerLoadRetryabilityDistinguishesLivePressureFromPermanentCapacity() {
        XCTAssertFalse(
            SplatRenderer.isRetryableLoadError(
                SplatRenderer.ViewerMemoryAdmissionError.invalidBudget(-1)
            )
        )
        XCTAssertFalse(
            SplatRenderer.isRetryableLoadError(
                SplatRenderer.ViewerMemoryAdmissionError.invalidSplatCapacity(0)
            )
        )
        XCTAssertFalse(
            SplatRenderer.isRetryableLoadError(
                SplatRenderer.ViewerMemoryAdmissionError.arithmeticOverflow(pointCount: Int.max)
            )
        )
        XCTAssertTrue(
            SplatRenderer.isRetryableLoadError(
                SplatRenderer.ViewerMemoryAdmissionError.budgetExceeded(
                    pointCount: 100,
                    requiredBytes: 1_000,
                    budgetBytes: 500
                )
            )
        )
        XCTAssertFalse(
            SplatRenderer.isRetryableLoadError(
                SplatRenderer.ViewerMemoryAdmissionError.permanentCapacityExceeded(
                    pointCount: 100,
                    requiredBytes: 1_000,
                    maximumRecoverableBytes: 750
                )
            )
        )
    }

    func testRendererInitializationFailuresNeverOfferADeadRetry() {
        let failures: [SplatRenderer.InitializationError] = [
            .shaderLibraryUnavailable("Shaders.metallib is missing"),
            .missingShaderFunction("splatVertexShader"),
            .renderPipelineUnavailable("unsupported pixel format"),
        ]

        for failure in failures {
            XCTAssertFalse(SplatRenderer.isRetryableLoadError(failure))
        }
    }

    func testFullSphericalHarmonicWorkingSetModelAccountsForEveryProductionSortAllocation() throws {
        let geometryBytes = MemoryLayout<SplatRenderer.Splat>.stride
        let sphericalHarmonicBytes = 16 * MemoryLayout<SplatRenderer.PackedHalf3>.stride
        let orderBytes = 2 * MemoryLayout<SplatRenderer.IndexType>.stride
        let cpuSortBytes = 2 * MemoryLayout<SplatRenderer.SplatIndexAndDepth>.stride
        let bytesPerSplat = geometryBytes + sphericalHarmonicBytes + orderBytes + cpuSortBytes
        XCTAssertEqual(
            SplatRenderer.ViewerMemoryModel.bytesPerFullSphericalHarmonicSplat,
            bytesPerSplat
        )
        XCTAssertEqual(
            try SplatRenderer.ViewerMemoryModel.requiredBytes(forPointCount: 2),
            SplatRenderer.ViewerMemoryModel.fixedReserveBytes
                + 2 * SplatRenderer.ViewerMemoryModel.bytesPerFullSphericalHarmonicSplat
        )
    }

    func testFullSphericalHarmonicWorkingSetModelRejectsOverflow() {
        XCTAssertThrowsError(
            try SplatRenderer.ViewerMemoryModel.requiredBytes(forPointCount: Int.max)
        ) { error in
            XCTAssertTrue(error is SplatRenderer.ViewerMemoryAdmissionError)
        }
    }

    func testFullSphericalHarmonicWorkingSetModelRejectsFixedReserveOverflow() {
        let largestPointCountBeforeReserve =
            (Int.max - SplatRenderer.ViewerMemoryModel.fixedReserveBytes)
            / SplatRenderer.ViewerMemoryModel.bytesPerFullSphericalHarmonicSplat

        XCTAssertThrowsError(
            try SplatRenderer.ViewerMemoryModel.requiredBytes(
                forPointCount: largestPointCountBeforeReserve + 1
            )
        ) { error in
            guard case let SplatRenderer.ViewerMemoryAdmissionError.arithmeticOverflow(pointCount) = error else {
                return XCTFail("Expected fixed-reserve addition overflow")
            }
            XCTAssertEqual(pointCount, largestPointCountBeforeReserve + 1)
        }
    }

    func testFullSphericalHarmonicWorkingSetAdmissionIsInclusiveAtTheBudgetBoundary() throws {
        let required = try SplatRenderer.ViewerMemoryModel.requiredBytes(forPointCount: 4_000_000)

        XCTAssertNoThrow(
            try SplatRenderer.ViewerMemoryModel.admit(
                pointCount: 4_000_000,
                budgetBytes: required
            )
        )
        XCTAssertThrowsError(
            try SplatRenderer.ViewerMemoryModel.admit(
                pointCount: 4_000_000,
                budgetBytes: required - 1
            )
        ) { error in
            guard case let SplatRenderer.ViewerMemoryAdmissionError.budgetExceeded(
                pointCount,
                requiredBytes,
                budgetBytes
            ) = error else {
                return XCTFail("Expected a typed viewer-memory budget failure")
            }
            XCTAssertEqual(pointCount, 4_000_000)
            XCTAssertEqual(requiredBytes, required)
            XCTAssertEqual(budgetBytes, required - 1)
        }
    }

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

        XCTAssertThrowsError(try renderer.readPLY(from: url)) { error in
            guard case let SplatRenderer.ViewerMemoryAdmissionError.permanentCapacityExceeded(
                pointCount,
                requiredBytes,
                maximumRecoverableBytes
            ) = error else {
                return XCTFail("Expected deterministic renderer-capacity rejection")
            }
            XCTAssertEqual(pointCount, 2)
            XCTAssertGreaterThan(requiredBytes, maximumRecoverableBytes)
            XCTAssertFalse(SplatRenderer.isRetryableLoadError(error))
        }
        XCTAssertEqual(renderer.splatCount, 0)
    }

    func testHeaderAdmissionFailureStopsBodyDeliveryAndPreservesTypedError() throws {
        let renderer = try makeRenderer(maximumSplatCount: 1)
        var deliveredBodyCount = 0

        XCTAssertThrowsError(
            try renderer.readScene(shouldCancel: { false }) { delegate, shouldStop in
                delegate.didStartReading(withPointCount: 2)
                XCTAssertTrue(shouldStop())
                if !shouldStop() {
                    deliveredBodyCount += 1
                    delegate.didRead(points: [makePoint()])
                }
                delegate.didFailReading(withError: CancellationError())
            }
        ) { error in
            guard case let SplatRenderer.ViewerMemoryAdmissionError.permanentCapacityExceeded(
                pointCount,
                requiredBytes,
                maximumRecoverableBytes
            ) = error else {
                return XCTFail("Expected the original renderer-capacity rejection")
            }
            XCTAssertEqual(pointCount, 2)
            XCTAssertGreaterThan(requiredBytes, maximumRecoverableBytes)
        }
        XCTAssertEqual(deliveredBodyCount, 0)
        XCTAssertEqual(renderer.splatCount, 0)
    }

    func testRendererRejectsNonpositiveExplicitCapacity() throws {
        for pointCount in [-1, 0] {
            XCTAssertThrowsError(try makeRenderer(maximumSplatCount: pointCount)) { error in
                XCTAssertEqual(
                    error as? SplatRenderer.ViewerMemoryAdmissionError,
                    .invalidSplatCapacity(pointCount)
                )
                XCTAssertFalse(SplatRenderer.isRetryableLoadError(error))
            }
        }
    }

    func testExplicitCapacityAboveDeviceLimitIsClampedBeforeFullSHAllocation() throws {
        let renderer = try makeRenderer(maximumSplatCount: Int.max)
        let url = try makeSphericalHarmonicPLY(restValue: "0")

        XCTAssertNoThrow(try renderer.readPLY(from: url))
        XCTAssertEqual(renderer.splatCount, 1)
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

        XCTAssertThrowsError(try renderer.readPLY(from: url)) { error in
            XCTAssertFalse(SplatRenderer.isRetryableLoadError(error))
        }
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
            XCTAssertFalse(SplatRenderer.isRetryableLoadError(error))
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

        XCTAssertThrowsError(try renderer.readPLY(from: url)) { error in
            XCTAssertFalse(SplatRenderer.isRetryableLoadError(error))
        }

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
