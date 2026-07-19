import Foundation
import XCTest
@testable import EasySplatCore

final class TrainingResourceAdmissionTests: XCTestCase {
    private let gibibyte: UInt64 = 1_073_741_824

    func testHardwareMatrixKeepsConstrainedLaneAndUsesLiveCapacityOnLargerMacs() {
        let cases: [(installedGiB: UInt64, availableGiB: UInt64, expectedMaximumGiB: UInt64?)] = [
            (8, 7, 12),
            (16, 14, 12),
            (32, 25, nil),
            (48, 30, nil),
            (64, 46, nil),
        ]

        for entry in cases {
            let observation = makeObservation(
                installed: entry.installedGiB * gibibyte,
                available: entry.availableGiB * gibibyte,
                metalRecommended: entry.installedGiB * gibibyte,
                metalAllocated: 1 * gibibyte
            )
            let admission = TrainingMemoryBudget.admit(
                observation: observation,
                resourcePolicy: .maximumPerformance
            )

            XCTAssertGreaterThan(admission.allowedTrainerBytes, 0)
            XCTAssertLessThanOrEqual(
                admission.allowedTrainerBytes,
                admission.hostCapacityBytes,
                "\(entry.installedGiB) GiB lane"
            )
            XCTAssertLessThanOrEqual(
                admission.allowedTrainerBytes,
                admission.metalCapacityBytes ?? .max,
                "\(entry.installedGiB) GiB lane"
            )
            if let expectedMaximumGiB = entry.expectedMaximumGiB {
                XCTAssertLessThanOrEqual(
                    admission.allowedTrainerBytes,
                    expectedMaximumGiB * gibibyte,
                    "\(entry.installedGiB) GiB lane"
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    admission.allowedTrainerBytes,
                    entry.availableGiB * gibibyte * 4 / 5,
                    "larger Macs should use most genuinely available memory"
                )
            }
        }
    }

    func testFortyEightGiBMacWithThirtyGiBAvailableAdmitsTwentySevenPointSixGiB() {
        let observation = makeObservation(
            installed: 48 * gibibyte,
            available: 30 * gibibyte,
            metalRecommended: 40 * gibibyte,
            metalAllocated: 2 * gibibyte
        )

        let admission = TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .maximumPerformance
        )

