#if canImport(XCTest)
import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryWorkerExecutionArtifactTests: XCTestCase {
    func testInvocationEncodingEmitsEveryKeyAndExplicitOptionalNulls() throws {
        XCTAssertEqual(GeometryWorkerExecutionArtifact.currentSchemaVersion, 13)
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
        XCTAssertTrue(boundedJSON["mapperExecution"] is NSNull)
        XCTAssertTrue(boundedJSON["modelConversion"] is NSNull)
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
        let mapperJSON = try XCTUnwrap(nativeJSON["mapperExecution"] as? [String: Any])
        XCTAssertEqual(Set(mapperJSON.keys), [
            "incrementalCadence",
            "globalMaxNumIterations",
            "randomSeed",
            "refineFocalLength",
            "minimumPairInlierCount",
            "pairGraphAttemptOrdinal",
            "pairListDigest",
            "descriptorMatcher",
            "matchingDatabaseDigest",
            "evaluation",
        ])
        XCTAssertEqual(mapperJSON["globalMaxNumIterations"] as? Int, 75)
        XCTAssertEqual(mapperJSON["randomSeed"] as? Int, 42)
        XCTAssertEqual(mapperJSON["refineFocalLength"] as? Bool, true)
        XCTAssertEqual(mapperJSON["minimumPairInlierCount"] as? Int, 15)
        XCTAssertEqual(mapperJSON["pairGraphAttemptOrdinal"] as? Int, 2)
        XCTAssertEqual(mapperJSON["descriptorMatcher"] as? String, "faiss")
        let evaluationJSON = try XCTUnwrap(mapperJSON["evaluation"] as? [String: Any])
        XCTAssertEqual(Set(evaluationJSON.keys), ["status", "fallbackTrigger"])
        XCTAssertEqual(evaluationJSON["status"] as? String, "accepted")
        XCTAssertTrue(evaluationJSON["fallbackTrigger"] is NSNull)

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

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var mapper = try XCTUnwrap(object["mapperExecution"] as? [String: Any])
        mapper.removeValue(forKey: "matchingDatabaseDigest")
        object["mapperExecution"] = mapper
        XCTAssertThrowsError(try JSONDecoder().decode(
            ColmapWorkerInvocationEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        mapper = try XCTUnwrap(object["mapperExecution"] as? [String: Any])
        mapper["retiredField"] = true
        object["mapperExecution"] = mapper
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

    func testLoadFromDataUsesCapturedBytesAfterCanonicalFileChanges() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = makeArtifact()
        let captured = try JSONEncoder().encode(artifact)
        try Data("{\"replacement\":true}".utf8).write(
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: fixture.paths),
            options: [.atomic]
        )

        XCTAssertEqual(
            try GeometryWorkerExecutionArtifactStore.load(
                data: captured,
                expectedBudget: budget
            ),
            artifact
        )
        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.load(
            from: GeometryWorkerExecutionArtifactStore.canonicalURL(for: fixture.paths),
            expectedBudget: budget,
            projectPaths: fixture.paths
        ))
    }

    func testLoadFromDataRejectsInvalidByteEnvelopeAndOldSchema() throws {
        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.load(
            data: Data(),
            expectedBudget: budget
        ))
        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.load(
            data: Data("not-json".utf8),
            expectedBudget: budget
        ))
        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.load(
            data: Data(
                repeating: 0x20,
                count: GeometryWorkerExecutionArtifactStore.maximumBytes + 1
            ),
            expectedBudget: budget
        ))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeArtifact()))
                as? [String: Any]
        )
        let oldSchema = GeometryWorkerExecutionArtifact.currentSchemaVersion - 1
        object["schemaVersion"] = oldSchema
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.load(
            data: data,
            expectedBudget: budget
        )) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .invalidSchema(oldSchema)
            )
        }
    }

    func testLoadFromDataEnforcesExpectedBudget() throws {
        let data = try JSONEncoder().encode(makeArtifact())
        let unexpected = GeometryWorkerBudget(
            featureExtractionWorkers: budget.featureExtractionWorkers - 1,
            coupledMatchingWorkers: budget.coupledMatchingWorkers,
            vocabularyRetrievalWorkers: budget.vocabularyRetrievalWorkers,
            maximumConcurrentVideoSourceAnalysisTasks:
                budget.maximumConcurrentVideoSourceAnalysisTasks
        )

        XCTAssertThrowsError(try GeometryWorkerExecutionArtifactStore.load(
            data: data,
            expectedBudget: unexpected
        )) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .workerBudgetMismatch
            )
        }
    }

    func testValidationRequiresCanonicalRuntimeClosureOrderAndDigest() throws {
        var artifact = makeArtifact()
        artifact.colmapRuntimeClosure.closureSHA256 = String(repeating: "c", count: 64)

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .invalidRuntimeClosure
            )
        }

        artifact = makeArtifact()
        artifact.colmapRuntimeClosure.components.reverse()
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .invalidRuntimeClosure
            )
        }
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

    func testPublishedBinaryGeometryRequiresItsSuccessfulModelConverter() throws {
        let conversionEvidence = binaryConversionEvidence()
        let binaryPublication = CanonicalModelPublicationArtifact(
            kind: .convertedFromBinary,
            sourceModelHashes: [
                "cameras.bin": String(repeating: "a", count: 64),
                "images.bin": String(repeating: "b", count: 64),
                "points3D.bin": String(repeating: "c", count: 64),
            ],
            conversion: CanonicalModelConversionArtifact(
                invocationOrdinal: 1,
                workerEvidence: conversionEvidence
            )
        )
        let context = publicationContext(
            refinement: .incrementalGlobal,
            pairGraph: measuredPairGraph(),
            input: twoVideoInput,
            canonicalModelPublication: binaryPublication
        )
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []

        XCTAssertThrowsError(
            try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: context
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .incompleteStage
            )
        }

        artifact.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.modelConverter, modelConversion: conversionEvidence)
        )
        XCTAssertNoThrow(
            try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: context
            )
        )

        artifact.mappingAndRefinementInvocations[2].succeeded = false
        artifact.mappingAndRefinementInvocations[2].exitStatus = 1
        artifact.mappingAndRefinementInvocations[2].modelConversion?
            .convertedModelDigest = nil
        XCTAssertThrowsError(
            try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: context
            )
        )
    }

    func testPublishedBinaryGeometryBindsTheConverterInvocationNotItsSuccessCount() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        let sourceHashes = [
            "cameras.bin": String(repeating: "a", count: 64),
            "images.bin": String(repeating: "b", count: 64),
            "points3D.bin": String(repeating: "c", count: 64),
        ]
        let conversionEvidence = binaryConversionEvidence(sourceHashes: sourceHashes)
        var failedConverter = nativeAutoInvocation(
            .modelConverter,
            modelConversion: conversionEvidence
        )
        failedConverter.exitStatus = 1
        failedConverter.succeeded = false
        failedConverter.modelConversion?.convertedModelDigest = nil
        artifact.mappingAndRefinementInvocations.append(failedConverter)
        artifact.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.modelConverter, modelConversion: conversionEvidence)
        )

        func context(converterOrdinal: Int) -> GeometryWorkerExecutionPublicationContext {
            publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput,
                canonicalModelPublication: CanonicalModelPublicationArtifact(
                    kind: .convertedFromBinary,
                    sourceModelHashes: sourceHashes,
                    conversion: CanonicalModelConversionArtifact(
                        invocationOrdinal: converterOrdinal,
                        workerEvidence: conversionEvidence
                    )
                )
            )
        }

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context(converterOrdinal: 1)
        ))
        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context(converterOrdinal: 2)
        ))
    }

    func testPublishedBinaryGeometryRejectsConverterFromAnotherCandidate() throws {
        let recordedEvidence = binaryConversionEvidence()
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.modelConverter, modelConversion: recordedEvidence)
        )
        let publishedSourceHashes = [
            "cameras.bin": String(repeating: "d", count: 64),
            "images.bin": String(repeating: "e", count: 64),
            "points3D.bin": String(repeating: "f", count: 64),
        ]
        let publication = CanonicalModelPublicationArtifact(
            kind: .convertedFromBinary,
            sourceModelHashes: publishedSourceHashes,
            conversion: CanonicalModelConversionArtifact(
                invocationOrdinal: 1,
                workerEvidence: binaryConversionEvidence(
                    sourceHashes: publishedSourceHashes,
                    candidatePath: "SfM/colmap/sparse/1"
                )
            )
        )

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput,
                canonicalModelPublication: publication
            )
        ))
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

    func testPublishedMapperEvidenceAcceptsOnlyTheTwoFixedGraphCadenceTransitions() throws {
        for transition in [
            (
                planned: IncrementalMappingCadenceArtifact.orderedFast,
                accepted: IncrementalMappingCadenceArtifact.balancedGlobal
            ),
            (
                planned: IncrementalMappingCadenceArtifact.balancedGlobal,
                accepted: IncrementalMappingCadenceArtifact.frequentGlobal
            ),
        ] {
            var artifact = makeArtifact()
            artifact.vocabularyRetrievalInvocations = []
            artifact.mappingAndRefinementInvocations = [
                nativeAutoInvocation(
                    .mapper,
                    mappingAttemptOrdinal: 1,
                    mapperExecution: mapperExecution(
                        cadence: transition.planned,
                        evaluation: ColmapMapperEvaluationEvidence(
                            status: .rejected,
                            fallbackTrigger: .insufficientViewSupport
                        )
                    )
                ),
                nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 1),
                nativeAutoInvocation(
                    .mapper,
                    mappingAttemptOrdinal: 2,
                    mapperExecution: mapperExecution(
                        cadence: transition.accepted,
                        evaluation: ColmapMapperEvaluationEvidence(
                            status: .accepted,
                            fallbackTrigger: nil
                        )
                    )
                ),
                nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 2),
            ]

            XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
                expectedBudget: budget,
                context: publicationContext(
                    refinement: .incrementalGlobal,
                    pairGraph: measuredPairGraph(),
                    input: twoVideoInput,
                    acceptedMappingAttemptOrdinal: 2,
                    plannedCadence: transition.planned,
                    acceptedCadence: transition.accepted,
                    cadenceFallbackTrigger: .insufficientViewSupport
                )
            ))
        }
    }

    func testPublishedMapperEvidenceRejectsMissingOrContradictoryEvaluation() throws {
        let context = publicationContext(
            refinement: .incrementalGlobal,
            pairGraph: measuredPairGraph(),
            input: twoVideoInput,
            plannedCadence: .balancedGlobal,
            acceptedCadence: .balancedGlobal
        )
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations[0].mapperExecution?.evaluation = nil
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.mapper, mappingAttemptOrdinal: 1),
            nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 1),
            nativeAutoInvocation(
                .mapper,
                mappingAttemptOrdinal: 2,
                mapperExecution: mapperExecution(
                    cadence: .balancedGlobal,
                    evaluation: ColmapMapperEvaluationEvidence(
                        status: .accepted,
                        fallbackTrigger: nil
                    )
                )
            ),
            nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 2),
        ]
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput,
                acceptedMappingAttemptOrdinal: 2,
                plannedCadence: .balancedGlobal,
                acceptedCadence: .balancedGlobal
            )
        ))

        artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations[0].mapperExecution?.evaluation =
            ColmapMapperEvaluationEvidence(
                status: .accepted,
                fallbackTrigger: .insufficientViewSupport
            )
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))
    }

    func testPublishedMapperEvidenceRejectsGraphOrAcceptedCadenceTampering() throws {
        let planned = IncrementalMappingCadenceArtifact.balancedGlobal
        let accepted = IncrementalMappingCadenceArtifact.frequentGlobal
        func fallbackArtifact() -> GeometryWorkerExecutionArtifact {
            var artifact = makeArtifact()
            artifact.vocabularyRetrievalInvocations = []
            artifact.mappingAndRefinementInvocations = [
                nativeAutoInvocation(
                    .mapper,
                    mappingAttemptOrdinal: 1,
                    mapperExecution: mapperExecution(
                        cadence: planned,
                        evaluation: ColmapMapperEvaluationEvidence(
                            status: .rejected,
                            fallbackTrigger: .insufficientViewSupport
                        )
                    )
                ),
                nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 1),
                nativeAutoInvocation(
                    .mapper,
                    mappingAttemptOrdinal: 2,
                    mapperExecution: mapperExecution(
                        cadence: accepted,
                        evaluation: ColmapMapperEvaluationEvidence(
                            status: .accepted,
                            fallbackTrigger: nil
                        )
                    )
                ),
                nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 2),
            ]
            return artifact
        }
        let context = publicationContext(
            refinement: .incrementalGlobal,
            pairGraph: measuredPairGraph(),
            input: twoVideoInput,
            acceptedMappingAttemptOrdinal: 2,
            plannedCadence: planned,
            acceptedCadence: accepted,
            cadenceFallbackTrigger: .insufficientViewSupport
        )

        var artifact = fallbackArtifact()
        artifact.mappingAndRefinementInvocations[2].mapperExecution?
            .matchingDatabaseDigest = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        artifact = fallbackArtifact()
        artifact.mappingAndRefinementInvocations[2].mapperExecution?
            .pairGraphAttemptOrdinal = 1
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        artifact = fallbackArtifact()
        artifact.mappingAndRefinementInvocations[2].mapperExecution?
            .pairListDigest = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        artifact = fallbackArtifact()
        artifact.mappingAndRefinementInvocations[2].mapperExecution?
            .descriptorMatcher = .exact
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        artifact = fallbackArtifact()
        artifact.mappingAndRefinementInvocations[2].mapperExecution?
            .incrementalCadence = .orderedFast
        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))
    }

    func testPublishedMapperEvidenceRejectsMoreThanOneCadenceTransition() throws {
        let rejected = ColmapMapperEvaluationEvidence(
            status: .rejected,
            fallbackTrigger: .insufficientViewSupport
        )
        let accepted = ColmapMapperEvaluationEvidence(
            status: .accepted,
            fallbackTrigger: nil
        )
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations = [
            nativeAutoInvocation(
                .mapper,
                mappingAttemptOrdinal: 1,
                mapperExecution: mapperExecution(
                    cadence: .orderedFast,
                    evaluation: rejected
                )
            ),
            nativeAutoInvocation(
                .mapper,
                mappingAttemptOrdinal: 2,
                mapperExecution: mapperExecution(
                    cadence: .balancedGlobal,
                    evaluation: rejected
                )
            ),
            nativeAutoInvocation(
                .mapper,
                mappingAttemptOrdinal: 3,
                mapperExecution: mapperExecution(
                    cadence: .frequentGlobal,
                    evaluation: accepted
                )
            ),
            nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 3),
        ]

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput,
                acceptedMappingAttemptOrdinal: 3,
                plannedCadence: .orderedFast,
                acceptedCadence: .frequentGlobal,
                cadenceFallbackTrigger: .insufficientViewSupport
            )
        ))
    }

    func testPublishedMapperEvidenceRejectsCrashDisguisedAsCadenceFallback() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations = [
            failedNativeAutoInvocation(
                .mapper,
                mappingAttemptOrdinal: 1,
                mapperExecution: mapperExecution(
                    cadence: .orderedFast,
                    evaluation: nil
                )
            ),
            nativeAutoInvocation(
                .mapper,
                mappingAttemptOrdinal: 2,
                mapperExecution: mapperExecution(
                    cadence: .balancedGlobal,
                    evaluation: ColmapMapperEvaluationEvidence(
                        status: .accepted,
                        fallbackTrigger: nil
                    )
                )
            ),
            nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 2),
        ]

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(),
                input: twoVideoInput,
                acceptedMappingAttemptOrdinal: 2,
                plannedCadence: .orderedFast,
                acceptedCadence: .balancedGlobal,
                cadenceFallbackTrigger: .insufficientViewSupport
            )
        ))
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
            if refinement == .seededBundleAdjustment {
                configureSeededMatching(&artifact)
            }
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
            configureSeededMatching(&artifact)
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
            configureSeededMatching(&artifact)
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

        artifact.matchingInvocations[0].pairExecution?.scheduledPairCount = 6
        artifact.matchingInvocations[1].pairExecution?.scheduledPairCount = 6
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
        artifact.matchingInvocations[0].pairExecution?.scheduledPairCount = 3
        artifact.matchingInvocations[1].pairExecution?.scheduledPairCount = 3

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
                pairGraph: measuredPairGraph(
                    retrievalWasScheduled: true,
                    usedLocalVocabularyRetrieval: false
                ),
                input: .photos(folder: "/tmp/photos")
            )
        ))
        artifact.vocabularyRetrievalInvocations = []

        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(retrievalWasScheduled: true),
                input: .photos(folder: "/tmp/photos")
            )
        ))

        XCTAssertThrowsError(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(
                    retrievalPairCount: 1,
                    retrievalWasScheduled: true,
                    usedLocalVocabularyRetrieval: true
                ),
                input: .photos(folder: "/tmp/photos")
            )
        )) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }

        let requestDigest = String(repeating: "d", count: 64)
        let outputDigest = String(repeating: "e", count: 64)
        artifact.matchingInvocations[1].pairExecution?.retrievalRequestDigest =
            requestDigest
        artifact.matchingInvocations[1].pairExecution?.retrievalOutputDigest =
            outputDigest
        artifact.matchingInvocations[0].pairExecution?.scheduledPairCount = 4
        artifact.matchingInvocations[1].pairExecution?.scheduledPairCount = 4
        artifact.vocabularyRetrievalInvocations = [
            boundedInvocation(
                .localVocabularyRetriever,
                workers: budget.vocabularyRetrievalWorkers,
                pairExecution: ColmapPairWorkerExecutionEvidence(
                    attemptOrdinal: 1,
                    descriptorMatcher: .faiss,
                    retrievalRequestDigest: requestDigest,
                    retrievalOutputDigest: outputDigest
                )
            ),
        ]
        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: publicationContext(
                refinement: .incrementalGlobal,
                pairGraph: measuredPairGraph(
                    retrievalPairCount: 1,
                    retrievalWasScheduled: true,
                    usedLocalVocabularyRetrieval: true
                ),
                input: .photos(folder: "/tmp/photos")
            )
        ))
    }

    func testPublishedSeededGeometryAuthenticatesBoundedFaissFirstExactRecovery() throws {
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.mappingAndRefinementInvocations = [
            nativeAutoInvocation(.pointTriangulator),
            nativeAutoInvocation(.bundleAdjuster),
            nativeAutoInvocation(.modelAnalyzer),
        ]
        let digest = String(repeating: "a", count: 64)
        artifact.matchingInvocations = [
            failedThenRecoveredInvocation(
                .matchesImporter,
                workers: budget.coupledMatchingWorkers,
                pairExecution: ColmapPairWorkerExecutionEvidence(
                    attemptOrdinal: 1,
                    descriptorMatcher: .faiss,
                    scheduledPairCount: 256,
                    pairListDigest: digest
                )
            ),
            boundedInvocation(
                .matchesImporter,
                workers: budget.coupledMatchingWorkers,
                pairExecution: ColmapPairWorkerExecutionEvidence(
                    attemptOrdinal: 2,
                    descriptorMatcher: .exact,
                    scheduledPairCount: 256,
                    pairListDigest: digest,
                    exactRecoveryReason: .faissCrash
                )
            ),
        ]
        let context = publicationContext(
            refinement: .seededBundleAdjustment,
            pairGraph: .notEvaluated(),
            input: twoVideoInput
        )

        XCTAssertNoThrow(try artifact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        var firstExact = artifact
        firstExact.matchingInvocations.removeFirst()
        XCTAssertThrowsError(try firstExact.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        var oversized = artifact
        oversized.matchingInvocations[0].pairExecution?.scheduledPairCount = 257
        oversized.matchingInvocations[1].pairExecution?.scheduledPairCount = 257
        XCTAssertThrowsError(try oversized.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))

        var mismatchedSchedule = artifact
        mismatchedSchedule.matchingInvocations[1].pairExecution?.pairListDigest =
            String(repeating: "b", count: 64)
        XCTAssertThrowsError(try mismatchedSchedule.validateForPublishedGeometry(
            expectedBudget: budget,
            context: context
        ))
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
            nativeAutoInvocation(
                .modelConverter,
                modelConversion: binaryConversionEvidence()
            )
        )

        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))
    }

    func testMappingStageRejectsModelConverterOutsideCanonicalToolchainPath() throws {
        var conversion = binaryConversionEvidence()
        conversion.executableComponentPath = "bin/other-colmap"
        var artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.modelConverter, modelConversion: conversion)
        )

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }
    }

    func testMappingStageRejectsMalformedModelConverterDigest() throws {
        var conversion = binaryConversionEvidence()
        conversion.executableSHA256 = "not-a-digest"
        var artifact = makeArtifact()
        artifact.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(.modelConverter, modelConversion: conversion)
        )

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget)) { error in
            XCTAssertEqual(error as? GeometryWorkerExecutionArtifactError, .incompleteStage)
        }
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

    func testCurrentSchemaRequiresRejectedVocabularyRetrievalLedger() throws {
        let artifact = makeArtifact()
        let encoded = try JSONEncoder().encode(artifact)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(
            object["schemaVersion"] as? Int,
            GeometryWorkerExecutionArtifact.currentSchemaVersion
        )
        XCTAssertNotNil(object["rejectedVocabularyRetrievalInvocations"])

        object.removeValue(forKey: "rejectedVocabularyRetrievalInvocations")
        XCTAssertThrowsError(try JSONDecoder().decode(
            GeometryWorkerExecutionArtifact.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testRejectedVocabularyRetrievalLedgerRejectsForgedDuplicateAndCrossLedgerEvidence() throws {
        let imageNames = (0..<61).map { "image_\($0).jpg" }
        let retrieval = rejectedRetrievalEvidence(imageNames: imageNames)
        let invocation = rejectedRetrievalInvocation(
            attemptOrdinal: 1,
            retrieval: retrieval
        )
        let entry = RejectedVocabularyRetrievalExecutionEvidence(
            retrievalAttemptOrdinal: 1,
            pairingPolicy: .unorderedRetrieval,
            planBinding: .testingDefault(pairingPolicy: .unorderedRetrieval),
            recoveryLevel: .normal,
            imageNames: imageNames,
            groups: [ColmapPairGroup(imageNames: imageNames, isVideo: false)],
            invocation: invocation,
            retrieval: retrieval,
            durationSeconds: 0.25
        )
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.rejectedVocabularyRetrievalInvocations = [entry]

        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))

        var forged = artifact
        forged.rejectedVocabularyRetrievalInvocations[0]
            .retrieval.outputDigest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try forged.validate(expectedBudget: budget))

        var unboundRequest = artifact
        unboundRequest.rejectedVocabularyRetrievalInvocations[0]
            .planBinding.retrievalCandidateCount = 21
        XCTAssertThrowsError(try unboundRequest.validate(expectedBudget: budget))

        var unfinishedInvocation = artifact
        unfinishedInvocation.rejectedVocabularyRetrievalInvocations[0]
            .invocation.exitStatus = 1
        unfinishedInvocation.rejectedVocabularyRetrievalInvocations[0]
            .invocation.succeeded = false
        XCTAssertThrowsError(try unfinishedInvocation.validate(expectedBudget: budget))

        var wrongOrdinal = artifact
        wrongOrdinal.rejectedVocabularyRetrievalInvocations[0]
            .retrievalAttemptOrdinal = 2
        XCTAssertThrowsError(try wrongOrdinal.validate(expectedBudget: budget))

        var duplicate = artifact
        duplicate.rejectedVocabularyRetrievalInvocations.append(entry)
        XCTAssertThrowsError(try duplicate.validate(expectedBudget: budget))

        var crossLedger = artifact
        crossLedger.vocabularyRetrievalInvocations = [invocation]
        XCTAssertThrowsError(try crossLedger.validate(expectedBudget: budget))
    }

    func testRejectedVocabularyRetrievalLedgerAcceptsAllRankedDisconnectedSchedule() throws {
        let imageNames = (0..<61).map { String(format: "image_%03d.jpg", $0) }
        let components = [Array(imageNames.prefix(30)), Array(imageNames.suffix(31))]
        var neighborByQuery: [String: String] = [:]
        for component in components {
            for (index, query) in component.enumerated() {
                neighborByQuery[query] = component[(index + 1) % component.count]
            }
        }
        let outcomes = imageNames.map { query in
            PairGraphRetrievalQueryOutcome(
                queryImageName: query,
                status: .ranked,
                rankedNeighborImageNames: [neighborByQuery[query]!]
            )
        }
        let retrieval = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: imageNames,
            queryStride: 1,
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            queryOutcomes: outcomes,
            directedPairLines: outcomes.map {
                "\($0.queryImageName) \($0.rankedNeighborImageNames[0])"
            }.sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
        )
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.rejectedVocabularyRetrievalInvocations = [
            RejectedVocabularyRetrievalExecutionEvidence(
                retrievalAttemptOrdinal: 1,
                pairingPolicy: .unorderedRetrieval,
                planBinding: .testingDefault(pairingPolicy: .unorderedRetrieval),
                recoveryLevel: .normal,
                imageNames: imageNames,
                groups: [ColmapPairGroup(imageNames: imageNames, isVideo: false)],
                invocation: rejectedRetrievalInvocation(
                    attemptOrdinal: 1,
                    retrieval: retrieval
                ),
                retrieval: retrieval,
                durationSeconds: 0.25
            ),
        ]

        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))
    }

    func testRejectedVocabularyRetrievalLedgerRejectsConnectedOrderedBase() throws {
        let imageNames = (0..<120).map { String(format: "image_%03d.jpg", $0) }
        let retrieval = rejectedRetrievalEvidence(
            imageNames: imageNames,
            minimumFrameSeparation: 12
        )
        var binding = PairGraphPlanBinding.testingDefault(
            pairingPolicy: .orderedContinuous
        )
        binding.temporalPairing = .multiscale
        binding.temporalOffsets = [1, 2, 4, 8, 16, 32, 64]
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.rejectedVocabularyRetrievalInvocations = [
            RejectedVocabularyRetrievalExecutionEvidence(
                retrievalAttemptOrdinal: 1,
                pairingPolicy: .orderedContinuous,
                planBinding: binding,
                recoveryLevel: .normal,
                imageNames: imageNames,
                groups: [ColmapPairGroup(imageNames: imageNames, isVideo: true)],
                invocation: rejectedRetrievalInvocation(
                    attemptOrdinal: 1,
                    retrieval: retrieval
                ),
                retrieval: retrieval,
                durationSeconds: 0.25
            ),
        ]

        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget))
    }

    func testRejectedRetrievalBindsShortOrderedCrossClipRequirement() throws {
        let firstClip = (0..<17).map { "a_\($0).jpg" }
        let secondClip = (0..<3).map { "b_\($0).jpg" }
        let imageNames = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let queryImageNames = [firstClip[0], firstClip[10], secondClip[0]]
        let groupContract = try XCTUnwrap(
            PipelineRunner.vocabularyRetrievalImageGroupContract(
                imageNames: imageNames,
                groups: groups,
                requiresCrossClipRetrieval: true
            )
        )
        let retrieval = rejectedRetrievalEvidence(
            imageNames: queryImageNames,
            queryStride: 10,
            minimumFrameSeparation: 0,
            imageGroupContract: groupContract
        )
        var binding = PairGraphPlanBinding.testingDefault(
            pairingPolicy: .orderedContinuous
        )
        binding.temporalPairing = .linear
        binding.temporalOffsets = [1, 2, 3, 4, 5, 6]
        binding.retrievalQueryStride = 10
        binding.requiresCrossClipRetrieval = true
        var artifact = makeArtifact()
        artifact.vocabularyRetrievalInvocations = []
        artifact.rejectedVocabularyRetrievalInvocations = [
            RejectedVocabularyRetrievalExecutionEvidence(
                retrievalAttemptOrdinal: 1,
                pairingPolicy: .orderedContinuous,
                planBinding: binding,
                recoveryLevel: .normal,
                imageNames: imageNames,
                groups: groups,
                invocation: rejectedRetrievalInvocation(
                    attemptOrdinal: 1,
                    retrieval: retrieval
                ),
                retrieval: retrieval,
                durationSeconds: 0.25
            ),
        ]

        XCTAssertNoThrow(try artifact.validate(expectedBudget: budget))

        var missingClip = artifact
        missingClip.rejectedVocabularyRetrievalInvocations[0].groups.removeLast()
        XCTAssertThrowsError(try missingClip.validate(expectedBudget: budget))

        artifact.rejectedVocabularyRetrievalInvocations[0]
            .planBinding.requiresCrossClipRetrieval = false
        XCTAssertThrowsError(try artifact.validate(expectedBudget: budget))
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
        "pairExecution",
        "mapperExecution",
        "modelConversion",
        "exitStatus",
        "succeeded",
    ]

    private var twoVideoInput: InputSpec {
        .video(files: ["/tmp/one.mov", "/tmp/two.mov"])
    }

    private func makeArtifact() -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
            colmapRuntimeClosure: makeColmapRuntimeClosureEvidence(),
            resolvedBudget: budget,
            featureExtractionInvocations: [
                boundedInvocation(.featureExtractor, workers: budget.featureExtractionWorkers)
            ],
            matchingInvocations: [
                failedThenRecoveredInvocation(
                    .matchesImporter,
                    workers: budget.coupledMatchingWorkers,
                    pairExecution: pairExecution(attemptOrdinal: 1)
                ),
                boundedInvocation(
                    .matchesImporter,
                    workers: budget.coupledMatchingWorkers,
                    pairExecution: pairExecution(attemptOrdinal: 2)
                ),
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
        workers: Int,
        pairExecution: ColmapPairWorkerExecutionEvidence? = nil
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
            pairExecution: pairExecution,
            exitStatus: 0,
            succeeded: true
        )
    }

    private func failedThenRecoveredInvocation(
        _ command: ColmapWorkerCommandIdentity,
        workers: Int,
        pairExecution: ColmapPairWorkerExecutionEvidence? = nil
    ) -> ColmapWorkerInvocationEvidence {
        var invocation = boundedInvocation(
            command,
            workers: workers,
            pairExecution: pairExecution
        )
        invocation.exitStatus = 1
        invocation.succeeded = false
        return invocation
    }

    private func pairExecution(
        attemptOrdinal: Int,
        scheduledPairCount: Int = 3
    ) -> ColmapPairWorkerExecutionEvidence {
        ColmapPairWorkerExecutionEvidence(
            attemptOrdinal: attemptOrdinal,
            descriptorMatcher: .faiss,
            scheduledPairCount: scheduledPairCount,
            pairListDigest: String(repeating: "a", count: 64)
        )
    }

    private func configureSeededMatching(
        _ artifact: inout GeometryWorkerExecutionArtifact
    ) {
        artifact.matchingInvocations = [
            boundedInvocation(
                .matchesImporter,
                workers: budget.coupledMatchingWorkers,
                pairExecution: pairExecution(attemptOrdinal: 1)
            ),
        ]
        artifact.vocabularyRetrievalInvocations = []
    }

    private func rejectedRetrievalEvidence(
        imageNames: [String],
        queryStride: Int = 1,
        minimumFrameSeparation: Int = 0,
        imageGroupContract: PipelineRunner.VocabularyRetrievalImageGroupContract? = nil
    ) -> PairGraphRetrievalAttemptEvidence {
        PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: imageNames,
            queryStride: queryStride,
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: minimumFrameSeparation,
            candidatePolicy: imageGroupContract?.policy,
            imageGroupListDigest: imageGroupContract?.digest,
            imageGroupLines: imageGroupContract?.canonicalLines,
            queryOutcomes: imageNames.map {
                PairGraphRetrievalQueryOutcome(
                    queryImageName: $0,
                    status: .noRankedNeighbors,
                    rankedNeighborImageNames: []
                )
            },
            directedPairLines: []
        )
    }

    private func rejectedRetrievalInvocation(
        attemptOrdinal: Int,
        retrieval: PairGraphRetrievalAttemptEvidence
    ) -> ColmapWorkerInvocationEvidence {
        boundedInvocation(
            .localVocabularyRetriever,
            workers: budget.vocabularyRetrievalWorkers,
            pairExecution: ColmapPairWorkerExecutionEvidence(
                attemptOrdinal: attemptOrdinal,
                descriptorMatcher: .faiss,
                pairListDigest: nil,
                retrievalRequestDigest: PairGraphEvidenceStore.retrievalRequestDigest(retrieval),
                retrievalOutputDigest: retrieval.outputDigest
            )
        )
    }

    private func failedNativeAutoInvocation(
        _ command: ColmapWorkerCommandIdentity,
        mappingAttemptOrdinal: Int = 1,
        mapperExecution: ColmapMapperWorkerExecutionEvidence? = nil
    ) -> ColmapWorkerInvocationEvidence {
        var invocation = nativeAutoInvocation(
            command,
            mappingAttemptOrdinal: mappingAttemptOrdinal,
            mapperExecution: mapperExecution
        )
        invocation.exitStatus = 1
        invocation.succeeded = false
        invocation.mapperExecution?.evaluation = nil
        return invocation
    }

    private func nativeAutoInvocation(
        _ command: ColmapWorkerCommandIdentity,
        mappingAttemptOrdinal: Int = 1,
        mapperExecution: ColmapMapperWorkerExecutionEvidence? = nil,
        modelConversion: ColmapModelConversionWorkerEvidence? = nil
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
            mapperExecution: mapperExecution ?? (command == .mapper
                ? self.mapperExecution(
                    cadence: .balancedGlobal,
                    evaluation: ColmapMapperEvaluationEvidence(
                        status: .accepted,
                        fallbackTrigger: nil
                    )
                )
                : nil),
            modelConversion: modelConversion,
            exitStatus: 0,
            succeeded: true
        )
    }

    private func mapperExecution(
        cadence: IncrementalMappingCadenceArtifact,
        evaluation: ColmapMapperEvaluationEvidence?
    ) -> ColmapMapperWorkerExecutionEvidence {
        ColmapMapperWorkerExecutionEvidence(
            incrementalCadence: cadence,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true,
            minimumPairInlierCount: 15,
            pairGraphAttemptOrdinal: 2,
            pairListDigest: String(repeating: "a", count: 64),
            descriptorMatcher: .faiss,
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            evaluation: evaluation
        )
    }

    private func binaryConversionEvidence(
        sourceHashes: [String: String] = [
            "cameras.bin": String(repeating: "a", count: 64),
            "images.bin": String(repeating: "b", count: 64),
            "points3D.bin": String(repeating: "c", count: 64),
        ],
        candidatePath: String = "SfM/colmap/sparse/0",
        mappingAttemptOrdinal: Int = 1
    ) -> ColmapModelConversionWorkerEvidence {
        let sourceDigest = GeometryArtifactStore.modelClosureDigest(
            sourceHashes,
            expectedNames: ["cameras.bin", "images.bin", "points3D.bin"]
        )!
        return ColmapModelConversionWorkerEvidence(
            executableComponentPath: "bin/colmap",
            executableSHA256: String(repeating: "a", count: 64),
            candidateProjectRelativePath: candidatePath,
            inputProjectRelativePath:
                "SfM/colmap/sparse/.text-model-00000000-0000-0000-0000-000000000000/binary",
            outputProjectRelativePath:
                "SfM/colmap/sparse/.text-model-00000000-0000-0000-0000-000000000000/text",
            sourceModelDigest: sourceDigest,
            convertedModelDigest: GeometryArtifactStore.modelClosureDigest(
                canonicalTextModelHashes(),
                expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
            ),
            candidateIdentitySHA256: GeometryArtifactStore.modelCandidateIdentity(
                mappingAttemptOrdinal: mappingAttemptOrdinal,
                candidateProjectRelativePath: candidatePath,
                sourceModelDigest: sourceDigest
            )!
        )
    }

    private func publicationContext(
        refinement: MappingRefinementKind,
        pairGraph: PairGraphArtifact,
        input: InputSpec,
        acceptedMappingAttemptOrdinal: Int = 1,
        plannedCadence: IncrementalMappingCadenceArtifact = .balancedGlobal,
        acceptedCadence: IncrementalMappingCadenceArtifact = .balancedGlobal,
        cadenceFallbackTrigger: MappingCadenceFallbackTrigger? = nil,
        canonicalModelPublication: CanonicalModelPublicationArtifact = directTextPublication()
    ) -> GeometryWorkerExecutionPublicationContext {
        GeometryWorkerExecutionPublicationContext(
            mapping: MappingArtifact(
                modelCount: 1,
                largestModelRegisteredViewCount: 3,
                secondLargestModelRegisteredViewCount: 0,
                unionRegisteredViewCount: 3,
                attemptCount: acceptedMappingAttemptOrdinal,
                acceptedMappingAttemptOrdinal: acceptedMappingAttemptOrdinal,
                acceptedRefinementKind: refinement,
                acceptedRefinementInvocationCount:
                    refinement == .seededBundleAdjustment ? 1 : 0,
                plannedIncrementalCadence:
                    refinement == .incrementalGlobal ? plannedCadence : nil,
                incrementalCadence:
                    refinement == .incrementalGlobal ? acceptedCadence : nil,
                cadenceFallbackTrigger:
                    refinement == .incrementalGlobal ? cadenceFallbackTrigger : nil,
                canonicalModelPublication: canonicalModelPublication,
                fallbackReason: nil
            ),
            pairGraph: pairGraph,
            input: input
        )
    }

    private func measuredPairGraph(
        retrievalPairCount: Int = 0,
        loopRevisitPairCount: Int = 0,
        retrievalWasScheduled: Bool = false,
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
            matcherAttempts: [
                PairMatchingAttemptArtifact(
                    attemptNumber: 1,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .failed,
                    scheduledPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
                    attemptedPairCount: 0,
                    rawMatchedPairCount: 0,
                    spatiallyVerifiedPairCount: 0,
                    durationSeconds: 0
                ),
                PairMatchingAttemptArtifact(
                    attemptNumber: 2,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .completed,
                    scheduledPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
                    attemptedPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
                    rawMatchedPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
                    spatiallyVerifiedPairCount: 3 + retrievalPairCount + loopRevisitPairCount,
                    durationSeconds: 0
                ),
            ],
            pairListDigest: String(repeating: "a", count: 64),
            featureDatabaseDigest: String(repeating: "b", count: 64),
            matchingDatabaseDigest: String(repeating: "c", count: 64),
            matchingDurationSeconds: 0
        ),
        retrievalWasScheduled: retrievalWasScheduled,
        usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval)
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
