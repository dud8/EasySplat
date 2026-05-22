#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class SmartFrameSelectionTests: XCTestCase {
    func testSelectBatchTargetsFPS() {
        let scores = (0..<30).map { (index: $0, sharpness: Double($0)) }
        var lastSelected = -999
        let config = SmartFrameSelectionConfig(targetFPS: 3, minDistanceRatio: 0.20, sharpnessFloor: 0, sharpnessRatio: 0)
        let result = SmartFrameSelection.selectBatch(scores: scores, config: config, fps: 30, lastSelectedIndex: &lastSelected)
        XCTAssertEqual(result.selectedIndices, [5, 15, 25])
    }

    func testAntiClusterSkipsTooCloseFrames() {
        let scores = (0..<30).map { (index: $0, sharpness: Double($0)) }
        var lastSelected = 4
        let config = SmartFrameSelectionConfig(targetFPS: 3, minDistanceRatio: 0.20, sharpnessFloor: 0, sharpnessRatio: 0)
        let result = SmartFrameSelection.selectBatch(scores: scores, config: config, fps: 30, lastSelectedIndex: &lastSelected)
        XCTAssertFalse(result.selectedIndices.contains(5))
        XCTAssertEqual(result.selectedIndices, [15, 25])
    }

    func testDynamicThresholdFiltersCandidates() {
        let scores = (0..<30).map { index -> (index: Int, sharpness: Double) in
            switch index {
            case 10: return (index, 100)
            case 20: return (index, 80)
            case 29: return (index, 70)
            default: return (index, 10)
            }
        }
        var lastSelected = -999
        let config = SmartFrameSelectionConfig(targetFPS: 3, minDistanceRatio: 0.20, sharpnessFloor: 40, sharpnessRatio: 0.6)
        let result = SmartFrameSelection.selectBatch(scores: scores, config: config, fps: 30, lastSelectedIndex: &lastSelected)
        let candidateSet: Set<Int> = [10, 20, 29]
        XCTAssertTrue(result.selectedIndices.allSatisfy { candidateSet.contains($0) })
    }

    func testThresholdCanYieldEmptySelection() {
        let scores = (0..<30).map { (index: $0, sharpness: 5.0) }
        var lastSelected = -999
        let config = SmartFrameSelectionConfig(targetFPS: 3, minDistanceRatio: 0.20, sharpnessFloor: 40, sharpnessRatio: 0.6)
        let result = SmartFrameSelection.selectBatch(scores: scores, config: config, fps: 30, lastSelectedIndex: &lastSelected)
        XCTAssertTrue(result.selectedIndices.isEmpty)
    }

    func testSelectBatchPrefersCleanNearbyCandidateOverClippedTarget() {
        var candidates = (0..<30).map {
            SmartFrameCandidate(index: $0, sharpness: 10, brightness: 0.5, clippedFraction: 0, dHash: UInt64($0 + 100))
        }
        candidates[5] = SmartFrameCandidate(index: 5, sharpness: 120, brightness: 0.96, clippedFraction: 0.65, dHash: 1)
        candidates[6] = SmartFrameCandidate(index: 6, sharpness: 60, brightness: 0.52, clippedFraction: 0.01, dHash: 2)
        candidates[15] = SmartFrameCandidate(index: 15, sharpness: 90, brightness: 0.50, clippedFraction: 0.00, dHash: 3)
        candidates[25] = SmartFrameCandidate(index: 25, sharpness: 90, brightness: 0.50, clippedFraction: 0.00, dHash: 4)

        var lastSelected = -999
        var recentHashes: [UInt64] = []
        let config = SmartFrameSelectionConfig(targetFPS: 3, minDistanceRatio: 0.20, sharpnessFloor: 40, sharpnessRatio: 0.6)
        let result = SmartFrameSelection.selectBatch(
            candidates: candidates,
            config: config,
            fps: 30,
            lastSelectedIndex: &lastSelected,
            recentHashes: &recentHashes
        )

        XCTAssertEqual(result.selectedIndices, [6, 15, 25])
    }

    func testSelectBatchAvoidsRecentNearDuplicateHashWhenAlternativeExists() {
        var candidates = (0..<30).map {
            SmartFrameCandidate(index: $0, sharpness: 10, brightness: 0.5, clippedFraction: 0, dHash: UInt64($0 + 100))
        }
        candidates[5] = SmartFrameCandidate(index: 5, sharpness: 100, brightness: 0.50, clippedFraction: 0.00, dHash: 0b1111)
        candidates[6] = SmartFrameCandidate(index: 6, sharpness: 60, brightness: 0.50, clippedFraction: 0.00, dHash: 0xffff_ffff_ffff_0000)
        candidates[15] = SmartFrameCandidate(index: 15, sharpness: 95, brightness: 0.50, clippedFraction: 0.00, dHash: 0xffff_0000_ffff_0000)
        candidates[25] = SmartFrameCandidate(index: 25, sharpness: 95, brightness: 0.50, clippedFraction: 0.00, dHash: 0x0000_ffff_0000_ffff)

        var lastSelected = -999
        var recentHashes: [UInt64] = [0b1110]
        let config = SmartFrameSelectionConfig(targetFPS: 3, minDistanceRatio: 0.20, sharpnessFloor: 40, sharpnessRatio: 0.6)
        let result = SmartFrameSelection.selectBatch(
            candidates: candidates,
            config: config,
            fps: 30,
            lastSelectedIndex: &lastSelected,
            recentHashes: &recentHashes
        )

        XCTAssertEqual(result.selectedIndices, [6, 15, 25])
    }

    func testSelectBatchUsesNextCandidateWhenFittestCandidateIsTooClose() {
        var candidates = (0..<30).map {
            SmartFrameCandidate(index: $0, sharpness: 5, brightness: 0.5, clippedFraction: 0, dHash: UInt64($0 + 100))
        }
        candidates[12] = SmartFrameCandidate(index: 12, sharpness: 140, brightness: 0.50, clippedFraction: 0, dHash: 1)
        candidates[15] = SmartFrameCandidate(index: 15, sharpness: 80, brightness: 0.50, clippedFraction: 0, dHash: 2)

        var lastSelected = 8
        var recentHashes: [UInt64] = []
        let config = SmartFrameSelectionConfig(targetFPS: 1, minDistanceRatio: 0.20, sharpnessFloor: 40, sharpnessRatio: 0.5)
        let result = SmartFrameSelection.selectBatch(
            candidates: candidates,
            config: config,
            fps: 30,
            lastSelectedIndex: &lastSelected,
            recentHashes: &recentHashes
        )

        XCTAssertEqual(result.selectedIndices, [15])
    }

    func testCandidateFilteringHonorsSharpnessRatioAfterQualityPenalties() {
        let candidates = [
            SmartFrameCandidate(index: 0, sharpness: 1_000, brightness: 0.5, clippedFraction: 0, dHash: 1),
            SmartFrameCandidate(index: 1, sharpness: 50, brightness: 0.5, clippedFraction: 0, dHash: 2),
            SmartFrameCandidate(index: 2, sharpness: 120, brightness: 0.98, clippedFraction: 0.8, dHash: 3)
        ]
        let config = SmartFrameSelectionConfig(targetFPS: 1, minDistanceRatio: 0, sharpnessFloor: 40, sharpnessRatio: 0.6)

        let filtered = SmartFrameSelection.qualityFilteredCandidates(candidates, config: config).map(\.index)

        XCTAssertEqual(filtered, [0])
    }
}
#endif
