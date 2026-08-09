import CryptoKit
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class SubjectIsolationArtifactStoreTests: XCTestCase {
    func testProjectPathsOwnOptionalIsolationLayoutWithoutChangingCanonicalOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let runID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

        XCTAssertEqual(paths.outputSplatURL.path, root.appendingPathComponent("Output/splat.ply").path)
        XCTAssertEqual(paths.isolatedOutputURL.path, root.appendingPathComponent("Output/isolated.ply").path)
        XCTAssertEqual(
            paths.isolationManifestURL.path,
            root.appendingPathComponent("Isolation/isolation_manifest.json").path
        )
        XCTAssertEqual(paths.isolationMasksURL.path, root.appendingPathComponent("Isolation/masks").path)
        XCTAssertEqual(
            paths.isolationStagingURL(for: runID).path,
            root.appendingPathComponent("Isolation/staging/\(runID.uuidString)").path
        )
    }

    func testStrictManifestDecodeRejectsUnknownKeysAndEscapingMaskPaths() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var artifact = try fixture.makeArtifact()
        let encoded = try JSONEncoder().encode(artifact)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["future_field"] = true
        try fixture.writeManifest(object)

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Unknown manifest keys must be invalid.")
        }

        artifact.masks[0].relativePath = "Isolation/masks/../../Output/splat.ply"
        try fixture.writeManifest(artifact)
        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Escaping mask paths must be invalid.")
        }
    }

    func testManifestRejectsMoreThanTwentyFourMasks() throws {
        let fixture = try makeFixture(maskCount: 25)
        defer { fixture.cleanup() }
        let artifact = try fixture.makeArtifact(maskCount: 25)

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                artifact,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        )
    }

    func testLoadClassifiesSourceTrainingAndDatasetIdentityChangesAsStale() throws {
        for mutation in IdentityMutation.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let artifact = try fixture.makeArtifact()
            _ = try SubjectIsolationArtifactStore.publish(
                artifact,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )

            switch mutation {
            case .source:
                try TestFileBuilder.writeMinimalPly(at: fixture.paths.outputSplatURL, vertexCount: 2)
            case .training:
                var training = fixture.training
                training.trainerVersion = "changed-trainer"
                try TrainingArtifactStore.persist(training, paths: fixture.paths)
            case .dataset:
                let image = fixture.paths.trainingURL.appendingPathComponent(
                    "msplat_dataset/images/frame-0.png"
                )
                XCTAssertTrue(
                    try TestFileBuilder.writeGrayscaleImage(
                        url: image,
                        size: 4,
                        value: 7,
                        utType: .png
                    )
                )
            }

            guard case .stale = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("\(mutation) mutation must be stale.")
            }
        }
    }

    func testMissingOutputWithPublishedManifestIsTornAndOptional() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let artifact = try fixture.makeArtifact()
        _ = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        try FileManager.default.removeItem(at: fixture.paths.isolatedOutputURL)

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A manifest without its output must be rejected as torn.")
        }
        XCTAssertNoThrow(try ProjectArtifactValidator.validatedPlyEvidence(at: fixture.paths.outputSplatURL))
    }

    func testLoadRejectsAtomicSubjectOutputReplacementAfterInitialValidation() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let replacement = fixture.paths.outputURL.appendingPathComponent(
            ".isolated-load-replacement.ply"
        )
        let originalBytes = try Data(contentsOf: fixture.paths.isolatedOutputURL)
        let originalIdentity = try testFileIdentity(at: fixture.paths.isolatedOutputURL)
        try originalBytes.write(to: replacement, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(replacement.path, 0o600), 0)

        let result = SubjectIsolationArtifactStore.test_load(
            paths: fixture.paths,
            beforeFinalCanonicalRevalidation: {
                try atomicallyReplaceTestFile(
                    at: fixture.paths.isolatedOutputURL,
                    with: replacement
                )
            }
        )

        guard case .invalid = result else {
            return XCTFail("Load must not return evidence for a replaced subject output inode.")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.isolatedOutputURL), originalBytes)
        XCTAssertNotEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            originalIdentity
        )
    }

    func testPublishAndLoadRejectAllZeroSubjectOutputIdentity() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let zeroIdentity = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        let invalid = try fixture.makeArtifact(outputIdentity: zeroIdentity)

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                invalid,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        ) { error in
            XCTAssertEqual(
                error as? SubjectIsolationArtifactStoreError,
                .invalidArtifact
            )
        }

        var published = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            published,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        published.output.identity = zeroIdentity
        try fixture.writeManifest(published)
        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A persisted all-zero subject output identity must fail closed.")
        }
    }

    func testCopiedPublicationAndSubjectPairCannotAuthorizeDifferentProjectID() throws {
        let projectAID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let projectBID = UUID(uuidString: "AAAAAAAA-2222-4333-8444-555555555555")!
        let source = try makeSubjectIsolationFixture(
            maskCount: 1,
            projectID: projectAID
        )
        defer { source.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            source.makeArtifact(),
            stagedOutputURL: source.stagedOutputURL,
            stagedMasksURL: source.stagedMasksURL,
            paths: source.paths
        )
        let copyParent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: copyParent) }
        let copiedRoot = copyParent.appendingPathComponent(
            "Project-B.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: source.root, to: copiedRoot)
        let copiedPaths = ProjectPaths(root: copiedRoot)
        var copiedMetadata = try ProjectMetadataStore.load(from: copiedPaths.metadataURL)
        copiedMetadata.id = projectBID
        try ProjectMetadataStore.save(copiedMetadata, to: copiedPaths.metadataURL)

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.captureCanonicalPublication(
                paths: copiedPaths
            )
        )
        guard case .stale(.sourceOutput) = SubjectIsolationArtifactStore.load(
            paths: copiedPaths
        ) else {
            return XCTFail("Project A's receipt must not authorize Project B's subject pair.")
        }
    }

    func testSuppliedProjectRootDescriptorIsDuplicatedAndRemainsCallerOwned() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let descriptor = try openTestDirectoryDescriptor(fixture.root)
        defer { Darwin.close(descriptor) }
        var duplicatedDescriptor: Int32?

        try SubjectIsolationArtifactStore.test_withIsolationLock(
            paths: fixture.paths,
            projectRootDescriptor: descriptor,
            shouldCancel: { false },
            didBindProjectRoot: { duplicate in
                duplicatedDescriptor = duplicate
                XCTAssertNotEqual(duplicate, descriptor)
                XCTAssertNotEqual(Darwin.fcntl(duplicate, F_GETFD) & FD_CLOEXEC, 0)
            }
        )

        XCTAssertNotNil(duplicatedDescriptor)
        XCTAssertGreaterThanOrEqual(Darwin.fcntl(descriptor, F_GETFD), 0)
    }

    func testCopiedRootSwapBeforeBindingIsRejectedWithoutTouchingReplacement() throws {
        let fixture = try makeFixture(maskCount: 1)
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacementArtifact = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            replacementArtifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: UUID(),
            after: .newOutputInstalled
        )

        let rootDescriptor = try openTestDirectoryDescriptor(fixture.root)
        let copiedRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "copied-subject-root-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: fixture.root, to: copiedRoot)
        let copiedSnapshot = try testProjectTreeSnapshot(at: copiedRoot)
        var rootsAreSwapped = false
        defer {
            if rootsAreSwapped {
                try? swapTestProjectRoots(fixture.root, copiedRoot)
            }
            Darwin.close(rootDescriptor)
            try? FileManager.default.removeItem(at: copiedRoot)
            fixture.cleanup()
        }

        try swapTestProjectRoots(fixture.root, copiedRoot)
        rootsAreSwapped = true
        guard case .invalid = SubjectIsolationArtifactStore.test_load(
            paths: fixture.paths,
            projectRootDescriptor: rootDescriptor,
            beforeFinalCanonicalRevalidation: {}
        ) else {
            return XCTFail("A copied root at the original pathname must not gain authority.")
        }
        XCTAssertEqual(
            try testProjectTreeSnapshot(at: fixture.root),
            copiedSnapshot,
            "The copied replacement tree must remain byte- and inode-identical."
        )

        try swapTestProjectRoots(fixture.root, copiedRoot)
        rootsAreSwapped = false
        guard case .valid(let reconciled, _) = SubjectIsolationArtifactStore.test_load(
            paths: fixture.paths,
            projectRootDescriptor: rootDescriptor,
            beforeFinalCanonicalRevalidation: {}
        ) else {
            return XCTFail("The descriptor-bound original transaction must reconcile after restore.")
        }
        XCTAssertEqual(reconciled.output.identity, first.output.identity)
        XCTAssertTrue(try subjectPairReservedEntries(paths: fixture.paths).isEmpty)
        XCTAssertEqual(try testProjectTreeSnapshot(at: copiedRoot), copiedSnapshot)
    }

    func testInvalidationUsesOriginalRootAcrossABASwapAtRemovalCheckpoint() throws {
        let fixture = try makeFixture(maskCount: 1)
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(outputIdentity: UUID()),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let replacementPublication = try fixture.installReplacementCanonicalResult(
            vertexCount: 2,
            publicationID: UUID()
        )
        let rootDescriptor = try openTestDirectoryDescriptor(fixture.root)
        let copiedRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "aba-subject-root-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: fixture.root, to: copiedRoot)
        let copiedSnapshot = try testProjectTreeSnapshot(at: copiedRoot)
        var rootsAreSwapped = false
        defer {
            if rootsAreSwapped {
                try? swapTestProjectRoots(fixture.root, copiedRoot)
            }
            Darwin.close(rootDescriptor)
            try? FileManager.default.removeItem(at: copiedRoot)
            fixture.cleanup()
        }

        XCTAssertTrue(
            try SubjectIsolationArtifactStore.test_invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                projectRootDescriptor: rootDescriptor,
                publication: replacementPublication,
                beforeRemoval: {
                    try swapTestProjectRoots(fixture.root, copiedRoot)
                    rootsAreSwapped = true
                },
                afterRemoval: {
                    XCTAssertEqual(
                        try testProjectTreeSnapshot(at: fixture.root),
                        copiedSnapshot
                    )
                    try swapTestProjectRoots(fixture.root, copiedRoot)
                    rootsAreSwapped = false
                }
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolationManifestURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolatedOutputURL.path
        ))
        XCTAssertEqual(try testProjectTreeSnapshot(at: copiedRoot), copiedSnapshot)
    }

    func testCleanupPreservesByteIdenticalForeignReplacementBeforeQuarantine() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(outputIdentity: UUID()),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let originalBytes = try Data(contentsOf: fixture.paths.isolatedOutputURL)
        let foreign = fixture.paths.outputURL.appendingPathComponent(
            ".foreign-before-subject-quarantine.ply"
        )
        try originalBytes.write(to: foreign, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)
        let foreignIdentity = try testFileIdentity(at: foreign)
        let rootDescriptor = try openTestDirectoryDescriptor(fixture.root)
        defer { Darwin.close(rootDescriptor) }
        var replaced = false

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.test_removeValidatedSubject(
                paths: fixture.paths,
                projectRootDescriptor: rootDescriptor,
                willQuarantineOwnedEntry: { original, _ in
                    guard original == "Output/isolated.ply", !replaced else { return }
                    try atomicallyReplaceTestFile(
                        at: fixture.paths.isolatedOutputURL,
                        with: foreign
                    )
                    replaced = true
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SubjectIsolationArtifactStoreError,
                .publicationConflict
            )
        }
        XCTAssertTrue(replaced)
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            foreignIdentity
        )
        XCTAssertEqual(try Data(contentsOf: fixture.paths.isolatedOutputURL), originalBytes)
    }

    func testCleanupPreservesByteIdenticalForeignReplacementBeforeQuarantineUnlink() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(outputIdentity: UUID()),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let originalBytes = try Data(contentsOf: fixture.paths.isolatedOutputURL)
        let foreign = fixture.paths.outputURL.appendingPathComponent(
            ".foreign-before-subject-unlink.ply"
        )
        try originalBytes.write(to: foreign, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)
        let foreignIdentity = try testFileIdentity(at: foreign)
        let rootDescriptor = try openTestDirectoryDescriptor(fixture.root)
        defer { Darwin.close(rootDescriptor) }
        var replaced = false

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.test_removeValidatedSubject(
                paths: fixture.paths,
                projectRootDescriptor: rootDescriptor,
                willUnlinkQuarantinedEntry: { original, quarantine in
                    guard original == "Output/isolated.ply", !replaced else { return }
                    try atomicallyReplaceTestFile(
                        at: fixture.root.appendingPathComponent(quarantine),
                        with: foreign
                    )
                    replaced = true
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SubjectIsolationArtifactStoreError,
                .publicationConflict
            )
        }
        XCTAssertTrue(replaced)
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            foreignIdentity
        )
        XCTAssertEqual(try Data(contentsOf: fixture.paths.isolatedOutputURL), originalBytes)
    }

    func testMalformedOptionalArtifactDoesNotAffectFormatThirtyOneProjectSnapshot() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let video = try TestFileBuilder.writeControlledVideoReceipt(paths: paths)
        let metadata = ProjectMetadata(
            formatVersion: 31,
            title: "Format 31",
            input: .video(files: [video.receipt.projectRelativePath]),
            videoInputReceipts: [video.receipt]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: paths.metadataURL, options: .atomic)
        try FileManager.default.createDirectory(
            at: paths.isolationURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion":1,"unexpected":true}"#.utf8)
            .write(to: paths.isolationManifestURL)

        XCTAssertTrue(ProjectMetadataStore.acceptedFormatVersions.contains(31))
        XCTAssertEqual(
            try ProjectArtifactSnapshotStore.load(projectURL: root).metadata.formatVersion,
            31
        )
        guard case .invalid = SubjectIsolationArtifactStore.load(paths: paths) else {
            return XCTFail("The malformed optional artifact should remain independently invalid.")
        }
    }

    func testAtomicReplacementAndCancellationPreservePreviousValidVersion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        let firstOutput = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let second = try fixture.makeArtifact(outputIdentity: UUID(), vertexCount: 2, maskValue: 2)
        let probe = CancellationProbe(cancelAfter: 2)
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                second,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                shouldCancel: { probe.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        guard case .valid(let restoredArtifact, let restoredOutput)
                = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("The previous subject result must survive cancellation.")
        }
        XCTAssertEqual(restoredArtifact.output.identity, first.output.identity)
        XCTAssertEqual(restoredOutput.sha256, firstOutput.sha256)

        _ = try SubjectIsolationArtifactStore.publish(
            second,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        guard case .valid(let replacedArtifact, let replacedOutput)
                = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("The replacement must load.")
        }
        XCTAssertEqual(replacedArtifact.output.identity, second.output.identity)
        XCTAssertEqual(replacedOutput.gaussianCount, 2)
    }

    func testCrashAfterPreviousOutputMoveRestoresExactPreviousPair() throws {
        try assertInterruptedSubjectPairPublication(
            after: .previousOutputMoved,
            expectsReplacement: false
        )
    }

    func testCrashAfterJournalActivationRestoresExactPreviousPair() throws {
        try assertInterruptedSubjectPairPublication(
            after: .journalActivated,
            expectsReplacement: false
        )
    }

    func testCrashAfterPreviousManifestMoveRestoresExactPreviousPair() throws {
        try assertInterruptedSubjectPairPublication(
            after: .previousManifestMoved,
            expectsReplacement: false
        )
    }

    func testCrashAfterNewOutputInstallRestoresExactPreviousPair() throws {
        try assertInterruptedSubjectPairPublication(
            after: .newOutputInstalled,
            expectsReplacement: false
        )
    }

    func testCrashAfterNewManifestInstallRetainsValidatedReplacement() throws {
        try assertInterruptedSubjectPairPublication(
            after: .newManifestInstalled,
            expectsReplacement: true
        )
    }

    func testRemovalCrashAfterJournalActivationConvergesIdempotently() throws {
        try assertInterruptedSubjectPairRemoval(after: .journalActivated)
    }

    func testRemovalCrashAfterManifestRemovalConvergesIdempotently() throws {
        try assertInterruptedSubjectPairRemoval(after: .manifestRemoved)
    }

    func testRemovalCrashAfterOutputRemovalConvergesIdempotently() throws {
        try assertInterruptedSubjectPairRemoval(after: .outputRemoved)
    }

    func testRemovalCrashAfterMaskRemovalConvergesIdempotently() throws {
        try assertInterruptedSubjectPairRemoval(after: .masksRemoved)
    }

    func testRemovalReconciliationPreservesByteIdenticalForeignOutput() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let artifact = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let outputBytes = try Data(contentsOf: fixture.paths.isolatedOutputURL)
        try SubjectIsolationArtifactStore.test_removeValidatedSubjectInterrupted(
            paths: fixture.paths,
            transactionID: UUID(),
            after: .manifestRemoved
        )
        let replacement = fixture.paths.outputURL.appendingPathComponent(
            ".foreign-retirement-replacement.ply"
        )
        try outputBytes.write(to: replacement, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(replacement.path, 0o600), 0)
        let replacementIdentity = try testFileIdentity(at: replacement)
        try atomicallyReplaceTestFile(
            at: fixture.paths.isolatedOutputURL,
            with: replacement
        )

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Retirement must preserve a foreign replacement and fail closed.")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.isolatedOutputURL), outputBytes)
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            replacementIdentity
        )
        XCTAssertFalse(
            try subjectRetirementReservedEntries(paths: fixture.paths).isEmpty
        )
    }

    func testRemovalReconciliationPreservesLinkedAndSpecialOutputReplacements() throws {
        for replacementKind in SubjectPairUnsafeReplacementKind.allCases {
            let fixture = try makeFixture(maskCount: 1)
            defer { fixture.cleanup() }
            _ = try SubjectIsolationArtifactStore.publish(
                fixture.makeArtifact(outputIdentity: UUID()),
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
            try SubjectIsolationArtifactStore.test_removeValidatedSubjectInterrupted(
                paths: fixture.paths,
                transactionID: UUID(),
                after: .manifestRemoved
            )
            try FileManager.default.removeItem(at: fixture.paths.isolatedOutputURL)
            let external = fixture.root.appendingPathComponent(
                "external-retirement-\(replacementKind)"
            )
            let externalBytes = Data("foreign retirement output".utf8)
            switch replacementKind {
            case .symbolicLink:
                try externalBytes.write(to: external, options: .withoutOverwriting)
                try FileManager.default.createSymbolicLink(
                    at: fixture.paths.isolatedOutputURL,
                    withDestinationURL: external
                )
            case .hardLink:
                try externalBytes.write(to: external, options: .withoutOverwriting)
                XCTAssertEqual(Darwin.chmod(external.path, 0o600), 0)
                XCTAssertEqual(
                    Darwin.link(external.path, fixture.paths.isolatedOutputURL.path),
                    0
                )
            case .fifo:
                XCTAssertEqual(
                    Darwin.mkfifo(fixture.paths.isolatedOutputURL.path, 0o600),
                    0
                )
            }

            guard case .invalid = SubjectIsolationArtifactStore.load(
                paths: fixture.paths
            ) else {
                return XCTFail(
                    "Retirement replacement \(replacementKind) must fail closed."
                )
            }
            var status = stat()
            XCTAssertEqual(
                Darwin.lstat(fixture.paths.isolatedOutputURL.path, &status),
                0
            )
            switch replacementKind {
            case .symbolicLink:
                XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
                XCTAssertEqual(try Data(contentsOf: external), externalBytes)
            case .hardLink:
                XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
                XCTAssertEqual(status.st_nlink, 2)
                XCTAssertEqual(try Data(contentsOf: external), externalBytes)
            case .fifo:
                XCTAssertEqual(status.st_mode & S_IFMT, S_IFIFO)
            }
            XCTAssertFalse(
                try subjectRetirementReservedEntries(paths: fixture.paths).isEmpty
            )
        }
    }

    func testMalformedRetirementJournalIsPreservedAsConflict() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let transactionID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789ABC"
        )!
        let journal = fixture.paths.isolationURL.appendingPathComponent(
            ".subject-retirement-tx-\(transactionID.uuidString.lowercased()).json"
        )
        let malformed = Data(
            #"{"schemaVersion":1,"transactionID":"12345678-1234-4234-8234-123456789ABC","unknown":true}"#.utf8
        )
        try malformed.write(to: journal, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(journal.path, 0o600), 0)
        let identity = try testFileIdentity(at: journal)

        for _ in 0..<2 {
            guard case .invalid = SubjectIsolationArtifactStore.load(
                paths: fixture.paths
            ) else {
                return XCTFail("A malformed retirement journal must fail closed.")
            }
            XCTAssertEqual(try testFileIdentity(at: journal), identity)
            XCTAssertEqual(try Data(contentsOf: journal), malformed)
        }
    }

    func testCrashBeforeJournalActivationKeepsPreviousPairAvailableAndPublishable() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let firstOutputIdentity = try testFileIdentity(at: fixture.paths.isolatedOutputURL)
        let firstManifestIdentity = try testFileIdentity(
            at: fixture.paths.isolationManifestURL
        )
        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let interrupted = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            interrupted,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: UUID(),
            after: .newPairStaged
        )

        for attempt in 0..<2 {
            guard case .valid(let loaded, _) =
                    SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("Attempt \(attempt) hid the untouched previous pair.")
            }
            XCTAssertEqual(loaded.output.identity, first.output.identity)
        }
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            firstOutputIdentity
        )
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolationManifestURL),
            firstManifestIdentity
        )

        let retry = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        XCTAssertNoThrow(
            try SubjectIsolationArtifactStore.publish(
                retry,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        )
        guard case .valid(let loadedRetry, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A fresh transaction token must bypass preserved build residue.")
        }
        XCTAssertEqual(loadedRetry.output.identity, retry.output.identity)
    }

    func testInterruptedPendingJournalDoesNotHideUntouchedPreviousPair() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let transactionID = UUID()
        let token = transactionID.uuidString.lowercased()
        let pending = fixture.paths.isolationURL.appendingPathComponent(
            ".subject-pair-tx-\(token).pending"
        )
        try Data("partial journal build".utf8).write(
            to: pending,
            options: .withoutOverwriting
        )
        XCTAssertEqual(Darwin.chmod(pending.path, 0o600), 0)
        let pendingIdentity = try testFileIdentity(at: pending)

        guard case .valid(let loaded, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A pre-activation pending journal has no commit authority.")
        }
        XCTAssertEqual(loaded.output.identity, first.output.identity)
        XCTAssertEqual(try testFileIdentity(at: pending), pendingIdentity)
    }

    func testFirstPublicationCrashAfterNewOutputInstallRestoresNoArtifact() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let artifact = try fixture.makeArtifact(outputIdentity: UUID())
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: UUID(),
            after: .newOutputInstalled
        )

        for _ in 0..<2 {
            guard case .noArtifact = SubjectIsolationArtifactStore.load(
                paths: fixture.paths
            ) else {
                return XCTFail("An uncommitted first subject must roll back to absence.")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolatedOutputURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolationManifestURL.path
        ))
        XCTAssertTrue(try subjectPairReservedEntries(paths: fixture.paths).isEmpty)
    }

    func testFirstPublicationCrashAfterManifestCommitRetainsValidatedArtifact() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let artifact = try fixture.makeArtifact(outputIdentity: UUID())
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: UUID(),
            after: .newManifestInstalled
        )

        for attempt in 0..<2 {
            guard case .valid(let loaded, _) =
                    SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("Attempt \(attempt) lost the committed first subject.")
            }
            XCTAssertEqual(loaded.output.identity, artifact.output.identity)
        }
        XCTAssertTrue(try subjectPairReservedEntries(paths: fixture.paths).isEmpty)
    }

    func testCommittedSameInodeOutputMutationRestoresExactPreviousPair() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let previousOutputIdentity = try testFileIdentity(at: fixture.paths.isolatedOutputURL)
        let previousManifestIdentity = try testFileIdentity(
            at: fixture.paths.isolationManifestURL
        )
        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            replacement,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: UUID(),
            after: .newManifestInstalled
        )
        let committedIdentity = try testFileIdentity(at: fixture.paths.isolatedOutputURL)
        try mutateFirstByteInPlace(at: fixture.paths.isolatedOutputURL)
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            committedIdentity
        )

        guard case .valid(let restored, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("An invalid committed replacement must restore the previous pair.")
        }
        XCTAssertEqual(restored.output.identity, first.output.identity)
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            previousOutputIdentity
        )
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolationManifestURL),
            previousManifestIdentity
        )
        XCTAssertTrue(try subjectPairReservedEntries(paths: fixture.paths).isEmpty)
    }

    func testCommittedSameInodeOutputTruncationRestoresExactPreviousPair() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let previousOutputIdentity = try testFileIdentity(at: fixture.paths.isolatedOutputURL)
        let previousManifestIdentity = try testFileIdentity(
            at: fixture.paths.isolationManifestURL
        )
        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            replacement,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: UUID(),
            after: .newManifestInstalled
        )
        let committedIdentity = try testFileIdentity(at: fixture.paths.isolatedOutputURL)
        try truncateTestFileInPlace(at: fixture.paths.isolatedOutputURL)
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            committedIdentity
        )

        guard case .valid(let restored, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A truncated committed replacement must restore the previous pair.")
        }
        XCTAssertEqual(restored.output.identity, first.output.identity)
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolatedOutputURL),
            previousOutputIdentity
        )
        XCTAssertEqual(
            try testFileIdentity(at: fixture.paths.isolationManifestURL),
            previousManifestIdentity
        )
        XCTAssertTrue(try subjectPairReservedEntries(paths: fixture.paths).isEmpty)
    }

    func testReplacementJournalAccommodatesLargestValidMaskLabelSets() throws {
        let fixture = try makeFixture(maskCount: IsolationArtifact.maximumMaskCount)
        defer { fixture.cleanup() }
        let allLabels = Array(UInt8(1)...UInt8.max)
        let pixels = [UInt8(0)] + allLabels
        for index in 0..<fixture.maskCount {
            let maskURL = fixture.stagedMasksURL.appendingPathComponent(
                "mask-\(index).png"
            )
            try FileManager.default.removeItem(at: maskURL)
            XCTAssertTrue(
                try writeGrayscalePNG(
                    at: maskURL,
                    width: 16,
                    height: 16,
                    pixels: pixels
                )
            )
        }
        var first = try fixture.makeArtifact(outputIdentity: UUID())
        for index in first.masks.indices {
            first.masks[index].pixelWidth = 16
            first.masks[index].pixelHeight = 16
            first.masks[index].instanceLabels = allLabels
        }
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        XCTAssertNoThrow(
            try SubjectIsolationArtifactStore.publish(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        )
        guard case .valid(let loaded, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A valid worst-case mask manifest must remain replaceable.")
        }
        XCTAssertEqual(loaded.output.identity, replacement.output.identity)
    }

    func testMalformedSubjectPairJournalIsPreservedAsConflict() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let transactionID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let urls = subjectPairTransactionURLs(
            paths: fixture.paths,
            transactionID: transactionID
        )
        let malformed = Data(
            #"{"schemaVersion":1,"transactionID":"11111111-2222-4333-8444-555555555555","unknown":true}"#.utf8
        )
        try malformed.write(to: urls.journal, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(urls.journal.path, 0o600), 0)
        let before = try testFileIdentity(at: urls.journal)

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A malformed transaction journal must fail closed.")
        }
        XCTAssertEqual(try testFileIdentity(at: urls.journal), before)
        XCTAssertEqual(try Data(contentsOf: urls.journal), malformed)

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Repeated reconciliation must preserve the conflict.")
        }
        XCTAssertEqual(try testFileIdentity(at: urls.journal), before)
    }

    func testLinkedAndSpecialJournalReplacementsArePreservedAsConflicts() throws {
        for replacementKind in SubjectPairUnsafeReplacementKind.allCases {
            let fixture = try makeFixture(maskCount: 1)
            defer { fixture.cleanup() }
            let first = try fixture.makeArtifact(outputIdentity: UUID())
            _ = try SubjectIsolationArtifactStore.publish(
                first,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
            try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
            let replacement = try fixture.makeArtifact(
                outputIdentity: UUID(),
                vertexCount: 2,
                maskValue: 2
            )
            let transactionID = UUID()
            let urls = subjectPairTransactionURLs(
                paths: fixture.paths,
                transactionID: transactionID
            )
            try SubjectIsolationArtifactStore.test_publishInterrupted(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                transactionID: transactionID,
                after: .journalActivated
            )
            try FileManager.default.removeItem(at: urls.journal)
            let external = fixture.root.appendingPathComponent(
                "external-journal-\(replacementKind)"
            )
            let externalBytes = Data("foreign journal".utf8)
            switch replacementKind {
            case .symbolicLink:
                try externalBytes.write(to: external, options: .withoutOverwriting)
                try FileManager.default.createSymbolicLink(
                    at: urls.journal,
                    withDestinationURL: external
                )
            case .hardLink:
                try externalBytes.write(to: external, options: .withoutOverwriting)
                XCTAssertEqual(Darwin.chmod(external.path, 0o600), 0)
                XCTAssertEqual(Darwin.link(external.path, urls.journal.path), 0)
            case .fifo:
                XCTAssertEqual(Darwin.mkfifo(urls.journal.path, 0o600), 0)
            }

            guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("Journal replacement \(replacementKind) must fail closed.")
            }
            var replacementStatus = stat()
            XCTAssertEqual(Darwin.lstat(urls.journal.path, &replacementStatus), 0)
            switch replacementKind {
            case .symbolicLink:
                XCTAssertEqual(replacementStatus.st_mode & S_IFMT, S_IFLNK)
                XCTAssertEqual(try Data(contentsOf: external), externalBytes)
            case .hardLink:
                XCTAssertEqual(replacementStatus.st_mode & S_IFMT, S_IFREG)
                XCTAssertEqual(replacementStatus.st_nlink, 2)
                XCTAssertEqual(try Data(contentsOf: external), externalBytes)
            case .fifo:
                XCTAssertEqual(replacementStatus.st_mode & S_IFMT, S_IFIFO)
            }
        }
    }

    func testByteIdenticalPreviousOutputReplacementIsPreservedAsConflict() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        let transactionID = UUID(uuidString: "22222222-3333-4444-8555-666666666666")!
        let urls = subjectPairTransactionURLs(
            paths: fixture.paths,
            transactionID: transactionID
        )
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            replacement,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: transactionID,
            after: .previousOutputMoved
        )
        let originalIdentity = try testFileIdentity(at: urls.previousOutput)
        let bytes = try Data(contentsOf: urls.previousOutput)
        let foreign = fixture.paths.outputURL.appendingPathComponent(
            ".foreign-byte-identical-subject-output"
        )
        try bytes.write(to: foreign, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)
        let foreignIdentity = try testFileIdentity(at: foreign)
        XCTAssertNotEqual(foreignIdentity, originalIdentity)
        try FileManager.default.removeItem(at: urls.previousOutput)
        try FileManager.default.moveItem(at: foreign, to: urls.previousOutput)

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A byte-identical inode replacement must remain a conflict.")
        }
        XCTAssertEqual(try testFileIdentity(at: urls.previousOutput), foreignIdentity)
        XCTAssertEqual(try Data(contentsOf: urls.previousOutput), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.journal.path))
    }

    func testLinkedAndSpecialPreviousOutputReplacementsNeverAuthorizeDeletion() throws {
        for replacementKind in SubjectPairUnsafeReplacementKind.allCases {
            let fixture = try makeFixture(maskCount: 1)
            defer { fixture.cleanup() }
            let first = try fixture.makeArtifact(outputIdentity: UUID())
            _ = try SubjectIsolationArtifactStore.publish(
                first,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
            try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
            let replacement = try fixture.makeArtifact(
                outputIdentity: UUID(),
                vertexCount: 2,
                maskValue: 2
            )
            let transactionID = UUID()
            let urls = subjectPairTransactionURLs(
                paths: fixture.paths,
                transactionID: transactionID
            )
            try SubjectIsolationArtifactStore.test_publishInterrupted(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                transactionID: transactionID,
                after: .previousOutputMoved
            )
            try FileManager.default.removeItem(at: urls.previousOutput)
            let external = fixture.root.appendingPathComponent(
                "external-\(replacementKind)"
            )
            let externalBytes = Data("outside subject transaction".utf8)
            switch replacementKind {
            case .symbolicLink:
                try externalBytes.write(to: external, options: .withoutOverwriting)
                try FileManager.default.createSymbolicLink(
                    at: urls.previousOutput,
                    withDestinationURL: external
                )
            case .hardLink:
                try externalBytes.write(to: external, options: .withoutOverwriting)
                XCTAssertEqual(Darwin.chmod(external.path, 0o600), 0)
                XCTAssertEqual(Darwin.link(external.path, urls.previousOutput.path), 0)
            case .fifo:
                XCTAssertEqual(Darwin.mkfifo(urls.previousOutput.path, 0o600), 0)
            }

            guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("Replacement \(replacementKind) must fail closed.")
            }
            var replacementStatus = stat()
            XCTAssertEqual(Darwin.lstat(urls.previousOutput.path, &replacementStatus), 0)
            switch replacementKind {
            case .symbolicLink:
                XCTAssertEqual(replacementStatus.st_mode & S_IFMT, S_IFLNK)
                XCTAssertEqual(try Data(contentsOf: external), externalBytes)
            case .hardLink:
                XCTAssertEqual(replacementStatus.st_mode & S_IFMT, S_IFREG)
                XCTAssertEqual(replacementStatus.st_nlink, 2)
                XCTAssertEqual(try Data(contentsOf: external), externalBytes)
            case .fifo:
                XCTAssertEqual(replacementStatus.st_mode & S_IFMT, S_IFIFO)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: urls.journal.path))
        }
    }

    func testTransactionJournalRejectsUnknownKeysAndUnsafePaths() throws {
        for mutation in SubjectPairJournalMutation.allCases {
            let fixture = try makeFixture(maskCount: 1)
            defer { fixture.cleanup() }
            let first = try fixture.makeArtifact(outputIdentity: UUID())
            _ = try SubjectIsolationArtifactStore.publish(
                first,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
            try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
            let replacement = try fixture.makeArtifact(
                outputIdentity: UUID(),
                vertexCount: 2,
                maskValue: 2
            )
            let transactionID = UUID()
            let urls = subjectPairTransactionURLs(
                paths: fixture.paths,
                transactionID: transactionID
            )
            try SubjectIsolationArtifactStore.test_publishInterrupted(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                transactionID: transactionID,
                after: .previousOutputMoved
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: urls.journal)
                ) as? [String: Any]
            )
            switch mutation {
            case .unknownKey:
                object["future"] = true
            case .unsafePath:
                var paths = try XCTUnwrap(object["paths"] as? [String: Any])
                paths["previousOutput"] = "../outside.ply"
                object["paths"] = paths
            }
            let mutated = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try FileManager.default.removeItem(at: urls.journal)
            try mutated.write(to: urls.journal, options: .withoutOverwriting)
            XCTAssertEqual(Darwin.chmod(urls.journal.path, 0o600), 0)
            let journalIdentity = try testFileIdentity(at: urls.journal)

            guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("Mutation \(mutation) must fail closed.")
            }
            XCTAssertEqual(try testFileIdentity(at: urls.journal), journalIdentity)
        }
    }

    func testReplacementPreservesForeignFileAtRetiredMaskPath() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let retiredMaskURL = try fixture.paths.resolveProjectRelativePath(
            first.masks[0].relativePath
        )
        try FileManager.default.removeItem(at: retiredMaskURL)
        let foreignBytes = Data("foreign replacement".utf8)
        try foreignBytes.write(to: retiredMaskURL, options: .withoutOverwriting)
        guard Darwin.chmod(retiredMaskURL.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let second = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        _ = try SubjectIsolationArtifactStore.publish(
            second,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: retiredMaskURL.path))
        XCTAssertEqual(try Data(contentsOf: retiredMaskURL), foreignBytes)
    }

    func testReplacementReportsConflictAndPreservesByteIdenticalRetiredMaskInodeSubstitution() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let retiredMaskURL = try fixture.paths.resolveProjectRelativePath(
            first.masks[0].relativePath
        )
        let retiredBytes = try Data(contentsOf: retiredMaskURL)
        var retiredStatus = stat()
        XCTAssertEqual(Darwin.lstat(retiredMaskURL.path, &retiredStatus), 0)

        let foreignMaskURL = retiredMaskURL.deletingLastPathComponent()
            .appendingPathComponent(".foreign-byte-identical-mask-\(UUID().uuidString)")
        try retiredBytes.write(to: foreignMaskURL, options: .withoutOverwriting)
        guard Darwin.chmod(foreignMaskURL.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var foreignStatus = stat()
        XCTAssertEqual(Darwin.lstat(foreignMaskURL.path, &foreignStatus), 0)
        XCTAssertEqual(foreignStatus.st_dev, retiredStatus.st_dev)
        XCTAssertNotEqual(foreignStatus.st_ino, retiredStatus.st_ino)

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        var didSubstitute = false
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.test_publish(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                beforeRetiredMaskCleanup: {
                    didSubstitute = true
                    try FileManager.default.removeItem(at: retiredMaskURL)
                    try FileManager.default.moveItem(
                        at: foreignMaskURL,
                        to: retiredMaskURL
                    )
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SubjectIsolationArtifactStoreError,
                .publicationConflict
            )
        }
        XCTAssertTrue(didSubstitute)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retiredMaskURL.path))
        XCTAssertEqual(try Data(contentsOf: retiredMaskURL), retiredBytes)
        var preservedStatus = stat()
        XCTAssertEqual(Darwin.lstat(retiredMaskURL.path, &preservedStatus), 0)
        XCTAssertEqual(preservedStatus.st_dev, foreignStatus.st_dev)
        XCTAssertEqual(preservedStatus.st_ino, foreignStatus.st_ino)
        guard case .valid(let committed, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("The replacement pair committed before mask retirement failed.")
        }
        XCTAssertEqual(committed.output.identity, replacement.output.identity)
    }

    func testInProcessLockWaitHonorsCancellationBeforeHolderReleases() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        try fixture.paths.ensureIsolationDirectories()
        let holderStarted = DispatchSemaphore(value: 0)
        let holderEntered = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        let holder = SubjectIsolationLockAttempt()
        let holderProcessWait = SubjectIsolationLockAttempt()
        let holderFileWait = SubjectIsolationLockAttempt()

        Thread.detachNewThread {
            holderStarted.signal()
            do {
                try SubjectIsolationArtifactStore.test_withIsolationLock(
                    paths: fixture.paths,
                    shouldCancel: { false },
                    onProcessLockContention: {
                        holderProcessWait.noteContention()
                    },
                    onFileLockContention: {
                        holderFileWait.noteContention()
                    }
                ) {
                    holderEntered.signal()
                    _ = releaseHolder.wait(timeout: .now() + 5)
                }
                holder.finish(with: nil)
            } catch {
                holder.finish(with: error)
            }
        }
        guard holderEntered.wait(timeout: .now() + 2) == .success else {
            releaseHolder.signal()
            _ = holder.finished.wait(timeout: .now() + 2)
            return XCTFail(
                "The first in-process lock holder did not start: "
                    + "scheduled=\(holderStarted.wait(timeout: .now()) == .success), "
                    + "processWait=\(holderProcessWait.didContend), "
                    + "fileWait=\(holderFileWait.didContend), "
                    + "error=\(String(describing: holder.error))"
            )
        }

        let contender = SubjectIsolationLockAttempt()
        Thread.detachNewThread {
            do {
                try SubjectIsolationArtifactStore.test_withIsolationLock(
                    paths: fixture.paths,
                    shouldCancel: { contender.shouldCancel() },
                    onProcessLockContention: { contender.noteContention() }
                ) {
                    contender.noteBodyEntered()
                }
                contender.finish(with: nil)
            } catch {
                contender.finish(with: error)
            }
        }
        guard contender.contention.wait(timeout: .now() + 2) == .success else {
            releaseHolder.signal()
            _ = holder.finished.wait(timeout: .now() + 2)
            return XCTFail("The contender never reached the in-process lock wait.")
        }

        let cancellationStartedAt = DispatchTime.now().uptimeNanoseconds
        contender.cancel()
        let finishedBeforeRelease = contender.finished.wait(timeout: .now() + 1)
        let cancellationElapsed = Double(
            DispatchTime.now().uptimeNanoseconds - cancellationStartedAt
        ) / 1_000_000_000
        releaseHolder.signal()
        _ = holder.finished.wait(timeout: .now() + 2)
        if finishedBeforeRelease != .success {
            _ = contender.finished.wait(timeout: .now() + 2)
        }

        XCTAssertEqual(finishedBeforeRelease, .success)
        XCTAssertTrue(contender.error is CancellationError)
        XCTAssertFalse(contender.bodyEntered)
        XCTAssertNil(holder.error)
        XCTAssertLessThan(cancellationElapsed, 0.75)
    }

    func testDifferentProjectsDoNotShareTheInProcessIsolationLock() throws {
        let rootA = try TestFileBuilder.makeTempDir()
        let rootB = try TestFileBuilder.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let pathsA = ProjectPaths(root: rootA)
        let pathsB = ProjectPaths(root: rootB)
        try pathsA.ensureIsolationDirectories()
        try pathsB.ensureIsolationDirectories()
        let holderStarted = DispatchSemaphore(value: 0)
        let holderEntered = DispatchSemaphore(value: 0)
        let projectBStarted = DispatchSemaphore(value: 0)
        let projectBEntered = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        let holder = SubjectIsolationLockAttempt()
        let holderProcessWait = SubjectIsolationLockAttempt()
        let holderFileWait = SubjectIsolationLockAttempt()
        let projectB = SubjectIsolationLockAttempt()
        let projectBProcessWait = SubjectIsolationLockAttempt()
        let projectBFileWait = SubjectIsolationLockAttempt()

        Thread.detachNewThread {
            holderStarted.signal()
            do {
                try SubjectIsolationArtifactStore.test_withIsolationLock(
                    paths: pathsA,
                    shouldCancel: { false },
                    onProcessLockContention: {
                        holderProcessWait.noteContention()
                    },
                    onFileLockContention: {
                        holderFileWait.noteContention()
                    }
                ) {
                    holderEntered.signal()
                    _ = releaseHolder.wait(timeout: .now() + 5)
                }
                holder.finish(with: nil)
            } catch {
                holder.finish(with: error)
            }
        }
        guard holderEntered.wait(timeout: .now() + 2) == .success else {
            releaseHolder.signal()
            _ = holder.finished.wait(timeout: .now() + 2)
            return XCTFail(
                "Project A did not acquire its isolation lock: "
                    + "scheduled=\(holderStarted.wait(timeout: .now()) == .success), "
                    + "processWait=\(holderProcessWait.didContend), "
                    + "fileWait=\(holderFileWait.didContend), "
                    + "error=\(String(describing: holder.error))"
            )
        }

        Thread.detachNewThread {
            projectBStarted.signal()
            do {
                try SubjectIsolationArtifactStore.test_withIsolationLock(
                    paths: pathsB,
                    shouldCancel: { false },
                    onProcessLockContention: {
                        projectBProcessWait.noteContention()
                    },
                    onFileLockContention: {
                        projectBFileWait.noteContention()
                    }
                ) {
                    projectB.noteBodyEntered()
                    projectBEntered.signal()
                }
                projectB.finish(with: nil)
            } catch {
                projectB.finish(with: error)
            }
        }
        XCTAssertEqual(projectBStarted.wait(timeout: .now() + 2), .success)
        let projectBProgressed = projectBEntered.wait(timeout: .now() + 0.75)
        releaseHolder.signal()
        _ = holder.finished.wait(timeout: .now() + 2)
        _ = projectB.finished.wait(timeout: .now() + 2)

        XCTAssertEqual(
            projectBProgressed,
            .success,
            "Project B contention: process=\(projectBProcessWait.didContend), "
                + "file=\(projectBFileWait.didContend), "
                + "error=\(String(describing: projectB.error))"
        )
        XCTAssertNil(holder.error)
        XCTAssertNil(projectB.error)
        XCTAssertTrue(projectB.bodyEntered)
    }

    func testCrossProcessLockWaitHonorsCancellationBeforeChildReleases() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        try fixture.paths.ensureIsolationDirectories()
        let child = try SubjectIsolationChildFileLock(
            lockURL: fixture.paths.isolationURL.appendingPathComponent(
                ".subject-artifact.lock"
            )
        )
        defer { child.release() }
        let contender = SubjectIsolationLockAttempt()

        Thread.detachNewThread {
            do {
                try SubjectIsolationArtifactStore.test_withIsolationLock(
                    paths: fixture.paths,
                    shouldCancel: { contender.shouldCancel() },
                    onFileLockContention: { contender.noteContention() }
                ) {
                    contender.noteBodyEntered()
                }
                contender.finish(with: nil)
            } catch {
                contender.finish(with: error)
            }
        }
        guard contender.contention.wait(timeout: .now() + 2) == .success else {
            child.release()
            _ = contender.finished.wait(timeout: .now() + 2)
            return XCTFail("The contender never reached the child-held file lock.")
        }

        contender.cancel()
        let finishedBeforeRelease = contender.finished.wait(timeout: .now() + 1)
        XCTAssertTrue(child.isRunning)
        child.release()
        if finishedBeforeRelease != .success {
            _ = contender.finished.wait(timeout: .now() + 2)
        }

        XCTAssertEqual(finishedBeforeRelease, .success)
        XCTAssertTrue(contender.error is CancellationError)
        XCTAssertFalse(contender.bodyEntered)
    }

    func testCancellationAfterMaskCommitRemovesNewMaskAndAllowsExactRetry() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let canonicalBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let firstSubjectBytes = try Data(contentsOf: fixture.paths.isolatedOutputURL)
        let firstManifestBytes = try Data(contentsOf: fixture.paths.isolationManifestURL)
        let firstMaskURL = try fixture.paths.resolveProjectRelativePath(
            first.masks[0].relativePath
        )
        let firstMaskBytes = try Data(contentsOf: firstMaskURL)

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        let replacementMaskURL = try fixture.paths.resolveProjectRelativePath(
            replacement.masks[0].relativePath
        )
        let probe = CommittedMaskCancellationProbe(
            destination: replacementMaskURL,
            expectedSHA256: replacement.masks[0].maskSHA256
        )

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                shouldCancel: { probe.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.completedDestinationCheckCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementMaskURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonicalBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.isolatedOutputURL), firstSubjectBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.isolationManifestURL), firstManifestBytes)
        XCTAssertEqual(try Data(contentsOf: firstMaskURL), firstMaskBytes)

        XCTAssertNoThrow(
            try SubjectIsolationArtifactStore.publish(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        )
        guard case .valid(let retried, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("The exact staged generation must publish after rollback.")
        }
        XCTAssertEqual(retried.output.identity, replacement.output.identity)
    }

    func testCancellationAfterOutputPublicationRestoresPreviousSubjectAndCanonicalBytes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let canonicalBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let firstSubjectBytes = try Data(contentsOf: fixture.paths.isolatedOutputURL)

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        let isolatedOutputURL = fixture.paths.isolatedOutputURL
        let replacementSHA256 = replacement.output.sha256
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                replacement,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                shouldCancel: {
                    (try? GeometryArtifactStore.sha256(
                        of: isolatedOutputURL
                    )) == replacementSHA256
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        guard case .valid(let restored, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Cancellation must restore the previous valid subject.")
        }
        XCTAssertEqual(restored.output.identity, first.output.identity)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.isolatedOutputURL), firstSubjectBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonicalBytes)
    }

    func testCanonicalPublicationUUIDSwapDuringPublishCannotReturnStaleSubject() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let canonicalBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
        let artifact = try fixture.makeArtifact()
        let replacementPublicationID = UUID(
            uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
        )!
        let destinationMask = try fixture.paths.resolveProjectRelativePath(
            artifact.masks[0].relativePath
        )
        let probe = CanonicalPublicationSwapProbe(
            destination: destinationMask,
            expectedSHA256: artifact.masks[0].maskSHA256
        ) {
            try fixture.installPublishedReceipt(
                publicationID: replacementPublicationID
            )
        }

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                artifact,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                shouldCancel: { probe.shouldCancel() }
            )
        )
        XCTAssertNil(probe.operationError)
        XCTAssertTrue(probe.didSwap)
        XCTAssertEqual(
            try PublishedSplatReceiptStore.load(projectPaths: fixture.paths)
                .publicationID,
            replacementPublicationID
        )
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonicalBytes)
        guard case .valid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return
        }
        XCTFail("Publication A must not return or remain valid after canonical UUID B commits.")
    }

    func testLoadRevalidatesCanonicalPublicationImmediatelyBeforeReturning() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let replacementPublicationID = UUID(
            uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
        )!

        let result = SubjectIsolationArtifactStore.test_load(
            paths: fixture.paths,
            beforeFinalCanonicalRevalidation: {
                try fixture.installPublishedReceipt(
                    publicationID: replacementPublicationID
                )
            }
        )

        guard case .valid = result else { return }
        XCTFail("A load of publication A must fail closed when UUID B commits before return.")
    }

    func testTimingOnlyReceiptUpdateDoesNotInvalidateSubjectAuthority() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        let result = SubjectIsolationArtifactStore.test_load(
            paths: fixture.paths,
            beforeFinalCanonicalRevalidation: {
                _ = try PublishedResultPairStore.recordFirstViewerReadyTiming(
                    900,
                    expectedPublicationID: fixture.publicationID,
                    projectPaths: fixture.paths
                )
            }
        )

        guard case .valid(let artifact, _) = result else {
            return XCTFail("Timing-only receipt updates preserve publication authority.")
        }
        XCTAssertEqual(artifact.sourcePublicationID, fixture.publicationID)
    }

    func testNestedReplacementSurvivesOuterCancellationRollback() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let canonicalBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(outputIdentity: UUID()),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let outer = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        let nestedStaging = try fixture.makeIndependentStaging(
            runID: UUID(),
            vertexCount: 3,
            maskValue: 3
        )
        let nested = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 3,
            maskValue: 3,
            stagedOutputURL: nestedStaging.output,
            stagedMasksURL: nestedStaging.masks
        )
        let probe = NestedSubjectPublicationProbe(
            destination: fixture.paths.isolatedOutputURL,
            expectedSHA256: outer.output.sha256
        ) {
            _ = try SubjectIsolationArtifactStore.publish(
                nested,
                stagedOutputURL: nestedStaging.output,
                stagedMasksURL: nestedStaging.masks,
                paths: fixture.paths
            )
        }

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                outer,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                shouldCancel: { probe.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(probe.operationError)
        XCTAssertTrue(probe.didPublish)
        guard case .valid(let loaded, let output) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("The nested replacement must remain authoritative.")
        }
        XCTAssertEqual(loaded.output.identity, nested.output.identity)
        XCTAssertEqual(output.sha256, nested.output.sha256)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonicalBytes)
    }

    func testMaskValidationRejectsCompressedPixelBombBeforeDecode() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let bomb = fixture.stagedMasksURL.appendingPathComponent("mask-0.png")
        XCTAssertTrue(try writeGrayscalePNG(
            at: bomb,
            width: IsolationArtifact.maximumMaskDimension + 1,
            height: IsolationArtifact.maximumMaskDimension + 1,
            value: 1
        ))
        var mask = try fixture.makeArtifact().masks[0]
        mask.pixelWidth = IsolationArtifact.maximumMaskDimension + 1
        mask.pixelHeight = IsolationArtifact.maximumMaskDimension + 1
        mask.maskSHA256 = try GeometryArtifactStore.sha256(of: bomb)
        var reachedDecode = false

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.test_validateMask(
                mask,
                at: bomb,
                shouldCancel: { false },
                beforeDecode: { reachedDecode = true }
            )
        )
        XCTAssertFalse(reachedDecode)
        XCTAssertEqual(IsolationArtifact.maximumDecodedMaskPixelCount, 16_777_216)
    }

    func testMaskValidationAcceptsExactLegalDimensionBoundary() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let boundary = fixture.stagedMasksURL.appendingPathComponent("mask-0.png")
        XCTAssertTrue(try writeGrayscalePNG(
            at: boundary,
            width: IsolationArtifact.maximumMaskDimension,
            height: IsolationArtifact.maximumMaskDimension,
            value: 1
        ))
        var mask = try fixture.makeArtifact().masks[0]
        mask.pixelWidth = IsolationArtifact.maximumMaskDimension
        mask.pixelHeight = IsolationArtifact.maximumMaskDimension
        mask.maskSHA256 = try GeometryArtifactStore.sha256(of: boundary)

        XCTAssertNoThrow(
            try SubjectIsolationArtifactStore.test_validateMask(
                mask,
                at: boundary,
                shouldCancel: { false }
            )
        )
    }

    func testMaskValidationChecksCancellationDuringBoundedReadAndPixelScan() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let mask = try fixture.makeArtifact().masks[0]
        let readProbe = CancellationProbe(cancelAfter: 3)

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.test_validateMask(
                mask,
                at: fixture.stagedMasksURL.appendingPathComponent("mask-0.png"),
                shouldCancel: { readProbe.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(readProbe.checkCount, 3)

        let scanProbe = CancellationProbe(cancelAfter: 9)
        var reachedDecode = false
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.test_validateMask(
                mask,
                at: fixture.stagedMasksURL.appendingPathComponent("mask-0.png"),
                shouldCancel: { scanProbe.shouldCancel() },
                beforeDecode: { reachedDecode = true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(reachedDecode)
        XCTAssertGreaterThanOrEqual(scanProbe.checkCount, 9)
    }

    func testDatasetImageHashChecksCancellationWithinOneLargeFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("retained-image.png")
        try Data(repeating: 0xA5, count: 4 * 1_048_576).write(to: imageURL)
        let probe = CancellationProbe(cancelAfter: 4)

        XCTAssertThrowsError(
            try GeometryArtifactStore.sha256(
                of: imageURL,
                maximumBytes: 512 * 1_048_576,
                shouldCancel: { probe.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 4)
    }

    func testRemovalAndRetrainInvalidationNeverMutateCanonicalBytes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let originalBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        XCTAssertTrue(try SubjectIsolationArtifactStore.removeValidatedSubject(paths: fixture.paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.isolatedOutputURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), originalBytes)

        try fixture.rebuildStaging(vertexCount: 1, maskValue: 1)
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let replacementCanonical = fixture.paths.outputURL.appendingPathComponent("replacement.ply")
        try TestFileBuilder.writeMinimalPly(at: replacementCanonical, vertexCount: 2)
        let replacementEvidence = try ProjectArtifactValidator.publishValidatedPly(
            from: replacementCanonical,
            to: fixture.paths.outputSplatURL
        )
        var replacementTraining = fixture.training
        replacementTraining.trainerVersion = "replacement-trainer"
        replacementTraining.outputSHA256 = replacementEvidence.sha256
        replacementTraining.outputBytes = Int64(replacementEvidence.byteCount)
        replacementTraining.gaussianCount = replacementEvidence.vertexCount
        replacementTraining.sceneBounds = replacementEvidence.sceneBounds
        try TrainingArtifactStore.persist(replacementTraining, paths: fixture.paths)
        try fixture.installPublishedReceipt(publicationID: UUID())
        let replacementPublication =
            try SubjectIsolationArtifactStore.captureCanonicalPublication(
                paths: fixture.paths
            )
        XCTAssertTrue(
            try SubjectIsolationArtifactStore.invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publication: replacementPublication
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.isolatedOutputURL.path))
        XCTAssertEqual(
            try ProjectArtifactValidator.validatedPlyEvidence(at: fixture.paths.outputSplatURL),
            replacementEvidence
        )
    }

    func testRetrainInvalidationHashesCanonicalPlyAtMostOnce() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let replacementCanonical = fixture.paths.outputURL.appendingPathComponent(
            "single-validation-replacement.ply"
        )
        try TestFileBuilder.writeMinimalPly(at: replacementCanonical, vertexCount: 2)
        let replacementEvidence = try ProjectArtifactValidator.publishValidatedPly(
            from: replacementCanonical,
            to: fixture.paths.outputSplatURL
        )
        var replacementTraining = fixture.training
        replacementTraining.trainerVersion = "single-validation-trainer"
        replacementTraining.outputSHA256 = replacementEvidence.sha256
        replacementTraining.outputBytes = Int64(replacementEvidence.byteCount)
        replacementTraining.gaussianCount = replacementEvidence.vertexCount
        replacementTraining.sceneBounds = replacementEvidence.sceneBounds
        try TrainingArtifactStore.persist(replacementTraining, paths: fixture.paths)
        try fixture.installPublishedReceipt(publicationID: UUID())
        let replacementPublication = try SubjectIsolationArtifactStore
            .captureCanonicalPublication(paths: fixture.paths)
        let validationCount = ThreadSafeInvocationCounter()

        XCTAssertTrue(
            try SubjectIsolationArtifactStore.test_invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publication: replacementPublication,
                beforeCanonicalPlyValidation: { validationCount.increment() },
                beforeRemoval: {}
            )
        )
        XCTAssertEqual(validationCount.value, 1)
    }

    func testRetrainInvalidationRequiresReplacementCanonicalPublicationFirst() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let uncommitted = fixture.paths.outputURL.appendingPathComponent("uncommitted.ply")
        try TestFileBuilder.writeMinimalPly(at: uncommitted, vertexCount: 2)
        let uncommittedEvidence = try ProjectArtifactValidator.validatedPlyEvidence(at: uncommitted)
        let current = try SubjectIsolationArtifactStore.captureCanonicalPublication(
            paths: fixture.paths
        )
        let uncommittedPublication = CanonicalSplatPublication(
            publicationID: current.publicationID,
            outputEvidence: uncommittedEvidence,
            trainingManifestSHA256: current.trainingManifestSHA256,
            trainingInputDigest: current.trainingInputDigest,
            trainingGeometryDigest: current.trainingGeometryDigest,
            selectedFramesDigest: current.selectedFramesDigest,
            selectedImageOrder: current.selectedImageOrder
        )

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publication: uncommittedPublication
            )
        )
        guard case .valid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Subject state must remain until canonical publication is proven.")
        }
    }

    func testRetrainInvalidationRejectsCurrentPreRetrainPublicationIdentity() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let currentPublication = try SubjectIsolationArtifactStore.captureCanonicalPublication(
            paths: fixture.paths
        )

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publication: currentPublication
            )
        )
        guard case .valid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Pre-retrain proof must not remove the current subject.")
        }
    }

    func testByteIdenticalPublicationUUIDChangeInvalidatesSubject() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let canonicalBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
        let trainingBytes = try Data(contentsOf: fixture.paths.trainingManifestURL)
        let replacementPublicationID = UUID(
            uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
        )!

        try fixture.installPublishedReceipt(publicationID: replacementPublicationID)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonicalBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.trainingManifestURL), trainingBytes)
        guard case .stale(.sourceOutput) = SubjectIsolationArtifactStore.load(
            paths: fixture.paths
        ) else {
            return XCTFail("A subject from the prior UUID must lose authority immediately.")
        }
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.captureCanonicalPublication(
                paths: fixture.paths,
                expectedPublicationID: fixture.publicationID
            )
        )

        let replacement = try SubjectIsolationArtifactStore.captureCanonicalPublication(
            paths: fixture.paths
        )
        XCTAssertTrue(
            try SubjectIsolationArtifactStore.invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publication: replacement
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolatedOutputURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolationManifestURL.path
        ))
    }

    func testRetrainInvalidationCannotDeleteNestedReplacementPublication() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let canonicalBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(outputIdentity: UUID()),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        let replacementPublicationID = UUID(
            uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
        )!
        try fixture.installPublishedReceipt(publicationID: replacementPublicationID)
        let replacementPublication =
            try SubjectIsolationArtifactStore.captureCanonicalPublication(
                paths: fixture.paths
            )
        let nestedStaging = try fixture.makeIndependentStaging(
            runID: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        let nested = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2,
            sourcePublicationID: replacementPublicationID,
            stagedOutputURL: nestedStaging.output,
            stagedMasksURL: nestedStaging.masks
        )

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.test_invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publication: replacementPublication,
                beforeRemoval: {
                    _ = try SubjectIsolationArtifactStore.publish(
                        nested,
                        stagedOutputURL: nestedStaging.output,
                        stagedMasksURL: nestedStaging.masks,
                        paths: fixture.paths
                    )
                }
            )
        )
        guard case .valid(let loaded, let output) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Invalidation must preserve the nested replacement.")
        }
        XCTAssertEqual(loaded.output.identity, nested.output.identity)
        XCTAssertEqual(output.sha256, nested.output.sha256)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonicalBytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.isolationStagingURL.path
        ))
    }

    func testManifestWithoutSourcePublicationBindingFailsClosed() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        var unboundProposal = try fixture.makeArtifact()
        unboundProposal.sourcePublicationID = nil
        XCTAssertThrowsError(try SubjectIsolationArtifactStore.publish(
            unboundProposal,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )) {
            XCTAssertEqual($0 as? SubjectIsolationArtifactStoreError, .invalidArtifact)
        }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let encoded = try Data(contentsOf: fixture.paths.isolationManifestURL)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            manifest["sourcePublicationID"] as? String,
            fixture.publicationID.uuidString
        )
        manifest.removeValue(forKey: "sourcePublicationID")
        try fixture.writeManifest(manifest)

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("An unbound subject artifact must never inherit result authority.")
        }
    }

    func testRetrainInvalidationLeavesTornOptionalSubjectUntrusted() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        _ = try SubjectIsolationArtifactStore.publish(
            fixture.makeArtifact(),
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        try TestFileBuilder.writeMinimalPly(
            at: fixture.paths.isolatedOutputURL,
            vertexCount: 2
        )
        try fixture.installPublishedReceipt(publicationID: UUID())
        let replacement = try SubjectIsolationArtifactStore.captureCanonicalPublication(
            paths: fixture.paths
        )

        XCTAssertFalse(
            try SubjectIsolationArtifactStore.invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publication: replacement
            ),
            "A torn optional subject must stay untrusted without failing the canonical result."
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.isolatedOutputURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.isolationManifestURL.path
        ))
    }

    func testBackgroundOnlyMaskPublishesAndReloads() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        try fixture.rebuildStaging(vertexCount: 1, maskPixels: Array(repeating: 0, count: 16))
        var artifact = try fixture.makeArtifact()
        artifact.masks[0].instanceLabels = []
        artifact.subjectAnchor = nil
        artifact.masks[0].maskSHA256 = try GeometryArtifactStore.sha256(
            of: fixture.stagedMasksURL.appendingPathComponent("mask-0.png")
        )

        _ = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        guard case .valid(let loaded, _) = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A background-only mask must publish and reload.")
        }
        XCTAssertEqual(loaded.masks[0].instanceLabels, [UInt8]())
    }

    func testMultiLabelMaskPublishesAndReloads() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        try fixture.rebuildStaging(
            vertexCount: 1,
            maskPixels: [0, 2, 9, 0, 2, 9, 0, 0, 2, 9, 0, 0, 0, 0, 0, 0]
        )
        var artifact = try fixture.makeArtifact()
        artifact.masks[0].instanceLabels = [2, 9]
        artifact.masks[0].maskSHA256 = try GeometryArtifactStore.sha256(
            of: fixture.stagedMasksURL.appendingPathComponent("mask-0.png")
        )

        _ = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )

        guard case .valid(let loaded, _) = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("A multi-label mask must publish and reload.")
        }
        XCTAssertEqual(loaded.masks[0].instanceLabels, [2, 9])
    }

    func testMaskLabelDeclarationsRejectZeroDuplicatesUnsortedAndPixelSetMismatch() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        try fixture.rebuildStaging(
            vertexCount: 1,
            maskPixels: [0, 2, 9, 0, 2, 9, 0, 0, 2, 9, 0, 0, 0, 0, 0, 0]
        )
        let expectedDigest = try GeometryArtifactStore.sha256(
            of: fixture.stagedMasksURL.appendingPathComponent("mask-0.png")
        )

        for labels in [[UInt8](arrayLiteral: 0), [2, 2], [9, 2], [2], [2, 9, 10]] {
            var artifact = try fixture.makeArtifact()
            artifact.masks[0].instanceLabels = labels
            artifact.masks[0].maskSHA256 = expectedDigest
            XCTAssertThrowsError(
                try SubjectIsolationArtifactStore.publish(
                    artifact,
                    stagedOutputURL: fixture.stagedOutputURL,
                    stagedMasksURL: fixture.stagedMasksURL,
                    paths: fixture.paths
                ),
                "Labels \(labels) must be rejected."
            )
        }
    }

    func testStrictManifestRejectsSupersededMaskKeysAndUnknownFields() throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let artifact = try fixture.makeArtifact()
        let encoded = try JSONEncoder().encode(artifact)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var mask = try XCTUnwrap(manifest["masks"] as? [[String: Any]]).first!
        mask.removeValue(forKey: "instanceLabels")
        mask["backgroundLabel"] = 0
        mask["subjectLabel"] = 1
        manifest["masks"] = [mask]
        try fixture.writeManifest(manifest)

        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("The superseded mask shape must be rejected.")
        }

        var unknownManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        unknownManifest["unknown"] = true
        try fixture.writeManifest(unknownManifest)
        guard case .invalid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Unknown manifest fields must be rejected.")
        }
    }

    func testHeldOutMetricsAreAllOrNoneAndMeetMedianAndFirstQuartilePolicy() throws {
        let fixture = try makeFixture(maskCount: 3)
        defer { fixture.cleanup() }

        var missingMetric = try fixture.makeArtifact()
        missingMetric.metrics.heldOutMedianIoU = nil
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                missingMetric,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        )

        var belowMedian = try fixture.makeArtifact()
        belowMedian.metrics.heldOutMedianIoU = 0.64
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                belowMedian,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        )

        var belowFirstQuartile = try fixture.makeArtifact()
        belowFirstQuartile.metrics.heldOutFirstQuartileIoU = 0.54
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                belowFirstQuartile,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths
            )
        )
    }

    func testAmbiguityAndAnchorValuesRetainVisionInstanceDetails() throws {
        let imageURL = URL(fileURLWithPath: "/tmp/keyframe.png")
        let maskURL = URL(fileURLWithPath: "/tmp/instances.png")
        let previewURL = URL(fileURLWithPath: "/tmp/preview.png")
        let candidate = SubjectChoiceRequest.Candidate(
            componentIdentity: "component-7",
            instanceLabel: 9,
            confidence: 0.92,
            previewMaskURL: previewURL
        )
        let request = SubjectChoiceRequest(
            keyframeImageURL: imageURL,
            combinedInstanceLabelMaskURL: maskURL,
            pixelWidth: 1920,
            pixelHeight: 1080,
            candidates: [candidate]
        )
        let anchor = SubjectAnchor(
            imageIdentity: "frame-7.png",
            instanceLabel: 9,
            normalizedX: 0.25,
            normalizedY: 0.75
        )

        XCTAssertEqual(request.keyframeImageURL, imageURL)
        XCTAssertEqual(request.combinedInstanceLabelMaskURL, maskURL)
        XCTAssertEqual(request.pixelWidth, 1920)
        XCTAssertEqual(request.pixelHeight, 1080)
        XCTAssertEqual(request.candidates[0].componentIdentity, "component-7")
        XCTAssertEqual(request.candidates[0].instanceLabel, 9)
        XCTAssertEqual(request.candidates[0].previewMaskURL, previewURL)
        XCTAssertEqual(anchor.instanceLabel, 9)
        XCTAssertEqual(anchor.normalizedX, 0.25)
        XCTAssertEqual(anchor.normalizedY, 0.75)
    }

    private func assertInterruptedSubjectPairPublication(
        after checkpoint: SubjectIsolationArtifactStore.SubjectPairPublicationCheckpoint,
        expectsReplacement: Bool
    ) throws {
        let fixture = try makeFixture(maskCount: 1)
        defer { fixture.cleanup() }
        let first = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            first,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let previousOutputBytes = try Data(contentsOf: fixture.paths.isolatedOutputURL)
        let previousManifestBytes = try Data(contentsOf: fixture.paths.isolationManifestURL)
        let previousOutputIdentity = try testFileIdentity(at: fixture.paths.isolatedOutputURL)
        let previousManifestIdentity = try testFileIdentity(
            at: fixture.paths.isolationManifestURL
        )
        let previousMaskURL = try fixture.paths.resolveProjectRelativePath(
            first.masks[0].relativePath
        )
        let previousMaskBytes = try Data(contentsOf: previousMaskURL)

        try fixture.rebuildStaging(vertexCount: 2, maskValue: 2)
        let replacement = try fixture.makeArtifact(
            outputIdentity: UUID(),
            vertexCount: 2,
            maskValue: 2
        )
        let transactionID = UUID()
        try SubjectIsolationArtifactStore.test_publishInterrupted(
            replacement,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths,
            transactionID: transactionID,
            after: checkpoint
        )
        let urls = subjectPairTransactionURLs(
            paths: fixture.paths,
            transactionID: transactionID
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.journal.path))

        let expected = expectsReplacement ? replacement : first
        for attempt in 0..<2 {
            guard case .valid(let artifact, let output) =
                    SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("Reconciliation attempt \(attempt) did not resolve the pair.")
            }
            XCTAssertEqual(artifact.output.identity, expected.output.identity)
            XCTAssertEqual(output.gaussianCount, expectsReplacement ? 2 : 1)
        }

        if !expectsReplacement {
            XCTAssertEqual(
                try Data(contentsOf: fixture.paths.isolatedOutputURL),
                previousOutputBytes
            )
            XCTAssertEqual(
                try Data(contentsOf: fixture.paths.isolationManifestURL),
                previousManifestBytes
            )
            XCTAssertEqual(
                try testFileIdentity(at: fixture.paths.isolatedOutputURL),
                previousOutputIdentity
            )
            XCTAssertEqual(
                try testFileIdentity(at: fixture.paths.isolationManifestURL),
                previousManifestIdentity
            )
            XCTAssertEqual(try Data(contentsOf: previousMaskURL), previousMaskBytes)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: previousMaskURL.path))
        }
        XCTAssertTrue(
            try subjectPairReservedEntries(paths: fixture.paths).isEmpty,
            "Successful reconciliation must retire every transaction-owned path."
        )
    }

    private func assertInterruptedSubjectPairRemoval(
        after checkpoint: SubjectIsolationArtifactStore.SubjectPairRetirementCheckpoint
    ) throws {
        let fixture = try makeFixture(maskCount: 2)
        defer { fixture.cleanup() }
        let artifact = try fixture.makeArtifact(outputIdentity: UUID())
        _ = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: fixture.stagedOutputURL,
            stagedMasksURL: fixture.stagedMasksURL,
            paths: fixture.paths
        )
        let maskURLs = try artifact.masks.map {
            try fixture.paths.resolveProjectRelativePath($0.relativePath)
        }
        try SubjectIsolationArtifactStore.test_removeValidatedSubjectInterrupted(
            paths: fixture.paths,
            transactionID: UUID(),
            after: checkpoint
        )

        for attempt in 0..<2 {
            guard case .noArtifact = SubjectIsolationArtifactStore.load(
                paths: fixture.paths
            ) else {
                return XCTFail("Removal reconciliation attempt \(attempt) did not converge.")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolationManifestURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.isolatedOutputURL.path
        ))
        for maskURL in maskURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: maskURL.path))
        }
        XCTAssertTrue(
            try subjectRetirementReservedEntries(paths: fixture.paths).isEmpty
        )
    }
}

