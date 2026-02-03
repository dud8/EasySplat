import XCTest
@testable import EasySplatCore

final class PipelineRunnerHelperTests: XCTestCase {
    func testDownsampleFramesEdgeCases() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let urls = (0..<5).map { root.appendingPathComponent("img\($0).jpg") }

        XCTAssertTrue(runner.test_downsampleFrames(urls, targetCount: 0).isEmpty)
        XCTAssertEqual(runner.test_downsampleFrames(urls, targetCount: 1), [urls[2]])
        XCTAssertEqual(runner.test_downsampleFrames(urls, targetCount: 10), urls)
    }

    func testTargetCountForVideoDistribution() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(runner.test_targetCountForVideo(index: 0, total: 3, targetCount: 10), 4)
        XCTAssertEqual(runner.test_targetCountForVideo(index: 1, total: 3, targetCount: 10), 3)
        XCTAssertEqual(runner.test_targetCountForVideo(index: 2, total: 3, targetCount: 10), 3)
    }

    func testFrameExtractionProfileValues() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let draft = runner.test_frameExtractionProfile(for: .draft)
        XCTAssertEqual(draft.targetCount, 120)
        XCTAssertEqual(draft.outputFormat, .jpeg)

        let ultra = runner.test_frameExtractionProfile(for: .ultra)
        XCTAssertEqual(ultra.outputFormat, .png)
        XCTAssertEqual(ultra.targetCount, 500)
    }

    func testShouldUseSequentialConditions() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let frames = (0..<30).map { root.appendingPathComponent("f\($0).jpg") }

        XCTAssertTrue(runner.test_shouldUseSequential(
            selectedFrames: frames,
            input: .video(files: ["/tmp/a.mov"]),
            forceExhaustive: false
        ))
        XCTAssertFalse(runner.test_shouldUseSequential(
            selectedFrames: frames,
            input: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos"),
            forceExhaustive: false
        ))
    }

    func testFrameGroupsFiltering() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let manifest: [TestSelectedFrameMapping] = [
            .init(outputFileName: "a.jpg", groupId: "video_000", isVideo: true, sourcePath: "/a.jpg"),
            .init(outputFileName: "b.jpg", groupId: "video_000", isVideo: true, sourcePath: "/b.jpg"),
            .init(outputFileName: "c.jpg", groupId: "video_001", isVideo: true, sourcePath: "/c.jpg"),
            .init(outputFileName: "d.jpg", groupId: "photos", isVideo: false, sourcePath: "/d.jpg")
        ]

        let groups = runner.test_frameGroups(from: manifest, allowedNames: ["b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].id, "video_000")
        XCTAssertEqual(groups[0].fileNames, ["b.jpg"])
        XCTAssertEqual(groups[1].id, "video_001")
        XCTAssertEqual(groups[2].id, "photos")
    }

    func testDownsampleSelectedFramesUpdatesManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        for index in 0..<4 {
            let url = paths.framesSelectedURL.appendingPathComponent(String(format: "frame_%06d.jpg", index))
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: url, size: 16, value: UInt8(index * 40), utType: .jpeg))
        }

        let manifest = (0..<4).map { index in
            TestSelectedFrameMapping(
                outputFileName: String(format: "frame_%06d.jpg", index),
                groupId: "video_000",
                isVideo: true,
                sourcePath: "/source/\(index).jpg"
            )
        }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: paths.framesSelectedManifestURL, options: [.atomic])

        let runner = makeRunner(projectURL: root)
        let reduced = try runner.test_downsampleSelectedFrames(to: 2, paths: paths)
        XCTAssertEqual(reduced?.count, 2)

        let contents = try FileManager.default.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.count, 2)

        let updatedData = try Data(contentsOf: paths.framesSelectedManifestURL)
        let updated = try JSONDecoder().decode([TestSelectedFrameMapping].self, from: updatedData)
        XCTAssertEqual(updated.count, 2)
        for entry in updated {
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesSelectedURL.appendingPathComponent(entry.outputFileName).path))
        }
    }

    func testNormalizeSelectedImagesForToolingNoHeic() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let url = paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: url, size: 16, value: 10, utType: .jpeg))

        let manifest = [TestSelectedFrameMapping(
            outputFileName: "frame_000000.jpg",
            groupId: "photos",
            isVideo: false,
            sourcePath: "/source.jpg"
        )]
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: paths.framesSelectedManifestURL, options: [.atomic])

        let runner = makeRunner(projectURL: root)
        let converted = try runner.test_normalizeSelectedImagesForTooling(paths: paths)
        XCTAssertEqual(converted, 0)

        let updatedData = try Data(contentsOf: paths.framesSelectedManifestURL)
        let updated = try JSONDecoder().decode([TestSelectedFrameMapping].self, from: updatedData)
        XCTAssertEqual(updated.first?.outputFileName, "frame_000000.jpg")
    }

    func testNormalizeSelectedImagesForToolingHeic() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let heicURL = paths.framesSelectedURL.appendingPathComponent("frame_000000.heic")
        let success = try TestFileBuilder.writeGrayscaleImage(url: heicURL, size: 16, value: 10, utType: .heic)
        if !success {
            throw XCTSkip("HEIC encoding unavailable")
        }

        let manifest = [TestSelectedFrameMapping(
            outputFileName: "frame_000000.heic",
            groupId: "photos",
            isVideo: false,
            sourcePath: "/source.heic"
        )]
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: paths.framesSelectedManifestURL, options: [.atomic])

        let runner = makeRunner(projectURL: root)
        let converted = try runner.test_normalizeSelectedImagesForTooling(paths: paths)
        XCTAssertEqual(converted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg").path))

        let updatedData = try Data(contentsOf: paths.framesSelectedManifestURL)
        let updated = try JSONDecoder().decode([TestSelectedFrameMapping].self, from: updatedData)
        XCTAssertEqual(updated.first?.outputFileName, "frame_000000.jpg")
    }

    func testBrushExportStepParsing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(runner.test_brushExportStep(from: root.appendingPathComponent("export_05000.ply")), 5000)
        XCTAssertEqual(runner.test_brushExportStep(from: root.appendingPathComponent("export_01000.compressed.ply")), 1000)
        XCTAssertNil(runner.test_brushExportStep(from: root.appendingPathComponent("other.ply")))
    }

    func testLatestBrushExportPrefersHighestStep() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let training = root.appendingPathComponent("Training", isDirectory: true)
        let exports = training.appendingPathComponent("dataset_exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        let low = exports.appendingPathComponent("export_01000.ply")
        let high = exports.appendingPathComponent("export_02000.ply")
        TestFileBuilder.createFile(at: low, data: Data([0x00]))
        TestFileBuilder.createFile(at: high, data: Data([0x00]))

        let runner = makeRunner(projectURL: root)
        let latest = runner.test_latestBrushExport(in: training)
        XCTAssertEqual(latest?.step, 2000)
        XCTAssertEqual(latest?.file.resolvingSymlinksInPath().path, high.resolvingSymlinksInPath().path)
    }

    func testBrushTrainStepProgressParsing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let progress = runner.test_brushTrainStepProgress(from: "progress 12 / 345 steps")
        XCTAssertEqual(progress?.step, 12)
        XCTAssertEqual(progress?.total, 345)
    }

    func testBrushTrainStepRateParsing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let firstRate = runner.test_brushTrainStepRate(from: "Steps (0.9195/s, 12h remaining)")
        XCTAssertNotNil(firstRate)
        if let firstRate {
            XCTAssertEqual(firstRate, 0.9195, accuracy: 0.0001)
        }
        let secondRate = runner.test_brushTrainStepRate(from: "speed: 5.2 it/s")
        XCTAssertNotNil(secondRate)
        if let secondRate {
            XCTAssertEqual(secondRate, 5.2, accuracy: 0.0001)
        }
        XCTAssertNil(runner.test_brushTrainStepRate(from: "no rate here"))
    }

    func testToolLogFiltering() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        XCTAssertTrue(runner.test_shouldEmitToolLogLine("EasySplat: colmap argv: /bin/colmap", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("warning: low confidence", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("ERROR: failed to open", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("something bad", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("\u{1B}[2K\u{1B}[1B", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("██████ 70/40000 Steps (0.9/s, 12h remaining)", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("normal progress line", isError: false))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("   ", isError: false))
    }

    func testBrushTrainingPlanForQualityPresets() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let draft = runner.test_brushTrainingPlan(for: PresetSpec(mode: .object, quality: .draft))
        XCTAssertEqual(draft.totalSteps, 20_000)
        XCTAssertEqual(draft.exportEvery, 5_000)

        let standard = runner.test_brushTrainingPlan(for: PresetSpec(mode: .object, quality: .standard))
        XCTAssertEqual(standard.totalSteps, 40_000)
        XCTAssertEqual(standard.exportEvery, 5_000)

        let ultra = runner.test_brushTrainingPlan(for: PresetSpec(mode: .room, quality: .ultra))
        XCTAssertEqual(ultra.totalSteps, 80_000)
        XCTAssertEqual(ultra.exportEvery, 10_000)
    }

    func testTrainingStatusMessageFormatting() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let progressMessage = runner.test_trainingStatusMessage(
            elapsed: 65,
            step: 1000,
            total: 10000,
            latestExportStep: nil,
            totalSteps: 10000
        )
        XCTAssertTrue(progressMessage.contains("1,000/10,000 steps"))
        XCTAssertTrue(progressMessage.contains("running 1m 05s"))

        let exportMessage = runner.test_trainingStatusMessage(
            elapsed: 90,
            step: nil,
            total: nil,
            latestExportStep: 30000,
            totalSteps: 60000
        )
        XCTAssertTrue(exportMessage.contains("30,000/60,000 steps"))
        XCTAssertFalse(exportMessage.contains("target"))
    }

    private func makeRunner(projectURL: URL) -> PipelineRunner {
        let vggt = VggtToolchain(root: projectURL, sfmTool: projectURL, python: projectURL, models: projectURL)
        let toolchain = ToolchainPaths(root: projectURL, colmap: projectURL, glomap: projectURL, brush: projectURL, vggt: vggt)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: projectURL, config: config)
    }
}
