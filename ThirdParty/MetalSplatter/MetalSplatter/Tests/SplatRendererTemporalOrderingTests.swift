import Metal
import SplatIO
import simd
import XCTest
@testable import MetalSplatter

/// The temporal gate for `SortOrdering.cameraForwardDepth`.
///
/// Depth ordering is what the trainer's own rasterizer keys on, and rendering a fixed PLY
/// with it recovers most of the viewer-to-trainer gap. The interactive viewer selected
/// Euclidean anyway, because rotation exposes something a still frame cannot show: the sort
/// runs asynchronously and a request arriving while one is in flight is dropped, so the order
/// a frame composites can belong to an older camera. Euclidean distance does not change under
/// rotation about the camera centre, so with that key a stale order is still the right order.
///
/// These tests are what withdrew that argument. The invariance is real but narrow: it holds
/// for a rotation about the eye and for nothing else. Both motions are measured here because
/// the viewer performs both -- its primary drag and its arrow keys `orbit`, which moves the
/// camera and leaves neither key invariant, while a secondary or Control drag is the
/// `freeLook` the invariance covers. Under an orbit the two orderings cost the same to within
/// noise; under a free look Euclidean is cheaper and depth still renders better, which is the
/// trade the numbers below price.
///
/// The first version of this gate measured *permutations* -- the share of splat pairs the
/// displayed order got wrong. That statistic cannot decide the question. Two splats whose
/// footprints never overlap may sit in either order without moving a single pixel, and rank
/// correlation counts that as an error; one swap between two large overlapping splats
/// repaints a wide area and counts the same as the invisible one. What ships is a picture,
/// so the gate measures pictures.
///
/// It also measures them deterministically. Racing the real sorter against a real frame
/// clock produced a number that moved with machine load -- 1/24 frames on a quiet host and
/// 10/24 with two training runs competing -- which is unusable as a gate. Staleness is
/// therefore imposed rather than raced: the displayed order is the one belonging to the
/// camera `k` frames back, and the measurement is the error-versus-lag curve. How much lag
/// actually occurs is a scheduling question, and it is measured where scheduling lives.
final class SplatRendererTemporalOrderingTests: XCTestCase {

    /// Frames of a continuous turn, and the lags whose cost is measured at each frame.
    private enum Turn {
        static let frames = 20
        static let radiansPerFrame: Float = 0.012   // about 83 deg/s at 120 Hz
        // A real scene is not the 2000 splats this fixture holds, and the lag it will see is
        // whatever a sort of a million-splat scene costs against the frame period. Measuring
        // out to 8 frames keeps the curve useful for lags this fixture is too small to
        // produce on its own.
        static let lags = [1, 2, 4, 8]
        static let width = 320
        static let height = 240
        // A trained scene sorts slowly enough that its realistic lag is tens of frames, so
        // the real-scene sweep needs a longer turn and a wider range to reach it.
        static let realFrames = 40
        static let realLags = [1, 2, 4, 8, 16, 32]
    }

    /// Exact histogram over absolute channel error, counted in 8-bit codes -- one bin per
    /// code, so nothing is approximated. A worst-pixel figure on its own cannot distinguish
    /// one stray pixel from half the screen; these can. Codes rather than floats because
    /// both quantities being measured are differences of quantised values, and integers keep
    /// the inner loop free of allocation.
    private final class Histogram {
        private var counts = [Int](repeating: 0, count: 512)
        private(set) var maximumCode = 0
        private var total = 0

        func add(_ code: Int) {
            if code > maximumCode { maximumCode = code }
            counts[code] += 1
            total += 1
        }

        var maximum: Double { Double(maximumCode) / 255 }

        func quantile(_ fraction: Double) -> Double {
            guard total > 0 else { return 0 }
            let target = Int((1 - fraction) * Double(total))
            var seen = 0
            for bin in stride(from: counts.count - 1, through: 0, by: -1) {
                seen += counts[bin]
                if seen > target { return Double(bin) / 255 }
            }
            return 0
        }

        func fractionAtLeast(codes threshold: Int) -> Double {
            guard total > 0 else { return 0 }
            return Double(counts[threshold...].reduce(0, +)) / Double(total)
        }
    }

    // MARK: the gate

