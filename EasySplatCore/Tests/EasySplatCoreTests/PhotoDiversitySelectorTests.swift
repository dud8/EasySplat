import Foundation
import XCTest
@testable import EasySplatCore

final class PhotoDiversitySelectorTests: XCTestCase {
    func testRankingIsIndependentOfInputOrder() throws {
        let candidates = [
            evidence(1, quality: 220, descriptor: descriptor(0)),
            evidence(2, quality: 190, descriptor: descriptor(64)),
            evidence(3, quality: 180, descriptor: descriptor(128)),
            evidence(4, quality: 170, descriptor: descriptor(255)),
        ]
        let expected = try PhotoDiversitySelector.rank(candidates, targetCount: 4)

        for permutation in permutations(of: candidates) {
            XCTAssertEqual(
                try PhotoDiversitySelector.rank(permutation, targetCount: 4),
                expected
            )
        }
    }

    func testVisualDistanceWinsAcrossQualityEquivalenceBins() throws {
        let anchor = evidence(1, quality: 255, descriptor: descriptor(0))
        let farther = evidence(
            2,
            quality: 0,
            descriptor: descriptor(changing: 0, to: 128)
        )
        let sharper = evidence(
            3,
            quality: 254,
            descriptor: descriptor(changing: 0, to: 127)
        )

        let ranked = try PhotoDiversitySelector.rank(
            [sharper, farther, anchor],
            targetCount: 2
        )

        XCTAssertEqual(
            ranked.map(\.sourceSHA256),
            [anchor.sourceSHA256, farther.sourceSHA256]
        )
    }

    func testQuantizedQualityBreaksOnlyNarrowEquivalentDistanceTies() throws {
        let anchor = evidence(1, quality: 255, descriptor: descriptor(0))
        let visuallyFarther = evidence(
            2,
            quality: 0,
            descriptor: descriptor(changing: 0, to: 127)
        )
        let sharper = evidence(
            3,
            quality: 200,
            descriptor: descriptor(changing: 0, to: 65)
        )

        let ranked = try PhotoDiversitySelector.rank(
            [visuallyFarther, sharper, anchor],
            targetCount: 2
        )

        XCTAssertEqual(
            ranked.map(\.sourceSHA256),
            [anchor.sourceSHA256, sharper.sourceSHA256]
        )
    }

    func testSHA256IsTheFinalTieBreak() throws {
        let anchor = evidence(1, quality: 255, descriptor: descriptor(0))
        let lowerSHA = evidence(2, quality: 100, descriptor: descriptor(255))
        let higherSHA = evidence(3, quality: 100, descriptor: descriptor(255))

        let ranked = try PhotoDiversitySelector.rank(
            [higherSHA, anchor, lowerSHA],
            targetCount: 2
        )

        XCTAssertEqual(
            ranked.map(\.sourceSHA256),
            [anchor.sourceSHA256, lowerSHA.sourceSHA256]
        )
    }

    func testUniqueSoftBridgeIsNotDisplacedBySharpDuplicateBurst() throws {
        let burstAnchor = evidence(1, quality: 255, descriptor: descriptor(24))
        let burstTwo = evidence(
            2,
            quality: 254,
            descriptor: descriptor(changing: 0, from: 24, to: 25)
        )
        let burstThree = evidence(
            3,
            quality: 253,
            descriptor: descriptor(changing: 1, from: 24, to: 26)
        )
        let softBridge = evidence(4, quality: 0, descriptor: descriptor(220))

        let ranked = try PhotoDiversitySelector.rank(
            [burstThree, softBridge, burstTwo, burstAnchor],
            targetCount: 2
        )

        XCTAssertEqual(
            ranked.map(\.sourceSHA256),
            [burstAnchor.sourceSHA256, softBridge.sourceSHA256]
        )
    }

