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

    func testGlobalMapperReprojectionIsDroppedFromSummary() {
        for mapper in ["global_mapper", "global_mapper-gpu", "global_mapper-cpu"] {
            let summary = ReconstructionSummary(score: makeScore(reproj: 0.0003), mapper: mapper, capturedAt: Date())
            XCTAssertNil(summary.meanReprojectionError,
                         "\(mapper): GLOMAP's non-pixel reprojection error must not be persisted.")
            // Every other real metric is preserved.
            XCTAssertEqual(summary.registeredImages, 30)
            XCTAssertEqual(summary.pointCount, 14_000)
            XCTAssertEqual(summary.observationCount, 56_000)
            XCTAssertEqual(summary.meanTrackLength, 4.0)
        }
    }

    func testColmapAndNeuralMappersKeepReprojection() {
        for mapper in ["colmap", "point_triangulator+bundle_adjuster", "point_triangulator", "mapanything-refinement"] {
            let summary = ReconstructionSummary(score: makeScore(reproj: 1.5), mapper: mapper, capturedAt: Date())
            XCTAssertEqual(summary.meanReprojectionError, 1.5,
                           "\(mapper): a real pixel reprojection error must be preserved.")
        }
    }

    func testGlobalMapperSummaryMapperDiscriminatorIsExact() {
        XCTAssertTrue(ReconstructionSummary.isGlobalMapperSummaryMapper("global_mapper"))
        XCTAssertTrue(ReconstructionSummary.isGlobalMapperSummaryMapper("global_mapper-gpu"))
        XCTAssertTrue(ReconstructionSummary.isGlobalMapperSummaryMapper("global_mapper-cpu"))
        // Must not catch the plain COLMAP mapper or unrelated labels.
        XCTAssertFalse(ReconstructionSummary.isGlobalMapperSummaryMapper("colmap"))
        XCTAssertFalse(ReconstructionSummary.isGlobalMapperSummaryMapper("global_mapper-experimental"))
        XCTAssertFalse(ReconstructionSummary.isGlobalMapperSummaryMapper("vggt"))
    }
}
#endif