    /// The cost of a stale draw order, in the pixels a viewer would actually see.
    ///
    /// Euclidean must be exactly free: its key does not change under this rotation, so an
    /// order from four frames ago is bit-identical to a fresh one and no lag can cost
    /// anything. That is asserted, because if it ever fails the reason the viewer keeps
    /// Euclidean is wrong. Depth is measured and reported: those numbers are what a
    /// promotion decision weighs, and pinning a threshold here before the decision is taken
    /// would be inventing the answer.
    func testStaleOrderCostIsMeasuredInRenderedPixels() async throws {
        let harness = try Harness()
        var report: [String] = []

        for ordering in [SplatRenderer.SortOrdering.euclideanCameraDistance, .cameraForwardDepth] {
            let renderer = try harness.makeRenderer(ordering: ordering)
            try harness.load(renderer, points: Harness.overlappingCloud(count: 2_000))
            let cameras = (0..<Turn.frames).map {
                Harness.yawed(Float($0) * Turn.radiansPerFrame)
            }

            for measurement in try await staleOrderCost(
                harness, renderer, cameras: cameras,
                cadences: Turn.lags.map { .constantLag($0) } + Turn.lags.map { .sampleAndHold($0) }
            ) {
                report.append("  " + String(describing: ordering) + " " + measurement.summary)
                if ordering == .euclideanCameraDistance {
                    XCTAssertEqual(
                        measurement.worstStaleness, 0, accuracy: 1e-9,
                        "Euclidean ordering does not change under rotation about the camera "
                        + "centre, so a draw order \(measurement.lag) frames old must render "
                        + "the same picture as a fresh one; if it does not, the property the "
                        + "interactive viewer relies on has been broken"
                    )
                }
            }
        }

        print("stale-order cost over a \(Turn.frames)-frame turn "
              + "(\(Turn.width)x\(Turn.height), bgra8Unorm, 2000 overlapping splats):")
        report.forEach { print($0) }
    }

    /// The same measurement on a real reconstruction, which is the one a promotion decision
    /// should actually weigh. The synthetic cloud is a deliberate stress case -- random
    /// saturated colours at high opacity, so every swap repaints -- whereas splats that
    /// describe one real surface tend to agree with their neighbours, and a trained scene
    /// carries a million of them rather than two thousand, so its sort is slow enough that
    /// the lag itself is larger. Those two pull in opposite directions and neither can be
    /// guessed, so the test also times a sort and reports the lag that follows from it.
    ///
    /// Skipped unless `EASYSPLAT_TEMPORAL_GATE_PLY` names a trained PLY; the suite must not
    /// depend on a dataset.
    func testStaleOrderCostOnARealScene() async throws {
        guard let path = ProcessInfo.processInfo.environment["EASYSPLAT_TEMPORAL_GATE_PLY"] else {
            throw XCTSkip("set EASYSPLAT_TEMPORAL_GATE_PLY to a trained PLY to measure a real scene")
        }
        let harness = try Harness()
        let size = SIMD2(960, 720)
        var report: [String] = []
        var orbitCost: [String: StaleOrderCost] = [:]
        var freeLookCost: [String: StaleOrderCost] = [:]

        for ordering in [SplatRenderer.SortOrdering.euclideanCameraDistance, .cameraForwardDepth] {
            let renderer = try harness.makeRenderer(ordering: ordering)
            try renderer.readPLY(from: URL(fileURLWithPath: path))

            let bounds = harness.sceneBounds(renderer)
            // Stand back far enough for the scene to fill the frame, then turn on the spot.
            let eye = bounds.centre + SIMD3<Float>(0, 0, bounds.radius * 1.1)
            let cameras = (0..<Turn.realFrames).map {
                Harness.yawed(
                    Float($0) * Turn.radiansPerFrame,
                    at: eye,
                    size: size,
                    far: bounds.radius * 8
                )
            }
            // The motion the invariance argument does not cover. Same angular rate, but the
            // camera position moves, so neither key is invariant.
            let orbit = (0..<Turn.realFrames).map {
                Harness.orbited(
                    Float($0) * Turn.radiansPerFrame,
                    centre: bounds.centre,
                    radius: bounds.radius * 1.1,
                    size: size,
                    far: bounds.radius * 8
                )
            }

            let sortSeconds = try await sortDuration(renderer, cameras: cameras)
            report.append(String(
                format: "  %@: %d splats, sort %.1f ms -> %d frames of lag at 60 Hz, %d at 120 Hz",
                String(describing: ordering), renderer.splatCount, sortSeconds * 1000,
                Int(ceil(sortSeconds * 60)), Int(ceil(sortSeconds * 120))
            ))
            for measurement in try await staleOrderCost(
                harness, renderer, cameras: orbit,
                cadences: [.constantLag(1), .sampleAndHold(1), .sampleAndHold(4), .sampleAndHold(16)]
            ) {
                report.append("  " + String(describing: ordering) + " ORBIT " + measurement.summary)
                if measurement.isHold, measurement.lag == 1 {
                    orbitCost[String(describing: ordering)] = measurement
                }
            }
            let intrinsic = try await intrinsicPop(harness, renderer, cameras: orbit)
            report.append(String(
                format: "  %@ ORBIT intrinsic pop, fresh sort every frame: p99.9 %.4f worst %.4f",
                String(describing: ordering), intrinsic.p999, intrinsic.worst
            ))
            for measurement in try await staleOrderCost(
                harness, renderer, cameras: cameras,
                cadences: Turn.realLags.map { .constantLag($0) }
                    + Turn.realLags.map { .sampleAndHold($0) }
            ) {
                report.append("  " + String(describing: ordering) + " " + measurement.summary)
                if measurement.isHold, measurement.lag == 1 {
                    freeLookCost[String(describing: ordering)] = measurement
                }
                if ordering == .euclideanCameraDistance {
                    // Not exactly zero here, unlike the synthetic fixture, and not for the
                    // reason first recorded. The sorter is a total order now, so ties are
                    // not the cause. The camera position is recovered by inverting the view
                    // matrix, and that inverse is not bit-stable as the matrix rotates -- a
                    // 40-frame yaw about the eye produces 16 distinct positions. The
                    // Euclidean key moves in its last bits, which reorders near-ties. The
                    // churn is not staleness -- it does not grow with lag -- and at 0.001%
                    // of channels it is not worth trading a general matrix inverse for an
                    // assumption of rigidity, but it is the reason this is a bound and not
                    // an equality.
                    XCTAssertLessThan(
                        measurement.visibleShare, 0.0005,
                        "Euclidean ordering does not change under rotation about the camera "
                        + "centre, so at lag \(measurement.lag) essentially no channel should "
                        + "move; a visible share this large means real staleness, not the "
                        + "tie-breaking churn this bound allows for"
                    )
                }
            }
        }

        print("stale-order cost on \((path as NSString).lastPathComponent) "
              + "(\(size.x)x\(size.y), bgra8Unorm):")
        report.forEach { print($0) }

        // Regression bounds, not perceptual thresholds. They were set from the 2026-07-28
        // measurement and cannot have justified the decision that measurement informed; their
        // job is to fail if a later change makes depth ordering materially worse than it was.
        // Stated as a ratio against Euclidean rather than an absolute, because Euclidean is
        // the alternative actually on offer -- the question a viewer default has to answer is
        // not "is this invisible" but "is this worse than what it replaces".
        let euclidean = String(describing: SplatRenderer.SortOrdering.euclideanCameraDistance)
        let depth = String(describing: SplatRenderer.SortOrdering.cameraForwardDepth)
        if let reference = orbitCost[euclidean], let candidate = orbitCost[depth] {
            XCTAssertLessThanOrEqual(
                candidate.visibleShare, reference.visibleShare * 1.5 + 0.0025,
                "under an orbit -- the viewer's primary drag -- depth ordering must not move "
                + "materially more of the frame than Euclidean does; measured 0.691% against "
                + "0.708% on bonsai, and this bound allows half again plus a quarter point"
            )
            XCTAssertLessThanOrEqual(
                candidate.worstTileShare, reference.worstTileShare * 1.5 + 0.02,
                "the same, within the worst 64x64 tile, so a small badly-wrong region cannot "
                + "hide inside a pooled share"
            )
        } else {
            XCTFail("the orbit sweep did not produce a hold-1 row for both orderings")
        }
        if let candidate = freeLookCost[depth] {
            // Free look is the one gesture Euclidean's invariance covers, so a ratio against
            // it is meaningless here -- Euclidean is near zero by construction. This is the
            // absolute bound on what the trade costs: measured 0.854% pooled on bonsai.
            XCTAssertLessThanOrEqual(
                candidate.visibleShare, 0.02,
                "a free look is where depth ordering pays for itself; measured 0.854% of RGB "
                + "channels moving at least 2/255, and this bound fails if that doubles"
            )
        } else {
            XCTFail("the free-look sweep did not produce a hold-1 row for depth ordering")
        }
    }

