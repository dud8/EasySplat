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
        XCTAssertTrue(fm.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.framesSelectedURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.colmapSparseURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.trainingURL.path))
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

    func testResolveProjectRelativePathRejectsUnsafePaths() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)

        for value in ["", "/tmp/splat.ply", "../splat.ply", "Output/../splat.ply", "Output//splat.ply"] {
            XCTAssertThrowsError(try paths.resolveProjectRelativePath(value), "Expected rejection for \(value)")
        }
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
}
