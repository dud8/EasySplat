import Metal
import SplatIO
import simd
import XCTest
@testable import MetalSplatter

final class SplatRendererSortTests: XCTestCase {
    func testCompletedSortsPublishDistinctOrderBufferGenerations() async throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 0))
        try renderer.add(makePoint(x: 1))

        let initialBuffer = renderer.orderBuffer.buffer
        try await completeCPUSort(renderer)
        let firstSortedBuffer = renderer.orderBuffer.buffer
        try await completeCPUSort(renderer)
        let secondSortedBuffer = renderer.orderBuffer.buffer
        try await completeCPUSort(renderer)
        let thirdSortedBuffer = renderer.orderBuffer.buffer

        let initialGeneration = bufferIdentity(initialBuffer)
        let firstSortedGeneration = bufferIdentity(firstSortedBuffer)
        let secondSortedGeneration = bufferIdentity(secondSortedBuffer)
        let thirdSortedGeneration = bufferIdentity(thirdSortedBuffer)

        XCTAssertNotEqual(firstSortedGeneration, initialGeneration)
        XCTAssertNotEqual(secondSortedGeneration, initialGeneration)
        XCTAssertNotEqual(secondSortedGeneration, firstSortedGeneration)
        XCTAssertNotEqual(thirdSortedGeneration, initialGeneration)
        XCTAssertNotEqual(thirdSortedGeneration, firstSortedGeneration)
        XCTAssertNotEqual(thirdSortedGeneration, secondSortedGeneration)
    }

    func testSuccessfulReadPublishesIdentityOrderBeforeFirstRender() throws {
        let renderer = try makeRenderer()
        let url = try makePLY(pointCount: 3)

        try renderer.readPLY(from: url)

        XCTAssertEqual(renderer.splatCount, 3)
        XCTAssertEqual(renderer.orderBuffer.count, 3)
        XCTAssertGreaterThanOrEqual(renderer.orderBuffer.capacity, 3)
        XCTAssertEqual(
            Array(UnsafeBufferPointer(start: renderer.orderBuffer.values, count: 3)),
            [0, 1, 2]
        )
    }

    func testResetPublishesANewEmptyOrderBufferGeneration() throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 1))
        let populatedGeneration = bufferIdentity(renderer.orderBuffer.buffer)

        renderer.reset()

        XCTAssertEqual(renderer.splatCount, 0)
        XCTAssertEqual(renderer.orderBuffer.count, 0)
        XCTAssertNotEqual(bufferIdentity(renderer.orderBuffer.buffer), populatedGeneration)
    }

    func testOrderBufferAllocationFailurePreservesLastOrderingAndBalancesCallbacks() async throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 1))
        let originalGeneration = bufferIdentity(renderer.orderBuffer.buffer)
        let originalOrder = Array(
            UnsafeBufferPointer(start: renderer.orderBuffer.values, count: renderer.orderBuffer.count)
        )
        renderer.sortedOrderBufferCapacityLimit = 1
        let completed = expectation(description: "failed sort completed")
        var starts = 0
        var completions = 0
        var failure: SplatRenderer.SortFailure?
        renderer.onSortStart = { starts += 1 }
        renderer.onSortFailure = { failure = $0 }
        renderer.onSortComplete = { _ in
            completions += 1
            completed.fulfill()
        }

        renderer.resortIndicesOnCPU()
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(completions, 1)
        guard case .orderBufferAllocationFailed = failure else {
            return XCTFail("Expected a typed order-buffer allocation failure")
        }
        XCTAssertFalse(renderer.sorting)
        XCTAssertEqual(bufferIdentity(renderer.orderBuffer.buffer), originalGeneration)
        XCTAssertEqual(
            Array(UnsafeBufferPointer(start: renderer.orderBuffer.values, count: renderer.orderBuffer.count)),
            originalOrder
        )
    }

    func testFailedSortCanBeRetriedExplicitlyAndReportsOnlyConfirmedRecovery() async throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 1))
        renderer.sortedOrderBufferCapacityLimit = 1
        let failed = expectation(description: "sort failed")
        var failures = 0
        var successes = 0
        renderer.onSortFailure = { _ in
            failures += 1
            failed.fulfill()
        }
        renderer.onSortSuccess = {
            successes += 1
        }

        renderer.resortIndicesOnCPU()
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(failures, 1)
        XCTAssertEqual(successes, 0)

        renderer.sortedOrderBufferCapacityLimit = nil
        let recovered = expectation(description: "sort recovered")
        renderer.onSortSuccess = {
            successes += 1
            recovered.fulfill()
        }
        renderer.resortIndicesOnCPU()
        await fulfillment(of: [recovered], timeout: 2)

        XCTAssertEqual(failures, 1)
        XCTAssertEqual(successes, 1)
    }

    func testUnchangedCameraDoesNotStartAnotherSortAfterCompletion() async throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 1))
        let camera = makeCamera()
        let firstSort = expectation(description: "first camera sort completed")
        renderer.onSortComplete = { _ in firstSort.fulfill() }

        renderer.willRender(viewportCameras: [camera])
        await fulfillment(of: [firstSort], timeout: 2)

        let duplicateSort = expectation(description: "unchanged camera must not sort again")
        duplicateSort.isInverted = true
        renderer.onSortStart = { duplicateSort.fulfill() }
        renderer.onSortComplete = nil
        renderer.willRender(viewportCameras: [camera])

        await fulfillment(of: [duplicateSort], timeout: 0.15)
    }

    func testChangedCameraStartsANewSortAfterCompletion() async throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 1))
        let firstSort = expectation(description: "first camera sort completed")
        renderer.onSortComplete = { _ in firstSort.fulfill() }
        renderer.willRender(viewportCameras: [makeCamera()])
        await fulfillment(of: [firstSort], timeout: 2)

        let changedSort = expectation(description: "changed camera sort completed")
        renderer.onSortComplete = { _ in changedSort.fulfill() }
        var changedView = matrix_identity_float4x4
        changedView.columns.3.x = 1
        renderer.willRender(viewportCameras: [makeCamera(viewMatrix: changedView)])

        await fulfillment(of: [changedSort], timeout: 2)
    }

    func testSortStartedBeforeResetCannotPublishItsStaleOrder() async throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 1))
        let completed = expectation(description: "stale sort completed")
        var resetOrderBuffer: MTLBuffer?
        renderer.onSortStart = {
            renderer.reset()
            resetOrderBuffer = renderer.orderBuffer.buffer
        }
        renderer.onSortComplete = { _ in completed.fulfill() }

        renderer.resortIndicesOnCPU()
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(renderer.splatCount, 0)
        XCTAssertEqual(renderer.orderBuffer.count, 0)
        XCTAssertEqual(
            bufferIdentity(renderer.orderBuffer.buffer),
            try bufferIdentity(XCTUnwrap(resetOrderBuffer))
        )
    }

    func testCPUSortWorkerUsesCapturedMetalBufferAcrossCapacityGrowth() async throws {
        try await assertSortWorkerUsesCapturedMetalBuffer { renderer in
            renderer.resortIndicesOnCPU()
        }
    }

    private func assertSortWorkerUsesCapturedMetalBuffer(
        start: (SplatRenderer) -> Void
    ) async throws {
        let renderer = try makeRenderer()
        try renderer.add(makePoint(x: -1))
        try renderer.add(makePoint(x: 1))
        let originalBuffer = renderer.splatBuffer.buffer
        let completed = expectation(description: "sort completed after capacity growth")
        let workerBound = expectation(description: "sort worker bound captured buffer")
        var capturedBuffer: MTLBuffer?
        var workerBuffer: MTLBuffer?
        renderer.onSortSnapshotCapturedForTesting = { capturedBuffer = $0 }
        renderer.onSortWorkerBufferBoundForTesting = {
            workerBuffer = $0
            workerBound.fulfill()
        }
        renderer.onSortStart = {
            do {
                try renderer.ensureAdditionalCapacity(100)
            } catch {
                XCTFail("Capacity growth failed: \(error)")
            }
        }
        renderer.onSortComplete = { _ in completed.fulfill() }

        start(renderer)
        await fulfillment(of: [workerBound, completed], timeout: 2)

        XCTAssertEqual(
            bufferIdentity(try XCTUnwrap(capturedBuffer)),
            bufferIdentity(originalBuffer)
        )
        XCTAssertEqual(
            bufferIdentity(try XCTUnwrap(workerBuffer)),
            bufferIdentity(originalBuffer)
        )
        XCTAssertNotEqual(
            bufferIdentity(renderer.splatBuffer.buffer),
            bufferIdentity(originalBuffer)
        )
        XCTAssertEqual(renderer.orderBuffer.count, 2)
    }

    private func completeCPUSort(_ renderer: SplatRenderer) async throws {
        let completed = expectation(description: "CPU sort completed")
        renderer.onSortComplete = { _ in completed.fulfill() }
        renderer.resortIndicesOnCPU()
        await fulfillment(of: [completed], timeout: 2)
        renderer.onSortComplete = nil
    }

    private func makeRenderer() throws -> SplatRenderer {
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
            maxSimultaneousRenders: 3,
            maximumSplatCount: nil,
            // These fixtures assert scheduling and failure handling, which both orderings
            // share; the ordering-specific behaviour has its own suite.
            sortOrdering: .cameraForwardDepth
        )
    }

    private func makePoint(x: Float) -> SplatScenePoint {
        SplatScenePoint(
            position: SIMD3<Float>(x, 0, 0),
            normal: .zero,
            color: .linearUInt8(255, 255, 255),
            opacity: 1,
            scale: .zero,
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }

    private func makeCamera(
        viewMatrix: simd_float4x4 = matrix_identity_float4x4
    ) -> SplatRenderer.CameraDescriptor {
        SplatRenderer.CameraDescriptor(
            projectionMatrix: matrix_identity_float4x4,
            viewMatrix: viewMatrix,
            screenSize: SIMD2<Int>(640, 480)
        )
    }

    private func bufferIdentity(_ buffer: MTLBuffer) -> ObjectIdentifier {
        ObjectIdentifier(buffer as AnyObject)
    }

    private func makePLY(pointCount: Int) throws -> URL {
        let rows = (0..<pointCount).map { index in
            "\(index) 0 0 255 255 255 0 0 0 1 1 0 0 0"
        }.joined(separator: "\n")
        let contents = """
        ply
        format ascii 1.0
        element vertex \(pointCount)
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
        \(rows)
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sort-fixture.ply")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
    }
}
