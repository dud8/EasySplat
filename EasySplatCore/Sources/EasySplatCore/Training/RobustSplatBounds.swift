import Foundation
import simd
import SplatIO

public struct SplatBoundsSample: Equatable, Sendable {
    public let position: SIMD3<Float>
    public let logScale: SIMD3<Float>
    public let opacityLogit: Float

    public init(
        position: SIMD3<Float>,
        logScale: SIMD3<Float>,
        opacityLogit: Float
    ) {
        self.position = position
        self.logScale = logScale
        self.opacityLogit = opacityLogit
    }
}

public struct ViewerSceneBounds: Equatable, Sendable {
    public let center: SIMD3<Float>
    public let radius: Float

    public init(center: SIMD3<Float>, radius: Float) {
        self.center = center
        self.radius = radius
    }
}

/// The robust scene-bounds definition shared by native training receipts and
/// finished-project validation.
public enum RobustSplatBounds {
    public static let maximumFallbackSampleCount = 100_000

    public static func sampleIndex(
        slot: Int,
        pointCount: Int,
        limit: Int = maximumFallbackSampleCount
    ) -> Int? {
        guard pointCount > 0, limit > 0 else { return nil }
        let sampleCount = min(pointCount, limit)
        guard slot >= 0, slot < sampleCount else { return nil }
        guard sampleCount > 1 else { return 0 }

        let numerator = UInt64(slot) * UInt64(pointCount - 1)
        let denominator = UInt64(sampleCount - 1)
        return Int((numerator + denominator / 2) / denominator)
    }

    public static func compute(samples: [SplatBoundsSample]) -> ViewerSceneBounds? {
        guard let bounds = computeTrainingBounds(samples: samples) else { return nil }
        let center = SIMD3<Float>(
            Float(bounds.center.x),
            Float(bounds.center.y),
            Float(bounds.center.z)
        )
        let radius = Float(bounds.radius)
        guard center.x.isFinite,
              center.y.isFinite,
              center.z.isFinite,
              radius.isFinite,
              radius > 0 else {
            return nil
        }
        return ViewerSceneBounds(center: center, radius: radius)
    }

    public static func computeTrainingBounds(
        samples: [SplatBoundsSample]
    ) -> SplatSceneBounds? {
        computeTrainingBounds(preparedSamples: samples.compactMap(prepare))
    }