    // MARK: the measurement

    private struct StaleOrderCost {
        let lag: Int
        let worstStaleness: Double
        /// Share of colour channels the stale order moves by at least two 8-bit codes. The
        /// stable statistic of the three: a worst pixel is one sample of a long tail, and
        /// PSNR buries a local artifact in a mostly-correct frame.
        let visibleShare: Double
        /// The same share within the worst 64x64 tile of any frame. Catches a small region
        /// that is badly wrong, which the pooled share cannot.
        let worstTileShare: Double
        /// True when the displayed order was held for the whole period and then jumped, which
        /// is what the scheduler does. False for the smooth constant-lag transfer function.
        let isHold: Bool
        let summary: String
    }

    /// How the displayed order falls behind.
    ///
    /// `constantLag` advances the displayed order every frame, always `k` behind. It is the
    /// clean transfer function and the wrong cadence: `beginSort` refuses a request while one
    /// is in flight, so production holds one order for the whole duration of a sort and then
    /// jumps. `sampleAndHold` reproduces that -- the order changes once every `k` frames and
    /// its age sawtooths between `k` and `2k - 1`. The distinction matters for the pop
    /// statistic specifically: the same total error arrives as one step rather than spread
    /// across `k` frames, and a step is what is visible.
    private enum Cadence {
        case constantLag(Int)
        case sampleAndHold(Int)

        var period: Int {
            switch self {
            case .constantLag(let k), .sampleAndHold(let k): return k
            }
        }

