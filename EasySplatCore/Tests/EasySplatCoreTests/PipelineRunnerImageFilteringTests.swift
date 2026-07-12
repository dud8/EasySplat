#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers

final class PipelineRunnerImageFilteringTests: XCTestCase {
    func testLoadImagesFiltersNonImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appendingPathComponent("frame_000001.jpg")
        try writeImage(url: imageURL, size: 16, value: 90)
        let junkURL = dir.appendingPathComponent(".DS_Store")
        try "junk".write(to: junkURL, atomically: true, encoding: .utf8)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let images = try runner.loadImagesForTesting(in: dir)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.lastPathComponent, "frame_000001.jpg")
    }

    func testLoadPhotosFiltersDirectories() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appendingPathComponent("photo.jpg")
        try writeImage(url: imageURL, size: 16, value: 42)
        let bundleDir = dir.appendingPathComponent("album.jpg", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.lastPathComponent, "photo.jpg")
    }

    func testLoadPhotosIncludesNestedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rootPhoto = dir.appendingPathComponent("root.jpg")
        try writeImage(url: rootPhoto, size: 16, value: 40)

        let nestedDir = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedPhoto = nestedDir.appendingPathComponent("inner.jpg")
        try writeImage(url: nestedPhoto, size: 16, value: 200)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(Set(photos.map(\.lastPathComponent)), Set(["root.jpg", "inner.jpg"]))
    }

    func testLoadPhotosIncludesHeifForTranscode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let heifURL = dir.appendingPathComponent("photo.heif")
        try Data("heif".utf8).write(to: heifURL)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.map(\.lastPathComponent), ["photo.heif"])
    }

    func testImportInputsKeepsDuplicateVideoBasenamesSeparate() throws {
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceRoot) }

        let firstDir = sourceRoot.appendingPathComponent("a", isDirectory: true)
        let secondDir = sourceRoot.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let firstVideo = firstDir.appendingPathComponent("clip.mov")
        let secondVideo = secondDir.appendingPathComponent("clip.mov")
        try Data("first".utf8).write(to: firstVideo)
        try Data("second".utf8).write(to: secondVideo)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)
        let metadata = ProjectMetadata(
            title: "Videos",
            input: .video(files: [firstVideo.path, secondVideo.path]),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )

        try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }

        let imported = try FileManager.default.contentsOfDirectory(at: paths.originalsURL, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(imported.map(\.lastPathComponent), ["clip-2.mov", "clip.mov"])
        XCTAssertEqual(try String(contentsOf: paths.originalsURL.appendingPathComponent("clip.mov"), encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: paths.originalsURL.appendingPathComponent("clip-2.mov"), encoding: .utf8), "second")
    }

    func testLoadPhotosSkipsGeneratedProjectDirectoriesAtProjectRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let rootPhoto = dir.appendingPathComponent("root.jpg")
        try writeImage(url: rootPhoto, size: 16, value: 25)

        let nestedDir = dir.appendingPathComponent("nested/input", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedPhoto = nestedDir.appendingPathComponent("inner.jpg")
        try writeImage(url: nestedPhoto, size: 16, value: 35)

        let generatedFramesDir = dir.appendingPathComponent("Frames/selected", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedFramesDir, withIntermediateDirectories: true)
        try writeImage(url: generatedFramesDir.appendingPathComponent("frame_000001.jpg"), size: 16, value: 45)

        let generatedSfMDir = dir.appendingPathComponent("SfM/colmap/sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedSfMDir, withIntermediateDirectories: true)
        try writeImage(url: generatedSfMDir.appendingPathComponent("model.jpg"), size: 16, value: 55)

        let generatedTrainingDir = dir.appendingPathComponent("Training", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedTrainingDir, withIntermediateDirectories: true)
        try writeImage(url: generatedTrainingDir.appendingPathComponent("checkpoint.jpg"), size: 16, value: 65)

        let generatedOutputDir = dir.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedOutputDir, withIntermediateDirectories: true)
        try writeImage(url: generatedOutputDir.appendingPathComponent("preview.jpg"), size: 16, value: 75)

        let generatedLogsDir = dir.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedLogsDir, withIntermediateDirectories: true)
        try writeImage(url: generatedLogsDir.appendingPathComponent("snapshot.jpg"), size: 16, value: 85)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(Set(photos.map(\.lastPathComponent)), Set(["root.jpg", "inner.jpg"]))
    }

    func testImportInputsReplacesZeroByteImportedVideo() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let source = root.appendingPathComponent("clip.mov")
        try Data("fresh-video".utf8).write(to: source)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        TestFileBuilder.createFile(at: paths.originalsURL.appendingPathComponent("clip.mov"))
        let runner = try makeRunner(projectURL: projectURL)
        let metadata = ProjectMetadata(
            title: "Video",
            input: .video(files: [source.path]),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )

        try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }

        let imported = paths.originalsURL.appendingPathComponent("clip.mov")
        XCTAssertEqual(try String(contentsOf: imported, encoding: .utf8), "fresh-video")
    }

    func testImportInputsReplacesPartialPhotoFolderWhenSourceStillExists() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writeImage(url: source.appendingPathComponent("one.jpg"), size: 16, value: 10)
        try writeImage(url: source.appendingPathComponent("two.jpg"), size: 16, value: 20)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let imported = paths.originalsURL.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        try writeImage(url: imported.appendingPathComponent("one.jpg"), size: 16, value: 10)
        let runner = try makeRunner(projectURL: projectURL)
        let metadata = ProjectMetadata(
            title: "Photos",
            input: .photos(folder: source.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )

        try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }

        XCTAssertEqual(try runner.loadPhotosForTesting(in: imported).count, 2)
    }

    func testImportInputsCopiesOnlyValidUniquePhotosWithStableCollisionNames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let first = source.appendingPathComponent("capture.jpg")
        let sameBasename = nested.appendingPathComponent("capture.jpg")
        let duplicate = source.appendingPathComponent("duplicate.jpg")
        try writeImage(url: first, size: 16, value: 20)
        try writeImage(url: sameBasename, size: 16, value: 180)
        try FileManager.default.copyItem(at: first, to: duplicate)
        try Data("not an image".utf8).write(to: source.appendingPathComponent("corrupt.png"))
        try Data("client notes".utf8).write(to: source.appendingPathComponent("notes.txt"))

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let runner = try makeRunner(projectURL: projectURL)
        let metadata = ProjectMetadata(
            title: "Photos",
            input: .photos(folder: source.path),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )

        try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }

        let imported = paths.originalsURL.appendingPathComponent("Photos", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: imported,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(contents.map(\.lastPathComponent), ["capture-2.jpg", "capture.jpg"])
        XCTAssertFalse(contents.contains { $0.lastPathComponent == "notes.txt" })
        XCTAssertFalse(contents.contains { $0.lastPathComponent == "corrupt.png" })
        XCTAssertFalse(contents.contains { $0.lastPathComponent == "duplicate.jpg" })
    }

    func testCancelledAtomicVideoCopyLeavesExistingDestinationUntouched() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        let destination = root.appendingPathComponent("destination.mov")
        try Data(repeating: 7, count: 2 * 1_024 * 1_024).write(to: source)
        try Data("existing".utf8).write(to: destination)
        let runner = try makeRunner(projectURL: root)

        let task = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            try runner.copyFileAtomically(from: source, to: destination)
        }

        do {
            try await task.value
            XCTFail("A cancelled import copy must stop.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAtomicInputCopyRejectsSymlinkSource() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let realSource = root.appendingPathComponent("real.mov")
        let linkedSource = root.appendingPathComponent("linked.mov")
        let destination = root.appendingPathComponent("destination.mov")
        try Data("video".utf8).write(to: realSource)
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: realSource)
        let runner = try makeRunner(projectURL: root)

        XCTAssertThrowsError(try runner.copyFileAtomically(from: linkedSource, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFrameBudgetAppliesToPhotoOnlyInputs() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let frames = (0..<140).map { root.appendingPathComponent(String(format: "photo_%03d.jpg", $0)) }
        let groups = [
            PipelineRunner.SelectedFrameGroup(id: "photos", frames: frames, isVideo: false)
        ]

        let budgeted = try runner.test_applyFrameBudget(to: groups, targetCount: 120)

        XCTAssertEqual(budgeted.reduce(0) { $0 + $1.frames.count }, 120)
        XCTAssertEqual(budgeted.first?.id, "photos")
    }

    func testFrameBudgetAppliesAcrossMixedInputs() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let videoFrames = (0..<80).map { root.appendingPathComponent(String(format: "video_%03d.jpg", $0)) }
        let photos = (0..<80).map { root.appendingPathComponent(String(format: "photo_%03d.jpg", $0)) }
        let groups = [
            PipelineRunner.SelectedFrameGroup(id: "video_000", frames: videoFrames, isVideo: true),
            PipelineRunner.SelectedFrameGroup(id: "photos", frames: photos, isVideo: false),
        ]

        let budgeted = try runner.test_applyFrameBudget(to: groups, targetCount: 120)

        XCTAssertEqual(budgeted.reduce(0) { $0 + $1.frames.count }, 120)
        XCTAssertTrue(budgeted.contains { $0.id == "video_000" })
        XCTAssertTrue(budgeted.contains { $0.id == "photos" })
    }

    func testUseAllValidPhotosRejectsCorruptDuplicatesAndUnsafeCounts() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let first = root.appendingPathComponent("first.jpg")
        let duplicate = root.appendingPathComponent("duplicate.jpg")
        let second = root.appendingPathComponent("second.jpg")
        let corrupt = root.appendingPathComponent("corrupt.jpg")
        try writeImage(url: first, size: 16, value: 40)
        try FileManager.default.copyItem(at: first, to: duplicate)
        try writeImage(url: second, size: 16, value: 180)
        try Data("not an image".utf8).write(to: corrupt)

        let filtered = try runner.test_filterValidUniquePhotos([first, duplicate, second, corrupt])

        XCTAssertEqual(filtered.frames.map(\.lastPathComponent), ["first.jpg", "second.jpg"])
        XCTAssertEqual(filtered.unreadableCount, 1)
        XCTAssertEqual(filtered.duplicateCount, 1)

        let repeatedValidPhotos = (0..<140).map { index in
            root.appendingPathComponent(String(format: "valid_%03d.jpg", index))
        }
        let groups = [
            PipelineRunner.SelectedFrameGroup(id: "photos", frames: repeatedValidPhotos, isVideo: false)
        ]
        XCTAssertThrowsError(
            try runner.test_applyFrameBudget(
                to: groups,
                targetCount: 120,
                photoSelection: .useAllValidPhotos
            )
        ) { error in
            guard case let .photoSelectionExceedsBudget(selected, maximum)? = error as? PipelineRunner.PipelineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(selected, 140)
            XCTAssertEqual(maximum, 120)
        }
    }

    func testUseAllValidPhotosPreservesPhotosAndFitsVideosIntoRemainingBudget() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let videos = (0..<80).map { root.appendingPathComponent("video_\($0).jpg") }
        let photos = (0..<80).map { root.appendingPathComponent("photo_\($0).jpg") }

        let selected = try runner.test_applyFrameBudget(
            to: [
                .init(id: "video_000", frames: videos, isVideo: true),
                .init(id: "photos", frames: photos, isVideo: false),
            ],
            targetCount: 120,
            photoSelection: .useAllValidPhotos
        )

        XCTAssertEqual(selected.first(where: { !$0.isVideo })?.frames.count, 80)
        XCTAssertEqual(selected.first(where: { $0.isVideo })?.frames.count, 40)
        XCTAssertEqual(selected.reduce(0) { $0 + $1.frames.count }, 120)
    }

    func testUseAllValidPhotosCannotConsumeTheEntireMixedInputBudget() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let videos = (0..<80).map { root.appendingPathComponent("video_\($0).jpg") }
        let photos = (0..<120).map { root.appendingPathComponent("photo_\($0).jpg") }

        XCTAssertThrowsError(try runner.test_applyFrameBudget(
            to: [
                .init(id: "video_000", frames: videos, isVideo: true),
                .init(id: "photos", frames: photos, isVideo: false),
            ],
            targetCount: 120,
            photoSelection: .useAllValidPhotos
        )) { error in
            guard case let .photoSelectionExceedsBudget(selected, maximum)? =
                    error as? PipelineRunner.PipelineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(selected, 120)
            XCTAssertEqual(maximum, 90)
        }
    }

    private func writeImage(url: URL, size: Int, value: UInt8) throws {
        let width = size
        let height = size
        let bytesPerRow = width
        var pixels = [UInt8](repeating: value, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let data = Data(bytes: &pixels, count: pixels.count)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            XCTFail("Failed to create image")
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Failed to create destination")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeRunner(projectURL: URL) throws -> PipelineRunner {
        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        return PipelineRunner(projectURL: projectURL, config: config)
    }
}
#endif
