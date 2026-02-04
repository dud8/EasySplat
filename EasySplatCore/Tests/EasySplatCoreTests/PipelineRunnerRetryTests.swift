import XCTest
@testable import EasySplatCore

final class PipelineRunnerRetryTests: XCTestCase {
    func testIsStageCompleteImportInput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let photosFolder = "/tmp/Photos"
        let dest = paths.originalsURL.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: photosFolder), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertTrue(runner.test_isStageComplete(.importInput, paths: paths, metadata: metadata))
    }

    func testIsStageCompleteSelectFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertFalse(runner.test_isStageComplete(.selectFrames, paths: paths, metadata: metadata))

        let file = paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg")
        TestFileBuilder.createFile(at: file, data: Data([0x00]))
        XCTAssertTrue(runner.test_isStageComplete(.selectFrames, paths: paths, metadata: metadata))
    }

    func testIsStageCompleteSfmMapping() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            TestFileBuilder.createFile(at: sparse.appendingPathComponent(name), data: Data([0x00]))
        }

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertTrue(runner.test_isStageComplete(.sfmMapping, paths: paths, metadata: metadata))
    }

    func testIsStageCompleteTrainBrush() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let training = paths.trainingURL
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)
        TestFileBuilder.createFile(at: training.appendingPathComponent("export_00001.ply"), data: Data([0x00]))

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertTrue(runner.test_isStageComplete(.trainBrush, paths: paths, metadata: metadata))
    }

    func testCleanForRetrySelectFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        TestFileBuilder.createFile(at: paths.framesSelectedManifestURL, data: Data([0x01]))
        TestFileBuilder.createFile(at: paths.colmapDatabaseURL, data: Data([0x03]))

        let runner = makeRunner(projectURL: root)
        try runner.test_cleanForRetry(failedStage: .selectFrames, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesSelectedManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path))
    }

    private func makeRunner(projectURL: URL) -> PipelineRunner {
        let vggt = VggtToolchain(root: projectURL, sfmTool: projectURL, python: projectURL, models: projectURL)
        let toolchain = ToolchainPaths(root: projectURL, colmap: projectURL, glomap: projectURL, brush: projectURL, vggt: vggt)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: projectURL, config: config)
    }
}