        /// Index of the order displayed at `frame`, or nil before the first publication.
        func orderIndex(forFrame frame: Int) -> Int? {
            switch self {
            case .constantLag(let k):
                return frame >= k ? frame - k : nil
            case .sampleAndHold(let k):
                // Sorts complete at frames k, 2k, 3k...; the one completing at j*k was
                // started at (j-1)*k and so carries that camera.
                let completed = frame / k
                return completed >= 2 ? (completed - 2) * k + k : nil
            }
        }

        var label: String {
            switch self {
            case .constantLag(let k): return String(format: "lag %2d      ", k)
            case .sampleAndHold(let k): return String(format: "hold %2d     ", k)
            }
        }

        var isHold: Bool {
            if case .sampleAndHold = self { return true }
            return false
        }

        /// Frames the turn must contain before this cadence displays anything at all.
        var framesNeeded: Int {
            switch self {
            case .constantLag(let k): return k + 1
            case .sampleAndHold(let k): return 2 * k + 1
            }
        }
    }

    /// Renders each camera on the turn twice -- once with the order that camera would have
    /// produced, once with the order the scheduler would actually be displaying -- and
    /// reports the difference. Every sort runs to completion first, so nothing here races the
    /// scheduler; the lag is imposed, which is what makes the numbers reproducible on a
    /// loaded machine.
    ///
    /// Alpha is excluded and the frame is tiled. Alpha is a quarter of the channels and the
    /// background is transparent, so pooling over all four dilutes a colour error by whatever
    /// share of the frame is empty; and a pooled percentile over 2.7M samples can hide a
    /// small region that is badly wrong, which is exactly the artifact worth catching. The
    /// worst 64x64 tile is reported alongside the pooled figures.
    private func staleOrderCost(
        _ harness: Harness,
        _ renderer: SplatRenderer,
        cameras: [SplatRenderer.CameraDescriptor],
        cadences: [Cadence]
    ) async throws -> [StaleOrderCost] {
        var orders: [[SplatRenderer.IndexType]] = []
        var fresh: [[UInt8]] = []
        for camera in cameras {
            orders.append(try await sortedOrder(renderer, camera: camera))
            fresh.append(try harness.render(renderer, camera: camera))
        }

        let width = cameras[0].screenSize.x
        let height = cameras[0].screenSize.y
        let channels = width * height * 4
        let tileSize = 64
        let tilesAcross = (width + tileSize - 1) / tileSize
        let tileCount = tilesAcross * ((height + tileSize - 1) / tileSize)
        var difference = [Int](repeating: 0, count: channels)
        var previous = [Int](repeating: 0, count: channels)
        var results: [StaleOrderCost] = []

        // A hold needs two full periods before it publishes anything, so a period that does
        // not fit the turn produces no frames at all -- and an empty measurement formats as a
        // flawless one, which is worse than no row at all.
        for cadence in cadences where cadence.framesNeeded <= cameras.count {
            var squaredError = 0.0
            var samples = 0
            let staleness = Histogram()
            let pop = Histogram()
            var worstTileShare = 0.0
            var havePrevious = false

            for frame in 0..<cameras.count {
                guard let source = cadence.orderIndex(forFrame: frame) else { continue }
                try renderer.publishOrderForTesting(orders[source])
                let displayed = try harness.render(renderer, camera: cameras[frame])
                let reference = fresh[frame]

                var tileVisible = [Int](repeating: 0, count: tileCount)
                var tileTotal = [Int](repeating: 0, count: tileCount)
                for pixel in 0..<(width * height) {
                    let tile = (pixel / width) / tileSize * tilesAcross
                        + (pixel % width) / tileSize
                    tileTotal[tile] += 3
                    // Skip index 3 of each BGRA quad: alpha is not a colour a viewer reads,
                    // and the transparent background would otherwise dominate the pool.
                    for component in 0..<3 {
                        let channel = pixel * 4 + component
                        let value = Int(displayed[channel]) - Int(reference[channel])
                        difference[channel] = value
                        staleness.add(abs(value))
                        squaredError += Double(value * value)
                        if abs(value) >= 2 { tileVisible[tile] += 1 }
                        // A constant offset from the fresh image is not what the eye catches
                        // -- nothing on screen offers the comparison. Popping is the offset
                        // *changing* between frames, which is this residual.
                        if havePrevious { pop.add(abs(value - previous[channel])) }
                    }
                    samples += 3
                }
                for tile in 0..<tileCount where tileTotal[tile] > 0 {
                    worstTileShare = max(
                        worstTileShare,
                        Double(tileVisible[tile]) / Double(tileTotal[tile])
                    )
                }
                swap(&difference, &previous)
                havePrevious = true
            }

            guard samples > 0 else { continue }
            let mse = squaredError / Double(samples) / (255 * 255)
            let psnr = mse > 0 ? 10 * log10(1 / mse) : Double.infinity
            results.append(StaleOrderCost(
                lag: cadence.period,
                worstStaleness: staleness.maximum,
                visibleShare: staleness.fractionAtLeast(codes: 2),
                worstTileShare: worstTileShare,
                isHold: cadence.isHold,
                summary: String(
                    format: "%@: PSNR %7.2f dB   stale p99.9 %.4f worst %.4f   "
                        + "pop p99.9 %.4f worst %.4f   RGB past 2/255: %.3f%% pooled, "
                        + "%.2f%% worst tile",
                    cadence.label, psnr,
                    staleness.quantile(0.999), staleness.maximum,
                    pop.quantile(0.999), pop.maximum,
                    100 * staleness.fractionAtLeast(codes: 2),
                    100 * worstTileShare
                )
            ))
        }
        return results
    }