private enum IdentityMutation: CaseIterable {
    case source
    case training
    case dataset
}

private enum SubjectPairJournalMutation: CaseIterable {
    case unknownKey
    case unsafePath
}

private enum SubjectPairUnsafeReplacementKind: CaseIterable, CustomStringConvertible {
    case symbolicLink
    case hardLink
    case fifo

    var description: String {
        switch self {
        case .symbolicLink: "symbolic-link"
        case .hardLink: "hard-link"
        case .fifo: "FIFO"
        }
    }
}

private struct TestFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private struct TestProjectTreeEntrySnapshot: Equatable {
    let relativePath: String
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let linkCount: UInt64
    let byteCount: off_t
    let contentSHA256: String?
    let symbolicLinkDestination: String?
}

private struct SubjectPairTransactionURLs {
    let journal: URL
    let previousOutput: URL
    let previousManifest: URL
    let newOutput: URL
    let newManifest: URL
}

private func subjectPairTransactionURLs(
    paths: ProjectPaths,
    transactionID: UUID
) -> SubjectPairTransactionURLs {
    let token = transactionID.uuidString.lowercased()
    return SubjectPairTransactionURLs(
        journal: paths.isolationURL.appendingPathComponent(
            ".subject-pair-tx-\(token).json"
        ),
        previousOutput: paths.outputURL.appendingPathComponent(
            ".subject-pair-\(token).previous.ply"
        ),
        previousManifest: paths.isolationURL.appendingPathComponent(
            ".subject-pair-\(token).previous-manifest.json"
        ),
        newOutput: paths.outputURL.appendingPathComponent(
            ".subject-pair-\(token).new.ply"
        ),
        newManifest: paths.isolationURL.appendingPathComponent(
            ".subject-pair-\(token).new-manifest.json"
        )
    )
}

