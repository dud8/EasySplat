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
}
#endif
