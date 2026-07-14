import XCTest
@testable import EasySplatCore

final class TrainingMemoryBudgetTests: XCTestCase {
    private let gibibyte: UInt64 = 1_073_741_824

    func testBudgetUsesMostOfMetalWorkingSetWhileLeavingHeadroom() {
        let physical = 48 * gibibyte
        let metalWorkingSet = 36 * gibibyte

        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: physical,
                recommendedMetalWorkingSetBytes: metalWorkingSet,
                resourcePolicy: .automatic
            ),
            Int64(metalWorkingSet * 9 / 10)
        )
        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: physical,
                recommendedMetalWorkingSetBytes: metalWorkingSet,
                resourcePolicy: .maximumPerformance
            ),
            Int64(metalWorkingSet * 49 / 50)
        )
        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: physical,
                recommendedMetalWorkingSetBytes: metalWorkingSet,
                resourcePolicy: .conserveMemory
            ),
            Int64(metalWorkingSet * 3 / 5)
        )
    }

    func testBudgetReservesMemoryWhenMetalDoesNotReportAWorkingSet() {
        let physical = 24 * gibibyte
        let afterReserve = physical - max(2 * gibibyte, physical / 10)

        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: physical,
                recommendedMetalWorkingSetBytes: nil,
                resourcePolicy: .automatic
            ),
            Int64(afterReserve * 9 / 10)
        )
    }

    func testMaximumPerformanceCannotBypassConstrainedMacHeadroom() {
        let physical = 16 * gibibyte
        let metalWorkingSet = 12 * gibibyte
        let automatic = TrainingMemoryBudget.resolve(
            physicalMemoryBytes: physical,
            recommendedMetalWorkingSetBytes: metalWorkingSet,
            resourcePolicy: .automatic
        )

        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: physical,
                recommendedMetalWorkingSetBytes: metalWorkingSet,
                resourcePolicy: .maximumPerformance
            ),
            automatic
        )
    }

    func testConstrainedLaneIsCappedAtTwelveGiBThroughExactBoundary() {
        let boundary = 33 * gibibyte / 2
        let cap = 12 * gibibyte

        for policy: ResourcePolicy in [.automatic, .conserveMemory, .maximumPerformance] {
            let resolved = TrainingMemoryBudget.resolve(
                physicalMemoryBytes: boundary,
                recommendedMetalWorkingSetBytes: boundary,
                resourcePolicy: policy
            )
            XCTAssertLessThanOrEqual(resolved, Int64(cap), "policy: \(policy)")
        }
        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: boundary,
                recommendedMetalWorkingSetBytes: boundary,
                resourcePolicy: .automatic
            ),
            Int64(cap)
        )
    }

    func testMemoryAboveConstrainedBoundaryUsesNormalPerformanceFraction() {
        let physical = 33 * gibibyte / 2 + 1
        let physicalHeadroom = physical - 2 * gibibyte

        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: physical,
                recommendedMetalWorkingSetBytes: physical,
                resourcePolicy: .maximumPerformance
            ),
            Int64(physicalHeadroom * 49 / 50)
        )
    }

    func testBudgetNeverExceedsPhysicalHeadroomOrMetalRecommendation() {
        let physical = 8 * gibibyte
        let physicalHeadroom = physical - 2 * gibibyte

        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                physicalMemoryBytes: physical,
                recommendedMetalWorkingSetBytes: 64 * gibibyte,
                resourcePolicy: .maximumPerformance
            ),
            Int64(physicalHeadroom * 9 / 10)
        )
    }

    func testHardwareConvenienceRejectsNonFiniteMeasurements() {
        XCTAssertEqual(
            TrainingMemoryBudget.resolve(
                hardware: HardwareProfile(
                    memoryGB: .infinity,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                ),
                resourcePolicy: .automatic
            ),
            0
        )

        let invalidMetal = TrainingMemoryBudget.resolve(
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: .infinity
            ),
            resourcePolicy: .automatic
        )
        let missingMetal = TrainingMemoryBudget.resolve(
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: nil
            ),
            resourcePolicy: .automatic
        )
        XCTAssertEqual(invalidMetal, missingMetal)
    }
}
