#if canImport(XCTest)
import Foundation
import SQLite3
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
        XCTAssertTrue(artifact.retrievalWasScheduled)
        XCTAssertTrue(artifact.usedLocalVocabularyRetrieval)
    }

    func testValidationRejectsTamperedAcceptedEdgeEvidence() throws {
        let cases: [(String, (inout PersistedColmapPairGraphInspection) -> Void)] = [
            ("duplicate attempted edge", { inspection in
                inspection.attemptedPairs.append(inspection.attemptedPairs[0])
            }),
            ("reordered raw edges", { inspection in
                inspection.rawMatchedPairs.swapAt(0, 1)
            }),
            ("raw edge was not attempted", { inspection in
                inspection.attemptedPairs.removeFirst()
                inspection.attemptedPairCount -= 1
            }),
            ("verified edge was not raw matched", { inspection in
                inspection.rawMatchedPairs.removeLast()
                inspection.rawMatchedPairCount -= 1
            }),
            ("count list disagreement", { inspection in
                inspection.spatiallyVerifiedPairCount -= 1
            }),
        ]
        for (name, mutate) in cases {
            var evidence = makeEvidence()
            mutate(&evidence.acceptedInspection)
            XCTAssertThrowsError(
                try PairGraphEvidenceStore.validate(evidence),
                name
            ) { error in
                XCTAssertEqual(
                    error as? PairGraphEvidenceStoreError,
                    .invalidEvidence,
                    name
                )
            }
        }
    }

    func testScheduleBindingRejectsAResolvedPlanWithDifferentSeed() throws {
        let fixture = makePlanBoundExhaustiveEvidence()

        XCTAssertNoThrow(try PairGraphEvidenceStore.validateSchedule(
            fixture.evidence,
            resolvedPlan: fixture.plan,
            groups: fixture.groups
        ))

        var changedPlan = fixture.plan
        changedPlan.runSeed = 43
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateSchedule(
            fixture.evidence,
            resolvedPlan: changedPlan,
            groups: fixture.groups
        )) { error in
            XCTAssertEqual(error as? PairGraphEvidenceStoreError, .invalidEvidence)
        }
    }

    func testWorkerExecutionBindingRejectsRelabeledMissingExtraAndMismatchedAttempts() throws {
        let fixture = makePlanBoundExhaustiveEvidence()
        var execution = makeWorkerExecution(for: fixture.evidence)

        XCTAssertNoThrow(try PairGraphEvidenceStore.validateWorkerExecution(
            fixture.evidence,
            workerExecution: execution
        ))

        execution.matchingInvocations[0].pairExecution?.descriptorMatcher = .exact
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateWorkerExecution(
            fixture.evidence,
            workerExecution: execution
        ))

        execution = makeWorkerExecution(for: fixture.evidence)
        execution.matchingInvocations[0].pairExecution?.attemptOrdinal = 2
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateWorkerExecution(
            fixture.evidence,
            workerExecution: execution
        ))

        execution = makeWorkerExecution(for: fixture.evidence)
        execution.matchingInvocations[0].pairExecution?.pairListDigest = String(
            repeating: "f",
            count: 64
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateWorkerExecution(
            fixture.evidence,
            workerExecution: execution
        ))

        execution = makeWorkerExecution(for: fixture.evidence)
        execution.matchingInvocations.append(execution.matchingInvocations[0])
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateWorkerExecution(
            fixture.evidence,
            workerExecution: execution
        ))

        execution = makeWorkerExecution(for: fixture.evidence)
        execution.matchingInvocations.removeAll()
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateWorkerExecution(
            fixture.evidence,
            workerExecution: execution
        ))
    }

    func testDa3EvidenceUsesAnExplicitBackendAndModelBinding() throws {
        var evidence = makeSameScheduleExactEvidence(previousOutcome: .failed)
        for index in evidence.attempts.indices {
            evidence.attempts[index].retrieval = nil
            evidence.attempts[index].retrievalWasExecuted = false
        }
        evidence.retrievalWasScheduled = false
        evidence.usedLocalVocabularyRetrieval = false

        var plan = makePlanBoundExhaustiveEvidence().plan
        plan.geometryBackend = .da3
        plan.modelIdentifier = "DA3-BASE"
        plan.pairingPolicy = evidence.pairingPolicy
        evidence.planBinding = PairGraphPlanBinding(plan)
        let pairPlan = try ColmapPairPlan.persisted(
            imageNames: evidence.imageNames,
            scheduledPairs: try XCTUnwrap(evidence.attempts.last).scheduledPairs
        )
        let execution = makeWorkerExecution(for: evidence)

        XCTAssertNoThrow(try PairGraphEvidenceStore.validateDa3Refinement(
            evidence,
            expectedPlanBinding: PairGraphPlanBinding(plan),
            expectedPairPlan: pairPlan
        ))
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateDa3WorkerExecution(
            evidence,
            expectedPlanBinding: PairGraphPlanBinding(plan),
            expectedPairPlan: pairPlan,
            workerExecution: execution
        ))
        XCTAssertThrowsError(try PairGraphEvidenceStore.validate(evidence))

        var differentModel = plan
        differentModel.modelIdentifier = "DA3-SMALL"
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateDa3Refinement(
            evidence,
            expectedPlanBinding: PairGraphPlanBinding(differentModel),
            expectedPairPlan: pairPlan
        ))

        var classicalPlan = plan
        classicalPlan.geometryBackend = .colmap
        classicalPlan.modelIdentifier = "none"
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateDa3Refinement(
            evidence,
            expectedPlanBinding: PairGraphPlanBinding(classicalPlan),
            expectedPairPlan: pairPlan
        ))
    }

    func testMatchingSeedSidecarsPreserveEveryRejectedRecoveryLevelBeforeSameOrdinalExhaustiveAcceptance() throws {
        let fixture = try makeSameOrdinalSegmentedRecoveryFixture()

        let sidecars = try PairGraphEvidenceStore.matchingSeedSidecarContents(
            evidence: fixture.evidence,
            workerExecution: fixture.workerExecution,
            resolvedPlan: fixture.plan,
            groups: fixture.groups
        )

        XCTAssertEqual(Set(sidecars.keys), [
            "match_pairs_attempt_1.txt",
            "retrieval_exclusions_expanded.txt",
            "retrieval_exclusions_normal.txt",
            "retrieval_pairs_expanded.txt",
            "retrieval_pairs_normal.txt",
            "retrieval_queries_expanded.txt",
            "retrieval_queries_normal.txt",
        ])
        XCTAssertEqual(
            sidecars["match_pairs_attempt_1.txt"],
            fixture.acceptedPlan.serializedData
        )
        XCTAssertEqual(
            sidecars["retrieval_exclusions_expanded.txt"],
            fixture.rejectedBasePlan.serializedData
        )
        XCTAssertNotEqual(
            sidecars["retrieval_exclusions_expanded.txt"],
            sidecars["match_pairs_attempt_1.txt"]
        )
        XCTAssertEqual(
            sidecars["retrieval_queries_expanded.txt"],
            Data((fixture.rejectedRetrieval.queryImageNames.joined(separator: "\n") + "\n").utf8)
        )
        XCTAssertEqual(
            sidecars["retrieval_pairs_expanded.txt"],
            Data((PairGraphEvidenceStore.retrievalContractLines(
                fixture.rejectedRetrieval
            ).joined(separator: "\n") + "\n").utf8)
        )
        XCTAssertNotEqual(
            sidecars["retrieval_pairs_normal.txt"],
            sidecars["retrieval_pairs_expanded.txt"]
        )
    }

    func testWorkerExecutionBindingRejectsSubstitutedRetrievalOutput() throws {
        var evidence = makeEvidence()
        evidence.attempts[0].retrieval = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: ["a.jpg"],
            queryStride: 1,
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            queryOutcomes: [PairGraphRetrievalQueryOutcome(
                queryImageName: "a.jpg",
                status: .ranked,
                rankedNeighborImageNames: ["d.jpg"]
            )],
            directedPairLines: ["a.jpg d.jpg"]
        )
        evidence.attempts[0].retrievalWasExecuted = true
        evidence.attempts[1].retrieval = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: ["b.jpg"],
            queryStride: 1,
            candidateCount: 40,
            returnedNeighborCount: 16,
            minimumFrameSeparation: 0,
            queryOutcomes: [PairGraphRetrievalQueryOutcome(
                queryImageName: "b.jpg",
                status: .ranked,
                rankedNeighborImageNames: ["d.jpg"]
            )],
            directedPairLines: ["b.jpg d.jpg"]
        )
        evidence.attempts[1].retrievalWasExecuted = true
        var execution = makeWorkerExecution(for: evidence)

        XCTAssertNoThrow(try PairGraphEvidenceStore.validateWorkerExecution(
            evidence,
            workerExecution: execution
        ))

        execution.vocabularyRetrievalInvocations[1]
            .pairExecution?.retrievalOutputDigest = String(repeating: "e", count: 64)
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateWorkerExecution(
            evidence,
            workerExecution: execution
        ))

        execution = makeWorkerExecution(for: evidence)
        execution.matchingInvocations[1]
            .pairExecution?.retrievalOutputDigest = String(repeating: "e", count: 64)
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateWorkerExecution(
            evidence,
            workerExecution: execution
        ))
    }

    func testRetrievalContractAcceptsAuthenticatedNoNeighborOutcome() throws {
        let imageNames = ["a.jpg", "b.jpg", "c.jpg"]
        let retrieval = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: ["a.jpg"],
            queryStride: 1,
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            queryOutcomes: [PairGraphRetrievalQueryOutcome(
                queryImageName: "a.jpg",
                status: .noRankedNeighbors,
                rankedNeighborImageNames: []
            )],
            directedPairLines: []
        )

        XCTAssertNoThrow(try PairGraphEvidenceStore.validateRetrievalContractEvidence(
            retrieval,
            imageNames: imageNames
        ))
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateRetrievalEvidence(
            retrieval,
            imageNames: imageNames
        ))

        var forged = retrieval
        forged.outputDigest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateRetrievalContractEvidence(
            forged,
            imageNames: imageNames
        ))
    }

    func testScheduleBindingRejectsAValidButWrongPairRole() throws {
        var fixture = makePlanBoundExhaustiveEvidence()
        let first = fixture.evidence.attempts[0].scheduledPairs[0]
        let relabeled = ColmapScheduledPair(
            first.firstImageName,
            first.secondImageName,
            role: .local
        )
        fixture.evidence.attempts[0].scheduledPairs[0] = relabeled
        fixture.evidence.acceptedInspection.attemptedPairs[0] = relabeled
        fixture.evidence.acceptedInspection.rawMatchedPairs[0] = relabeled
        fixture.evidence.acceptedInspection.spatiallyVerifiedPairs[0] = relabeled
        fixture.evidence.acceptedInspection.localPairCount = 1
        fixture.evidence.acceptedInspection.retrievalPairCount -= 1

        XCTAssertNoThrow(try PairGraphEvidenceStore.validate(fixture.evidence))
        XCTAssertThrowsError(try PairGraphEvidenceStore.validateSchedule(
            fixture.evidence,
            resolvedPlan: fixture.plan,
            groups: fixture.groups
        )) { error in
            XCTAssertEqual(error as? PairGraphEvidenceStoreError, .invalidEvidence)
        }
    }

    func testStoreRejectsUsedVocabularyRetrievalThatWasNotScheduled() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = makeEvidence()
        evidence.retrievalWasScheduled = false

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? PairGraphEvidenceStoreError, .invalidEvidence)
        }
    }

    func testAcceptedExhaustiveAttemptDoesNotInheritEarlierVocabularyUsage() throws {
        var evidence = makeEvidence()
        evidence.attempts[1].artifact.recoveryLevel = .maximum
        evidence.attempts[1].retrieval = nil
        evidence.attempts[1].retrievalWasExecuted = false
        evidence.usedLocalVocabularyRetrieval = false
        evidence.fallbackReasons = [
            "denser pair graph",
            "exhaustive graph without retrieval",
        ]

        XCTAssertNoThrow(try PairGraphEvidenceStore.validate(evidence))

        evidence.usedLocalVocabularyRetrieval = true
        XCTAssertThrowsError(try PairGraphEvidenceStore.validate(evidence)) {
            XCTAssertEqual(
                $0 as? PairGraphEvidenceStoreError,
                .invalidEvidence
            )
        }
    }

    func testAcceptedExactAttemptUsesItsInheritedVocabularyReceipt() throws {
        var evidence = makeSameScheduleExactEvidence(previousOutcome: .failed)
        evidence.attempts[1].retrievalWasExecuted = false
        evidence.usedLocalVocabularyRetrieval = true

        XCTAssertNoThrow(try PairGraphEvidenceStore.validate(evidence))

        evidence.usedLocalVocabularyRetrieval = false
        XCTAssertThrowsError(try PairGraphEvidenceStore.validate(evidence)) {
            XCTAssertEqual(
                $0 as? PairGraphEvidenceStoreError,
                .invalidEvidence
            )
        }
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

    func testLoadFromDataUsesCapturedBytesAfterCanonicalFileChanges() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeEvidence()
        let captured = try JSONEncoder().encode(evidence)
        try Data("{\"replacement\":true}".utf8).write(
            to: fixture.paths.pairGraphEvidenceURL,
            options: [.atomic]
        )

        XCTAssertEqual(try PairGraphEvidenceStore.load(data: captured), evidence)
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testLoadFromDataRejectsInvalidByteEnvelopeAndOldSchema() throws {
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(data: Data()))
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(data: Data("not-json".utf8)))
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(
            data: Data(repeating: 0x20, count: PairGraphEvidenceStore.maximumBytes + 1)
        ))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeEvidence()))
                as? [String: Any]
        )
        let oldSchema = PairGraphEvidence.currentSchemaVersion - 1
        object["schemaVersion"] = oldSchema
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try PairGraphEvidenceStore.load(data: data)) { error in
            XCTAssertEqual(
                error as? PairGraphEvidenceStoreError,
                .invalidSchema(oldSchema)
            )
        }
    }

    func testBoundAndVerifiedDataLoadsNeverReopenEvidencePath() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let base = makeEvidence()
        for (index, name) in base.imageNames.enumerated() {
            try Data("selected-\(index)".utf8).write(
                to: fixture.paths.framesSelectedURL.appendingPathComponent(name),
                options: [.atomic]
            )
        }
        let selectedDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: base.imageNames,
            projectPaths: fixture.paths
        )
        try writeVerifiedPairDatabase(
            at: fixture.paths.colmapDatabaseURL,
            imageNames: base.imageNames,
            scheduledPairs: try XCTUnwrap(base.attempts.last).scheduledPairs,
            verifiedPairs: base.acceptedInspection.spatiallyVerifiedPairs
        )
        let acceptedAttempt = try XCTUnwrap(base.attempts.last)
        let liveInspection = try ColmapPairGraphInspector(
            databaseURL: fixture.paths.colmapDatabaseURL
        ).inspect(
            schedule: ColmapPairSchedule(
                imageNames: base.imageNames,
                pairs: acceptedAttempt.scheduledPairs
            ),
            completion: .succeeded
        )
        let evidence = PairGraphEvidence(
            selectedFramesDigest: selectedDigest,
            imageNames: base.imageNames,
            pairingPolicy: base.pairingPolicy,
            planBinding: base.planBinding,
            attempts: base.attempts,
            acceptedAttemptNumber: base.acceptedAttemptNumber,
            acceptedInspection: liveInspection,
            retrievalWasScheduled: base.retrievalWasScheduled,
            usedLocalVocabularyRetrieval: base.usedLocalVocabularyRetrieval,
            matchingDurationSeconds: base.matchingDurationSeconds,
            fallbackReasons: base.fallbackReasons
        )
        let captured = try JSONEncoder().encode(evidence)
        try Data("not-the-captured-evidence".utf8).write(
            to: fixture.paths.pairGraphEvidenceURL,
            options: [.atomic]
        )

        XCTAssertEqual(
            try PairGraphEvidenceStore.loadBound(
                data: captured,
                expectedImageNames: base.imageNames,
                projectPaths: fixture.paths
            ),
            evidence
        )
        XCTAssertEqual(
            try PairGraphEvidenceStore.loadVerified(
                data: captured,
                expectedImageNames: base.imageNames,
                databaseURL: fixture.paths.colmapDatabaseURL,
                projectPaths: fixture.paths
            ),
            evidence
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.loadVerified(
            from: fixture.paths.pairGraphEvidenceURL,
            expectedImageNames: base.imageNames,
            databaseURL: fixture.paths.colmapDatabaseURL,
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
        evidence.planBinding = .testingDefault(pairingPolicy: evidence.pairingPolicy)

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveAcceptsExactSwitchAfterRejectedExhaustiveSmallUnorderedSchedule() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeSmallUnorderedExactEvidence()

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
    }

    func testSaveRejectsSecondExactAttemptAfterRejectedExactRetry() throws {
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

        XCTAssertThrowsError(try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    func testSaveAcceptsExactSwitchAfterRejectedMaximumRecoveryLevel() throws {
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
        evidence.planBinding = .testingDefault(pairingPolicy: evidence.pairingPolicy)
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
                outcome: .rejected,
                scheduledPairs: completePairs,
                durationSeconds: 0.5
            ),
            makeAttempt(
                number: 4,
                matcher: .exact,
                recoveryLevel: .maximum,
                outcome: .completed,
                exactRecoveryReason: .faissGeometryRejectedAfterRetries,
                scheduledPairs: completePairs,
                durationSeconds: 0.5
            ),
        ]
        evidence.attempts[2].artifact.attemptedPairCount = completePairs.count
        evidence.acceptedAttemptNumber = 4
        evidence.matchingDurationSeconds = 2
        evidence.fallbackReasons = ["denser pair graph", "exact descriptor matching"]

        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
    }

    func testExactTransitionIsBoundedByScheduledPairCount() {
        func attempt(pairCount: Int, outcome: PairMatchingAttemptOutcome) -> PairMatchingAttemptArtifact {
            PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .maximum,
                outcome: outcome,
                scheduledPairCount: pairCount,
                attemptedPairCount: outcome == .failed ? 0 : pairCount,
                rawMatchedPairCount: 0,
                spatiallyVerifiedPairCount: 0,
                durationSeconds: 1
            )
        }

        for outcome in [PairMatchingAttemptOutcome.failed, .rejected] {
            let reason: DescriptorMatcherRecoveryReason = outcome == .failed
                ? .faissCrash
                : .faissGeometryRejectedAfterRetries
            XCTAssertTrue(PairGraphEvidenceStore.permitsExactMatcherTransition(
                after: attempt(pairCount: 256, outcome: outcome),
                reason: reason,
                imageCount: 500,
                pairingPolicy: .orderedContinuous
            ))
            XCTAssertFalse(PairGraphEvidenceStore.permitsExactMatcherTransition(
                after: attempt(pairCount: 257, outcome: outcome),
                reason: reason,
                imageCount: 500,
                pairingPolicy: .orderedContinuous
            ))
        }
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

    private func writeVerifiedPairDatabase(
        at url: URL,
        imageNames: [String],
        scheduledPairs: [ColmapScheduledPair],
        verifiedPairs: [ColmapScheduledPair]
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "PairGraphEvidenceStoreTests", code: 1)
        }
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);")
        try execute(database, "CREATE TABLE rigs(rig_id INTEGER PRIMARY KEY);")
        try execute(
            database,
            "CREATE TABLE rig_sensors(rig_id INTEGER, sensor_id INTEGER, sensor_type INTEGER);"
        )
        try execute(database, "CREATE TABLE frames(frame_id INTEGER PRIMARY KEY);")
        try execute(
            database,
            "CREATE TABLE frame_data(frame_id INTEGER, data_id INTEGER, sensor_id INTEGER, sensor_type INTEGER);"
        )
        try execute(
            database,
            "CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT, camera_id INTEGER);"
        )
        try execute(database, "CREATE TABLE pose_priors(pose_prior_id INTEGER PRIMARY KEY);")
        try execute(
            database,
            "CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )
        try execute(
            database,
            "CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )
        try execute(
            database,
            "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )
        try execute(
            database,
            "CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )
        try execute(database, "BEGIN IMMEDIATE TRANSACTION;")
        try execute(database, "INSERT INTO cameras(camera_id) VALUES (1);")
        for (offset, name) in imageNames.enumerated() {
            let imageID = offset + 1
            try execute(
                database,
                "INSERT INTO images(image_id, name, camera_id) VALUES (\(imageID), '\(name)', 1);"
            )
            try execute(
                database,
                "INSERT INTO keypoints(image_id, rows, cols, data) VALUES (\(imageID), 1, 4, X'00');"
            )
            try execute(
                database,
                "INSERT INTO descriptors(image_id, rows, cols, data) VALUES (\(imageID), 1, 128, X'00');"
            )
        }
        let imageIDs = Dictionary(
            uniqueKeysWithValues: imageNames.enumerated().map { ($0.element, $0.offset + 1) }
        )
        let verifiedLines = Set(verifiedPairs.map(\.line))
        for pair in scheduledPairs {
            let first = try XCTUnwrap(imageIDs[pair.firstImageName])
            let second = try XCTUnwrap(imageIDs[pair.secondImageName])
            let low = Int64(min(first, second))
            let high = Int64(max(first, second))
            let pairID = low * ColmapPairGraphInspector.pairIDDivisor + high
            let rows = verifiedLines.contains(pair.line) ? 20 : 0
            let verifiedRows = verifiedLines.contains(pair.line) ? 18 : 0
            try execute(
                database,
                "INSERT INTO matches(pair_id, rows, cols, data) VALUES (\(pairID), \(rows), 2, X'00');"
            )
            try execute(
                database,
                "INSERT INTO two_view_geometries(pair_id, rows, cols, data) VALUES (\(pairID), \(verifiedRows), 2, X'00');"
            )
        }
        try execute(database, "COMMIT;")
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw NSError(
                domain: "PairGraphEvidenceStoreTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    private func makeWorkerExecution(
        for evidence: PairGraphEvidence
    ) -> GeometryWorkerExecutionArtifact {
        let budget = GeometryWorkerBudget(
            featureExtractionWorkers: 2,
            coupledMatchingWorkers: 2,
            vocabularyRetrievalWorkers: 2,
            maximumConcurrentVideoSourceAnalysisTasks: 1
        )
        func invocation(
            command: ColmapWorkerCommandIdentity,
            workers: Int,
            binding: ColmapPairWorkerExecutionEvidence,
            succeeded: Bool = true
        ) -> ColmapWorkerInvocationEvidence {
            let value = "\(workers)"
            let environment = [
                "OMP_NUM_THREADS": value,
                "OPENBLAS_NUM_THREADS": value,
                "MKL_NUM_THREADS": value,
            ]
            return ColmapWorkerInvocationEvidence(
                command: command,
                mappingAttemptOrdinal: nil,
                threadPolicy: .bounded,
                argvWorkerCount: workers,
                explicitThreadEnvironment: environment,
                removedThreadEnvironmentKeysSHA256:
                    GeometryWorkerExecutionArtifact
                        .canonicalRemovedThreadEnvironmentKeysSHA256,
                effectiveSanitizedThreadEnvironment: environment,
                pairExecution: binding,
                exitStatus: succeeded ? 0 : 1,
                succeeded: succeeded
            )
        }
        let matchingInvocations = evidence.attempts.map { attempt in
            invocation(
                command: .matchesImporter,
                workers: budget.coupledMatchingWorkers,
                binding: ColmapPairWorkerExecutionEvidence(
                    attemptOrdinal: attempt.artifact.attemptNumber,
                    descriptorMatcher: attempt.artifact.matcher,
                    scheduledPairCount: attempt.artifact.scheduledPairCount,
                    pairListDigest: PairGraphEvidence.digest(of: attempt.scheduledPairs),
                    exactRecoveryReason: attempt.artifact.exactRecoveryReason,
                    retrievalRequestDigest: attempt.retrieval.map(
                        PairGraphEvidenceStore.retrievalRequestDigest
                    ),
                    retrievalOutputDigest: attempt.retrieval.map(
                        PairGraphEvidenceStore.retrievalOutputDigest
                    )
                ),
                succeeded: attempt.artifact.outcome != .failed
            )
        }
        let retrievalInvocations: [ColmapWorkerInvocationEvidence] = evidence.attempts.compactMap {
            attempt in
            guard attempt.retrievalWasExecuted,
                  let retrieval = attempt.retrieval else { return nil }
            let requestDigest = PairGraphEvidenceStore.retrievalRequestDigest(retrieval)
            let outputDigest = PairGraphEvidenceStore.retrievalOutputDigest(retrieval)
            return invocation(
                command: .localVocabularyRetriever,
                workers: budget.vocabularyRetrievalWorkers,
                binding: ColmapPairWorkerExecutionEvidence(
                    attemptOrdinal: attempt.artifact.attemptNumber,
                    descriptorMatcher: attempt.artifact.matcher,
                    retrievalRequestDigest: requestDigest,
                    retrievalOutputDigest: outputDigest
                )
            )
        }
        return GeometryWorkerExecutionArtifact(
            colmapRuntimeClosure: makeColmapRuntimeClosureEvidence(),
            resolvedBudget: budget,
            featureExtractionInvocations: [],
            matchingInvocations: matchingInvocations,
            vocabularyRetrievalInvocations: retrievalInvocations,
            mappingAndRefinementInvocations: [],
            videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: 0,
                startedAnalysisTaskCount: 0,
                peakInFlightAnalysisTaskCount: 0
            )
        )
    }

    private func makePlanBoundExhaustiveEvidence() -> (
        evidence: PairGraphEvidence,
        plan: ResolvedRunPlan,
        groups: [ColmapPairGroup]
    ) {
        let imageNames = ["a.jpg", "b.jpg", "c.jpg"]
        let plan = ResolvedRunPlan(
            geometryBackend: .colmap,
            modelIdentifier: "none",
            memoryTier: "standard",
            chunkSize: 0,
            keyframeBudget: 250,
            maximumImageDimension: 1_024,
            cameraGrouping: .automatic,
            lensProjection: .automatic,
            refinementIterationLimit: 75,
            trainerIterationLimit: 3_000,
            plateauWindow: 400,
            trainerMemoryBudgetBytes: 1_024 * 1_024 * 1_024,
            geometryWorkerBudget: GeometryWorkerBudget(
                featureExtractionWorkers: 12,
                coupledMatchingWorkers: 8,
                vocabularyRetrievalWorkers: 8,
                maximumConcurrentVideoSourceAnalysisTasks: 4
            ),
            requiredToolchainCapabilities: [
                "geometry.colmap", "runtime.core", "training.msplat",
            ],
            pairingPolicy: .unorderedRetrieval,
            temporalPairing: .none,
            temporalOffsets: [],
            retrievalCandidateCount: 20,
            retrievalNeighborCount: 8,
            retrievalQueryStride: 1,
            runSeed: 42
        )
        let pairs = try! ColmapPairPlan.exhaustive(imageNames: imageNames).pairs
        let attempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: pairs.count,
                attemptedPairCount: pairs.count,
                rawMatchedPairCount: pairs.count,
                spatiallyVerifiedPairCount: pairs.count,
                durationSeconds: 1
            ),
            scheduledPairs: pairs
        )
        let inspection = ColmapPairGraphInspection(
            scheduledPairCount: pairs.count,
            attemptedPairCount: pairs.count,
            rawMatchedPairCount: pairs.count,
            spatiallyVerifiedPairCount: pairs.count,
            localPairCount: 0,
            retrievalPairCount: pairs.count,
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
            attemptedPairs: pairs,
            rawMatchedPairs: pairs,
            verifiedGraph: ColmapVerifiedGraphSnapshot(
                verifiedPairs: pairs,
                components: [imageNames]
            )
        )
        return (
            PairGraphEvidence(
                selectedFramesDigest: String(repeating: "a", count: 64),
                imageNames: imageNames,
                pairingPolicy: plan.pairingPolicy,
                planBinding: PairGraphPlanBinding(plan),
                attempts: [attempt],
                acceptedAttemptNumber: 1,
                acceptedInspection: inspection,
                retrievalWasScheduled: false,
                usedLocalVocabularyRetrieval: false,
                matchingDurationSeconds: 1,
                fallbackReasons: []
            ),
            plan,
            [ColmapPairGroup(imageNames: imageNames, isVideo: false)]
        )
    }

    private func makeSameOrdinalSegmentedRecoveryFixture() throws -> (
        evidence: PairGraphEvidence,
        workerExecution: GeometryWorkerExecutionArtifact,
        plan: ResolvedRunPlan,
        groups: [ColmapPairGroup],
        acceptedPlan: ColmapPairPlan,
        rejectedBasePlan: ColmapPairPlan,
        rejectedRetrieval: PairGraphRetrievalAttemptEvidence
    ) {
        let firstClip = (0..<30).map { String(format: "a_%03d.jpg", $0) }
        let secondClip = (0..<30).map { String(format: "b_%03d.jpg", $0) }
        let imageNames = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let plan = ResolvedRunPlan(
            geometryBackend: .colmap,
            modelIdentifier: "none",
            memoryTier: "standard",
            chunkSize: 0,
            keyframeBudget: imageNames.count,
            maximumImageDimension: 1_024,
            cameraGrouping: .automatic,
            lensProjection: .automatic,
            refinementIterationLimit: 75,
            trainerIterationLimit: 3_000,
            plateauWindow: 400,
            trainerMemoryBudgetBytes: 1_024 * 1_024 * 1_024,
            geometryWorkerBudget: GeometryWorkerBudget(
                featureExtractionWorkers: 2,
                coupledMatchingWorkers: 2,
                vocabularyRetrievalWorkers: 2,
                maximumConcurrentVideoSourceAnalysisTasks: 1
            ),
            requiredToolchainCapabilities: [
                "geometry.colmap", "runtime.core", "training.msplat",
            ],
            capturePath: .automatic,
            inputOrdering: .automatic,
            pairingPolicy: .segmentedMixed,
            temporalPairing: .linear,
            temporalOffsets: [1, 2, 3, 4, 5, 6],
            retrievalCandidateCount: 20,
            retrievalNeighborCount: 2,
            retrievalQueryStride: 10,
            runSeed: 42
        )
        let acceptedPlan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
        let rejectedBasePlan = try PipelineRunner.baseColmapPairPlan(
            imageNames: imageNames,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .expanded
        )
        func rejectedRetrieval(
            recoveryLevel: PipelineRunner.PairRecoveryLevel
        ) throws -> PairGraphRetrievalAttemptEvidence {
            let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
                imageNames: imageNames,
                groups: groups,
                resolvedPlan: plan,
                recoveryLevel: recoveryLevel
            ))
            return PairGraphRetrievalAttemptEvidence(
                engine: plan.retrievalEngine,
                queryImageNames: request.queryImageNames,
                queryStride: plan.retrievalQueryStride,
                candidateCount: request.candidateCount,
                returnedNeighborCount: request.returnedNeighborCount,
                minimumFrameSeparation: request.minimumFrameSeparation,
                queryOutcomes: request.queryImageNames.map {
                    PairGraphRetrievalQueryOutcome(
                        queryImageName: $0,
                        status: .noRankedNeighbors,
                        rankedNeighborImageNames: []
                    )
                },
                directedPairLines: []
            )
        }
        let normalRejectedRetrieval = try rejectedRetrieval(
            recoveryLevel: .normal
        )
        let expandedRejectedRetrieval = try rejectedRetrieval(
            recoveryLevel: .expanded
        )
        let attempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .maximum,
                outcome: .completed,
                scheduledPairCount: acceptedPlan.pairs.count,
                attemptedPairCount: acceptedPlan.pairs.count,
                rawMatchedPairCount: acceptedPlan.pairs.count,
                spatiallyVerifiedPairCount: acceptedPlan.pairs.count,
                durationSeconds: 1
            ),
            scheduledPairs: acceptedPlan.pairs
        )
        let inspection = ColmapPairGraphInspection(
            scheduledPairCount: acceptedPlan.pairs.count,
            attemptedPairCount: acceptedPlan.pairs.count,
            rawMatchedPairCount: acceptedPlan.pairs.count,
            spatiallyVerifiedPairCount: acceptedPlan.pairs.count,
            localPairCount: 0,
            retrievalPairCount: acceptedPlan.pairs.count,
            loopRevisitPairCount: 0,
            connectedComponentCount: 1,
            isolatedViewCount: 0,
            articulationViewCount: 0,
            biconnectedBlockCount: 1,
            largestBiconnectedBlockViewCount: imageNames.count,
            secondLargestBiconnectedBlockViewCount: 0,
            degreeP10: imageNames.count - 1,
            degreeMedian: imageNames.count - 1,
            degreeP90: imageNames.count - 1,
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            descriptorlessImageNames: [],
            attemptedPairs: acceptedPlan.pairs,
            rawMatchedPairs: acceptedPlan.pairs,
            verifiedGraph: ColmapVerifiedGraphSnapshot(
                verifiedPairs: acceptedPlan.pairs,
                components: [imageNames]
            )
        )
        let evidence = PairGraphEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: imageNames,
            pairingPolicy: plan.pairingPolicy,
            planBinding: PairGraphPlanBinding(plan),
            attempts: [attempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: inspection,
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: false,
            matchingDurationSeconds: 1,
            fallbackReasons: [
                "normal retrieval did not return neighbors",
                "expanded retrieval did not return neighbors",
            ]
        )
        var workerExecution = makeWorkerExecution(for: evidence)
        let threadValue = String(
            workerExecution.resolvedBudget.vocabularyRetrievalWorkers
        )
        let environment = [
            "OMP_NUM_THREADS": threadValue,
            "OPENBLAS_NUM_THREADS": threadValue,
            "MKL_NUM_THREADS": threadValue,
        ]
        func invocation(
            for retrieval: PairGraphRetrievalAttemptEvidence
        ) -> ColmapWorkerInvocationEvidence {
            ColmapWorkerInvocationEvidence(
                command: .localVocabularyRetriever,
                mappingAttemptOrdinal: nil,
                threadPolicy: .bounded,
                argvWorkerCount:
                    workerExecution.resolvedBudget.vocabularyRetrievalWorkers,
                explicitThreadEnvironment: environment,
                removedThreadEnvironmentKeysSHA256:
                    GeometryWorkerExecutionArtifact
                        .canonicalRemovedThreadEnvironmentKeysSHA256,
                effectiveSanitizedThreadEnvironment: environment,
                pairExecution: ColmapPairWorkerExecutionEvidence(
                    attemptOrdinal: 1,
                    descriptorMatcher: .faiss,
                    retrievalRequestDigest:
                        PairGraphEvidenceStore.retrievalRequestDigest(retrieval),
                    retrievalOutputDigest:
                        PairGraphEvidenceStore.retrievalOutputDigest(retrieval)
                ),
                exitStatus: 0,
                succeeded: true
            )
        }
        workerExecution.rejectedVocabularyRetrievalInvocations = [
            RejectedVocabularyRetrievalExecutionEvidence(
                retrievalAttemptOrdinal: 1,
                pairingPolicy: plan.pairingPolicy,
                planBinding: PairGraphPlanBinding(plan),
                recoveryLevel: .normal,
                imageNames: imageNames,
                groups: groups,
                invocation: invocation(for: normalRejectedRetrieval),
                retrieval: normalRejectedRetrieval,
                durationSeconds: 0.25
            ),
            RejectedVocabularyRetrievalExecutionEvidence(
                retrievalAttemptOrdinal: 2,
                pairingPolicy: plan.pairingPolicy,
                planBinding: PairGraphPlanBinding(plan),
                recoveryLevel: .expanded,
                imageNames: imageNames,
                groups: groups,
                invocation: invocation(for: expandedRejectedRetrieval),
                retrieval: expandedRejectedRetrieval,
                durationSeconds: 0.25
            ),
        ]
        try workerExecution.validate(expectedBudget: workerExecution.resolvedBudget)
        return (
            evidence,
            workerExecution,
            plan,
            groups,
            acceptedPlan,
            rejectedBasePlan,
            expandedRejectedRetrieval
        )
    }

    private func makeEvidence() -> PairGraphEvidence {
        func retrieval(_ neighbors: [[String]]) -> PairGraphRetrievalAttemptEvidence {
            let queryImageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
            return PairGraphRetrievalAttemptEvidence(
                engine: .localSiftVocabularyV2,
                queryImageNames: queryImageNames,
                queryStride: 1,
                candidateCount: 20,
                returnedNeighborCount: 8,
                minimumFrameSeparation: 12,
                queryOutcomes: zip(queryImageNames, neighbors).map { query, values in
                    PairGraphRetrievalQueryOutcome(
                        queryImageName: query,
                        status: .ranked,
                        rankedNeighborImageNames: values.sorted()
                    )
                },
                directedPairLines: []
            )
        }
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
            ],
            retrieval: retrieval([
                ["b.jpg"], ["a.jpg", "c.jpg"], ["b.jpg", "d.jpg"], ["c.jpg"],
            ])
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
            ],
            retrieval: retrieval([
                ["b.jpg", "d.jpg"], ["a.jpg", "c.jpg"],
                ["b.jpg", "d.jpg"], ["a.jpg", "c.jpg"],
            ])
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
            attemptedPairs: acceptedAttempt.scheduledPairs,
            rawMatchedPairs: [
                acceptedAttempt.scheduledPairs[0],
                acceptedAttempt.scheduledPairs[2],
                acceptedAttempt.scheduledPairs[3],
            ],
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
            pairingPolicy: .orderedOrbit,
            attempts: [firstAttempt, acceptedAttempt],
            acceptedAttemptNumber: 2,
            acceptedInspection: inspection,
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: true,
            matchingDurationSeconds: 4,
            fallbackReasons: ["denser pair graph"]
        )
    }

    private func makeSameScheduleExactEvidence(
        previousOutcome: PairMatchingAttemptOutcome
    ) -> PairGraphEvidence {
        var evidence = makeEvidence()
        let scheduledPairs = evidence.attempts[1].scheduledPairs
        evidence.pairingPolicy = .orderedOrbit
        evidence.planBinding = .testingDefault(pairingPolicy: evidence.pairingPolicy)
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
        evidence.attempts[1].artifact.exactRecoveryReason = previousOutcome == .failed
            ? .faissCrash
            : .faissGeometryRejectedAfterRetries
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
        var attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .rejected,
                scheduledPairs: scheduledPairs,
                durationSeconds: 0.5
            ),
            makeAttempt(
                number: 2,
                matcher: .exact,
                recoveryLevel: .normal,
                outcome: .completed,
                exactRecoveryReason: .faissGeometryRejectedAfterRetries,
                scheduledPairs: scheduledPairs,
                durationSeconds: 0.5
            ),
        ]
        attempts[0].artifact.attemptedPairCount = scheduledPairs.count
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
            attemptedPairs: scheduledPairs,
            rawMatchedPairs: scheduledPairs,
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
        exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil,
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
                exactRecoveryReason: matcher == .exact
                    ? (exactRecoveryReason ?? .faissCrash)
                    : nil,
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
            attemptedPairs: scheduledPairs,
            rawMatchedPairs: Array(scheduledPairs.dropLast()),
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