private func subjectPairReservedEntries(paths: ProjectPaths) throws -> [String] {
    var entries: [String] = []
    for directory in [paths.outputURL, paths.isolationURL] {
        entries.append(contentsOf: try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix(".subject-pair-") })
    }
    return entries.sorted()
}

private func subjectRetirementReservedEntries(paths: ProjectPaths) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        atPath: paths.isolationURL.path
    ).filter { $0.hasPrefix(".subject-retirement-tx-") }.sorted()
}

private func testFileIdentity(at url: URL) throws -> TestFileIdentity {
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return TestFileIdentity(device: status.st_dev, inode: status.st_ino)
}

private func openTestDirectoryDescriptor(_ url: URL) throws -> Int32 {
    let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR,
          Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    return descriptor
}

private func swapTestProjectRoots(_ first: URL, _ second: URL) throws {
    guard first.deletingLastPathComponent().path
            == second.deletingLastPathComponent().path else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
    }
    let parent = try openTestDirectoryDescriptor(
        first.deletingLastPathComponent()
    )
    defer { Darwin.close(parent) }
    let result = first.lastPathComponent.withCString { firstName in
        second.lastPathComponent.withCString { secondName in
            Darwin.renameatx_np(
                parent,
                firstName,
                parent,
                secondName,
                UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
            )
        }
    }
    guard result == 0, Darwin.fsync(parent) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func testProjectTreeSnapshot(
    at root: URL
) throws -> [TestProjectTreeEntrySnapshot] {
    // FileManager canonicalizes `/var` to `/private/var` while enumerating on
    // macOS. Anchor both the root and descendants to the same spelling so the
    // project-relative snapshot does not acquire a random temporary-directory
    // prefix. Enumeration still uses lstat below and does not follow leaf links.
    let snapshotRoot = root.resolvingSymlinksInPath()
    var entries: [(url: URL, relativePath: String)] = [(snapshotRoot, ".")]
    guard let enumerator = FileManager.default.enumerator(
        at: snapshotRoot,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in false }
    ) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
    }
    for case let url as URL in enumerator {
        let depth = enumerator.level
        guard depth > 0, url.pathComponents.count >= depth else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        entries.append((
            url,
            url.pathComponents.suffix(depth).joined(separator: "/")
        ))
    }
    return try entries.map { entry in
        let url = entry.url
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let type = status.st_mode & S_IFMT
        let contentSHA256: String?
        let symbolicLinkDestination: String?
        if type == S_IFREG {
            contentSHA256 = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
            symbolicLinkDestination = nil
        } else if type == S_IFLNK {
            contentSHA256 = nil
            symbolicLinkDestination = try FileManager.default
                .destinationOfSymbolicLink(atPath: url.path)
        } else {
            contentSHA256 = nil
            symbolicLinkDestination = nil
        }
        return TestProjectTreeEntrySnapshot(
            relativePath: entry.relativePath,
            device: status.st_dev,
            inode: status.st_ino,
            mode: status.st_mode,
            linkCount: UInt64(status.st_nlink),
            byteCount: status.st_size,
            contentSHA256: contentSHA256,
            symbolicLinkDestination: symbolicLinkDestination
        )
    }.sorted { $0.relativePath < $1.relativePath }
}

