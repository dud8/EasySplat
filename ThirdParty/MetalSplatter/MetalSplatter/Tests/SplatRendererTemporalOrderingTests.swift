import Metal
import SplatIO
import simd
import XCTest
@testable import MetalSplatter

/// The temporal gate for `SortOrdering.cameraForwardDepth`.
///
/// Depth ordering renders better than Euclidean on a still image, but the product viewer
/// still selects Euclidean because rotation exposes two distinct problems that a
/// still-image comparison cannot see:
///
/// 1. **Staleness.** A sort requested while another is in flight is dropped, not queued,
///    so the displayed order can belong to an older camera. Euclidean distance is
///    invariant under rotation about the camera centre, so with that key the correct
///    order does not change during a turn and staleness is invisible. Depth ordering
///    does change, so the same lag becomes visible popping.
///
/// 2. **Intrinsic crossing.** Two overlapping splats swap discontinuously when their
///    centre depths cross under rotation, even when the sort is perfectly fresh.
///    Coalescing cannot fix this, and — the reason it needs its own fixture — comparing
///    a frame against a freshly sorted reference cannot detect it either, because the
///    reference contains the same swap.
///
/// These tests characterise both. They are the evidence for whether depth ordering can
/// become the interactive policy, and today they document why it is not.
final class SplatRendererTemporalOrderingTests: XCTestCase {

    // MARK: staleness

    /// A sort requested while one is in flight must not be silently lost: the last
    /// camera asked for is the one whose order should eventually be published.
    func testLatestRequestedCameraEventuallyWins() async throws {
        let renderer = try makeRenderer(ordering: .cameraForwardDepth)
        try load(renderer, points: spread(count: 4_000))

        try await sortFully(renderer, camera: yawed(0))

        // Fire three cameras back to back. Under the current implementation the second
        // and third are dropped while the first sort runs.
        renderer.willRender(viewportCameras: [yawed(0.10)])
        renderer.willRender(viewportCameras: [yawed(0.20)])
        renderer.willRender(viewportCameras: [yawed(0.30)])

        // Settle: keep asking until the renderer stops scheduling work.
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 40_000_000)
            renderer.willRender(viewportCameras: [yawed(0.30)])
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let settled = renderer.orderSnapshotForTesting()
        try await sortFully(renderer, camera: yawed(0.30), force: true)
        let fresh = renderer.orderSnapshotForTesting()

