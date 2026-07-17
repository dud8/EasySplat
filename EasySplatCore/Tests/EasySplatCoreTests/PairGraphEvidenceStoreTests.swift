#if canImport(XCTest)
import CryptoKit
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

    func testSaveRejectsInvalidAttemptCountsAndDurations() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.attempts[0].artifact.rawMatchedPairCount = 3

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
        try Data(#"{"schemaVersion":3,"retiredPayload":true}"#.utf8).write(
            to: fixture.paths.pairGraphEvidenceURL,
            options: [.atomic]
        )

        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? PairGraphEvidenceStoreError, .invalidSchema(3))
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
        XCTAssertEqual(loaded.acceptedInspection.articulationViewCount, 0)
        XCTAssertEqual(loaded.acceptedInspection.biconnectedBlockCount, 1)
        XCTAssertEqual(loaded.acceptedInspection.largestBiconnectedBlockViewCount, 3)
        XCTAssertEqual(loaded.acceptedInspection.secondLargestBiconnectedBlockViewCount, 0)
        XCTAssertEqual(try loaded.pairGraphMeasurement().descriptorlessViewCount, 1)
    }

    func testRejectsTamperedDescriptorlessGraphEvidenceAndRetiredSchema() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var evidence = makeDescriptorlessEvidence()
        evidence.acceptedInspection.descriptorlessViewCount = 0
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
        evidence.schemaVersion = 3
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? PairGraphEvidenceStoreError, .invalidSchema(3))
        }
    }

    func testTargetedAndFullExactRecoveryPurposesRoundTrip() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeExactRecoveryEvidence(includeFullRecovery: true)

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        let loaded = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )

        XCTAssertEqual(
            loaded.attempts.map(\.purpose),
            [.policy, .targetedExactGraphRecovery, .fullExactGraphRecovery]
        )
        XCTAssertEqual(loaded, evidence)
        let restored = try loaded.restoredPairPlans()
        XCTAssertEqual(restored.accepted.pairs, evidence.attempts[2].scheduledPairs)
        XCTAssertEqual(restored.recoverySource?.pairs, evidence.attempts[0].scheduledPairs)
    }

    func testDirectFullRecoveryAndFailedTargetedRetryAreValid() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var directFull = makeExactRecoveryEvidence(includeFullRecovery: true)
        directFull.attempts.remove(at: 1)
        directFull.attempts[1].artifact.attemptNumber = 2
        directFull.acceptedAttemptNumber = 2
        directFull.matchingDurationSeconds = 4
        try PairGraphEvidenceStore.save(
            directFull,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )

        var retriedTarget = makeExactRecoveryEvidence(includeFullRecovery: false)
        var failedTarget = retriedTarget.attempts[1]
        failedTarget.artifact.outcome = .failed
        retriedTarget.attempts[1].artifact.attemptNumber = 3
        retriedTarget.attempts.insert(failedTarget, at: 1)
        retriedTarget.acceptedAttemptNumber = 3
        retriedTarget.matchingDurationSeconds = 5
        try PairGraphEvidenceStore.save(
            retriedTarget,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
    }

    func testSaveRejectsInvalidExactRecoverySequence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var evidence = makeExactRecoveryEvidence(includeFullRecovery: false)
        evidence.attempts[1].artifact.matcher = .faiss
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeExactRecoveryEvidence(includeFullRecovery: false)
        evidence.attempts[1].scheduledPairs[1] = ColmapScheduledPair(
            "a.jpg",
            "c.jpg",
            role: .retrieval
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeExactRecoveryEvidence(includeFullRecovery: false)
        var unrelatedPolicy = evidence.attempts[0]
        unrelatedPolicy.artifact.attemptNumber = 2
        unrelatedPolicy.artifact.matcher = .exact
        evidence.attempts[1].artifact.attemptNumber = 3
        evidence.attempts.insert(unrelatedPolicy, at: 1)
        evidence.acceptedAttemptNumber = 3
        evidence.matchingDurationSeconds += unrelatedPolicy.artifact.durationSeconds
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))

        evidence = makeExactRecoveryEvidence(includeFullRecovery: true)
        evidence.attempts[2].scheduledPairs.removeLast()
        evidence.attempts[2].artifact.scheduledPairCount -= 1
        evidence.attempts[2].artifact.attemptedPairCount -= 1
        evidence.attempts[2].artifact.rawMatchedPairCount -= 1
        evidence.attempts[2].artifact.spatiallyVerifiedPairCount -= 1
        evidence.acceptedInspection.scheduledPairCount -= 1
        evidence.acceptedInspection.attemptedPairCount -= 1
        evidence.acceptedInspection.rawMatchedPairCount -= 1
        evidence.acceptedInspection.spatiallyVerifiedPairCount -= 1
        evidence.acceptedInspection.retrievalPairCount -= 1
        let pairData = Data((evidence.attempts[2].scheduledPairs.map(\.line)
            .joined(separator: "\n") + "\n").utf8)
        evidence.pairListDigest = SHA256.hash(data: pairData)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
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
                scheduledPairCount: 2,
                attemptedPairCount: 2,
                rawMatchedPairCount: 1,
                spatiallyVerifiedPairCount: 1,
                durationSeconds: 1.25
            ),
            scheduledPairs: [
                ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
                ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
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
            descriptorlessImageNames: []
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

    private func makeExactRecoveryEvidence(includeFullRecovery: Bool) -> PairGraphEvidence {
        let sourcePairs = [
            ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
            ColmapScheduledPair("a.jpg", "d.jpg", role: .retrieval),
            ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
            ColmapScheduledPair("c.jpg", "d.jpg", role: .local),
        ]
        let targetedPairs = [sourcePairs[0], sourcePairs[2], sourcePairs[3]]
        let policy = PairGraphAttemptEvidence(
            purpose: .policy,
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairCount: sourcePairs.count,
                attemptedPairCount: sourcePairs.count,
                rawMatchedPairCount: targetedPairs.count,
                spatiallyVerifiedPairCount: targetedPairs.count,
                durationSeconds: 1
            ),
            scheduledPairs: sourcePairs
        )
        let targeted = PairGraphAttemptEvidence(
            purpose: .targetedExactGraphRecovery,
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 2,
                matcher: .exact,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairCount: targetedPairs.count,
                attemptedPairCount: targetedPairs.count,
                rawMatchedPairCount: targetedPairs.count,
                spatiallyVerifiedPairCount: targetedPairs.count,
                durationSeconds: 2
            ),
            scheduledPairs: targetedPairs
        )
        let full = PairGraphAttemptEvidence(
            purpose: .fullExactGraphRecovery,
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 3,
                matcher: .exact,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairCount: sourcePairs.count,
                attemptedPairCount: sourcePairs.count,
                rawMatchedPairCount: sourcePairs.count,
                spatiallyVerifiedPairCount: sourcePairs.count,
                durationSeconds: 3
            ),
            scheduledPairs: sourcePairs
        )
        let attempts = includeFullRecovery ? [policy, targeted, full] : [policy, targeted]
        let acceptedPairs = attempts.last?.scheduledPairs ?? []
        let acceptedLocalCount = acceptedPairs.count { $0.role == .local }
        let acceptedRetrievalCount = acceptedPairs.count { $0.role == .retrieval }
        let acceptedIsCycle = includeFullRecovery
        let inspection = ColmapPairGraphInspection(
            scheduledPairCount: acceptedPairs.count,
            attemptedPairCount: acceptedPairs.count,
            rawMatchedPairCount: acceptedPairs.count,
            spatiallyVerifiedPairCount: acceptedPairs.count,
            localPairCount: acceptedLocalCount,
            retrievalPairCount: acceptedRetrievalCount,
            loopRevisitPairCount: 0,
            connectedComponentCount: 1,
            isolatedViewCount: 0,
            articulationViewCount: acceptedIsCycle ? 0 : 2,
            biconnectedBlockCount: acceptedIsCycle ? 1 : 3,
            largestBiconnectedBlockViewCount: acceptedIsCycle ? 4 : 2,
            secondLargestBiconnectedBlockViewCount: acceptedIsCycle ? 0 : 2,
            degreeP10: 1,
            degreeMedian: 2,
            degreeP90: 2,
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            descriptorlessImageNames: []
        )
        return PairGraphEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
            attempts: attempts,
            acceptedAttemptNumber: attempts.count,
            acceptedInspection: inspection,
            matchingDurationSeconds: attempts.reduce(0) { $0 + $1.artifact.durationSeconds },
            fallbackReasons: ["exact descriptor matching"]
        )
    }

    private func makeDescriptorlessEvidence() -> PairGraphEvidence {
        let scheduledPairs = [
            ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
            ColmapScheduledPair("a.jpg", "c.jpg", role: .retrieval),
            ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
            ColmapScheduledPair("c.jpg", "d.jpg", role: .retrieval),
        ]
        let attempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: 4,
                attemptedPairCount: 4,
                rawMatchedPairCount: 3,
                spatiallyVerifiedPairCount: 3,
                durationSeconds: 1
            ),
            scheduledPairs: scheduledPairs
        )
        let inspection = ColmapPairGraphInspection(
            scheduledPairCount: 4,
            attemptedPairCount: 4,
            rawMatchedPairCount: 3,
            spatiallyVerifiedPairCount: 3,
            localPairCount: 2,
            retrievalPairCount: 2,
            loopRevisitPairCount: 0,
            connectedComponentCount: 2,
            isolatedViewCount: 1,
            articulationViewCount: 0,
            biconnectedBlockCount: 1,
            largestBiconnectedBlockViewCount: 3,
            secondLargestBiconnectedBlockViewCount: 0,
            degreeP10: 0,
            degreeMedian: 2,
            degreeP90: 2,
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            descriptorlessImageNames: ["d.jpg"]
        )
        return PairGraphEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
            attempts: [attempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: inspection,
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
    }
}
#endif
