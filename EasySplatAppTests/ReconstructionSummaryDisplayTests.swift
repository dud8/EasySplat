import XCTest
import EasySplatCore
@testable import EasySplatApp

final class ReconstructionSummaryDisplayTests: XCTestCase {
    func testQualityRequiresMeasuredMetricsForStrongRating() {
        let coverageOnly = ReconstructionSummary(
            mapper: "vggt",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 30,
            totalImages: 30
        )
        XCTAssertEqual(coverageOnly.quality, .fair,
                       "Coverage-only summaries must not earn the 'strong' rating because we have no quality evidence.")
        XCTAssertTrue(coverageOnly.hasOnlyCoverage)
    }

    func testQualityStrongRequiresGoodMetricsAcrossTheBoard() {
        let strong = ReconstructionSummary(
            mapper: "global_mapper",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 30,
            totalImages: 30,
            meanReprojectionError: 0.85,
            pointCount: 14_000,
            observationCount: 56_000,
            meanTrackLength: 4.5
        )
        XCTAssertEqual(strong.quality, .strong)
        XCTAssertFalse(strong.hasOnlyCoverage)
    }

    func testQualityDowngradesToFairWhenReprojectionMissing() {
        let summary = ReconstructionSummary(
            mapper: "da3-direct",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 28,
            totalImages: 30,
            meanReprojectionError: nil,
            pointCount: 10_000,
            observationCount: 40_000,
            meanTrackLength: 4.2
        )
        XCTAssertEqual(summary.quality, .fair)
    }

    func testQualityDowngradesToLowOnBadReprojectionEvenWithHighCoverage() {
        let summary = ReconstructionSummary(
            mapper: "global_mapper",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 30,
            totalImages: 30,
            meanReprojectionError: 4.0,
            pointCount: 14_000,
            observationCount: 56_000,
            meanTrackLength: 4.0
        )
        XCTAssertEqual(summary.quality, .low)
    }

    func testCompactSummaryOmitsAbsentFields() {
        let summary = ReconstructionSummary(
            mapper: "vggt",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 18,
            totalImages: 20
        )
        XCTAssertEqual(summary.compactSummary, "18/20 frames")
    }

    func testCompactSummaryIncludesPointsAndReprojWhenPresent() {
        let summary = ReconstructionSummary(
            mapper: "mapanything-direct",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 27,
            totalImages: 30,
            meanReprojectionError: 0.85,
            pointCount: 14_231
        )
        XCTAssertEqual(summary.compactSummary, "27/30 frames · 14.2k pts · 0.85 px")
    }

    func testDisplayMapperFriendlyLabels() {
        let labels: [(String, String)] = [
            ("da3-direct", "Depth Anything 3"),
            ("mapanything-direct", "MapAnything (direct)"),
            ("vggt", "VGGT"),
            ("point_triangulator+bundle_adjuster", "Point triangulator + BA"),
            ("global_mapper", "GLOMAP (global mapper, GPU)"),
            ("global_mapper-cpu", "GLOMAP (global mapper, CPU)"),
            ("colmap", "COLMAP (mapper)")
        ]
        for (raw, expected) in labels {
            let summary = ReconstructionSummary(
                mapper: raw,
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 1,
                totalImages: 1
            )
            XCTAssertEqual(summary.displayMapper, expected, "Display label mismatch for \(raw)")
        }
    }

    func testStageTimingDisplayFormatsDurations() {
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 0), "0s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 45), "45s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 60), "1m")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 150), "2m 30s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 3600), "1h")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 3725), "1h 2m")
    }

    func testStageTimingComparisonHandlesUnavailableInputs() {
        XCTAssertEqual(StageTimingComparison.compute(timings: [], medianSeconds: 100), .unavailable)
        XCTAssertEqual(
            StageTimingComparison.compute(
                timings: [.init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60)],
                medianSeconds: nil
            ),
            .unavailable
        )
    }

    func testStageTimingComparisonDeadbandReportsWithinBand() {
        let timings: [StageTimingRecord] = [
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 105)
        ]
        XCTAssertEqual(
            StageTimingComparison.compute(timings: timings, medianSeconds: 100),
            .withinBand
        )
    }

    func testStageTimingComparisonReportsSlowerAndFaster() {
        let slower: [StageTimingRecord] = [
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 130)
        ]
        XCTAssertEqual(
            StageTimingComparison.compute(timings: slower, medianSeconds: 100),
            .slowerBy(percent: 30)
        )
        let faster: [StageTimingRecord] = [
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 70)
        ]
        XCTAssertEqual(
            StageTimingComparison.compute(timings: faster, medianSeconds: 100),
            .fasterBy(percent: 30)
        )
    }

    func testStageTimingSurfaceableStagesHidesImportInput() {
        let timings: [StageTimingRecord] = [
            .init(stage: .importInput, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 1),
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 10), durationSeconds: 60),
            .init(stage: .trainBrush, startedAt: Date(timeIntervalSince1970: 100), durationSeconds: 120)
        ]
        let surfaced = StageTimingDisplay.surfaceableStages(from: timings)
        XCTAssertEqual(surfaced.map { $0.stage }, [.sfmFeatures, .trainBrush])
    }
}