private func mutateFirstByteInPlace(at url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(descriptor) }
    var byte = UInt8(0)
    guard Darwin.pread(descriptor, &byte, 1, 0) == 1 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    byte ^= 0xff
    guard Darwin.pwrite(descriptor, &byte, 1, 0) == 1,
          Darwin.fsync(descriptor) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func truncateTestFileInPlace(at url: URL) throws {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.ftruncate(descriptor, 0) == 0,
          Darwin.fsync(descriptor) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func atomicallyReplaceTestFile(at destination: URL, with replacement: URL) throws {
    guard destination.deletingLastPathComponent().path
            == replacement.deletingLastPathComponent().path else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
    }
    let parent = Darwin.open(
        destination.deletingLastPathComponent().path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parent >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(parent) }
    let result = replacement.lastPathComponent.withCString { source in
        destination.lastPathComponent.withCString { target in
            Darwin.renameatx_np(
                parent,
                source,
                parent,
                target,
                UInt32(RENAME_NOFOLLOW_ANY)
            )
        }
    }
    guard result == 0, Darwin.fsync(parent) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

struct SubjectIsolationFixture {
    let root: URL
    let paths: ProjectPaths
    let projectID: UUID
    let publicationID: UUID
    let runID: UUID
    let training: TrainingArtifact
    let stagedOutputURL: URL
    let stagedMasksURL: URL
    let maskCount: Int

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func rebuildStaging(vertexCount: Int, maskValue: UInt8) throws {
        try rebuildStaging(
            vertexCount: vertexCount,
            maskPixels: Array(repeating: maskValue, count: 16)
        )
    }

    func rebuildStaging(vertexCount: Int, maskPixels: [UInt8]) throws {
        let staging = paths.isolationStagingURL(for: runID)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: stagedMasksURL, withIntermediateDirectories: true)
        try TestFileBuilder.writeMinimalPly(at: stagedOutputURL, vertexCount: vertexCount)
        for index in 0..<maskCount {
            XCTAssertTrue(
                try writeGrayscalePNG(
                    at: stagedMasksURL.appendingPathComponent("mask-\(index).png"),
                    width: 4,
                    height: 4,
                    pixels: maskPixels
                )
            )
        }
    }

    func makeIndependentStaging(
        runID: UUID,
        vertexCount: Int,
        maskValue: UInt8
    ) throws -> (output: URL, masks: URL) {
        let staging = paths.isolationStagingURL(for: runID)
        let masks = staging.appendingPathComponent("masks", isDirectory: true)
        let output = staging.appendingPathComponent("isolated.ply")
        try FileManager.default.createDirectory(
            at: masks,
            withIntermediateDirectories: true
        )
        try TestFileBuilder.writeMinimalPly(at: output, vertexCount: vertexCount)
        for index in 0..<maskCount {
            XCTAssertTrue(
                try writeGrayscalePNG(
                    at: masks.appendingPathComponent("mask-\(index).png"),
                    width: 4,
                    height: 4,
                    value: maskValue
                )
            )
        }
        return (output, masks)
    }

    func installPublishedReceipt(publicationID: UUID) throws {
        let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.outputSplatURL
        )
        let trainingManifest = try Data(contentsOf: paths.trainingManifestURL)
        let requestedOptions = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced,
            cameraGrouping: .sameCameraAndLens,
            lensProjection: .perspective,
            inputOrdering: .automatic,
            resourcePolicy: .maximumPerformance,
            photoSelection: .useAllValidPhotos
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: .photos(folder: "Originals/Photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        let publishedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let trainingDurationSeconds = try XCTUnwrap(training.elapsedSeconds)
        XCTAssertGreaterThanOrEqual(trainingDurationSeconds, 812.5)
        var geometry = makeGeometryArtifact()
        geometry.residualProvenance = "colmap-text-tracks-v1"
        let receipt = PublishedSplatReceipt(
            publicationID: publicationID,
            projectID: projectID,
            publishedAt: publishedAt,
            outputEvidence: outputEvidence,
            lineage: PublishedSplatLineage(
                trainingManifestSHA256: SHA256.hash(data: trainingManifest)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                trainingInputDigest: training.inputDigest,
                trainingGeometryDigest: training.geometryDigest
            ),
            presentation: PublishedResultPresentation(
                requestedRunOptions: requestedOptions,
                resolvedRunPlan: plan,
                reconstruction: PublishedReconstructionSummary(geometry: geometry),
                orientation: PublishedOrientationSummary(geometry: geometry),
                stageTimings: [
                    StageTimingRecord(
                        stage: .trainSplat,
                        startedAt: publishedAt.addingTimeInterval(-trainingDurationSeconds),
                        durationSeconds: trainingDurationSeconds
                    )
                ],
                autoTunerSnapshot: PublishedAutoTunerSnapshot(resolvedRunPlan: plan),
                trainerVersion: training.trainerVersion,
                runtimeVersion: training.runtimeVersion,
                completedIteration: min(training.completedIteration, plan.trainerIterationLimit),
                trainingDurationSeconds: trainingDurationSeconds,
                createToViewerReadySeconds: nil
            )
        )
        let data = try PublishedSplatReceiptStore.encode(receipt)
        try data.write(to: paths.outputSplatReceiptURL, options: .atomic)
        guard Darwin.chmod(paths.outputSplatReceiptURL.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func installReplacementCanonicalResult(
        vertexCount: Int,
        publicationID: UUID
    ) throws -> CanonicalSplatPublication {
        let candidate = paths.outputURL.appendingPathComponent(
            ".replacement-canonical-\(publicationID.uuidString).ply"
        )
        try TestFileBuilder.writeMinimalPly(
            at: candidate,
            vertexCount: vertexCount
        )
        let evidence = try ProjectArtifactValidator.publishValidatedPly(
            from: candidate,
            to: paths.outputSplatURL
        )
        var replacementTraining = training
        replacementTraining.trainerVersion = "replacement-subject-root-trainer"
        replacementTraining.outputSHA256 = evidence.sha256
        replacementTraining.outputBytes = Int64(evidence.byteCount)
        replacementTraining.gaussianCount = evidence.vertexCount
        replacementTraining.sceneBounds = evidence.sceneBounds
        try TrainingArtifactStore.persist(replacementTraining, paths: paths)
        try installPublishedReceipt(publicationID: publicationID)
        return try SubjectIsolationArtifactStore.captureCanonicalPublication(
            paths: paths
        )
    }

    func makeArtifact(
        outputIdentity: UUID = UUID(),
        maskCount requestedMaskCount: Int? = nil,
        vertexCount: Int = 1,
        maskValue: UInt8 = 1,
        sourcePublicationID: UUID? = nil,
        stagedOutputURL proposedOutputURL: URL? = nil,
        stagedMasksURL proposedMasksURL: URL? = nil
    ) throws -> IsolationArtifact {
        let sourceOutputURL = proposedOutputURL ?? stagedOutputURL
        let sourceMasksURL = proposedMasksURL ?? stagedMasksURL
        let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: sourceOutputURL
        )
        XCTAssertEqual(outputEvidence.vertexCount, vertexCount)
        let count = requestedMaskCount ?? maskCount
        let imageNames = (0..<count).map { "frame-\($0).png" }
        let masks = try (0..<count).map { index in
            let maskURL = sourceMasksURL.appendingPathComponent("mask-\(index).png")
            return IsolationArtifact.Mask(
                relativePath: "Isolation/masks/\(outputIdentity.uuidString)-mask-\(index).png",
                imageIdentity: imageNames[index],
                imageSHA256: try GeometryArtifactStore.sha256(
                    of: paths.trainingURL.appendingPathComponent(
                        "msplat_dataset/images/\(imageNames[index])"
                    )
                ),
                maskSHA256: try GeometryArtifactStore.sha256(of: maskURL),
                pixelWidth: 4,
                pixelHeight: 4,
                instanceLabels: maskValue == 0 ? [] : [maskValue]
            )
        }
        return IsolationArtifact(
            sourcePublicationID: sourcePublicationID ?? publicationID,
            sourcePlySHA256: try GeometryArtifactStore.sha256(of: paths.outputSplatURL),
            trainingManifestSHA256: try GeometryArtifactStore.sha256(of: paths.trainingManifestURL),
            dataset: .init(
                inputDigest: training.inputDigest,
                geometryDigest: training.geometryDigest,
                selectedFramesDigest: training.datasetDerivation.sourceSelectedFramesDigest,
                selectedImageOrder: imageNames
            ),
            masks: masks,
            toolchainBuildIdentity: "test-toolchain-1",
            nativeExecutableSHA256: String(repeating: "8", count: 64),
            visionRequestRevision: 1,
            selectedViewIdentities: Array(imageNames.prefix(max(1, min(imageNames.count, 2)))),
            heldOutViewIdentities: Array(imageNames.dropFirst(max(1, min(imageNames.count, 2)))),
            policy: .init(
                version: 1,
                minimumMaskConfidence: 0.8,
                minimumHeldOutMedianIoU: 0.65,
                minimumHeldOutFirstQuartileIoU: 0.55,
                minimumRetainedGaussianFraction: 0.01,
                maximumRetainedGaussianFraction: 0.95
            ),
            subjectAnchor: SubjectAnchor(
                imageIdentity: imageNames[0],
                instanceLabel: maskValue,
                normalizedX: 0.5,
                normalizedY: 0.5
            ),
            metrics: .init(
                meanMaskConfidence: 0.9,
                heldOutMeanIoU: imageNames.count > 2 ? 0.8 : nil,
                heldOutMedianIoU: imageNames.count > 2 ? 0.8 : nil,
                heldOutFirstQuartileIoU: imageNames.count > 2 ? 0.8 : nil,
                retainedGaussianFraction: 0.5
            ),
            output: .init(
                identity: outputIdentity,
                relativePath: "Output/isolated.ply",
                sha256: outputEvidence.sha256,
                byteCount: outputEvidence.byteCount,
                gaussianCount: outputEvidence.vertexCount,
                sceneBounds: outputEvidence.sceneBounds
            )
        )
    }

    func writeManifest(_ artifact: IsolationArtifact) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: paths.isolationManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(artifact).write(to: paths.isolationManifestURL, options: .atomic)
    }

    func writeManifest(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: paths.isolationManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: paths.isolationManifestURL, options: .atomic)
    }
}

