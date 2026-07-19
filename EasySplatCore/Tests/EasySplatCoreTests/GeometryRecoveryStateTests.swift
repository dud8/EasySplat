import XCTest
@testable import EasySplatCore

final class GeometryRecoveryStateTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let imageNames = [
        "frame 0001.jpg",
        "frame_0002.jpg",
        "frame_0003.jpg",
    ]

    func testValidDA3StateRoundTrips() throws {
        let state = GeometryRecoveryState(
            selectedFramesDigest: digest,
            orderedImageNames: imageNames,
            activeBackend: .da3,
            mappingAttemptCount: 2,
            mappingFallbackReasons: ["Initial seeded refinement did not meet coverage."]
        )

        try state.validate()
        XCTAssertEqual(state.schemaVersion, GeometryRecoveryState.currentSchemaVersion)
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testValidPrimaryColmapCadenceRoundTripsWithPairGraphBinding() throws {
        let state = GeometryRecoveryState(
            selectedFramesDigest: digest,
            orderedImageNames: imageNames,
            activeBackend: .colmap,
            mappingAttemptCount: 1,
            mappingFallbackReasons: [],
            pendingPairRecoveryLevel: .expanded,
            colmapComputeMode: .cpu,
            plannedIncrementalCadence: .balancedGlobal,
            activeIncrementalCadence: .balancedGlobal,
            acceptedPairAttemptOrdinal: 2,
            pairListDigest: digest,
            matchingDatabaseDigest: String(repeating: "b", count: 64)
        )

        try state.validate()
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testValidOrderedCadenceFallbackRoundTrips() throws {
        let state = colmapState(
            mappingAttemptCount: 2,
            plannedCadence: .orderedFast,
            activeCadence: .balancedGlobal,
            fallbackTrigger: .excessiveResiduals
        )

        try state.validate()
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testValidBalancedCadenceFallbackRoundTrips() throws {
        let state = colmapState(
            mappingAttemptCount: 2,
            plannedCadence: .balancedGlobal,
            activeCadence: .frequentGlobal,
            fallbackTrigger: .lowRegisteredViewCoverage
        )

        try state.validate()
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testRejectsEveryNonCurrentSchema() {
        XCTAssertEqual(GeometryRecoveryState.currentSchemaVersion, 8)

        for schemaVersion in [7, 9, Int.max] {
            var state = validState()
            state.schemaVersion = schemaVersion

            XCTAssertThrowsError(try state.validate(), "schema: \(schemaVersion)") { error in
                XCTAssertEqual(
                    error as? GeometryRecoveryState.ValidationError,
                    .invalidSchema(schemaVersion)
                )
            }
        }
    }

    func testRejectsMalformedSelectedFramesDigest() {
        for invalidDigest in [
            String(repeating: "a", count: 63),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            var state = validState()
            state.selectedFramesDigest = invalidDigest

            XCTAssertThrowsError(try state.validate(), invalidDigest)
        }
    }

    func testRejectsEmptyDuplicateOrUnsafeImageNames() {
        let invalidNames = [
            [],
            ["frame_0001.jpg", "frame_0001.jpg"],
            [""],
            ["."],
            [".."],
            ["folder/frame.jpg"],
            ["folder\\frame.jpg"],
            ["frame\n.jpg"],
        ]

        for names in invalidNames {
            var state = validState()
            state.orderedImageNames = names

            XCTAssertThrowsError(try state.validate(), "\(names)")
        }
    }

    func testRejectsNegativeMappingAttemptCount() {
        var state = validState()
        state.mappingAttemptCount = -1

        XCTAssertThrowsError(try state.validate())
    }

    func testRejectsMappingAttemptCountThatCouldOverflowThePipeline() {
        var state = validState()
        state.mappingAttemptCount = Int.max

        XCTAssertThrowsError(try state.validate())
    }

    func testAcceptsFallbackReasonsAtSizeLimits() throws {
        var state = validState()
        state.mappingFallbackReasons = (0..<16).map(reasonWith4096Bytes)

        try state.validate()
    }

    func testRejectsInvalidFallbackReasons() {
        let invalidReasons = [
            [""],
            ["   "],
            [" leading"],
            ["trailing "],
            ["line\nbreak"],
            [String(repeating: "é", count: 2_049)],
            ["same reason", "same reason"],
            (0..<17).map(reasonWith4096Bytes),
        ]

        for reasons in invalidReasons {
            var state = validState()
            state.mappingFallbackReasons = reasons

            XCTAssertThrowsError(try state.validate(), "reason count: \(reasons.count)")
        }
    }

    func testRejectsBackendSpecificFieldsOnTheWrongRoute() {
        var da3State = validState()
        da3State.activeBackend = .da3
        da3State.pendingPairRecoveryLevel = .maximum

        var da3ComputeState = validState()
        da3ComputeState.activeBackend = .da3

        var da3CadenceState = validState()
        da3CadenceState.activeBackend = .da3
        da3CadenceState.colmapComputeMode = nil

        var colmapComputeState = validState()
        colmapComputeState.colmapComputeMode = nil

        XCTAssertThrowsError(try da3State.validate())
        XCTAssertThrowsError(try da3ComputeState.validate())
        XCTAssertThrowsError(try da3CadenceState.validate())
        XCTAssertThrowsError(try colmapComputeState.validate())
    }

    func testRejectsMissingOrUnrecognizedColmapCadence() {
        var missingPlanned = validState()
        missingPlanned.plannedIncrementalCadence = nil

        var missingActive = validState()
        missingActive.activeIncrementalCadence = nil

        var unrelatedActive = validState()
        unrelatedActive.activeIncrementalCadence = IncrementalMappingCadenceArtifact(
            localMaxRefinements: 1,
            globalFramesRatio: 2,
            globalPointsRatio: 2,
            globalMaxRefinements: 5
        )

        var invalidPlanned = validState()
        invalidPlanned.plannedIncrementalCadence?.globalFramesRatio = .nan

        XCTAssertThrowsError(try missingPlanned.validate())
        XCTAssertThrowsError(try missingActive.validate())
        XCTAssertThrowsError(try unrelatedActive.validate())
        XCTAssertThrowsError(try invalidPlanned.validate())
    }

    func testRejectsCadenceTransitionWithoutFallbackTrigger() {
        let transitions: [(
            IncrementalMappingCadenceArtifact,
            IncrementalMappingCadenceArtifact
        )] = [
            (IncrementalMappingCadenceArtifact.orderedFast, .balancedGlobal),
            (.balancedGlobal, .frequentGlobal),
        ]
        for (planned, active) in transitions {
            let state = colmapState(
                plannedCadence: planned,
                activeCadence: active,
                fallbackTrigger: nil
            )

            assertInvalidBackendFields(state)
        }
    }

    func testRejectsFallbackTriggerWithoutCadenceTransition() {
        let cadences: [IncrementalMappingCadenceArtifact] = [
            IncrementalMappingCadenceArtifact.orderedFast,
            .balancedGlobal,
            .frequentGlobal,
        ]
        for cadence in cadences {
            let state = colmapState(
                plannedCadence: cadence,
                activeCadence: cadence,
                fallbackTrigger: .insufficientParallax
            )

            assertInvalidBackendFields(state)
        }
    }

    func testRejectsIllegalCadenceTransitionsEvenWithEligibleTrigger() {
        let illegalTransitions: [(
            IncrementalMappingCadenceArtifact,
            IncrementalMappingCadenceArtifact
        )] = [
            (IncrementalMappingCadenceArtifact.orderedFast, .frequentGlobal),
            (.balancedGlobal, .orderedFast),
            (.frequentGlobal, .balancedGlobal),
            (.frequentGlobal, .orderedFast),
        ]

        for (planned, active) in illegalTransitions {
            let state = colmapState(
                plannedCadence: planned,
                activeCadence: active,
                fallbackTrigger: .degeneratePointDistribution
            )

            assertInvalidBackendFields(state)
        }
    }

    func testStartedColmapMappingRequiresCompletePairGraphBinding() {
        var missingOrdinal = colmapState()
        missingOrdinal.acceptedPairAttemptOrdinal = nil

        var missingPairDigest = colmapState()
        missingPairDigest.pairListDigest = nil

        var missingDatabaseDigest = colmapState()
        missingDatabaseDigest.matchingDatabaseDigest = nil

        for state in [missingOrdinal, missingPairDigest, missingDatabaseDigest] {
            assertInvalidBackendFields(state)
        }
    }

    func testRejectsInvalidPairGraphOrdinalAndDigests() {
        for invalidOrdinal in [0, -1] {
            var state = colmapState()
            state.acceptedPairAttemptOrdinal = invalidOrdinal
            assertInvalidBackendFields(state)
        }

        for invalidDigest in [
            String(repeating: "a", count: 63),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            var invalidPairDigest = colmapState()
            invalidPairDigest.pairListDigest = invalidDigest
            assertInvalidBackendFields(invalidPairDigest)

            var invalidDatabaseDigest = colmapState()
            invalidDatabaseDigest.matchingDatabaseDigest = invalidDigest
            assertInvalidBackendFields(invalidDatabaseDigest)
        }
    }

    func testBindingRequiresExactImageOrderAndDigest() throws {
        let state = validState()

        try state.validateBinding(
            expectedImageNames: imageNames,
            expectedSelectedFramesDigest: digest,
            expectedGeometryBackend: .colmap,
            expectedPlannedIncrementalCadence: state.plannedIncrementalCadence
        )
        XCTAssertThrowsError(
            try state.validateBinding(
                expectedImageNames: imageNames.reversed(),
                expectedSelectedFramesDigest: digest,
                expectedGeometryBackend: .colmap,
                expectedPlannedIncrementalCadence: state.plannedIncrementalCadence
            )
        )
        XCTAssertThrowsError(
            try state.validateBinding(
                expectedImageNames: imageNames,
                expectedSelectedFramesDigest: String(repeating: "b", count: 64),
                expectedGeometryBackend: .colmap,
                expectedPlannedIncrementalCadence: state.plannedIncrementalCadence
            )
        )
        XCTAssertThrowsError(
            try state.validateBinding(
                expectedImageNames: imageNames,
                expectedSelectedFramesDigest: digest,
                expectedGeometryBackend: .colmap,
                expectedPlannedIncrementalCadence: IncrementalMappingCadenceArtifact(
                    localMaxRefinements: 1,
                    globalFramesRatio: 8,
                    globalPointsRatio: 8,
                    globalMaxRefinements: 5
                )
            )
        )
    }

    func testRecoveryBindingRejectsAStaleDifferentGeometryRoute() throws {
        let da3State = GeometryRecoveryState(
            selectedFramesDigest: digest,
            orderedImageNames: imageNames,
            activeBackend: .da3,
            mappingAttemptCount: 1,
            mappingFallbackReasons: []
        )
        let colmapState = validState()

        XCTAssertThrowsError(try da3State.validateBinding(
            expectedImageNames: imageNames,
            expectedSelectedFramesDigest: digest,
            expectedGeometryBackend: .colmap,
            expectedPlannedIncrementalCadence: .balancedGlobal
        )) { error in
            XCTAssertEqual(
                error as? GeometryRecoveryState.ValidationError,
                .bindingMismatch
            )
        }
        XCTAssertThrowsError(try colmapState.validateBinding(
            expectedImageNames: imageNames,
            expectedSelectedFramesDigest: digest,
            expectedGeometryBackend: .da3,
            expectedPlannedIncrementalCadence: nil
        )) { error in
            XCTAssertEqual(
                error as? GeometryRecoveryState.ValidationError,
                .bindingMismatch
            )
        }
    }

    func testRecoveryBindingAcceptsInterruptedStateOnlyOnItsResolvedRoute() throws {
        let da3State = GeometryRecoveryState(
            selectedFramesDigest: digest,
            orderedImageNames: imageNames,
            activeBackend: .da3,
            mappingAttemptCount: 1,
            mappingFallbackReasons: ["interrupted mapping resumed"]
        )
        let colmapState = colmapState(mappingAttemptCount: 2)

        try da3State.validateBinding(
            expectedImageNames: imageNames,
            expectedSelectedFramesDigest: digest,
            expectedGeometryBackend: .da3,
            expectedPlannedIncrementalCadence: nil
        )
        try colmapState.validateBinding(
            expectedImageNames: imageNames,
            expectedSelectedFramesDigest: digest,
            expectedGeometryBackend: .colmap,
            expectedPlannedIncrementalCadence: .balancedGlobal
        )
    }

    private func roundTrip(_ state: GeometryRecoveryState) throws -> GeometryRecoveryState {
        let data = try JSONEncoder().encode(state)
        return try JSONDecoder().decode(GeometryRecoveryState.self, from: data)
    }

    private func validState() -> GeometryRecoveryState {
        GeometryRecoveryState(
            selectedFramesDigest: digest,
            orderedImageNames: imageNames,
            activeBackend: .colmap,
            mappingAttemptCount: 0,
            mappingFallbackReasons: [],
            colmapComputeMode: .gpu,
            plannedIncrementalCadence: .balancedGlobal,
            activeIncrementalCadence: .balancedGlobal
        )
    }

    private func colmapState(
        mappingAttemptCount: Int = 1,
        plannedCadence: IncrementalMappingCadenceArtifact = .balancedGlobal,
        activeCadence: IncrementalMappingCadenceArtifact = .balancedGlobal,
        fallbackTrigger: MappingCadenceFallbackTrigger? = nil
    ) -> GeometryRecoveryState {
        GeometryRecoveryState(
            selectedFramesDigest: digest,
            orderedImageNames: imageNames,
            activeBackend: .colmap,
            mappingAttemptCount: mappingAttemptCount,
            mappingFallbackReasons: [],
            colmapComputeMode: .gpu,
            plannedIncrementalCadence: plannedCadence,
            activeIncrementalCadence: activeCadence,
            cadenceFallbackTrigger: fallbackTrigger,
            acceptedPairAttemptOrdinal: 1,
            pairListDigest: digest,
            matchingDatabaseDigest: String(repeating: "b", count: 64)
        )
    }

    private func assertInvalidBackendFields(
        _ state: GeometryRecoveryState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try state.validate(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? GeometryRecoveryState.ValidationError,
                .invalidBackendFields,
                file: file,
                line: line
            )
        }
    }

    private func reasonWith4096Bytes(_ index: Int) -> String {
        String(repeating: "r", count: 4_092) + String(format: "%04d", index)
    }
}