    /// The popping that sort freshness cannot remove.
    ///
    /// Every frame here is freshly sorted, so any remaining discontinuity is intrinsic: two
    /// overlapping splats whose centre keys cross swap in one frame however current the sort
    /// is. Comparing against a freshly sorted reference cannot see it, because the reference
    /// contains the same swap.
    ///
    /// Camera motion has to be cancelled first or it swamps everything -- texture sweeping
    /// across pixels dominates any difference statistic taken on the frames themselves. So
    /// each frame is rendered twice, once freshly sorted and once with the order frozen at
    /// the first camera, and the measurement runs on the residual between them. The frozen
    /// arm carries the camera motion and no reordering at all; the residual is reordering
    /// alone. Its frame-to-frame change is popping: growing staleness moves the residual
    /// smoothly, a crossing steps it.
    private func intrinsicPop(
        _ harness: Harness,
        _ renderer: SplatRenderer,
        cameras: [SplatRenderer.CameraDescriptor]
    ) async throws -> (p999: Double, worst: Double) {
        guard let first = cameras.first else { return (0, 0) }
        let frozen = try await sortedOrder(renderer, camera: first)

        let histogram = Histogram()
        var previousResidual: [Int]?
        for camera in cameras {
            let fresh = try await sortedOrder(renderer, camera: camera)
            let freshFrame = try harness.render(renderer, camera: camera)
            try renderer.publishOrderForTesting(frozen)
            let frozenFrame = try harness.render(renderer, camera: camera)
            try renderer.publishOrderForTesting(fresh)

            let residual = (0..<freshFrame.count).map {
                Int(freshFrame[$0]) - Int(frozenFrame[$0])
            }
            if let previous = previousResidual {
                for channel in 0..<residual.count {
                    histogram.add(abs(residual[channel] - previous[channel]))
                }
            }
            previousResidual = residual
        }
        return (histogram.quantile(0.999), histogram.maximum)
    }

    /// Median wall-clock time of a forced sort across the turn. This is the load-dependent
    /// half of the question and the reason the earlier frequency statistic was unusable as a
    /// gate; it belongs in a reported number rather than an assertion.
    private func sortDuration(
        _ renderer: SplatRenderer,
        cameras: [SplatRenderer.CameraDescriptor]
    ) async throws -> TimeInterval {
        var samples: [TimeInterval] = []
        for camera in cameras.prefix(8) {
            let elapsed = DurationBox()
            _ = try await sortedOrder(renderer, camera: camera, force: true, timing: elapsed)
            if let seconds = elapsed.value { samples.append(seconds) }
        }
        guard !samples.isEmpty else { return 0 }
        return samples.sorted()[samples.count / 2]
    }