func makeSubjectIsolationFixture(
    maskCount: Int = 3,
    projectID: UUID = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!
) throws -> SubjectIsolationFixture {
    let root = try TestFileBuilder.makeTempDir()
    let paths = ProjectPaths(root: root)
    try paths.ensureDirectories()
    let (_, photoReceipt) = try TestFileBuilder.writeControlledPhotoReceipt(
        paths: paths
    )
    let requestedOptions = RequestedRunOptions(
        capturePath: .orbit,
        detailProfile: .balanced,
        cameraGrouping: .sameCameraAndLens,
        lensProjection: .perspective,
        inputOrdering: .automatic,
        resourcePolicy: .maximumPerformance,
        photoSelection: .useAllValidPhotos
    )
    let input = InputSpec.photos(folder: "Originals/Photos")
    let plan = RunPlanResolver.resolve(
        requestedOptions: requestedOptions,
        input: input,
        hardware: HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        ),
        developmentOverrides: .none
    )
    let selectionArtifact = PhotoSelectionArtifact(
        strategy: .useAll,
        analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
        analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
        selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
        selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
        inputOrdering: plan.inputOrdering,
        requestedPhotoSelection: requestedOptions.photoSelection,
        admissionCapacity: 1,
        discoveredCount: 1,
        acceptedCount: 1,
        unreadableCount: 0,
        exactDuplicateCount: 0,
        companionDuplicateCount: 0,
        candidates: [
            PhotoSelectionCandidateArtifact(
                admissionOrdinal: 0,
                evidence: photoReceipt.analysisEvidence,
                retainedRank: 0
            ),
        ],
        retainedSourceSHA256s: [photoReceipt.source.sha256],
        canonicalRetainedSourceSHA256s: [photoReceipt.source.sha256]
    )
    let selectionFile = try PhotoSelectionArtifactStore.save(
        selectionArtifact,
        to: paths.photoSelectionArtifactURL,
        projectPaths: paths
    )
    let selectionReceipt = PhotoSelectionReceipt(
        projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
        byteCount: selectionFile.byteCount,
        sha256: selectionFile.sha256,
        artifactSchemaVersion: selectionArtifact.schemaVersion,
        analysisRecipeVersion: selectionArtifact.analysisRecipeVersion,
        analysisRecipeSHA256: selectionArtifact.analysisRecipeSHA256,
        selectorPolicyVersion: selectionArtifact.selectorPolicyVersion,
        selectorPolicySHA256: selectionArtifact.selectorPolicySHA256
    )
    try ProjectMetadataStore.save(
        ProjectMetadata(
            id: projectID,
            title: "Subject isolation fixture",
            input: input,
            photoInputReceipts: [photoReceipt],
            photoSelectionReceipt: selectionReceipt,
            requestedRunOptions: requestedOptions,
            resolvedRunPlan: plan
        ),
        to: paths.metadataURL
    )
    try TestFileBuilder.writeMinimalPly(at: paths.outputSplatURL)
    guard Darwin.chmod(paths.outputSplatURL.path, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(at: paths.outputSplatURL)
    var training = makeTrainingArtifact()
    training.outputSHA256 = outputEvidence.sha256
    training.outputBytes = Int64(outputEvidence.byteCount)
    training.gaussianCount = outputEvidence.vertexCount
    training.sceneBounds = outputEvidence.sceneBounds
    training.datasetDerivation.registeredImageNames = (0..<maskCount).map { "frame-\($0).png" }
    let datasetImages = paths.trainingURL.appendingPathComponent(
        "msplat_dataset/images",
        isDirectory: true
    )
    for index in 0..<maskCount {
        XCTAssertTrue(
            try TestFileBuilder.writeGrayscaleImage(
                url: datasetImages.appendingPathComponent("frame-\(index).png"),
                size: 4,
                value: UInt8(index % 255),
                utType: .png
            )
        )
    }
    try TrainingArtifactStore.persist(training, paths: paths)

    let publicationID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let staging = paths.isolationStagingURL(for: runID)
    let stagedMasksURL = staging.appendingPathComponent("masks", isDirectory: true)
    let stagedOutputURL = staging.appendingPathComponent("isolated.ply")
    let fixture = SubjectIsolationFixture(
        root: root,
        paths: paths,
        projectID: projectID,
        publicationID: publicationID,
        runID: runID,
        training: training,
        stagedOutputURL: stagedOutputURL,
        stagedMasksURL: stagedMasksURL,
        maskCount: maskCount
    )
    try fixture.installPublishedReceipt(publicationID: publicationID)
    try fixture.rebuildStaging(vertexCount: 1, maskValue: 1)
    return fixture
}

