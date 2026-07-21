import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class PipelineMappingResumeValidationTests: XCTestCase {
    func testMappingResumeRejectsSymlinkedTextModelFile() throws {
        let fixture = try makeFixture()
        let imagesURL = fixture.sparse.appendingPathComponent("images.txt")
        let externalURL = fixture.root.appendingPathComponent("external-images.txt")
        try FileManager.default.moveItem(at: imagesURL, to: externalURL)
        try FileManager.default.createSymbolicLink(
            at: imagesURL,
            withDestinationURL: externalURL
        )

        assertCorrupt(try mappingStatus(fixture))
    }

    func testMappingResumeRejectsHardLinkedTextModelFile() throws {
        let fixture = try makeFixture()
        let pointsURL = fixture.sparse.appendingPathComponent("points3D.txt")
        let externalURL = fixture.root.appendingPathComponent("external-points3D.txt")
        try FileManager.default.moveItem(at: pointsURL, to: externalURL)
        XCTAssertEqual(Darwin.link(externalURL.path, pointsURL.path), 0)

        assertCorrupt(try mappingStatus(fixture))
    }

    func testMappingResumeRejectsMalformedImagesObservationRow() throws {
        let fixture = try makeFixture(
            images: "1 1 0 0 0 0 0 0 1 frame.jpg\n320 240\n"
        )

        assertCorrupt(try mappingStatus(fixture))
    }

    func testMappingResumeRejectsIntegerOverflowInPoints() throws {
        let fixture = try makeFixture(
            points: "9223372036854775808 0 0 10 255 255 255 0.1 1 0\n"
        )

        assertCorrupt(try mappingStatus(fixture))
    }

    func testMappingResumeRejectsLineAboveBoundWithoutReadingWholeModel() throws {
        let fixture = try makeFixture()
        let imagesURL = fixture.sparse.appendingPathComponent("images.txt")
        let handle = try FileHandle(forWritingTo: imagesURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("#".utf8))
        try handle.seek(toOffset: UInt64(ColmapTextFileLimits.maximumLine + 1))
        try handle.write(contentsOf: Data("\n1 1 0 0 0 0 0 0 1 frame.jpg\n320 240 1\n".utf8))

        assertCorrupt(try mappingStatus(fixture))
    }

    func testMappingResumeRejectsFileAboveBoundBeforeReading() throws {
        let fixture = try makeFixture()
        let pointsURL = fixture.sparse.appendingPathComponent("points3D.txt")
        XCTAssertEqual(
            Darwin.truncate(
                pointsURL.path,
                off_t(ColmapTextFileLimits.points) + 1
            ),
            0
        )

        assertCorrupt(try mappingStatus(fixture))
    }

    func testStreamingSparseStatsPreserveValidCounts() throws {
        let fixture = try makeFixture(
            images: "# images\r\n1 1 0 0 0 0 0 0 1 frame one.jpg\r\n320 240 1 100 200 -1\r\n2 1 0 0 0 1 0 0 1 frame_two.jpg\r\n\r\n",
            points: "# points\n1 0 0 10 255 255 255 0.1 1 0 2 1\n2 1 0 10 64 64 64 0.2 2 3\n"
        )
        let stats = try runner(for: fixture).colmapSparseTextStats(at: fixture.sparse)

        XCTAssertEqual(stats.registeredImageCount, 2)
        XCTAssertEqual(stats.pointCount, 2)
        XCTAssertEqual(stats.observationCount, 3)
        XCTAssertEqual(stats.meanTrackLength, 1.5)
    }

    private struct Fixture {
        let root: URL
        let paths: ProjectPaths
        let sparse: URL
        let metadata: ProjectMetadata
    }

    private func makeFixture(
        images: String = "1 1 0 0 0 0 0 0 1 frame.jpg\n320 240 1\n",
        points: String = "1 0 0 10 255 255 255 0.1 1 0\n"
    ) throws -> Fixture {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n".write(
            to: sparse.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try images.write(
            to: sparse.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try points.write(
            to: sparse.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        return Fixture(
            root: root,
            paths: paths,
            sparse: sparse,
            metadata: ProjectMetadata(title: "Resume", input: .photos(folder: "/tmp/Photos"))
        )
    }

    private func mappingStatus(_ fixture: Fixture) throws -> PipelineRunner.StageOutputStatus {
        try runner(for: fixture).validateStageOutput(
            .sfmMapping,
            paths: fixture.paths,
            metadata: fixture.metadata
        )
    }

    private func runner(for fixture: Fixture) -> PipelineRunner {
        let toolchain = TestToolchains.toolchainPaths(root: fixture.root)
        return PipelineRunner(
            projectURL: fixture.root,
            config: PipelineRunner.PipelineConfig(toolchain: toolchain)
        )
    }

    private func assertCorrupt(
        _ status: PipelineRunner.StageOutputStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .corrupt = status else {
            return XCTFail("Expected corrupt, got \(status)", file: file, line: line)
        }
    }
}
