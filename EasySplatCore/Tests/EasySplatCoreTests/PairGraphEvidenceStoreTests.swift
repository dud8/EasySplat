#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class PairGraphEvidenceStoreTests: XCTestCase {
    func testStoreAcceptsCanonicalPathThroughPrivateTemporaryAlias() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/EasySplat-PairGraphEvidence-\(UUID().uuidString).easysplatproj",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let evidence = makeEvidence()

        try PairGraphEvidenceStore.save(
            evidence,
            to: paths.pairGraphEvidenceURL,
            projectPaths: paths
        )

        XCTAssertEqual(
            try PairGraphEvidenceStore.load(
                from: paths.pairGraphEvidenceURL,
                projectPaths: paths
            ),
            evidence
        )
    }

    func testRoundTripPreservesEvidenceAndBuildsMeasuredArtifact() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeEvidence()

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        let loaded = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )

        XCTAssertEqual(loaded, evidence)
        let measurement = try loaded.pairGraphMeasurement()
        XCTAssertEqual(measurement.scheduledPairCount, 4)
        XCTAssertEqual(measurement.localPairCount, 2)
        XCTAssertEqual(measurement.retrievalPairCount, 1)
        XCTAssertEqual(measurement.loopRevisitPairCount, 1)
        XCTAssertEqual(measurement.componentViewCounts, [4])
        XCTAssertEqual(measurement.descriptorlessViewCount, 0)
        XCTAssertEqual(measurement.articulationViewCount, 2)
        XCTAssertEqual(measurement.biconnectedBlockCount, 3)
        XCTAssertEqual(measurement.largestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(measurement.secondLargestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(measurement.matcherAttempts, evidence.attempts.map(\.artifact))
        XCTAssertEqual(measurement.matchingDurationSeconds, 4)
        XCTAssertEqual(loaded.fallbackReasons, ["denser pair graph"])

        let artifact = try loaded.pairGraphArtifact()
        XCTAssertEqual(artifact.status, .measured)
        XCTAssertEqual(artifact.measurement, measurement)
    }

    func testSaveProducesDeterministicBytes() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeEvidence()

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        let first = try Data(contentsOf: fixture.paths.pairGraphEvidenceURL)
        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        let second = try Data(contentsOf: fixture.paths.pairGraphEvidenceURL)

        XCTAssertEqual(first, second)
    }

    func testStoreRejectsComponentSizesThatDisagreeWithTheMeasuredGraph() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.acceptedInspection.componentViewCounts = [3, 1]

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence.acceptedInspection.componentViewCounts = [Int.max, 1]
        evidence.acceptedInspection.connectedComponentCount = 2
        evidence.acceptedInspection.isolatedViewCount = 1
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testLoadRejectsTamperedPairListDigest() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try PairGraphEvidenceStore.save(
            makeEvidence(),
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.pairGraphEvidenceURL)
            ) as? [String: Any]
        )
        object["pairListDigest"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.paths.pairGraphEvidenceURL, options: [.atomic])

        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testStoreRejectsOutsidePathAndLoadRejectsSymlink() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outsideURL = fixture.root.appendingPathComponent("outside.json")

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            makeEvidence(),
            to: outsideURL,
            projectPaths: fixture.paths
        ))

        try PairGraphEvidenceStore.save(
            makeEvidence(),
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        let data = try Data(contentsOf: fixture.paths.pairGraphEvidenceURL)
        let externalAlias = fixture.root.appendingPathComponent("pair-graph-alias.json")
        try FileManager.default.createSymbolicLink(
            at: externalAlias,
            withDestinationURL: fixture.paths.pairGraphEvidenceURL
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            makeEvidence(),
            to: externalAlias,
            projectPaths: fixture.paths
        ))
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: externalAlias.path)
        )

        try FileManager.default.removeItem(at: fixture.paths.pairGraphEvidenceURL)
        try data.write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.pairGraphEvidenceURL,
            withDestinationURL: outsideURL
        )

        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testLoadRejectsOversizeAndMalformedFiles() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Data(repeating: 0x20, count: PairGraphEvidenceStore.maximumBytes + 1)
            .write(to: fixture.paths.pairGraphEvidenceURL)
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        try FileManager.default.removeItem(at: fixture.paths.pairGraphEvidenceURL)
        try FileManager.default.createDirectory(
            at: fixture.paths.pairGraphEvidenceURL,
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        try FileManager.default.removeItem(at: fixture.paths.pairGraphEvidenceURL)
        try Data("{not-json".utf8).write(
            to: fixture.paths.pairGraphEvidenceURL,
            options: [.atomic]
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveRejectsNoncontiguousAttemptsAndNonfinalAcceptance() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.attempts[1].artifact.attemptNumber = 3

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.acceptedAttemptNumber = 1
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveRejectsPartialOrDisconnectedRejectedAttempts() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeSmallUnorderedExactEvidence()
        evidence.attempts[0].artifact.outcome = .rejected
        evidence.attempts[0].artifact.attemptedPairCount = 2
        evidence.attempts[0].artifact.rawMatchedPairCount = 2
        evidence.attempts[0].artifact.spatiallyVerifiedPairCount = 1

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.attempts[0].artifact.outcome = .rejected
        evidence.attempts[0].scheduledPairs.removeLast()
        evidence.attempts[0].artifact.scheduledPairCount = 2
        evidence.attempts[0].artifact.attemptedPairCount = 2
        evidence.attempts[0].artifact.rawMatchedPairCount = 1
        evidence.attempts[0].artifact.spatiallyVerifiedPairCount = 1

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveRejectsExactSwitchAfterCompletedNondensestFaissAttempt() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeSameScheduleExactEvidence(previousOutcome: .completed)

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveAcceptsExactSwitchAfterFailedFaissAttempt() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeSameScheduleExactEvidence(previousOutcome: .failed)

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
    }

    func testSaveRejectsCompletedExactSwitchForIncompleteSmallUnorderedSchedule() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeSameScheduleExactEvidence(previousOutcome: .completed)
        evidence.pairingPolicy = .unorderedRetrieval

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveAcceptsCompletedExactSwitchForExhaustiveSmallUnorderedSchedule() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeSmallUnorderedExactEvidence()

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
    }

    func testSaveAcceptsSameScheduleSuccessAfterRejectedExactRetry() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeSmallUnorderedExactEvidence()
        evidence.attempts[0].artifact.outcome = .rejected
        evidence.attempts[1].artifact.outcome = .rejected
        var accepted = evidence.attempts[1]
        accepted.artifact.attemptNumber = 3
        accepted.artifact.outcome = .completed
        evidence.attempts.append(accepted)
        evidence.acceptedAttemptNumber = 3
        evidence.matchingDurationSeconds = 1.5

        XCTAssertNoThrow(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveAcceptsCompletedExactSwitchAtMaximumRecoveryLevel() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeSmallUnorderedExactEvidence()
        let completePairs = evidence.attempts[0].scheduledPairs
        let normalPairs = [
            ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
            ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
        ]
        let expandedPairs = [
            ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
            ColmapScheduledPair("a.jpg", "c.jpg", role: .retrieval),
        ]
        evidence.pairingPolicy = .orderedContinuous
        evidence.attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .failed,
                scheduledPairs: normalPairs,
                durationSeconds: 0.5
            ),
            makeAttempt(
                number: 2,
                matcher: .faiss,
                recoveryLevel: .expanded,
                outcome: .failed,
                scheduledPairs: expandedPairs,
                durationSeconds: 0.5
            ),
            makeAttempt(
                number: 3,
                matcher: .faiss,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairs: completePairs,
                durationSeconds: 0.5
            ),
            makeAttempt(
                number: 4,
                matcher: .exact,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairs: completePairs,
                durationSeconds: 0.5
            ),
        ]
        evidence.acceptedAttemptNumber = 4
        evidence.matchingDurationSeconds = 2
        evidence.fallbackReasons = ["denser pair graph", "exact descriptor matching"]

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
    }

    func testSaveRejectsInvalidAttemptCountsAndDurations() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.attempts[0].artifact.rawMatchedPairCount = 4

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.attempts[0].artifact.durationSeconds = -.infinity
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.attempts[0].artifact.attemptedPairCount = -1
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.attempts[0].artifact.durationSeconds = .greatestFiniteMagnitude
        evidence.attempts[1].artifact.durationSeconds = .greatestFiniteMagnitude
        evidence.matchingDurationSeconds = .greatestFiniteMagnitude
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveRejectsMismatchedFinalInspectionAndDuration() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.acceptedInspection.spatiallyVerifiedPairCount = 1

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.matchingDurationSeconds += 0.001
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.acceptedInspection.localPairCount = 1
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.fallbackReasons = ["duplicate", "duplicate"]
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.acceptedInspection.connectedComponentCount = 2
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveRejectsUnknownDuplicateAndNoncanonicalPairs() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.attempts[1].scheduledPairs[0] = ColmapScheduledPair(
            "a.jpg",
            "unknown.jpg",
            role: .local
        )

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.attempts[1].scheduledPairs[1] = evidence.attempts[1].scheduledPairs[0]
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.attempts[1].scheduledPairs[0] = ColmapScheduledPair(
            "b.jpg",
            "a.jpg",
            role: .local
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveRejectsIncoherentGraphFactsAndBadSelectedDigest() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.acceptedInspection.degreeMedian = 2
        evidence.acceptedInspection.degreeP90 = 1

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeEvidence()
        evidence.selectedFramesDigest = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveRejectsIncoherentBiconnectedGraphFacts() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutations: [(inout PersistedColmapPairGraphInspection) -> Void] = [
            { $0.articulationViewCount = -1 },
            { $0.articulationViewCount = 3 },
            { $0.biconnectedBlockCount = 0 },
            { $0.biconnectedBlockCount = 4 },
            { $0.largestBiconnectedBlockViewCount = 5 },
            { $0.secondLargestBiconnectedBlockViewCount = 3 },
            {
                $0.articulationViewCount = 0
                $0.biconnectedBlockCount = 3
            },
            {
                $0.articulationViewCount = 0
                $0.biconnectedBlockCount = 1
                $0.largestBiconnectedBlockViewCount = 2
                $0.secondLargestBiconnectedBlockViewCount = 0
            },
        ]

        for mutate in mutations {
            var evidence = makeEvidence()
            mutate(&evidence.acceptedInspection)
            XCTAssertThrowsError(try PairGraphEvidenceStore.save(
                evidence,
                to: fixture.paths.pairGraphEvidenceURL,
                projectPaths: fixture.paths
            ))
        }
    }

    func testLoadRejectsRetiredSchemaBeforeStrictPayloadDecoding() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retiredSchema = PairGraphEvidence.currentSchemaVersion - 1
        try Data(#"{"schemaVersion":\#(retiredSchema),"retiredPayload":true}"#.utf8).write(
            to: fixture.paths.pairGraphEvidenceURL,
            options: [.atomic]
        )

        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PairGraphEvidenceStoreError,
                .invalidSchema(retiredSchema)
            )
        }
    }

    func testDescriptorlessSingletonEvidenceRoundTripsWithoutFlatteningGraphFacts() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeDescriptorlessEvidence()

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        let loaded = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )

        XCTAssertEqual(loaded.acceptedInspection.connectedComponentCount, 2)
        XCTAssertEqual(loaded.acceptedInspection.isolatedViewCount, 1)
        XCTAssertEqual(loaded.acceptedInspection.descriptorlessViewCount, 1)
        XCTAssertEqual(loaded.acceptedInspection.articulationViewCount, 7)
        XCTAssertEqual(loaded.acceptedInspection.biconnectedBlockCount, 8)
        XCTAssertEqual(loaded.acceptedInspection.largestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(loaded.acceptedInspection.secondLargestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(try loaded.pairGraphMeasurement().descriptorlessViewCount, 1)
    }

    func testRejectsTamperedDescriptorlessGraphEvidenceAndRetiredSchema() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var evidence = makeDescriptorlessEvidence()
        evidence.acceptedInspection.descriptorlessViewCount = 2
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeDescriptorlessEvidence()
        evidence.acceptedInspection.connectedComponentCount = 3
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeDescriptorlessEvidence()
        evidence.acceptedInspection.descriptorlessViewCount = .min
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeDescriptorlessEvidence()
        evidence.schemaVersion = PairGraphEvidence.currentSchemaVersion - 1
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PairGraphEvidenceStoreError,
                .invalidSchema(PairGraphEvidence.currentSchemaVersion - 1)
            )
        }
    }

    func testProjectPathsUsesCanonicalEvidenceLocation() throws {
        let root = URL(fileURLWithPath: "/tmp/easysplat-project", isDirectory: true)
        let paths = ProjectPaths(root: root)

        XCTAssertEqual(
            paths.pairGraphEvidenceURL,
            root.appendingPathComponent("SfM/pair_graph_evidence.json")
        )
    }

    private func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        return (root, paths)
    }

    private func makeEvidence() -> PairGraphEvidence {
        let firstAttempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: 3,
                attemptedPairCount: 3,
                rawMatchedPairCount: 1,
                spatiallyVerifiedPairCount: 1,
                durationSeconds: 1.25
            ),
            scheduledPairs: [
                ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
                ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
                ColmapScheduledPair("c.jpg", "d.jpg", role: .local),
            ]
        )
        let acceptedAttempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 2,
                matcher: .faiss,
                recoveryLevel: .expanded,
                outcome: .completed,
                scheduledPairCount: 4,
                attemptedPairCount: 4,
                rawMatchedPairCount: 3,
                spatiallyVerifiedPairCount: 3,
                durationSeconds: 2.75
            ),
            scheduledPairs: [
                ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
                ColmapScheduledPair("a.jpg", "d.jpg", role: .loopRevisit),
                ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
                ColmapScheduledPair("c.jpg", "d.jpg", role: .retrieval),
            ]
        )
        let inspection = ColmapPairGraphInspection(
            scheduledPairCount: 4,
            attemptedPairCount: 4,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            localPairCount: 2,
            retrievalPairCount: 1,
            loopRevisitPairCount: 1,
            connectedComponentCount: 1,
            isolatedViewCount: 0,
            articulationViewCount: 2,
            biconnectedBlockCount: 3,
            largestBiconnectedBlockViewCount: 2,
            secondLargestBiconnectedBlockViewCount: 2,
            degreeP10: 1,
            degreeMedian: 2,
            degreeP90: 2,
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            descriptorlessImageNames: [],
            verifiedGraph: ColmapVerifiedGraphSnapshot(
                verifiedPairs: [
                    acceptedAttempt.scheduledPairs[0],
                    acceptedAttempt.scheduledPairs[2],
                    acceptedAttempt.scheduledPairs[3],
                ],
                components: [["a.jpg", "b.jpg", "c.jpg", "d.jpg"]]
            )
        )
        return PairGraphEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
            attempts: [firstAttempt, acceptedAttempt],
            acceptedAttemptNumber: 2,
            acceptedInspection: inspection,
            matchingDurationSeconds: 4,
            fallbackReasons: ["denser pair graph"]
        )
    }

    private func makeSameScheduleExactEvidence(
        previousOutcome: PairMatchingAttemptOutcome
    ) -> PairGraphEvidence {
        var evidence = makeEvidence()
        let scheduledPairs = evidence.attempts[1].scheduledPairs
        evidence.pairingPolicy = .orderedContinuous
        evidence.attempts[0].scheduledPairs = scheduledPairs
        evidence.attempts[0].artifact.outcome = previousOutcome
        evidence.attempts[0].artifact.scheduledPairCount = scheduledPairs.count
        if previousOutcome == .failed {
            evidence.attempts[0].artifact.attemptedPairCount = 0
            evidence.attempts[0].artifact.rawMatchedPairCount = 0
            evidence.attempts[0].artifact.spatiallyVerifiedPairCount = 0
        } else {
            evidence.attempts[0].artifact.attemptedPairCount = 4
            evidence.attempts[0].artifact.rawMatchedPairCount = 3
            evidence.attempts[0].artifact.spatiallyVerifiedPairCount = 3
        }
        evidence.attempts[1].artifact.matcher = .exact
        evidence.attempts[1].artifact.recoveryLevel = .normal
        return evidence
    }

    private func makeSmallUnorderedExactEvidence() -> PairGraphEvidence {
        let imageNames = ["a.jpg", "b.jpg", "c.jpg"]
        let scheduledPairs = [
            ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
            ColmapScheduledPair("a.jpg", "c.jpg", role: .retrieval),
            ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
        ]
        let attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairs: scheduledPairs,
                durationSeconds: 0.5
            ),
            makeAttempt(
                number: 2,
                matcher: .exact,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairs: scheduledPairs,
                durationSeconds: 0.5
            ),
        ]
        let inspection = ColmapPairGraphInspection(
            scheduledPairCount: scheduledPairs.count,
            attemptedPairCount: scheduledPairs.count,
            rawMatchedPairCount: scheduledPairs.count,
            spatiallyVerifiedPairCount: scheduledPairs.count,
            localPairCount: 2,
            retrievalPairCount: 1,
            loopRevisitPairCount: 0,
            connectedComponentCount: 1,
            isolatedViewCount: 0,
            articulationViewCount: 0,
            biconnectedBlockCount: 1,
            largestBiconnectedBlockViewCount: imageNames.count,
            secondLargestBiconnectedBlockViewCount: 0,
            degreeP10: 2,
            degreeMedian: 2,
            degreeP90: 2,
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            descriptorlessImageNames: [],
            verifiedGraph: ColmapVerifiedGraphSnapshot(
                verifiedPairs: scheduledPairs,
                components: [imageNames]
            )
        )
        return PairGraphEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: imageNames,
            pairingPolicy: .unorderedRetrieval,
            attempts: attempts,
            acceptedAttemptNumber: 2,
            acceptedInspection: inspection,
            matchingDurationSeconds: 1,
            fallbackReasons: ["exact descriptor matching"]
        )
    }

    private func makeAttempt(
        number: Int,
        matcher: DescriptorMatcher,
        recoveryLevel: PairGraphRecoveryLevel,
        outcome: PairMatchingAttemptOutcome,
        scheduledPairs: [ColmapScheduledPair],
        durationSeconds: Double
    ) -> PairGraphAttemptEvidence {
        let completedPairCount = outcome == .completed ? scheduledPairs.count : 0
        return PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: number,
                matcher: matcher,
                recoveryLevel: recoveryLevel,
                outcome: outcome,
                scheduledPairCount: scheduledPairs.count,
                attemptedPairCount: completedPairCount,
                rawMatchedPairCount: completedPairCount,
                spatiallyVerifiedPairCount: completedPairCount,
                durationSeconds: durationSeconds
            ),
            scheduledPairs: scheduledPairs
        )
    }

    private func makeDescriptorlessEvidence() -> PairGraphEvidence {
        let imageNames = (0..<10).map { "image_\($0).jpg" }
        let scheduledPairs = (0..<9).map { index in
            ColmapScheduledPair(
                imageNames[index],
                imageNames[index + 1],
                role: .local
            )
        }
        let attempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: 9,
                attemptedPairCount: 9,
                rawMatchedPairCount: 8,
                spatiallyVerifiedPairCount: 8,
                durationSeconds: 1
            ),
            scheduledPairs: scheduledPairs
        )
        let inspection = ColmapPairGraphInspection(
            scheduledPairCount: 9,
            attemptedPairCount: 9,
            rawMatchedPairCount: 8,
            spatiallyVerifiedPairCount: 8,
            localPairCount: 9,
            retrievalPairCount: 0,
            loopRevisitPairCount: 0,
            connectedComponentCount: 2,
            isolatedViewCount: 1,
            articulationViewCount: 7,
            biconnectedBlockCount: 8,
            largestBiconnectedBlockViewCount: 2,
            secondLargestBiconnectedBlockViewCount: 2,
            degreeP10: 0,
            degreeMedian: 2,
            degreeP90: 2,
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            descriptorlessImageNames: [imageNames[9]],
            verifiedGraph: ColmapVerifiedGraphSnapshot(
                verifiedPairs: Array(scheduledPairs.dropLast()),
                components: [Array(imageNames.prefix(9)), [imageNames[9]]]
            )
        )
        return PairGraphEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: imageNames,
            attempts: [attempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: inspection,
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
    }
}
#endif
