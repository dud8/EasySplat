import XCTest
@testable import EasySplatApp

final class RobustSplatBoundsTests: XCTestCase {
    func testDeterministicSamplingCapsCountAndIncludesBothEndpoints() throws {
        let pointCount = 553_052
        let count = RobustSplatBounds.maximumFallbackSampleCount
        let indices = (0..<count).compactMap {
            RobustSplatBounds.sampleIndex(slot: $0, pointCount: pointCount)
        }

        XCTAssertEqual(indices.count, count)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, pointCount - 1)
        XCTAssertEqual(Set(indices).count, count)
        XCTAssertEqual(
            indices,
            (0..<count).compactMap {
                RobustSplatBounds.sampleIndex(slot: $0, pointCount: pointCount)
            }
        )
    }

    func testSamplingUsesEveryPointWhenBelowTheLimit() {
        XCTAssertEqual(
            (0..<4).compactMap { RobustSplatBounds.sampleIndex(slot: $0, pointCount: 4) },
            [0, 1, 2, 3]
        )
        XCTAssertNil(RobustSplatBounds.sampleIndex(slot: 4, pointCount: 4))
        XCTAssertNil(RobustSplatBounds.sampleIndex(slot: 0, pointCount: 0))
    }

    func testBoundsUseCoordinateMedianAndPhysicalGaussianScale() throws {
        let samples = [
            sample(position: .init(0, 0, 0), physicalScale: .init(1, 2, 1)),
            sample(position: .init(2, 4, 6), physicalScale: .init(1, 1, 1)),
            sample(position: .init(4, 8, 12), physicalScale: .init(1, 1, 3))
        ]

        let bounds = try XCTUnwrap(RobustSplatBounds.compute(samples: samples))

        XCTAssertEqual(bounds.center, SIMD3<Float>(2, 4, 6))
        XCTAssertEqual(bounds.radius, sqrt(56) + 9, accuracy: 1e-5)
    }

    func testLowOpacityOutlierDoesNotMoveVisibleBounds() throws {
        var samples = (0..<8).map { index in
            sample(position: .init(index.isMultiple(of: 2) ? -1 : 1, 0, 0))
        }
        samples.append(contentsOf: (0..<100).map { _ in
            sample(position: .init(10_000, 10_000, 10_000), opacityLogit: -20)
        })

        let bounds = try XCTUnwrap(RobustSplatBounds.compute(samples: samples))

        XCTAssertEqual(bounds.center, .zero)
        XCTAssertEqual(bounds.radius, 1.3, accuracy: 1e-5)
    }

    func testAllLowOpacitySamplesFallBackToFiniteGeometry() throws {
        let samples = [
            sample(position: .init(-2, 0, 0), opacityLogit: -20),
            sample(position: .init(2, 0, 0), opacityLogit: -20)
        ]

        let bounds = try XCTUnwrap(RobustSplatBounds.compute(samples: samples))

        XCTAssertEqual(bounds.center, .zero)
        XCTAssertEqual(bounds.radius, 2.3, accuracy: 1e-5)
    }

    func testP995ExtentRejectsSparseExtremeOutliers() throws {
        var samples = (0..<1_000).map { index in
            sample(position: .init(Float(index % 10) * 0.01, 0, 0))
        }
        samples.append(sample(position: .init(1_000_000, 0, 0)))

        let bounds = try XCTUnwrap(RobustSplatBounds.compute(samples: samples))

        XCTAssertLessThan(bounds.radius, 1)
    }

    func testInvalidSamplesAreIgnoredAndInvalidOnlyInputReturnsNil() throws {
        let valid = sample(position: .init(1, 2, 3))
        let invalid = SplatBoundsSample(
            position: .init(.nan, 0, 0),
            logScale: .zero,
            opacityLogit: 0
        )

        let bounds = try XCTUnwrap(RobustSplatBounds.compute(samples: [invalid, valid]))
        XCTAssertEqual(bounds.center, valid.position)
        XCTAssertNil(RobustSplatBounds.compute(samples: [invalid]))
    }

    func testUnderflowedPhysicalScaleIsIgnored() throws {
        let valid = SplatBoundsSample(
            position: .zero,
            logScale: .zero,
            opacityLogit: 4
        )
        let underflowed = SplatBoundsSample(
            position: .init(1_000, 0, 0),
            logScale: .init(repeating: -Float.greatestFiniteMagnitude),
            opacityLogit: 4
        )

        let bounds = try XCTUnwrap(RobustSplatBounds.compute(samples: [valid, underflowed]))

        XCTAssertEqual(bounds.center, .zero)
        XCTAssertEqual(bounds.radius, 3, accuracy: 1e-5)
        XCTAssertNil(RobustSplatBounds.compute(samples: [underflowed]))
    }

    private func sample(
        position: SIMD3<Float>,
        physicalScale: SIMD3<Float> = .init(repeating: 0.1),
        opacityLogit: Float = 4
    ) -> SplatBoundsSample {
        SplatBoundsSample(
            position: position,
            logScale: SIMD3<Float>(
                log(physicalScale.x),
                log(physicalScale.y),
                log(physicalScale.z)
            ),
            opacityLogit: opacityLogit
        )
    }
}
