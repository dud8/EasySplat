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

    func testFastSpeedProfileUsesMsplatIterationBudget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SPEED_PROFILE": "fast"]) {
            XCTAssertEqual(runner.test_msplatDefaultIterations(), 1_800)
        }

        await withEnvironmentAsync(["EASYSPLAT_SPEED_PROFILE": nil]) {
            XCTAssertNil(runner.test_msplatDefaultIterations())
        }
    }

    func testFastSpeedProfileAvoidsAutomaticMsplatWhenSparsePointCountIsLow() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let lowScore = ReconstructionScore(
            registeredImages: 60,
            totalImages: 60,
            meanReprojectionError: 0.001,
            pointCount: 1_499
        )
        let enoughScore = ReconstructionScore(
            registeredImages: 60,
            totalImages: 60,
            meanReprojectionError: 0.001,
            pointCount: 1_500
        )

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_TRAINER": nil
        ]) {
            XCTAssertTrue(runner.test_shouldUseBrushInsteadOfAutomaticMsplat(for: lowScore))
            XCTAssertFalse(runner.test_shouldUseBrushInsteadOfAutomaticMsplat(for: enoughScore))
            XCTAssertFalse(runner.test_shouldUseBrushInsteadOfAutomaticMsplat(for: nil))
        }
    }

    func testExplicitMsplatOverrideKeepsMsplatForLowSparsePointCount() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let lowScore = ReconstructionScore(
            registeredImages: 60,
            totalImages: 60,
            meanReprojectionError: 0.001,
            pointCount: 500
        )

        await withEnvironmentAsync([
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_TRAINER": "msplat"
        ]) {
            XCTAssertFalse(runner.test_shouldUseBrushInsteadOfAutomaticMsplat(for: lowScore))
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

    func testVggtPreferencesFromEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_VGGT_USE_BA": "0",
            "EASYSPLAT_VGGT_MAX_REPROJ_ERROR": "9.5",
            "EASYSPLAT_VGGT_SHARED_CAMERA": "1",
            "EASYSPLAT_VGGT_CAMERA_TYPE": "PINHOLE",
            "EASYSPLAT_VGGT_VIS_THRESH": "0.35",
            "EASYSPLAT_VGGT_QUERY_FRAMES": "12",
            "EASYSPLAT_VGGT_MAX_QUERY_PTS": "1024",
            "EASYSPLAT_VGGT_FINE_TRACKING": "0",
            "EASYSPLAT_VGGT_KEYPOINT_EXTRACTOR": "aliked",
            "EASYSPLAT_VGGT_BA_MAX_FRAMES": "77"
        ]) {
            XCTAssertFalse(runner.test_vggtUseBundleAdjustmentPreference())
            XCTAssertEqual(runner.test_vggtMaxReprojectionErrorPreference(), 9.5)
            XCTAssertTrue(runner.test_vggtSharedCameraPreference())
            XCTAssertEqual(runner.test_vggtCameraTypePreference(), "PINHOLE")
            XCTAssertEqual(runner.test_vggtVisibilityThresholdPreference(), 0.35)
            XCTAssertEqual(runner.test_vggtQueryFrameCountPreference(), 12)
            XCTAssertEqual(runner.test_vggtMaxQueryPointsPreference(), 1024)
            XCTAssertFalse(runner.test_vggtFineTrackingPreference())
            XCTAssertEqual(runner.test_vggtKeypointExtractorPreference(), "aliked")
            XCTAssertEqual(runner.test_vggtBaMaxFramesLimit(autoTuneTier: nil), 77)
        }
    }

    func testMapperDefaultsToGlomapWithGpuEnabled() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_COLMAP_USE_GPU": nil,
            "EASYSPLAT_GLOBAL_MAPPER_GP_USE_GPU": nil,
            "EASYSPLAT_GLOBAL_MAPPER_BA_USE_GPU": nil
        ]) {
            XCTAssertEqual(runner.test_sfmMapperPreference(), "glomap")
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

    func testVggtBaMaxFramesLimitDefaults() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let restore = await scopedEnvironment(["EASYSPLAT_VGGT_BA_MAX_FRAMES": nil])
        defer { restore() }

        XCTAssertEqual(runner.test_vggtBaMaxFramesLimit(autoTuneTier: .low), 24)
        XCTAssertEqual(runner.test_vggtBaMaxFramesLimit(autoTuneTier: .mid), 48)
        XCTAssertEqual(runner.test_vggtBaMaxFramesLimit(autoTuneTier: .high), 96)
        XCTAssertEqual(runner.test_vggtBaMaxFramesLimit(autoTuneTier: nil), 32)
    }

    func testFastVggtPreferencesFromEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_FASTVGGT_MERGING": "2",
            "EASYSPLAT_FASTVGGT_MERGE_RATIO": "0.85",
            "EASYSPLAT_FASTVGGT_DEPTH_CONF_THRES": "4.5",
            "EASYSPLAT_FASTVGGT_USE_BA": "0",
            "EASYSPLAT_FASTVGGT_REQUIRE_REFINED_MODEL": "0",
            "EASYSPLAT_FASTVGGT_BA_MAX_ITERS": "33",
            "EASYSPLAT_FASTVGGT_BA_REFINE_FOCAL": "0",
            "EASYSPLAT_FASTVGGT_BA_REFINE_PP": "1",
            "EASYSPLAT_FASTVGGT_BA_REFINE_EXTRA": "1",
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": "1",
            "EASYSPLAT_FASTVGGT_NO_FALLBACK": "1",
            "EASYSPLAT_FASTVGGT_GPU_ONLY": "1",
            "EASYSPLAT_FASTVGGT_POSTPROCESS": "gpu_ba_lite",
            "EASYSPLAT_FASTVGGT_COVERAGE_PLANNER": "temporal",
            "EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS": "31000",
            "EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP": "0.4",
            "EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS": "6"
        ]) {
            XCTAssertEqual(runner.test_fastvggtMergingPreference(), 2)
            XCTAssertEqual(runner.test_fastvggtMergeRatioPreference(), 0.85, accuracy: 0.0001)
            XCTAssertEqual(runner.test_fastvggtConfidenceThresholdPreference(), 4.5)
            XCTAssertFalse(runner.test_fastvggtUseBundleAdjustmentPreference())
            XCTAssertFalse(runner.test_fastvggtRequireRefinedModelPreference())
            XCTAssertEqual(runner.test_fastvggtBaMaxIterationsPreference(), 33)
            XCTAssertFalse(runner.test_fastvggtBaRefineFocalPreference())
            XCTAssertTrue(runner.test_fastvggtBaRefinePrincipalPointPreference())
            XCTAssertTrue(runner.test_fastvggtBaRefineExtraParamsPreference())
            XCTAssertTrue(runner.test_fastvggtFullCoveragePreference())
            XCTAssertTrue(runner.test_fastvggtNoFallbackPreference())
            XCTAssertTrue(runner.test_fastvggtGpuOnlyPreference())
            XCTAssertEqual(runner.test_fastvggtPostprocessPreference(), "gpu_ba_lite")
            XCTAssertEqual(runner.test_fastvggtCoveragePlannerPreference(), "temporal")
            XCTAssertEqual(runner.test_fastvggtCoverageWindowTokensPreference(), 31_000)
            XCTAssertEqual(runner.test_fastvggtCoverageOverlapPreference(), 0.4, accuracy: 0.0001)
            XCTAssertEqual(runner.test_fastvggtCoverageMaxRoundsPreference(), 6)
        }
    }

    func testFastVggtRefinementPreferenceDefaults() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let restore = await scopedEnvironment([
            "EASYSPLAT_FASTVGGT_USE_BA": nil,
            "EASYSPLAT_FASTVGGT_REQUIRE_REFINED_MODEL": nil,
            "EASYSPLAT_FASTVGGT_BA_MAX_ITERS": nil,
            "EASYSPLAT_FASTVGGT_BA_REFINE_FOCAL": nil,
            "EASYSPLAT_FASTVGGT_BA_REFINE_PP": nil,
            "EASYSPLAT_FASTVGGT_BA_REFINE_EXTRA": nil,
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": nil,
            "EASYSPLAT_FASTVGGT_NO_FALLBACK": nil,
            "EASYSPLAT_FASTVGGT_GPU_ONLY": nil,
            "EASYSPLAT_FASTVGGT_POSTPROCESS": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_PLANNER": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS": nil
        ])
        defer { restore() }

        XCTAssertTrue(runner.test_fastvggtUseBundleAdjustmentPreference())
        XCTAssertTrue(runner.test_fastvggtRequireRefinedModelPreference())
        XCTAssertEqual(runner.test_fastvggtBaMaxIterationsPreference(), 50)
        XCTAssertTrue(runner.test_fastvggtBaRefineFocalPreference())
        XCTAssertFalse(runner.test_fastvggtBaRefinePrincipalPointPreference())
        XCTAssertFalse(runner.test_fastvggtBaRefineExtraParamsPreference())
        XCTAssertFalse(runner.test_fastvggtFullCoveragePreference())
        XCTAssertFalse(runner.test_fastvggtNoFallbackPreference())
        XCTAssertFalse(runner.test_fastvggtGpuOnlyPreference())
        XCTAssertEqual(runner.test_fastvggtPostprocessPreference(), "gpu_ba_lite")
        XCTAssertEqual(runner.test_fastvggtCoveragePlannerPreference(), "auto")
        XCTAssertEqual(runner.test_fastvggtCoverageWindowTokensPreference(), 25_000)
        XCTAssertEqual(runner.test_fastvggtCoverageOverlapPreference(), 0.35, accuracy: 0.0001)
        XCTAssertEqual(runner.test_fastvggtCoverageMaxRoundsPreference(), 4)
    }

    func testFastVggtStrictCoverageDefaultsByTier() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let lowVideo = runner.test_fastvggtStrictCoverageDefaults(
            autoTuneTier: .low,
            hardwareTier: nil,
            input: .video(files: ["movie.mp4"]),
            selectedFrameCount: 1_400
        )
        XCTAssertEqual(lowVideo.planner, "temporal")
        XCTAssertEqual(lowVideo.windowTokens, 14_000)
        XCTAssertEqual(lowVideo.overlap, 0.55, accuracy: 0.0001)
        XCTAssertEqual(lowVideo.maxRounds, 8)
        XCTAssertEqual(lowVideo.postprocess, "none")

        let midPhotos = runner.test_fastvggtStrictCoverageDefaults(
            autoTuneTier: .mid,
            hardwareTier: nil,
            input: .photos(folder: "/tmp/photos"),
            selectedFrameCount: 600
        )
        XCTAssertEqual(midPhotos.planner, "appearance")
        XCTAssertEqual(midPhotos.windowTokens, 22_000)
        XCTAssertEqual(midPhotos.overlap, 0.42, accuracy: 0.0001)
        XCTAssertEqual(midPhotos.maxRounds, 5)
        XCTAssertEqual(midPhotos.postprocess, "gpu_ba_lite")

        let highPhotos = runner.test_fastvggtStrictCoverageDefaults(
            autoTuneTier: .high,
            hardwareTier: nil,
            input: .photos(folder: "/tmp/photos"),
            selectedFrameCount: 1_700
        )
        XCTAssertEqual(highPhotos.planner, "auto")
        XCTAssertEqual(highPhotos.windowTokens, 30_000)
        XCTAssertEqual(highPhotos.overlap, 0.32, accuracy: 0.0001)
        XCTAssertEqual(highPhotos.maxRounds, 6)
        XCTAssertEqual(highPhotos.postprocess, "gpu_ba_lite")
    }

    func testFastVggtCoverageConfigDefaultsToGpuOnlyInStrictMode() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_FASTVGGT_GPU_ONLY": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_PLANNER": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS": nil,
            "EASYSPLAT_FASTVGGT_POSTPROCESS": nil
        ]) {
            let config = runner.test_fastvggtCoverageConfig(
                strictModeEnabled: true,
                input: .video(files: ["movie.mp4"]),
                selectedFrameCount: 240,
                autoTuneTier: .mid,
                hardwareTier: nil
            )

            XCTAssertTrue(config.requireFullCoverage)
            XCTAssertTrue(config.gpuOnly)
            XCTAssertEqual(config.postprocessMode, "gpu_ba_lite")
            XCTAssertEqual(config.coveragePlanner, "temporal")
        }
    }

    func testFastVggtCoverageConfigUsesHardwareTierWhenAutotuneUnavailable() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_FASTVGGT_GPU_ONLY": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_PLANNER": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP": nil,
            "EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS": nil,
            "EASYSPLAT_FASTVGGT_POSTPROCESS": nil
        ]) {
            let config = runner.test_fastvggtCoverageConfig(
                strictModeEnabled: true,
                input: .photos(folder: "/tmp/photos"),
                selectedFrameCount: 500,
                autoTuneTier: nil,
                hardwareTier: .low
            )

            XCTAssertEqual(config.coveragePlanner, "appearance")
            XCTAssertEqual(config.coverageWindowTokens, 14_000)
            XCTAssertEqual(config.coverageOverlap, 0.55, accuracy: 0.0001)
            XCTAssertEqual(config.coverageMaxRounds, 7)
        }
    }

    func testFastVggtStrictCoverageDefaultsTightenForConstrainedHardware() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let constrained = runner.test_fastvggtStrictCoverageDefaults(
            autoTuneTier: nil,
            hardwareTier: nil,
            hardwareMemoryGB: 10,
            hardwareGpuWorkingSetGB: 4.5,
            input: .photos(folder: "/tmp/photos"),
            selectedFrameCount: 1_000
        )

        XCTAssertEqual(constrained.planner, "appearance")
        XCTAssertEqual(constrained.windowTokens, 12_000)
        XCTAssertEqual(constrained.overlap, 0.58, accuracy: 0.0001)
        XCTAssertEqual(constrained.maxRounds, 9)
        XCTAssertEqual(constrained.postprocess, "none")
    }

    func testFastVggtStrictCoverageDefaultsExpandForHighEndHardware() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let highEnd = runner.test_fastvggtStrictCoverageDefaults(
            autoTuneTier: nil,
            hardwareTier: nil,
            hardwareMemoryGB: 64,
            hardwareGpuWorkingSetGB: 24,
            input: .photos(folder: "/tmp/photos"),
            selectedFrameCount: 1_700
        )

        XCTAssertEqual(highEnd.planner, "auto")
        XCTAssertEqual(highEnd.windowTokens, 34_000)
        XCTAssertEqual(highEnd.overlap, 0.27, accuracy: 0.0001)
        XCTAssertEqual(highEnd.maxRounds, 5)
        XCTAssertEqual(highEnd.postprocess, "gpu_ba_lite")
    }

    func testFastVggtStrictCoverageDefaultsDisablePostprocessForHugeSets() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let huge = runner.test_fastvggtStrictCoverageDefaults(
            autoTuneTier: .high,
            hardwareTier: nil,
            input: .photos(folder: "/tmp/photos"),
            selectedFrameCount: 3_200
        )

        XCTAssertEqual(huge.postprocess, "none")
    }

    func testFastVggtCoverageConfigEnvOverridesStrictGpuOnlyDefault() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_FASTVGGT_GPU_ONLY": "0",
            "EASYSPLAT_FASTVGGT_COVERAGE_PLANNER": "appearance",
            "EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS": "26000",
            "EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP": "0.33",
            "EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS": "9",
            "EASYSPLAT_FASTVGGT_POSTPROCESS": "none"
        ]) {
            let config = runner.test_fastvggtCoverageConfig(
                strictModeEnabled: true,
                input: .video(files: ["movie.mp4"]),
                selectedFrameCount: 240,
                autoTuneTier: .mid,
                hardwareTier: nil
            )

            XCTAssertFalse(config.gpuOnly)
            XCTAssertEqual(config.coveragePlanner, "appearance")
            XCTAssertEqual(config.coverageWindowTokens, 26_000)
            XCTAssertEqual(config.coverageOverlap, 0.33, accuracy: 0.0001)
            XCTAssertEqual(config.coverageMaxRounds, 9)
            XCTAssertEqual(config.postprocessMode, "none")
        }
    }

    func testFastVggtRefinementSpeedTuningAppliesForLargeFrameSets() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let extract = ColmapOptions(
            useGPU: false,
            extractThreads: 8,
            matchThreads: 8,
            sequentialOverlap: 12,
            maxNumFeatures: 10_000,
            maxNumMatches: nil,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 25,
            environment: [:]
        )
        let match = ColmapOptions(
            useGPU: false,
            extractThreads: 8,
            matchThreads: 8,
            sequentialOverlap: 12,
            maxNumFeatures: nil,
            maxNumMatches: 10_000,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 25,
            environment: [:]
        )

        let tuned = runner.test_tuneFastVggtRefinementColmapOptions(
            frameCount: 445,
            extractOptions: extract,
            matchOptions: match
        )

        XCTAssertEqual(tuned.extract.maxNumFeatures, 9_000)
        XCTAssertEqual(tuned.match.sequentialOverlap, 8)
        XCTAssertEqual(tuned.match.maxNumMatches, 8_000)
        XCTAssertEqual(tuned.match.exhaustiveBlockSize, 25)
        XCTAssertFalse(tuned.notes.isEmpty)
    }

    func testFastVggtRefinementSpeedTuningAppliesAggressiveCapsForVeryLargeFrameSets() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let extract = ColmapOptions(
            useGPU: false,
            extractThreads: 8,
            matchThreads: 8,
            sequentialOverlap: 12,
            maxNumFeatures: 11_000,
            maxNumMatches: nil,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: nil,
            environment: [:]
        )
        let match = ColmapOptions(
            useGPU: false,
            extractThreads: 8,
            matchThreads: 8,
            sequentialOverlap: 12,
            maxNumFeatures: nil,
            maxNumMatches: 11_000,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 20,
            environment: [:]
        )

        let tuned = runner.test_tuneFastVggtRefinementColmapOptions(
            frameCount: 520,
            extractOptions: extract,
            matchOptions: match
        )

        XCTAssertEqual(tuned.extract.maxNumFeatures, 8_192)
        XCTAssertEqual(tuned.match.sequentialOverlap, 6)
        XCTAssertEqual(tuned.match.maxNumMatches, 7_000)
        XCTAssertEqual(tuned.match.exhaustiveBlockSize, 30)
        XCTAssertGreaterThanOrEqual(tuned.notes.count, 3)
    }

    func testFastVggtRefinementSpeedTuningSkipsSmallFrameSets() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let extract = ColmapOptions(
            useGPU: false,
            extractThreads: 8,
            matchThreads: 8,
            sequentialOverlap: 10,
            maxNumFeatures: 8_192,
            maxNumMatches: nil,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 20,
            environment: [:]
        )
        let match = ColmapOptions(
            useGPU: false,
            extractThreads: 8,
            matchThreads: 8,
            sequentialOverlap: 10,
            maxNumFeatures: nil,
            maxNumMatches: 8_192,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 20,
            environment: [:]
        )

        let tuned = runner.test_tuneFastVggtRefinementColmapOptions(
            frameCount: 120,
            extractOptions: extract,
            matchOptions: match
        )

        XCTAssertEqual(tuned.extract.maxNumFeatures, extract.maxNumFeatures)
        XCTAssertEqual(tuned.match.sequentialOverlap, match.sequentialOverlap)
        XCTAssertEqual(tuned.match.maxNumMatches, match.maxNumMatches)
        XCTAssertEqual(tuned.match.exhaustiveBlockSize, match.exhaustiveBlockSize)
        XCTAssertTrue(tuned.notes.isEmpty)
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
        XCTAssertEqual(order, [.da3, .mapanything, .colmap])
        XCTAssertEqual(runner.test_sfmBackendPolicy(), .da3)
    }

    func testSfmBackendFallbackOrderIgnoresDeprecatedGraceEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_ENABLE_VGGT_GRACE_FALLBACK": "1"
        ]) {
            let order = runner.test_sfmBackendFallbackOrder()
            XCTAssertEqual(order, [.da3, .mapanything, .colmap])
        }
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

    func testSfmBackendGlomapAliasFromEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "glomap"]) {
            XCTAssertEqual(runner.test_sfmBackendPolicy(), .colmap)
            XCTAssertEqual(runner.test_sfmBackendFallbackOrder(), [.colmap])
        }
    }

    func testSfmBackendMapAnythingFromEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "mapanything"]) {
            XCTAssertEqual(runner.test_sfmBackendPolicy(), .mapanything)
            XCTAssertEqual(runner.test_sfmBackendFallbackOrder(), [.mapanything, .colmap])
        }
    }

    func testSfmBackendFastVggtFromEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "fastvggt"]) {
            XCTAssertEqual(runner.test_sfmBackendPolicy(), .fastvggt)
        }
    }

    func testSfmBackendFallbackOrderFromEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "vggt"]) {
            let order = runner.test_sfmBackendFallbackOrder()
            XCTAssertEqual(order, [.vggt])
        }
    }

    func testVggtDirectMinimumSparsePointsClampsToMaxPoints() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let score = ReconstructionScore(
            registeredImages: 500,
            totalImages: 500,
            meanReprojectionError: nil,
            pointCount: 150_000,
            observationCount: 300_000,
            meanTrackLength: 2.0
        )

        let reason = runner.test_vggtDirectQualityFailureReason(
            score: score,
            selectedFrameCount: 500,
            mode: .object,
            maxPoints: 150_000
        )

        XCTAssertNil(reason)
    }

    func testMapAnythingExecutionPlanDisablesDirectOnLowTier() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_RESOLUTION": nil,
            "EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT": nil,
            "EASYSPLAT_MAPANYTHING_USE_AMP": nil,
            "EASYSPLAT_MAPANYTHING_MAX_POINTS": nil,
            "EASYSPLAT_MAPANYTHING_CAMERA_TYPE": nil,
            "EASYSPLAT_MAPANYTHING_SHARED_CAMERA": nil,
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": nil
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .low,
                selectedFrameCount: 4,
                preset: PresetSpec(mode: .object, quality: .standard)
            )

            XCTAssertEqual(plan.mode, "seed_refine")
            XCTAssertFalse(plan.directAllowed)
            XCTAssertEqual(plan.directViewLimit, 0)
            XCTAssertEqual(plan.resolution, 518)
            XCTAssertTrue(plan.memoryEfficientInference)
            XCTAssertFalse(plan.useAMP)
        }
    }

    func testMapAnythingExecutionPlanAllowsExplicitDirectOnLowTier() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_RESOLUTION": nil,
            "EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT": nil,
            "EASYSPLAT_MAPANYTHING_USE_AMP": nil,
            "EASYSPLAT_MAPANYTHING_MAX_POINTS": nil,
            "EASYSPLAT_MAPANYTHING_CAMERA_TYPE": nil,
            "EASYSPLAT_MAPANYTHING_SHARED_CAMERA": nil,
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": nil
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .low,
                selectedFrameCount: 4,
                preset: PresetSpec(mode: .object, quality: .standard),
                explicitlyRequested: true
            )

            XCTAssertEqual(plan.mode, "direct")
            XCTAssertTrue(plan.directAllowed)
            XCTAssertEqual(plan.directViewLimit, 8)
            XCTAssertTrue(plan.memoryEfficientInference)
        }
    }

    func testMapAnythingExecutionPlanUsesDirectWithinMidTierLimit() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_RESOLUTION": nil,
            "EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT": nil,
            "EASYSPLAT_MAPANYTHING_USE_AMP": nil,
            "EASYSPLAT_MAPANYTHING_MAX_POINTS": nil,
            "EASYSPLAT_MAPANYTHING_CAMERA_TYPE": nil,
            "EASYSPLAT_MAPANYTHING_SHARED_CAMERA": nil,
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": nil
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .mid,
                selectedFrameCount: 6,
                preset: PresetSpec(mode: .object, quality: .standard)
            )

            XCTAssertEqual(plan.mode, "direct")
            XCTAssertTrue(plan.directAllowed)
            XCTAssertEqual(plan.directViewLimit, 6)
            XCTAssertEqual(plan.windowSize, 6)
            XCTAssertEqual(plan.windowOverlap, 0)
            XCTAssertEqual(plan.cameraType, "SIMPLE_RADIAL")
        }
    }

    func testMapAnythingExecutionPlanDisablesDirectWhenOnlyOneFrameRemains() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_RESOLUTION": nil,
            "EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT": nil,
            "EASYSPLAT_MAPANYTHING_USE_AMP": nil,
            "EASYSPLAT_MAPANYTHING_MAX_POINTS": nil,
            "EASYSPLAT_MAPANYTHING_CAMERA_TYPE": nil,
            "EASYSPLAT_MAPANYTHING_SHARED_CAMERA": nil,
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": nil
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .high,
                selectedFrameCount: 1,
                preset: PresetSpec(mode: .object, quality: .standard)
            )

            XCTAssertEqual(plan.mode, "seed_refine")
            XCTAssertFalse(plan.directAllowed)
        }
    }

    func testMapAnythingExecutionPlanFallsBackToSeedRefineAboveHighTierLimit() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_RESOLUTION": nil,
            "EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT": nil,
            "EASYSPLAT_MAPANYTHING_USE_AMP": nil,
            "EASYSPLAT_MAPANYTHING_MAX_POINTS": nil,
            "EASYSPLAT_MAPANYTHING_CAMERA_TYPE": nil,
            "EASYSPLAT_MAPANYTHING_SHARED_CAMERA": nil,
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": nil,
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": nil
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .high,
                selectedFrameCount: 12,
                preset: PresetSpec(mode: .room, quality: .ultra)
            )

            XCTAssertEqual(plan.mode, "seed_refine")
            XCTAssertFalse(plan.directAllowed)
            XCTAssertEqual(plan.directViewLimit, 8)
            XCTAssertEqual(plan.windowSize, 8)
            XCTAssertEqual(plan.windowOverlap, 2)
            XCTAssertEqual(plan.cameraType, "OPENCV")
        }
    }

    func testMapAnythingExecutionPlanEnvOverridesTakePrecedenceOverAutoTune() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let autoTune = makeMapAnythingAutoTuneProfile(
            tier: .low,
            anchorMaxViews: 24,
            windowSize: 4,
            windowOverlap: 1
        )

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": "19",
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": "11",
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": "7"
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .low,
                selectedFrameCount: 30,
                preset: PresetSpec(mode: .object, quality: .standard),
                autoTune: autoTune
            )

            XCTAssertEqual(plan.anchorMaxViews, 19)
            XCTAssertEqual(plan.windowSize, 11)
            XCTAssertEqual(plan.windowOverlap, 7)
        }
    }

    func testMapAnythingExecutionPlanIgnoresInvalidEnvAndUsesAutoTuneValues() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let autoTune = makeMapAnythingAutoTuneProfile(
            tier: .mid,
            anchorMaxViews: 15,
            windowSize: 7,
            windowOverlap: 3
        )

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": "0",
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": "-5",
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": "-1"
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .mid,
                selectedFrameCount: 20,
                preset: PresetSpec(mode: .object, quality: .standard),
                autoTune: autoTune
            )

            XCTAssertEqual(plan.anchorMaxViews, 15)
            XCTAssertEqual(plan.windowSize, 7)
            XCTAssertEqual(plan.windowOverlap, 3)
        }
    }

    func testMapAnythingExecutionPlanClampsLargeEnvOverridesToSafeBounds() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS": "99",
            "EASYSPLAT_MAPANYTHING_WINDOW_SIZE": "99",
            "EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP": "99"
        ]) {
            let plan = runner.test_mapAnythingExecutionPlan(
                hardwareTier: .low,
                selectedFrameCount: 5,
                preset: PresetSpec(mode: .object, quality: .standard)
            )

            XCTAssertEqual(plan.anchorMaxViews, 5)
            XCTAssertEqual(plan.windowSize, 5)
            XCTAssertEqual(plan.windowOverlap, 4)
        }
    }

    func testMapAnythingSharedCameraDefaultsToVideoInputs() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        XCTAssertTrue(
            runner.test_mapAnythingSharedCameraPreference(
                input: .video(files: ["/tmp/video.mov"])
            )
        )
        XCTAssertFalse(
            runner.test_mapAnythingSharedCameraPreference(
                input: .photos(folder: "/tmp/photos")
            )
        )
    }

    func testMapAnythingResolutionPreferenceNormalizesUnsupportedValues() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_MAPANYTHING_RESOLUTION": "500"]) {
            XCTAssertEqual(runner.test_mapAnythingResolutionPreference(), 512)
        }
        await withEnvironmentAsync(["EASYSPLAT_MAPANYTHING_RESOLUTION": "900"]) {
            XCTAssertEqual(runner.test_mapAnythingResolutionPreference(), 518)
        }
        await withEnvironmentAsync(["EASYSPLAT_MAPANYTHING_RESOLUTION": "518"]) {
            XCTAssertEqual(runner.test_mapAnythingResolutionPreference(), 518)
        }
    }

    func testMapAnythingDirectMinimumTrackLengthDefaultsAndAllowsOverride() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH": nil]) {
            XCTAssertEqual(runner.test_mapAnythingDirectMinimumMeanTrackLengthPreference(mode: .object), 1.15, accuracy: 0.001)
            XCTAssertEqual(runner.test_mapAnythingDirectMinimumMeanTrackLengthPreference(mode: .room), 1.20, accuracy: 0.001)
        }

        await withEnvironmentAsync(["EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH": "1.33"]) {
            XCTAssertEqual(runner.test_mapAnythingDirectMinimumMeanTrackLengthPreference(mode: .object), 1.33, accuracy: 0.001)
            XCTAssertEqual(runner.test_mapAnythingDirectMinimumMeanTrackLengthPreference(mode: .room), 1.33, accuracy: 0.001)
        }
    }

    func testDa3DirectMinimumTrackLengthUsesDa3EnvOnly() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_DA3_DIRECT_MIN_TRACK_LENGTH": nil,
            "EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH": nil
        ]) {
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .object), 1.15, accuracy: 0.001)
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .room), 1.20, accuracy: 0.001)
        }

        await withEnvironmentAsync([
            "EASYSPLAT_DA3_DIRECT_MIN_TRACK_LENGTH": nil,
            "EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH": "1.80"
        ]) {
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .object), 1.15, accuracy: 0.001)
        }
        await withEnvironmentAsync([
            "EASYSPLAT_DA3_DIRECT_MIN_TRACK_LENGTH": "1.33",
            "EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH": nil
        ]) {
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .object), 1.33, accuracy: 0.001)
            XCTAssertEqual(runner.test_da3DirectMinimumMeanTrackLengthPreference(mode: .room), 1.33, accuracy: 0.001)
        }
    }

    func testMapAnythingDirectQualityFailureReasonRequiresRobustTracks() async throws {
        let restore = await scopedEnvironment(["EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH": nil])
        defer { restore() }

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let good = ReconstructionScore(
            registeredImages: 4,
            totalImages: 4,
            meanReprojectionError: 0.8,
            pointCount: 4_000,
            observationCount: 5_200,
            meanTrackLength: 1.30
        )
        XCTAssertNil(runner.test_mapAnythingDirectQualityFailureReason(score: good, mode: .object))

        let thinTracks = ReconstructionScore(
            registeredImages: 4,
            totalImages: 4,
            meanReprojectionError: 0.8,
            pointCount: 4_000,
            observationCount: 4_080,
            meanTrackLength: 1.02
        )
        XCTAssertTrue(
            runner.test_mapAnythingDirectQualityFailureReason(score: thinTracks, mode: .object)?
                .contains("mean track length") == true
        )

        let missingTrackStats = ReconstructionScore(
            registeredImages: 4,
            totalImages: 4,
            meanReprojectionError: 0.8,
            pointCount: 4_000,
            observationCount: 4_500,
            meanTrackLength: nil
        )
        XCTAssertTrue(
            runner.test_mapAnythingDirectQualityFailureReason(score: missingTrackStats, mode: .object)?
                .contains("mean track length") == true
        )
    }

    func testDa3DirectQualityFailureReasonIgnoresMapAnythingThreshold() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        let score = ReconstructionScore(
            registeredImages: 4,
            totalImages: 4,
            meanReprojectionError: 0.8,
            pointCount: 4_000,
            observationCount: 5_200,
            meanTrackLength: 1.30
        )

        await withEnvironmentAsync([
            "EASYSPLAT_DA3_DIRECT_MIN_TRACK_LENGTH": nil,
            "EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH": "1.80"
        ]) {
            XCTAssertNil(runner.test_da3DirectQualityFailureReason(score: score, mode: .object))
            XCTAssertNotNil(runner.test_mapAnythingDirectQualityFailureReason(score: score, mode: .object))
        }
    }

    func testResetPerRunToolLogsRemovesDa3Log() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let urls = [
            paths.colmapLogURL,
            paths.glomapLogURL,
            paths.da3LogURL,
            paths.mapanythingLogURL,
            paths.vggtLogURL,
            paths.fastvggtLogURL,
            paths.brushLogURL,
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

    func testBrushExportStepParsing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(runner.test_brushExportStep(from: root.appendingPathComponent("export_05000.ply")), 5000)
        XCTAssertEqual(runner.test_brushExportStep(from: root.appendingPathComponent("export_01000.compressed.ply")), 1000)
        XCTAssertNil(runner.test_brushExportStep(from: root.appendingPathComponent("other.ply")))
    }

    func testLatestBrushExportPrefersNewestFileInCurrentRunWindow() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let training = root.appendingPathComponent("Training", isDirectory: true)
        let exports = training.appendingPathComponent("dataset_exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        let historicalHigh = exports.appendingPathComponent("export_35000.ply")
        let currentRun = exports.appendingPathComponent("export_05000.ply")
        TestFileBuilder.createFile(at: historicalHigh, data: Data([0x00]))
        TestFileBuilder.createFile(at: currentRun, data: Data([0x00]))

        let base = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: historicalHigh.path)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(300)], ofItemAtPath: currentRun.path)
        let runStart = base.addingTimeInterval(120)

        let runner = makeRunner(projectURL: root)
        let latest = runner.test_latestBrushExport(in: training, minModificationDate: runStart)
        XCTAssertEqual(latest?.step, 5000)
        XCTAssertEqual(latest?.file.resolvingSymlinksInPath().path, currentRun.resolvingSymlinksInPath().path)
    }

    func testLatestBrushExportReturnsNilWhenNoFilesInCurrentRunWindow() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let training = root.appendingPathComponent("Training", isDirectory: true)
        let exports = training.appendingPathComponent("dataset_exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        let oldExport = exports.appendingPathComponent("export_10000.ply")
        TestFileBuilder.createFile(at: oldExport, data: Data([0x00]))
        let oldDate = Date().addingTimeInterval(-900)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldExport.path)

        let runner = makeRunner(projectURL: root)
        let latest = runner.test_latestBrushExport(in: training, minModificationDate: Date().addingTimeInterval(-30))
        XCTAssertNil(latest)
    }

    func testLatestTrainingExportFallsBackFromStaleMsplatToFreshBrushExport() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let training = root.appendingPathComponent("Training", isDirectory: true)
        let exports = training.appendingPathComponent("dataset_exports", isDirectory: true)
        let msplat = training.appendingPathComponent("msplat", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: msplat, withIntermediateDirectories: true)

        let staleMsplat = msplat.appendingPathComponent("splat.ply")
        let freshBrush = exports.appendingPathComponent("export_00020.ply")
        try TestFileBuilder.writeMinimalPly(at: staleMsplat)
        try TestFileBuilder.writeMinimalPly(at: freshBrush)

        let cutoff = Date()
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(-60)], ofItemAtPath: staleMsplat.path)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(5)], ofItemAtPath: freshBrush.path)

        let runner = makeRunner(projectURL: root)
        let latest = runner.test_latestTrainingExport(in: training, backend: .msplat, minModificationDate: cutoff)
        XCTAssertEqual(latest?.standardizedFileURL, freshBrush.standardizedFileURL)
    }

    func testLatestBrushExportRecursiveFallbackIgnoresSnapshotsAndCompressedFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let training = root.appendingPathComponent("Training", isDirectory: true)
        let nested = training.appendingPathComponent("custom_exports", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let exportOld = nested.appendingPathComponent("export_00010.ply")
        let compressedNew = nested.appendingPathComponent("export_99999.compressed.ply")
        let snapshotNew = training.appendingPathComponent("latest_snapshot.ply")
        try TestFileBuilder.writeMinimalPly(at: exportOld)
        try TestFileBuilder.writeMinimalPly(at: compressedNew)
        try TestFileBuilder.writeMinimalPly(at: snapshotNew)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: exportOld.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: compressedNew.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(100)], ofItemAtPath: snapshotNew.path)

        let runner = makeRunner(projectURL: root)
        let latest = runner.test_latestBrushExport(in: training)
        XCTAssertEqual(latest?.file.standardizedFileURL, exportOld.standardizedFileURL)
        XCTAssertEqual(latest?.step, 10)
    }

    func testUpdateBrushResumeSnapshotReplacesFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let training = root.appendingPathComponent("Training", isDirectory: true)
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)

        let export = training.appendingPathComponent("export_00001.ply")
        let snapshot = training.appendingPathComponent("latest_snapshot.ply")
        let exportData = Data([0x01, 0x02, 0x03])
        let oldData = Data([0x00])
        TestFileBuilder.createFile(at: export, data: exportData)
        TestFileBuilder.createFile(at: snapshot, data: oldData)

        let runner = makeRunner(projectURL: root)
        runner.test_updateBrushResumeSnapshot(from: export, trainingURL: training)

        let updatedData = try Data(contentsOf: snapshot)
        XCTAssertEqual(updatedData, exportData)
        let tempURL = training.appendingPathComponent("latest_snapshot.ply.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testClearBrushResumeSnapshotRemovesStaleSnapshot() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let training = root.appendingPathComponent("Training", isDirectory: true)
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)

        let snapshot = training.appendingPathComponent("latest_snapshot.ply")
        TestFileBuilder.createFile(at: snapshot, data: Data([0xAA]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        let runner = makeRunner(projectURL: root)
        runner.test_clearBrushResumeSnapshot(in: training)

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
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

    func testBrushTrainingPlanForQualityPresets() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SPEED_PROFILE": nil]) {
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
    }

    func testBrushTrainingPlanFastSpeedProfileUsesShortBudget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync(["EASYSPLAT_SPEED_PROFILE": "fast"]) {
            let plan = runner.test_brushTrainingPlan(for: PresetSpec(mode: .object, quality: .standard))
            XCTAssertEqual(plan.totalSteps, 2_000)
            XCTAssertEqual(plan.exportEvery, 2_000)
        }
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

        let etaMessage = runner.test_trainingStatusMessage(
            elapsed: 65,
            step: 1000,
            total: 10000,
            latestExportStep: nil,
            totalSteps: 10000,
            etaSeconds: 754
        )
        XCTAssertTrue(etaMessage.contains("ETA 12m 34s"))

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

    func testTrainingEtaEstimatorThresholdsAndSmoothing() {
        let root = try? TestFileBuilder.makeTempDir()
        defer {
            if let root {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let runner = makeRunner(projectURL: root ?? URL(fileURLWithPath: "/tmp"))

        let early = runner.test_trainingEtaEstimate(rates: [1, 1, 1, 1, 1], step: 50, total: 100)
        XCTAssertNil(early)

        let eta = runner.test_trainingEtaEstimate(rates: [1, 1, 1, 1, 1, 1], step: 50, total: 100)
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta ?? 0, 50, accuracy: 0.001)

        let smoothed = runner.test_trainingEtaEstimate(rates: [1, 1, 1, 1, 1, 2], step: 50, total: 100)
        XCTAssertNotNil(smoothed)
        XCTAssertEqual(smoothed ?? 0, 41.66, accuracy: 0.1)
    }

    func testTrainingEtaEstimatorDampensSuddenEtaDrops() {
        let root = try? TestFileBuilder.makeTempDir()
        defer {
            if let root {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let runner = makeRunner(projectURL: root ?? URL(fileURLWithPath: "/tmp"))

        let estimates = runner.test_trainingEtaEstimatesWithSpike(
            initialRates: [1, 1, 1, 1, 1, 1],
            spikeRate: 5,
            step: 60,
            total: 120
        )
        guard let baseline = estimates.baseline else {
            return XCTFail("Expected initial ETA estimate")
        }
        guard let damped = estimates.damped else {
            return XCTFail("Expected damped ETA estimate")
        }
        XCTAssertLessThan(damped, baseline)
        XCTAssertGreaterThan(damped, 45)
    }

    private func makeRunner(
        projectURL: URL,
        speedProfile: PipelineRunner.SpeedProfile = .standard
    ) -> PipelineRunner {
        let vggt = VggtToolchain(root: projectURL, sfmTool: projectURL, python: projectURL, models: projectURL)
        let fastvggt = FastVggtToolchain(root: projectURL, sfmTool: projectURL, python: projectURL, models: projectURL)
        let toolchain = ToolchainPaths(
            root: projectURL,
            colmap: projectURL,
            glomap: projectURL,
            brush: projectURL,
            vggt: vggt,
            fastvggt: fastvggt
        )
        let config = PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            preset: PresetSpec(mode: .object, quality: .standard),
            speedProfile: speedProfile
        )
        return PipelineRunner(projectURL: projectURL, config: config)
    }

    private func makeMapAnythingAutoTuneProfile(
        tier: HardwareProfile.Tier,
        anchorMaxViews: Int,
        windowSize: Int,
        windowOverlap: Int
    ) -> AutoTuneProfile {
        AutoTuneProfile(
            tier: tier,
            mapAnythingResolution: 518,
            mapAnythingDirectViewLimit: 0,
            mapAnythingAnchorMaxViews: anchorMaxViews,
            mapAnythingWindowSize: windowSize,
            mapAnythingWindowOverlap: windowOverlap,
            vggtImageLoadResolution: 1024,
            vggtFixedResolution: 518,
            vggtMaxPoints: 100_000,
            colmapMaxNumFeatures: 8_192,
            colmapMaxNumMatches: 8_192,
            sequentialOverlap: 10,
            exhaustiveBlockSize: 20,
            threadCap: 6,
            colmapMaxImageSizeCap: nil,
            vggtAllowed: true
        )
    }

}
