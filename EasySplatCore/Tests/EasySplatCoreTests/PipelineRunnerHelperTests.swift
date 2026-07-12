import XCTest
@testable import EasySplatCore

final class PipelineRunnerHelperTests: XCTestCase {
    func testDa3AutomaticInputOrderingUsesCaptureTopology() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        XCTAssertEqual(
            runner.test_da3ResolvedInputOrdering(requested: .automatic, input: .video(files: ["clip.mov"])),
            .continuous
        )
        XCTAssertEqual(
            runner.test_da3ResolvedInputOrdering(requested: .automatic, input: .photos(folder: "/photos")),
            .unordered
        )
        XCTAssertEqual(
            runner.test_da3ResolvedInputOrdering(
                requested: .automatic,
                input: .mixed(videos: ["clip.mov"], photosFolder: "/photos")
            ),
            .unordered
        )
        XCTAssertEqual(
            runner.test_da3ResolvedInputOrdering(
                requested: .continuous,
                input: .mixed(videos: ["clip.mov"], photosFolder: "/photos")
            ),
            .continuous
        )
    }

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

    func testResolveSparseModelDirectoryHandlesNestedOutputs() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let sparseRoot = root.appendingPathComponent("sparse/0", isDirectory: true)
        let nested = sparseRoot.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            let file = nested.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3])))
        }

        let resolved = try runner.test_resolveSparseModelDirectory(sparseRoot)
        XCTAssertEqual(resolved.standardizedFileURL, nested.standardizedFileURL)
    }

    func testFrameExtractionProfileValues() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_FRAME_TARGET_COUNT": nil,
            "EASYSPLAT_FRAME_MAX_DIMENSION": nil,
            "EASYSPLAT_FRAME_TARGET_FPS": nil
        ]) {
            let draft = runner.test_frameExtractionProfile(for: .draft)
            XCTAssertEqual(draft.targetCount, 120)
            XCTAssertNil(draft.maxExtractedFrames)
            XCTAssertEqual(draft.outputFormat, .jpeg)

            let ultra = runner.test_frameExtractionProfile(for: .ultra)
            XCTAssertEqual(ultra.outputFormat, .png)
            XCTAssertEqual(ultra.targetCount, 500)
            XCTAssertNil(ultra.maxExtractedFrames)
        }
    }

    func testFrameExtractionProfileHonorsRuntimeOverrides() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_FRAME_TARGET_COUNT": "60",
            "EASYSPLAT_FRAME_MAX_DIMENSION": "960",
            "EASYSPLAT_FRAME_TARGET_FPS": "3"
        ]) {
            let profile = runner.test_frameExtractionProfile(for: .standard)
            XCTAssertEqual(profile.targetCount, 60)
            XCTAssertEqual(profile.maxDimension, 960)
            XCTAssertEqual(profile.targetFPS, 3)
            XCTAssertNil(profile.maxExtractedFrames)
            XCTAssertEqual(profile.outputFormat, .jpeg)
        }
    }

    func testFrameExtractionProfileFastSpeedProfileUsesMeasuredBudget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_FRAME_TARGET_COUNT": nil,
            "EASYSPLAT_FRAME_MAX_DIMENSION": nil,
            "EASYSPLAT_FRAME_TARGET_FPS": nil
        ]) {
            let profile = runner.test_frameExtractionProfile(for: .standard)
            XCTAssertEqual(profile.targetCount, 30)
            XCTAssertEqual(profile.maxDimension, 960)
            XCTAssertEqual(profile.targetFPS, 3)
            XCTAssertEqual(profile.maxExtractedFrames, 40)
            XCTAssertEqual(profile.outputFormat, .jpeg)
        }
    }

    func testFrameExtractionProfileConfiguredFastProfileUsesMeasuredBudget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root, speedProfile: .fast)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_FRAME_TARGET_COUNT": nil,
            "EASYSPLAT_FRAME_MAX_DIMENSION": nil,
            "EASYSPLAT_FRAME_TARGET_FPS": nil
        ]) {
            let profile = runner.test_frameExtractionProfile(for: .standard)
            XCTAssertEqual(profile.targetCount, 30)
            XCTAssertEqual(profile.maxDimension, 960)
            XCTAssertEqual(profile.targetFPS, 3)
            XCTAssertEqual(profile.maxExtractedFrames, 40)
            XCTAssertEqual(profile.outputFormat, .jpeg)
        }
    }

    func testFrameExtractionProfileFastSpeedProfileCapsExplicitTargetCount() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_FRAME_TARGET_COUNT": "90",
            "EASYSPLAT_FRAME_MAX_DIMENSION": nil,
            "EASYSPLAT_FRAME_TARGET_FPS": nil
        ]) {
            let profile = runner.test_frameExtractionProfile(for: .standard)
            XCTAssertEqual(profile.targetCount, 90)
            XCTAssertEqual(profile.maxExtractedFrames, 120)
        }
    }

    func testSpeedProfileFastCapsColmapImageSizeAndOverlap() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_FRAME_MAX_DIMENSION": nil,
            "EASYSPLAT_COLMAP_MAX_IMAGE_SIZE": nil
        ]) {
            let options = runner.test_applySpeedProfileToColmap(
                maxImageSize: 1600,
                extractSequentialOverlap: 12,
                matchSequentialOverlap: 12
            )
            XCTAssertEqual(options.maxImageSize, 512)
            XCTAssertEqual(options.extractSequentialOverlap, 2)
            XCTAssertEqual(options.matchSequentialOverlap, 2)
            XCTAssertEqual(options.maxNumFeatures, 4_000)
            XCTAssertEqual(options.maxNumMatches, 4_000)
        }
    }

    func testInvalidFrameMaxDimensionDoesNotDisableFastSpeedProfileCap() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_FRAME_MAX_DIMENSION": "nope",
            "EASYSPLAT_COLMAP_MAX_IMAGE_SIZE": nil
        ]) {
            let options = runner.test_applySpeedProfileToColmap(
                maxImageSize: 1600,
                extractSequentialOverlap: 12,
                matchSequentialOverlap: 12
            )
            XCTAssertEqual(options.maxImageSize, 512)
            XCTAssertEqual(options.extractSequentialOverlap, 2)
            XCTAssertEqual(options.matchSequentialOverlap, 2)
            XCTAssertEqual(options.maxNumFeatures, 4_000)
            XCTAssertEqual(options.maxNumMatches, 4_000)
        }
    }

    func testExplicitFrameMaxDimensionDoesNotDisableFastColmapCap() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_FRAME_MAX_DIMENSION": "1200",
            "EASYSPLAT_COLMAP_MAX_IMAGE_SIZE": nil
        ]) {
            let options = runner.test_applySpeedProfileToColmap(
                maxImageSize: 1200,
                extractSequentialOverlap: 12,
                matchSequentialOverlap: 12
            )
            XCTAssertEqual(options.maxImageSize, 512)
            XCTAssertEqual(options.extractSequentialOverlap, 2)
            XCTAssertEqual(options.matchSequentialOverlap, 2)
        }
    }

    func testExplicitColmapMaxImageSizeBeatsFastSpeedProfileForColmap() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_FRAME_MAX_DIMENSION": "960",
            "EASYSPLAT_COLMAP_MAX_IMAGE_SIZE": "1200"
        ]) {
            let options = runner.test_applySpeedProfileToColmap(
                maxImageSize: 1200,
                extractSequentialOverlap: 12,
                matchSequentialOverlap: 12
            )
            XCTAssertEqual(options.maxImageSize, 1200)
            XCTAssertEqual(options.extractSequentialOverlap, 2)
            XCTAssertEqual(options.matchSequentialOverlap, 2)
        }
    }

    func testFrameExtractionProfileIgnoresInvalidRuntimeOverrides() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_FRAME_TARGET_COUNT": "0",
            "EASYSPLAT_FRAME_MAX_DIMENSION": "-1",
            "EASYSPLAT_FRAME_TARGET_FPS": "nope"
        ]) {
            let profile = runner.test_frameExtractionProfile(for: .draft)
            XCTAssertEqual(profile.targetCount, 120)
            XCTAssertEqual(profile.maxDimension, 1024)
            XCTAssertEqual(profile.targetFPS, 2)
        }
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

    func testMapperDefaultsToIntegratedGlobalMapperWithGpuEnabled() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_COLMAP_USE_GPU": nil,
            "EASYSPLAT_GLOBAL_MAPPER_GP_USE_GPU": nil,
            "EASYSPLAT_GLOBAL_MAPPER_BA_USE_GPU": nil
        ]) {
            XCTAssertEqual(runner.test_sfmMapperPreference(), "globalMapper")
            let options = runner.test_globalMapperOptions(threadHint: 8)
            XCTAssertTrue(options.useGpuForGlobalPositioning)
            XCTAssertTrue(options.useGpuForBundleAdjustment)
        }
    }

    func testGlobalMapperDefaultUseGpuFalseDisablesGpuWithoutOverrides() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_GLOBAL_MAPPER_GP_USE_GPU": nil,
            "EASYSPLAT_GLOBAL_MAPPER_BA_USE_GPU": nil
        ]) {
            let options = runner.test_globalMapperOptions(threadHint: 8, defaultUseGpu: false)
            XCTAssertFalse(options.useGpuForGlobalPositioning)
            XCTAssertFalse(options.useGpuForBundleAdjustment)
        }
    }

    func testGlobalMapperGpuEnvOverridesTakePrecedence() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_GLOBAL_MAPPER_GP_USE_GPU": "1",
            "EASYSPLAT_GLOBAL_MAPPER_BA_USE_GPU": "0"
        ]) {
            let options = runner.test_globalMapperOptions(threadHint: 8, defaultUseGpu: false)
            XCTAssertTrue(options.useGpuForGlobalPositioning)
            XCTAssertFalse(options.useGpuForBundleAdjustment)
        }
    }

    func testSfmBackendDefaultFallbackOrder() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let restore = await scopedEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SPEED_PROFILE": nil
        ])
        defer { restore() }

        let order = runner.test_sfmBackendFallbackOrder()
        XCTAssertEqual(order, [.da3, .colmap])
        XCTAssertEqual(runner.test_sfmBackendPolicy(), .da3)
    }

    func testFastSpeedProfileDefaultsToColmap() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SPEED_PROFILE": "fast"
        ]) {
            XCTAssertEqual(runner.test_sfmBackendPolicy(), .colmap)
            XCTAssertEqual(runner.test_sfmBackendFallbackOrder(), [.colmap])
        }
    }

    func testConfiguredFastSpeedProfileDefaultsToColmap() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root, speedProfile: .fast)

        await withEnvironmentAsync([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SPEED_PROFILE": nil
        ]) {
            XCTAssertEqual(runner.test_sfmBackendPolicy(), .colmap)
            XCTAssertEqual(runner.test_sfmBackendFallbackOrder(), [.colmap])
        }
    }

    func testSfmBackendDa3FromEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertEqual(runner.test_sfmBackendPolicy(), .da3)
            XCTAssertEqual(runner.test_sfmBackendFallbackOrder(), [.da3])
        }
    }

    func testDa3DirectMinimumTrackLengthPreference() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_DA3_DIRECT_MIN_TRACK_LENGTH": nil]) {
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .object), 1.15, accuracy: 0.001)
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .room), 1.20, accuracy: 0.001)
        }

        await withEnvironmentAsync(["EASYSPLAT_DA3_DIRECT_MIN_TRACK_LENGTH": "1.33"]) {
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .object), 1.33, accuracy: 0.001)
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .room), 1.33, accuracy: 0.001)
        }
    }

    func testResetPerRunToolLogsRemovesDa3Log() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let urls = [
            paths.colmapLogURL,
            paths.globalMapperLogURL,
            paths.da3LogURL,
            paths.msplatLogURL
        ]
        for url in urls {
            try "stale\n".write(to: url, atomically: true, encoding: .utf8)
        }

        PipelineRunner.resetPerRunToolLogs(at: paths)

        for url in urls {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) should be reset")
        }
    }

    func testToolLogFiltering() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let cudaFallbackWarning = "W20260210 22:40:38.521257 0x1f79a2c40 global_positioning.cc:400] Requested to use GPU for bundle adjustment, but COLMAP was compiled without CUDA support. Falling back to CPU-based solvers."

        XCTAssertTrue(runner.test_shouldEmitToolLogLine("EasySplat: colmap argv: /bin/colmap", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("warning: low confidence", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("ERROR: failed to open", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("something bad", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("I20260207 16:43:09.118649 1624963 model.cc:455] Registered images: 3", isError: true))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("W20260207 16:43:09.118649 1624963 model.cc:455] Numerical issue encountered", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("I20260207 16:43:09.118649 1624963 model.cc:455] Registered images: 3", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("W20260207 16:43:09.118649 1624963 model.cc:455] Numerical issue encountered", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine(cudaFallbackWarning, isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("Traceback (most recent call last):", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("  File \"run.py\", line 287, in run_pipeline", isError: false))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("\u{1B}[2K\u{1B}[1B", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("██████ 70/40000 Steps (0.9/s, 12h remaining)", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("normal progress line", isError: false))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("   ", isError: false))
    }

    func testToolLogSeverityNormalization() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let cudaFallbackWarning = "W20260210 22:40:38.521257 0x1f79a2c40 global_positioning.cc:400] Requested to use GPU for bundle adjustment, but COLMAP was compiled without CUDA support. Falling back to CPU-based solvers."

        XCTAssertFalse(runner.test_normalizedToolLogIsError("I20260207 16:43:09.118649 1624963 model.cc:455] Registered images: 3", isError: true))
        XCTAssertFalse(runner.test_normalizedToolLogIsError("W20260207 16:43:09.118649 1624963 model.cc:455] Numerical issue encountered", isError: true))
        XCTAssertTrue(runner.test_normalizedToolLogIsError("E20260207 16:43:09.118649 1624963 model.cc:455] Fatal mapping issue", isError: true))
        XCTAssertTrue(runner.test_normalizedToolLogIsError("TypeError: unexpected keyword argument", isError: true))
        XCTAssertFalse(runner.test_normalizedToolLogIsError("some stdout line", isError: false))
        XCTAssertFalse(runner.test_normalizedToolLogIsError(cudaFallbackWarning, isError: true))
    }

    private func makeRunner(
        projectURL: URL,
        speedProfile: PipelineRunner.SpeedProfile = .standard
    ) -> PipelineRunner {
        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            preset: PresetSpec(mode: .object, quality: .standard),
            speedProfile: speedProfile
        )
        return PipelineRunner(projectURL: projectURL, config: config)
    }

}
