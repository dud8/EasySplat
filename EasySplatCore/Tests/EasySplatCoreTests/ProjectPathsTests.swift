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
        XCTAssertTrue(paths.appEventsLogURL.path.hasSuffix("Logs/app_events.jsonl"))
        XCTAssertTrue(paths.da3LogURL.path.hasSuffix("Logs/da3.log"))
        XCTAssertTrue(paths.da3CoverageManifestURL.path.hasSuffix("Logs/da3_coverage_manifest.json"))
        XCTAssertTrue(paths.mapanythingLogURL.path.hasSuffix("Logs/mapanything.log"))
        XCTAssertTrue(paths.mapanythingCoverageManifestURL.path.hasSuffix("Logs/mapanything_coverage_manifest.json"))
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
}
