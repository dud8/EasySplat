import Metal
import SplatIO
import simd
import XCTest
@testable import MetalSplatter

/// The temporal gate for `SortOrdering.cameraForwardDepth`.
///
/// Depth ordering is what the trainer's own rasterizer keys on, and rendering a fixed PLY
/// with it recovers most of the viewer-to-trainer gap. The interactive viewer still selects
/// Euclidean because rotation exposes something a still frame cannot show: the sort runs
/// asynchronously and a request arriving while one is in flight is dropped, so the order a
/// frame composites can belong to an older camera. Euclidean distance does not change under
/// rotation about the camera centre, so with that key a stale order is still the right
/// order. Depth does change, and the same lag becomes visible popping.
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

            for measurement in try await staleOrderCost(harness, renderer, cameras: cameras) {
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

            let sortSeconds = try await sortDuration(renderer, cameras: cameras)
            report.append(String(
                format: "  %@: %d splats, sort %.1f ms -> %d frames of lag at 60 Hz, %d at 120 Hz",
                String(describing: ordering), renderer.splatCount, sortSeconds * 1000,
                Int(ceil(sortSeconds * 60)), Int(ceil(sortSeconds * 120))
            ))
            for measurement in try await staleOrderCost(
                harness, renderer, cameras: cameras, lags: Turn.realLags
            ) {
                report.append("  " + String(describing: ordering) + " " + measurement.summary)
                if ordering == .euclideanCameraDistance {
                    // Not exactly zero here, unlike the synthetic fixture. A real scene has
                    // more splats than the sort key has distinguishable Float32 values, so
                    // keys tie; `Array.sort` is not stable, and the array it sorts is the
                    // previous frame's output, so tied splats come back in a different order
                    // each time. That churn is not staleness -- it does not grow with lag --
                    // and it is small, but it is the reason this is a bound rather than an
                    // equality.
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
    }

    // MARK: the measurement

    private struct StaleOrderCost {
        let lag: Int
        let worstStaleness: Double
        /// Share of colour channels the stale order moves by at least two 8-bit codes. The
        /// stable statistic of the three: a worst pixel is one sample of a long tail, and
        /// PSNR buries a local artifact in a mostly-correct frame.
        let visibleShare: Double
        let summary: String
    }

    /// Renders each camera on the turn twice -- once with the order that camera would have
    /// produced, once with the order from `lag` frames earlier -- and reports the difference.
    /// Every sort runs to completion first, so nothing here races the scheduler; the lag is
    /// imposed, which is what makes the numbers reproducible on a loaded machine.
    private func staleOrderCost(
        _ harness: Harness,
        _ renderer: SplatRenderer,
        cameras: [SplatRenderer.CameraDescriptor],
        lags: [Int] = Turn.lags
    ) async throws -> [StaleOrderCost] {
        var orders: [[SplatRenderer.IndexType]] = []
        var fresh: [[UInt8]] = []
        for camera in cameras {
            orders.append(try await sortedOrder(renderer, camera: camera))
            fresh.append(try harness.render(renderer, camera: camera))
        }

        let channels = cameras[0].screenSize.x * cameras[0].screenSize.y * 4
        var difference = [Int](repeating: 0, count: channels)
        var previous = [Int](repeating: 0, count: channels)
        var results: [StaleOrderCost] = []

        for lag in lags where lag < cameras.count {
            var squaredError = 0.0
            var samples = 0
            let staleness = Histogram()
            let pop = Histogram()
            var havePrevious = false

            for frame in lag..<cameras.count {
                try renderer.publishOrderForTesting(orders[frame - lag])
                let displayed = try harness.render(renderer, camera: cameras[frame])
                let reference = fresh[frame]

                for channel in 0..<channels {
                    let value = Int(displayed[channel]) - Int(reference[channel])
                    difference[channel] = value
                    staleness.add(abs(value))
                    squaredError += Double(value * value)
                    // A constant offset from the fresh image is not what the eye catches --
                    // nothing on screen offers the comparison. Popping is the offset
                    // *changing* between frames, which is this residual.
                    if havePrevious { pop.add(abs(value - previous[channel])) }
                }
                samples += channels
                swap(&difference, &previous)
                havePrevious = true
            }

            let mse = samples > 0 ? squaredError / Double(samples) / (255 * 255) : 0
            let psnr = mse > 0 ? 10 * log10(1 / mse) : Double.infinity
            results.append(StaleOrderCost(
                lag: lag,
                worstStaleness: staleness.maximum,
                visibleShare: staleness.fractionAtLeast(codes: 2),
                summary: String(
                    format: "lag %2d: PSNR %7.2f dB   stale p99.9 %.4f worst %.4f   "
                        + "pop p99.9 %.4f worst %.4f   %.3f%% of channels past 2/255",
                    lag, psnr,
                    staleness.quantile(0.999), staleness.maximum,
                    pop.quantile(0.999), pop.maximum,
                    100 * staleness.fractionAtLeast(codes: 2)
                )
            ))
        }
        return results
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
        // Not equidistant: nearly so, which is what makes Euclidean hold them still, but
        // exactly equidistant would tie the sort key and leave the comparison at the mercy
        // of an unstable sort.
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
        let finished = expectation(description: "sort")
        finished.assertForOverFulfill = false
        renderer.onSortStart = { started.raise() }
        renderer.onSortComplete = { seconds in
            timing?.record(seconds)
            finished.fulfill()
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
            await fulfillment(of: [finished], timeout: 30)
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
        /// long before 2000 samples, tie the Euclidean sort key, and leave the order at the
        /// mercy of an unstable sort.
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
            let fieldOfView: Float = 60 * .pi / 180
            let aspect = Float(size.x) / Float(size.y)
            let scaleY = 1 / tan(fieldOfView / 2)
            let near: Float = 0.1
            let projection = simd_float4x4(columns: (
                SIMD4<Float>(scaleY / aspect, 0, 0, 0),
                SIMD4<Float>(0, scaleY, 0, 0),
                SIMD4<Float>(0, 0, far / (near - far), -1),
                SIMD4<Float>(0, 0, far * near / (near - far), 0)
            ))
            return SplatRenderer.CameraDescriptor(
                projectionMatrix: projection,
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
