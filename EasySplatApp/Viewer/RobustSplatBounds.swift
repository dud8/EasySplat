import Foundation
import simd

struct SplatBoundsSample: Equatable {
    let position: SIMD3<Float>
    let logScale: SIMD3<Float>
    let opacityLogit: Float
}

struct ViewerSceneBounds: Equatable {
    let center: SIMD3<Float>
    let radius: Float
}

enum RobustSplatBounds {
    static let maximumFallbackSampleCount = 100_000

    static func sampleIndex(
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

    static func compute(samples: [SplatBoundsSample]) -> ViewerSceneBounds? {
        let finite = samples.compactMap { sample -> PreparedSample? in
            guard sample.position.x.isFinite,
                  sample.position.y.isFinite,
                  sample.position.z.isFinite,
                  sample.logScale.x.isFinite,
                  sample.logScale.y.isFinite,
                  sample.logScale.z.isFinite,
                  sample.opacityLogit.isFinite else {
                return nil
            }

            let physicalScale = SIMD3<Float>(
                exp(sample.logScale.x),
                exp(sample.logScale.y),
                exp(sample.logScale.z)
            )
            guard physicalScale.x.isFinite,
                  physicalScale.y.isFinite,
                  physicalScale.z.isFinite,
                  physicalScale.x > 0,
                  physicalScale.y > 0,
                  physicalScale.z > 0 else {
                return nil
            }
            return PreparedSample(
                position: sample.position,
                largestPhysicalScale: max(physicalScale.x, physicalScale.y, physicalScale.z),
                alpha: sigmoid(sample.opacityLogit)
            )
        }
        guard !finite.isEmpty else { return nil }

        let visible = finite.filter { $0.alpha >= 0.01 }
        let minimumVisibleCount = min(
            finite.count,
            max(8, (finite.count + 999) / 1_000)
        )
        let selected = visible.count >= minimumVisibleCount ? visible : finite
        let center = SIMD3<Float>(
            median(selected.map { $0.position.x }),
            median(selected.map { $0.position.y }),
            median(selected.map { $0.position.z })
        )
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { return nil }

        var extents = selected.compactMap { sample -> Float? in
            let extent = simd_distance(sample.position, center) + 3 * sample.largestPhysicalScale
            return extent.isFinite && extent > 0 ? extent : nil
        }
        guard !extents.isEmpty else { return nil }
        extents.sort()
        let percentileIndex = min(
            extents.count - 1,
            max(0, Int(ceil(0.995 * Double(extents.count))) - 1)
        )
        let radius = extents[percentileIndex]
        guard radius.isFinite, radius > 0 else { return nil }
        return ViewerSceneBounds(center: center, radius: radius)
    }

    private struct PreparedSample {
        let position: SIMD3<Float>
        let largestPhysicalScale: Float
        let alpha: Float
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] / 2 + sorted[middle] / 2
        }
        return sorted[middle]
    }

    private static func sigmoid(_ value: Float) -> Float {
        if value >= 0 {
            return 1 / (1 + exp(-value))
        }
        let exponential = exp(value)
        return exponential / (1 + exponential)
    }
}
