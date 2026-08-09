import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

final class PublishedSplatReceiptTests: XCTestCase {
    func testProjectPathsExposeTheOnlyCanonicalReceiptPath() throws {
        let root = URL(fileURLWithPath: "/tmp/Receipt Project.easysplatproj", isDirectory: true)
        XCTAssertEqual(
            ProjectPaths(root: root).outputSplatReceiptURL.path,
            root.appendingPathComponent("Output/splat_receipt.json").path
        )
    }

    func testCanonicalEncodingIsDeterministicExactAndRoundTrips() throws {
        let receipt = makeReceipt()

        let first = try PublishedSplatReceiptStore.encode(receipt)
        let second = try PublishedSplatReceiptStore.encode(receipt)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try PublishedSplatReceiptStore.decode(first), receipt)
        XCTAssertEqual(
            SHA256.hash(data: first).map { String(format: "%02x", $0) }.joined(),
            "f2bd245ed4deafa642de8a5e5b9fac2999aa91d0cc7f9ba6fd166b244e06ab58"
        )
        XCTAssertFalse(first.last == UInt8(ascii: "\n"))
        XCTAssertTrue(
            try XCTUnwrap(String(data: first, encoding: .utf8)).contains(
                #""publishedAt":"2026-01-01T00:00:00Z""#
            )
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )
        XCTAssertEqual(
            Set(root.keys),
            [
                "schemaVersion",
                "publicationID",
                "projectID",
                "publishedAt",
                "outputPath",
                "outputEvidence",
                "lineage",
                "presentation",
            ]
        )
        let evidence = try XCTUnwrap(root["outputEvidence"] as? [String: Any])
        XCTAssertNotNil(evidence["gaussianCount"])
        XCTAssertNil(evidence["vertexCount"])
        let encodedText = try XCTUnwrap(String(data: first, encoding: .utf8))
        for forbidden in [
            "title", "notes", "viewerPreferences", "currentFailure", "checkpoint",
            "orderedImageNames", "datasetDerivation", "geometryArtifact",
        ] {
            XCTAssertNil(encodedText.range(of: forbidden), "Unexpected field: \(forbidden)")
        }
    }

    func testV1SchemaOmitsInputProjectionAndRejectsItAsUnknownData() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        let presentation = try XCTUnwrap(root["presentation"] as? [String: Any])

        XCTAssertEqual(
            Set(presentation.keys),
            [
                "requestedRunOptions",
                "resolvedRunPlan",
                "reconstruction",
                "orientation",
                "stageTimings",
                "autoTunerSnapshot",
                "trainerVersion",
                "runtimeVersion",
                "completedIteration",
                "trainingDurationSeconds",
                "createToViewerReadySeconds",
            ]
        )
        XCTAssertNil(presentation["inputProjection"])

        var tamperedRoot = root
        var tamperedPresentation = presentation
        tamperedPresentation["inputProjection"] = [
            "kind": "media",
            "videoCount": 1,
            "hasPhotos": false,
        ]
        tamperedRoot["presentation"] = tamperedPresentation
        let tampered = try JSONSerialization.data(withJSONObject: tamperedRoot)
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(tampered)) {
            guard case .unexpectedKeys = $0 as? PublishedSplatReceiptStoreError else {
                return XCTFail("Expected inputProjection to be rejected as unknown v1 data, got \($0)")
            }
        }
    }

    func testDecoderRejectsUnknownKeysAtEveryObjectNestingLevel() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let objectPaths: [[JSONPathComponent]] = [
            [],
            [.key("outputEvidence")],
            [.key("outputEvidence"), .key("sceneBounds")],
            [.key("outputEvidence"), .key("sceneBounds"), .key("center")],
            [.key("lineage")],
            [.key("presentation")],
            [.key("presentation"), .key("requestedRunOptions")],
            [.key("presentation"), .key("resolvedRunPlan")],
            [
                .key("presentation"), .key("resolvedRunPlan"),
                .key("geometryWorkerBudget"),
            ],
            [.key("presentation"), .key("reconstruction")],
            [.key("presentation"), .key("orientation")],
            [.key("presentation"), .key("orientation"), .key("openingDirection")],
            [.key("presentation"), .key("stageTimings"), .index(0)],
            [.key("presentation"), .key("autoTunerSnapshot")],
            [
                .key("presentation"), .key("autoTunerSnapshot"),
                .key("geometryWorkerBudget"),
            ],
        ]

        for path in objectPaths {
            let tampered = try addingUnknownKey(to: canonical, objectPath: path)
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(tampered), "Path: \(path)") {
                guard case .unexpectedKeys = $0 as? PublishedSplatReceiptStoreError else {
                    return XCTFail("Expected unexpectedKeys at \(path), got \($0)")
                }
            }
        }
    }

    func testDecoderRejectsDuplicateTopLevelAndNestedSecurityKeys() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let publicationID = "11111111-2222-4333-8444-555555555555"
        let digest = String(repeating: "a", count: 64)
        let cases = [
            try replacingOnce(
                in: canonical,
                target: #""publicationID":"\#(publicationID)""#,
                replacement:
                    #""publicationID":"\#(publicationID)","publicationID":"\#(publicationID)""#
            ),
            try replacingOnce(
                in: canonical,
                target: #""sha256":"\#(digest)""#,
                replacement:
                    #""sha256":"\#(digest)","\u0073ha256":"\#(digest)""#
            ),
        ]

        for duplicate in cases {
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(duplicate)) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .malformed)
            }
        }
    }

    func testDuplicateScannerDecodesEscapedKeysAndScopesKeysPerObject() throws {
        let escapedQuoteDuplicate = Data(
            #"{"schemaVersion":2,"a\"b":1,"a\u0022b":2}"#.utf8
        )
        XCTAssertThrowsError(
            try PublishedSplatReceiptStore.decode(escapedQuoteDuplicate)
        ) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .malformed)
        }

        let separateObjects = Data(
            #"{"left":{"shared":1},"right":{"\u0073hared":2},"schemaVersion":2}"#.utf8
        )
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(separateObjects)) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptStoreError,
                .unsupportedSchemaVersion(2)
            )
        }
    }

    func testDuplicateScannerAcceptsEveryJSONValueForm() throws {
        let document = Data(
            #"""
            {
              "payload": [
                null, true, false, 0, -1, 1.25, 6.02e23, "raw-é",
                "quote:\" slash:\/ backslash:\\ controls:\b\f\n\r\t unicode:\u00e9 pair:\uD83D\uDE00",
                {"value": null}
              ],
              "schemaVersion": 2
            }
            """#.utf8
        )

        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(document)) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptStoreError,
                .unsupportedSchemaVersion(2)
            )
        }
    }

    func testDuplicateScannerEnforcesExactContainerDepthBound() throws {
        func nestedDocument(arrayCount: Int) -> Data {
            Data((
                #"{"payload":"#
                    + String(repeating: "[", count: arrayCount)
                    + "null"
                    + String(repeating: "]", count: arrayCount)
                    + #", "schemaVersion":2}"#
            ).utf8)
        }

        XCTAssertThrowsError(
            try PublishedSplatReceiptStore.decode(nestedDocument(arrayCount: 63))
        ) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptStoreError,
                .unsupportedSchemaVersion(2)
            )
        }
        XCTAssertThrowsError(
            try PublishedSplatReceiptStore.decode(nestedDocument(arrayCount: 64))
        ) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .malformed)
        }
    }

    func testDuplicateScannerRejectsMalformedJSONTokens() throws {
        let malformedDocuments: [Data] = [
            Data(#"{"schemaVersion":2,"value":01}"#.utf8),
            Data(#"{"schemaVersion":2,"value":1.}"#.utf8),
            Data(#"{"schemaVersion":2,"value":1e+}"#.utf8),
            Data(#"{"schemaVersion":2,"value":"\uD800"}"#.utf8),
            Data(#"{"schemaVersion":2,"value":"\uDC00"}"#.utf8),
            Data(#"{"schemaVersion":2,"value":"\x20"}"#.utf8),
            Data(#"{"schemaVersion":2,"value":true,}"#.utf8),
            Data(#"{"schemaVersion":2 "value":null}"#.utf8),
            Data(#"{"schemaVersion":2} trailing"#.utf8),
            Data([0x7B, 0x22, 0x73, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D]),
        ]

        for document in malformedDocuments {
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(document)) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .malformed)
            }
        }
    }

    func testDecoderRejectsMissingRequiredKeys() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let cases: [([JSONPathComponent], String)] = [
            ([], "projectID"),
            ([.key("outputEvidence")], "gaussianCount"),
            ([.key("lineage")], "trainingInputDigest"),
            ([.key("presentation")], "resolvedRunPlan"),
            ([.key("presentation"), .key("requestedRunOptions")], "capturePath"),
            ([.key("presentation"), .key("resolvedRunPlan")], "memoryTier"),
            (
                [.key("presentation"), .key("resolvedRunPlan"), .key("geometryWorkerBudget")],
                "featureExtractionWorkers"
            ),
            ([.key("presentation"), .key("stageTimings"), .index(0)], "stage"),
            ([.key("presentation"), .key("autoTunerSnapshot")], "keyframeBudget"),
        ]

        for (path, key) in cases {
            let tampered = try removingKey(key, from: canonical, objectPath: path)
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(tampered)) {
                guard case .missingKeys = $0 as? PublishedSplatReceiptStoreError else {
                    return XCTFail("Expected missingKeys for \(key), got \($0)")
                }
            }
        }
    }

    func testOneMiBBoundaryIsInclusiveAndOneByteMoreIsRejectedBeforeDecode() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        XCTAssertLessThan(canonical.count, PublishedSplatReceiptStore.maximumBytes)
        let exact = canonical + Data(
            repeating: UInt8(ascii: " "),
            count: PublishedSplatReceiptStore.maximumBytes - canonical.count
        )

        XCTAssertEqual(try PublishedSplatReceiptStore.decode(exact), makeReceipt())
        XCTAssertThrowsError(
            try PublishedSplatReceiptStore.decode(exact + Data([UInt8(ascii: " ")]))
        ) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .tooLarge)
        }

        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writePrivate(exact, to: fixture.paths.outputSplatReceiptURL)
        XCTAssertEqual(
            try PublishedSplatReceiptStore.load(projectPaths: fixture.paths),
            makeReceipt()
        )
    }

    func testMalformedAndFutureSchemasFailClosedAndLoadNeverModifiesFutureBytes() throws {
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(Data("{}".utf8)))
        XCTAssertThrowsError(
            try PublishedSplatReceiptStore.decode(Data(#"{"schemaVersion":"1"}"#.utf8))
        )
        let future = Data(#"{"futurePayload":true,"schemaVersion":2}"#.utf8)
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(future)) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptStoreError,
                .unsupportedSchemaVersion(2)
            )
        }

        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writePrivate(future, to: fixture.paths.outputSplatReceiptURL)

        XCTAssertThrowsError(
            try PublishedSplatReceiptStore.load(projectPaths: fixture.paths)
        ) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptStoreError,
                .unsupportedSchemaVersion(2)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatReceiptURL), future)
    }

    func testDecoderRejectsInvalidHashesCountsFormatsBoundsAndNumbers() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let mutations: [([JSONPathComponent], Any)] = [
            ([.key("outputPath")], "Output/other.ply"),
            ([.key("outputEvidence"), .key("byteCount")], 0),
            ([.key("outputEvidence"), .key("gaussianCount")], 0),
            ([.key("outputEvidence"), .key("format")], "unknown"),
            ([.key("outputEvidence"), .key("sha256")], String(repeating: "A", count: 64)),
            ([.key("outputEvidence"), .key("sceneBounds"), .key("radius")], 0),
            ([.key("lineage"), .key("trainingManifestSHA256")], String(repeating: "g", count: 64)),
            ([.key("lineage"), .key("trainingInputDigest")], "abc"),
            ([.key("presentation"), .key("trainingDurationSeconds")], -1),
            ([.key("presentation"), .key("createToViewerReadySeconds")], -1),
            ([.key("presentation"), .key("stageTimings"), .index(0), .key("durationSeconds")], -1),
        ]

        for (path, value) in mutations {
            let tampered = try replacingJSONValue(in: canonical, at: path, with: value)
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(tampered), "Path: \(path)") {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }

        let text = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        let nonfinite = text.replacingOccurrences(
            of: #""trainingDurationSeconds":12.5"#,
            with: #""trainingDurationSeconds":1e999"#
        )
        XCTAssertNotEqual(text, nonfinite)
        XCTAssertThrowsError(
            try PublishedSplatReceiptStore.decode(try XCTUnwrap(nonfinite.data(using: .utf8)))
        )

        for (original, replacement) in [
            (#""radius":8.5"#, #""radius":1e999"#),
            (#""medianPixelResidual":0.42"#, #""medianPixelResidual":1e999"#),
            (#""durationSeconds":3.25"#, #""durationSeconds":1e999"#),
        ] {
            let tampered = text.replacingOccurrences(of: original, with: replacement)
            XCTAssertNotEqual(text, tampered)
            XCTAssertThrowsError(
                try PublishedSplatReceiptStore.decode(
                    try XCTUnwrap(tampered.data(using: .utf8))
                )
            )
        }

        for format in ["ascii", "binary_little_endian", "binary_big_endian"] {
            let tampered = try replacingJSONValue(
                in: canonical,
                at: [.key("outputEvidence"), .key("format")],
                with: format
            )
            XCTAssertNoThrow(try PublishedSplatReceiptStore.decode(tampered))
        }
    }

    func testDecoderRejectsDuplicateTimingsAndInconsistentPresentation() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        var root = try jsonObject(canonical)
        var presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
        var timings = try XCTUnwrap(presentation["stageTimings"] as? [Any])
        timings.append(try XCTUnwrap(timings.first))
        presentation["stageTimings"] = timings
        root["presentation"] = presentation
        let duplicateTimings = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(duplicateTimings)) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        let mutations: [([JSONPathComponent], Any)] = [
            ([.key("presentation"), .key("reconstruction"), .key("registeredViewCount")], 25),
            ([.key("presentation"), .key("reconstruction"), .key("p90PixelResidual")], 0.1),
            (
                [
                    .key("presentation"), .key("reconstruction"),
                    .key("secondLargestModelRegisteredViewCount"),
                ],
                21
            ),
            (
                [
                    .key("presentation"), .key("reconstruction"),
                    .key("secondLargestModelRegisteredViewCount"),
                ],
                19
            ),
            ([.key("presentation"), .key("orientation"), .key("allowsViewOnlyUprightFlip")], true),
            ([.key("presentation"), .key("orientation"), .key("openingDirection"), .key("z")], 2),
            ([.key("presentation"), .key("completedIteration")], 0),
            ([.key("presentation"), .key("completedIteration")], 30_001),
            ([.key("presentation"), .key("autoTunerSnapshot"), .key("memoryTier")], "forged"),
            (
                [
                    .key("presentation"), .key("autoTunerSnapshot"),
                    .key("geometryWorkerBudget"), .key("featureExtractionWorkers"),
                ],
                11
            ),
        ]
        for (path, value) in mutations {
            let tampered = try replacingJSONValue(in: canonical, at: path, with: value)
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(tampered), "Path: \(path)") {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }
    }

    func testReconstructionMustSatisfyPersistedGeometryAcceptancePolicy() throws {
        let invalidReconstructions: [(name: String, value: PublishedReconstructionSummary)] = [
            (
                "median residual above 1.5",
                makeReconstruction(medianPixelResidual: 1.501, p90PixelResidual: 2)
            ),
            (
                "p90 residual above 3.0",
                makeReconstruction(p90PixelResidual: 3.001)
            ),
            (
                "untrusted residual provenance",
                makeReconstruction(residualProvenance: "forged-residuals-v1")
            ),
            (
                "partial result below eight registered views",
                makeReconstruction(
                    registeredViewCount: 7,
                    totalViewCount: 20,
                    usedPartialCoverageAcceptance: true,
                    secondLargestModelRegisteredViewCount: 0
                )
            ),
            (
                "strict result below nested dominant coverage",
                makeReconstruction(
                    registeredViewCount: 80,
                    totalViewCount: 100,
                    usedPartialCoverageAcceptance: false,
                    secondLargestModelRegisteredViewCount: 0
                )
            ),
            (
                "strict result that cannot exclude a dominant component",
                makeReconstruction(
                    registeredViewCount: 5,
                    totalViewCount: 6,
                    usedPartialCoverageAcceptance: false,
                    secondLargestModelRegisteredViewCount: 0
                )
            ),
            (
                "partial flag with complete registration",
                makeReconstruction(
                    registeredViewCount: 20,
                    totalViewCount: 20,
                    usedPartialCoverageAcceptance: true,
                    secondLargestModelRegisteredViewCount: 2
                )
            ),
        ]

        for (name, reconstruction) in invalidReconstructions {
            XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
                reconstruction: reconstruction
            )), name) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }
    }

    func testReconstructionPreservesStrictDominantAndPartialCoverageBoundaries() throws {
        let strictDominantBoundary = makeReconstruction(
            registeredViewCount: 81,
            totalViewCount: 100,
            usedPartialCoverageAcceptance: false,
            secondLargestModelRegisteredViewCount: 0
        )
        let partialBoundary = makeReconstruction(
            registeredViewCount: PairGraphConnectivityPolicy.minimumViableDominantViewCount,
            totalViewCount: 20,
            medianPixelResidual: 1.5,
            p90PixelResidual: 3.0,
            usedPartialCoverageAcceptance: true,
            secondLargestModelRegisteredViewCount: 0
        )

        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            reconstruction: strictDominantBoundary
        )))
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            reconstruction: partialBoundary
        )))
    }

    func testRequestedResolvedConsistencyAcceptsEverySourceCompatibleShape() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let mediaOptions = RequestedRunOptions()
        let mediaInputs: [InputSpec] = [
            .photos(folder: "Inputs/photos"),
            .video(files: ["Inputs/one.mov"]),
            .video(files: ["Inputs/one.mov", "Inputs/two.mov"]),
            .mixed(videos: ["Inputs/one.mov"], photosFolder: "Inputs/photos"),
        ]
        for input in mediaInputs {
            let plan = RunPlanResolver.resolve(
                requestedOptions: mediaOptions,
                input: input,
                hardware: hardware,
                developmentOverrides: .none
            )
            XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
                requestedRunOptions: mediaOptions,
                resolvedRunPlan: plan
            )))
        }

        let datasetInput = InputSpec.dataset(
            kind: .nerfstudio,
            imagesFolder: "Inputs/Dataset/images"
        )
        let datasetOptions = RequestedRunOptions(
            capturePath: .largeArea,
            detailProfile: .balanced,
            cameraGrouping: .automatic,
            lensProjection: .perspective,
            inputOrdering: .continuous,
            resourcePolicy: .maximumPerformance,
            photoSelection: .automatic
        )
        let datasetPlan = RunPlanResolver.resolve(
            requestedOptions: datasetOptions,
            input: datasetInput,
            hardware: hardware,
            developmentOverrides: .none,
            datasetImport: RunPlanResolver.DatasetImportContext(
                route: .adoptDirect,
                imageCount: 20,
                maximumImagePixelDimension: 2_048
            )
        )
        XCTAssertEqual(datasetPlan.capturePath, .automatic)
        XCTAssertEqual(datasetPlan.inputOrdering, .unordered)
        XCTAssertEqual(datasetPlan.photoSelection, .useAllValidPhotos)
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: datasetOptions,
            resolvedRunPlan: datasetPlan
        )))
    }

    func testExplicitRequestedOptionsMustMatchTheResolvedMediaPlan() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let input = InputSpec.photos(folder: "Inputs/photos")
        var options = defaultRequestedRunOptions()
        options.inputOrdering = .unordered
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )))

        var mismatches: [ResolvedRunPlan] = []
        var capturePath = plan
        capturePath.capturePath = .automatic
        mismatches.append(capturePath)
        var inputOrdering = plan
        inputOrdering.inputOrdering = .continuous
        mismatches.append(inputOrdering)
        var photoSelection = plan
        photoSelection.photoSelection = .automatic
        mismatches.append(photoSelection)
        var cameraGrouping = plan
        cameraGrouping.cameraGrouping = .mixedCamerasOrLenses
        cameraGrouping.cameraInitializationRecipe = ColmapCameraInitializationRecipe.resolve(
            lensProjection: cameraGrouping.lensProjection,
            cameraGrouping: cameraGrouping.cameraGrouping
        )
        mismatches.append(cameraGrouping)

        for mismatch in mismatches {
            XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
                requestedRunOptions: options,
                resolvedRunPlan: mismatch
            ))) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }
    }

    func testImportedDatasetPlanRetainsProvableCanonicalOverrides() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let input = InputSpec.dataset(
            kind: .nerfstudio,
            imagesFolder: "Inputs/Dataset/images"
        )
        let options = RequestedRunOptions(
            capturePath: .largeArea,
            detailProfile: .balanced,
            cameraGrouping: .automatic,
            lensProjection: .perspective,
            inputOrdering: .continuous,
            resourcePolicy: .maximumPerformance,
            photoSelection: .automatic
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: hardware,
            developmentOverrides: .none,
            datasetImport: RunPlanResolver.DatasetImportContext(
                route: .adoptDirect,
                imageCount: 20,
                maximumImagePixelDimension: 2_048
            )
        )

        var mismatches: [ResolvedRunPlan] = []
        var capturePath = plan
        capturePath.capturePath = .largeArea
        mismatches.append(capturePath)
        var inputOrdering = plan
        inputOrdering.inputOrdering = .continuous
        mismatches.append(inputOrdering)
        var photoSelection = plan
        photoSelection.photoSelection = .automatic
        mismatches.append(photoSelection)
        var analysisFrameRate = plan
        analysisFrameRate.analysisFrameRate = 3
        mismatches.append(analysisFrameRate)

        for mismatch in mismatches {
            XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
                requestedRunOptions: options,
                resolvedRunPlan: mismatch
            ))) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }
    }

    func testAnalysisFrameRateRequiresExactFrozenV1ResolverValue() throws {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let input = InputSpec.video(files: ["Inputs/capture.mov"])
        let cases: [(DetailProfile, CapturePath, Int)] = [
            (.fast, .orbit, 2),
            (.balanced, .orbit, 3),
            (.balanced, .largeArea, 4),
            (.highDetail, .orbit, 3),
            (.highDetail, .largeArea, 4),
        ]

        for (detailProfile, capturePath, expectedFrameRate) in cases {
            let options = RequestedRunOptions(
                capturePath: capturePath,
                detailProfile: detailProfile,
                cameraGrouping: .automatic,
                lensProjection: .perspective,
                inputOrdering: .automatic,
                resourcePolicy: .maximumPerformance,
                photoSelection: .useAllValidPhotos
            )
            let plan = RunPlanResolver.resolve(
                requestedOptions: options,
                input: input,
                hardware: hardware,
                developmentOverrides: .none
            )
            XCTAssertEqual(plan.analysisFrameRate, expectedFrameRate)
            XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
                requestedRunOptions: options,
                resolvedRunPlan: plan
            )))

            var impossiblePlan = plan
            impossiblePlan.analysisFrameRate = expectedFrameRate + 1
            XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
                requestedRunOptions: options,
                resolvedRunPlan: impossiblePlan
            ))) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }
    }

    func testRequestedResolvedConsistencyRejectsImpossiblePairs() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let mutations: [([JSONPathComponent], Any)] = [
            ([.key("presentation"), .key("resolvedRunPlan"), .key("capturePath")], "automatic"),
            ([.key("presentation"), .key("resolvedRunPlan"), .key("inputOrdering")], "continuous"),
            ([.key("presentation"), .key("resolvedRunPlan"), .key("photoSelection")], "automatic"),
            ([.key("presentation"), .key("requestedRunOptions"), .key("lensProjection")], "automatic"),
        ]

        for (path, value) in mutations {
            let tampered = try replacingJSONValue(in: canonical, at: path, with: value)
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(tampered), "Path: \(path)") {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }
    }

    func testConserveMemoryReceiptRequiresConstrainedTier() throws {
        let input = InputSpec.photos(folder: "Inputs/photos")
        var options = defaultRequestedRunOptions()
        options.resourcePolicy = .conserveMemory
        var plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        XCTAssertEqual(plan.memoryTier, "constrained")
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )))

        plan.memoryTier = "performance"
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: options,
            resolvedRunPlan: plan
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }
    }

    func testReceiptRequiresCurrentOrSanctionedLegacyTrainerBudget() throws {
        let input = InputSpec.photos(folder: "Inputs/photos")
        let cases: [(
            detail: DetailProfile,
            resourcePolicy: ResourcePolicy,
            memoryGB: Double,
            tier: String,
            iterations: Int,
            plateau: Int
        )] = [
            (.fast, .conserveMemory, 48, "constrained", 3_000, 400),
            (.fast, .automatic, 24, "standard", 3_000, 400),
            (.fast, .maximumPerformance, 48, "performance", 3_000, 400),
            (.balanced, .conserveMemory, 48, "constrained", 12_000, 1_200),
            (.balanced, .automatic, 24, "standard", 20_000, 1_600),
            (.balanced, .maximumPerformance, 48, "performance", 30_000, 2_000),
            (.highDetail, .conserveMemory, 48, "constrained", 20_000, 1_600),
            (.highDetail, .automatic, 24, "standard", 30_000, 2_000),
            (.highDetail, .maximumPerformance, 48, "performance", 40_000, 2_500),
        ]

        for entry in cases {
            var options = defaultRequestedRunOptions()
            options.detailProfile = entry.detail
            options.resourcePolicy = entry.resourcePolicy
            let plan = RunPlanResolver.resolve(
                requestedOptions: options,
                input: input,
                hardware: HardwareProfile(
                    memoryGB: entry.memoryGB,
                    cpuCount: 16,
                    gpuWorkingSetGB: entry.memoryGB * 0.75
                ),
                developmentOverrides: .none
            )

            XCTAssertEqual(plan.memoryTier, entry.tier)
            XCTAssertEqual(plan.trainerIterationLimit, entry.iterations)
            XCTAssertEqual(plan.plateauWindow, entry.plateau)
            XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
                requestedRunOptions: options,
                resolvedRunPlan: plan
            )))
        }

        var balancedOptions = defaultRequestedRunOptions()
        balancedOptions.detailProfile = .balanced
        let balancedPerformancePlan = RunPlanResolver.resolve(
            requestedOptions: balancedOptions,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        XCTAssertEqual(balancedPerformancePlan.trainerIterationLimit, 30_000)

        var legacyBalancedPlan = balancedPerformancePlan
        legacyBalancedPlan.trainerIterationLimit = 7_000
        legacyBalancedPlan.plateauWindow = 800
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: balancedOptions,
            resolvedRunPlan: legacyBalancedPlan
        )))

        var mixedLegacyBudget = legacyBalancedPlan
        mixedLegacyBudget.plateauWindow = 1_600
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: balancedOptions,
            resolvedRunPlan: mixedLegacyBudget
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        var wrongIterationLimit = balancedPerformancePlan
        wrongIterationLimit.trainerIterationLimit = 20_000
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: balancedOptions,
            resolvedRunPlan: wrongIterationLimit
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        var wrongPlateauWindow = balancedPerformancePlan
        wrongPlateauWindow.plateauWindow = 1_600
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: balancedOptions,
            resolvedRunPlan: wrongPlateauWindow
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        var highDetailOptions = defaultRequestedRunOptions()
        highDetailOptions.detailProfile = .highDetail
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: highDetailOptions,
            resolvedRunPlan: balancedPerformancePlan
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        var legacyHighDetailPlan = RunPlanResolver.resolve(
            requestedOptions: highDetailOptions,
            input: input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        legacyHighDetailPlan.trainerIterationLimit = 15_000
        legacyHighDetailPlan.plateauWindow = 1_500
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            requestedRunOptions: highDetailOptions,
            resolvedRunPlan: legacyHighDetailPlan
        )))
    }

    func testReceiptRequiresExactFrozenPairingPolicyAndTuple() throws {
        let canonical = makeReceipt()
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(canonical))

        var impossiblePolicy = canonical.presentation.resolvedRunPlan
        impossiblePolicy.pairingPolicy = .segmentedMixed
        impossiblePolicy.temporalPairing = .linear
        impossiblePolicy.temporalOffsets = Array(1...6)
        XCTAssertNoThrow(try impossiblePolicy.validate())
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            resolvedRunPlan: impossiblePolicy
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        var impossibleTuple = canonical.presentation.resolvedRunPlan
        impossibleTuple.retrievalNeighborCount = 7
        XCTAssertNoThrow(try impossibleTuple.validate())
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            resolvedRunPlan: impossibleTuple
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }
    }

    func testCreateToViewerTimingCoversTrainingAndAggregateStageDurations() throws {
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            createToViewerReadySeconds: 12.0
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            createToViewerReadySeconds: 98.5
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt(
            createToViewerReadySeconds: 98.75
        )))
    }

    func testTrainingDurationCannotExceedTrainStageTiming() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let impossible = try replacingJSONValue(
            in: canonical,
            at: [.key("presentation"), .key("trainingDurationSeconds")],
            with: 96.0
        )
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(impossible)) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        let exact = try replacingJSONValue(
            in: canonical,
            at: [.key("presentation"), .key("trainingDurationSeconds")],
            with: 95.5
        )
        XCTAssertNoThrow(try PublishedSplatReceiptStore.decode(exact))
    }

    func testStageTimingChronologySurvivesWireDateULPBoundary() throws {
        let startedAt = Date(
            timeIntervalSinceReferenceDate: 807_000_000.002_006_05
        )
        let publishedAt = Date(
            timeIntervalSinceReferenceDate: 807_000_000.152_844_07
        )
        let duration = publishedAt.timeIntervalSince(startedAt)
        let receipt = makeReceipt(
            publishedAt: publishedAt,
            stageTimings: [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: startedAt,
                    durationSeconds: duration
                ),
            ],
            trainingDurationSeconds: 0.1,
            createToViewerReadySeconds: nil
        )

        let encoded = try PublishedSplatReceiptStore.encode(receipt)
        XCTAssertNoThrow(try PublishedSplatReceiptStore.decode(encoded))
    }

    func testReceiptRequiresExactlyOneTrainSplatTiming() throws {
        XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(makeReceipt(
            stageTimings: [
                StageTimingRecord(
                    stage: .importInput,
                    startedAt: Date(timeIntervalSince1970: 1_767_225_000),
                    durationSeconds: 3.25
                ),
            ]
        ))) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(makeReceipt()))
    }

    func testReconstructionProjectionPreservesOverlappingSecondModelCount() throws {
        var geometry = makeGeometryArtifact()
        geometry.residualProvenance = "colmap-text-tracks-v1"
        geometry.registeredViewCount = 9
        geometry.totalViewCount = 9
        geometry.mapping.modelCount = 2
        geometry.mapping.largestModelRegisteredViewCount = 9
        geometry.mapping.secondLargestModelRegisteredViewCount = 8
        geometry.mapping.unionRegisteredViewCount = 9

        let reconstruction = PublishedReconstructionSummary(geometry: geometry)
        XCTAssertEqual(reconstruction.secondLargestModelRegisteredViewCount, 8)

        let encoded = try PublishedSplatReceiptStore.encode(makeReceipt(
            reconstruction: reconstruction
        ))
        let root = try jsonObject(encoded)
        let presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
        let document = try XCTUnwrap(presentation["reconstruction"] as? [String: Any])
        XCTAssertEqual(document["secondLargestModelRegisteredViewCount"] as? Int, 8)
        XCTAssertNil(document["separateGroupViewCount"])
    }

    func testFactoryBindsExactReboundManifestAndResultEraPresentation() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("ReceiptFactory.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        var plan = makePlan()
        plan.trainerIterationLimit = 30_000
        let requested = defaultRequestedRunOptions()
        let publishedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let metadata = ProjectMetadata(
            id: UUID(uuidString: "99999999-8888-4777-8666-555555555555")!,
            createdAt: Date(timeIntervalSince1970: 1_767_224_000),
            title: "Live title is not copied",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: requested,
            resolvedRunPlan: plan,
            stageTimings: [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: Date(timeIntervalSince1970: 1_767_225_100),
                    durationSeconds: 95.5
                ),
            ],
            createToViewerReadySeconds: nil,
            notes: "Live notes are not copied"
        )
        var geometry = makeGeometryArtifact()
        geometry.residualProvenance = "colmap-text-tracks-v1"
        geometry.selectedFramesDigest = String(repeating: "e", count: 64)
        let geometryManifestDigest = try writeGeometryManifest(geometry, paths: paths)
        let evidence = makeReceipt().outputEvidence
        var training = makeTrainingArtifact()
        let sparseGeometryDigest = training.geometryDigest
        training.detailProfile = requested.detailProfile
        training.iterationLimit = plan.trainerIterationLimit
        training.plateauWindow = plan.plateauWindow
        training.cameraOrderSeed = plan.runSeed
        training.completedIteration = plan.trainerIterationLimit
        training.elapsedSeconds = 95.5
        training.memoryBudgetBytes = min(
            training.memoryBudgetBytes,
            plan.trainerMemoryBudgetBytes
        )
        training.resourceAdmission = makeTestTrainingResourceAdmission(
            resourcePolicy: requested.resourcePolicy
        )
        training.outputPath = PublishedSplatReceipt.canonicalOutputPath
        training.outputSHA256 = evidence.sha256
        training.outputBytes = Int64(evidence.byteCount)
        training.gaussianCount = evidence.vertexCount
        training.sceneBounds = evidence.sceneBounds
        training.datasetDerivation = makeMsplatDatasetDerivation(
            inputDigest: training.inputDigest,
            geometryDigest: sparseGeometryDigest,
            registeredImageNames: geometry.orderedImageNames,
            sourceGeometryManifestSHA256: geometryManifestDigest,
            sourceSelectedFramesDigest: geometry.selectedFramesDigest,
            maximumImageDimension: plan.maximumImageDimension
        )
        let manifest = try TrainingArtifactStore.encodedManifestData(
            training,
            projectPaths: paths
        )
        let publicationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

        let receipt = try PublishedSplatReceiptFactory.make(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            geometryManifestDigest: geometryManifestDigest,
            reboundTraining: training,
            reboundTrainingManifestData: manifest,
            outputEvidence: evidence,
            projectPaths: paths,
            publicationID: publicationID,
            publishedAt: publishedAt
        )

        XCTAssertEqual(receipt.publicationID, publicationID)
        XCTAssertEqual(receipt.projectID, metadata.id)
        XCTAssertEqual(receipt.lineage.trainingManifestSHA256, SHA256.hash(data: manifest)
            .map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(
            receipt.lineage.trainingGeometryDigest,
            sparseGeometryDigest
        )
        XCTAssertEqual(receipt.presentation.requestedRunOptions, requested)
        XCTAssertEqual(receipt.presentation.resolvedRunPlan, plan)
        XCTAssertEqual(receipt.presentation.reconstruction, PublishedReconstructionSummary(
            geometry: geometry
        ))
        XCTAssertEqual(receipt.presentation.orientation, PublishedOrientationSummary(
            geometry: geometry
        ))
        XCTAssertNil(receipt.presentation.createToViewerReadySeconds)
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(receipt))

        var recoveredMetadata = metadata
        recoveredMetadata.stageTimings = []
        let recoveredReceipt = try PublishedSplatReceiptFactory.make(
            metadata: recoveredMetadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            geometryManifestDigest: geometryManifestDigest,
            reboundTraining: training,
            reboundTrainingManifestData: manifest,
            outputEvidence: evidence,
            projectPaths: paths,
            publicationID: publicationID,
            publishedAt: publishedAt
        )
        let recoveredTrainingTiming = try XCTUnwrap(
            recoveredReceipt.presentation.stageTimings.first {
                $0.stage == .trainSplat
            }
        )
        XCTAssertEqual(recoveredTrainingTiming.durationSeconds, 95.5)
        XCTAssertEqual(
            recoveredTrainingTiming.startedAt.addingTimeInterval(
                recoveredTrainingTiming.durationSeconds
            ),
            publishedAt
        )
        XCTAssertNoThrow(try PublishedSplatReceiptStore.encode(recoveredReceipt))

        var drifted = manifest
        drifted.append(0x0A)
        XCTAssertThrowsError(try PublishedSplatReceiptFactory.make(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            geometryManifestDigest: geometryManifestDigest,
            reboundTraining: training,
            reboundTrainingManifestData: drifted,
            outputEvidence: evidence,
            projectPaths: paths,
            publicationID: publicationID,
            publishedAt: publishedAt
        )) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptFactoryError,
                .inconsistentArtifacts
            )
        }

        var presentationDrift = geometry
        presentationDrift.pointCount += 1
        presentationDrift.medianPixelResidual += 0.25
        presentationDrift.canonicalOrientation = .unresolved(
            openingViewDirection: CanonicalDirection(x: 1, y: 0, z: 0)
        )
        XCTAssertEqual(
            presentationDrift.selectedFramesDigest,
            geometry.selectedFramesDigest
        )
        XCTAssertEqual(presentationDrift.orderedImageNames, geometry.orderedImageNames)
        let driftedGeometryManifestDigest = try writeGeometryManifest(
            presentationDrift,
            paths: paths
        )
        XCTAssertNotEqual(driftedGeometryManifestDigest, geometryManifestDigest)
        XCTAssertThrowsError(try PublishedSplatReceiptFactory.make(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: presentationDrift,
            geometryManifestDigest: driftedGeometryManifestDigest,
            reboundTraining: training,
            reboundTrainingManifestData: manifest,
            outputEvidence: evidence,
            projectPaths: paths,
            publicationID: publicationID,
            publishedAt: publishedAt
        )) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptFactoryError,
                .inconsistentArtifacts
            )
        }

        XCTAssertThrowsError(try PublishedSplatReceiptFactory.make(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            geometryManifestDigest: geometryManifestDigest.uppercased(),
            reboundTraining: training,
            reboundTrainingManifestData: manifest,
            outputEvidence: evidence,
            projectPaths: paths,
            publicationID: publicationID,
            publishedAt: publishedAt
        )) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptFactoryError,
                .inconsistentArtifacts
            )
        }

        var sparseLineageDrift = training
        sparseLineageDrift.geometryDigest = String(repeating: "9", count: 64)
        XCTAssertThrowsError(try PublishedSplatReceiptFactory.make(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            geometryManifestDigest: geometryManifestDigest,
            reboundTraining: sparseLineageDrift,
            reboundTrainingManifestData: manifest,
            outputEvidence: evidence,
            projectPaths: paths,
            publicationID: publicationID,
            publishedAt: publishedAt
        )) {
            XCTAssertEqual(
                $0 as? PublishedSplatReceiptFactoryError,
                .inconsistentArtifacts
            )
        }
    }

    func testImmutableBindingIncludesPublicationGenerationIdentity() {
        let existing = makeReceipt()
        let otherPublication = makeReceipt(
            publicationID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        )
        let otherPublicationTime = makeReceipt(
            publishedAt: existing.publishedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(PublishedSplatReceiptFactory.isBound(existing, to: existing))
        XCTAssertFalse(PublishedSplatReceiptFactory.isBound(existing, to: otherPublication))
        XCTAssertFalse(PublishedSplatReceiptFactory.isBound(
            existing,
            to: otherPublicationTime
        ))
    }

    func testPublisherReusesReceiptCommittedBeforeTrainingManifestFailure() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("ReceiptRecovery.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        var plan = makePlan()
        plan.trainerIterationLimit = 30_000
        let requested = defaultRequestedRunOptions()
        var metadata = ProjectMetadata(
            id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-BBBBBBBBBBBB")!,
            title: "Receipt recovery",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: requested,
            resolvedRunPlan: plan,
            stageTimings: [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: Date(timeIntervalSince1970: 1_767_224_800),
                    durationSeconds: 812.5
                ),
                StageTimingRecord(
                    stage: .exportSplat,
                    startedAt: Date(timeIntervalSince1970: 1_767_225_700),
                    durationSeconds: 0.75
                ),
            ]
        )
        var geometry = makeGeometryArtifact()
        geometry.residualProvenance = "colmap-text-tracks-v1"
        geometry.selectedFramesDigest = String(repeating: "e", count: 64)
        let geometryManifestSHA256 = try writeGeometryManifest(
            geometry,
            paths: paths
        )
        try TestFileBuilder.writeMinimalPly(at: paths.msplatOutputURL, vertexCount: 7)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.msplatOutputURL
        )
        var training = makeTrainingArtifact(outputPath: "Training/msplat/splat.ply")
        training.detailProfile = requested.detailProfile
        training.iterationLimit = plan.trainerIterationLimit
        training.plateauWindow = plan.plateauWindow
        training.cameraOrderSeed = plan.runSeed
        training.completedIteration = plan.trainerIterationLimit
        training.memoryBudgetBytes = min(
            training.memoryBudgetBytes,
            plan.trainerMemoryBudgetBytes
        )
        training.resourceAdmission = makeTestTrainingResourceAdmission(
            resourcePolicy: requested.resourcePolicy
        )
        training.outputSHA256 = evidence.sha256
        training.outputBytes = Int64(evidence.byteCount)
        training.gaussianCount = evidence.vertexCount
        training.sceneBounds = evidence.sceneBounds
        training.datasetDerivation = makeMsplatDatasetDerivation(
            inputDigest: training.inputDigest,
            geometryDigest: training.geometryDigest,
            registeredImageNames: geometry.orderedImageNames,
            sourceGeometryManifestSHA256: geometryManifestSHA256,
            sourceSelectedFramesDigest: geometry.selectedFramesDigest,
            maximumImageDimension: plan.maximumImageDimension
        )
        try TrainingArtifactStore.persist(training, paths: paths)

        let publicationID = UUID(uuidString: "CCCCCCCC-4444-4555-8666-DDDDDDDDDDDD")!
        metadata.pendingPublicationID = publicationID
        let checkpoints = ReceiptPublicationCheckpointRecorder()
        var pairOperations = PublishedResultPairOperations.system()
        pairOperations.makeUUID = {
            UUID(uuidString: "EEEEEEEE-7777-4888-8999-FFFFFFFFFFFF")!
        }
        pairOperations.didReachCheckpoint = { checkpoints.append($0) }

        XCTAssertThrowsError(try PublishedResultPublisher.publishCompletedTraining(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            paths: paths,
            publicationID: publicationID,
            publishedAt: Date(timeIntervalSince1970: 1_767_225_800),
            pairOperations: pairOperations,
            persistPreparedManifest: { _, _, _, _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
        ))

        let committed: ValidatedPublishedResult
        switch try PublishedResultPairStore.resolve(projectPaths: paths) {
        case .available(let value):
            committed = value
        default:
            return XCTFail("The receipt-last commit must remain authoritative")
        }
        XCTAssertEqual(committed.receipt.publicationID, publicationID)
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ).outputPath,
            "Training/msplat/splat.ply"
        )
        let transactionCount = checkpoints.values.filter {
            $0 == .transactionCreated
        }.count

        metadata.stageTimings = [
            StageTimingRecord(
                stage: .exportSplat,
                startedAt: Date(timeIntervalSince1970: 1_767_225_900),
                durationSeconds: 0.5
            ),
        ]

        let recovered = try PublishedResultPublisher.publishCompletedTraining(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            paths: paths,
            publicationID: publicationID,
            publishedAt: Date(),
            pairOperations: pairOperations
        )
        XCTAssertEqual(recovered.receipt.publicationID, publicationID)
        XCTAssertEqual(
            recovered.receipt.presentation.stageTimings,
            committed.receipt.presentation.stageTimings,
            "Recovery must retain the timing history committed by the receipt."
        )
        XCTAssertEqual(
            checkpoints.values.filter { $0 == .transactionCreated }.count,
            transactionCount,
            "Recovery must not replace an already-committed publication"
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ).outputPath,
            PublishedSplatReceipt.canonicalOutputPath
        )

        metadata.stageTimings = committed.receipt.presentation.stageTimings

        let replacementPublicationID = UUID(
            uuidString: "12345678-9ABC-4DEF-8123-456789ABCDEF"
        )!
        var replacementMetadata = metadata
        replacementMetadata.pendingPublicationID = replacementPublicationID
        try FileManager.default.removeItem(at: paths.msplatOutputURL)
        try FileManager.default.copyItem(
            at: paths.outputSplatURL,
            to: paths.msplatOutputURL
        )
        var replacementTraining = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        replacementTraining.outputPath = "Training/msplat/splat.ply"
        try TrainingArtifactStore.persist(replacementTraining, paths: paths)

        let replacement = try PublishedResultPublisher.publishCompletedTraining(
            metadata: replacementMetadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            paths: paths,
            publicationID: replacementPublicationID,
            publishedAt: Date(timeIntervalSince1970: 1_767_225_900),
            pairOperations: pairOperations
        )
        XCTAssertEqual(
            replacement.receipt.publicationID,
            replacementPublicationID,
            "Byte-identical retraining must create the new attempt's publication."
        )
        XCTAssertEqual(
            checkpoints.values.filter { $0 == .transactionCreated }.count,
            transactionCount + 1
        )

        let cancelledPublicationID = UUID(
            uuidString: "87654321-CBA9-4FED-8876-543210FEDCBA"
        )!
        var cancelledMetadata = metadata
        cancelledMetadata.pendingPublicationID = cancelledPublicationID
        try FileManager.default.removeItem(at: paths.msplatOutputURL)
        try FileManager.default.copyItem(
            at: paths.outputSplatURL,
            to: paths.msplatOutputURL
        )
        var cancelledTraining = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        cancelledTraining.outputPath = "Training/msplat/splat.ply"
        try TrainingArtifactStore.persist(cancelledTraining, paths: paths)
        let cancellation = ReceiptLockedCounter()

        XCTAssertThrowsError(
            try PublishedResultPublisher.publishCompletedTraining(
                metadata: cancelledMetadata,
                resolvedRunPlan: plan,
                geometry: geometry,
                paths: paths,
                publicationID: cancelledPublicationID,
                publishedAt: Date(timeIntervalSince1970: 1_767_226_000),
                pairOperations: pairOperations,
                shouldCancel: { cancellation.value > 0 },
                persistPreparedManifest: {
                    data, artifact, evidence, expectedSourceIdentity, projectPaths in
                    try TrainingArtifactStore.persistPreparedManifest(
                        data,
                        artifact: artifact,
                        validatedOutputEvidence: evidence,
                        expectedSourceIdentity: expectedSourceIdentity,
                        paths: projectPaths
                    )
                    cancellation.increment()
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        guard case .available(let cancelledPublication) = try PublishedResultPairStore.resolve(
            projectPaths: paths
        ) else {
            return XCTFail("Late cancellation must retain the consistent committed pair.")
        }
        XCTAssertEqual(
            cancelledPublication.receipt.publicationID,
            cancelledPublicationID
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ).outputPath,
            PublishedSplatReceipt.canonicalOutputPath
        )
    }

    func testConcurrentSameAttemptPublishesExactlyOnePairTransaction() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("ConcurrentPublish.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        var plan = makePlan()
        plan.trainerIterationLimit = 30_000
        let requested = defaultRequestedRunOptions()
        let publicationID = UUID(
            uuidString: "ABCDEF12-3456-4789-8ABC-DEF123456789"
        )!
        var metadata = ProjectMetadata(
            id: UUID(uuidString: "AAAA1111-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
            title: "Concurrent publication",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: requested,
            resolvedRunPlan: plan,
            stageTimings: [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: Date(timeIntervalSince1970: 1_767_224_800),
                    durationSeconds: 812.5
                ),
            ]
        )
        metadata.pendingPublicationID = publicationID
        var geometry = makeGeometryArtifact()
        geometry.residualProvenance = "colmap-text-tracks-v1"
        geometry.selectedFramesDigest = String(repeating: "e", count: 64)
        let geometryManifestSHA256 = try writeGeometryManifest(
            geometry,
            paths: paths
        )
        try TestFileBuilder.writeMinimalPly(at: paths.msplatOutputURL, vertexCount: 7)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.msplatOutputURL
        )
        var training = makeTrainingArtifact(outputPath: "Training/msplat/splat.ply")
        training.detailProfile = requested.detailProfile
        training.iterationLimit = plan.trainerIterationLimit
        training.plateauWindow = plan.plateauWindow
        training.cameraOrderSeed = plan.runSeed
        training.completedIteration = plan.trainerIterationLimit
        training.memoryBudgetBytes = min(
            training.memoryBudgetBytes,
            plan.trainerMemoryBudgetBytes
        )
        training.resourceAdmission = makeTestTrainingResourceAdmission(
            resourcePolicy: requested.resourcePolicy
        )
        training.outputSHA256 = evidence.sha256
        training.outputBytes = Int64(evidence.byteCount)
        training.gaussianCount = evidence.vertexCount
        training.sceneBounds = evidence.sceneBounds
        training.datasetDerivation = makeMsplatDatasetDerivation(
            inputDigest: training.inputDigest,
            geometryDigest: training.geometryDigest,
            registeredImageNames: geometry.orderedImageNames,
            sourceGeometryManifestSHA256: geometryManifestSHA256,
            sourceSelectedFramesDigest: geometry.selectedFramesDigest,
            maximumImageDimension: plan.maximumImageDimension
        )
        try TrainingArtifactStore.persist(training, paths: paths)

        let checkpoints = ReceiptPublicationCheckpointRecorder()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoints.append($0) }
        let concurrentMetadata = metadata
        let concurrentPlan = plan
        let concurrentGeometry = geometry
        let concurrentOperations = operations
        let barrier = ReceiptTwoPartyBarrier()
        let results = ReceiptTimingResults()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    results.recordSuccess(
                        try PublishedResultPublisher.publishCompletedTraining(
                            metadata: concurrentMetadata,
                            resolvedRunPlan: concurrentPlan,
                            geometry: concurrentGeometry,
                            paths: paths,
                            publicationID: publicationID,
                            publishedAt: Date(timeIntervalSince1970: 1_767_225_900),
                            pairOperations: concurrentOperations,
                            beforePublish: { barrier.wait() }
                        )
                    )
                } catch {
                    results.recordFailure(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertTrue(results.failures.isEmpty)
        XCTAssertEqual(results.successes.count, 2)
        XCTAssertEqual(
            checkpoints.values.filter { $0 == .transactionCreated }.count,
            1,
            "The publication lock must adopt the winner instead of republishing it."
        )
        if results.successes.count == 2 {
            XCTAssertEqual(results.successes[0], results.successes[1])
        }
    }

    func testTimingOnlyUpdatePreservesPublicationIdentityAndIsIdempotent() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let updated = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths
        )
        XCTAssertEqual(updated.receipt.publicationID, original.publicationID)
        XCTAssertEqual(
            updated.receipt.presentation.createToViewerReadySeconds,
            142.25
        )

        let repeated = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths
        )
        XCTAssertEqual(repeated, updated)
        XCTAssertThrowsError(try PublishedResultPublisher.recordFirstViewerReadyTiming(
            143,
            publicationID: original.publicationID,
            paths: fixture.paths
        ))
        XCTAssertThrowsError(try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: UUID(),
            paths: fixture.paths
        ))
    }

    func testTimingOnlyUpdatePreservesCanonicalPlyInodeAndOpenReader() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let reader = Darwin.open(
            fixture.paths.outputSplatURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { Darwin.close(reader) }
        var before = stat()
        XCTAssertEqual(Darwin.fstat(reader, &before), 0)

        _ = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths
        )

        var heldAfter = stat()
        var canonicalAfter = stat()
        XCTAssertEqual(Darwin.fstat(reader, &heldAfter), 0)
        XCTAssertEqual(Darwin.lstat(
            fixture.paths.outputSplatURL.path,
            &canonicalAfter
        ), 0)
        XCTAssertEqual(before.st_dev, heldAfter.st_dev)
        XCTAssertEqual(before.st_ino, heldAfter.st_ino)
        XCTAssertEqual(before.st_size, heldAfter.st_size)
        XCTAssertEqual(before.st_dev, canonicalAfter.st_dev)
        XCTAssertEqual(before.st_ino, canonicalAfter.st_ino)
        XCTAssertEqual(before.st_size, canonicalAfter.st_size)
    }

    func testTimingUpdateRejectsSameSizePlyMutationAfterReceiptSwap() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let system = PublishedResultPairOperations.system()
        let mutation = ReceiptFirstSyncFailure()
        var operations = system
        operations.swap = { sourceDirectory, sourceName, destinationDirectory, destinationName in
            let result = system.swap(
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName
            )
            guard result == 0, mutation.consume() else { return result }
            do {
                try mutateReceiptTimingTestPly(at: fixture.paths.outputSplatURL)
                return 0
            } catch {
                Darwin.__error().pointee = EIO
                return -1
            }
        }

        XCTAssertThrowsError(try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        ))
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.evidenceMismatch)
        )
    }

    func testTimingOnlyUpdateValidatesPlyOnceAndCreatesNoPairTransaction() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let validations = ReceiptLockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in validations.increment() }
        _ = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        )

        XCTAssertEqual(validations.value, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains { $0.hasPrefix(".published-result-tx-") })
    }

    func testPartialTimingTransactionWritesRemainRecoverablyOwned() throws {
        for targetWrite in 1...3 {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
            try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
            let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
            let original = makeReceipt(
                outputEvidence: evidence,
                createToViewerReadySeconds: nil
            )
            let published = try PublishedResultPairStore.publish(
                sourceURL: source,
                receipt: original,
                projectPaths: fixture.paths
            )

            let injector = ReceiptPartialWriteFailure(targetWrite: targetWrite)
            var operations = PublishedResultPairOperations.system()
            operations.write = { descriptor, bytes, count in
                injector.write(descriptor: descriptor, bytes: bytes, count: count)
            }
            XCTAssertThrowsError(
                try PublishedResultPublisher.recordFirstViewerReadyTiming(
                    142.25,
                    publicationID: original.publicationID,
                    paths: fixture.paths,
                    pairOperations: operations
                ),
                "Injected write: \(targetWrite)"
            )

            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .available(published),
                "A partial app-owned timing write must reconcile to the old receipt."
            )
            let names = try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.outputURL.path
            )
            XCTAssertFalse(names.contains {
                $0.hasPrefix(".published-receipt-tx-")
                    || $0.hasPrefix(".published-receipt-retired-")
            })
        }
    }

    func testInitialTimingAuthoritySyncFailureLeavesNoPendingConflict() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let failure = ReceiptFirstSyncFailure()
        let system = PublishedResultPairOperations.system()
        var operations = system
        operations.synchronizeFile = { descriptor in
            if failure.consume() {
                Darwin.__error().pointee = EIO
                return -1
            }
            return system.synchronizeFile(descriptor)
        }
        XCTAssertThrowsError(try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        ))

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(published)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains {
            $0.hasPrefix(".published-receipt-tx-")
                || $0.hasPrefix(".published-receipt-retired-")
        })
    }

    func testEmptyViewerTimingTransactionIsPreservedAsConflict() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )
        let transaction = fixture.paths.outputURL.appendingPathComponent(
            ".published-receipt-tx-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: transaction,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: transaction.path),
            "A reserved directory without durable ownership must never be deleted."
        )
    }

    func testViewerTimingBuildRemainsInactiveUntilCreatedJournalIsDurable() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let observations = ReceiptTimingActivationObservations()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .receiptCleanupPlaceholderDurable
                    || checkpoint == .receiptTransactionActivated else {
                return
            }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: fixture.paths.outputURL,
                includingPropertiesForKeys: nil
            )) ?? []
            observations.record(
                checkpoint: checkpoint,
                names: entries.map(\.lastPathComponent),
                activeIsComplete: entries.first {
                    $0.lastPathComponent.hasPrefix(".published-receipt-tx-")
                }.map {
                    Set((try? FileManager.default.contentsOfDirectory(
                        atPath: $0.path
                    )) ?? []) == Set([
                        "journal-created.json",
                        "journal-prepared.json",
                        "next-receipt.json",
                        "cleanup-authorized.json",
                        "parent-cleanup-authority.json",
                    ])
                } ?? false
            )
        }
        _ = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        )

        XCTAssertTrue(observations.placeholderNames.contains {
            $0.hasPrefix(".published-receipt-build-")
        })
        XCTAssertFalse(observations.placeholderNames.contains {
            $0.hasPrefix(".published-receipt-tx-")
        })
        XCTAssertTrue(observations.activatedIsComplete)
    }

    func testPreparedViewerTimingBuildRecoversWithoutTouchingCanonicalPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let system = PublishedResultPairOperations.system()
        var operations = system
        operations.renameExclusive = {
            sourceDirectory,
            sourceName,
            destinationDirectory,
            destinationName in
            if sourceName.hasPrefix(".published-receipt-build-"),
               destinationName.hasPrefix(".published-receipt-tx-") {
                Darwin.__error().pointee = EIO
                return -1
            }
            return system.renameExclusive(
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName
            )
        }
        operations.willQuarantineOwnedEntry = { _ in
            throw NSError(
                domain: "PublishedSplatReceiptTests.simulated-build-crash",
                code: 1
            )
        }
        XCTAssertThrowsError(try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains { $0.hasPrefix(".published-receipt-build-") })

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(published)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains { $0.hasPrefix(".published-receipt-build-") })
    }

    func testUnknownViewerTimingBuildStateRemainsConflict() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )
        let build = fixture.paths.outputURL.appendingPathComponent(
            ".published-receipt-build-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: build,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: build.path))
    }

    func testTimingRetirementRenameThenErrorHealsCommittedReceipt() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let system = PublishedResultPairOperations.system()
        let injector = ReceiptFirstSyncFailure()
        var operations = system
        operations.renameExclusive = {
            sourceDirectory,
            sourceName,
            destinationDirectory,
            destinationName in
            let result = system.renameExclusive(
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName
            )
            if result == 0,
               sourceName.hasPrefix(".published-receipt-tx-"),
               destinationName.hasPrefix(".published-receipt-retired-"),
               injector.consume() {
                Darwin.__error().pointee = EIO
                return -1
            }
            return result
        }
        let committed = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        )
        XCTAssertEqual(
            committed.receipt.presentation.createToViewerReadySeconds,
            142.25
        )
        XCTAssertNoThrow(
            try PublishedResultPairStore.reconcile(projectPaths: fixture.paths),
            "Recovery must finish cleanup after a rename that reported failure."
        )
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(committed),
            "The committed receipt must remain authoritative while cleanup heals."
        )
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        )
        XCTAssertFalse(names.contains {
            $0.hasPrefix(".published-receipt-tx-")
                || $0.hasPrefix(".published-receipt-retired-")
        })
    }

    func testTimingRecoveryFinishesRetirementAfterParentAuthorityMove() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let system = PublishedResultPairOperations.system()
        let state = ReceiptParentAuthorityMoveState()
        var operations = system
        operations.renameExclusive = {
            sourceDirectory,
            sourceName,
            destinationDirectory,
            destinationName in
            if sourceName == "parent-cleanup-authority.json",
               destinationName.hasPrefix(".published-receipt-cleanup-") {
                let result = system.renameExclusive(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName
                )
                if result == 0 { state.markMoved() }
                return result
            }
            if sourceName.hasPrefix(".published-receipt-tx-"),
               destinationName.hasPrefix(".published-receipt-retired-"),
               state.consumeMoved() {
                Darwin.__error().pointee = EIO
                return -1
            }
            return system.renameExclusive(
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName
            )
        }
        let committed = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        )
        let interruptedNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        )
        XCTAssertTrue(interruptedNames.contains {
            $0.hasPrefix(".published-receipt-tx-")
        })
        XCTAssertTrue(interruptedNames.contains {
            $0.hasPrefix(".published-receipt-cleanup-")
        })

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(committed)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains {
            $0.hasPrefix(".published-receipt-tx-")
                || $0.hasPrefix(".published-receipt-retired-")
                || $0.contains(".published-receipt-cleanup-")
        })
    }

    func testTimingCleanupResumesAfterAuthorityWasQuarantined() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        var operations = PublishedResultPairOperations.system()
        operations.willUnlinkQuarantinedEntry = { name in
            if name == "cleanup-authorized.json" {
                throw NSError(
                    domain: "PublishedSplatReceiptTests.cleanup-interruption",
                    code: 1
                )
            }
        }
        let committed = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains { $0.hasPrefix(".published-receipt-retired-") })

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(committed)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains {
            $0.hasPrefix(".published-receipt-tx-")
                || $0.hasPrefix(".published-receipt-retired-")
        })
    }

    func testTimingCleanupResumesAfterParentAuthorityWasQuarantined() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let interruption = ReceiptFirstSyncFailure()
        var operations = PublishedResultPairOperations.system()
        operations.willUnlinkQuarantinedEntry = { name in
            guard name.hasPrefix(".published-receipt-cleanup-"),
                  interruption.consume() else { return }
            throw NSError(
                domain: "PublishedSplatReceiptTests.parent-cleanup-interruption",
                code: 1
            )
        }
        let committed = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains {
            $0.hasPrefix(".cleanup-.published-receipt-cleanup-")
        })

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(committed)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains {
            $0.contains(".published-receipt-cleanup-")
        })
    }

    func testTimingCleanupKeepsParentAuthorityWhenForeignStateAppears() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let injection = ReceiptFirstSyncFailure()
        var operations = PublishedResultPairOperations.system()
        operations.willUnlinkQuarantinedEntry = { name in
            guard name == "cleanup-authorized.json", injection.consume() else {
                return
            }
            let retired = try FileManager.default.contentsOfDirectory(
                at: fixture.paths.outputURL,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(".published-receipt-retired-")
            }
            let directory = try XCTUnwrap(retired)
            let foreign = directory.appendingPathComponent("foreign.bin")
            try Data([0x7f]).write(to: foreign, options: .withoutOverwriting)
            XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)
        }
        let committed = try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142.25,
            publicationID: original.publicationID,
            paths: fixture.paths,
            pairOperations: operations
        )

        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        )
        XCTAssertTrue(names.contains {
            $0.hasPrefix(".published-receipt-cleanup-")
        }, "Cleanup authority must survive outside the directory it authorizes.")
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        let retired = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.paths.outputURL,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(".published-receipt-retired-")
            }
        )
        try FileManager.default.removeItem(
            at: retired.appendingPathComponent("foreign.bin")
        )
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(committed)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains {
            $0.hasPrefix(".published-receipt-retired-")
                || $0.hasPrefix(".published-receipt-cleanup-")
        })
    }

    func testConcurrentConflictingViewerTimingsHaveExactlyOneWinner() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let results = ReceiptTimingResults()
        let group = DispatchGroup()
        for seconds in [142.0, 143.0] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let value = try PublishedResultPublisher.recordFirstViewerReadyTiming(
                        seconds,
                        publicationID: original.publicationID,
                        paths: fixture.paths
                    )
                    results.recordSuccess(value)
                } catch {
                    results.recordFailure(error)
                }
            }
        }
        group.wait()

        XCTAssertEqual(results.successes.count, 1)
        XCTAssertEqual(results.failures.count, 1)
        guard case .available(let current) = try PublishedResultPairStore.resolve(
            projectPaths: fixture.paths
        ) else {
            return XCTFail("Expected one authoritative timing")
        }
        XCTAssertEqual(
            current.receipt.presentation.createToViewerReadySeconds,
            results.successes.first?.receipt.presentation.createToViewerReadySeconds
        )
    }

    func testStaleTimingCannotReplaceNewPublicationWithIdenticalPly() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let staleResult = ReceiptTimingResults()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                let result = try PublishedResultPublisher.recordFirstViewerReadyTiming(
                    142,
                    publicationID: original.publicationID,
                    paths: fixture.paths,
                    beforeLockedUpdate: {
                        paused.signal()
                        resume.wait()
                    }
                )
                staleResult.recordSuccess(result)
            } catch {
                staleResult.recordFailure(error)
            }
        }
        paused.wait()

        let replacementReceipt = makeReceipt(
            publicationID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        let replacement = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: replacementReceipt,
            projectPaths: fixture.paths
        )
        resume.signal()
        group.wait()

        XCTAssertTrue(staleResult.successes.isEmpty)
        XCTAssertEqual(staleResult.failures.count, 1)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(replacement)
        )
    }

    func testCancelledTimingUpdateCreatesNoTransaction() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let original = makeReceipt(
            outputEvidence: evidence,
            createToViewerReadySeconds: nil
        )
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: original,
            projectPaths: fixture.paths
        )

        XCTAssertThrowsError(try PublishedResultPublisher.recordFirstViewerReadyTiming(
            142,
            publicationID: original.publicationID,
            paths: fixture.paths,
            shouldCancel: { true }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).contains { $0.hasPrefix(".published-receipt-tx-") })
    }

    func testDecoderRejectsDomainOverflowAndCountsBeyondTheirAuthorities() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let mutations: [([JSONPathComponent], Any)] = [
            ([.key("outputEvidence"), .key("byteCount")], UInt64(Int64.max) + 1),
            ([.key("outputEvidence"), .key("gaussianCount")], 146_381_210),
            (
                [.key("presentation"), .key("reconstruction"), .key("totalViewCount")],
                makePlan().keyframeBudget + 1
            ),
            (
                [
                    .key("presentation"), .key("reconstruction"),
                    .key("secondLargestModelRegisteredViewCount"),
                ],
                -1
            ),
        ]

        for (path, value) in mutations {
            let tampered = try replacingJSONValue(in: canonical, at: path, with: value)
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(tampered), "Path: \(path)") {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }
    }

    func testDecoderRejectsTimingsThatEndAfterPublicationOrOverflow() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        var afterPublication = try replacingJSONValue(
            in: canonical,
            at: [.key("presentation"), .key("stageTimings"), .index(0), .key("startedAt")],
            with: "2025-12-31T23:59:59Z"
        )
        afterPublication = try replacingJSONValue(
            in: afterPublication,
            at: [
                .key("presentation"), .key("stageTimings"), .index(0),
                .key("durationSeconds"),
            ],
            with: 2
        )
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(afterPublication)) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }

        let overflowing = try replacingJSONValue(
            in: canonical,
            at: [
                .key("presentation"), .key("stageTimings"), .index(0),
                .key("durationSeconds"),
            ],
            with: 1e308
        )
        XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(overflowing)) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
        }
    }

    func testWireDateRangeRoundTripsBoundariesAndRejectsOutsideIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let lowerBoundary = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 1,
            month: 1,
            day: 1
        )))
        let upperBoundary = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 9_999,
            month: 12,
            day: 31,
            hour: 23,
            minute: 59,
            second: 59
        )))

        for (date, wireValue) in [
            (lowerBoundary, "0001-01-01T00:00:00Z"),
            (upperBoundary, "9999-12-31T23:59:59Z"),
        ] {
            let receipt = makeReceipt(
                publishedAt: date,
                stageTimings: [
                    StageTimingRecord(
                        stage: .trainSplat,
                        startedAt: date,
                        durationSeconds: 0
                    ),
                ],
                trainingDurationSeconds: 0,
                createToViewerReadySeconds: 0
            )
            let encoded = try PublishedSplatReceiptStore.encode(receipt)
            XCTAssertEqual(try PublishedSplatReceiptStore.decode(encoded), receipt)
            XCTAssertTrue(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains(
                #""publishedAt":"\#(wireValue)""#
            ))
        }

        for date in [
            lowerBoundary.addingTimeInterval(-1),
            upperBoundary.addingTimeInterval(1),
        ] {
            let receipt = makeReceipt(
                publishedAt: date,
                stageTimings: [
                    StageTimingRecord(
                        stage: .trainSplat,
                        startedAt: date,
                        durationSeconds: 0
                    ),
                ],
                trainingDurationSeconds: 0,
                createToViewerReadySeconds: 0
            )
            XCTAssertThrowsError(try PublishedSplatReceiptStore.encode(receipt)) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .invalidReceipt)
            }
        }

        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        for wireValue in [
            "0000-12-31T23:59:59Z",
            "10000-01-01T00:00:00Z",
        ] {
            let outsideRange = try replacingJSONValue(
                in: canonical,
                at: [.key("publishedAt")],
                with: wireValue
            )
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(outsideRange)) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .malformed)
            }
        }
    }

    func testDecoderRejectsNoncanonicalFractionalWireDates() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())

        for wireValue in [
            "2026-01-01T00:00:00.1Z",
            "2026-01-01T00:00:00.000000001Z",
        ] {
            let noncanonical = try replacingJSONValue(
                in: canonical,
                at: [.key("publishedAt")],
                with: wireValue
            )
            XCTAssertThrowsError(try PublishedSplatReceiptStore.decode(noncanonical)) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .malformed)
            }
        }

        let exact = try replacingJSONValue(
            in: canonical,
            at: [.key("publishedAt")],
            with: "2026-01-01T00:00:00.125000000Z"
        )
        XCTAssertNoThrow(try PublishedSplatReceiptStore.decode(exact))
    }

    func testLoadRejectsSymlinkHardlinkFIFOAndUnsafePermissionsWithoutBlocking() throws {
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())

        for kind in UnsafeLeafKind.allCases {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let receiptURL = fixture.paths.outputSplatReceiptURL
            switch kind {
            case .symlink:
                let target = fixture.root.appendingPathComponent("target.json")
                try writePrivate(canonical, to: target)
                XCTAssertEqual(Darwin.symlink(target.path, receiptURL.path), 0)
            case .hardlink:
                let target = fixture.root.appendingPathComponent("target.json")
                try writePrivate(canonical, to: target)
                XCTAssertEqual(Darwin.link(target.path, receiptURL.path), 0)
            case .fifo:
                XCTAssertEqual(Darwin.mkfifo(receiptURL.path, 0o600), 0)
            }

            XCTAssertThrowsError(try PublishedSplatReceiptStore.load(projectPaths: fixture.paths)) {
                XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .unsafeFile)
            }
        }

        for mode: mode_t in [0o400, 0o600, 0o644, 0o700] {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try writePrivate(canonical, to: fixture.paths.outputSplatReceiptURL)
            XCTAssertEqual(Darwin.chmod(fixture.paths.outputSplatReceiptURL.path, mode), 0)
            if mode == 0o600 {
                XCTAssertNoThrow(try PublishedSplatReceiptStore.load(projectPaths: fixture.paths))
            } else {
                XCTAssertThrowsError(
                    try PublishedSplatReceiptStore.load(projectPaths: fixture.paths)
                ) {
                    XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .unsafeFile)
                }
            }
        }
    }

    func testLoadRejectsSameSizeInPlaceMutationDuringRead() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        let padded = canonical + Data(repeating: UInt8(ascii: " "), count: 8)
        try writePrivate(padded, to: fixture.paths.outputSplatReceiptURL)

        XCTAssertThrowsError(try PublishedSplatReceiptStore.load(
            projectPaths: fixture.paths,
            beforeFinalIdentityCheck: {
                let descriptor = Darwin.open(
                    fixture.paths.outputSplatReceiptURL.path,
                    O_WRONLY | O_CLOEXEC
                )
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                defer { Darwin.close(descriptor) }
                var newline = UInt8(ascii: "\n")
                XCTAssertEqual(
                    Darwin.pwrite(descriptor, &newline, 1, off_t(padded.count - 1)),
                    1
                )
                XCTAssertEqual(Darwin.fsync(descriptor), 0)
            }
        )) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .unstableFile)
        }
    }

    func testLoadRejectsPathReplacementDuringReadEvenWhenBytesMatch() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonical = try PublishedSplatReceiptStore.encode(makeReceipt())
        try writePrivate(canonical, to: fixture.paths.outputSplatReceiptURL)
        let held = fixture.paths.outputURL.appendingPathComponent("held-receipt.json")

        XCTAssertThrowsError(try PublishedSplatReceiptStore.load(
            projectPaths: fixture.paths,
            beforeFinalIdentityCheck: {
                XCTAssertEqual(
                    Darwin.rename(fixture.paths.outputSplatReceiptURL.path, held.path),
                    0
                )
                try self.writePrivate(canonical, to: fixture.paths.outputSplatReceiptURL)
            }
        )) {
            XCTAssertEqual($0 as? PublishedSplatReceiptStoreError, .unstableFile)
        }
    }

}

private func mutateReceiptTimingTestPly(at url: URL) throws {
    let data = try Data(contentsOf: url)
    guard let marker = data.range(of: Data("end_header\n".utf8)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    var original = stat()
    guard Darwin.fstat(descriptor, &original) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var byte = data[marker.upperBound] ^ 0x01
    guard Darwin.pwrite(descriptor, &byte, 1, off_t(marker.upperBound)) == 1,
          Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var originalTimes = [original.st_atimespec, original.st_mtimespec]
    guard Darwin.futimens(descriptor, &originalTimes) == 0,
          Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private final class ReceiptPublicationCheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PublishedResultPairCheckpoint] = []

    var values: [PublishedResultPairCheckpoint] {
        lock.withLock { storage }
    }

    func append(_ value: PublishedResultPairCheckpoint) {
        lock.withLock { storage.append(value) }
    }
}

private final class ReceiptTimingActivationObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var placeholderStorage: [String] = []
    private var activatedCompleteStorage = false

    var placeholderNames: [String] { lock.withLock { placeholderStorage } }
    var activatedIsComplete: Bool {
        lock.withLock { activatedCompleteStorage }
    }

    func record(
        checkpoint: PublishedResultPairCheckpoint,
        names: [String],
        activeIsComplete: Bool
    ) {
        lock.withLock {
            if checkpoint == .receiptCleanupPlaceholderDurable {
                placeholderStorage = names
            }
            if checkpoint == .receiptTransactionActivated {
                activatedCompleteStorage = activeIsComplete
            }
        }
    }
}

private final class ReceiptLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class ReceiptTimingResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successStorage: [ValidatedPublishedResult] = []
    private var failureStorage: [Error] = []

    var successes: [ValidatedPublishedResult] {
        lock.withLock { successStorage }
    }

    var failures: [Error] {
        lock.withLock { failureStorage }
    }

    func recordSuccess(_ value: ValidatedPublishedResult) {
        lock.withLock { successStorage.append(value) }
    }

    func recordFailure(_ error: Error) {
        lock.withLock { failureStorage.append(error) }
    }
}

private final class ReceiptPartialWriteFailure: @unchecked Sendable {
    private enum Action { case normal, partial, fail }

    private let lock = NSLock()
    private let targetWrite: Int
    private var writeCount = 0
    private var failNext = false

    init(targetWrite: Int) {
        self.targetWrite = targetWrite
    }

    func write(
        descriptor: Int32,
        bytes: UnsafeRawPointer?,
        count: Int
    ) -> Int {
        let action: Action = lock.withLock {
            if failNext {
                failNext = false
                return .fail
            }
            writeCount += 1
            if writeCount == targetWrite {
                failNext = true
                return .partial
            }
            return .normal
        }
        switch action {
        case .normal:
            return Darwin.write(descriptor, bytes, count)
        case .partial:
            return Darwin.write(descriptor, bytes, min(7, count))
        case .fail:
            Darwin.__error().pointee = ENOSPC
            return -1
        }
    }
}

private final class ReceiptFirstSyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true

    func consume() -> Bool {
        lock.withLock {
            guard pending else { return false }
            pending = false
            return true
        }
    }
}

private final class ReceiptParentAuthorityMoveState: @unchecked Sendable {
    private let lock = NSLock()
    private var moved = false

    func markMoved() {
        lock.withLock { moved = true }
    }

    func consumeMoved() -> Bool {
        lock.withLock {
            guard moved else { return false }
            moved = false
            return true
        }
    }
}

private final class ReceiptTwoPartyBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var arrivals = 0

    func wait() {
        let shouldRelease = lock.withLock {
            arrivals += 1
            return arrivals == 2
        }
        if shouldRelease {
            release.signal()
            release.signal()
        }
        release.wait()
    }
}

private extension PublishedSplatReceiptTests {
    enum JSONPathComponent: CustomStringConvertible {
        case key(String)
        case index(Int)

        var description: String {
            switch self {
            case .key(let key): return key
            case .index(let index): return "[\(index)]"
            }
        }
    }

    enum UnsafeLeafKind: CaseIterable {
        case symlink
        case hardlink
        case fifo
    }

    func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Receipt.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        return (root, paths)
    }

    func makeReceipt(
        publicationID: UUID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
        publishedAt: Date = Date(timeIntervalSince1970: 1_767_225_600),
        outputEvidence: ValidatedPlyArtifactEvidence? = nil,
        requestedRunOptions: RequestedRunOptions? = nil,
        resolvedRunPlan: ResolvedRunPlan? = nil,
        reconstruction: PublishedReconstructionSummary? = nil,
        stageTimings: [StageTimingRecord]? = nil,
        trainingDurationSeconds: Double = 12.5,
        createToViewerReadySeconds: Double? = 117.75
    ) -> PublishedSplatReceipt {
        let plan = resolvedRunPlan ?? makePlan()
        return PublishedSplatReceipt(
            schemaVersion: PublishedSplatReceipt.currentSchemaVersion,
            publicationID: publicationID,
            projectID: UUID(uuidString: "99999999-8888-4777-8666-555555555555")!,
            publishedAt: publishedAt,
            outputPath: PublishedSplatReceipt.canonicalOutputPath,
            outputEvidence: outputEvidence ?? ValidatedPlyArtifactEvidence(
                byteCount: 146_381_209,
                vertexCount: 1_234_567,
                format: "binary_little_endian",
                sha256: String(repeating: "a", count: 64),
                sceneBounds: SplatSceneBounds(
                    center: ScenePoint3D(x: 1.25, y: -2.5, z: 3.75),
                    radius: 8.5
                )
            ),
            lineage: PublishedSplatLineage(
                trainingManifestSHA256: String(repeating: "b", count: 64),
                trainingInputDigest: String(repeating: "c", count: 64),
                trainingGeometryDigest: String(repeating: "d", count: 64)
            ),
            presentation: PublishedResultPresentation(
                requestedRunOptions: requestedRunOptions ?? defaultRequestedRunOptions(),
                resolvedRunPlan: plan,
                reconstruction: reconstruction ?? PublishedReconstructionSummary(
                    registeredViewCount: 18,
                    totalViewCount: 20,
                    pointCount: 45_678,
                    observationCount: 123_456,
                    medianPixelResidual: 0.42,
                    p90PixelResidual: 1.25,
                    solverVersion: "COLMAP 3.12",
                    modelVersion: "classic-incremental",
                    cameraModel: "SIMPLE_RADIAL",
                    residualProvenance: "colmap-text-tracks-v1",
                    usedPartialCoverageAcceptance: true,
                    secondLargestModelRegisteredViewCount: 2
                ),
                orientation: PublishedOrientationSummary(
                    status: .verified,
                    openingDirection: CanonicalDirection(x: 0, y: 0, z: -1),
                    allowsViewOnlyUprightFlip: false
                ),
                stageTimings: stageTimings ?? [
                    StageTimingRecord(
                        stage: .importInput,
                        startedAt: Date(timeIntervalSince1970: 1_767_225_000),
                        durationSeconds: 3.25
                    ),
                    StageTimingRecord(
                        stage: .trainSplat,
                        startedAt: Date(timeIntervalSince1970: 1_767_225_100),
                        durationSeconds: 95.5
                    ),
                ],
                autoTunerSnapshot: PublishedAutoTunerSnapshot(resolvedRunPlan: plan),
                trainerVersion: "msplat-1.2.3",
                runtimeVersion: "python-3.12.4-metal",
                completedIteration: min(12_345, plan.trainerIterationLimit),
                trainingDurationSeconds: trainingDurationSeconds,
                createToViewerReadySeconds: createToViewerReadySeconds
            )
        )
    }

    func makeReconstruction(
        registeredViewCount: Int = 18,
        totalViewCount: Int = 20,
        medianPixelResidual: Double = 0.42,
        p90PixelResidual: Double = 1.25,
        residualProvenance: String = "colmap-text-tracks-v1",
        usedPartialCoverageAcceptance: Bool = true,
        secondLargestModelRegisteredViewCount: Int = 2
    ) -> PublishedReconstructionSummary {
        PublishedReconstructionSummary(
            registeredViewCount: registeredViewCount,
            totalViewCount: totalViewCount,
            pointCount: 45_678,
            observationCount: 123_456,
            medianPixelResidual: medianPixelResidual,
            p90PixelResidual: p90PixelResidual,
            solverVersion: "COLMAP 3.12",
            modelVersion: "classic-incremental",
            cameraModel: "SIMPLE_RADIAL",
            residualProvenance: residualProvenance,
            usedPartialCoverageAcceptance: usedPartialCoverageAcceptance,
            secondLargestModelRegisteredViewCount:
                secondLargestModelRegisteredViewCount
        )
    }

    func defaultRequestedRunOptions() -> RequestedRunOptions {
        RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced,
            cameraGrouping: .sameCameraAndLens,
            lensProjection: .perspective,
            inputOrdering: .automatic,
            resourcePolicy: .maximumPerformance,
            photoSelection: .useAllValidPhotos
        )
    }

    func makePlan() -> ResolvedRunPlan {
        RunPlanResolver.resolve(
            requestedOptions: defaultRequestedRunOptions(),
            input: .photos(folder: "Inputs/photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
    }

    func addingUnknownKey(
        to data: Data,
        objectPath: [JSONPathComponent]
    ) throws -> Data {
        var root: Any = try JSONSerialization.jsonObject(with: data)
        root = try transformJSON(root, at: objectPath) { object in
            var dictionary = try XCTUnwrap(object as? [String: Any])
            dictionary["unexpected"] = true
            return dictionary
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func removingKey(
        _ key: String,
        from data: Data,
        objectPath: [JSONPathComponent]
    ) throws -> Data {
        var root: Any = try JSONSerialization.jsonObject(with: data)
        root = try transformJSON(root, at: objectPath) { object in
            var dictionary = try XCTUnwrap(object as? [String: Any])
            dictionary.removeValue(forKey: key)
            return dictionary
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func replacingJSONValue(
        in data: Data,
        at path: [JSONPathComponent],
        with value: Any
    ) throws -> Data {
        var root: Any = try JSONSerialization.jsonObject(with: data)
        root = try transformJSON(root, at: path) { _ in value }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func replacingOnce(
        in data: Data,
        target: String,
        replacement: String
    ) throws -> Data {
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        let range = try XCTUnwrap(source.range(of: target))
        XCTAssertNil(
            source[range.upperBound...].range(of: target),
            "The mutation target must be unique"
        )
        return try XCTUnwrap(
            source.replacingCharacters(in: range, with: replacement).data(using: .utf8)
        )
    }

    func transformJSON(
        _ object: Any,
        at path: [JSONPathComponent],
        transform: (Any) throws -> Any
    ) throws -> Any {
        guard let first = path.first else { return try transform(object) }
        let rest = Array(path.dropFirst())
        switch first {
        case .key(let key):
            var dictionary = try XCTUnwrap(object as? [String: Any])
            dictionary[key] = try transformJSON(
                try XCTUnwrap(dictionary[key]),
                at: rest,
                transform: transform
            )
            return dictionary
        case .index(let index):
            var array = try XCTUnwrap(object as? [Any])
            array[index] = try transformJSON(array[index], at: rest, transform: transform)
            return array
        }
    }

    func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        XCTAssertEqual(Darwin.chmod(url.path, 0o600), 0)
    }

    func writeGeometryManifest(
        _ geometry: GeometryArtifact,
        paths: ProjectPaths
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(geometry).write(
            to: paths.geometryManifestURL,
            options: [.atomic]
        )
        return try GeometryArtifactStore.manifestDigest(
            matching: geometry,
            at: paths.geometryManifestURL
        )
    }

}
