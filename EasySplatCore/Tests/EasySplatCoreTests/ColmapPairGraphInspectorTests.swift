#if canImport(XCTest)
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapPairGraphInspectorTests: XCTestCase {
    func testDominantConnectivityPolicyRequiresConsistentComponentsAndNinetyPercent() {
        XCTAssertEqual(
            PairGraphConnectivityPolicy.dominantViewCount(
                totalViewCount: 60,
                componentViewCounts: [54, 1, 1, 1, 1, 1, 1],
                connectedComponentCount: 7,
                isolatedViewCount: 6,
                descriptorlessViewCount: 2
            ),
            54
        )
        XCTAssertNil(PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: 60,
            componentViewCounts: [53, 1, 1, 1, 1, 1, 1, 1],
            connectedComponentCount: 8,
            isolatedViewCount: 7,
            descriptorlessViewCount: 0
        ))
        XCTAssertNil(PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: 60,
            componentViewCounts: [59, 1],
            connectedComponentCount: 2,
            isolatedViewCount: 0,
            descriptorlessViewCount: 0
        ))
        XCTAssertNil(PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: 60,
            componentViewCounts: [59, 1],
            connectedComponentCount: 2,
            isolatedViewCount: 1,
            descriptorlessViewCount: 2
        ))
        XCTAssertNil(PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: 22,
            componentViewCounts: [18, 1, 1, 1, 1],
            connectedComponentCount: 5,
            isolatedViewCount: 4,
            descriptorlessViewCount: 0
        ))
        XCTAssertNil(PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: 60,
            componentViewCounts: [54, 2, 1, 1, 1, 1],
            connectedComponentCount: 6,
            isolatedViewCount: 4,
            descriptorlessViewCount: 0
        ))
        XCTAssertEqual(PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: 60,
            componentViewCounts: [57, 2, 1],
            connectedComponentCount: 3,
            isolatedViewCount: 1,
            descriptorlessViewCount: 0
        ), 57)
    }

    func testOrderedDominantComponentPolicyAcceptsMinorVerifiedComponents() {
        let inspection = makeInspection(componentSizes: [239, 2, 2, 1, 1, 1, 1, 1, 1, 1])

        XCTAssertFalse(inspection.hasAcceptableDominantVerifiedComponent)
        XCTAssertTrue(inspection.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))
    }

    func testDominantComponentPoliciesRetainStrictAndCoverageBoundaries() {
        let singletonMinority = makeInspection(componentSizes: [54, 1, 1, 1, 1, 1, 1])
        XCTAssertTrue(singletonMinority.hasAcceptableDominantVerifiedComponent)
        XCTAssertTrue(singletonMinority.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let verifiedMinority = makeInspection(componentSizes: [54, 2, 1, 1, 1, 1])
        XCTAssertFalse(verifiedMinority.hasAcceptableDominantVerifiedComponent)
        XCTAssertFalse(verifiedMinority.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let verifiedMinorityAtQualityFloor = makeInspection(componentSizes: [57, 2, 1])
        XCTAssertTrue(verifiedMinorityAtQualityFloor.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let belowCoverage = makeInspection(componentSizes: [224, 26])
        XCTAssertFalse(belowCoverage.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let tiedLargest = makeInspection(componentSizes: [125, 125])
        XCTAssertFalse(tiedLargest.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))
    }

    func testDominantComponentPolicyRejectsScalarSnapshotDisagreement() {
        let valid = makeInspection(componentSizes: [9, 1])
        XCTAssertTrue(valid.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let wrongComponentCount = makeInspection(
            componentSizes: [9, 1],
            connectedComponentCount: 3
        )
        XCTAssertFalse(wrongComponentCount.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let wrongIsolatedCount = makeInspection(
            componentSizes: [9, 1],
            isolatedViewCount: 0
        )
        XCTAssertFalse(wrongIsolatedCount.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let wrongVerifiedPairCount = makeInspection(
            componentSizes: [9, 1],
            spatiallyVerifiedPairCount: 9
        )
        XCTAssertFalse(wrongVerifiedPairCount.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))
    }

    func testDominantComponentPolicyRejectsMalformedNamesAndEdges() {
        let duplicateName = makeInspection(components: [
            ["image-1.jpg", "image-2.jpg"],
            ["image-2.jpg"],
        ])
        XCTAssertFalse(duplicateName.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let crossComponentEdge = makeInspection(
            components: [
                (1...9).map(imageName),
                [imageName(10)],
            ],
            verifiedPairs: [
                ColmapScheduledPair(imageName(1), imageName(10), role: .local),
            ]
        )
        XCTAssertFalse(crossComponentEdge.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let disconnectedSnapshotComponent = makeInspection(
            components: [
                (1...9).map(imageName),
                [imageName(10)],
            ],
            verifiedPairs: []
        )
        XCTAssertFalse(disconnectedSnapshotComponent.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))
    }

    func testDominantComponentPolicyRequiresDescriptorlessViewsToBeExcludedSingletons() {
        let descriptorlessSingleton = makeInspection(
            componentSizes: [9, 1],
            descriptorlessImageNames: [imageName(10)]
        )
        XCTAssertTrue(descriptorlessSingleton.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let descriptorlessViewWithEdges = makeInspection(
            componentSizes: [9, 1],
            descriptorlessImageNames: [imageName(1)]
        )
        XCTAssertFalse(descriptorlessViewWithEdges.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))

        let unknownDescriptorlessView = makeInspection(
            componentSizes: [9, 1],
            descriptorlessImageNames: ["unknown.jpg"]
        )
        XCTAssertFalse(unknownDescriptorlessView.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))
    }

    func testRejectsSymlinkDatabaseWithoutReadingItsTarget() throws {
        let externalDatabase = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let databaseURL = externalDatabase
            .deletingLastPathComponent()
            .appendingPathComponent("linked.db")
        try FileManager.default.createSymbolicLink(
            at: databaseURL,
            withDestinationURL: externalDatabase
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? ColmapPairGraphInspectorError, .unsafeDatabaseFile)
        }
    }

    func testRejectsHardLinkedDatabaseWithoutReadingItsTarget() throws {
        let externalDatabase = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let databaseURL = externalDatabase
            .deletingLastPathComponent()
            .appendingPathComponent("linked.db")
        try FileManager.default.linkItem(at: externalDatabase, to: databaseURL)

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? ColmapPairGraphInspectorError, .unsafeDatabaseFile)
        }
    }

    func testRejectsDatabaseReachedThroughSymlinkedImmediateParent() throws {
        let externalDatabase = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let directory = externalDatabase.deletingLastPathComponent()
        let linkedParent = directory.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: directory
        )
        let databaseURL = linkedParent.appendingPathComponent(externalDatabase.lastPathComponent)

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? ColmapPairGraphInspectorError, .unsafeDatabaseFile)
        }
    }

    func testInspectsCompleteSuccessfulAttemptAndBindsDatabasePayloads() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [2, 7, 11, 20],
            matches: [
                (pairID(2, 7), 20),
                (pairID(7, 11), 22),
                (pairID(11, 20), 0),
                (pairID(2, 20), 9),
            ],
            verified: [
                (pairID(2, 7), 15),
                (pairID(7, 11), 16),
                (pairID(11, 20), 0),
                (pairID(2, 20), 0),
            ]
        )
        let schedule = makeSchedule(
            imageIDs: [2, 7, 11, 20],
            pairs: [
                (2, 7, .local),
                (7, 11, .retrieval),
                (11, 20, .loopRevisit),
                (2, 20, .retrieval),
            ]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.scheduledPairCount, 4)
        XCTAssertEqual(result.attemptedPairCount, 4)
        XCTAssertEqual(result.rawMatchedPairCount, 3)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 2)
        XCTAssertEqual(result.localPairCount, 1)
        XCTAssertEqual(result.retrievalPairCount, 2)
        XCTAssertEqual(result.loopRevisitPairCount, 1)
        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 1)
        XCTAssertEqual(result.degreeP10, 0)
        XCTAssertEqual(result.degreeMedian, 1)
        XCTAssertEqual(result.degreeP90, 2)
        XCTAssertEqual(result.articulationViewCount, 1)
        XCTAssertEqual(result.biconnectedBlockCount, 2)
        XCTAssertEqual(result.largestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(result.secondLargestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(result.featureDatabaseDigest.count, 64)
        XCTAssertEqual(result.matchingDatabaseDigest.count, 64)
        XCTAssertEqual(result.attemptedPairs, schedule.pairs)
        XCTAssertEqual(result.rawMatchedPairs, [
            ColmapScheduledPair(imageName(2), imageName(7), role: .local),
            ColmapScheduledPair(imageName(7), imageName(11), role: .retrieval),
            ColmapScheduledPair(imageName(2), imageName(20), role: .retrieval),
        ])
        XCTAssertEqual(result.verifiedGraph.verifiedPairs, [
            ColmapScheduledPair(imageName(2), imageName(7), role: .local),
            ColmapScheduledPair(imageName(7), imageName(11), role: .retrieval),
        ])
        XCTAssertEqual(result.verifiedGraph.components, [
            [imageName(2), imageName(7), imageName(11)],
            [imageName(20)],
        ])
    }

    func testMeasuresBiconnectedRobustnessAcrossGraphShapes() throws {
        struct GraphCase {
            let name: String
            let imageIDs: [Int]
            let edges: [(Int, Int)]
            let articulationViews: Int
            let blockSizes: [Int]
        }
        let cases = [
            GraphCase(
                name: "line",
                imageIDs: [1, 2, 3, 4],
                edges: [(1, 2), (2, 3), (3, 4)],
                articulationViews: 2,
                blockSizes: [2, 2, 2]
            ),
            GraphCase(
                name: "cycle",
                imageIDs: [1, 2, 3, 4],
                edges: [(1, 2), (2, 3), (3, 4), (1, 4)],
                articulationViews: 0,
                blockSizes: [4]
            ),
            GraphCase(
                name: "bow tie",
                imageIDs: [1, 2, 3, 4, 5],
                edges: [(1, 2), (2, 3), (1, 3), (3, 4), (4, 5), (3, 5)],
                articulationViews: 1,
                blockSizes: [3, 3]
            ),
        ]

        for graphCase in cases {
            let rows = graphCase.edges.map { edge in
                (pairID(edge.0, edge.1), Int64(20))
            }
            let databaseURL = try makeDatabase(
                imageIDs: graphCase.imageIDs,
                matches: rows,
                verified: rows
            )
            let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: makeSchedule(
                    imageIDs: graphCase.imageIDs,
                    pairs: graphCase.edges.map { ($0.0, $0.1, .local) }
                ),
                completion: .succeeded
            )

            XCTAssertEqual(
                result.articulationViewCount,
                graphCase.articulationViews,
                graphCase.name
            )
            XCTAssertEqual(
                result.biconnectedBlockCount,
                graphCase.blockSizes.count,
                graphCase.name
            )
            XCTAssertEqual(
                result.largestBiconnectedBlockViewCount,
                graphCase.blockSizes.first ?? 0,
                graphCase.name
            )
            XCTAssertEqual(
                result.secondLargestBiconnectedBlockViewCount,
                graphCase.blockSizes.dropFirst().first ?? 0,
                graphCase.name
            )
        }
    }

    func testBiconnectedRobustnessExcludesDescriptorlessSingletons() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3, 4],
            descriptorRecords: [(1, 64), (2, 64), (3, 64), (4, 0)],
            matches: [
                (pairID(1, 2), 20),
                (pairID(2, 3), 20),
                (pairID(3, 4), 0),
            ],
            verified: [
                (pairID(1, 2), 20),
                (pairID(2, 3), 20),
                (pairID(3, 4), 0),
            ]
        )
        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: makeSchedule(
                imageIDs: [1, 2, 3, 4],
                pairs: [(1, 2, .local), (2, 3, .local), (3, 4, .local)]
            ),
            completion: .succeeded
        )

        XCTAssertEqual(result.descriptorlessImageNames, [imageName(4)])
        XCTAssertEqual(result.articulationViewCount, 1)
        XCTAssertEqual(result.biconnectedBlockCount, 2)
        XCTAssertEqual(result.largestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(result.secondLargestBiconnectedBlockViewCount, 2)
    }

    func testBiconnectedRobustnessDescribesTheDominantAcceptedComponent() throws {
        let dominantCycle = (1..<38).map { ($0, $0 + 1, ColmapPairRole.local) }
            + [(1, 38, .local)]
        let minorEdge = [(39, 40, ColmapPairRole.local)]
        let pairs = dominantCycle + minorEdge
        let rows = pairs.map { (pairID($0.0, $0.1), Int64(20)) }
        let databaseURL = try makeDatabase(
            imageIDs: Array(1...40),
            matches: rows,
            verified: rows
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: makeSchedule(imageIDs: Array(1...40), pairs: pairs),
            completion: .succeeded
        )

        XCTAssertTrue(result.hasAcceptableDominantVerifiedComponent(
            allowMinorVerifiedComponents: true
        ))
        XCTAssertEqual(result.articulationViewCount, 0)
        XCTAssertEqual(result.biconnectedBlockCount, 1)
        XCTAssertEqual(result.largestBiconnectedBlockViewCount, 38)
        XCTAssertEqual(result.secondLargestBiconnectedBlockViewCount, 0)
    }

    func testSparseGraphsHaveTotalBiconnectedMeasurements() throws {
        let noDescriptorDatabase = try makeDatabase(
            imageIDs: [1, 2],
            descriptorRecords: [(1, 0), (2, 0)],
            matches: [],
            verified: []
        )
        let noDescriptors = try ColmapPairGraphInspector(
            databaseURL: noDescriptorDatabase
        ).inspect(
            schedule: makeSchedule(imageIDs: [1, 2], pairs: []),
            completion: .succeeded
        )
        XCTAssertEqual(noDescriptors.articulationViewCount, 0)
        XCTAssertEqual(noDescriptors.biconnectedBlockCount, 0)
        XCTAssertEqual(noDescriptors.largestBiconnectedBlockViewCount, 0)
        XCTAssertEqual(noDescriptors.secondLargestBiconnectedBlockViewCount, 0)

        let oneDescriptorDatabase = try makeDatabase(
            imageIDs: [1, 2],
            descriptorRecords: [(1, 64), (2, 0)],
            matches: [],
            verified: []
        )
        let oneDescriptor = try ColmapPairGraphInspector(
            databaseURL: oneDescriptorDatabase
        ).inspect(
            schedule: makeSchedule(imageIDs: [1, 2], pairs: []),
            completion: .succeeded
        )
        XCTAssertEqual(oneDescriptor.articulationViewCount, 0)
        XCTAssertEqual(oneDescriptor.biconnectedBlockCount, 0)
        XCTAssertEqual(oneDescriptor.largestBiconnectedBlockViewCount, 0)
        XCTAssertEqual(oneDescriptor.secondLargestBiconnectedBlockViewCount, 0)

        let singleEdgeDatabase = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 20)],
            verified: [(pairID(1, 2), 20)]
        )
        let singleEdge = try ColmapPairGraphInspector(
            databaseURL: singleEdgeDatabase
        ).inspect(
            schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
            completion: .succeeded
        )
        XCTAssertEqual(singleEdge.articulationViewCount, 0)
        XCTAssertEqual(singleEdge.biconnectedBlockCount, 1)
        XCTAssertEqual(singleEdge.largestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(singleEdge.secondLargestBiconnectedBlockViewCount, 0)
    }

    func testBiconnectedAnalysisUsesAnIterativeTraversalForLongPaths() throws {
        let imageIDs = Array(1...3_000)
        let edges = imageIDs.dropLast().map { ($0, $0 + 1) }
        let rows = edges.map { (pairID($0.0, $0.1), Int64(20)) }
        let databaseURL = try makeDatabase(
            imageIDs: imageIDs,
            matches: rows,
            verified: rows
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: makeSchedule(
                imageIDs: imageIDs,
                pairs: edges.map { ($0.0, $0.1, .local) }
            ),
            completion: .succeeded
        )

        XCTAssertEqual(result.articulationViewCount, 2_998)
        XCTAssertEqual(result.biconnectedBlockCount, 2_999)
        XCTAssertEqual(result.largestBiconnectedBlockViewCount, 2)
        XCTAssertEqual(result.secondLargestBiconnectedBlockViewCount, 2)
    }

    func testZeroRowPairsAreAttemptedButNotMatchedOrVerified() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [3, 9],
            matches: [(pairID(3, 9), 0)],
            verified: [(pairID(3, 9), 0)]
        )
        let schedule = makeSchedule(imageIDs: [3, 9], pairs: [(3, 9, .local)])

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.attemptedPairCount, 1)
        XCTAssertEqual(result.rawMatchedPairCount, 0)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 0)
        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 2)
        XCTAssertEqual(result.degreeP10, 0)
        XCTAssertEqual(result.degreeMedian, 0)
        XCTAssertEqual(result.degreeP90, 0)
        XCTAssertTrue(result.verifiedGraph.verifiedPairs.isEmpty)
        XCTAssertEqual(result.verifiedGraph.components, [
            [imageName(3)],
            [imageName(9)],
        ])
    }

    func testPairBelowMapperInlierFloorDoesNotConnectGraph() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [3, 9],
            matches: [(pairID(3, 9), 30)],
            verified: [(pairID(3, 9), 14)]
        )
        let schedule = makeSchedule(imageIDs: [3, 9], pairs: [(3, 9, .local)])

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.spatiallyVerifiedPairCount, 0)
        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 2)
        XCTAssertTrue(result.verifiedGraph.verifiedPairs.isEmpty)
    }

    func testRejectsDescriptorlessSingletonWhenDominantCoverageIsBelowNinetyPercent() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            descriptorRecords: [(1, 64), (2, 64), (3, 0)],
            matches: [(pairID(1, 2), 30), (pairID(2, 3), 0)],
            verified: [(pairID(1, 2), 20), (pairID(2, 3), 0)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 1)
        XCTAssertEqual(result.descriptorlessImageNames, [imageName(3)])
        XCTAssertFalse(result.hasAcceptableDominantVerifiedComponent)
    }

    func testDescriptorBearingSingletonRemainsDisconnected() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 30), (pairID(2, 3), 0)],
            verified: [(pairID(1, 2), 20), (pairID(2, 3), 0)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertTrue(result.descriptorlessImageNames.isEmpty)
        XCTAssertFalse(result.hasAcceptableDominantVerifiedComponent)
    }

    func testDescriptorlessSingletonDoesNotExcuseTwoDescriptorBearingComponents() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3, 4, 5],
            descriptorRecords: [(1, 64), (2, 64), (3, 64), (4, 64), (5, 0)],
            matches: [
                (pairID(1, 2), 30),
                (pairID(2, 3), 0),
                (pairID(3, 4), 30),
                (pairID(4, 5), 0),
            ],
            verified: [
                (pairID(1, 2), 20),
                (pairID(2, 3), 0),
                (pairID(3, 4), 20),
                (pairID(4, 5), 0),
            ]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3, 4, 5],
            pairs: [
                (1, 2, .local),
                (2, 3, .local),
                (3, 4, .local),
                (4, 5, .local),
            ]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.descriptorlessImageNames, [imageName(5)])
        XCTAssertEqual(result.connectedComponentCount, 3)
        XCTAssertFalse(result.hasAcceptableDominantVerifiedComponent)
    }

    func testRejectsMissingDuplicateNullAndNegativeDescriptorRows() throws {
        let invalidRecords: [[(Int, Int64?)]] = [
            [(1, 64)],
            [(1, 64), (1, 64), (2, 64)],
            [(1, 64), (2, nil)],
            [(1, 64), (2, -1)],
        ]

        for records in invalidRecords {
            let databaseURL = try makeDatabase(
                imageIDs: [1, 2],
                descriptorRecords: records,
                descriptorImageIDIsPrimaryKey: false,
                matches: [(pairID(1, 2), 0)],
                verified: [(pairID(1, 2), 0)]
            )

            XCTAssertThrowsError(
                try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                    schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                    completion: .succeeded
                )
            ) { error in
                guard case .malformedSchema(let table, _) = error as? ColmapPairGraphInspectorError else {
                    return XCTFail("Expected malformed descriptor evidence, got \(error)")
                }
                XCTAssertEqual(table, "descriptors")
            }
        }
    }

    func testRejectsPositiveCorrespondencesForDescriptorlessImage() throws {
        for table in ["matches", "two_view_geometries"] {
            let rawRows: Int64 = table == "matches" ? 20 : 0
            let verifiedRows: Int64 = table == "two_view_geometries" ? 20 : 0
            let databaseURL = try makeDatabase(
                imageIDs: [1, 2],
                descriptorRecords: [(1, 64), (2, 0)],
                matches: [(pairID(1, 2), rawRows)],
                verified: [(pairID(1, 2), verifiedRows)]
            )

            XCTAssertThrowsError(
                try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                    schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                    completion: .succeeded
                )
            ) { error in
                XCTAssertEqual(
                    error as? ColmapPairGraphInspectorError,
                    .descriptorlessImageHasCorrespondences(
                        table: table,
                        pairID: pairID(1, 2)
                    )
                )
            }
        }
    }

    func testNoncontiguousPositiveImageIDsAreSupported() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 41, 10_003],
            matches: [(pairID(1, 10_003), 20)],
            verified: [(pairID(1, 10_003), 15)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 41, 10_003],
            pairs: [(10_003, 1, .retrieval)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 1)
        XCTAssertEqual(result.verifiedGraph.verifiedPairs, [
            ColmapScheduledPair(imageName(10_003), imageName(1), role: .retrieval),
        ])
        XCTAssertEqual(result.verifiedGraph.components, [
            [imageName(1), imageName(10_003)],
            [imageName(41)],
        ])
    }

    func testVerifiedGraphSnapshotIsIndependentOfDatabaseRowOrder() throws {
        let imageIDs = [40, 3, 900, 12, 77]
        let scheduledPairs: [(Int, Int, ColmapPairRole)] = [
            (40, 3, .local),
            (900, 12, .retrieval),
            (12, 77, .loopRevisit),
            (3, 900, .retrieval),
        ]
        let matches: [(Int64, Int64)] = [
            (pairID(3, 40), 20),
            (pairID(12, 900), 20),
            (pairID(12, 77), 0),
            (pairID(3, 900), 0),
        ]
        let verified: [(Int64, Int64)] = [
            (pairID(3, 40), 15),
            (pairID(12, 900), 16),
            (pairID(12, 77), 0),
            (pairID(3, 900), 0),
        ]
        let schedule = makeSchedule(imageIDs: imageIDs, pairs: scheduledPairs)
        let firstDatabase = try makeDatabase(
            imageIDs: imageIDs,
            matches: matches,
            verified: verified
        )
        let secondDatabase = try makeDatabase(
            imageIDs: imageIDs.reversed(),
            matches: matches.reversed(),
            verified: verified.reversed()
        )

        let first = try ColmapPairGraphInspector(databaseURL: firstDatabase).inspect(
            schedule: schedule,
            completion: .succeeded
        )
        let second = try ColmapPairGraphInspector(databaseURL: secondDatabase).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(first.verifiedGraph, second.verifiedGraph)
        XCTAssertEqual(first.articulationViewCount, second.articulationViewCount)
        XCTAssertEqual(first.biconnectedBlockCount, second.biconnectedBlockCount)
        XCTAssertEqual(
            first.largestBiconnectedBlockViewCount,
            second.largestBiconnectedBlockViewCount
        )
        XCTAssertEqual(
            first.secondLargestBiconnectedBlockViewCount,
            second.secondLargestBiconnectedBlockViewCount
        )
        XCTAssertEqual(first.verifiedGraph.verifiedPairs, [
            ColmapScheduledPair(imageName(40), imageName(3), role: .local),
            ColmapScheduledPair(imageName(900), imageName(12), role: .retrieval),
        ])
        XCTAssertEqual(first.verifiedGraph.components, [
            [imageName(40), imageName(3)],
            [imageName(900), imageName(12)],
            [imageName(77)],
        ])
    }

    func testSupportsZeroAndNoncontiguousImageIDs() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [0, 5, 91],
            matches: [(pairID(0, 5), 20)],
            verified: [(pairID(0, 5), 15)]
        )
        let schedule = makeSchedule(imageIDs: [0, 5], pairs: [(0, 5, .local)])
        let completeSchedule = ColmapPairSchedule(
            imageNames: [imageName(0), imageName(5), imageName(91)],
            pairs: schedule.pairs
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: completeSchedule,
            completion: .failed
        )

        XCTAssertEqual(result.spatiallyVerifiedPairCount, 1)
        XCTAssertEqual(result.isolatedViewCount, 1)
    }

    func testSuccessfulAttemptRequiresEveryScheduledPairInBothTables() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 20)],
            verified: [(pairID(1, 2), 15)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .incompleteSuccessfulAttempt(
                    table: "matches",
                    missingPairIDs: [pairID(2, 3)]
                )
            )
        }
    }

    func testFailedAttemptAcceptsAValidPartialSchedule() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 20)],
            verified: [(pairID(1, 2), 15)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .failed
        )

        XCTAssertEqual(result.scheduledPairCount, 2)
        XCTAssertEqual(result.attemptedPairCount, 1)
        XCTAssertEqual(result.rawMatchedPairCount, 1)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 1)
        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 1)
    }

    func testFailedAttemptCountsTheUnionOfBothResultTables() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(2, 3), 0)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .failed
        )

        XCTAssertEqual(result.attemptedPairCount, 2)
        XCTAssertEqual(result.rawMatchedPairCount, 1)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 0)
    }

    func testSuccessfulAttemptAlsoRequiresCompleteVerifiedTable() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 5), (pairID(2, 3), 0)],
            verified: [(pairID(1, 2), 3)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .incompleteSuccessfulAttempt(
                    table: "two_view_geometries",
                    missingPairIDs: [pairID(2, 3)]
                )
            )
        }
    }

    func testRejectsDatabaseImageSetMismatch() throws {
        let databaseURL = try makeDatabase(imageIDs: [1, 2, 4], matches: [], verified: [])
        let schedule = makeSchedule(imageIDs: [1, 2, 3], pairs: [])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .imageSetMismatch(
                    expected: [imageName(1), imageName(2), imageName(3)],
                    actual: [imageName(1), imageName(2), imageName(4)]
                )
            )
        }
    }

    func testRejectsDuplicateDatabaseImageIDWithoutTrapping() throws {
        let databaseURL = try makeDuplicateImageIDDatabase()
        let schedule = ColmapPairSchedule(
            imageNames: ["a.jpg", "b.jpg"],
            pairs: []
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .duplicateDatabaseImageID(1)
            )
        }
    }

    func testRejectsPairOutsideSchedule() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 3), 4)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2, 3], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .pairOutsideSchedule(table: "matches", pairID: pairID(1, 3))
            )
        }
    }

    func testRejectsPairContainingUnknownImage() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 99), 4)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .unknownImageID(table: "matches", pairID: pairID(1, 99), imageID: 99)
            )
        }
    }

    func testRejectsInvalidEncodedPairID() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(0, 4)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .invalidPairID(table: "matches", pairID: 0)
            )
        }
    }

    func testRejectsNegativeRowCount() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), -1)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .negativeRows(table: "matches", pairID: pairID(1, 2), rows: -1)
            )
        }
    }

    func testRejectsVerifiedRowsGreaterThanRawRows() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 3)],
            verified: [(pairID(1, 2), 4)]
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .verifiedRowsExceedRaw(pairID: pairID(1, 2), verifiedRows: 4, rawRows: 3)
            )
        }
    }

    func testRejectsMalformedMatchSchema() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [],
            verified: [],
            matchesHasRowsColumn: false
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            guard case .malformedSchema(let table, _) = error as? ColmapPairGraphInspectorError else {
                return XCTFail("Expected malformed schema, got \(error)")
            }
            XCTAssertEqual(table, "matches")
        }
    }

    func testRejectsDuplicateScheduledPair() throws {
        let databaseURL = try makeDatabase(imageIDs: [1, 2], matches: [], verified: [])
        let schedule = makeSchedule(
            imageIDs: [1, 2],
            pairs: [(1, 2, .local), (2, 1, .retrieval)]
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .duplicateScheduledPair(imageName(1), imageName(2))
            )
        }
    }

    func testCancellationIsCheckedBeforeDatabaseInspection() async throws {
        let databaseURL = try makeDatabase(imageIDs: [1, 2], matches: [], verified: [])
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func pairID(_ first: Int, _ second: Int) -> Int64 {
        let low = Int64(min(first, second))
        let high = Int64(max(first, second))
        return low * ColmapPairGraphInspector.pairIDDivisor + high
    }

    private func imageName(_ imageID: Int) -> String {
        "image-\(imageID).jpg"
    }

    private func makeSchedule(
        imageIDs: [Int],
        pairs: [(Int, Int, ColmapPairRole)]
    ) -> ColmapPairSchedule {
        ColmapPairSchedule(
            imageNames: imageIDs.map(imageName),
            pairs: pairs.map { first, second, role in
                ColmapScheduledPair(imageName(first), imageName(second), role: role)
            }
        )
    }

    private func makeInspection(
        componentSizes: [Int],
        descriptorlessImageNames: [String] = [],
        connectedComponentCount: Int? = nil,
        isolatedViewCount: Int? = nil,
        spatiallyVerifiedPairCount: Int? = nil
    ) -> ColmapPairGraphInspection {
        var nextImageID = 1
        let components = componentSizes.map { componentSize in
            defer { nextImageID += componentSize }
            return (nextImageID..<(nextImageID + componentSize)).map(imageName)
        }
        return makeInspection(
            components: components,
            descriptorlessImageNames: descriptorlessImageNames,
            connectedComponentCount: connectedComponentCount,
            isolatedViewCount: isolatedViewCount,
            spatiallyVerifiedPairCount: spatiallyVerifiedPairCount
        )
    }

    private func makeInspection(
        components: [[String]],
        verifiedPairs: [ColmapScheduledPair]? = nil,
        descriptorlessImageNames: [String] = [],
        connectedComponentCount: Int? = nil,
        isolatedViewCount: Int? = nil,
        spatiallyVerifiedPairCount: Int? = nil
    ) -> ColmapPairGraphInspection {
        let defaultVerifiedPairs = components.flatMap { component in
            zip(component, component.dropFirst()).map { first, second in
                ColmapScheduledPair(first, second, role: .local)
            }
        }
        let snapshotPairs = verifiedPairs ?? defaultVerifiedPairs
        return ColmapPairGraphInspection(
            scheduledPairCount: snapshotPairs.count,
            attemptedPairCount: snapshotPairs.count,
            rawMatchedPairCount: snapshotPairs.count,
            spatiallyVerifiedPairCount: spatiallyVerifiedPairCount ?? snapshotPairs.count,
            localPairCount: snapshotPairs.count,
            retrievalPairCount: 0,
            loopRevisitPairCount: 0,
            connectedComponentCount: connectedComponentCount ?? components.count,
            isolatedViewCount: isolatedViewCount
                ?? components.count(where: { $0.count == 1 }),
            articulationViewCount: 0,
            biconnectedBlockCount: 0,
            largestBiconnectedBlockViewCount: 0,
            secondLargestBiconnectedBlockViewCount: 0,
            degreeP10: 0,
            degreeMedian: 0,
            degreeP90: 0,
            featureDatabaseDigest: String(repeating: "0", count: 64),
            matchingDatabaseDigest: String(repeating: "1", count: 64),
            descriptorlessImageNames: descriptorlessImageNames,
            verifiedGraph: ColmapVerifiedGraphSnapshot(
                verifiedPairs: snapshotPairs,
                components: components
            )
        )
    }

    private func makeDatabase(
        imageIDs: [Int],
        descriptorRecords: [(Int, Int64?)]? = nil,
        descriptorImageIDIsPrimaryKey: Bool = true,
        matches: [(Int64, Int64)],
        verified: [(Int64, Int64)],
        matchesHasRowsColumn: Bool = true
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("database.db")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "ColmapPairGraphInspectorTests", code: 1)
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
            "CREATE TABLE descriptors(image_id INTEGER\(descriptorImageIDIsPrimaryKey ? " PRIMARY KEY" : ""), rows INTEGER, cols INTEGER, data BLOB);"
        )
        if matchesHasRowsColumn {
            try execute(
                database,
                "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
            )
        } else {
            try execute(database, "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, data BLOB);")
        }
        try execute(
            database,
            "CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )

        try execute(database, "BEGIN IMMEDIATE TRANSACTION;")
        try execute(database, "INSERT INTO cameras(camera_id) VALUES (1);")
        for imageID in imageIDs {
            try execute(
                database,
                "INSERT INTO images(image_id, name, camera_id) VALUES (\(imageID), '\(imageName(imageID))', 1);"
            )
            try execute(
                database,
                "INSERT INTO keypoints(image_id, rows, cols, data) VALUES (\(imageID), 1, 4, X'00');"
            )
        }
        for (imageID, rows) in descriptorRecords ?? imageIDs.map({ ($0, Int64(1)) }) {
            let rowsSQL = rows.map(String.init) ?? "NULL"
            try execute(
                database,
                "INSERT INTO descriptors(image_id, rows, cols, data) VALUES (\(imageID), \(rowsSQL), 128, X'00');"
            )
        }
        guard matchesHasRowsColumn else {
            try execute(database, "COMMIT;")
            return databaseURL
        }

        for (encodedPair, rows) in matches {
            try execute(
                database,
                "INSERT INTO matches(pair_id, rows, cols, data) VALUES (\(encodedPair), \(rows), 2, X'00');"
            )
        }
        for (encodedPair, rows) in verified {
            try execute(
                database,
                "INSERT INTO two_view_geometries(pair_id, rows, cols, data) VALUES (\(encodedPair), \(rows), 2, X'00');"
            )
        }
        try execute(database, "COMMIT;")
        return databaseURL
    }

    private func makeDuplicateImageIDDatabase() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("database.db")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "ColmapPairGraphInspectorTests", code: 1)
        }
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE images(image_id INTEGER, name TEXT);")
        try execute(database, "CREATE TABLE matches(pair_id INTEGER, rows INTEGER);")
        try execute(database, "CREATE TABLE two_view_geometries(pair_id INTEGER, rows INTEGER);")
        try execute(database, "INSERT INTO images(image_id, name) VALUES (1, 'a.jpg');")
        try execute(database, "INSERT INTO images(image_id, name) VALUES (1, 'b.jpg');")
        return databaseURL
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail =
                message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw NSError(
                domain: "ColmapPairGraphInspectorTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
#endif