    fileprivate static func computeTrainingBounds(
        preparedSamples: [PreparedSample]
    ) -> SplatSceneBounds? {
        guard !preparedSamples.isEmpty else { return nil }

        let visibleCount = preparedSamples.count(where: \.isVisible)
        let minimumVisibleCount = min(
            preparedSamples.count,
            max(8, (preparedSamples.count + 999) / 1_000)
        )
        let useVisibleSamples = visibleCount >= minimumVisibleCount
        let selectedCount = useVisibleSamples ? visibleCount : preparedSamples.count

        // Keep one compact prepared population and one reusable scalar buffer instead
        // of materializing visible, coordinate, and extent copies of a large model.
        var values = [Double]()
        values.reserveCapacity(selectedCount)
        var center = SIMD3<Double>(repeating: 0)
        for axis in 0..<3 {
            values.removeAll(keepingCapacity: true)
            for sample in preparedSamples where !useVisibleSamples || sample.isVisible {
                values.append(Double(sample.position[axis]))
            }
            guard values.count == selectedCount,
                  let coordinateMedian = medianInPlace(&values) else {
                return nil
            }
            center[axis] = coordinateMedian
        }
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { return nil }

        values.removeAll(keepingCapacity: true)
        for sample in preparedSamples where !useVisibleSamples || sample.isVisible {
            let position = SIMD3<Double>(
                Double(sample.position.x),
                Double(sample.position.y),
                Double(sample.position.z)
            )
            let delta = position - center
            let distance = hypot(hypot(delta.x, delta.y), delta.z)
            let extent = distance + 3 * sample.largestPhysicalScale
            if extent.isFinite && extent > 0 {
                values.append(extent)
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        // Match the native trainer's deterministic nearest-rank p99.5 exactly.
        let rank = max(1, (995 * values.count + 999) / 1_000)
        let radius = values[min(rank, values.count) - 1]
        guard radius.isFinite, radius > 0 else { return nil }
        return SplatSceneBounds(
            center: ScenePoint3D(x: center.x, y: center.y, z: center.z),
            radius: radius
        )
    }

    fileprivate struct PreparedSample {
        let position: SIMD3<Float>
        let largestPhysicalScale: Double
        let isVisible: Bool
    }

    fileprivate static func prepare(_ sample: SplatBoundsSample) -> PreparedSample? {
        guard sample.position.x.isFinite,
              sample.position.y.isFinite,
              sample.position.z.isFinite,
              sample.logScale.x.isFinite,
              sample.logScale.y.isFinite,
              sample.logScale.z.isFinite,
              sample.opacityLogit.isFinite else {
            return nil
        }

        let physicalScale = SIMD3<Double>(
            exp(Double(sample.logScale.x)),
            exp(Double(sample.logScale.y)),
            exp(Double(sample.logScale.z))
        )
        guard physicalScale.x.isFinite,
              physicalScale.y.isFinite,
              physicalScale.z.isFinite,
              physicalScale.x > 0,
              physicalScale.y > 0,
              physicalScale.z > 0,
              physicalScale.x <= Double(Float.greatestFiniteMagnitude),
              physicalScale.y <= Double(Float.greatestFiniteMagnitude),
              physicalScale.z <= Double(Float.greatestFiniteMagnitude) else {
            return nil
        }
        let alpha = sigmoid(Double(sample.opacityLogit))
        guard alpha.isFinite else { return nil }
        return PreparedSample(
            position: sample.position,
            largestPhysicalScale: max(
                physicalScale.x,
                physicalScale.y,
                physicalScale.z
            ),
            isVisible: alpha >= 0.01
        )
    }

    private static func medianInPlace(_ values: inout [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        values.sort()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return values[middle - 1] + (values[middle] - values[middle - 1]) * 0.5
        }
        return values[middle]
    }

    private static func sigmoid(_ value: Double) -> Double {
        if value >= 0 {
            return 1 / (1 + exp(-value))
        }
        let exponential = exp(value)
        return exponential / (1 + exponential)
    }
}

public enum SplatSceneBoundsCalculator {
    static func matches(_ lhs: SplatSceneBounds, _ rhs: SplatSceneBounds) -> Bool {
        approximatelyEqual(lhs.center.x, rhs.center.x)
            && approximatelyEqual(lhs.center.y, rhs.center.y)
            && approximatelyEqual(lhs.center.z, rhs.center.z)
            && approximatelyEqual(lhs.radius, rhs.radius)
    }

    public static func compute(
        at url: URL,
        maximumSampleCount: Int? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> SplatSceneBounds? {
        let collector = BoundsCollector(maximumSampleCount: maximumSampleCount)
        SplatPLYSceneReader(url).read(to: collector, shouldCancel: shouldCancel)
        if let error = collector.error { throw error }
        return RobustSplatBounds.computeTrainingBounds(preparedSamples: collector.samples)
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= max(1e-9, max(abs(lhs), abs(rhs)) * 1e-9)
    }

    private final class BoundsCollector: NSObject, SplatSceneReaderDelegate {
        fileprivate var samples: [RobustSplatBounds.PreparedSample] = []
        fileprivate var error: Error?
        private let maximumSampleCount: Int?
        private var pointCount = 0
        private var pointIndex = 0
        private var sampleSlot = 0
        private var nextSampleIndex: Int?

        init(maximumSampleCount: Int?) {
            self.maximumSampleCount = maximumSampleCount
        }

        func didStartReading(withPointCount pointCount: UInt32) {
            self.pointCount = Int(pointCount)
            let limit = maximumSampleCount ?? self.pointCount
            samples.reserveCapacity(min(self.pointCount, max(0, limit)))
            nextSampleIndex = RobustSplatBounds.sampleIndex(
                slot: sampleSlot,
                pointCount: self.pointCount,
                limit: limit
            )
        }

        func didRead(points: [SplatScenePoint]) {
            for point in points {
                if pointIndex == nextSampleIndex {
                    if let sample = RobustSplatBounds.prepare(
                        SplatBoundsSample(
                            position: point.position,
                            logScale: point.scale,
                            opacityLogit: point.opacity
                        )
                    ) {
                        samples.append(sample)
                    }
                    sampleSlot += 1
                    nextSampleIndex = RobustSplatBounds.sampleIndex(
                        slot: sampleSlot,
                        pointCount: pointCount,
                        limit: maximumSampleCount ?? pointCount
                    )
                }
                pointIndex += 1
            }
        }

        func didFinishReading() {}

        func didFailReading(withError error: Error?) {
            self.error = error ?? SplatSceneBoundsCalculatorError.readerFailed
        }
    }
}

public enum SplatSceneBoundsCalculatorError: Error {
    case readerFailed
}
