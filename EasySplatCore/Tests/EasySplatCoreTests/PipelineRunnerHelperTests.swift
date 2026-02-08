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
            "EASYSPLAT_SFM_BACKEND": nil
        ])
        defer { restore() }

        let order = runner.test_sfmBackendFallbackOrder()
        XCTAssertEqual(order, [.fastvggt, .colmap])
        XCTAssertEqual(runner.test_sfmBackendPolicy(), .fastvggt)
    }

    func testSfmBackendFallbackOrderIgnoresDeprecatedGraceEnv() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        await withEnvironmentAsync([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_ENABLE_VGGT_GRACE_FALLBACK": "1"
        ]) {
            let order = runner.test_sfmBackendFallbackOrder()
            XCTAssertEqual(order, [.fastvggt, .colmap])
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

        XCTAssertTrue(runner.test_shouldEmitToolLogLine("EasySplat: colmap argv: /bin/colmap", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("warning: low confidence", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("ERROR: failed to open", isError: false))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("something bad", isError: true))
        XCTAssertFalse(runner.test_shouldEmitToolLogLine("I20260207 16:43:09.118649 1624963 model.cc:455] Registered images: 3", isError: true))
        XCTAssertTrue(runner.test_shouldEmitToolLogLine("W20260207 16:43:09.118649 1624963 model.cc:455] Numerical issue encountered", isError: true))
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

    private func makeRunner(projectURL: URL) -> PipelineRunner {
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
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: projectURL, config: config)
    }
}