private func makeFixture(maskCount: Int = 3) throws -> SubjectIsolationFixture {
    try makeSubjectIsolationFixture(maskCount: maskCount)
}

private final class SubjectIsolationLockAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var didSignalContention = false
    private var storedError: Error?
    private var enteredBody = false

    let contention = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    var error: Error? { lock.withLock { storedError } }
    var bodyEntered: Bool { lock.withLock { enteredBody } }
    var didContend: Bool { lock.withLock { didSignalContention } }

    func shouldCancel() -> Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func noteContention() {
        let shouldSignal = lock.withLock {
            guard !didSignalContention else { return false }
            didSignalContention = true
            return true
        }
        if shouldSignal {
            contention.signal()
        }
    }

    func noteBodyEntered() {
        lock.withLock { enteredBody = true }
    }

    func finish(with error: Error?) {
        lock.withLock { storedError = error }
        finished.signal()
    }
}

private final class ThreadSafeInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class SubjectIsolationChildFileLock {
    private let process: Process
    private let standardInput: Pipe
    private let stateLock = NSLock()
    private var released = false

    var isRunning: Bool { process.isRunning }

    init(lockURL: URL) throws {
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            guard FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        }
        guard Darwin.chmod(lockURL.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            "-k",
            lockURL.path,
            "/bin/sh",
            "-c",
            "printf 'ready\\n'; IFS= read -r line"
        ]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = Pipe()
        self.process = process
        self.standardInput = standardInput
        try process.run()
        let ready = standardOutput.fileHandleForReading.readData(ofLength: 6)
        guard ready == Data("ready\n".utf8), process.isRunning else {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
    }

