import Foundation
import XCTest
@testable import EasySplatCore

final class PhotoSelectionProjectionTests: XCTestCase {
    func testVisualDiversityLoadsAuthenticatedRankedPrefix() throws {
        let fixture = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [6, 1, 5, 2, 4, 3].map(makeEvidence),
            capacity: 4
        )
        defer { fixture.remove() }

        let projection = try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: fixture.metadata,
            paths: fixture.paths
        ))

        XCTAssertEqual(projection.artifact, fixture.artifact)
        XCTAssertEqual(projection.policy, .rankedPrefix)
        XCTAssertEqual(
            projection.canonicalReceipts.map(\.source.sha256),
            fixture.artifact.canonicalRetainedSourceSHA256s
        )
        XCTAssertEqual(
            projection.rankOrderedReceipts.map(\.source.sha256),
            fixture.artifact.retainedSourceSHA256s
        )
        XCTAssertEqual(
            try projection.project(targetCount: 2).map(\.source.sha256),
            Array(fixture.artifact.retainedSourceSHA256s.prefix(2))
        )
    }

    func testContinuousSelectionProjectsByEndpointRoundedEvenSpacing() throws {
        let fixture = try makeFixture(
            strategy: .continuousEvenSpacing,
            admissionOrder: [7, 1, 6, 2, 5, 3, 4].map(makeEvidence),
            capacity: 5
        )
        defer { fixture.remove() }

        let projection = try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: fixture.metadata,
            paths: fixture.paths
        ))

        XCTAssertEqual(projection.policy, .evenlySpaced)
        XCTAssertEqual(
            try projection.project(targetCount: 3).map(\.source.sha256),
            [
                projection.canonicalReceipts[0].source.sha256,
                projection.canonicalReceipts[2].source.sha256,
                projection.canonicalReceipts[4].source.sha256,
            ]
        )
        XCTAssertEqual(try projection.project(targetCount: 0), [])
    }

    func testUseAllPreservesCanonicalReceiptsAndRejectsShrink() throws {
        let fixture = try makeFixture(
            strategy: .useAll,
            admissionOrder: [4, 1, 3, 2].map(makeEvidence),
            capacity: 4
        )
        defer { fixture.remove() }

        let projection = try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: fixture.metadata,
            paths: fixture.paths
        ))

        XCTAssertEqual(projection.policy, .preserve)
        XCTAssertEqual(
            try projection.project(targetCount: 4),
            projection.canonicalReceipts
        )
        XCTAssertThrowsError(try projection.project(targetCount: 3)) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .useAllRequiresFullCount(expected: 4, actual: 3)
            )
        }
    }

    func testVideoOnlyRequiresNoPhotoSelectionClosure() throws {
        let paths = try makeProjectPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let metadata = ProjectMetadata(
            title: "Video",
            input: .video(files: ["Originals/video-0000.mov"])
        )

        XCTAssertNil(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: paths
        ))

        var invalid = metadata
        invalid.photoInputReceipts = []
        invalid.photoSelectionReceipt = placeholderSelectionReceipt()
        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: invalid,
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .invalidInputCombination
            )
        }
    }

    func testMixedInputMayHaveNoPhotosOnlyAfterVideoAdoption() throws {
        let paths = try makeProjectPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var metadata = ProjectMetadata(
            title: "Mixed",
            input: .mixed(
                videos: ["Originals/video-0000.mov"],
                photosFolder: "Originals/Photos"
            ),
            videoInputReceipts: [makeVideoReceipt()],
            photoInputReceipts: []
        )

        XCTAssertNoThrow(try VideoInputReceiptValidator.validateMetadata(
            metadata,
            paths: paths
        ))
        XCTAssertNil(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: paths
        ))
        let projectBound = try PhotoSelectionProjection.loadProjectBoundVerified(
            metadata: metadata,
            paths: paths
        )
        XCTAssertNil(projectBound.projection)
        XCTAssertNil(projectBound.leaseEvidence)

        metadata.videoInputReceipts = []
        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .invalidInputCombination
            )
        }
    }

    func testPhotoInputRejectsMissingOrStructurallyTamperedSelectionReceipt() throws {
        let fixture = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [1, 2, 3].map(makeEvidence),
            capacity: 2
        )
        defer { fixture.remove() }
        var metadata = fixture.metadata
        metadata.photoSelectionReceipt = nil

        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .missingSelectionReceipt
            )
        }

        metadata.photoSelectionReceipt = replacingSelectionReceipt(
            try XCTUnwrap(fixture.metadata.photoSelectionReceipt),
            projectRelativePath: "Frames/other.json"
        )
        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .invalidSelectionReceipt
            )
        }
    }

    func testArtifactTamperIsRejectedByReceiptDigest() throws {
        let fixture = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [1, 2, 3].map(makeEvidence),
            capacity: 2
        )
        defer { fixture.remove() }
        var data = try Data(contentsOf: fixture.paths.photoSelectionArtifactURL)
        data[data.startIndex] ^= 0x01
        try data.write(to: fixture.paths.photoSelectionArtifactURL, options: [.atomic])

        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: fixture.metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .artifactVerificationFailed(.artifactDigestMismatch)
            )
        }
    }

    func testStaleSelectionPolicyReceiptIsRejectedBeforeLoadingArtifact() throws {
        let fixture = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [1, 2, 3].map(makeEvidence),
            capacity: 2
        )
        defer { fixture.remove() }
        var metadata = fixture.metadata
        metadata.photoSelectionReceipt = replacingSelectionReceipt(
            try XCTUnwrap(metadata.photoSelectionReceipt),
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion + 1
        )

        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .invalidSelectionReceipt
            )
        }
    }

    func testCanonicalReceiptReorderingIsRejectedEvenWhenRanksRemainValid() throws {
        let fixture = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [1, 2, 3, 4].map(makeEvidence),
            capacity: 3
        )
        defer { fixture.remove() }
        var metadata = fixture.metadata
        var receipts = try XCTUnwrap(metadata.photoInputReceipts)
        receipts.swapAt(0, 1)
        receipts = receipts.enumerated().map { index, receipt in
            replacingPhotoReceipt(
                receipt,
                projectRelativePath: String(
                    format: "Originals/Photos/photo-%04d.jpg",
                    index
                )
            )
        }
        metadata.photoInputReceipts = receipts

        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .receiptBindingMismatch
            )
        }
    }

    func testEvidenceAndRankMustMatchAuthenticatedArtifactCandidate() throws {
        let fixture = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [1, 2, 3, 4].map(makeEvidence),
            capacity: 3
        )
        defer { fixture.remove() }
        var metadata = fixture.metadata
        var receipts = try XCTUnwrap(metadata.photoInputReceipts)
        let first = receipts[0]
        let wrongEvidence = PhotoAnalysisEvidence(
            sourceSHA256: first.analysisEvidence.sourceSHA256,
            spatialDescriptor: Array(first.analysisEvidence.spatialDescriptor.reversed()),
            qualityBucket: first.analysisEvidence.qualityBucket,
            dHash: first.analysisEvidence.dHash,
            proxyPixelWidth: first.analysisEvidence.proxyPixelWidth,
            proxyPixelHeight: first.analysisEvidence.proxyPixelHeight,
            proxyPixelSHA256: first.analysisEvidence.proxyPixelSHA256,
            analysisRecipeVersion: first.analysisEvidence.analysisRecipeVersion,
            analysisRecipeSHA256: first.analysisEvidence.analysisRecipeSHA256
        )
        receipts[0] = replacingPhotoReceipt(first, analysisEvidence: wrongEvidence)
        metadata.photoInputReceipts = receipts

        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .receiptBindingMismatch
            )
        }

        receipts = try XCTUnwrap(fixture.metadata.photoInputReceipts)
        receipts[0] = replacingPhotoReceipt(receipts[0], retainedRank: receipts[1].retainedRank)
        receipts[1] = replacingPhotoReceipt(receipts[1], retainedRank: 0)
        metadata.photoInputReceipts = receipts
        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .receiptBindingMismatch
            )
        }
    }

    func testArtifactStrategyAndRequestedPolicyMustMatchResolvedPlan() throws {
        let fixture = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [1, 2, 3].map(makeEvidence),
            capacity: 2
        )
        defer { fixture.remove() }
        var metadata = fixture.metadata
        var plan = try XCTUnwrap(metadata.resolvedRunPlan)
        plan.inputOrdering = .continuous
        metadata.resolvedRunPlan = plan

        XCTAssertThrowsError(try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoSelectionProjectionError,
                .planMismatch
            )
        }
    }

    func testVisualCanonicalBindingIsIndependentOfAdmissionPermutation() throws {
        let evidence = [1, 2, 3, 4, 5, 6].map(makeEvidence)
        let first = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: evidence,
            capacity: 4
        )
        defer { first.remove() }
        let second = try makeFixture(
            strategy: .visualDiversity,
            admissionOrder: [evidence[3], evidence[0], evidence[5], evidence[1], evidence[4], evidence[2]],
            capacity: 4
        )
        defer { second.remove() }

        let firstProjection = try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: first.metadata,
            paths: first.paths
        ))
        let secondProjection = try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: second.metadata,
            paths: second.paths
        ))

        XCTAssertEqual(
            firstProjection.canonicalReceipts.map(\.source.sha256),
            secondProjection.canonicalReceipts.map(\.source.sha256)
        )
        XCTAssertEqual(
            try firstProjection.project(targetCount: 3).map(\.source.sha256),
            try secondProjection.project(targetCount: 3).map(\.source.sha256)
        )
    }

    private struct Fixture {
        let paths: ProjectPaths
        let artifact: PhotoSelectionArtifact
        var metadata: ProjectMetadata

        func remove() {
            try? FileManager.default.removeItem(at: paths.root)
        }
    }

    private func makeFixture(
        strategy: PhotoSelectionStrategy,
        admissionOrder: [PhotoAnalysisEvidence],
        capacity: Int
    ) throws -> Fixture {
        let ordering: InputOrdering
        let requestedSelection: PhotoSelection
        let retained: [PhotoAnalysisEvidence]
        switch strategy {
        case .visualDiversity:
            ordering = .unordered
            requestedSelection = .automatic
            retained = try PhotoDiversitySelector.rank(
                admissionOrder,
                targetCount: capacity
            )
        case .continuousEvenSpacing:
            ordering = .continuous
            requestedSelection = .automatic
            retained = evenlySpaced(admissionOrder, targetCount: capacity)
        case .useAll:
            ordering = .unordered
            requestedSelection = .useAllValidPhotos
            retained = admissionOrder.sorted { $0.sourceSHA256 < $1.sourceSHA256 }
        }
        let rankBySHA = Dictionary(
            uniqueKeysWithValues: retained.enumerated().map {
                ($0.element.sourceSHA256, $0.offset)
            }
        )
        let retainedSHA = retained.map(\.sourceSHA256)
        let canonicalSHA = ordering == .continuous ? retainedSHA : retainedSHA.sorted()
        let artifact = PhotoSelectionArtifact(
            strategy: strategy,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: ordering,
            requestedPhotoSelection: requestedSelection,
            admissionCapacity: capacity,
            discoveredCount: admissionOrder.count,
            acceptedCount: admissionOrder.count,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: admissionOrder.enumerated().map { ordinal, evidence in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: ordinal,
                    evidence: evidence,
                    retainedRank: rankBySHA[evidence.sourceSHA256]
                )
            },
            retainedSourceSHA256s: retainedSHA,
            canonicalRetainedSourceSHA256s: canonicalSHA
        )
        let paths = try makeProjectPaths()
        let fileEvidence = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let evidenceBySHA = Dictionary(
            uniqueKeysWithValues: admissionOrder.map { ($0.sourceSHA256, $0) }
        )
        let receipts = try canonicalSHA.enumerated().map { index, sha in
            makePhotoReceipt(
                index: index,
                evidence: try XCTUnwrap(evidenceBySHA[sha]),
                retainedRank: try XCTUnwrap(rankBySHA[sha])
            )
        }
        let selectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: fileEvidence.byteCount,
            sha256: fileEvidence.sha256,
            artifactSchemaVersion: artifact.schemaVersion,
            analysisRecipeVersion: artifact.analysisRecipeVersion,
            analysisRecipeSHA256: artifact.analysisRecipeSHA256,
            selectorPolicyVersion: artifact.selectorPolicyVersion,
            selectorPolicySHA256: artifact.selectorPolicySHA256
        )
        var plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                inputOrdering: ordering,
                photoSelection: requestedSelection
            ),
            input: .photos(folder: "Originals/Photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        plan.inputOrdering = ordering
        plan.photoSelection = requestedSelection
        let metadata = ProjectMetadata(
            title: "Photos",
            input: .photos(folder: "Originals/Photos"),
            photoInputReceipts: receipts,
            photoSelectionReceipt: selectionReceipt,
            requestedRunOptions: RequestedRunOptions(
                inputOrdering: ordering,
                photoSelection: requestedSelection
            ),
            resolvedRunPlan: plan
        )
        return Fixture(paths: paths, artifact: artifact, metadata: metadata)
    }

    private func makeProjectPaths() throws -> ProjectPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoSelectionProjectionTests-\(UUID().uuidString).easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        return paths
    }

    private func makeEvidence(_ index: Int) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: String(format: "%064llx", UInt64(index)),
            spatialDescriptor: (0..<PhotoAnalysisEvidence.spatialDescriptorLength).map {
                UInt8(truncatingIfNeeded: index * 31 + $0 * 11)
            },
            qualityBucket: UInt8(220 - index),
            dHash: UInt64(index * 13),
            proxyPixelWidth: 16,
            proxyPixelHeight: 12,
            proxyPixelSHA256: String(format: "%064llx", UInt64(10_000 + index)),
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256
        )
    }

    private func makePhotoReceipt(
        index: Int,
        evidence: PhotoAnalysisEvidence,
        retainedRank: Int
    ) -> PhotoInputReceipt {
        PhotoInputReceipt(
            projectRelativePath: String(
                format: "Originals/Photos/photo-%04d.jpg",
                index
            ),
            safeDisplayName: "photo-\(index).jpg",
            byteCount: 1_024 + Int64(index),
            sha256: evidence.sourceSHA256,
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            orientation: 1,
            typeIdentifier: "public.jpeg",
            analysisEvidence: evidence,
            retainedRank: retainedRank
        )
    }

    private func replacingPhotoReceipt(
        _ receipt: PhotoInputReceipt,
        projectRelativePath: String? = nil,
        analysisEvidence: PhotoAnalysisEvidence? = nil,
        retainedRank: Int? = nil
    ) -> PhotoInputReceipt {
        PhotoInputReceipt(
            schemaVersion: receipt.schemaVersion,
            projectRelativePath: projectRelativePath ?? receipt.projectRelativePath,
            safeDisplayName: receipt.safeDisplayName,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            orientation: receipt.orientation,
            typeIdentifier: receipt.typeIdentifier,
            source: receipt.source,
            importMode: receipt.importMode,
            analysisEvidence: analysisEvidence ?? receipt.analysisEvidence,
            retainedRank: retainedRank ?? receipt.retainedRank
        )
    }

    private func placeholderSelectionReceipt() -> PhotoSelectionReceipt {
        PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: 1,
            sha256: String(repeating: "a", count: 64),
            artifactSchemaVersion: PhotoSelectionArtifact.currentSchemaVersion,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256
        )
    }

    private func replacingSelectionReceipt(
        _ receipt: PhotoSelectionReceipt,
        projectRelativePath: String? = nil,
        selectorPolicyVersion: Int? = nil
    ) -> PhotoSelectionReceipt {
        PhotoSelectionReceipt(
            schemaVersion: receipt.schemaVersion,
            projectRelativePath: projectRelativePath ?? receipt.projectRelativePath,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            artifactSchemaVersion: receipt.artifactSchemaVersion,
            analysisRecipeVersion: receipt.analysisRecipeVersion,
            analysisRecipeSHA256: receipt.analysisRecipeSHA256,
            selectorPolicyVersion: selectorPolicyVersion ?? receipt.selectorPolicyVersion,
            selectorPolicySHA256: receipt.selectorPolicySHA256
        )
    }

    private func makeVideoReceipt() -> VideoInputReceipt {
        VideoInputReceipt(
            projectRelativePath: "Originals/video-0000.mov",
            safeDisplayName: "video.mov",
            byteCount: 1,
            sha256: String(repeating: "a", count: 64),
            trackID: 1,
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            durationSeconds: 1,
            nominalFrameRate: 30,
            isHDR: false,
            decodedFrameCount: 30,
            transformA: 1,
            transformB: 0,
            transformC: 0,
            transformD: 1,
            transformTX: 0,
            transformTY: 0,
            clipGroupID: String(repeating: "b", count: 64),
            analysisPolicySHA256: String(repeating: "c", count: 64),
            analysisArtifactPath: "Frames/video-analysis-0000.json",
            analysisArtifactByteCount: 1,
            analysisArtifactSHA256: String(repeating: "d", count: 64)
        )
    }

    private func evenlySpaced<Element>(
        _ items: [Element],
        targetCount: Int
    ) -> [Element] {
        guard targetCount > 0, !items.isEmpty else { return [] }
        guard items.count > targetCount else { return items }
        guard targetCount > 1 else { return [items[items.count / 2]] }
        let step = Double(items.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            items[Int((Double(index) * step).rounded())]
        }
    }
}
