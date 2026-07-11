#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class ReconstructionSummaryReprojectionTests: XCTestCase {
    private func makeScore(reproj: Double?) -> ReconstructionScore {
        ReconstructionScore(
            registeredImages: 30,
            totalImages: 30,
            meanReprojectionError: reproj,
            pointCount: 14_000,
            observationCount: 56_000,
            meanTrackLength: 4.0
        )
    }

    private let unreliableMappers = [
        "global_mapper", "global_mapper-gpu", "global_mapper-cpu",
        "da3-direct", "mapanything-direct", "fastvggt-seed"
    ]

    private let reliableMappers = [
        "colmap", "point_triangulator", "point_triangulator+bundle_adjuster", "mapanything-refinement"
    ]

    func testUnreliableMapperReprojectionIsDroppedFromSummary() {
        for mapper in unreliableMappers {
            let summary = ReconstructionSummary(score: makeScore(reproj: 1.0), mapper: mapper, capturedAt: Date())
            XCTAssertNil(summary.meanReprojectionError,
                         "\(mapper): a placeholder point-error must not be persisted as a pixel reproj.")
            // Every other real metric is preserved.
            XCTAssertEqual(summary.registeredImages, 30)
            XCTAssertEqual(summary.pointCount, 14_000)
            XCTAssertEqual(summary.observationCount, 56_000)
            XCTAssertEqual(summary.meanTrackLength, 4.0)
        }
    }

    func testReliableMapperReprojectionIsPreserved() {
        for mapper in reliableMappers {
            let summary = ReconstructionSummary(score: makeScore(reproj: 1.5), mapper: mapper, capturedAt: Date())
            XCTAssertEqual(summary.meanReprojectionError, 1.5,
                           "\(mapper): a re-triangulated pixel reproj must be preserved.")
            XCTAssertEqual(summary.resolvedReprojectionError, 1.5)
        }
    }

    func testResolvedReprojectionMasksLegacyPersistedValue() {
        // Old project.json could carry a placeholder reproj on an unreliable mapper (built via
        // the memberwise init, which does not sanitize). resolvedReprojectionError masks it.
        for mapper in unreliableMappers {
            let legacy = ReconstructionSummary(
                mapper: mapper,
                capturedAt: Date(),
                registeredImages: 30,
                totalImages: 30,
                meanReprojectionError: 0.0003,
                pointCount: 14_000,
                observationCount: 56_000,
                meanTrackLength: 4.0
            )
            XCTAssertNil(legacy.resolvedReprojectionError, "\(mapper): legacy placeholder reproj must be masked on read.")
        }
    }

    func testReprojectionErrorIsUnreliableDiscriminatorIsExact() {
        for mapper in unreliableMappers {
            XCTAssertTrue(ReconstructionSummary.reprojectionErrorIsUnreliable(forMapper: mapper), mapper)
        }
        for mapper in reliableMappers + ["vggt", "global_mapper-experimental"] {
            XCTAssertFalse(ReconstructionSummary.reprojectionErrorIsUnreliable(forMapper: mapper), mapper)
        }
    }
}
#endif
