#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers

final class PipelineRunnerImageFilteringTests: XCTestCase {
    func testSharedCameraRequiresUniformSelectedImageDimensions() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let landscape = root.appendingPathComponent("landscape.jpg")
        let landscapeCopy = root.appendingPathComponent("landscape-copy.jpg")
        let portrait = root.appendingPathComponent("portrait.jpg")
        try writeImage(url: landscape, width: 30, height: 20, value: 90)
        try writeImage(url: landscapeCopy, width: 30, height: 20, value: 100)
        try writeImage(url: portrait, width: 20, height: 30, value: 110)
        let runner = try makeRunner(projectURL: root)

        XCTAssertTrue(
            try runner.test_selectedImagesHaveUniformPixelDimensions([landscape, landscapeCopy])
        )
        XCTAssertFalse(
            try runner.test_selectedImagesHaveUniformPixelDimensions([landscape, portrait])
        )
    }

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

    func testImportInputsUsesControlledVideosWithoutASecondCopy() throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let paths = ProjectPaths(root: projectURL)
        let (firstVideo, firstReceipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 0,
            bytes: Data("first".utf8),
            safeDisplayName: "clip.mov"
        )
        let (secondVideo, secondReceipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 1,
            bytes: Data("second".utf8),
            safeDisplayName: "clip.mov"
        )
        var firstBefore = stat()
        var secondBefore = stat()
        XCTAssertEqual(lstat(firstVideo.path, &firstBefore), 0)
        XCTAssertEqual(lstat(secondVideo.path, &secondBefore), 0)
        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)
        let metadata = ProjectMetadata(
            title: "Videos",
            input: .video(files: [
                firstReceipt.projectRelativePath,
                secondReceipt.projectRelativePath,
            ]),
            videoInputReceipts: [firstReceipt, secondReceipt],
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )

        try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }

        var firstAfter = stat()
        var secondAfter = stat()
        XCTAssertEqual(lstat(firstVideo.path, &firstAfter), 0)
        XCTAssertEqual(lstat(secondVideo.path, &secondAfter), 0)
        XCTAssertEqual(firstAfter.st_ino, firstBefore.st_ino)
        XCTAssertEqual(secondAfter.st_ino, secondBefore.st_ino)
        XCTAssertEqual(try Data(contentsOf: firstVideo), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: secondVideo), Data("second".utf8))
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

    func testReceiptValidationRejectsEmptyControlledVideoBeforeImport() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        let (video, receipt) = try TestFileBuilder.writeControlledVideoReceipt(paths: paths)
        try Data().write(to: video, options: [.atomic])
        let metadata = ProjectMetadata(
            title: "Video",
            input: .video(files: [receipt.projectRelativePath]),
            videoInputReceipts: [receipt],
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )

        XCTAssertThrowsError(try VideoInputReceiptValidator.validateFiles(
            metadata: metadata,
            paths: paths
        )) { error in
            XCTAssertEqual(error as? VideoInputReceiptValidationError, .sizeMismatch(index: 0))
        }
        XCTAssertEqual(try Data(contentsOf: video), Data())
    }

    func testImportInputsRejectsExternalPhotoPathWithoutRepairingPartialFolder() throws {
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

        XCTAssertThrowsError(try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }) {
            XCTAssertEqual($0 as? PhotoInputReceiptValidationError, .invalidPhotoRoot)
        }
        XCTAssertEqual(try runner.loadPhotosForTesting(in: imported).count, 1)
    }

    func testMixedImportAllowsAnAllInvalidPhotoFolderWhenVideoRemains() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: photos.appendingPathComponent("broken.jpg"))

        let paths = ProjectPaths(root: projectURL)
        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: Data("video".utf8),
            safeDisplayName: "walkthrough.mov"
        )
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let runner = try makeRunner(projectURL: projectURL)
        let metadata = ProjectMetadata(
            title: "Mixed",
            input: .mixed(
                videos: [receipt.projectRelativePath],
                photosFolder: "Originals/Photos"
            ),
            videoInputReceipts: [receipt],
            photoInputReceipts: [],
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )

        try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }

        XCTAssertEqual(try runner.loadPhotosForTesting(in: paths.importedPhotosURL), [])
        XCTAssertEqual(
            try runner.test_validateStageOutput(.importInput, paths: paths, metadata: metadata),
            .valid
        )
    }

    func testImportInputsUsesControlledPhotosWithoutASecondCopy() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.importedPhotosURL, withIntermediateDirectories: true)
        let first = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        let second = paths.importedPhotosURL.appendingPathComponent("photo-0001.jpg")
        try writeImage(url: first, size: 16, value: 20)
        try writeImage(url: second, size: 16, value: 180)
        XCTAssertEqual(chmod(first.path, 0o600), 0)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        let photos = [first, second]
        var before = [stat(), stat()]
        XCTAssertEqual(lstat(first.path, &before[0]), 0)
        XCTAssertEqual(lstat(second.path, &before[1]), 0)
        let receipts = try photos.enumerated().map { index, photo in
            let attributes = try FileManager.default.attributesOfItem(atPath: photo.path)
            let sha256 = try GeometryArtifactStore.sha256(of: photo)
            return PhotoInputReceipt(
                projectRelativePath: "Originals/Photos/\(photo.lastPathComponent)",
                safeDisplayName: "capture-\(index).jpg",
                byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
                sha256: sha256,
                pixelWidth: 16,
                pixelHeight: 16,
                orientation: 1,
                typeIdentifier: "public.jpeg",
                analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                    sourceSHA256: sha256,
                    seed: UInt8(truncatingIfNeeded: index)
                ),
                retainedRank: index
            )
        }
        let runner = try makeRunner(projectURL: projectURL)
        let metadata = try TestFileBuilder.bindContinuousPhotoSelectionFixture(
            to: ProjectMetadata(
            title: "Photos",
            input: .photos(folder: "Originals/Photos"),
            photoInputReceipts: receipts,
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
            ),
            paths: paths
        )

        try runner.importInputs(metadata: metadata, paths: paths) { _, _ in }

        var after = [stat(), stat()]
        XCTAssertEqual(lstat(first.path, &after[0]), 0)
        XCTAssertEqual(lstat(second.path, &after[1]), 0)
        XCTAssertEqual(after.map(\.st_ino), before.map(\.st_ino))
        XCTAssertEqual(
            try runner.loadPhotosForTesting(in: paths.importedPhotosURL).map(\.lastPathComponent),
            photos.map(\.lastPathComponent)
        )
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

    func testAtomicInputCopyUsesCopyOnWriteCloneOnAPFS() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var fileSystem = statfs()
        guard statfs(root.path, &fileSystem) == 0 else {
            throw XCTSkip("Could not inspect the test filesystem")
        }
        let fileSystemName = withUnsafePointer(to: &fileSystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        }
        guard fileSystemName == "apfs" else {
            throw XCTSkip("Copy-on-write cloning requires APFS")
        }

        let source = root.appendingPathComponent("source.mov")
        let destination = root.appendingPathComponent("destination.mov")
        let original = Data(repeating: 0x2A, count: 2 * 1_024 * 1_024)
        try original.write(to: source)
        let attributeName = "com.easysplat.clone-test"
        let attributeValue = Data("private-source-metadata".utf8)
        let setAttributeResult = attributeValue.withUnsafeBytes { bytes in
            source.path.withCString { path in
                attributeName.withCString { name in
                    setxattr(
                        path,
                        name,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        XATTR_NOFOLLOW
                    )
                }
            }
        }
        XCTAssertEqual(setAttributeResult, 0)
        XCTAssertEqual(chmod(source.path, S_IRUSR | S_IRGRP | S_IROTH), 0)
        let runner = try makeRunner(projectURL: root)

        let strategy = try runner.test_copyFileContents(
            from: source,
            to: destination
        )

        XCTAssertEqual(strategy, .copyOnWriteClone)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        var sourceMetadata = stat()
        var destinationMetadata = stat()
        XCTAssertEqual(lstat(source.path, &sourceMetadata), 0)
        XCTAssertEqual(lstat(destination.path, &destinationMetadata), 0)
        XCTAssertNotEqual(sourceMetadata.st_ino, destinationMetadata.st_ino)
        XCTAssertEqual(
            destinationMetadata.st_mode & mode_t(0o7777),
            mode_t(S_IRUSR | S_IWUSR)
        )
        let destinationAttributeSize = destination.path.withCString { path in
            attributeName.withCString { name in
                getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        XCTAssertEqual(destinationAttributeSize, -1)
        XCTAssertEqual(errno, ENOATTR)
        try Data(repeating: 0x51, count: original.count).write(to: destination)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testFilesystemCompressedAPFSInputUsesStreamedCopyWithoutCorruption() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var fileSystem = statfs()
        guard statfs(root.path, &fileSystem) == 0 else {
            throw XCTSkip("Could not inspect the test filesystem")
        }
        let fileSystemName = withUnsafePointer(to: &fileSystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        }
        guard fileSystemName == "apfs" else {
            throw XCTSkip("Filesystem compression requires APFS")
        }

        let plain = root.appendingPathComponent("plain.mov")
        let source = root.appendingPathComponent("compressed.mov")
        let destination = root.appendingPathComponent("destination.mov")
        let original = Data(repeating: 0x2A, count: 2 * 1_024 * 1_024)
        try original.write(to: plain)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--hfsCompression", plain.path, source.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationReason == .exit, ditto.terminationStatus == 0 else {
            throw XCTSkip("Could not create an APFS-compressed fixture")
        }
        var sourceMetadata = stat()
        guard lstat(source.path, &sourceMetadata) == 0,
              sourceMetadata.st_flags & UInt32(UF_COMPRESSED) != 0 else {
            throw XCTSkip("The test filesystem did not compress the fixture")
        }
        try FileManager.default.removeItem(at: plain)
        let runner = try makeRunner(projectURL: root)

        let strategy = try runner.test_copyFileContents(from: source, to: destination)

        XCTAssertEqual(strategy, .streamed)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        var destinationMetadata = stat()
        XCTAssertEqual(lstat(destination.path, &destinationMetadata), 0)
        XCTAssertEqual(destinationMetadata.st_size, sourceMetadata.st_size)
        XCTAssertEqual(destinationMetadata.st_flags & UInt32(UF_COMPRESSED), 0)
    }

    func testCloneFailureFallsBackOnlyForUnsupportedOrCrossVolumeCopies() {
        XCTAssertTrue(PipelineRunner.test_shouldFallBackFromCloneError(ENOTSUP))
        XCTAssertTrue(PipelineRunner.test_shouldFallBackFromCloneError(EXDEV))
        XCTAssertFalse(PipelineRunner.test_shouldFallBackFromCloneError(ENOSPC))
        XCTAssertFalse(PipelineRunner.test_shouldFallBackFromCloneError(EIO))
        XCTAssertFalse(PipelineRunner.test_shouldFallBackFromCloneError(EINVAL))
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

    func testRankedPhotoBudgetUsesExactPrefixInsteadOfEvenSpacing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let ranked = (0..<9).map {
            root.appendingPathComponent("rank-\($0).jpg")
        }

        let budgeted = try runner.test_applyFrameBudget(
            to: [.init(
                id: "photos",
                frames: ranked,
                isVideo: false,
                budgetProjection: .rankedPrefix
            )],
            targetCount: 3
        )

        XCTAssertEqual(budgeted.first?.frames, Array(ranked.prefix(3)))
        XCTAssertEqual(budgeted.first?.budgetProjection, .rankedPrefix)
    }

    func testContinuousPhotoBudgetKeepsEndpointRoundedSpacing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let ordered = (0..<9).map {
            root.appendingPathComponent("ordered-\($0).jpg")
        }

        let budgeted = try runner.test_applyFrameBudget(
            to: [.init(
                id: "photos",
                frames: ordered,
                isVideo: false,
                budgetProjection: .evenlySpaced
            )],
            targetCount: 3
        )

        XCTAssertEqual(
            budgeted.first?.frames,
            [ordered[0], ordered[4], ordered[8]]
        )
    }

    func testPreservedPhotoBudgetFailsClosedWhenAllocationShrinksIt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let photos = (0..<5).map {
            root.appendingPathComponent("photo-\($0).jpg")
        }

        XCTAssertThrowsError(try runner.test_applyFrameBudget(
            to: [.init(
                id: "photos",
                frames: photos,
                isVideo: false,
                budgetProjection: .preserve
            )],
            targetCount: 3
        )) { error in
            guard case let .photoSelectionExceedsBudget(selected, maximum)? =
                    error as? PipelineRunner.PipelineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(selected, 5)
            XCTAssertEqual(maximum, 3)
        }
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

    func testFrameBudgetPreservesEveryVideoClipAndItsEndpoints() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
        let shortVideo = (0..<3).map {
            root.appendingPathComponent("short_\($0).jpg")
        }
        let longVideo = (0..<100).map {
            root.appendingPathComponent("long_\($0).jpg")
        }
        let photos = (0..<100).map {
            root.appendingPathComponent("photo_\($0).jpg")
        }

        let budgeted = try runner.test_applyFrameBudget(
            to: [
                .init(id: "video_000", frames: shortVideo, isVideo: true),
                .init(id: "video_001", frames: longVideo, isVideo: true),
                .init(id: "photos", frames: photos, isVideo: false),
            ],
            targetCount: 50
        )

        XCTAssertEqual(budgeted.reduce(0) { $0 + $1.frames.count }, 50)
        for (id, source) in [("video_000", shortVideo), ("video_001", longVideo)] {
            let frames = try XCTUnwrap(budgeted.first { $0.id == id }?.frames)
            XCTAssertGreaterThanOrEqual(frames.count, 2)
            XCTAssertEqual(frames.first, source.first)
            XCTAssertEqual(frames.last, source.last)
        }
        XCTAssertNotNil(budgeted.first { $0.id == "photos" })
    }

    func testUseAllValidPhotosRejectsUnsafeCounts() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try makeRunner(projectURL: root)
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
        try writeImage(url: url, width: size, height: size, value: value)
    }

    private func writeImage(
        url: URL,
        width: Int,
        height: Int,
        value: UInt8
    ) throws {
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
