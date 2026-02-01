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
        XCTAssertTrue(fm.fileExists(atPath: paths.sfmLearnedFeaturesURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.trainingURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.outputURL.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.logsURL.path))
    }
}