    func testSpatialEvidenceDistinguishesPhotosWithIdenticalLegacyDHash() throws {
        let legacyDHash: UInt64 = 0xA5A5_A5A5_A5A5_A5A5
        let anchor = evidence(
            1,
            quality: 255,
            descriptor: descriptor(0),
            dHash: legacyDHash
        )
        let duplicateLike = evidence(
            2,
            quality: 254,
            descriptor: descriptor(changing: 0, to: 1),
            dHash: legacyDHash
        )
        let spatiallyDistinct = evidence(
            3,
            quality: 0,
            descriptor: descriptor(255),
            dHash: legacyDHash
        )

        let ranked = try PhotoDiversitySelector.rank(
            [duplicateLike, spatiallyDistinct, anchor],
            targetCount: 2
        )

        XCTAssertEqual(
            ranked.map(\.sourceSHA256),
            [anchor.sourceSHA256, spatiallyDistinct.sourceSHA256]
        )
    }

    func testEveryTargetIsAPrefixOfTheFullRanking() throws {
        let candidates = (1...12).map { index in
            evidence(
                index,
                quality: UInt8(255 - index),
                descriptor: (0..<PhotoAnalysisEvidence.spatialDescriptorLength).map { offset in
                    UInt8(truncatingIfNeeded: index * 37 + offset * 19)
                }
            )
        }
        let full = try PhotoDiversitySelector.rank(candidates, targetCount: candidates.count)

        for target in 0...candidates.count {
            XCTAssertEqual(
                try PhotoDiversitySelector.rank(candidates, targetCount: target),
                Array(full.prefix(target))
            )
        }
    }

    func testTargetCountIsClampedToAvailableEvidence() throws {
        let candidates = [
            evidence(1, quality: 255, descriptor: descriptor(0)),
            evidence(2, quality: 100, descriptor: descriptor(128)),
            evidence(3, quality: 0, descriptor: descriptor(255)),
        ]

        XCTAssertEqual(
            try PhotoDiversitySelector.rank(candidates, targetCount: 0),
            []
        )
        XCTAssertEqual(
            try PhotoDiversitySelector.rank(candidates, targetCount: 1).count,
            1
        )
        XCTAssertEqual(
            try PhotoDiversitySelector.rank(candidates, targetCount: candidates.count).count,
            candidates.count
        )
        XCTAssertEqual(
            try PhotoDiversitySelector.rank(candidates, targetCount: candidates.count + 1).count,
            candidates.count
        )
    }