    private final class DurationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TimeInterval?
        func record(_ seconds: TimeInterval) {
            lock.lock(); stored = seconds; lock.unlock()
        }
        var value: TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    /// Two overlapping splats of different colours whose centre depths cross under a yaw.
    /// Both orders are freshly sorted, so this isolates the discontinuity that no amount of
    /// sort freshness removes, and that comparing against a fresh reference cannot see --
    /// the reference contains the same swap.
    ///
    /// Three separate claims, measured separately: that the picture depends on the order at
    /// all, that depth ordering reverses these two across the crossing, and that Euclidean
    /// does not. An earlier version used two identical white splats, which established the
    /// second claim while silently assuming the first.
    func testFreshDepthOrderChangesPixelsWhenCentreDepthsCross() async throws {
        let harness = try Harness()
        // Not equidistant: nearly so, which is what makes Euclidean hold them still. Exactly
        // equidistant would tie the sort key, and while the sorter now breaks ties by index
        // rather than leaving them to chance, a fixture should not rest on which of two
        // tied splats the implementation happens to put first.
        let crossing = [
            Harness.point(
                at: SIMD3<Float>(-0.3, 0, -2.00),
                logScale: -1.2,
                color: (255, 40, 40),
                opacityLogit: 1.4
            ),
            Harness.point(
                at: SIMD3<Float>(0.3, 0, -2.02),
                logScale: -1.2,
                color: (40, 60, 255),
                opacityLogit: 1.4
            ),
        ]
        let before = Harness.yawed(-0.35)
        let after = Harness.yawed(0.35)

        // 1. Does the order change the picture? Same camera, both orders, forced.
        let probe = try harness.makeRenderer(ordering: .cameraForwardDepth)
        try harness.load(probe, points: crossing)
        try probe.publishOrderForTesting([0, 1])
        let redInFront = try harness.render(probe, camera: after)
        try probe.publishOrderForTesting([1, 0])
        let blueInFront = try harness.render(probe, camera: after)
        let orderSensitivity = Harness.worstDifference(redInFront, blueInFront)
        XCTAssertGreaterThan(
            orderSensitivity, 0.05,
            "the two splats must share enough of the frame that swapping them repaints it; "
            + "without that this fixture measures an ordering nobody can see"
        )

        // 2. Depth ordering reverses them across the crossing.
        let depth = try harness.makeRenderer(ordering: .cameraForwardDepth)
        try harness.load(depth, points: crossing)
        let depthBefore = try await sortedOrder(depth, camera: before)
        let depthAfter = try await sortedOrder(depth, camera: after)
        XCTAssertNotEqual(
            depthBefore, depthAfter,
            "depth ordering must reverse these two splats across the crossing; if it does "
            + "not, the fixture no longer exercises the artifact it was written for"
        )

        // 3. Euclidean leaves them alone. That asymmetry is the whole reason the interactive
        //    viewer still defaults to it.
        let euclid = try harness.makeRenderer(ordering: .euclideanCameraDistance)
        try harness.load(euclid, points: crossing)
        let euclidBefore = try await sortedOrder(euclid, camera: before)
        let euclidAfter = try await sortedOrder(euclid, camera: after)
        XCTAssertEqual(
            euclidBefore, euclidAfter,
            "rotation about the camera centre leaves Euclidean distance unchanged, so these "
            + "two splats must keep their order - this is the property that masks popping"
        )

        print(String(
            format: "crossing: reversing the pair repaints the overlap by %.4f (worst channel)",
            orderSensitivity
        ))
    }

    /// A sort requested while one is in flight must not be silently lost: the last camera
    /// asked for is the one whose order should eventually be published. This is the
    /// scheduling half of the question, and it is a property rather than a measurement.
    func testLatestRequestedCameraEventuallyWins() async throws {
        let harness = try Harness()
        let renderer = try harness.makeRenderer(ordering: .cameraForwardDepth)
        try harness.load(renderer, points: Harness.overlappingCloud(count: 2_000))
        _ = try await sortedOrder(renderer, camera: Harness.yawed(0))

        // Fire three cameras back to back; the second and third arrive while the first sort
        // is still running.
        renderer.willRender(viewportCameras: [Harness.yawed(0.10)])
        renderer.willRender(viewportCameras: [Harness.yawed(0.20)])
        renderer.willRender(viewportCameras: [Harness.yawed(0.30)])

        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 40_000_000)
            renderer.willRender(viewportCameras: [Harness.yawed(0.30)])
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let settled = renderer.orderSnapshotForTesting()