        XCTAssertEqual(admission.hostHeadroomBytes, 48 * gibibyte / 20)
        XCTAssertEqual(admission.metalHeadroomBytes, 2 * gibibyte)
        XCTAssertEqual(admission.hostCapacityBytes, 30 * gibibyte - 48 * gibibyte / 20)
        XCTAssertEqual(admission.metalCapacityBytes, 36 * gibibyte)
        XCTAssertEqual(admission.allowedTrainerBytes, admission.hostCapacityBytes)
    }

    func testCurrentMetalAllocationReducesAdmissionWithoutOOMProbing() {
        let base = makeObservation(
            installed: 48 * gibibyte,
            available: 44 * gibibyte,
            metalRecommended: 36 * gibibyte,
            metalAllocated: 2 * gibibyte
        )
        var occupied = base
        occupied.metalCurrentAllocatedBytes = 12 * gibibyte

        let baseAdmission = TrainingMemoryBudget.admit(
            observation: base,
            resourcePolicy: .maximumPerformance
        )
        let occupiedAdmission = TrainingMemoryBudget.admit(
            observation: occupied,
            resourcePolicy: .maximumPerformance
        )

        XCTAssertEqual(
            baseAdmission.allowedTrainerBytes - occupiedAdmission.allowedTrainerBytes,
            10 * gibibyte
        )
        XCTAssertEqual(
            occupiedAdmission.metalCapacityBytes,
            36 * gibibyte - 12 * gibibyte - 36 * gibibyte / 20
        )
    }

    func testPressureTransitionsReduceAdmissionDeterministically() {
        let normalObservation = makeObservation(
            installed: 48 * gibibyte,
            available: 30 * gibibyte,
            metalRecommended: 48 * gibibyte,
            metalAllocated: 0
        )
        var warningObservation = normalObservation
        warningObservation.memoryPressure = .warning
        var criticalObservation = normalObservation
        criticalObservation.memoryPressure = .critical
        var unknownObservation = normalObservation
        unknownObservation.memoryPressure = .unknown
        unknownObservation.memoryPressureSource = .unavailable

        let normal = TrainingMemoryBudget.admit(
            observation: normalObservation,
            resourcePolicy: .automatic
        )
        let warning = TrainingMemoryBudget.admit(
            observation: warningObservation,
            resourcePolicy: .automatic
        )
        let critical = TrainingMemoryBudget.admit(
            observation: criticalObservation,
            resourcePolicy: .automatic
        )
        let unknown = TrainingMemoryBudget.admit(
            observation: unknownObservation,
            resourcePolicy: .automatic
        )

        XCTAssertEqual(warning.hostCapacityBytes, normal.hostCapacityBytes * 3 / 5)
        XCTAssertEqual(critical.hostCapacityBytes, normal.hostCapacityBytes / 3)
        XCTAssertEqual(unknown.hostCapacityBytes, normal.hostCapacityBytes * 4 / 5)
        XCTAssertGreaterThan(normal.allowedTrainerBytes, unknown.allowedTrainerBytes)
        XCTAssertGreaterThan(unknown.allowedTrainerBytes, warning.allowedTrainerBytes)
        XCTAssertGreaterThan(warning.allowedTrainerBytes, critical.allowedTrainerBytes)
    }

    func testKernelDispatchPressureLevelsMapWithoutGuessingUnknownValues() {
        XCTAssertEqual(
            LiveTrainingResourceObserver.pressureState(rawDispatchLevel: 1).state,
            .normal
        )
        XCTAssertEqual(
            LiveTrainingResourceObserver.pressureState(rawDispatchLevel: 2).state,
            .warning
        )
        XCTAssertEqual(
            LiveTrainingResourceObserver.pressureState(rawDispatchLevel: 4).state,
            .critical
        )
        let unknown = LiveTrainingResourceObserver.pressureState(
            rawDispatchLevel: 8
        )
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertEqual(unknown.source, .unavailable)
    }

    func testResourcePoliciesRemainOrderedWhenLiveLimitsAreGenerous() {
        let observation = makeObservation(
            installed: 64 * gibibyte,
            available: 64 * gibibyte,
            metalRecommended: 64 * gibibyte,
            metalAllocated: 0
        )
        let conserve = TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .conserveMemory
        )
        let automatic = TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .automatic
        )
        let maximum = TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .maximumPerformance
        )

        XCTAssertLessThan(conserve.allowedTrainerBytes, automatic.allowedTrainerBytes)
        XCTAssertLessThan(automatic.allowedTrainerBytes, maximum.allowedTrainerBytes)
    }

    func testMissingMetalDeviceUsesPolicyAndHostCaps() {
        let observation = makeObservation(
            installed: 32 * gibibyte,
            available: 24 * gibibyte,
            metalRecommended: nil,
            metalAllocated: nil
        )

        let admission = TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .automatic
        )

        XCTAssertNil(admission.metalHeadroomBytes)
        XCTAssertNil(admission.metalCapacityBytes)
        XCTAssertEqual(
            admission.allowedTrainerBytes,
            min(admission.policyCapacityBytes, admission.hostCapacityBytes)
        )
    }

    func testTrainerBudgetUsesLiveCapacityWithoutExceedingTheResolvedPlan() throws {
        let admission = TrainingMemoryBudget.admit(
            observation: makeObservation(
                installed: 48 * gibibyte,
                available: 30 * gibibyte,
                metalRecommended: 40 * gibibyte,
                metalAllocated: 2 * gibibyte
            ),
            resourcePolicy: .maximumPerformance
        )

        XCTAssertEqual(
            try TrainingMemoryBudget.trainerBudget(
                plannedBytes: 36 * Int64(gibibyte),
                admission: admission
            ),
            Int64(admission.allowedTrainerBytes)
        )
        XCTAssertEqual(
            try TrainingMemoryBudget.trainerBudget(
                plannedBytes: 20 * Int64(gibibyte),
                admission: admission
            ),
            20 * Int64(gibibyte)
        )
    }

    func testTrainerBudgetRequiresTheOriginalCheckpointBudgetToRemainAvailable() throws {
        let admission = TrainingMemoryBudget.admit(
            observation: makeObservation(
                installed: 48 * gibibyte,
                available: 20 * gibibyte,
                metalRecommended: 40 * gibibyte,
                metalAllocated: 2 * gibibyte
            ),
            resourcePolicy: .maximumPerformance
        )
        let available = Int64(admission.allowedTrainerBytes)

        XCTAssertEqual(
            try TrainingMemoryBudget.trainerBudget(
                plannedBytes: 36 * Int64(gibibyte),
                checkpointBytes: available,
                admission: admission
            ),
            available
        )
        XCTAssertThrowsError(
            try TrainingMemoryBudget.trainerBudget(
                plannedBytes: 36 * Int64(gibibyte),
                checkpointBytes: available + 1,
                admission: admission
            )
        ) {
            XCTAssertEqual(
                $0 as? TrainingResourceAdmissionError,
                .insufficientAvailableMemory(
                    requiredBytes: available + 1,
                    availableBytes: available
                )
            )
        }
    }

    func testConservativeMachFallbackDoesNotDoubleCountSpeculativePages() {
        let pages = HostMemoryPageEvidence(
            pageSizeBytes: 16_384,
            freePageCount: 100,
            inactivePageCount: 200,
            speculativePageCount: 50,
            purgeablePageCount: 10_000,
            compressedPageCount: 20_000
        )

        XCTAssertEqual(pages.conservativeAvailableBytes, 300 * 16_384)
        let saturated = HostMemoryPageEvidence(
            pageSizeBytes: .max,
            freePageCount: .max,
            inactivePageCount: .max,
            speculativePageCount: .max,
            purgeablePageCount: 0,
            compressedPageCount: 0
        )
        XCTAssertEqual(saturated.conservativeAvailableBytes, .max)
    }

    func testKernelAvailablePercentageIsClampedAndOverflowSafe() {
        XCTAssertEqual(
            LiveTrainingResourceObserver.availableBytes(
                installedBytes: 48 * gibibyte,
                kernelAvailablePercentage: 75,
                fallback: 1
            ),
            36 * gibibyte
        )
        XCTAssertEqual(
            LiveTrainingResourceObserver.availableBytes(
                installedBytes: 48 * gibibyte,
                kernelAvailablePercentage: 150,
                fallback: 1
            ),
            48 * gibibyte
        )
        XCTAssertEqual(
            LiveTrainingResourceObserver.availableBytes(
                installedBytes: UInt64.max,
                kernelAvailablePercentage: 100,
                fallback: 1
            ),
            UInt64.max
        )
    }

    func testInjectedObserverIsCapturedExactlyOnce() throws {
        let observation = makeObservation(
            installed: 32 * gibibyte,
            available: 20 * gibibyte,
            metalRecommended: 24 * gibibyte,
            metalAllocated: 1 * gibibyte
        )
        let counter = LockedCounter()
        let observer = LiveClockTrainingResourceObserver(observation: observation) {
            counter.increment()
        }

        let admission = try TrainingMemoryBudget.admit(
            observing: observer,
            resourcePolicy: .automatic
        )

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(
            admission.observation.installedMemoryBytes,
            observation.installedMemoryBytes
        )
        XCTAssertEqual(
            admission.observation.availableHostMemoryBytes,
            observation.availableHostMemoryBytes
        )
    }

    func testInjectedObserverRejectsEvidenceCapturedBeforeTheAdmissionCall() throws {
        var observation = makeObservation(
            installed: 32 * gibibyte,
            available: 20 * gibibyte,
            metalRecommended: 24 * gibibyte,
            metalAllocated: 1 * gibibyte
        )
        observation.clock = retreating(
            try LiveTrainingResourceObserver.captureClockEvidence(),
            seconds: 1
        )
        let observer = StubTrainingResourceObserver(observation: observation) {}

        XCTAssertThrowsError(
            try TrainingMemoryBudget.admit(
                observing: observer,
                resourcePolicy: .automatic
            )
        ) {
            XCTAssertEqual(
                $0 as? TrainingResourceAdmissionError,
                .staleObservation
            )
        }
    }

    func testLiveObserverCapturesBoundedMacOSEvidence() throws {
        let observation = try LiveTrainingResourceObserver().observe()

        XCTAssertGreaterThan(observation.installedMemoryBytes, 0)
        XCTAssertLessThanOrEqual(
            observation.availableHostMemoryBytes,
            observation.installedMemoryBytes
        )
        XCTAssertGreaterThan(observation.hostPages.pageSizeBytes, 0)
        XCTAssertGreaterThan(observation.clock.monotonicTicks, 0)
        XCTAssertGreaterThan(observation.clock.machTimebaseNumerator, 0)
        XCTAssertGreaterThan(observation.clock.machTimebaseDenominator, 0)
        XCTAssertGreaterThan(observation.clock.bootTimeSeconds, 0)
        if observation.memoryPressureSource == .unavailable {
            XCTAssertEqual(observation.memoryPressure, .unknown)
        } else {
            XCTAssertNotEqual(observation.memoryPressure, .unknown)
        }
        if let recommendation = observation.metalRecommendedWorkingSetBytes {
            XCTAssertGreaterThan(recommendation, 0)
            XCTAssertNotNil(observation.metalCurrentAllocatedBytes)
        }
        XCTAssertTrue(
            TrainingMemoryBudget.isValid(
                TrainingMemoryBudget.admit(
                    observation: observation,
                    resourcePolicy: .automatic
                )
            )
        )
    }

    func testSerializableDiagnosticContainsAdmissionAndTrainerMemoryEvidenceOnly() throws {
        let admission = TrainingMemoryBudget.admit(
            observation: makeObservation(
                installed: 48 * gibibyte,
                available: 30 * gibibyte,
                metalRecommended: 36 * gibibyte,
                metalAllocated: 2 * gibibyte
            ),
            resourcePolicy: .automatic
        )
        let trainerBudget = 8 * gibibyte
        let diagnostic = TrainingResourceDiagnosticEvidence(
            admission: admission,
            memoryBudgetBytes: trainerBudget,
            peakMemoryBytes: 8 * gibibyte,
            rasterExactBufferGrowthCount: 2,
            rasterExactBufferBytesAdded: 512 * 1_048_576
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(diagnostic)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"allowed_trainer_bytes\""))
        XCTAssertTrue(json.contains("\"memory_budget_bytes\":\(trainerBudget)"))
        XCTAssertTrue(json.contains("\"schema_version\":2"))
        XCTAssertTrue(json.contains("\"peak_memory_bytes\""))
        XCTAssertTrue(json.contains("\"raster_exact_buffer_bytes_added\""))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("notes"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("path"))
        XCTAssertEqual(
            try JSONDecoder().decode(TrainingResourceDiagnosticEvidence.self, from: data),
            diagnostic
        )
        XCTAssertTrue(TrainingMemoryBudget.isValid(diagnostic.admission))
    }

    func testPersistedAdmissionRejectsSchemaOrResolvedBudgetTampering() {
        let valid = TrainingMemoryBudget.admit(
            observation: makeObservation(
                installed: 48 * gibibyte,
                available: 30 * gibibyte,
                metalRecommended: 36 * gibibyte,
                metalAllocated: 2 * gibibyte
            ),
            resourcePolicy: .automatic
        )
        XCTAssertTrue(TrainingMemoryBudget.isValid(valid))

        var wrongSchema = valid
        wrongSchema.schemaVersion += 1
        XCTAssertFalse(TrainingMemoryBudget.isValid(wrongSchema))

        var inflated = valid
        inflated.allowedTrainerBytes += 1
        XCTAssertFalse(TrainingMemoryBudget.isValid(inflated))

        var rewrittenObservation = valid
        rewrittenObservation.observation.availableHostMemoryBytes += 1
        XCTAssertFalse(TrainingMemoryBudget.isValid(rewrittenObservation))
    }

    func testAdmissionRequiresSameBootAndAnObservationNoMoreThanFiveSecondsOld() throws {
        let observation = makeObservation(
            installed: 48 * gibibyte,
            available: 30 * gibibyte,
            metalRecommended: 36 * gibibyte,
            metalAllocated: 2 * gibibyte
        )
        let freshReference = advancing(observation.clock, seconds: 4)
        let admission = try TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .automatic,
            freshnessReference: freshReference
        )
        XCTAssertTrue(TrainingMemoryBudget.isFresh(admission, relativeTo: freshReference))

        let staleReference = advancing(observation.clock, seconds: 6)
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .automatic,
            freshnessReference: staleReference
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .staleObservation) }
        XCTAssertFalse(TrainingMemoryBudget.isFresh(admission, relativeTo: staleReference))

        var anotherBoot = observation.clock
        anotherBoot.bootTimeMicroseconds += 1
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .automatic,
            freshnessReference: anotherBoot
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .staleObservation) }

        var monotonicPredecessor = observation.clock
        monotonicPredecessor.monotonicTicks -= 1
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: observation,
            resourcePolicy: .automatic,
            freshnessReference: monotonicPredecessor
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .staleObservation) }
    }

    func testHostAvailabilitySourceMustMatchItsRawEvidence() {
        var fallback = makeObservation(
            installed: 48 * gibibyte,
            available: 1 * gibibyte,
            metalRecommended: nil,
            metalAllocated: nil
        )
        fallback.availableHostMemoryBytes += 16_384
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: fallback,
            resourcePolicy: .automatic,
            freshnessReference: fallback.clock
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .invalidObservation) }

        var kernel = makeObservation(
            installed: 48 * gibibyte,
            available: 1 * gibibyte,
            metalRecommended: nil,
            metalAllocated: nil
        )
        kernel.availableHostMemorySource = .kernelMemorystatusPercentage
        kernel.kernelAvailableMemoryPercentage = 50
        kernel.availableHostMemoryBytes = 24 * gibibyte
        XCTAssertNoThrow(try TrainingMemoryBudget.admit(
            observation: kernel,
            resourcePolicy: .automatic,
            freshnessReference: kernel.clock
        ))

        kernel.kernelAvailableMemoryPercentage = nil
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: kernel,
            resourcePolicy: .automatic,
            freshnessReference: kernel.clock
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .invalidObservation) }

        var overflow = fallback
        overflow.hostPages.freePageCount = .max
        overflow.hostPages.inactivePageCount = .max
        overflow.availableHostMemoryBytes = overflow.installedMemoryBytes
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: overflow,
            resourcePolicy: .automatic,
            freshnessReference: overflow.clock
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .invalidObservation) }
    }

    func testInvalidOrContradictoryObservationsFailClosed() {
        var noInstalledMemory = makeObservation(
            installed: 48 * gibibyte,
            available: 30 * gibibyte,
            metalRecommended: 36 * gibibyte,
            metalAllocated: 2 * gibibyte
        )
        noInstalledMemory.installedMemoryBytes = 0
        XCTAssertThrowsError(
            try TrainingMemoryBudget.admit(
                observation: noInstalledMemory,
                resourcePolicy: .automatic,
                freshnessReference: noInstalledMemory.clock
            )
        ) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .invalidObservation) }

        var exhaustedMetal = makeObservation(
            installed: 48 * gibibyte,
            available: 30 * gibibyte,
            metalRecommended: 8 * gibibyte,
            metalAllocated: 8 * gibibyte
        )
        exhaustedMetal.availableHostMemoryBytes = UInt64.max
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: exhaustedMetal,
            resourcePolicy: .automatic,
            freshnessReference: exhaustedMetal.clock
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .invalidObservation) }

        var contradictoryHost = makeObservation(
            installed: 48 * gibibyte,
            available: 1 * gibibyte,
            metalRecommended: nil,
            metalAllocated: nil
        )
        contradictoryHost.availableHostMemoryBytes = UInt64.max
        XCTAssertThrowsError(try TrainingMemoryBudget.admit(
            observation: contradictoryHost,
            resourcePolicy: .maximumPerformance,
            freshnessReference: contradictoryHost.clock
        )) { XCTAssertEqual($0 as? TrainingResourceAdmissionError, .invalidObservation) }
    }

    private func makeObservation(
        installed: UInt64,
        available: UInt64,
        metalRecommended: UInt64?,
        metalAllocated: UInt64?,
        pressure: MemoryPressureState = .normal
    ) -> TrainingResourceObservation {
        let pageSize: UInt64 = 16_384
        precondition(available.isMultiple(of: pageSize))
        return TrainingResourceObservation(
            clock: TrainingResourceClockEvidence(
                wallClock: Date(timeIntervalSince1970: 1_721_234_567),
                monotonicTicks: 123_456_789,
                machTimebaseNumerator: 125,
                machTimebaseDenominator: 3,
                bootTimeSeconds: 1_721_200_000,
                bootTimeMicroseconds: 123_456
            ),
            installedMemoryBytes: installed,
            availableHostMemoryBytes: available,
            availableHostMemorySource: .machVMFreeInactive,
            kernelAvailableMemoryPercentage: nil,
            hostPages: HostMemoryPageEvidence(
                pageSizeBytes: pageSize,
                freePageCount: available / pageSize,
                inactivePageCount: 0,
                speculativePageCount: 0,
                purgeablePageCount: 4,
                compressedPageCount: 5
            ),
            memoryPressure: pressure,
            memoryPressureSource: .kernelMemorystatus,
            metalRecommendedWorkingSetBytes: metalRecommended,
            metalCurrentAllocatedBytes: metalAllocated
        )
    }

    private func advancing(
        _ clock: TrainingResourceClockEvidence,
        seconds: UInt64
    ) -> TrainingResourceClockEvidence {
        var result = clock
        result.wallClock = clock.wallClock.addingTimeInterval(TimeInterval(seconds))
        let nanoseconds = seconds * 1_000_000_000
        let ticks = nanoseconds * UInt64(clock.machTimebaseDenominator)
            / UInt64(clock.machTimebaseNumerator)
        result.monotonicTicks += ticks
        return result
    }

    private func retreating(
        _ clock: TrainingResourceClockEvidence,
        seconds: UInt64
    ) -> TrainingResourceClockEvidence {
        var result = clock
        result.wallClock = clock.wallClock.addingTimeInterval(-TimeInterval(seconds))
        let nanoseconds = seconds * 1_000_000_000
        let ticks = nanoseconds * UInt64(clock.machTimebaseDenominator)
            / UInt64(clock.machTimebaseNumerator)
        precondition(clock.monotonicTicks > ticks)
        result.monotonicTicks -= ticks
        return result
    }
}

private extension TrainingMemoryBudget {
    static func admit(
        observation: TrainingResourceObservation,
        resourcePolicy: ResourcePolicy
    ) -> TrainingResourceAdmission {
        try! admit(
            observation: observation,
            resourcePolicy: resourcePolicy,
            freshnessReference: observation.clock
        )
    }
}

private struct StubTrainingResourceObserver: TrainingResourceObserving {
    let observation: TrainingResourceObservation
    let onObserve: @Sendable () -> Void

    func observe() throws -> TrainingResourceObservation {
        onObserve()
        return observation
    }
}

private struct LiveClockTrainingResourceObserver: TrainingResourceObserving {
    let observation: TrainingResourceObservation
    let onObserve: @Sendable () -> Void

    func observe() throws -> TrainingResourceObservation {
        onObserve()
        var result = observation
        result.clock = try LiveTrainingResourceObserver.captureClockEvidence()
        return result
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