    func testRejectsNegativeTargetCount() {
        XCTAssertThrowsError(try PhotoDiversitySelector.rank([], targetCount: -1)) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .negativeTargetCount(-1)
            )
        }
    }

    func testRejectsMalformedAndUppercaseSHA256() {
        for invalid in ["not-a-digest", String(repeating: "A", count: 64)] {
            let candidate = PhotoAnalysisEvidence(
                sourceSHA256: invalid,
                spatialDescriptor: descriptor(0),
                qualityBucket: 0,
                dHash: 0,
                proxyPixelWidth: 8,
                proxyPixelHeight: 8,
                proxyPixelSHA256: sha256(101),
                analysisRecipeVersion: 1,
                analysisRecipeSHA256: recipeSHA256
            )

            XCTAssertThrowsError(
                try PhotoDiversitySelector.rank([candidate], targetCount: 0)
            ) { error in
                XCTAssertEqual(
                    error as? PhotoDiversitySelectorError,
                    .invalidSourceSHA256(invalid)
                )
            }
        }
    }

    func testRejectsDuplicateSHA256EvenWhenDescriptorsDiffer() {
        let first = evidence(1, quality: 255, descriptor: descriptor(0))
        let second = PhotoAnalysisEvidence(
            sourceSHA256: first.sourceSHA256,
            spatialDescriptor: descriptor(255),
            qualityBucket: 0,
            dHash: 42,
            proxyPixelWidth: 8,
            proxyPixelHeight: 8,
            proxyPixelSHA256: sha256(102),
            analysisRecipeVersion: 1,
            analysisRecipeSHA256: recipeSHA256
        )

        XCTAssertThrowsError(
            try PhotoDiversitySelector.rank([first, second], targetCount: 0)
        ) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .duplicateSourceSHA256(first.sourceSHA256)
            )
        }
    }

    func testRejectsWrongSpatialDescriptorLength() {
        let candidate = PhotoAnalysisEvidence(
            sourceSHA256: sha256(1),
            spatialDescriptor: [0, 1, 2],
            qualityBucket: 100,
            dHash: 0,
            proxyPixelWidth: 8,
            proxyPixelHeight: 8,
            proxyPixelSHA256: sha256(101),
            analysisRecipeVersion: 1,
            analysisRecipeSHA256: recipeSHA256
        )

        XCTAssertThrowsError(
            try PhotoDiversitySelector.rank([candidate], targetCount: 1)
        ) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .invalidSpatialDescriptorLength(
                    sourceSHA256: candidate.sourceSHA256,
                    actual: 3
                )
            )
        }
    }

    func testRejectsInvalidProxyAndRecipeEvidence() {
        let invalidProxyHash = PhotoAnalysisEvidence(
            sourceSHA256: sha256(1),
            spatialDescriptor: descriptor(0),
            qualityBucket: 100,
            dHash: 0,
            proxyPixelWidth: 8,
            proxyPixelHeight: 8,
            proxyPixelSHA256: "invalid",
            analysisRecipeVersion: 1,
            analysisRecipeSHA256: recipeSHA256
        )
        XCTAssertThrowsError(
            try PhotoDiversitySelector.rank([invalidProxyHash], targetCount: 1)
        ) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .invalidProxyPixelSHA256(sourceSHA256: invalidProxyHash.sourceSHA256)
            )
        }

        let invalidDimensions = PhotoAnalysisEvidence(
            sourceSHA256: sha256(2),
            spatialDescriptor: descriptor(0),
            qualityBucket: 100,
            dHash: 0,
            proxyPixelWidth: 0,
            proxyPixelHeight: 8,
            proxyPixelSHA256: sha256(102),
            analysisRecipeVersion: 1,
            analysisRecipeSHA256: recipeSHA256
        )
        XCTAssertThrowsError(
            try PhotoDiversitySelector.rank([invalidDimensions], targetCount: 1)
        ) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .invalidProxyDimensions(
                    sourceSHA256: invalidDimensions.sourceSHA256,
                    width: 0,
                    height: 8
                )
            )
        }

        let invalidRecipe = PhotoAnalysisEvidence(
            sourceSHA256: sha256(3),
            spatialDescriptor: descriptor(0),
            qualityBucket: 100,
            dHash: 0,
            proxyPixelWidth: 8,
            proxyPixelHeight: 8,
            proxyPixelSHA256: sha256(103),
            analysisRecipeVersion: 0,
            analysisRecipeSHA256: "invalid"
        )
        XCTAssertThrowsError(
            try PhotoDiversitySelector.rank([invalidRecipe], targetCount: 1)
        ) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .invalidAnalysisRecipeVersion(
                    sourceSHA256: invalidRecipe.sourceSHA256,
                    actual: 0
                )
            )
        }

        let invalidRecipeHash = PhotoAnalysisEvidence(
            sourceSHA256: sha256(4),
            spatialDescriptor: descriptor(0),
            qualityBucket: 100,
            dHash: 0,
            proxyPixelWidth: 8,
            proxyPixelHeight: 8,
            proxyPixelSHA256: sha256(104),
            analysisRecipeVersion: 1,
            analysisRecipeSHA256: "invalid"
        )
        XCTAssertThrowsError(
            try PhotoDiversitySelector.rank([invalidRecipeHash], targetCount: 1)
        ) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .invalidAnalysisRecipeSHA256(
                    sourceSHA256: invalidRecipeHash.sourceSHA256
                )
            )
        }
    }

    func testRejectsMixedAnalysisRecipesIndependentOfInputOrder() {
        let expected = evidence(1, quality: 100, descriptor: descriptor(0))
        let wrongVersion = evidence(
            2,
            quality: 100,
            descriptor: descriptor(128),
            analysisRecipeVersion: 2
        )
        for candidates in [[expected, wrongVersion], [wrongVersion, expected]] {
            XCTAssertThrowsError(
                try PhotoDiversitySelector.rank(candidates, targetCount: 2)
            ) { error in
                XCTAssertEqual(
                    error as? PhotoDiversitySelectorError,
                    .mixedAnalysisRecipeVersion(
                        expected: 1,
                        actual: 2,
                        sourceSHA256: wrongVersion.sourceSHA256
                    )
                )
            }
        }

        let wrongHash = evidence(
            3,
            quality: 100,
            descriptor: descriptor(255),
            analysisRecipeSHA256: String(repeating: "f", count: 64)
        )
        XCTAssertThrowsError(
            try PhotoDiversitySelector.rank([expected, wrongHash], targetCount: 2)
        ) { error in
            XCTAssertEqual(
                error as? PhotoDiversitySelectorError,
                .mixedAnalysisRecipeSHA256(
                    expected: recipeSHA256,
                    actual: wrongHash.analysisRecipeSHA256,
                    sourceSHA256: wrongHash.sourceSHA256
                )
            )
        }
    }

    func testSelectorPolicyIdentityIsStable() {
        XCTAssertEqual(PhotoDiversitySelector.selectorPolicyVersion, 1)
        XCTAssertEqual(
            PhotoDiversitySelector.selectorPolicySHA256,
            "946add648e84c7de840aa25ac94cb261366d67f599fb7aad245af92688754abf"
        )
    }

    func testEvidenceRoundTripsThroughCodable() throws {
        let original = evidence(
            7,
            quality: 173,
            descriptor: (0..<PhotoAnalysisEvidence.spatialDescriptorLength).map(UInt8.init),
            dHash: 0x1234_5678_9ABC_DEF0
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoAnalysisEvidence.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testCancellationIsPolledInsideRankingWork() {
        enum Stop: Error { case now }
        let candidates = (1...100).map { index in
            evidence(
                index,
                quality: UInt8(truncatingIfNeeded: index),
                descriptor: (0..<PhotoAnalysisEvidence.spatialDescriptorLength).map { offset in
                    UInt8(truncatingIfNeeded: index * 17 + offset * 13)
                }
            )
        }
        var checks = 0

        XCTAssertThrowsError(try PhotoDiversitySelector.rank(
            candidates,
            targetCount: 80,
            checkCancellation: {
                checks += 1
                if checks == 150 { throw Stop.now }
            }
        )) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(checks, 150)
    }

    func testRanksAProductionSizedInjectedEvidenceSet() throws {
        let candidates = (1...512).map { index in
            evidence(
                index,
                quality: UInt8(truncatingIfNeeded: index * 11),
                descriptor: (0..<PhotoAnalysisEvidence.spatialDescriptorLength).map { offset in
                    UInt8(truncatingIfNeeded: index * 31 + offset * 17)
                }
            )
        }
        var cancellationChecks = 0

        let ranked = try PhotoDiversitySelector.rank(
            candidates,
            targetCount: 250,
            checkCancellation: { cancellationChecks += 1 }
        )

        XCTAssertEqual(ranked.count, 250)
        XCTAssertEqual(Set(ranked.map(\.sourceSHA256)).count, 250)
        XCTAssertGreaterThan(cancellationChecks, candidates.count)
    }

    private func evidence(
        _ identity: Int,
        quality: UInt8,
        descriptor: [UInt8],
        dHash: UInt64 = 0,
        analysisRecipeVersion: Int = 1,
        analysisRecipeSHA256: String? = nil
    ) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: sha256(identity),
            spatialDescriptor: descriptor,
            qualityBucket: quality,
            dHash: dHash,
            proxyPixelWidth: 8,
            proxyPixelHeight: 8,
            proxyPixelSHA256: sha256(identity + 10_000),
            analysisRecipeVersion: analysisRecipeVersion,
            analysisRecipeSHA256: analysisRecipeSHA256 ?? recipeSHA256
        )
    }

    private func sha256(_ identity: Int) -> String {
        String(format: "%064llx", UInt64(identity))
    }

    private func descriptor(_ value: UInt8) -> [UInt8] {
        [UInt8](
            repeating: value,
            count: PhotoAnalysisEvidence.spatialDescriptorLength
        )
    }

    private func descriptor(changing index: Int, to value: UInt8) -> [UInt8] {
        descriptor(changing: index, from: 0, to: value)
    }

    private func descriptor(
        changing index: Int,
        from base: UInt8,
        to value: UInt8
    ) -> [UInt8] {
        var result = descriptor(base)
        result[index] = value
        return result
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard let first = values.first else { return [[]] }
        return permutations(of: Array(values.dropFirst())).flatMap { permutation in
            (0...permutation.count).map { index in
                var copy = permutation
                copy.insert(first, at: index)
                return copy
            }
        }
    }

    private var recipeSHA256: String {
        String(repeating: "e", count: 64)
    }
}
