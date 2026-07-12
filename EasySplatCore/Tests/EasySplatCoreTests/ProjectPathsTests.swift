import XCTest
@testable import EasySplatCore

final class ProjectPathsTests: XCTestCase {
    func testEnsureDirectoriesCreatesAllPaths() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)

        try paths.ensureDirectories()

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: paths.originalsURL.path))
        XCTAssertEqual(paths.importedPhotosURL.lastPathComponent, "Photos")
        XCTAssertTrue(fm.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.framesSelectedURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.colmapSparseURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.trainingURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.msplatCheckpointURL.path))
        XCTAssertTrue(
            fm.fileExists(atPath: paths.msplatOutputURL.deletingLastPathComponent().path)
        )
        XCTAssertTrue(
            fm.fileExists(
                atPath: paths.trainingURL.appendingPathComponent(
                    "msplat_dataset/sparse/0",
                    isDirectory: true
                ).path
            )
        )
        XCTAssertTrue(fm.fileExists(atPath: paths.outputURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.logsURL.path))
        XCTAssertTrue(paths.da3LogURL.path.hasSuffix("Logs/da3.log"))
        XCTAssertTrue(paths.da3CoverageManifestURL.path.hasSuffix("Logs/da3_coverage_manifest.json"))
        XCTAssertTrue(paths.globalMapperLogURL.path.hasSuffix("Logs/global_mapper.log"))
        XCTAssertTrue(paths.msplatLogURL.path.hasSuffix("Logs/msplat.log"))
    }

    func testResolveProjectRelativePathAcceptsNestedRelativePath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)

        let resolved = try paths.resolveProjectRelativePath("Output/splat.ply")

        XCTAssertEqual(resolved.standardizedFileURL, root.appendingPathComponent("Output/splat.ply").standardizedFileURL)
    }

    func testResolveProjectRelativePathAcceptsMissingDescendantThroughEnumeratedRootAlias() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let originalRoot = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let originalPaths = ProjectPaths(root: originalRoot)
        try originalPaths.ensureDirectories()
        let enumeratedRoot = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent == originalRoot.lastPathComponent }
        )

        let resolved = try ProjectPaths(root: enumeratedRoot)
            .resolveProjectRelativePath("SfM/colmap/sparse/0")

        XCTAssertEqual(resolved.lastPathComponent, "0")
        XCTAssertEqual(resolved.deletingLastPathComponent().lastPathComponent, "sparse")
    }

    func testResolveProjectRelativePathRejectsUnsafePaths() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)

        for value in ["", "/tmp/splat.ply", "../splat.ply", "Output/../splat.ply", "Output//splat.ply"] {
            XCTAssertThrowsError(try paths.resolveProjectRelativePath(value), "Expected rejection for \(value)")
        }
    }

    func testProjectRelativePathRoundTripsAnInBundleArtifact() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let artifact = paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg")
        try Data([0x01]).write(to: artifact)

        let relativePath = try paths.projectRelativePath(for: artifact)

        XCTAssertEqual(relativePath, "Frames/selected/frame_000001.jpg")
        XCTAssertEqual(try paths.resolveProjectRelativePath(relativePath), artifact.standardizedFileURL)
    }

    func testProjectRelativePathAcceptsEquivalentEnumeratedRootSpelling() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let originalRoot = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let originalPaths = ProjectPaths(root: originalRoot)
        try originalPaths.ensureDirectories()
        let artifact = originalPaths.outputURL.appendingPathComponent("splat.ply")
        try Data([0x01]).write(to: artifact)
        let enumeratedRoot = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent == originalRoot.lastPathComponent }
        )

        let relativePath = try ProjectPaths(root: enumeratedRoot)
            .projectRelativePath(for: artifact)

        XCTAssertEqual(relativePath, "Output/splat.ply")
    }

    func testProjectRelativePathRejectsAnOutsideFile() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("outside.jpg")
        try Data([0x01]).write(to: outside)

        XCTAssertThrowsError(try ProjectPaths(root: root).projectRelativePath(for: outside))
    }

    func testResolveProjectRelativePathRejectsEscapingSymlink() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let outside = parent.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Output", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try ProjectPaths(root: root).resolveProjectRelativePath("Output/splat.ply")
        )
    }

    func testEnsureDirectoriesRejectsEscapingTrainingSymlinkBeforeWritingOutside() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let outside = parent.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Training", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try ProjectPaths(root: root).ensureDirectories())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("checkpoints").path
            )
        )
    }

    func testEnsureDirectoriesRejectsEscapingCheckpointParentSymlink() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let training = root.appendingPathComponent("Training", isDirectory: true)
        let outside = parent.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: training.appendingPathComponent("checkpoints", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try ProjectPaths(root: root).ensureDirectories())
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    func testEnsureDirectoriesRejectsEscapingMsplatOutputDirectorySymlink() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let training = root.appendingPathComponent("Training", isDirectory: true)
        let outside = parent.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: training.appendingPathComponent("msplat", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try ProjectPaths(root: root).ensureDirectories())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("splat.ply").path
            )
        )
    }

    func testEnsureDirectoriesRejectsEscapingMsplatCheckpointDirectorySymlink() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let checkpoints = root.appendingPathComponent(
            "Training/checkpoints",
            isDirectory: true
        )
        let outside = parent.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: checkpoints.appendingPathComponent("msplat", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try ProjectPaths(root: root).ensureDirectories())
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }
}
