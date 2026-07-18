#if canImport(XCTest)
import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryWorkerExecutionArtifactTests: XCTestCase {
    func testInvocationEncodingEmitsEveryKeyAndExplicitOptionalNulls() throws {
        let bounded = boundedInvocation(
            .featureExtractor,
            workers: budget.featureExtractionWorkers
        )
        let native = nativeAutoInvocation(.mapper)

        let boundedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(bounded))
                as? [String: Any]
        )
        XCTAssertEqual(Set(boundedJSON.keys), expectedInvocationJSONKeys)
        XCTAssertTrue(boundedJSON["mappingAttemptOrdinal"] is NSNull)
        XCTAssertEqual(
            boundedJSON["argvWorkerCount"] as? Int,
            budget.featureExtractionWorkers
        )

        let nativeJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(native))
                as? [String: Any]
        )
        XCTAssertEqual(Set(nativeJSON.keys), expectedInvocationJSONKeys)
        XCTAssertEqual(nativeJSON["mappingAttemptOrdinal"] as? Int, 1)
        XCTAssertTrue(nativeJSON["argvWorkerCount"] is NSNull)

        XCTAssertEqual(
            try JSONDecoder().decode(
                ColmapWorkerInvocationEvidence.self,
                from: JSONEncoder().encode(bounded)
            ),
            bounded
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ColmapWorkerInvocationEvidence.self,
                from: JSONEncoder().encode(native)
            ),
            native
        )
    }

    func testInvocationDecodingRejectsMissingAndUnknownKeys() throws {
        let encoded = try JSONEncoder().encode(nativeAutoInvocation(.mapper))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object.removeValue(forKey: "argvWorkerCount")
        XCTAssertThrowsError(try JSONDecoder().decode(
            ColmapWorkerInvocationEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["retiredField"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(
            ColmapWorkerInvocationEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testCanonicalStoreRoundTripsAndReturnsItsDigest() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = makeArtifact()
        XCTAssertEqual(
            GeometryWorkerExecutionArtifactStore.canonicalURL(for: fixture.paths),
            fixture.paths.workerExecutionURL
        )

        let digest = try GeometryWorkerExecutionArtifactStore.save(
            artifact,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: fixture.paths),
            expectedBudget: budget,
            projectPaths: fixture.paths
        )

        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
        XCTAssertEqual(
            try GeometryWorkerExecutionArtifactStore.load(
                from: GeometryWorkerExecutionArtifactStore.canonicalURL(for: fixture.paths),
                expectedBudget: budget,
                projectPaths: fixture.paths
            ),
            artifact
        )
    }

    func testZeroVocabularyInvocationsAndPhotoOnlyAnalysisAreHonest() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: 0,
            startedAnalysisTaskCount: 0,
            peakInFlightAnalysisTaskCount: 0
        )

        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))

        artifact.videoSourceAnalysis.startedAnalysisTaskCount = 1
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidVideoSourceAnalysis)
        }
    }

    func testNativeAutoMappingRequiresNoWorkerArgumentOrThreadEnvironment() throws {
        var artifact = makeArtifact()
        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))

        artifact.mappingAndRefinementInvocations[0].argvWorkerCount = 8
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidThreadPolicy)
        }

        artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations[0].effectiveSanitizedThreadEnvironment = [
            "OMP_NUM_THREADS": "8"
        ]
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidThreadEnvironment)
        }

        artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations[0].explicitThreadEnvironment = [
            "OMP_NUM_THREADS": "8"
        ]
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidThreadEnvironment)
        }
    }

    func testInvocationValidationRequiresStageAppropriateMonotonicAttemptOrdinals() throws {
        var artifact = makeArtifact()
        artifact.featureExtractionInvocations[0].mappingAttemptOrdinal = 1
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .invalidMappingAttemptOrdinal
            )
        }

        artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations[0].mappingAttemptOrdinal = nil
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget))

        artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations[0].mappingAttemptOrdinal = 2
        artifact.mappingAndRefinementInvocations[1].mappingAttemptOrdinal = 1
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget))

        artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations[0].mappingAttemptOrdinal =
            GeometryRecoveryState.maximumMappingAttemptCount + 1
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget))
    }

    func testCanonicalSanitizerDigestIsStableAcrossTheBenchmarkBoundary() {
        let canonicalJSON = "[\""
            + GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys
                .joined(separator: "\",\"")
            + "\"]"
        let recomputed = "sha256:" + SHA256.hash(data: Data(canonicalJSON.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            "sha256:d3e774ca1af94008cb9f77957e08e11c81cc35c07b337c45d1f98f2025bdb939"
        )
        XCTAssertEqual(
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            recomputed
        )
        XCTAssertEqual(
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys,
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys.sorted()
        )
        XCTAssertTrue(
            Set([
                "KMP_ALL_THREADS",
                "KMP_DEVICE_THREAD_LIMIT",
                "KMP_LIBRARY",
                "KMP_PLACE_THREADS",
            ]).isSubset(
                of: Set(
                    GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys
                )
            )
        )
    }

    func testValidationRejectsCommandInTheWrongStage() throws {
        var artifact = makeArtifact()
        artifact.matchingInvocations[0] = boundedInvocation(
            .featureExtractor,
            workers: budget.coupledMatchingWorkers
        )

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidCommandForStage)
        }
    }

    func testValidationRejectsUnexpectedThreadEnvironmentKeys() throws {
        var artifact = makeArtifact()
        artifact.matchingInvocations[0].explicitThreadEnvironment["DYLD_INSERT_LIBRARIES"] =
            "/tmp/not-allowed.dylib"

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidThreadEnvironment)
        }
    }

    func testValidationRejectsWorkerCountThatDiffersFromResolvedBudget() throws {
        var artifact = makeArtifact()
        artifact.featureExtractionInvocations[0].argvWorkerCount =
            budget.featureExtractionWorkers - 1

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .workerBudgetMismatch)
        }

        var differentBudget = budget
        differentBudget.coupledMatchingWorkers += 1
        XCTAssertThrowsError(try artifact.validate(expectedBudget: differentBudget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .workerBudgetMismatch)
        }
    }

    func testValidationRejectsWrongSanitizerDigest() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations[0].removedThreadEnvironmentKeysSHA256 =
            "sha256:" + String(repeating: "0", count: 64)

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidSanitizerDigest)
        }
    }

    func testPublishedIncrementalGeometryRequiresSuccessfulMappingAndAnalysis() throws {
        for missingCommand in [
            ColmapWorkerCommandIdentity.mapper,
            .modelAnalyzer,
        ] {
            var artifact = makeArtifact()
            artifact.vocabularyRetrievalInvocations = []
            artifact.mappingAndRefinementInvocations = [
                .mapper,
                .modelAnalyzer,
            ].filter { $0 != missingCommand }.map { nativeAutoInvocation($0) }

            XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: publicationContext(
                    refinement: .incrementalGlobal,
                    pairGraph: measuredPairGraph(),
                    input: twoVideoInput
                )
            )) { error in
                XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
            }
        }
    }

    func testPublishedIncrementalGeometryCannotBorrowCommandsFromRejectedAttempt() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.mapper, mappingAttemptOrdinal: 1),
            nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 1),
            nativeAutoInvocation(.mapper, mappingAttemptOrdinal: 2),
        ]

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput,
                acceptedMappingAttemptOrdinal: 2
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }
    }

    func testPublishedGeometryRejectsRollbackToCompleteOlderAttempt() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.mapper, mappingAttemptOrdinal: 2)
        )

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput,
                acceptedMappingAttemptOrdinal: 1
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }
    }

    func testPublishedAttemptRejectsFailedCommandFromConflictingRoute() throws {
        for refinement in [
            MappingRefinementKind.incrementalGlobal,
            .seededBundleAdjustment,
        ] {
            var artifact = makeArtifact()
            artifact.vocabularyRetrievalInvocations = []
            artifact.mappingAndRefinementInvocations = refinement == .incrementalGlobal
                ? [
                    nativeAutoInvocation(.mapper),
                    nativeAutoInvocation(.modelAnalyzer),
                    failedNativeAutoInvocation(.bundleAdjuster),
                ]
                : [
                    nativeAutoInvocation(.pointTriangulator),
                    nativeAutoInvocation(.bundleAdjuster),
                    nativeAutoInvocation(.modelAnalyzer),
                    failedNativeAutoInvocation(.mapper),
                ]

            XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: publicationContext(
                    refinement: refinement,
                    pairGraph: refinement == .incrementalGlobal
                        ? measuredPairGraph()
                        : .notEvaluated(),
                    input: twoVideoInput
                )
            )) { error in
                XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
            }
        }
    }

    func testPublishedSeededGeometryRequiresSuccessfulTriangulationAdjustmentAndAnalysis() throws {
        for missingCommand in [
            ColmapWorkerCommandIdentity.pointTriangulator,
            .bundleAdjuster,
            .modelAnalyzer,
        ] {
            var artifact = makeArtifact()
            artifact.vocabularyRetrievalInvocations = []
            artifact.mappingAndRefinementInvocations = [
                .pointTriangulator,
                .bundleAdjuster,
                .modelAnalyzer,
            ].filter { $0 != missingCommand }.map { nativeAutoInvocation($0) }

            XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: publicationContext(
                    refinement: .seededBundleAdjustment,
                    pairGraph: .notEvaluated(),
                    input: twoVideoInput
                )
            )) { error in
                XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
            }
        }
    }

    func testPublishedSeededGeometryRequiresFeaturesAndMatchesWithoutMeasuredPairGraph() throws {
        for missingStage in ["features", "matches"] {
            var artifact = makeArtifact()
            artifact.vocabularyRetrievalInvocations = []
            artifact.mappingAndRefinementInvocations = [
                nativeAutoInvocation(.pointTriangulator),
                nativeAutoInvocation(.bundleAdjuster),
                nativeAutoInvocation(.modelAnalyzer),
            ]
            if missingStage == "features" {
                artifact.featureExtractionInvocations = []
            } else {
                artifact.matchingInvocations = []
            }

            XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: publicationContext(
                    refinement: .seededBundleAdjustment,
                    pairGraph: .notEvaluated(),
                    input: twoVideoInput
                )
            )) { error in
                XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
            }
        }
    }

    func testPublishedSmallExhaustivePhotoGraphRequiresVocabularyOnlyWhenRecorded() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: 0,
            startedAnalysisTaskCount: 0,
            peakInFlightAnalysisTaskCount: 0
        )

        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(retrievalPairCount: 0, loopRevisitPairCount: 0),
                input: .photos(folder: "/tmp/photos")
            )
        ))

        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(
                    retrievalPairCount: 3,
                    usedLocalVocabularyRetrieval: false
                ),
                input: .photos(folder: "/tmp/photos")
            )
        ))

        artifact.vocabularyRetrievalInvocations = [
            boundedInvocation(
                .localVocabularyRetriever,
                workers: budget.vocabularyRetrievalWorkers
            )
        ]
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(usedLocalVocabularyRetrieval: false),
                input: .photos(folder: "/tmp/photos")
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }
        var failedSpeculativeRetrieval = boundedInvocation(
            .localVocabularyRetriever,
            workers: budget.vocabularyRetrievalWorkers
        )
        failedSpeculativeRetrieval.exitStatus = 1
        failedSpeculativeRetrieval.succeeded = false
        artifact.vocabularyRetrievalInvocations = [failedSpeculativeRetrieval]
        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(usedLocalVocabularyRetrieval: false),
                input: .photos(folder: "/tmp/photos")
            )
        ))
        artifact.vocabularyRetrievalInvocations = []

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(
                    retrievalPairCount: 1,
                    usedLocalVocabularyRetrieval: true
                ),
                input: .photos(folder: "/tmp/photos")
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }
    }

    func testPublishedVideoAnalysisMustMatchTheMetadataInput() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: 0,
            startedAnalysisTaskCount: 0,
            peakInFlightAnalysisTaskCount: 0
        )

        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: .photos(folder: "/tmp/photos")
            )
        ))
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: .video(files: ["/tmp/one.mov"])
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidVideoSourceAnalysis)
        }

        artifact.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: 2,
            startedAnalysisTaskCount: 2,
            peakInFlightAnalysisTaskCount: 2
        )
        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: .mixed(
                    videos: ["/tmp/one.mov", "/tmp/two.mov"],
                    photosFolder: "/tmp/photos"
                )
            )
        ))
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: .video(files: ["/tmp/one.mov"])
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidVideoSourceAnalysis)
        }
    }

    func testMappingStageAcceptsNativeModelConverterEvidence() throws {
        var artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.modelConverter)
        )

        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))
    }

    func testValidationRejectsContradictoryOrOutOfRangeExitStatus() throws {
        var artifact = makeArtifact()
        artifact.matchingInvocations[0].exitStatus = 1
        artifact.matchingInvocations[0].succeeded = true

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidExitStatus)
        }

        artifact = makeArtifact()
        artifact.matchingInvocations[0].exitStatus = -1
        artifact.matchingInvocations[0].succeeded = false
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidExitStatus)
        }
    }

    func testPublishedGeometryRejectsAnExecutedStageWithoutAnySuccess() throws {
        var artifact = makeArtifact()
        artifact.matchingInvocations = [
            failedThenRecoveredInvocation(
                .matchesImporter,
                workers: budget.coupledMatchingWorkers
            )
        ]

        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }
    }

    func testPublishedIncrementalGeometryKeepsFailedOptionalAttempts() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
            videoSourceCount: 0,
            startedAnalysisTaskCount: 0,
            peakInFlightAnalysisTaskCount: 0
        )
        var failedAnalyzer = nativeAutoInvocation(.modelAnalyzer)
        failedAnalyzer.exitStatus = 1
        failedAnalyzer.succeeded = false
        artifact.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.mapper),
            failedAnalyzer,
            nativeAutoInvocation(.modelAnalyzer),
        ]

        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: .photos(folder: "/tmp/photos")
            )
        ))
    }

    func testValidationCapsInvocationCounts() throws {
        var artifact = makeArtifact()
        artifact.matchingInvocations = Array(
            repeating: boundedInvocation(.matchesImporter, workers: budget.coupledMatchingWorkers),
            count: GeometryWorkerExecutionArtifact.maximumInvocationsPerStage + 1
        )

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidInvocationCount)
        }
    }

    func testStoreRejectsNoncanonicalAndSymlinkedLocations() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = makeArtifact()
        let canonicalURL = GeometryWorkerExecutionArtifactStore.canonicalURL(for: fixture.paths)
        let outside = fixture.root.appendingPathComponent("outside.json")

        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.save(
            artifact,
            to: outside,
            expectedBudget: budget,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidLocation)
        }

        try Data("{}".utf8).write(to: outside, options: [.atomic])
        try FileManager.default.createSymbolicLink(
            at: canonicalURL,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.load(
            from: canonicalURL,
            expectedBudget: budget,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .invalidLocation)
        }
    }

    private let budget = GeometryWorkerBudget(
        featureExtractionWorkers: 12,
        coupledMatchingWorkers: 8,
        vocabularyRetrievalWorkers: 6,
        maximumConcurrentVideoSourceAnalysisTasks: 4
    )

    private let expectedInvocationJSONKeys: Set<String> = [
        "command",
        "mappingAttemptOrdinal",
        "threadPolicy",
        "argvWorkerCount",
        "explicitThreadEnvironment",
        "removedThreadEnvironmentKeysSHA256",
        "effectiveSanitizedThreadEnvironment",
        "exitStatus",
        "succeeded",
    ]

    private var twoVideoInput: InputSpec {
        .video(files: ["/tmp/one.mov", "/tmp/two.mov"])
    }

    private func makeArtifact() -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
            resolvedBudget: budget,
            featureExtractionInvocations: [
                boundedInvocation(.featureExtractor, workers: budget.featureExtractionWorkers)
            ],
            matchingInvocations: [
                failedThenRecoveredInvocation(.matchesImporter, workers: budget.coupledMatchingWorkers),
                boundedInvocation(.matchesImporter, workers: budget.coupledMatchingWorkers),
            ],
            vocabularyRetrievalInvocations: [
                boundedInvocation(
                    .localVocabularyRetriever,
                    workers: budget.vocabularyRetrievalWorkers
                )
            ],
            mappingAndRefinementInvocations: [
                nativeAutoInvocation(.mapper),
                nativeAutoInvocation(.modelAnalyzer),
            ],
            videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: 2,
                startedAnalysisTaskCount: 4,
                peakInFlightAnalysisTaskCount: 2
            )
        )
    }

    private func boundedInvocation(
        _ command: ColmapWorkerCommandIdentity,
        workers: Int
    ) -> ColmapWorkerInvocationEvidence {
        let environment = [
            "OMP_NUM_THREADS": "\(workers)",
            "OPENBLAS_NUM_THREADS": "\(workers)",
            "MKL_NUM_THREADS": "\(workers)",
        ]
        return ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: nil,
            threadPolicy: .bounded,
            argvWorkerCount: workers,
            explicitThreadEnvironment: environment,
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: environment,
            exitStatus: 0,
            succeeded: true
        )
    }

    private func failedThenRecoveredInvocation(
        _ command: ColmapWorkerCommandIdentity,
        workers: Int
    ) -> ColmapWorkerInvocationEvidence {
        var invocation = boundedInvocation(command, workers: workers)
        invocation.exitStatus = 1
        invocation.succeeded = false
        return invocation
    }

    private func failedNativeAutoInvocation(
        _ command: ColmapWorkerCommandIdentity
    ) -> ColmapWorkerInvocationEvidence {
        var invocation = nativeAutoInvocation(command)
        invocation.exitStatus = 1
        invocation.succeeded = false
        return invocation
    }

    private func nativeAutoInvocation(
        _ command: ColmapWorkerCommandIdentity,
        mappingAttemptOrdinal: Int = 1
    ) -> ColmapWorkerInvocationEvidence {
        ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: mappingAttemptOrdinal,
            threadPolicy: .nativeAuto,
            argvWorkerCount: nil,
            explicitThreadEnvironment: [:],
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: [:],
            exitStatus: 0,
            succeeded: true
        )
    }

    private func publicationContext(
        refinement: MappingRefinementKind,
        pairGraph: PairGraphArtifact,
        input: InputSpec,
        acceptedMappingAttemptOrdinal: Int = 1
    ) -> GeometryWorkerExecutionPublicationContext {
        GeometryWorkerExecutionPublicationContext(
            mapping: MappingArtifact(
                modelCount: 1,
                largestModelRegisteredViewCount: 3,
                secondLargestModelRegisteredViewCount: 0,
                unionRegisteredViewCount: 3,
                attemptCount: 1,
                acceptedMappingAttemptOrdinal: acceptedMappingAttemptOrdinal,
                acceptedRefinementKind: refinement,
                acceptedRefinementInvocationCount:
                    refinement == .seededBundleAdjustment ? 1 : 0,
                incrementalCadence: refinement == .incrementalGlobal ? .conservative : nil,
                fallbackReason: nil
            ),
            pairGraph: pairGraph,
            input: input
        )
    }

    private func measuredPairGraph(
        retrievalPairCount: Int = 0,
        loopRevisitPairCount: Int = 0,
        usedLocalVocabularyRetrieval: Bool = false
    ) -> PairGraphArtifact {
        .measured(PairGraphMeasurement(
            scheduledPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
            attemptedPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
            rawMatchedPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
            spatiallyVerifiedPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
            localPairCount: 3,
            retrievalPairCount: retrievalPairCount,
            loopRevisitPairCount: loopRevisitPairCount,
            connectedComponentCount: 1,
            isolatedViewCount: 0,
            descriptorlessViewCount: 0,
            componentViewCounts: [3],
            articulationViewCount: 0,
            biconnectedBlockCount: 1,
            largestBiconnectedBlockViewCount: 3,
            secondLargestBiconnectedBlockViewCount: 0,
            degreeP10: 2,
            degreeMedian: 2,
            degreeP90: 2,
            matcherAttempts: [],
            pairListDigest: String(repeating: "a", count: 64),
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            matchingDurationSeconds: 0
        ), usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval)
    }

    private func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        return (root, paths)
    }
}
#endif