        let fresh = try await sortedOrder(renderer, camera: Harness.yawed(0.30), force: true)
        XCTAssertEqual(
            settled, fresh,
            "after the camera stops moving the published order must converge on the final "
            + "camera; a dropped request that is never retried would leave it stale forever"
        )
    }

    // MARK: driving a sort to completion

    /// Shows the renderer a camera and returns the order it publishes, waiting out the
    /// asynchronous sort. Returns immediately when no sort was scheduled, which is why the
    /// start flag is consulted rather than a timeout being waited out: `onSortStart` fires
    /// synchronously inside `willRender`, before the worker task is created.
    @discardableResult
    private func sortedOrder(
        _ renderer: SplatRenderer,
        camera: SplatRenderer.CameraDescriptor,
        force: Bool = false,
        timing: DurationBox? = nil
    ) async throws -> [SplatRenderer.IndexType] {
        let started = Flag()
        let finished = Signal()
        renderer.onSortStart = { started.raise() }
        renderer.onSortComplete = { seconds in
            timing?.record(seconds)
            finished.signal()
        }
        defer {
            renderer.onSortStart = nil
            renderer.onSortComplete = nil
        }

        renderer.willRender(viewportCameras: [camera])
        if force, !started.isRaised {
            renderer.resortIndices()
        }
        if started.isRaised {
            // Bounded: a sort that fails without calling back would otherwise hang the
            // suite rather than fail it.
            guard await finished.wait(timeoutSeconds: 60) else {
                XCTFail("a scheduled sort did not complete within 60 s")
                return renderer.orderSnapshotForTesting()
            }
        }
        return renderer.orderSnapshotForTesting()
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() {
            lock.lock(); raised = true; lock.unlock()
        }
        var isRaised: Bool {
            lock.lock(); defer { lock.unlock() }
            return raised
        }
    }

    /// A one-shot await. Deliberately not an `XCTestExpectation`: this helper has to install
    /// its completion handler before it knows whether a sort will start at all, and an
    /// expectation created and then not waited on fails the test on its own.
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var signalled = false
        private var waiter: CheckedContinuation<Void, Never>?

        func signal() {
            lock.lock()
            guard !signalled else { return lock.unlock() }
            signalled = true
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }

        /// Returns false if the deadline passed first.
        func wait(timeoutSeconds: Double) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        lock.lock()
                        if signalled {
                            lock.unlock()
                            continuation.resume()
                        } else {
                            waiter = continuation
                            lock.unlock()
                        }
                    }
                }
                group.addTask { [self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    // Unblocks the waiter so the group can finish; `signalled` is what the
                    // caller reads, and this does not set it.
                    expire()
                }
                await group.next()
                group.cancelAll()
            }
            return isSignalled
        }

        private var isSignalled: Bool {
            lock.withLock { signalled }
        }

        private func expire() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                let pending = self.waiter
                self.waiter = nil
                return pending
            }
            waiter?.resume()
        }
    }

    // MARK: offscreen rendering

    private enum HarnessError: Error {
        case renderResourceUnavailable(String)
    }

    /// Renders through the same path the product viewer uses, into the pixel format the
    /// app's `MTKView` presents (`bgra8Unorm`). Measuring in a wider format would count
    /// ordering differences the display quantizes away, which is not what a viewer sees.
    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw XCTSkip("Metal is unavailable")
            }
            guard let queue = device.makeCommandQueue() else {
                throw XCTSkip("Metal could not create a command queue")
            }
            self.device = device
            self.queue = queue
        }

        func makeRenderer(ordering: SplatRenderer.SortOrdering) throws -> SplatRenderer {
            try SplatRenderer(
                device: device,
                colorFormat: .bgra8Unorm,
                depthFormat: .invalid,
                stencilFormat: .invalid,
                sampleCount: 1,
                maxViewCount: 1,
                maxSimultaneousRenders: 3,
                maximumSplatCount: nil,
                sortOrdering: ordering
            )
        }

        func load(_ renderer: SplatRenderer, points: [SplatScenePoint]) throws {
            for point in points {
                try renderer.add(point)
            }
        }

        /// Centroid and enclosing radius of the loaded splats, read straight out of the
        /// renderer's own buffer so a real scene can be framed without a camera file.
        func sceneBounds(_ renderer: SplatRenderer) -> (centre: SIMD3<Float>, radius: Float) {
            let count = renderer.splatCount
            guard count > 0 else { return (.zero, 1) }
            let splats = renderer.splatBuffer.values
            var sum = SIMD3<Double>.zero
            for index in 0..<count {
                let position = splats[index].position
                sum += SIMD3<Double>(Double(position.x), Double(position.y), Double(position.z))
            }
            let centre = SIMD3<Float>(sum / Double(count))
            var radius: Float = 0
            for index in 0..<count {
                let position = splats[index].position
                let offset = SIMD3<Float>(position.x, position.y, position.z) - centre
                radius = max(radius, simd_length_squared(offset))
            }
            return (centre, max(sqrt(radius), 1e-3))
        }

        /// The rendered frame as interleaved BGRA bytes.
        func render(
            _ renderer: SplatRenderer,
            camera: SplatRenderer.CameraDescriptor
        ) throws -> [UInt8] {
            let width = camera.screenSize.x
            let height = camera.screenSize.y
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw HarnessError.renderResourceUnavailable("render target")
            }
            guard let commandBuffer = queue.makeCommandBuffer() else {
                throw HarnessError.renderResourceUnavailable("command buffer")
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw HarnessError.renderResourceUnavailable("render encoder")
            }
            renderer.render(viewportCameras: [camera], to: encoder)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                throw HarnessError.renderResourceUnavailable(error.localizedDescription)
            }

            let bytesPerRow = width * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
            texture.getBytes(
                &pixels,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
            return pixels
        }

        // MARK: fixtures

        /// A shell of splats in front of the camera, sized so their projected footprints
        /// overlap heavily and coloured so that swapping two of them changes the pixels they
        /// share. Both properties carry the measurement: ordering is invisible without
        /// overlap, and invisible between identical colours.
        ///
        /// Radii are stratified rather than drawn freely. Every splat sits exactly `radius`
        /// from the camera, so a free draw would collide within the generator's resolution
        /// long before 2000 samples and tie the Euclidean sort key wholesale. Ties resolve
        /// by index now, but a fixture asserting bit-identical frames should not depend on
        /// that; distinct keys make the assertion about ordering rather than tie policy.
        static func overlappingCloud(count: Int) -> [SplatScenePoint] {
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            func uniform() -> Float {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float((state >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
            }
            return (0..<count).map { index in
                // Wide in azimuth so the turn keeps the frame populated, shallow in depth so
                // many splats share each pixel.
                let azimuth = (uniform() - 0.5) * 1.6
                let elevation = (uniform() - 0.5) * 0.9
                let radius = 2.0 + 4.0 * (Float(index) + uniform()) / Float(count)
                let position = SIMD3<Float>(
                    radius * sin(azimuth) * cos(elevation),
                    radius * sin(elevation),
                    -radius * cos(azimuth) * cos(elevation)
                )
                return point(
                    at: position,
                    logScale: -1.2 + uniform() * 0.8,
                    color: (
                        UInt8(uniform() * 255),
                        UInt8(uniform() * 255),
                        UInt8(uniform() * 255)
                    ),
                    // sigmoid(-1.4 .. 2.4) spans roughly 0.20 to 0.92, so the frame holds
                    // both order-sensitive opaque splats and near-commutative faint ones.
                    opacityLogit: -1.4 + uniform() * 3.8
                )
            }
        }

        /// `scale` is a log scale and `opacity` a logit; the encoder applies `exp` and a
        /// sigmoid (`SplatRenderEncodingValidator.encode`).
        static func point(
            at position: SIMD3<Float>,
            logScale: Float,
            color: (UInt8, UInt8, UInt8),
            opacityLogit: Float
        ) -> SplatScenePoint {
            SplatScenePoint(
                position: position,
                normal: .zero,
                color: .linearUInt8(color.0, color.1, color.2),
                opacity: opacityLogit,
                scale: SIMD3<Float>(repeating: logScale),
                rotation: simd_quatf(real: 1, imag: .zero)
            )
        }

        /// A yaw about the camera's own centre, under a real perspective projection. The
        /// rotation is the motion Euclidean ordering is invariant to and depth ordering is
        /// not; the perspective is what separates forward depth from radial distance at all.
        /// A camera on a circle around `centre`, looking inward. This is how a viewer is
        /// actually driven -- the user orbits the subject -- and unlike a yaw about the eye
        /// it moves the camera position, so Euclidean distance is no longer invariant. The
        /// whole argument for keeping Euclidean interactive rests on an invariance that only
        /// one motion has; this is the other one.
        static func orbited(
            _ radians: Float,
            centre: SIMD3<Float>,
            radius: Float,
            size: SIMD2<Int>,
            far: Float
        ) -> SplatRenderer.CameraDescriptor {
            let eye = centre + SIMD3<Float>(radius * sin(radians), 0, radius * cos(radians))
            let forward = simd_normalize(centre - eye)
            // right = forward x up, not up x forward, which is left and gives a basis of
            // determinant -1 -- a mirrored camera. Pooled error magnitudes survive a mirror,
            // so this was invisible in the numbers and wrong anyway.
            let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            let up = simd_cross(right, forward)
            // World-to-camera: the basis as rows, then the translation into that basis.
            let view = simd_float4x4(columns: (
                SIMD4<Float>(right.x, up.x, -forward.x, 0),
                SIMD4<Float>(right.y, up.y, -forward.y, 0),
                SIMD4<Float>(right.z, up.z, -forward.z, 0),
                SIMD4<Float>(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)
            ))
            return SplatRenderer.CameraDescriptor(
                projectionMatrix: perspective(size: size, far: far),
                viewMatrix: view,
                screenSize: size
            )
        }

        static func perspective(size: SIMD2<Int>, far: Float) -> simd_float4x4 {
            let fieldOfView: Float = 60 * .pi / 180
            let aspect = Float(size.x) / Float(size.y)
            let scaleY = 1 / tan(fieldOfView / 2)
            let near: Float = 0.1
            return simd_float4x4(columns: (
                SIMD4<Float>(scaleY / aspect, 0, 0, 0),
                SIMD4<Float>(0, scaleY, 0, 0),
                SIMD4<Float>(0, 0, far / (near - far), -1),
                SIMD4<Float>(0, 0, far * near / (near - far), 0)
            ))
        }

        static func yawed(
            _ radians: Float,
            at position: SIMD3<Float> = .zero,
            size: SIMD2<Int> = SIMD2(Turn.width, Turn.height),
            far: Float = 100
        ) -> SplatRenderer.CameraDescriptor {
            let c = cos(radians), s = sin(radians)
            let rotation = simd_float4x4(columns: (
                SIMD4<Float>(c, 0, -s, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(s, 0, c, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))
            // Rotate after translating the world so the camera sits at `position`: the
            // camera's own centre stays put under any yaw, which is the motion Euclidean
            // ordering is invariant to.
            let recentre = simd_float4x4(columns: (
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(-position.x, -position.y, -position.z, 1)
            ))
            return SplatRenderer.CameraDescriptor(
                projectionMatrix: perspective(size: size, far: far),
                viewMatrix: rotation * recentre,
                screenSize: size
            )
        }

        // MARK: comparison

        static func worstDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            zip(a, b).reduce(0.0) { max($0, abs(Double($1.0) - Double($1.1)) / 255.0) }
        }
    }
}