    func release() {
        let shouldRelease = stateLock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }
        try? standardInput.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
        try? standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    deinit {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfter: Int
    private var count = 0

    init(cancelAfter: Int) {
        self.cancelAfter = cancelAfter
    }

    var checkCount: Int {
        lock.withLock { count }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            count += 1
            return count >= cancelAfter
        }
    }
}

private final class CommittedMaskCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let expectedSHA256: String
    private var completedCheckCount = 0

    init(destination: URL, expectedSHA256: String) {
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
    }

    var completedDestinationCheckCount: Int {
        lock.withLock { completedCheckCount }
    }

    func shouldCancel() -> Bool {
        guard (try? GeometryArtifactStore.sha256(of: destination)) == expectedSHA256 else {
            return false
        }
        return lock.withLock {
            completedCheckCount += 1
            return completedCheckCount == 2
        }
    }
}

private final class CanonicalPublicationSwapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let expectedSHA256: String
    private let operation: () throws -> Void
    private var swapped = false
    private var storedError: Error?

    init(
        destination: URL,
        expectedSHA256: String,
        operation: @escaping () throws -> Void
    ) {
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
        self.operation = operation
    }

    var didSwap: Bool { lock.withLock { swapped } }
    var operationError: Error? { lock.withLock { storedError } }

    func shouldCancel() -> Bool {
        guard (try? GeometryArtifactStore.sha256(of: destination)) == expectedSHA256 else {
            return false
        }
        let shouldRun = lock.withLock {
            guard !swapped else { return false }
            swapped = true
            return true
        }
        guard shouldRun else { return false }
        do {
            try operation()
        } catch {
            lock.withLock { storedError = error }
        }
        return false
    }
}