        XCTAssertEqual(
            settled, fresh,
            "after the camera stops moving the published order must converge on the "
            + "final camera; a dropped request that is never retried would leave it stale"
        )
    }

    /// How far the displayed order can lag during a continuous turn, per ordering.
    /// This is the number that decides whether depth ordering is shippable interactively.
    func testRotationLagIsMeasuredForBothOrderings() async throws {
        for ordering in [SplatRenderer.SortOrdering.euclideanCameraDistance, .cameraForwardDepth] {
            let renderer = try makeRenderer(ordering: ordering)
            try load(renderer, points: spread(count: 4_000))

            var mismatchedFrames = 0
            var disagreement = 0.0
            let frames = 24
            for frame in 0..<frames {
                let angle = Float(frame) * 0.05
                renderer.willRender(viewportCameras: [yawed(angle)])
                try await Task.sleep(nanoseconds: 8_000_000)   // ~120 fps request rate
                let displayed = renderer.orderSnapshotForTesting()

                let reference = try makeRenderer(ordering: ordering)
                try load(reference, points: spread(count: 4_000))
                try await sortFully(reference, camera: yawed(angle))
                let fresh = reference.orderSnapshotForTesting()
                if displayed != fresh {
                    mismatchedFrames += 1
                    // Frequency alone conflates a single adjacent swap with a wholesale
                    // reorder, and those are not perceptually alike. Normalised Kendall
                    // distance: the fraction of splat pairs whose relative order differs.
                    disagreement += normalisedInversionDistance(displayed, fresh)
                }
            }
            // Not an assertion on a threshold: Euclidean is invariant under this rotation
            // so it should be near zero, while depth ordering is expected to lag. The
            // test fails only if Euclidean — the shipped interactive policy — is the one
            // that lags, which would mean the rationale for keeping it is wrong.
            if ordering == .euclideanCameraDistance {
                XCTAssertLessThanOrEqual(
                    mismatchedFrames, frames / 4,
                    "Euclidean ordering is rotation-invariant about the camera centre, so "
                    + "it should rarely disagree with a freshly sorted reference during a turn"
                )
            }
            let meanDisagreement = disagreement / Double(frames)
            print(String(
                format: "rotation lag [%@]: %d/%d frames differ from fresh, "
                    + "mean normalised inversion distance %.5f",
                String(describing: ordering), mismatchedFrames, frames, meanDisagreement
            ))
        }
    }

    // MARK: intrinsic crossing

    /// Two overlapping splats whose centre depths cross under a small yaw. Both orders
    /// are freshly sorted, so this isolates the discontinuity that coalescing cannot fix
    /// and that a fresh-reference comparison cannot see.
    func testFreshDepthOrderSwapsWhenCentreDepthsCross() async throws {
        let renderer = try makeRenderer(ordering: .cameraForwardDepth)
        // Two splats at equal distance from the origin but different bearings, so a
        // rotation exchanges which one is nearer along the view axis while leaving their
        // Euclidean distances untouched.
        try load(renderer, points: [
            point(at: SIMD3<Float>(-0.5, 0, -2.0)),
            point(at: SIMD3<Float>(0.5, 0, -2.0)),
        ])

        try await sortFully(renderer, camera: yawed(-0.25))
        let before = renderer.orderSnapshotForTesting()
        try await sortFully(renderer, camera: yawed(0.25), force: true)
        let after = renderer.orderSnapshotForTesting()

        XCTAssertNotEqual(
            before, after,
            "depth ordering must reverse these two splats across the crossing; if it does "
            + "not, this fixture no longer exercises the artifact it was written for"
        )

        // The same rotation must NOT reorder them under Euclidean distance. That
        // asymmetry is the whole reason the interactive viewer keeps Euclidean.
        let euclid = try makeRenderer(ordering: .euclideanCameraDistance)
        try load(euclid, points: [
            point(at: SIMD3<Float>(-0.5, 0, -2.0)),
            point(at: SIMD3<Float>(0.5, 0, -2.0)),
        ])
        try await sortFully(euclid, camera: yawed(-0.25))
        let euclidBefore = euclid.orderSnapshotForTesting()
        try await sortFully(euclid, camera: yawed(0.25), force: true)
        XCTAssertEqual(
            euclidBefore, euclid.orderSnapshotForTesting(),
            "Euclidean distance is unchanged by rotation about the camera centre, so these "
            + "two equidistant splats must keep their order - this is the property that "
            + "masks popping and the reason it is still the interactive default"
        )
    }

    // MARK: helpers

    /// Fraction of splat pairs whose relative order differs between two permutations, via
    /// rank correlation. 0 means identical ordering, 1 means fully reversed. Counting
    /// frames that differ says how often the viewer is wrong; this says how wrong.
    private func normalisedInversionDistance(
        _ a: [SplatRenderer.IndexType],
        _ b: [SplatRenderer.IndexType]
    ) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        var rank = [Int](repeating: 0, count: a.count)
        for (position, index) in b.enumerated() { rank[Int(index)] = position }
        let projected = a.map { rank[Int($0)] }
        // Count inversions in `projected` by merge sort; O(n log n).
        var work = projected
        var scratch = work
        var inversions = 0
        func sortRange(_ lo: Int, _ hi: Int) {
            guard hi - lo > 1 else { return }
            let mid = (lo + hi) / 2
            sortRange(lo, mid); sortRange(mid, hi)
            var i = lo, j = mid, k = lo
            while i < mid || j < hi {
                if j >= hi || (i < mid && work[i] <= work[j]) {
                    scratch[k] = work[i]; i += 1
                } else {
                    inversions += mid - i
                    scratch[k] = work[j]; j += 1
                }
                k += 1
            }
            for index in lo..<hi { work[index] = scratch[index] }
        }
        sortRange(0, work.count)
        let pairs = Double(a.count) * Double(a.count - 1) / 2
        return pairs > 0 ? Double(inversions) / pairs : 0
    }

    private func makeRenderer(ordering: SplatRenderer.SortOrdering) throws -> SplatRenderer {
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
            sortOrdering: ordering
        )
    }

    private func load(_ renderer: SplatRenderer, points: [SplatScenePoint]) throws {
        for point in points {
            try renderer.add(point)
        }
    }

    /// Deterministic by construction. The reference renderer has to hold exactly the
    /// same splats as the one under test, or every frame differs for a trivial reason.
    private func spread(count: Int) -> [SplatScenePoint] {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xFFFF) / Float(0xFFFF) * 4 - 2
        }
        return (0..<count).map { index in
            let t = Float(index) / Float(count)
            return point(at: SIMD3<Float>(next(), next(), -1 - t * 4))
        }
    }

    private func point(at position: SIMD3<Float>) -> SplatScenePoint {
        SplatScenePoint(
            position: position,
            normal: .zero,
            color: .linearUInt8(255, 255, 255),
            opacity: 1,
            scale: .zero,
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }

    /// A view matrix rotated about the camera's own centre, which is exactly the motion
    /// Euclidean ordering is invariant to and depth ordering is not.
    private func yawed(_ radians: Float) -> SplatRenderer.CameraDescriptor {
        let c = cos(radians), s = sin(radians)
        let rotation = simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        return SplatRenderer.CameraDescriptor(
            projectionMatrix: matrix_identity_float4x4,
            viewMatrix: rotation,
            screenSize: SIMD2<Int>(640, 480)
        )
    }

    private func sortFully(
        _ renderer: SplatRenderer,
        camera: SplatRenderer.CameraDescriptor,
        force: Bool = false
    ) async throws {
        let completed = expectation(description: "sort")
        renderer.onSortComplete = { _ in completed.fulfill() }
        // resortIndices() re-sorts against lastScheduledSortCamera, so it cannot be used
        // to sort a camera the renderer has not been shown. Schedule first, always.
        renderer.willRender(viewportCameras: [camera])
        if force {
            renderer.resortIndices()
        }
        await fulfillment(of: [completed], timeout: 5)
        renderer.onSortComplete = nil
    }
}
