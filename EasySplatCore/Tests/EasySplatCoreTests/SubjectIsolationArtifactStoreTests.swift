import CryptoKit
import Foundation
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
            title: "Format 31",
            input: .video(files: [video.receipt.projectRelativePath]),
            videoInputReceipts: [video.receipt]
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try FileManager.default.createDirectory(
            at: paths.isolationURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion":1,"unexpected":true}"#.utf8)
            .write(to: paths.isolationManifestURL)

        XCTAssertEqual(ProjectMetadataStore.supportedFormatVersion, 31)
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
        var checks = 0
        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.publish(
                second,
                stagedOutputURL: fixture.stagedOutputURL,
                stagedMasksURL: fixture.stagedMasksURL,
                paths: fixture.paths,
                shouldCancel: {
                    checks += 1
                    return checks >= 2
                }
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
        XCTAssertTrue(
            try SubjectIsolationArtifactStore.invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publishedCanonicalOutput: replacementEvidence
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

        XCTAssertThrowsError(
            try SubjectIsolationArtifactStore.invalidateAfterCanonicalRetraining(
                paths: fixture.paths,
                publishedCanonicalOutput: uncommittedEvidence
            )
        )
        guard case .valid = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Subject state must remain until canonical publication is proven.")
        }
    }
}

private enum IdentityMutation: CaseIterable {
    case source
    case training
    case dataset
}

private struct SubjectIsolationFixture {
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
        let staging = paths.isolationStagingURL(for: runID)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: stagedMasksURL, withIntermediateDirectories: true)
        try TestFileBuilder.writeMinimalPly(at: stagedOutputURL, vertexCount: vertexCount)
        for index in 0..<maskCount {
            XCTAssertTrue(
                try TestFileBuilder.writeGrayscaleImage(
                    url: stagedMasksURL.appendingPathComponent("mask-\(index).png"),
                    size: 4,
                    value: maskValue,
                    utType: .png
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
                backgroundLabel: 0,
                subjectLabel: maskValue
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
                minimumHeldOutIoU: 0.65,
                minimumRetainedGaussianFraction: 0.01,
                maximumRetainedGaussianFraction: 0.95
            ),
            subjectAnchor: SubjectAnchor(
                imageIdentity: imageNames[0],
                normalizedX: 0.5,
                normalizedY: 0.5
            ),
            metrics: .init(
                meanMaskConfidence: 0.9,
                heldOutMeanIoU: imageNames.count > 2 ? 0.8 : nil,
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

private func makeFixture(maskCount: Int = 3) throws -> SubjectIsolationFixture {
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
