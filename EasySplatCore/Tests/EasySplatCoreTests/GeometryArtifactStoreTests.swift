import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryArtifactStoreTests: XCTestCase {
    func testValidateAcceptsCurrentTrustedCanonicalSnapshot() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let measured = try ColmapResidualAnalyzer.analyze(modelDirectory: model)
        let snapshot = try GeometryModelSnapshot.capture(in: model)

        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(
                makeArtifact(fixture: fixture),
                projectPaths: paths,
                measuredResiduals: measured,
                verifiedSourceSnapshot: snapshot
            )
        )
    }

    func testValidateRejectsInvalidTimingEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        for timings in [
            [:],
            ["  ": 1],
            ["sfmMapping": -0.01],
            ["sfmMapping": Double.nan],
            ["sfmMapping": 1],
            ["sfmMapping": 1, "orientation_seconds": 0.01],
        ] {
            var artifact = makeArtifact(fixture: fixture)
            artifact.timings = timings
            XCTAssertThrowsError(
                try GeometryArtifactStore.validate(artifact, projectPaths: paths)
            ) { error in
                XCTAssertEqual(
                    error as? GeometryArtifactStore.Error,
                    .invalidTimings
                )
            }
        }
    }

    func testLoadRejectsSchemaNineBeforeDecodingRetiredMappingState() throws {
        let baselineSchemaVersion = GeometryArtifact.currentSchemaVersion - 1
        XCTAssertEqual(baselineSchemaVersion, 9)

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(makeArtifact(fixture: fixture))
            ) as? [String: Any]
        )
        object["schemaVersion"] = baselineSchemaVersion
        object.removeValue(forKey: "mapping")
        try JSONSerialization.data(withJSONObject: object).write(
            to: paths.geometryManifestURL
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidSchema(baselineSchemaVersion)
            )
        }
    }

    func testPersistsRelativeMeasuredArtifactToSidecarAndMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Measured",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let artifact = makeArtifact(fixture: fixture)

        try GeometryArtifactStore.persist(artifact, metadata: &metadata, paths: paths)

        XCTAssertEqual(
            try GeometryArtifactStore.load(from: paths.geometryManifestURL, projectPaths: paths),
            artifact
        )
        XCTAssertEqual(try ProjectMetadataStore.load(from: paths.metadataURL).geometryArtifact, artifact)
        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.geometryManifestURL))
                as? [String: Any]
        )
        XCTAssertEqual(
            (sidecar["pairGraph"] as? [String: Any])?["status"] as? String,
            "measured"
        )
        XCTAssertNil((sidecar["pairGraph"] as? [String: Any])?["mappingAttemptNumber"])
        XCTAssertNil((sidecar["pairGraph"] as? [String: Any])?["bundleAdjustmentCycleCount"])
        XCTAssertEqual((sidecar["mapping"] as? [String: Any])?["modelCount"] as? Int, 1)
        XCTAssertEqual(
            (sidecar["mapping"] as? [String: Any])?["acceptedRefinementKind"] as? String,
            "incrementalGlobal"
        )
        XCTAssertEqual(
            (sidecar["canonicalOrientation"] as? [String: Any])?["status"] as? String,
            "unresolved"
        )
    }

    func testLoadRejectsSymlinkedGeometryManifest() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = ProjectPaths(
            root: parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let outside = parent.appendingPathComponent("outside-geometry.json")
        try JSONEncoder().encode(makeArtifact(fixture: fixture)).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.geometryManifestURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        )
    }

    func testLoadRejectsOversizedOtherwiseDecodableGeometryManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(makeArtifact(fixture: fixture))
            ) as? [String: Any]
        )
        object["ignoredPadding"] = String(repeating: "x", count: 1_048_576)
        let oversized = try JSONSerialization.data(withJSONObject: object)
        XCTAssertGreaterThan(oversized.count, 1_048_576)
        try oversized.write(to: paths.geometryManifestURL)

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        )
    }

    func testLoadRejectsNonRegularGeometryManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.geometryManifestURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        )
    }

    func testPersistRejectsSymlinkedPreviousManifestWithoutTouchingTarget() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = ProjectPaths(
            root: parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Measured",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let outside = parent.appendingPathComponent("outside-geometry.json")
        let sentinel = Data("do not replace".utf8)
        try sentinel.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.geometryManifestURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try GeometryArtifactStore.persist(
                makeArtifact(fixture: fixture),
                metadata: &metadata,
                paths: paths
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        XCTAssertNil(metadata.geometryArtifact)
    }

    func testPersistRestoresPreviousManifestWhenMetadataSaveFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Measured",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let previousManifest = Data("previous manifest bytes".utf8)
        try previousManifest.write(to: paths.geometryManifestURL)
        metadata.input = .photos(folder: String(repeating: "x", count: 8 * 1_024 * 1_024))

        XCTAssertThrowsError(
            try GeometryArtifactStore.persist(
                makeArtifact(fixture: fixture),
                metadata: &metadata,
                paths: paths
            )
        )

        XCTAssertEqual(try Data(contentsOf: paths.geometryManifestURL), previousManifest)
        XCTAssertNil(metadata.geometryArtifact)
    }

    func testRejectsEscapingCanonicalPathAndPlaceholderResidualProvenance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var escaping = makeArtifact(fixture: fixture)
        escaping.sourceModelPath = "../outside"
        XCTAssertThrowsError(try GeometryArtifactStore.validate(escaping, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidSourceModelPath)
        }

        let alternate = try paths.resolveProjectRelativePath("SfM/alternate")
        try FileManager.default.copyItem(
            at: paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true),
            to: alternate
        )
        var inBundleButNotCanonical = makeArtifact(fixture: fixture)
        inBundleButNotCanonical.sourceModelPath = "SfM/alternate"
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(inBundleButNotCanonical, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidSourceModelPath)
        }

        var placeholder = makeArtifact(fixture: fixture)
        placeholder.residualProvenance = "mapper-summary"
        XCTAssertThrowsError(try GeometryArtifactStore.validate(placeholder, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidResiduals)
        }

        var unmeasuredMemory = makeArtifact(fixture: fixture)
        unmeasuredMemory.peakMemoryBytes = 0
        XCTAssertThrowsError(try GeometryArtifactStore.validate(unmeasuredMemory, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPeakMemory)
        }
    }

    func testRejectsCanonicalModelWhoseContentsNoLongerMatchManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let artifact = makeArtifact(fixture: fixture)

        try "tampered\n".write(
            to: paths.colmapSparseURL.appendingPathComponent("0/images.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .modelHashMismatch("images.txt")
            )
        }
    }

    func testRejectsHardLinkedCanonicalModelFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let artifact = makeArtifact(fixture: fixture)
        let imagesURL = paths.colmapSparseURL.appendingPathComponent("0/images.txt")
        let externalURL = root.appendingPathComponent("hardlinked-images.txt")
        try FileManager.default.moveItem(at: imagesURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, imagesURL.path), 0)

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .modelHashMismatch("images.txt")
            )
        }
    }

    func testSelectedFramesDigestRejectsHardLinkedFrame() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        _ = try writeCanonicalModel(at: paths)
        let frameURL = paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg")
        let externalURL = root.appendingPathComponent("hardlinked-frame.jpg")
        try FileManager.default.moveItem(at: frameURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, frameURL.path), 0)

        XCTAssertThrowsError(
            try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: ["frame_000001.jpg"],
                projectPaths: paths
            )
        )
    }

    func testInputDigestRejectsHardLinkedOriginal() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        _ = try writeCanonicalModel(at: paths)
        let inputURL = paths.originalsURL.appendingPathComponent("source.jpg")
        let externalURL = root.appendingPathComponent("hardlinked-input.jpg")
        try FileManager.default.moveItem(at: inputURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, inputURL.path), 0)

        XCTAssertThrowsError(try GeometryArtifactStore.inputDigest(projectPaths: paths))
    }

    func testRejectsLearnedInitializerChangedAfterGeometryAcceptance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths, observationCount: 20)
        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent("learned_points3D.txt")
        try FileManager.default.createDirectory(
            at: paths.colmapSeedModelURL,
            withIntermediateDirectories: true
        )
        try "1 1 2 3 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )
        let digest = try GeometryArtifactStore.sha256(of: learnedURL)
        var artifact = makeArtifact(fixture: fixture)
        artifact.modelVersion = "DA3-SMALL@89abcdef0123456789abcdef0123456789abcdef"
        artifact.provenance.runtime = GeometryComponentProvenance(
            identifier: "da3_mps",
            version: "main",
            revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
            payloadSHA256: String(repeating: "b", count: 64)
        )
        artifact.provenance.model = GeometryComponentProvenance(
            identifier: "DA3-SMALL",
            version: "apache-2.0-release",
            revision: "89abcdef0123456789abcdef0123456789abcdef",
            payloadSHA256: String(repeating: "c", count: 64)
        )
        artifact.learnedPointInitializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: digest,
            pointCount: 1
        )
        artifact.pairGraph = .notEvaluated()
        artifact.mapping.acceptedRefinementKind = .seededBundleAdjustment
        artifact.mapping.incrementalCadence = nil
        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))

        var fabricatedInvocationCount = artifact
        fabricatedInvocationCount.mapping.acceptedRefinementInvocationCount = 2
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedInvocationCount, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }

        var fabricatedIncrementalRoute = artifact
        fabricatedIncrementalRoute.mapping.acceptedRefinementKind = .incrementalGlobal
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedIncrementalRoute, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }

        try "1 9 8 7 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .learnedInitializerDigestMismatch
            )
        }
    }

    func testRejectsResidualsAndFrameDigestsThatDoNotMatchHashedArtifacts() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var fabricatedResiduals = makeArtifact(fixture: fixture)
        fabricatedResiduals.medianPixelResidual = 0.1
        fabricatedResiduals.p90PixelResidual = 0.1
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedResiduals, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .measuredResidualMismatch)
        }

        var staleFrames = makeArtifact(fixture: fixture)
        staleFrames.selectedFramesDigest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(staleFrames, projectPaths: paths)
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .artifactDigestMismatch("selected frames")
            )
        }
    }

    func testCurrentSchemaRequiresCompleteToolchainProvenance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths, observationCount: 20)

        var artifact = makeArtifact(fixture: fixture)
        artifact.provenance.solver.identifier = ""
        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidProvenance)
        }

        artifact = makeArtifact(fixture: fixture)
        let modelRevision = "89abcdef0123456789abcdef0123456789abcdef"
        artifact.modelVersion = "DA3-SMALL@\(modelRevision)"
        artifact.provenance = GeometryProvenance(
            toolchainVersion: "2.0.0",
            solver: GeometryComponentProvenance(
                identifier: "colmap",
                version: "4.1.0",
                revision: "fa8e3b3ff591552855f8ad2806723c80f963f69c",
                payloadSHA256: String(repeating: "a", count: 64)
            ),
            runtime: GeometryComponentProvenance(
                identifier: "da3_mps",
                version: "main",
                revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
                payloadSHA256: String(repeating: "b", count: 64)
            ),
            model: GeometryComponentProvenance(
                identifier: "DA3-SMALL",
                version: "apache-2.0-release",
                revision: modelRevision,
                payloadSHA256: String(repeating: "c", count: 64)
            )
        )
        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent("learned_points3D.txt")
        try FileManager.default.createDirectory(
            at: paths.colmapSeedModelURL,
            withIntermediateDirectories: true
        )
        try "1 1 2 3 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )
        artifact.learnedPointInitializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: try GeometryArtifactStore.sha256(of: learnedURL),
            pointCount: 1
        )
        artifact.pairGraph = .notEvaluated()
        artifact.mapping.acceptedRefinementKind = .seededBundleAdjustment
        artifact.mapping.incrementalCadence = nil

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))
    }

    func testRejectsRetiredGeometrySchema() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var artifact = makeArtifact(fixture: fixture)
        artifact.schemaVersion = 1

        XCTAssertThrowsError(try GeometryArtifactStore.validate(artifact, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidSchema(1))
        }
    }

    func testLoadRejectsFutureSchemaBeforeDecodingItsPayload() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let futureSchemaVersion = GeometryArtifact.currentSchemaVersion + 1
        let payload = #"{"schemaVersion":\#(futureSchemaVersion),"futurePayload":true}"#
        try Data(payload.utf8)
            .write(to: paths.geometryManifestURL)

        XCTAssertThrowsError(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .invalidSchema(futureSchemaVersion)
            )
        }
    }

    func testAcceptsMeasuredPairGraphAndExplicitUnresolvedOrientation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        var artifact = makeDescriptorlessMeasuredArtifact(fixture: fixture)
        artifact.canonicalOrientation = CanonicalOrientationArtifact(
            status: .unresolved,
            method: nil,
            sourceToCanonicalQuaternionWXYZ: nil,
            evidence: nil,
            canonicalOpeningViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
        )

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))

        artifact.mapping.largestModelRegisteredViewCount = 10
        artifact.mapping.secondLargestModelRegisteredViewCount = 9
        artifact.mapping.unionRegisteredViewCount = 10
        XCTAssertNoThrow(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths),
            "An unanalyzable model can be larger than the accepted model without erasing it from mapping evidence."
        )

        var disconnected = artifact
        disconnected.pairGraph.measurement?.connectedComponentCount = 3
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(disconnected, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        var failedAcceptedAttempt = artifact
        failedAcceptedAttempt.pairGraph.measurement?.matcherAttempts[0].outcome = .failed
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(failedAcceptedAttempt, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testMeasuredPairGraphAllowsOnlyDescriptorlessUnregisteredViews() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        var artifact = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))

        artifact.registeredViewCount = 10
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        artifact.registeredViewCount = 9
        artifact.pairGraph.measurement?.descriptorlessViewCount = .min
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(artifact, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testMeasuredPairGraphValidatesSingleAndMultipleBiconnectedBlocks() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        let multipleBlocks = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        XCTAssertNoThrow(try GeometryArtifactStore.validate(multipleBlocks, projectPaths: paths))

        var singleBlock = multipleBlocks
        singleBlock.pairGraph.measurement?.rawMatchedPairCount = 9
        singleBlock.pairGraph.measurement?.spatiallyVerifiedPairCount = 9
        singleBlock.pairGraph.measurement?.matcherAttempts[0].rawMatchedPairCount = 9
        singleBlock.pairGraph.measurement?.matcherAttempts[0].spatiallyVerifiedPairCount = 9
        singleBlock.pairGraph.measurement?.articulationViewCount = 0
        singleBlock.pairGraph.measurement?.biconnectedBlockCount = 1
        singleBlock.pairGraph.measurement?.largestBiconnectedBlockViewCount = 9
        singleBlock.pairGraph.measurement?.secondLargestBiconnectedBlockViewCount = 0

        XCTAssertNoThrow(try GeometryArtifactStore.validate(singleBlock, projectPaths: paths))

        singleBlock.pairGraph.measurement?.largestBiconnectedBlockViewCount = 8
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(singleBlock, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        var multipleWithoutArticulation = multipleBlocks
        multipleWithoutArticulation.pairGraph.measurement?.articulationViewCount = 0
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(multipleWithoutArticulation, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }
    }

    func testMappingArtifactAcceptsOverlappingModelsAndDetailedRecovery() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        var artifact = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        artifact.mapping = MappingArtifact(
            modelCount: 3,
            largestModelRegisteredViewCount: 9,
            secondLargestModelRegisteredViewCount: 8,
            unionRegisteredViewCount: 9,
            attemptCount: 2,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 0,
            incrementalCadence: IncrementalMappingCadenceArtifact(
                localMaxRefinements: 2,
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5
            ),
            fallbackReason: "normal graph missed coverage; denser graph accepted"
        )

        XCTAssertNoThrow(try GeometryArtifactStore.validate(artifact, projectPaths: paths))
    }

    func testMappingArtifactRejectsFabricatedCountsAndFallbacks() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        let baseline = makeArtifact(fixture: fixture)

        var invalidMappings: [MappingArtifact] = []
        for mutate in [
            { (mapping: inout MappingArtifact) in mapping.modelCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.largestModelRegisteredViewCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.largestModelRegisteredViewCount = 2 },
            { (mapping: inout MappingArtifact) in mapping.secondLargestModelRegisteredViewCount = 1 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 2 },
            { (mapping: inout MappingArtifact) in mapping.attemptCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.acceptedRefinementInvocationCount = -1 },
            { (mapping: inout MappingArtifact) in mapping.incrementalCadence = nil },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.localMaxRefinements = 0
            },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.globalFramesRatio = 1
            },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.globalPointsRatio = .infinity
            },
            { (mapping: inout MappingArtifact) in
                mapping.incrementalCadence?.globalMaxRefinements = 0
            },
            { (mapping: inout MappingArtifact) in
                mapping.attemptCount = 2
                mapping.fallbackReason = nil
            },
            { (mapping: inout MappingArtifact) in mapping.fallbackReason = "  " },
            { (mapping: inout MappingArtifact) in mapping.fallbackReason = " recovery" },
            { (mapping: inout MappingArtifact) in mapping.fallbackReason = "bad\nreason" },
            { (mapping: inout MappingArtifact) in
                mapping.fallbackReason = String(repeating: "x", count: 4_097)
            },
            { (mapping: inout MappingArtifact) in
                mapping.acceptedRefinementKind = .seededBundleAdjustment
            },
        ] {
            var mapping = baseline.mapping
            mutate(&mapping)
            invalidMappings.append(mapping)
        }

        for mapping in invalidMappings {
            var artifact = baseline
            artifact.mapping = mapping
            XCTAssertThrowsError(
                try GeometryArtifactStore.validate(artifact, projectPaths: paths)
            ) { error in
                XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
            }
        }
    }

    func testMappingArtifactRejectsInvalidMultipleModelEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)
        let baseline = makeDescriptorlessMeasuredArtifact(fixture: fixture)

        for mutate in [
            { (mapping: inout MappingArtifact) in mapping.secondLargestModelRegisteredViewCount = 0 },
            { (mapping: inout MappingArtifact) in mapping.secondLargestModelRegisteredViewCount = 10 },
            { (mapping: inout MappingArtifact) in mapping.modelCount = 10 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 8 },
            { (mapping: inout MappingArtifact) in mapping.unionRegisteredViewCount = 11 },
            { (mapping: inout MappingArtifact) in
                mapping.largestModelRegisteredViewCount = 10
                mapping.secondLargestModelRegisteredViewCount = 8
                mapping.unionRegisteredViewCount = 10
            },
        ] {
            var artifact = baseline
            mutate(&artifact.mapping)
            XCTAssertThrowsError(
                try GeometryArtifactStore.validate(artifact, projectPaths: paths)
            ) { error in
                XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
            }
        }
    }

    func testRejectsPairGraphThatContradictsAcceptedRefinementRoute() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeDescriptorlessGeometryFixture(at: paths)

        var incremental = makeDescriptorlessMeasuredArtifact(fixture: fixture)
        incremental.pairGraph = .notEvaluated()
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(incremental, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }

        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent(
            "learned_points3D.txt"
        )
        try FileManager.default.createDirectory(
            at: learnedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "1 1 2 3 10 20 30 -1\n".write(
            to: learnedURL,
            atomically: true,
            encoding: .utf8
        )
        var seeded = makeDescriptorlessMeasuredArtifact(fixture: fixture)
        seeded.modelVersion = "DA3-SMALL@89abcdef0123456789abcdef0123456789abcdef"
        seeded.provenance.runtime = GeometryComponentProvenance(
            identifier: "da3_mps",
            version: "main",
            revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
            payloadSHA256: String(repeating: "b", count: 64)
        )
        seeded.provenance.model = GeometryComponentProvenance(
            identifier: "DA3-SMALL",
            version: "apache-2.0-release",
            revision: "89abcdef0123456789abcdef0123456789abcdef",
            payloadSHA256: String(repeating: "c", count: 64)
        )
        seeded.learnedPointInitializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: try GeometryArtifactStore.sha256(of: learnedURL),
            pointCount: 1
        )
        seeded.mapping = MappingArtifact(
            modelCount: 1,
            largestModelRegisteredViewCount: 9,
            secondLargestModelRegisteredViewCount: 0,
            unionRegisteredViewCount: 9,
            attemptCount: 1,
            acceptedRefinementKind: .seededBundleAdjustment,
            acceptedRefinementInvocationCount: 1,
            incrementalCadence: nil,
            fallbackReason: nil
        )
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(seeded, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidMapping)
        }
    }

    func testRejectsFabricatedPairAndOrientationEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var fabricatedPairGraph = makeArtifact(fixture: fixture)
        fabricatedPairGraph.pairGraph = PairGraphArtifact(
            status: .notEvaluated,
            measurement: PairGraphMeasurement(
                scheduledPairCount: 0,
                attemptedPairCount: 0,
                rawMatchedPairCount: 0,
                spatiallyVerifiedPairCount: 0,
                localPairCount: 0,
                retrievalPairCount: 0,
                loopRevisitPairCount: 0,
                connectedComponentCount: 1,
                isolatedViewCount: 1,
                articulationViewCount: 0,
                biconnectedBlockCount: 0,
                largestBiconnectedBlockViewCount: 0,
                secondLargestBiconnectedBlockViewCount: 0,
                degreeP10: 0,
                degreeMedian: 0,
                degreeP90: 0,
                matcherAttempts: [],
                pairListDigest: String(repeating: "d", count: 64),
                featureDatabaseDigest: String(repeating: "e", count: 64),
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                matchingDurationSeconds: 0
            ),
        )
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedPairGraph, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidPairGraph)
        }

        var fabricatedOrientation = makeArtifact(fixture: fixture)
        fabricatedOrientation.canonicalOrientation.sourceToCanonicalQuaternionWXYZ =
            CanonicalQuaternionWXYZ(w: 1, x: 0, y: 0, z: 0)
        XCTAssertThrowsError(
            try GeometryArtifactStore.validate(fabricatedOrientation, projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidCanonicalOrientation)
        }
    }

    private typealias Fixture = (
        modelHashes: [String: String],
        inputDigest: String,
        selectedFramesDigest: String,
        pointCount: Int,
        observationCount: Int
    )

    private func makeArtifact(fixture: Fixture) -> GeometryArtifact {
        let imageNames = (1...3).map { String(format: "frame_%06d.jpg", $0) }
        return GeometryArtifact(
            schemaVersion: GeometryArtifact.currentSchemaVersion,
            solverVersion: "colmap; COLMAP 4.1.0",
            runtimeVersion: "easysplat-core-v2",
            modelVersion: "none",
            inputDigest: fixture.inputDigest,
            selectedFramesDigest: fixture.selectedFramesDigest,
            orderedImageNames: imageNames,
            orderedImageTimestamps: Array(repeating: nil, count: imageNames.count),
            sourceModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: "SIMPLE_PINHOLE",
            cameraGrouping: .sameCameraAndLens,
            registeredViewCount: imageNames.count,
            totalViewCount: imageNames.count,
            trackCount: fixture.observationCount,
            pointCount: fixture.pointCount,
            residualProvenance: "colmap-text-tracks-v1",
            medianPixelResidual: 0,
            p90PixelResidual: 0,
            timings: ["sfmMapping": 1.5, "orientation_estimation_seconds": 0.001],
            peakMemoryBytes: 1_024,
            modelHashes: fixture.modelHashes,
            fallbackReason: nil,
            provenance: GeometryProvenance(
                toolchainVersion: "2.0.0",
                solver: GeometryComponentProvenance(
                    identifier: "colmap",
                    version: "4.1.0",
                    revision: "fa8e3b3ff591552855f8ad2806723c80f963f69c",
                    payloadSHA256: String(repeating: "a", count: 64)
                ),
                runtime: nil,
                model: nil
            ),
            pairGraph: .measured(PairGraphMeasurement(
                scheduledPairCount: 3,
                attemptedPairCount: 3,
                rawMatchedPairCount: 3,
                spatiallyVerifiedPairCount: 3,
                localPairCount: 3,
                retrievalPairCount: 0,
                loopRevisitPairCount: 0,
                connectedComponentCount: 1,
                isolatedViewCount: 0,
                descriptorlessViewCount: 0,
                articulationViewCount: 0,
                biconnectedBlockCount: 1,
                largestBiconnectedBlockViewCount: 3,
                secondLargestBiconnectedBlockViewCount: 0,
                degreeP10: 2,
                degreeMedian: 2,
                degreeP90: 2,
                matcherAttempts: [PairMatchingAttemptArtifact(
                    attemptNumber: 1,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .completed,
                    scheduledPairCount: 3,
                    attemptedPairCount: 3,
                    rawMatchedPairCount: 3,
                    spatiallyVerifiedPairCount: 3,
                    durationSeconds: 0.01
                )],
                pairListDigest: String(repeating: "d", count: 64),
                featureDatabaseDigest: String(repeating: "e", count: 64),
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                matchingDurationSeconds: 0.01
            )),
            mapping: MappingArtifact(
                modelCount: 1,
                largestModelRegisteredViewCount: imageNames.count,
                secondLargestModelRegisteredViewCount: 0,
                unionRegisteredViewCount: imageNames.count,
                attemptCount: 1,
                acceptedRefinementKind: .incrementalGlobal,
                acceptedRefinementInvocationCount: 1,
                incrementalCadence: IncrementalMappingCadenceArtifact(
                    localMaxRefinements: 2,
                    globalFramesRatio: 1.4,
                    globalPointsRatio: 1.4,
                    globalMaxRefinements: 5
                ),
                fallbackReason: nil
            ),
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
            )
        )
    }

    private func makeDescriptorlessMeasuredArtifact(
        fixture: Fixture
    ) -> GeometryArtifact {
        let imageNames = (1...10).map { String(format: "frame_%06d.jpg", $0) }
        var artifact = makeArtifact(fixture: fixture)
        artifact.orderedImageNames = imageNames
        artifact.orderedImageTimestamps = Array(repeating: nil, count: imageNames.count)
        artifact.registeredViewCount = 9
        artifact.totalViewCount = 10
        artifact.trackCount = 9
        artifact.pointCount = 1
        artifact.pairGraph = .measured(
            PairGraphMeasurement(
                scheduledPairCount: 9,
                attemptedPairCount: 9,
                rawMatchedPairCount: 8,
                spatiallyVerifiedPairCount: 8,
                localPairCount: 9,
                retrievalPairCount: 0,
                loopRevisitPairCount: 0,
                connectedComponentCount: 2,
                isolatedViewCount: 1,
                descriptorlessViewCount: 1,
                articulationViewCount: 7,
                biconnectedBlockCount: 8,
                largestBiconnectedBlockViewCount: 2,
                secondLargestBiconnectedBlockViewCount: 2,
                degreeP10: 0,
                degreeMedian: 2,
                degreeP90: 2,
                matcherAttempts: [PairMatchingAttemptArtifact(
                    attemptNumber: 1,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .completed,
                    scheduledPairCount: 9,
                    attemptedPairCount: 9,
                    rawMatchedPairCount: 8,
                    spatiallyVerifiedPairCount: 8,
                    durationSeconds: 0.01
                )],
                pairListDigest: String(repeating: "d", count: 64),
                featureDatabaseDigest: String(repeating: "e", count: 64),
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                matchingDurationSeconds: 0.01
            ),
        )
        artifact.mapping = MappingArtifact(
            modelCount: 2,
            largestModelRegisteredViewCount: 9,
            secondLargestModelRegisteredViewCount: 8,
            unionRegisteredViewCount: 9,
            attemptCount: 1,
            acceptedRefinementKind: .incrementalGlobal,
            acceptedRefinementInvocationCount: 1,
            incrementalCadence: IncrementalMappingCadenceArtifact(
                localMaxRefinements: 2,
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5
            ),
            fallbackReason: nil
        )
        return artifact
    }

    private func writeCanonicalModel(
        at paths: ProjectPaths,
        observationCount: Int = 1
    ) throws -> Fixture {
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let imageNames = (1...3).map { String(format: "frame_%06d.jpg", $0) }
        let observations = (1...observationCount)
            .map { "320 240 \($0)" }
            .joined(separator: " ")
        let images = imageNames.enumerated().flatMap { offset, name in
            [
                "\(offset + 1) 1 0 0 0 0 0 0 1 \(name)",
                observations,
            ]
        }.joined(separator: "\n") + "\n"
        let points = (1...observationCount)
            .map { pointID in
                let track = (1...imageNames.count)
                    .map { "\($0) \(pointID - 1)" }
                    .joined(separator: " ")
                return "\(pointID) 0 0 1 255 255 255 0 \(track)"
            }
            .joined(separator: "\n")
        let contents = [
            "cameras.txt": "1 SIMPLE_PINHOLE 640 480 500 320 240\n",
            "images.txt": images,
            "points3D.txt": points + "\n",
        ]
        var hashes: [String: String] = [:]
        for (name, contents) in contents {
            let data = Data(contents.utf8)
            try data.write(to: model.appendingPathComponent(name), options: [.atomic])
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        try Data("original input".utf8).write(
            to: paths.originalsURL.appendingPathComponent("source.jpg"),
            options: [.atomic]
        )
        for (offset, imageName) in imageNames.enumerated() {
            try Data("selected frame \(offset + 1)".utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(imageName),
                options: [.atomic]
            )
        }
        return (
            modelHashes: hashes,
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            pointCount: observationCount,
            observationCount: observationCount * imageNames.count
        )
    }

    private func writeDescriptorlessGeometryFixture(
        at paths: ProjectPaths
    ) throws -> Fixture {
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let registeredImageNames = (1...9).map { String(format: "frame_%06d.jpg", $0) }
        let selectedImageNames = registeredImageNames + ["frame_000010.jpg"]
        let images = registeredImageNames.enumerated().flatMap { offset, name in
            [
                "\(offset + 1) 1 0 0 0 0 0 0 1 \(name)",
                "320 240 1",
            ]
        }.joined(separator: "\n") + "\n"
        let track = (1...9).map { "\($0) 0" }.joined(separator: " ")
        let contents = [
            "cameras.txt": "1 SIMPLE_PINHOLE 640 480 500 320 240\n",
            "images.txt": images,
            "points3D.txt": "1 0 0 1 255 255 255 0 \(track)\n",
        ]
        var hashes: [String: String] = [:]
        for (name, contents) in contents {
            let data = Data(contents.utf8)
            try data.write(to: model.appendingPathComponent(name), options: [.atomic])
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        try Data("original input".utf8).write(
            to: paths.originalsURL.appendingPathComponent("source.jpg"),
            options: [.atomic]
        )
        for name in selectedImageNames {
            try Data(name.utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(name),
                options: [.atomic]
            )
        }
        return (
            modelHashes: hashes,
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: selectedImageNames,
                projectPaths: paths
            ),
            pointCount: 1,
            observationCount: 9
        )
    }
}
