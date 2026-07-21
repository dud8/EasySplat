import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

final class PhotoSelectionArtifactStoreTests: XCTestCase {
    func testPhotoSelectionPersistenceExposesNoUnboundDiskAPI() throws {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectSourceRoot = coreRoot.appendingPathComponent(
            "Sources/EasySplatCore/Project",
            isDirectory: true
        )
        let storeSource = try String(
            contentsOf: projectSourceRoot.appendingPathComponent(
                "PhotoSelectionArtifact.swift"
            ),
            encoding: .utf8
        ).filter { !$0.isWhitespace }
        let adoptionSource = try String(
            contentsOf: projectSourceRoot.appendingPathComponent(
                "ProjectInputAdoption.swift"
            ),
            encoding: .utf8
        ).filter { !$0.isWhitespace }

        XCTAssertFalse(
            storeSource.contains(
                "staticfuncsave(_artifact:PhotoSelectionArtifact,tourl:URL,beforeAtomicRename:"
            ),
            "Photo selection persistence must not expose an unbound pathname save API."
        )
        XCTAssertFalse(
            storeSource.contains("staticfuncload(fromurl:URL)"),
            "Photo selection persistence must not expose an unbound pathname load API."
        )
        XCTAssertFalse(
            storeSource.contains("staticfuncloadVerified(fromurl:URL,"),
            "Photo selection persistence must not expose an unbound verified-load API."
        )
        XCTAssertFalse(
            adoptionSource.contains("PhotoSelectionArtifactStore.loadVerified("),
            "Project adoption must not reread the sidecar through an unbound pathname API."
        )
    }

    func testProjectBoundVisualDiversityArtifactRoundTripsWithVerifiedReceipt() throws {
        let artifact = try makeVisualArtifact(count: 6, capacity: 3)
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()

        let receipt = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let loaded = try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )

