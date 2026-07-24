import CryptoKit
import CoreGraphics
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
}

private enum IdentityMutation: CaseIterable {
    case source
    case training
    case dataset
}

struct SubjectIsolationFixture {
    let root: URL
    let paths: ProjectPaths
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

    func makeArtifact(
        outputIdentity: UUID = UUID(),
        maskCount requestedMaskCount: Int? = nil,
        vertexCount: Int = 1,
        maskValue: UInt8 = 1
    ) throws -> IsolationArtifact {
        let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(at: stagedOutputURL)
        XCTAssertEqual(outputEvidence.vertexCount, vertexCount)
        let count = requestedMaskCount ?? maskCount
        let imageNames = (0..<count).map { "frame-\($0).png" }
        let masks = try (0..<count).map { index in
            let maskURL = stagedMasksURL.appendingPathComponent("mask-\(index).png")
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

func makeSubjectIsolationFixture(maskCount: Int = 3) throws -> SubjectIsolationFixture {
    let root = try TestFileBuilder.makeTempDir()
    let paths = ProjectPaths(root: root)
    try paths.ensureDirectories()
    try TestFileBuilder.writeMinimalPly(at: paths.outputSplatURL)
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

    let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let staging = paths.isolationStagingURL(for: runID)
    let stagedMasksURL = staging.appendingPathComponent("masks", isDirectory: true)
    let stagedOutputURL = staging.appendingPathComponent("isolated.ply")
    let fixture = SubjectIsolationFixture(
        root: root,
        paths: paths,
        runID: runID,
        training: training,
        stagedOutputURL: stagedOutputURL,
        stagedMasksURL: stagedMasksURL,
        maskCount: maskCount
    )
    try fixture.rebuildStaging(vertexCount: 1, maskValue: 1)
    return fixture
}

private func makeFixture(maskCount: Int = 3) throws -> SubjectIsolationFixture {
    try makeSubjectIsolationFixture(maskCount: maskCount)
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
