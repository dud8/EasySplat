import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class PipelineRunnerHelperTests: XCTestCase {
    func testAutomaticCameraSharingRequiresOneVideoClip() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        XCTAssertTrue(runner.test_da3SharedCameraPreference(
            input: .video(files: ["/tmp/a.mov"]),
            cameraGrouping: .automatic
        ))
        XCTAssertFalse(runner.test_da3SharedCameraPreference(
            input: .video(files: ["/tmp/a.mov", "/tmp/b.mov"]),
            cameraGrouping: .automatic
        ))
        XCTAssertTrue(runner.test_da3SharedCameraPreference(
            input: .video(files: ["/tmp/a.mov", "/tmp/b.mov"]),
            cameraGrouping: .sameCameraAndLens
        ))
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

    func testPrepareDa3RefinementSeedBuildsFreshTextOnlyModelWithoutChangingRawSeed() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawModel = root.appendingPathComponent("raw/0", isDirectory: true)
        try FileManager.default.createDirectory(at: rawModel, withIntermediateDirectories: true)
        let rawFiles: [String: Data] = [
            "cameras.txt": Data("1 PINHOLE 100 80 50 50 50 40\n".utf8),
            "images.txt": Data("1 1 0 0 0 0 0 0 1 café frame.jpg".utf8),
            "points3D.txt": Data("1 0 0 1 255 255 255 0 1 0\n".utf8),
            "learned_points3D.txt": Data("1 0 0 1 255 255 255 -1\n".utf8),
        ]
        for (name, data) in rawFiles {
            try data.write(to: rawModel.appendingPathComponent(name))
        }
        let outputModel = root.appendingPathComponent("refinement/0", isDirectory: true)
        try FileManager.default.createDirectory(at: outputModel, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: outputModel.appendingPathComponent("cameras.bin"))
        try Data("stale".utf8).write(to: outputModel.appendingPathComponent("notes.json"))
        let databaseURL = root.appendingPathComponent("database.db")
        try writeImageMappingDatabase(
            at: databaseURL,
            rows: [(1, "café frame.jpg", 1)]
        )

        let changed = try makeRunner(projectURL: root).prepareDa3RefinementSeed(
            rawModelURL: rawModel,
            outputModelURL: outputModel,
            databaseURL: databaseURL
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outputModel.path).sorted(),
            ["cameras.txt", "images.txt", "points3D.txt"]
        )
        for (name, data) in rawFiles {
            XCTAssertEqual(try Data(contentsOf: rawModel.appendingPathComponent(name)), data)
        }
    }

    func testPrepareDa3RefinementSeedFailureRemovesPartialAndStaleOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawModel = root.appendingPathComponent("raw/0", isDirectory: true)
        try FileManager.default.createDirectory(at: rawModel, withIntermediateDirectories: true)
        try Data("1 PINHOLE 100 80 50 50 50 40\n".utf8)
            .write(to: rawModel.appendingPathComponent("cameras.txt"))
        try Data("1 1 0 0 0 0 0 0 1 frame.jpg\n\n".utf8)
            .write(to: rawModel.appendingPathComponent("images.txt"))
        let points = (1...10_000).map { "\($0) 0 0 1 255 255 255 0 1 0" }
            .joined(separator: "\n") + "\n10001 malformed\n"
        try Data(points.utf8).write(to: rawModel.appendingPathComponent("points3D.txt"))
        let outputParent = root.appendingPathComponent("refinement", isDirectory: true)
        let outputModel = outputParent.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: outputModel, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: outputModel.appendingPathComponent("cameras.bin"))
        let databaseURL = root.appendingPathComponent("database.db")
        try writeImageMappingDatabase(at: databaseURL, rows: [(10, "frame.jpg", 20)])

        XCTAssertThrowsError(
            try makeRunner(projectURL: root).prepareDa3RefinementSeed(
                rawModelURL: rawModel,
                outputModelURL: outputModel,
                databaseURL: databaseURL
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputParent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawModel.path))
    }

    func testPrepareDa3RefinementSeedCancellationInterruptsEveryTextFileCopy() throws {
        for targetName in ["cameras.txt", "images.txt", "points3D.txt"] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let rawModel = root.appendingPathComponent("raw/0", isDirectory: true)
            try FileManager.default.createDirectory(at: rawModel, withIntermediateDirectories: true)
            try Data("1 PINHOLE 100 80 50 50 50 40\n".utf8)
                .write(to: rawModel.appendingPathComponent("cameras.txt"))
            try Data("1 1 0 0 0 0 0 0 1 frame.jpg\n\n".utf8)
                .write(to: rawModel.appendingPathComponent("images.txt"))
            try Data("1 0 0 1 255 255 255 0 1 0\n".utf8)
                .write(to: rawModel.appendingPathComponent("points3D.txt"))
            let outputParent = root.appendingPathComponent("refinement", isDirectory: true)
            let outputModel = outputParent.appendingPathComponent("0", isDirectory: true)
            let databaseURL = root.appendingPathComponent("database.db")
            try writeImageMappingDatabase(at: databaseURL, rows: [(10, "frame.jpg", 20)])
            var reachedTarget = false

            XCTAssertThrowsError(
                try makeRunner(projectURL: root).prepareDa3RefinementSeed(
                    rawModelURL: rawModel,
                    outputModelURL: outputModel,
                    databaseURL: databaseURL,
                    checkCancellation: {
                        guard FileManager.default.fileExists(
                            atPath: outputModel.appendingPathComponent(targetName).path
                        ) else { return }
                        reachedTarget = true
                        throw CancellationError()
                    }
                )
            ) { error in
                XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
            }

            XCTAssertTrue(reachedTarget, "Cancellation never reached \(targetName)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputParent.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: rawModel.path))
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
                isVideo: true
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

    func testLoadSelectedFrameManifestRejectsSymlinkedFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appendingPathComponent("outside-selected-frames.json")
        let manifestURL = root.appendingPathComponent("selected_frames.json")
        let manifest = [TestSelectedFrameMapping(
            outputFileName: "frame_000000.jpg",
            groupId: "video_000",
            isVideo: true
        )]
        try JSONEncoder().encode(manifest).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: outsideURL)
        let runner = makeRunner(projectURL: root)

        XCTAssertThrowsError(try runner.loadSelectedFrameManifest(from: manifestURL))
    }

    func testLoadSelectedFrameManifestRejectsFileLargerThanFourMiB() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("selected_frames.json")
        let manifest = [TestSelectedFrameMapping(
            outputFileName: "frame_000000.jpg",
            groupId: String(repeating: "x", count: 4 * 1_024 * 1_024),
            isVideo: true
        )]
        let data = try JSONEncoder().encode(manifest)
        XCTAssertGreaterThan(data.count, 4 * 1_024 * 1_024)
        try data.write(to: manifestURL)
        let runner = makeRunner(projectURL: root)

        XCTAssertThrowsError(try runner.loadSelectedFrameManifest(from: manifestURL))
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
            isVideo: false
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

    func testCopySelectedCarriesVideoTimestampIntoManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("frame_000007_t000012345678.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: source, size: 16, value: 10, utType: .jpeg))
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("selected_frames.json")
        let runner = makeRunner(projectURL: root)

        let manifest = try runner.test_copySelected(
            groups: [.init(id: "video_000", frames: [source], isVideo: true)],
            to: selected,
            manifestURL: manifestURL
        )

        XCTAssertEqual(manifest.first?.timestampSeconds ?? -1, 12.345678, accuracy: 0.000001)
    }

    func testCopySelectedNormalizesSafeLowLightWithoutChangingOriginal() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("low-light.png")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: source, size: 32, value: 40, utType: .png))
        let sourceData = try Data(contentsOf: source)
        let sourceScore = try FrameScoring.scoreFrame(at: source)
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("selected_frames.json")
        let runner = makeRunner(projectURL: root)

        let manifest = try runner.test_copySelected(
            groups: [.init(id: "photos", frames: [source], isVideo: false)],
            to: selected,
            manifestURL: manifestURL
        )

        let copied = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: selected, includingPropertiesForKeys: nil).first
        )
        let copiedScore = try FrameScoring.scoreFrame(at: copied)
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertGreaterThan(copiedScore.brightness, sourceScore.brightness)
        XCTAssertEqual(
            manifest.first?.lowLightExposureEV ?? 0,
            sourceScore.lowLightExposureEV,
            accuracy: 0.01
        )
    }

    func testCopySelectedBoundsLargePhotoToResolvedDimension() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source,
            size: 256,
            value: 128,
            utType: .jpeg
        ))
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let runner = makeRunner(projectURL: root)

        _ = try runner.test_copySelected(
            groups: [.init(id: "photos", frames: [source], isVideo: false)],
            to: selected,
            manifestURL: root.appendingPathComponent("selected_frames.json"),
            maxDimension: 64
        )

        let copied = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: selected, includingPropertiesForKeys: nil).first
        )
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(copied as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertLessThanOrEqual(
            max(
                (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? .max,
                (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? .max
            ),
            64
        )
    }

    func testCopySelectedBakesJPEGOrientationIntoPixels() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("oriented.jpg")
        try writeOrientedJPEG(to: source, width: 8, height: 12, orientation: 6)
        XCTAssertEqual(try FrameScoring.scoreFrame(at: source).lowLightExposureEV, 0)

        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let runner = makeRunner(projectURL: root)
        _ = try runner.test_copySelected(
            groups: [.init(id: "photos", frames: [source], isVideo: false)],
            to: selected,
            manifestURL: root.appendingPathComponent("selected_frames.json"),
            maxDimension: 128
        )

        let output = selected.appendingPathComponent("frame_000000.jpg")
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let outputProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(
            (outputProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            12
        )
        XCTAssertEqual(
            (outputProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            8
        )
        XCTAssertEqual(
            (outputProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
            1
        )

        let outputImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        let sideMeans = grayscaleSideMeans(outputImage)
        XCTAssertGreaterThan(sideMeans.left, sideMeans.right + 0.25)
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
            isVideo: false
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

    private func writeOrientedJPEG(
        to url: URL,
        width: Int,
        height: Int,
        orientation: Int
    ) throws {
        var pixels = (0..<height).flatMap { row -> [UInt8] in
            let value: UInt8
            switch row {
            case ..<(height / 3): value = 64
            case (height / 3)..<(2 * height / 3): value = 160
            default: value = 240
            }
            return [UInt8](repeating: value, count: width)
        }
        let data = Data(bytes: &pixels, count: pixels.count)
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: data as CFData)),
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: 1.0,
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func grayscaleSideMeans(_ image: CGImage) -> (left: Double, right: Double) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let columnCount = max(1, width / 3)
        var left = 0
        var right = 0
        for row in 0..<height {
            let offset = row * width
            left += pixels[offset..<(offset + columnCount)].reduce(0) { $0 + Int($1) }
            right += pixels[(offset + width - columnCount)..<(offset + width)].reduce(0) {
                $0 + Int($1)
            }
        }
        let sampleCount = Double(columnCount * height * 255)
        return (Double(left) / sampleCount, Double(right) / sampleCount)
    }

    func testMapperDefaultsToIntegratedGlobalMapperWithGpuEnabled() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let options = runner.test_globalMapperOptions(threadHint: 8)
        XCTAssertTrue(options.useGpuForGlobalPositioning)
        XCTAssertTrue(options.useGpuForBundleAdjustment)
    }

    func testGlobalMapperDefaultUseGpuFalseDisablesGpuWithoutOverrides() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner(projectURL: root)

        let options = runner.test_globalMapperOptions(threadHint: 8, defaultUseGpu: false)
        XCTAssertFalse(options.useGpuForGlobalPositioning)
        XCTAssertFalse(options.useGpuForBundleAdjustment)
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

    func testResetPerRunToolLogsRemovesDanglingSymlink() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let outside = parent.appendingPathComponent("missing-da3.log")
        try FileManager.default.createSymbolicLink(
            at: paths.da3LogURL,
            withDestinationURL: outside
        )

        PipelineRunner.resetPerRunToolLogs(at: paths)

        XCTAssertThrowsError(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: paths.da3LogURL.path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
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

    func testRegenerateBinarySparseModelReadsOnlyAuthenticatedText() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model", isDirectory: true)
        try writeSparseTextModel(at: model, cameraModel: "PINHOLE")
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data("stale".utf8).write(to: model.appendingPathComponent(name))
        }
        let subprocess = MockSubprocessRunner(scripts: [modelConverterScript { args in
            let input = URL(fileURLWithPath: try XCTUnwrap(self.argumentValue("--input_path", args)))
            XCTAssertNotEqual(input.standardizedFileURL, model.standardizedFileURL)
            for name in ["cameras.txt", "images.txt", "points3D.txt"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: input.appendingPathComponent(name).path))
            }
            for name in ["cameras.bin", "images.bin", "points3D.bin"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: input.appendingPathComponent(name).path))
            }
            try self.writeBinaryModel(to: args)
        }])
        let runner = makeRunner(projectURL: root, subprocess: subprocess)

        XCTAssertTrue(try runner.regenerateBinarySparseModelFiles(at: model))
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            XCTAssertEqual(try Data(contentsOf: model.appendingPathComponent(name)), Data([1, 2, 3]))
        }
    }

    func testPrepareMsplatDatasetAddsLearnedDepthInitializer() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: paths.framesSelectedURL.appendingPathComponent("frame.jpg"),
            size: 8,
            value: 128,
            utType: .jpeg
        ))
        let sourceSparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try writeSparseTextModel(at: sourceSparse, cameraModel: "PINHOLE")
        let sourceModelBytes = try sparseTextModelBytes(at: sourceSparse)
        try writeLearnedPoints(to: paths.colmapSeedModelURL, count: 2)
        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent("learned_points3D.txt")
        let initializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: try GeometryArtifactStore.sha256(of: learnedURL),
            pointCount: 2
        )
        let subprocess = MockSubprocessRunner(scripts: [
            modelConverterScript { try self.writeBinaryModel(to: $0) },
        ])
        let runner = makeRunner(projectURL: root, subprocess: subprocess)
        let previousSparse = paths.trainingURL.appendingPathComponent(
            "msplat_dataset/sparse/0",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: previousSparse, withIntermediateDirectories: true)
        try Data(#"{"stale":true}"#.utf8).write(
            to: previousSparse.appendingPathComponent("easysplat_orientation.json")
        )
        let halfTurn = CanonicalQuaternionWXYZ(w: 0, x: 1, y: 0, z: 0)
        let geometryArtifact = try trainingGeometryArtifact(
            sourceSparse: sourceSparse,
            learnedPointInitializer: initializer,
            canonicalOrientation: testOrientation(
                status: .verified,
                quaternion: halfTurn
            )
        )

        var progressValues: [Double] = []
        let preparedDataset = try await runner.prepareMsplatDataset(
            paths: paths,
            maxImageSize: 1_024,
            geometryArtifact: geometryArtifact,
            progress: { value, _ in progressValues.append(value) }
        )
        let dataset = preparedDataset.url

        let points = try String(
            contentsOf: dataset.appendingPathComponent("sparse/0/points3D.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(points.contains("2 1.0 0.0 2.0 10 20 30 -1.0"))
        XCTAssertTrue(points.contains("3 2.0 0.0 2.0 10 20 30 -1.0"))
        XCTAssertEqual(subprocess.calls.map { $0.1.first }, ["model_converter"])
        XCTAssertEqual(
            try orientationQuaternion(in: dataset),
            [halfTurn.w, halfTurn.x, halfTurn.y, halfTurn.z]
        )
        XCTAssertEqual(preparedDataset.identity.inputDigest.count, 64)
        XCTAssertEqual(preparedDataset.identity.geometryDigest.count, 64)
        XCTAssertEqual(progressValues.last, 1)
        XCTAssertEqual(progressValues, progressValues.sorted())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourceSparse.appendingPathComponent("cameras.bin").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourceSparse.appendingPathComponent("learned_points3D.txt").path
            )
        )
        XCTAssertEqual(try sparseTextModelBytes(at: sourceSparse), sourceModelBytes)
    }

    func testPrepareMsplatDatasetUndistortsFisheyeBeforeTraining() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let selectedImage = paths.framesSelectedURL.appendingPathComponent("frame.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: selectedImage,
            size: 8,
            value: 128,
            utType: .jpeg
        ))
        let sourceSparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try writeSparseTextModel(at: sourceSparse, cameraModel: "OPENCV_FISHEYE")
        let sourceModelBytes = try sparseTextModelBytes(at: sourceSparse)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data("stale \(name)".utf8).write(to: sourceSparse.appendingPathComponent(name))
        }
        try writeLearnedPoints(to: paths.colmapSeedModelURL, count: 1)
        let learnedURL = paths.colmapSeedModelURL.appendingPathComponent("learned_points3D.txt")
        let initializer = LearnedPointInitializerArtifact(
            path: "SfM/colmap/seed/0/learned_points3D.txt",
            sha256: try GeometryArtifactStore.sha256(of: learnedURL),
            pointCount: 1
        )

        let undistort = MockSubprocessRunner.Script(
            path: "/mock/colmap",
            argsPrefix: ["image_undistorter"],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
            onRun: { args in
                do {
                    let inputPath = try XCTUnwrap(self.argumentValue("--input_path", args))
                    let input = URL(fileURLWithPath: inputPath)
                    XCTAssertNotEqual(input.standardizedFileURL, sourceSparse.standardizedFileURL)
                    XCTAssertEqual(try self.sparseTextModelBytes(at: input), sourceModelBytes)
                    for name in ["cameras.bin", "images.bin", "points3D.bin"] {
                        XCTAssertEqual(
                            try Data(contentsOf: input.appendingPathComponent(name)),
                            Data([1, 2, 3])
                        )
                    }
                    let outputPath = try XCTUnwrap(self.argumentValue("--output_path", args))
                    let output = URL(fileURLWithPath: outputPath)
                    let images = output.appendingPathComponent("images", isDirectory: true)
                    let sparse = output.appendingPathComponent("sparse", isDirectory: true)
                    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: selectedImage, to: images.appendingPathComponent("frame.jpg"))
                    for name in ["cameras.bin", "images.bin", "points3D.bin"] {
                        try Data([1, 2, 3]).write(to: sparse.appendingPathComponent(name))
                    }
                } catch {
                    XCTFail("Fixture setup failed: \(error)")
                }
            }
        )
        let textConverter = modelConverterScript { args in
            let output = URL(fileURLWithPath: try XCTUnwrap(self.argumentValue("--output_path", args)))
            try self.writeSparseTextModel(at: output, cameraModel: "PINHOLE")
        }
        let subprocess = MockSubprocessRunner(scripts: [
            modelConverterScript { try self.writeBinaryModel(to: $0) },
            undistort,
            textConverter,
            modelConverterScript { try self.writeBinaryModel(to: $0) },
        ])
        let runner = makeRunner(projectURL: root, subprocess: subprocess)
        let geometryArtifact = try trainingGeometryArtifact(
            sourceSparse: sourceSparse,
            learnedPointInitializer: initializer,
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
            )
        )

        let preparedDataset = try await runner.prepareMsplatDataset(
            paths: paths,
            maxImageSize: 2_048,
            geometryArtifact: geometryArtifact,
            progress: { _, _ in }
        )
        let dataset = preparedDataset.url

        let cameras = try String(
            contentsOf: dataset.appendingPathComponent("sparse/0/cameras.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(cameras.contains(" PINHOLE "))
        XCTAssertEqual(
            subprocess.calls.map { $0.1.first },
            ["model_converter", "image_undistorter", "model_converter", "model_converter"]
        )
        XCTAssertEqual(try orientationQuaternion(in: dataset), [1, 0, 0, 0])
        XCTAssertEqual(preparedDataset.identity.inputDigest.count, 64)
        XCTAssertEqual(preparedDataset.identity.geometryDigest.count, 64)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourceSparse.appendingPathComponent("learned_points3D.txt").path
            )
        )
        XCTAssertEqual(try sparseTextModelBytes(at: sourceSparse), sourceModelBytes)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            XCTAssertEqual(
                try Data(contentsOf: sourceSparse.appendingPathComponent(name)),
                Data("stale \(name)".utf8)
            )
        }
    }

    func testPrepareMsplatDatasetRejectsSourceModelHashMismatchWithoutReplacingDataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: paths.framesSelectedURL.appendingPathComponent("frame.jpg"),
            size: 8,
            value: 128,
            utType: .jpeg
        ))
        let sourceSparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try writeSparseTextModel(at: sourceSparse, cameraModel: "PINHOLE")
        let geometryArtifact = try trainingGeometryArtifact(
            sourceSparse: sourceSparse,
            learnedPointInitializer: nil,
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
            )
        )
        try "changed\n".write(
            to: sourceSparse.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )

        let existingDataset = paths.trainingURL.appendingPathComponent(
            "msplat_dataset",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: existingDataset, withIntermediateDirectories: true)
        let marker = existingDataset.appendingPathComponent("keep.txt")
        try Data("existing".utf8).write(to: marker)
        let runner = makeRunner(projectURL: root)

        do {
            _ = try await runner.prepareMsplatDataset(
                paths: paths,
                maxImageSize: 1_024,
                geometryArtifact: geometryArtifact,
                progress: { _, _ in }
            )
            XCTFail("Expected geometry provenance validation to fail")
        } catch let error as GeometryArtifactStore.Error {
            XCTAssertEqual(error, .modelHashMismatch("cameras.txt"))
        }

        XCTAssertEqual(try Data(contentsOf: marker), Data("existing".utf8))
    }

    func testPrepareMsplatDatasetRejectsSourceMutationDuringConversionWithoutReplacingDataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: paths.framesSelectedURL.appendingPathComponent("frame.jpg"),
            size: 8,
            value: 128,
            utType: .jpeg
        ))
        let sourceSparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try writeSparseTextModel(at: sourceSparse, cameraModel: "PINHOLE")
        let geometryArtifact = try trainingGeometryArtifact(
            sourceSparse: sourceSparse,
            learnedPointInitializer: nil,
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
            )
        )

        let existingDataset = paths.trainingURL.appendingPathComponent(
            "msplat_dataset",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: existingDataset, withIntermediateDirectories: true)
        let marker = existingDataset.appendingPathComponent("keep.txt")
        try Data("existing".utf8).write(to: marker)
        let subprocess = MockSubprocessRunner(scripts: [
            modelConverterScript { arguments in
                try self.writeBinaryModel(to: arguments)
                try Data("changed during conversion".utf8).write(
                    to: sourceSparse.appendingPathComponent("cameras.txt")
                )
            },
        ])
        let runner = makeRunner(projectURL: root, subprocess: subprocess)

        do {
            _ = try await runner.prepareMsplatDataset(
                paths: paths,
                maxImageSize: 1_024,
                geometryArtifact: geometryArtifact,
                progress: { _, _ in }
            )
            XCTFail("Expected a changed source model to be rejected")
        } catch let error as GeometryModelSnapshot.Error {
            XCTAssertEqual(error, .modelChanged)
        }

        XCTAssertEqual(try Data(contentsOf: marker), Data("existing".utf8))
    }

    private func makeRunner(
        projectURL: URL,
        subprocess: SubprocessRunning? = nil
    ) -> PipelineRunner {
        let colmap = subprocess == nil ? nil : URL(fileURLWithPath: "/mock/colmap")
        let toolchain = TestToolchains.toolchainPaths(root: projectURL, colmap: colmap)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let tooling = subprocess.map(PipelineRunner.Tooling.init(runner:)) ?? PipelineRunner.Tooling()
        return PipelineRunner(projectURL: projectURL, config: config, tooling: tooling)
    }

    private func modelConverterScript(
        onRun: @escaping ([String]) throws -> Void
    ) -> MockSubprocessRunner.Script {
        .init(
            path: "/mock/colmap",
            argsPrefix: ["model_converter"],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
            onRun: { args in
                do { try onRun(args) } catch { XCTFail("Fixture setup failed: \(error)") }
            }
        )
    }

    private func argumentValue(_ flag: String, _ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func writeBinaryModel(to arguments: [String]) throws {
        let output = URL(fileURLWithPath: try XCTUnwrap(argumentValue("--output_path", arguments)))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data([1, 2, 3]).write(to: output.appendingPathComponent(name))
        }
    }

    private func writeSparseTextModel(at directory: URL, cameraModel: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let camera = cameraModel == "OPENCV_FISHEYE"
            ? "1 OPENCV_FISHEYE 8 8 4 4 4 4 0 0 0 0\n"
            : "1 PINHOLE 8 8 4 4 4 4\n"
        try camera.write(to: directory.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try "1 1 0 0 0 0 0 0 1 frame.jpg\n0 0 1\n".write(
            to: directory.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 1 128 128 128 0.1 1 0\n".write(
            to: directory.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func testOrientation(
        status: CanonicalOrientationStatus,
        quaternion: CanonicalQuaternionWXYZ?
    ) -> CanonicalOrientationArtifact {
        CanonicalOrientationArtifact(
            status: status,
            method: .cameraRightNullspace,
            sourceToCanonicalQuaternionWXYZ: quaternion,
            evidence: nil,
            canonicalOpeningViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
        )
    }

    private func trainingGeometryArtifact(
        sourceSparse: URL,
        learnedPointInitializer: LearnedPointInitializerArtifact?,
        canonicalOrientation: CanonicalOrientationArtifact
    ) throws -> GeometryArtifact {
        var artifact = makeGeometryArtifact()
        artifact.modelHashes = try GeometryModelSnapshot.capture(in: sourceSparse).modelHashes
        artifact.learnedPointInitializer = learnedPointInitializer
        artifact.canonicalOrientation = canonicalOrientation
        return artifact
    }

    private func orientationQuaternion(in dataset: URL) throws -> [Double] {
        let data = try Data(
            contentsOf: dataset.appendingPathComponent(
                "sparse/0/easysplat_orientation.json"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schema_version", "source_to_canonical_wxyz"])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        return try XCTUnwrap(object["source_to_canonical_wxyz"] as? [Double])
    }

    private func sparseTextModelBytes(at directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["cameras.txt", "images.txt", "points3D.txt"].map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
    }

    private func writeLearnedPoints(to directory: URL, count: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows = (1...count).map { "\($0) \(Double($0)) 0.0 2.0 10 20 30 -1.0" }
        try (rows.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("learned_points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeImageMappingDatabase(
        at url: URL,
        rows: [(imageID: Int, name: String, cameraID: Int)]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "PipelineRunnerHelperTests", code: 100)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE images (image_id INTEGER PRIMARY KEY, name TEXT UNIQUE, camera_id INTEGER NOT NULL);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "PipelineRunnerHelperTests", code: 101)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO images (image_id, name, camera_id) VALUES (?, ?, ?);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "PipelineRunnerHelperTests", code: 102)
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_int64(statement, 1, sqlite3_int64(row.imageID)) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, row.name, -1, transient) == SQLITE_OK,
                  sqlite3_bind_int64(statement, 3, sqlite3_int64(row.cameraID)) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "PipelineRunnerHelperTests", code: 103)
            }
        }
    }

}
