import XCTest
@testable import EasySplatCore

final class VideoClipIdentityTests: XCTestCase {
    private let digestA = String(repeating: "1", count: 64)
    private let digestB = String(repeating: "a", count: 64)

    func testSegmentedClipIdentityIsPermutationInvariantAndDigestBound() throws {
        let forward = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestB, digestA],
            pairingPolicy: .segmentedMixed
        )
        let reverse = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestA, digestB],
            pairingPolicy: .segmentedMixed
        )

        XCTAssertEqual(forward.map(\.sourceSHA256), [digestA, digestB])
        XCTAssertEqual(reverse.map(\.sourceSHA256), [digestA, digestB])
        XCTAssertEqual(
            forward.map { "\($0.sourceSHA256):\($0.groupID)" },
            reverse.map { "\($0.sourceSHA256):\($0.groupID)" }
        )
        XCTAssertEqual(forward.map(\.sourceIndex), [1, 0])
        XCTAssertEqual(reverse.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(forward.map(\.groupID), [
            "video_sha256_\(digestA)",
            "video_sha256_\(digestB)",
        ])
    }

    func testUnorderedClipIdentityUsesTheSameCanonicalContract() throws {
        let segmented = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestB, digestA],
            pairingPolicy: .segmentedMixed
        )
        let unordered = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestB, digestA],
            pairingPolicy: .unorderedRetrieval
        )

        XCTAssertEqual(segmented, unordered)
    }

    func testContinuousClipIdentityPreservesUserOrder() throws {
        let forward = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestB, digestA],
            pairingPolicy: .orderedContinuous
        )
        let reverse = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestA, digestB],
            pairingPolicy: .orderedContinuous
        )

        XCTAssertEqual(forward.map(\.sourceSHA256), [digestB, digestA])
        XCTAssertEqual(reverse.map(\.sourceSHA256), [digestA, digestB])
        XCTAssertEqual(forward.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(reverse.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(forward.map(\.groupID), ["video_000", "video_001"])
        XCTAssertEqual(reverse.map(\.groupID), ["video_000", "video_001"])
    }

    func testEveryPairingPolicyRejectsExactDuplicateClipContent() {
        for policy in [
            ResolvedPairingPolicy.segmentedMixed,
            .unorderedRetrieval,
            .orderedContinuous,
            .orderedOrbit,
            .orderedWalkthrough,
            .orderedLargeArea,
        ] {
            XCTAssertThrowsError(try VideoClipIdentityResolver.resolve(
                sourceSHA256s: [digestA, digestA],
                pairingPolicy: policy
            )) { error in
                XCTAssertEqual(
                    error as? VideoClipIdentityError,
                    .duplicateSourceSHA256(digestA)
                )
            }
        }
    }

    func testRejectsInvalidOrAmbiguousDigestEvidenceBeforeOrdering() {
        XCTAssertThrowsError(try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [digestB.uppercased()],
            pairingPolicy: .segmentedMixed
        )) { error in
            XCTAssertEqual(error as? VideoClipIdentityError, .invalidSourceSHA256(index: 0))
        }
        XCTAssertThrowsError(try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [String(repeating: "0", count: 63)],
            pairingPolicy: .segmentedMixed
        )) { error in
            XCTAssertEqual(error as? VideoClipIdentityError, .invalidSourceSHA256(index: 0))
        }
    }

    func testAutomaticRuntimeReceiptIdentityIgnoresClipPermutationAndControlledNames() throws {
        let forward = metadata(receipts: [
            receipt(path: "Originals/video-0000.mov", digest: digestB, byteCount: 20),
            receipt(path: "Originals/video-0001.mp4", digest: digestA, byteCount: 10),
        ])
        let reverse = metadata(receipts: [
            receipt(path: "Originals/video-0000.mp4", digest: digestA, byteCount: 10),
            receipt(path: "Originals/video-0001.mov", digest: digestB, byteCount: 20),
        ])

        XCTAssertEqual(
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: forward,
                pairingPolicy: .segmentedMixed
            ),
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: reverse,
                pairingPolicy: .segmentedMixed
            )
        )
        XCTAssertNotEqual(
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: forward,
                pairingPolicy: .orderedContinuous
            ),
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: reverse,
                pairingPolicy: .orderedContinuous
            )
        )
    }

    func testMixedAutomaticFixtureBindsStableNamesPairsAndCameraEvidence() throws {
        let photoDigests = [String(repeating: "2", count: 64), String(repeating: "f", count: 64)]
        let forward = try selectedFixture(
            videoDigests: [digestB, digestA],
            photoDigests: photoDigests,
            pairingPolicy: .segmentedMixed
        )
        let reverse = try selectedFixture(
            videoDigests: [digestA, digestB],
            photoDigests: photoDigests.reversed(),
            pairingPolicy: .segmentedMixed
        )

        XCTAssertEqual(normalized(forward), normalized(reverse))
        XCTAssertEqual(forward.map(\.outputFileName), reverse.map(\.outputFileName))

        let forwardNames = forward.map(\.outputFileName)
        let reverseNames = reverse.map(\.outputFileName)
        let forwardGroups = try PipelineRunner.colmapPairGroups(
            imageNames: forwardNames,
            manifest: forward
        )
        let reverseGroups = try PipelineRunner.colmapPairGroups(
            imageNames: reverseNames,
            manifest: reverse
        )
        XCTAssertEqual(forwardGroups, reverseGroups)

        let forwardPairs = try ColmapPairPlan.exhaustive(imageNames: forwardNames)
        let reversePairs = try ColmapPairPlan.exhaustive(imageNames: reverseNames)
        XCTAssertEqual(forwardPairs.pairLines, reversePairs.pairLines)
        XCTAssertEqual(forwardPairs.sha256, reversePairs.sha256)

        let forwardCameraEvidence = try PipelineRunner.colmapCameraGroupingEvidence(
            imageNames: forwardNames,
            manifest: forward
        )
        let reverseCameraEvidence = try PipelineRunner.colmapCameraGroupingEvidence(
            imageNames: reverseNames,
            manifest: reverse
        )
        XCTAssertEqual(forwardCameraEvidence, reverseCameraEvidence)
        XCTAssertEqual(
            PipelineRunner.colmapCameraGroupingMode(
                cameraGrouping: .mixedCamerasOrLenses,
                evidence: forwardCameraEvidence
            ),
            .videoSourceGroups
        )
    }

    func testContinuousFixtureDiffersOnlyByIntentionalClipOrder() throws {
        let forward = try selectedFixture(
            videoDigests: [digestB, digestA],
            photoDigests: [],
            pairingPolicy: .orderedContinuous
        )
        let reverse = try selectedFixture(
            videoDigests: [digestA, digestB],
            photoDigests: [],
            pairingPolicy: .orderedContinuous
        )

        XCTAssertEqual(forward.map(\.outputFileName), reverse.map(\.outputFileName))
        XCTAssertEqual(forward.map(\.groupId), reverse.map(\.groupId))
        XCTAssertNotEqual(forward.compactMap(\.sourceSHA256), reverse.compactMap(\.sourceSHA256))
    }

    private func metadata(receipts: [VideoInputReceipt]) -> ProjectMetadata {
        ProjectMetadata(
            title: "Clip identity fixture",
            input: .video(files: receipts.map(\.projectRelativePath)),
            videoInputReceipts: receipts
        )
    }

    private func receipt(
        path: String,
        digest: String,
        byteCount: Int64
    ) -> VideoInputReceipt {
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        let controlledIndex = Int(leaf.dropFirst("video-".count).prefix(4)) ?? 0
        return VideoInputReceipt(
            projectRelativePath: path,
            safeDisplayName: "Capture.mov",
            byteCount: byteCount,
            sha256: digest,
            trackID: 1,
            pixelWidth: 64,
            pixelHeight: 48,
            durationSeconds: 1,
            nominalFrameRate: 30,
            isHDR: false,
            decodedFrameCount: 3,
            transformA: 1,
            transformB: 0,
            transformC: 0,
            transformD: 1,
            transformTX: 0,
            transformTY: 0,
            clipGroupID: String(format: "video_%03d", controlledIndex),
            analysisPolicySHA256: VideoFrameAnalysisPolicy(
                targetFrameCeiling: 1,
                targetFPS: 1
            ).sha256,
            analysisArtifactPath: String(
                format: "Frames/video-analysis-%04d.json",
                controlledIndex
            ),
            analysisArtifactByteCount: 1,
            analysisArtifactSHA256: digest
        )
    }

    private func selectedFixture<S: Sequence>(
        videoDigests: [String],
        photoDigests: S,
        pairingPolicy: ResolvedPairingPolicy
    ) throws -> [PipelineRunner.SelectedFrameMapping] where S.Element == String {
        let identities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: videoDigests,
            pairingPolicy: pairingPolicy
        )
        var output: [PipelineRunner.SelectedFrameMapping] = []
        for identity in identities {
            for frameIndex in 0..<2 {
                output.append(PipelineRunner.SelectedFrameMapping(
                    outputFileName: String(format: "frame_%06d.jpg", output.count),
                    groupId: identity.groupID,
                    isVideo: true,
                    timestampSeconds: Double(frameIndex),
                    sourceSHA256: identity.sourceSHA256
                ))
            }
        }
        for digest in photoDigests.sorted() {
            output.append(PipelineRunner.SelectedFrameMapping(
                outputFileName: String(format: "frame_%06d.jpg", output.count),
                groupId: "photos",
                isVideo: false,
                sourceSHA256: digest
            ))
        }
        return output
    }

    private func normalized(
        _ mappings: [PipelineRunner.SelectedFrameMapping]
    ) -> [String] {
        mappings.map {
            [
                $0.outputFileName,
                $0.groupId,
                $0.sourceSHA256 ?? "",
                $0.timestampSeconds.map { String($0) } ?? "photo",
            ].joined(separator: "|")
        }
    }
}
