import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryArtifactStoreTests: XCTestCase {
    func testPersistsRelativeMeasuredArtifactToSidecarAndMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)
        var metadata = ProjectMetadata(
            title: "Measured",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let artifact = makeArtifact(fixture: fixture)

        try GeometryArtifactStore.persist(artifact, metadata: &metadata, paths: paths)

        XCTAssertEqual(
            try GeometryArtifactStore.load(from: paths.geometryManifestURL, projectPaths: paths),
            artifact
        )
        XCTAssertEqual(try ProjectMetadataStore.load(from: paths.metadataURL).geometryArtifact, artifact)
    }

    func testRejectsEscapingCanonicalPathAndPlaceholderResidualProvenance() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let fixture = try writeCanonicalModel(at: paths)

        var escaping = makeArtifact(fixture: fixture)
        escaping.canonicalModelPath = "../outside"
        XCTAssertThrowsError(try GeometryArtifactStore.validate(escaping, projectPaths: paths)) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidCanonicalPath)
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

    private typealias Fixture = (
        modelHashes: [String: String],
        inputDigest: String,
        selectedFramesDigest: String
    )

    private func makeArtifact(fixture: Fixture) -> GeometryArtifact {
        GeometryArtifact(
            schemaVersion: 1,
            solverVersion: "da3-aligned",
            runtimeVersion: "easysplat-core-v2",
            modelVersion: "DA3-BASE",
            inputDigest: fixture.inputDigest,
            selectedFramesDigest: fixture.selectedFramesDigest,
            orderedImageNames: ["frame_000001.jpg"],
            orderedImageTimestamps: [nil],
            canonicalModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: "SIMPLE_PINHOLE",
            cameraGrouping: .sameCameraAndLens,
            registeredViewCount: 1,
            totalViewCount: 1,
            trackCount: 1,
            pointCount: 1,
            residualProvenance: "colmap-text-tracks-v1",
            medianPixelResidual: 0,
            p90PixelResidual: 0,
            timings: ["sfmMapping": 1.5],
            peakMemoryBytes: 1_024,
            modelHashes: fixture.modelHashes,
            fallbackReason: nil
        )
    }

    private func writeCanonicalModel(at paths: ProjectPaths) throws -> Fixture {
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let contents = [
            "cameras.txt": "1 SIMPLE_PINHOLE 640 480 500 320 240\n",
            "images.txt": "1 1 0 0 0 0 0 0 1 frame_000001.jpg\n320 240 1\n",
            "points3D.txt": "1 0 0 1 255 255 255 0 1 0\n",
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
        try Data("selected frame".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg"),
            options: [.atomic]
        )
        return (
            modelHashes: hashes,
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: ["frame_000001.jpg"],
                projectPaths: paths
            )
        )
    }
}