        XCTAssertEqual(loaded.artifact, artifact)
        XCTAssertEqual(
            loaded.artifact.candidates.map(\.evidence.sourceSHA256),
            loaded.artifact.candidates.map(\.evidence.sourceSHA256).sorted()
        )
        XCTAssertEqual(
            loaded.artifact.canonicalRetainedSourceSHA256s,
            loaded.artifact.retainedSourceSHA256s.sorted()
        )
        XCTAssertEqual(
            receipt.byteCount,
            Int64(try Data(contentsOf: paths.photoSelectionArtifactURL).count)
        )
        XCTAssertEqual(loaded.leaseEvidence.byteCount, receipt.byteCount)
        XCTAssertEqual(loaded.leaseEvidence.sha256, receipt.sha256)
        XCTAssertEqual(receipt.sha256.count, 64)
    }

    func testCanonicalEncodingIsIndependentOfCandidateArrayPermutation() throws {
        let artifact = try makeVisualArtifact(count: 5, capacity: 3)
        let permuted = PhotoSelectionArtifact(
            strategy: artifact.strategy,
            analysisRecipeVersion: artifact.analysisRecipeVersion,
            analysisRecipeSHA256: artifact.analysisRecipeSHA256,
            selectorPolicyVersion: artifact.selectorPolicyVersion,
            selectorPolicySHA256: artifact.selectorPolicySHA256,
            inputOrdering: artifact.inputOrdering,
            requestedPhotoSelection: artifact.requestedPhotoSelection,
            admissionCapacity: artifact.admissionCapacity,
            discoveredCount: artifact.discoveredCount,
            acceptedCount: artifact.acceptedCount,
            unreadableCount: artifact.unreadableCount,
            exactDuplicateCount: artifact.exactDuplicateCount,
            companionDuplicateCount: artifact.companionDuplicateCount,
            candidates: artifact.candidates.reversed(),
            retainedSourceSHA256s: artifact.retainedSourceSHA256s,
            canonicalRetainedSourceSHA256s: artifact.canonicalRetainedSourceSHA256s,
            tiePolicyIdentifier: artifact.tiePolicyIdentifier
        )

        XCTAssertEqual(
            try PhotoSelectionArtifactStore.canonicalData(artifact),
            try PhotoSelectionArtifactStore.canonicalData(permuted)
        )
        XCTAssertEqual(permuted, artifact)
    }

    func testDecodedArtifactRejectsNonCanonicalCandidatePermutation() throws {
        let artifact = try makeVisualArtifact(count: 5, capacity: 3)
        let canonical = try PhotoSelectionArtifactStore.canonicalData(artifact)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        let candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        object["candidates"] = Array(candidates.reversed())
        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        try tampered.write(to: paths.photoSelectionArtifactURL, options: [.atomic])
        XCTAssertEqual(
            Darwin.chmod(paths.photoSelectionArtifactURL.path, mode_t(0o600)),
            0
        )
        let digest = SHA256.hash(data: tampered)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: Int64(tampered.count),
            expectedSHA256: digest,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testVisualDiversityArtifactRejectsRankingTamper() throws {
        var artifact = try makeVisualArtifact(count: 5, capacity: 3)
        artifact.retainedSourceSHA256s.swapAt(1, 2)

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(artifact)) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testContinuousEvenSpacingUsesAdmissionOrderAndEndpointRounding() throws {
        let evidence = [4, 1, 5, 2, 3].map(makeEvidence)
        let retained = [evidence[0], evidence[2], evidence[4]]
        let artifact = makeArtifact(
            evidenceInAdmissionOrder: evidence,
            retainedInStrategyOrder: retained,
            strategy: .continuousEvenSpacing,
            inputOrdering: .continuous,
            requestedPhotoSelection: .automatic,
            admissionCapacity: 3
        )

        XCTAssertNoThrow(try PhotoSelectionArtifactStore.validate(artifact))
        XCTAssertEqual(
            artifact.canonicalRetainedSourceSHA256s,
            retained.map(\.sourceSHA256)
        )

        var tampered = artifact
        tampered.retainedSourceSHA256s = [
            evidence[0].sourceSHA256,
            evidence[1].sourceSHA256,
            evidence[4].sourceSHA256,
        ]
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(tampered))
    }

    func testUseAllValidatesUnorderedAndContinuousOrderingWithoutVisualRanking() throws {
        let evidence = [3, 1, 4, 2].map(makeEvidence)
        let unorderedRetained = evidence.sorted { $0.sourceSHA256 < $1.sourceSHA256 }
        let unordered = makeArtifact(
            evidenceInAdmissionOrder: evidence,
            retainedInStrategyOrder: unorderedRetained,
            strategy: .useAll,
            inputOrdering: .unordered,
            requestedPhotoSelection: .useAllValidPhotos,
            admissionCapacity: evidence.count
        )
        let continuous = makeArtifact(
            evidenceInAdmissionOrder: evidence,
            retainedInStrategyOrder: evidence,
            strategy: .useAll,
            inputOrdering: .continuous,
            requestedPhotoSelection: .useAllValidPhotos,
            admissionCapacity: evidence.count
        )

        XCTAssertNoThrow(try PhotoSelectionArtifactStore.validate(unordered))
        XCTAssertNoThrow(try PhotoSelectionArtifactStore.validate(continuous))
        XCTAssertEqual(
            unordered.canonicalRetainedSourceSHA256s,
            unorderedRetained.map(\.sourceSHA256)
        )
        XCTAssertEqual(
            continuous.canonicalRetainedSourceSHA256s,
            evidence.map(\.sourceSHA256)
        )

        var wrongOrder = unordered
        wrongOrder.retainedSourceSHA256s = evidence.map(\.sourceSHA256)
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(wrongOrder))
    }

    func testRejectsInvalidCountArithmeticAndCapacity() throws {
        let valid = try makeVisualArtifact(count: 4, capacity: 2)

        var wrongArithmetic = valid
        wrongArithmetic.discoveredCount += 1
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(wrongArithmetic))

        var capacityBelowRetained = valid
        capacityBelowRetained.admissionCapacity = 1
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(capacityBelowRetained))

        var capacityAboveAccepted = valid
        capacityAboveAccepted.admissionCapacity = valid.acceptedCount + 1
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(capacityAboveAccepted))

        var acceptedMismatch = valid
        acceptedMismatch.acceptedCount += 1
        acceptedMismatch.discoveredCount += 1
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(acceptedMismatch))
    }

    func testRejectsMoreThanTenThousandCandidates() throws {
        let evidence = (1...10_001).map(makeEvidence)
        let artifact = makeArtifact(
            evidenceInAdmissionOrder: evidence,
            retainedInStrategyOrder: [evidence[0]],
            strategy: .visualDiversity,
            inputOrdering: .unordered,
            requestedPhotoSelection: .automatic,
            admissionCapacity: 1
        )

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(artifact)) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testRejectsDuplicateCandidateSourceAndNonCanonicalHashes() throws {
        let valid = try makeVisualArtifact(count: 4, capacity: 2)
        var duplicate = valid
        duplicate.candidates[1].evidence = duplicate.candidates[0].evidence
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(duplicate))

        var uppercase = valid
        uppercase.analysisRecipeSHA256 = uppercase.analysisRecipeSHA256.uppercased()
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(uppercase))
    }

    func testRejectsInvalidAdmissionOrdinalsAndRetainedRanks() throws {
        let valid = try makeVisualArtifact(count: 5, capacity: 3)

        var duplicateOrdinal = valid
        duplicateOrdinal.candidates[1].admissionOrdinal = 0
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(duplicateOrdinal))

        var missingRank = valid
        let retainedSHA = missingRank.retainedSourceSHA256s[0]
        let retainedIndex = try XCTUnwrap(
            missingRank.candidates.firstIndex {
                $0.evidence.sourceSHA256 == retainedSHA
            }
        )
        missingRank.candidates[retainedIndex].retainedRank = nil
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(missingRank))

        var rankOnRejected = valid
        let rejectedIndex = try XCTUnwrap(
            rankOnRejected.candidates.firstIndex { $0.retainedRank == nil }
        )
        rankOnRejected.candidates[rejectedIndex].retainedRank = 0
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(rankOnRejected))
    }

    func testRejectsMixedEvidenceRecipeAndWrongSelectorPolicy() throws {
        let valid = try makeVisualArtifact(count: 4, capacity: 2)

        var mixedRecipe = valid
        mixedRecipe.candidates[1].evidence = replacingRecipe(
            mixedRecipe.candidates[1].evidence,
            version: valid.analysisRecipeVersion + 1,
            sha256: valid.analysisRecipeSHA256
        )
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(mixedRecipe))

        var wrongPolicy = valid
        wrongPolicy.selectorPolicySHA256 = hash(character: "f")
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(wrongPolicy))
    }

    func testRejectsUniformlyStaleAnalysisRecipe() throws {
        let valid = try makeVisualArtifact(count: 4, capacity: 2)
        var stale = valid
        stale.analysisRecipeVersion += 1
        stale.analysisRecipeSHA256 = hash(character: "e")
        stale.candidates = stale.candidates.map { candidate in
            PhotoSelectionCandidateArtifact(
                admissionOrdinal: candidate.admissionOrdinal,
                evidence: replacingRecipe(
                    candidate.evidence,
                    version: stale.analysisRecipeVersion,
                    sha256: stale.analysisRecipeSHA256
                ),
                retainedRank: candidate.retainedRank
            )
        }

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.validate(stale)) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testProjectBoundVerifiedLoadRejectsTamperAndWrongExpectedRecipeOrPolicy() throws {
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let receipt = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion + 1,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .policyMismatch)
        }

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion + 1,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .policyMismatch)
        }

        var data = try Data(contentsOf: paths.photoSelectionArtifactURL)
        data[data.startIndex] ^= 0x01
        try data.write(to: paths.photoSelectionArtifactURL, options: [.atomic])
        XCTAssertEqual(
            Darwin.chmod(paths.photoSelectionArtifactURL.path, mode_t(0o600)),
            0
        )
        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .artifactDigestMismatch)
        }
    }

    func testProjectBoundSaveRejectsNonreservedPath() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.save(
            artifact,
            to: project.appendingPathComponent("photo_selection.json"),
            projectPaths: paths
        ))
        XCTAssertNoThrow(try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        ))
    }

    func testProjectBoundSaveStagesPrivateFileBeforeAtomicReplacement() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let first = try makeVisualArtifact(count: 4, capacity: 2)
        let second = try makeVisualArtifact(count: 5, capacity: 3)
        var firstTemporaryURL: URL?

        let firstReceipt = try PhotoSelectionArtifactStore.save(
            first,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            beforeAtomicRename: {
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: paths.photoSelectionArtifactURL.path
                ))
                let visible = try self.visibleSelectionPaths(paths: paths)
                let temporary = try XCTUnwrap(visible.first)
                XCTAssertEqual(visible.count, 1)
                XCTAssertEqual(try self.permissions(of: temporary), 0o600)
                firstTemporaryURL = temporary
            }
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try XCTUnwrap(firstTemporaryURL).path
        ))
        XCTAssertEqual(try permissions(of: paths.photoSelectionArtifactURL), 0o600)
        let firstData = try Data(contentsOf: paths.photoSelectionArtifactURL)
        var replacementTemporaryURL: URL?

        let secondReceipt = try PhotoSelectionArtifactStore.save(
            second,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            beforeAtomicRename: {
                XCTAssertEqual(
                    try Data(contentsOf: paths.photoSelectionArtifactURL),
                    firstData,
                    "The prior sidecar must remain intact until the atomic rename"
                )
                let visible = try self.visibleSelectionPaths(paths: paths)
                XCTAssertEqual(visible.count, 2)
                for url in visible {
                    XCTAssertEqual(try self.permissions(of: url), 0o600)
                }
                replacementTemporaryURL = try XCTUnwrap(
                    visible.first { $0 != paths.photoSelectionArtifactURL }
                )
            }
        )

        XCTAssertNotEqual(firstReceipt.sha256, secondReceipt.sha256)
        _ = try XCTUnwrap(replacementTemporaryURL)
        XCTAssertEqual(
            try visibleSelectionPaths(paths: paths).map(\.lastPathComponent),
            ["photo_selection.json"]
        )
        XCTAssertEqual(try permissions(of: paths.photoSelectionArtifactURL), 0o600)
        let loaded = try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: secondReceipt.byteCount,
            expectedSHA256: secondReceipt.sha256,
            expectedAnalysisRecipeVersion: second.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: second.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: second.selectorPolicyVersion,
            expectedSelectorPolicySHA256: second.selectorPolicySHA256
        )
        XCTAssertEqual(loaded.artifact, second)
    }

    func testProjectBoundSaveRejectsFramesRebindAndCleansStagedFile() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let first = try makeVisualArtifact(count: 4, capacity: 2)
        let second = try makeVisualArtifact(count: 5, capacity: 3)
        _ = try PhotoSelectionArtifactStore.save(
            first,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let firstData = try Data(contentsOf: paths.photoSelectionArtifactURL)
        let frames = project.appendingPathComponent("Frames", isDirectory: true)
        let heldFrames = project.appendingPathComponent("Frames-held", isDirectory: true)

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.save(
            second,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            beforeAtomicRename: {
                XCTAssertEqual(Darwin.rename(frames.path, heldFrames.path), 0)
                try FileManager.default.createDirectory(
                    at: frames,
                    withIntermediateDirectories: false
                )
            }
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
        XCTAssertEqual(
            try Data(contentsOf: heldFrames.appendingPathComponent("photo_selection.json")),
            firstData
        )
        XCTAssertTrue(try visibleSelectionPaths(in: heldFrames).allSatisfy {
            $0.lastPathComponent == "photo_selection.json"
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.photoSelectionArtifactURL.path
        ))
    }

    func testProjectBoundSaveRejectsRootRebindAndCleansStagedFile() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let project = container.appendingPathComponent("project.easysplatproj", isDirectory: true)
        let heldProject = container.appendingPathComponent("project-held", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let first = try makeVisualArtifact(count: 4, capacity: 2)
        let second = try makeVisualArtifact(count: 5, capacity: 3)
        _ = try PhotoSelectionArtifactStore.save(
            first,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let firstData = try Data(contentsOf: paths.photoSelectionArtifactURL)

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.save(
            second,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            beforeAtomicRename: {
                XCTAssertEqual(Darwin.rename(project.path, heldProject.path), 0)
                try FileManager.default.createDirectory(
                    at: project.appendingPathComponent("Frames", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
        let heldFrames = heldProject.appendingPathComponent("Frames", isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: heldFrames.appendingPathComponent("photo_selection.json")),
            firstData
        )
        XCTAssertTrue(try visibleSelectionPaths(in: heldFrames).allSatisfy {
            $0.lastPathComponent == "photo_selection.json"
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.photoSelectionArtifactURL.path
        ))
    }

    func testProjectBoundVerifiedLoadRejectsNonprivateFileMode() throws {
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let receipt = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        XCTAssertEqual(
            Darwin.chmod(paths.photoSelectionArtifactURL.path, mode_t(0o644)),
            0
        )

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testProjectBoundVerifiedLoadRejectsNonreservedPath() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let project = container.appendingPathComponent(
            "project.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)
        let outside = container.appendingPathComponent("photo_selection.json")
        let outsideData = try PhotoSelectionArtifactStore.canonicalData(artifact)
        try outsideData.write(to: outside, options: [.atomic])
        XCTAssertEqual(Darwin.chmod(outside.path, mode_t(0o600)), 0)

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: outside,
            projectPaths: paths,
            expectedByteCount: Int64(outsideData.count),
            expectedSHA256: String(repeating: "a", count: 64),
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testProjectBoundVerifiedLoadRejectsPathReplacementDuringRead() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)
        let receipt = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let replacement = paths.framesRawURL
            .deletingLastPathComponent()
            .appendingPathComponent("replacement.json")
        try Data(contentsOf: paths.photoSelectionArtifactURL).write(to: replacement)
        XCTAssertEqual(Darwin.chmod(replacement.path, mode_t(0o600)), 0)

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256,
            beforeFinalPathValidation: {
                XCTAssertEqual(
                    Darwin.rename(replacement.path, paths.photoSelectionArtifactURL.path),
                    0
                )
            }
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testProjectBoundVerifiedLoadReturnsFileAndDirectoryLeaseEvidence() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)
        let receipt = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )

        let loaded = try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
        )

        XCTAssertEqual(loaded.artifact, artifact)
        XCTAssertEqual(loaded.leaseEvidence.owner, UInt32(getuid()))
        XCTAssertEqual(loaded.leaseEvidence.mode & 0o7777, 0o600)
        XCTAssertEqual(loaded.leaseEvidence.linkCount, 1)
        XCTAssertEqual(loaded.leaseEvidence.byteCount, receipt.byteCount)
        XCTAssertEqual(loaded.leaseEvidence.sha256, receipt.sha256)
        XCTAssertEqual(loaded.leaseEvidence.projectRoot.owner, UInt32(getuid()))
        XCTAssertEqual(loaded.leaseEvidence.framesDirectory.owner, UInt32(getuid()))
    }

    func testProjectBoundVerifiedLoadRejectsHardLinkedSpecialAndOversizeSidecars() throws {
        enum Mutation: CaseIterable {
            case hardLink
            case fifo
            case oversize
        }

        for mutation in Mutation.allCases {
            let project = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: project) }
            let paths = ProjectPaths(root: project)
            try paths.ensureDirectories()
            let artifact = try makeVisualArtifact(count: 4, capacity: 2)
            let receipt = try PhotoSelectionArtifactStore.save(
                artifact,
                to: paths.photoSelectionArtifactURL,
                projectPaths: paths
            )

            switch mutation {
            case .hardLink:
                try FileManager.default.linkItem(
                    at: paths.photoSelectionArtifactURL,
                    to: project.appendingPathComponent("selection-hardlink.json")
                )
            case .fifo:
                try FileManager.default.removeItem(at: paths.photoSelectionArtifactURL)
                XCTAssertEqual(
                    mkfifo(paths.photoSelectionArtifactURL.path, S_IRUSR | S_IWUSR),
                    0
                )
            case .oversize:
                let handle = try FileHandle(forWritingTo: paths.photoSelectionArtifactURL)
                try handle.truncate(
                    atOffset: UInt64(PhotoSelectionArtifactStore.maximumArtifactBytes + 1)
                )
                try handle.close()
            }

            XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
                from: paths.photoSelectionArtifactURL,
                projectPaths: paths,
                expectedByteCount: receipt.byteCount,
                expectedSHA256: receipt.sha256,
                expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
                expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
                expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
                expectedSelectorPolicySHA256: artifact.selectorPolicySHA256
            )) { error in
                XCTAssertEqual(
                    error as? PhotoSelectionArtifactStoreError,
                    .invalidArtifact,
                    "\(mutation)"
                )
            }
        }
    }

    func testProjectBoundVerifiedLoadRejectsFramesDirectoryRebindDuringRead() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)
        let receipt = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let frames = project.appendingPathComponent("Frames", isDirectory: true)
        let heldFrames = project.appendingPathComponent("Frames-held", isDirectory: true)

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256,
            beforeFinalPathValidation: {
                XCTAssertEqual(Darwin.rename(frames.path, heldFrames.path), 0)
                try FileManager.default.createDirectory(
                    at: frames,
                    withIntermediateDirectories: false
                )
                let replacement = frames.appendingPathComponent("photo_selection.json")
                try PhotoSelectionArtifactStore.canonicalData(artifact).write(to: replacement)
                XCTAssertEqual(Darwin.chmod(replacement.path, mode_t(0o600)), 0)
            }
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    func testProjectBoundVerifiedLoadRejectsProjectRootRebindDuringRead() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let project = container.appendingPathComponent("project.easysplatproj", isDirectory: true)
        let heldProject = container.appendingPathComponent("project-held", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let artifact = try makeVisualArtifact(count: 4, capacity: 2)
        let receipt = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )

        XCTAssertThrowsError(try PhotoSelectionArtifactStore.loadProjectBoundVerified(
            from: paths.photoSelectionArtifactURL,
            projectPaths: paths,
            expectedByteCount: receipt.byteCount,
            expectedSHA256: receipt.sha256,
            expectedAnalysisRecipeVersion: artifact.analysisRecipeVersion,
            expectedAnalysisRecipeSHA256: artifact.analysisRecipeSHA256,
            expectedSelectorPolicyVersion: artifact.selectorPolicyVersion,
            expectedSelectorPolicySHA256: artifact.selectorPolicySHA256,
            beforeFinalPathValidation: {
                XCTAssertEqual(Darwin.rename(project.path, heldProject.path), 0)
                try FileManager.default.createDirectory(
                    at: project.appendingPathComponent("Frames", isDirectory: true),
                    withIntermediateDirectories: true
                )
                let replacement = project
                    .appendingPathComponent("Frames", isDirectory: true)
                    .appendingPathComponent("photo_selection.json")
                try PhotoSelectionArtifactStore.canonicalData(artifact).write(to: replacement)
                XCTAssertEqual(Darwin.chmod(replacement.path, mode_t(0o600)), 0)
            }
        )) { error in
            XCTAssertEqual(error as? PhotoSelectionArtifactStoreError, .invalidArtifact)
        }
    }

    private func makeVisualArtifact(
        count: Int,
        capacity: Int
    ) throws -> PhotoSelectionArtifact {
        let evidence = (1...count).map(makeEvidence)
        let retained = try PhotoDiversitySelector.rank(evidence, targetCount: capacity)
        return makeArtifact(
            evidenceInAdmissionOrder: evidence.reversed(),
            retainedInStrategyOrder: retained,
            strategy: .visualDiversity,
            inputOrdering: .unordered,
            requestedPhotoSelection: .automatic,
            admissionCapacity: capacity
        )
    }

    private func makeArtifact(
        evidenceInAdmissionOrder evidence: some Sequence<PhotoAnalysisEvidence>,
        retainedInStrategyOrder retained: [PhotoAnalysisEvidence],
        strategy: PhotoSelectionStrategy,
        inputOrdering: InputOrdering,
        requestedPhotoSelection: PhotoSelection,
        admissionCapacity: Int
    ) -> PhotoSelectionArtifact {
        let admitted = Array(evidence)
        let retainedRanks = Dictionary(
            uniqueKeysWithValues: retained.enumerated().map { ($0.element.sourceSHA256, $0.offset) }
        )
        let candidates = admitted.enumerated().map { ordinal, evidence in
            PhotoSelectionCandidateArtifact(
                admissionOrdinal: ordinal,
                evidence: evidence,
                retainedRank: retainedRanks[evidence.sourceSHA256]
            )
        }
        let retainedSHA256s = retained.map(\.sourceSHA256)
        let canonical = inputOrdering == .continuous
            ? retainedSHA256s
            : retainedSHA256s.sorted()
        return PhotoSelectionArtifact(
            strategy: strategy,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: inputOrdering,
            requestedPhotoSelection: requestedPhotoSelection,
            admissionCapacity: admissionCapacity,
            discoveredCount: admitted.count + 6,
            acceptedCount: admitted.count,
            unreadableCount: 1,
            exactDuplicateCount: 2,
            companionDuplicateCount: 3,
            candidates: candidates,
            retainedSourceSHA256s: retainedSHA256s,
            canonicalRetainedSourceSHA256s: canonical,
            tiePolicyIdentifier: PhotoSelectionArtifact.tiePolicyIdentifier
        )
    }

    private func makeEvidence(_ index: Int) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: String(format: "%064llx", UInt64(index)),
            spatialDescriptor: (0..<PhotoAnalysisEvidence.spatialDescriptorLength).map {
                UInt8(truncatingIfNeeded: index * 41 + $0 * 17)
            },
            qualityBucket: UInt8(255 - (index % 32)),
            dHash: UInt64(index),
            proxyPixelWidth: 8,
            proxyPixelHeight: 8,
            proxyPixelSHA256: String(format: "%064llx", UInt64(index + 10_000)),
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256
        )
    }

    private func replacingRecipe(
        _ evidence: PhotoAnalysisEvidence,
        version: Int,
        sha256: String
    ) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: evidence.sourceSHA256,
            spatialDescriptor: evidence.spatialDescriptor,
            qualityBucket: evidence.qualityBucket,
            dHash: evidence.dHash,
            proxyPixelWidth: evidence.proxyPixelWidth,
            proxyPixelHeight: evidence.proxyPixelHeight,
            proxyPixelSHA256: evidence.proxyPixelSHA256,
            analysisRecipeVersion: version,
            analysisRecipeSHA256: sha256
        )
    }

    private func hash(character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func visibleSelectionPaths(paths: ProjectPaths) throws -> [URL] {
        try visibleSelectionPaths(
            in: paths.root.appendingPathComponent("Frames", isDirectory: true)
        )
    }

    private func visibleSelectionPaths(in frames: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: frames,
            includingPropertiesForKeys: nil
        ).filter { url in
            url.lastPathComponent == "photo_selection.json"
                || url.lastPathComponent.hasPrefix(".photo_selection.json.tmp-")
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSelectionArtifactTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