private final class NestedSubjectPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let expectedSHA256: String
    private let operation: () throws -> Void
    private var published = false
    private var storedError: Error?

    init(
        destination: URL,
        expectedSHA256: String,
        operation: @escaping () throws -> Void
    ) {
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
        self.operation = operation
    }

    var didPublish: Bool { lock.withLock { published } }
    var operationError: Error? { lock.withLock { storedError } }

    func shouldCancel() -> Bool {
        guard (try? GeometryArtifactStore.sha256(of: destination)) == expectedSHA256 else {
            return false
        }
        let shouldRun = lock.withLock {
            guard !published else { return false }
            published = true
            return true
        }
        guard shouldRun else { return false }
        do {
            try operation()
        } catch {
            lock.withLock { storedError = error }
        }
        return true
    }
}

private func writeGrayscalePNG(
    at url: URL,
    width: Int,
    height: Int,
    value: UInt8
) throws -> Bool {
    let pixelCount = try XCTUnwrap(
        width.multipliedReportingOverflow(by: height).overflow
            ? nil
            : width * height
    )
    return try writeGrayscalePNG(
        at: url,
        width: width,
        height: height,
        pixels: [UInt8](repeating: value, count: pixelCount)
    )
}

private func writeGrayscalePNG(
    at url: URL,
    width: Int,
    height: Int,
    pixels: [UInt8]
) throws -> Bool {
    guard pixels.count == width * height else {
        return false
    }
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}
