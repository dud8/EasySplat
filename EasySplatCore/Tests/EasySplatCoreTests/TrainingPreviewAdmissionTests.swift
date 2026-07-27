import XCTest
@testable import EasySplatCore

final class TrainingPreviewAdmissionTests: XCTestCase {
    private let gibibyte: Int64 = 1_073_741_824

    private func evaluate(
        admittedTrainerBytes: Int64,
        physicalMemoryBytes: UInt64 = 64 * 1_073_741_824,
        memoryPressure: MemoryPressureState = .normal
    ) -> TrainingPreviewPermit {
        TrainingPreviewAdmissionPolicy.evaluate(
            admission: makeTestTrainingResourceAdmission(),
            admittedTrainerBytes: admittedTrainerBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            memoryPressure: memoryPressure
        )
    }

    func testGrantsWhenTheTrainerLeftMoreThanTheReserveUnspent() {
        let admission = makeTestTrainingResourceAdmission()
        let allowed = Int64(admission.allowedTrainerBytes)
        let permit = evaluate(
            admittedTrainerBytes: allowed - TrainingPreviewAdmissionPolicy.previewReserveBytes
        )
        XCTAssertTrue(permit.isGranted)
    }

    func testRefusesWhenTheTrainerTookAlmostEverything() {
        let admission = makeTestTrainingResourceAdmission()
        let allowed = Int64(admission.allowedTrainerBytes)
        let permit = evaluate(
            admittedTrainerBytes: allowed - TrainingPreviewAdmissionPolicy.previewReserveBytes + 1
        )
        XCTAssertEqual(permit.refusal, .insufficientSurplus)
    }

    func testRefusesOnConstrainedMemoryMachines() {
        // 16 GB sits inside the trainer's own constrained tier; there is no surplus
        // to lend a preview there however the rest of the numbers land.
        let permit = evaluate(
            admittedTrainerBytes: gibibyte,
            physicalMemoryBytes: 16 * 1_073_741_824
        )
        XCTAssertEqual(permit.refusal, .constrainedMemory)
    }

    func testAnythingOtherThanObservedNormalPressureFailsClosed() {
        for pressure: MemoryPressureState in [.warning, .critical, .unknown] {
            let permit = evaluate(admittedTrainerBytes: gibibyte, memoryPressure: pressure)
            XCTAssertEqual(
                permit.refusal,
                .memoryPressure,
                "\(pressure) must refuse: an unobserved reading is not evidence of calm"
            )
        }
    }

    func testRefusesAnImpossibleTrainerBudget() {
        XCTAssertEqual(evaluate(admittedTrainerBytes: 0).refusal, .invalidObservation)
        XCTAssertEqual(evaluate(admittedTrainerBytes: -1).refusal, .invalidObservation)
    }

    /// The whole point of the policy: a preview is funded from headroom the trainer
    /// declined, never by taking capacity away from it.
    func testPreviewNeverReducesTheTrainerBudget() {
        let admission = makeTestTrainingResourceAdmission()
        let allowed = Int64(admission.allowedTrainerBytes)
        let admitted = allowed - TrainingPreviewAdmissionPolicy.previewReserveBytes
        XCTAssertTrue(evaluate(admittedTrainerBytes: admitted).isGranted)
        // The trainer's own budget is an input, not an output: evaluating the permit
        // cannot change what training was admitted.
        XCTAssertEqual(Int64(makeTestTrainingResourceAdmission().allowedTrainerBytes), allowed)
    }
}
