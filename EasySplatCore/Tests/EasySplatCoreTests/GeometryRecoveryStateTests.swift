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
            mappingFallbackReasons: ["Initial seeded refinement did not meet coverage."],
            da3DescriptorMatcher: .exact
        )

        try state.validate()
        XCTAssertEqual(state.schemaVersion, GeometryRecoveryState.currentSchemaVersion)
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testValidColmapStateRoundTrips() throws {
        let plannedCadence = IncrementalMappingCadenceArtifact(
            localMaxRefinements: 1,
            globalFramesRatio: 4,
            globalPointsRatio: 4,
            globalMaxRefinements: 5
        )
        let state = GeometryRecoveryState(
            selectedFramesDigest: digest,
            orderedImageNames: imageNames,
            activeBackend: .colmap,
            mappingAttemptCount: 1,
            mappingFallbackReasons: [],
            pendingPairRecoveryLevel: .expanded,
            colmapComputeMode: .cpu,
            plannedIncrementalCadence: plannedCadence,
            activeIncrementalCadence: .conservative
        )

        try state.validate()
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testRejectsNonCurrentSchema() {
        var state = validState()
        state.schemaVersion = GeometryRecoveryState.currentSchemaVersion + 1

        XCTAssertThrowsError(try state.validate())
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

        var colmapState = validState()
        colmapState.da3DescriptorMatcher = .exact

        var da3ComputeState = validState()
        da3ComputeState.activeBackend = .da3

        var da3CadenceState = validState()
        da3CadenceState.activeBackend = .da3
        da3CadenceState.colmapComputeMode = nil

        var colmapComputeState = validState()
        colmapComputeState.colmapComputeMode = nil

        XCTAssertThrowsError(try da3State.validate())
        XCTAssertThrowsError(try colmapState.validate())
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

    func testRejectsConservativeFallbackForUnorderedPlannedCadence() {
        var state = validState()
        state.plannedIncrementalCadence = IncrementalMappingCadenceArtifact(
            localMaxRefinements: 2,
            globalFramesRatio: 1.1,
            globalPointsRatio: 1.1,
            globalMaxRefinements: 5
        )
        state.activeIncrementalCadence = .conservative

        XCTAssertThrowsError(try state.validate()) { error in
            XCTAssertEqual(
                error as? GeometryRecoveryState.ValidationError,
                .invalidBackendFields
            )
        }
    }

    func testRejectsPersistedNormalMatcherForDA3() {
        var state = validState()
        state.activeBackend = .da3
        state.da3DescriptorMatcher = .faiss

        XCTAssertThrowsError(try state.validate())
    }

    func testBindingRequiresExactImageOrderAndDigest() throws {
        let state = validState()

        try state.validateBinding(
            expectedImageNames: imageNames,
            expectedSelectedFramesDigest: digest,
            expectedPlannedIncrementalCadence: state.plannedIncrementalCadence
        )
        XCTAssertThrowsError(
            try state.validateBinding(
                expectedImageNames: imageNames.reversed(),
                expectedSelectedFramesDigest: digest,
                expectedPlannedIncrementalCadence: state.plannedIncrementalCadence
            )
        )
        XCTAssertThrowsError(
            try state.validateBinding(
                expectedImageNames: imageNames,
                expectedSelectedFramesDigest: String(repeating: "b", count: 64),
                expectedPlannedIncrementalCadence: state.plannedIncrementalCadence
            )
        )
        XCTAssertThrowsError(
            try state.validateBinding(
                expectedImageNames: imageNames,
                expectedSelectedFramesDigest: digest,
                expectedPlannedIncrementalCadence: IncrementalMappingCadenceArtifact(
                    localMaxRefinements: 1,
                    globalFramesRatio: 8,
                    globalPointsRatio: 8,
                    globalMaxRefinements: 5
                )
            )
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
            plannedIncrementalCadence: .conservative,
            activeIncrementalCadence: .conservative
        )
    }

    private func reasonWith4096Bytes(_ index: Int) -> String {
        String(repeating: "r", count: 4_092) + String(format: "%04d", index)
    }
}
