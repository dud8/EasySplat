#if canImport(XCTest)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class AppModelDatasetSelectionTests: XCTestCase {
    private let standardHardwareProfile = HardwareProfile(
        memoryGB: 48,
        cpuCount: 16,
        gpuWorkingSetGB: 36
    )

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelDatasetSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeModel(
        toolchainManager: ToolchainManaging = MockToolchainManager(),
        datasetInputPreflight: DatasetInputPreflightOperation = .live
    ) -> AppModel {
        AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: base.appendingPathComponent("projects", isDirectory: true),
            hardwareProfile: standardHardwareProfile,
            datasetInputPreflight: datasetInputPreflight
        ) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
    }

    private func makeColmapDataset(named name: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let model = root.appendingPathComponent("sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: model.appendingPathComponent("cameras.bin"))
        try Data("i".utf8).write(to: model.appendingPathComponent("images.bin"))
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: images.appendingPathComponent("frame001.jpg"))
        return root
    }

    private func makeNerfstudioDataset(named name: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("transforms.json"))
        return root
    }

    private func makeRunnableNerfstudioDataset(at root: URL) throws -> URL {
        let framePaths = (1...3).map { "images/frame_\($0).jpg" }
        for (index, path) in framePaths.enumerated() {
            try writeGrayscaleJPEG(
                at: root.appendingPathComponent(path),
                value: UInt8(48 + index * 72)
            )
        }
        let identity: [[Double]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ]
        let transforms: [String: Any] = [
            "camera_model": "PINHOLE",
            "fl_x": 100.0,
            "fl_y": 100.0,
            "cx": 32.0,
            "cy": 32.0,
            "w": 64,
            "h": 64,
            "frames": framePaths.map {
                ["file_path": $0, "transform_matrix": identity]
            },
        ]
        try JSONSerialization.data(withJSONObject: transforms).write(
            to: root.appendingPathComponent(DatasetContract.nerfstudioManifestName)
        )
        return root
    }

    private func writeGrayscaleJPEG(at url: URL, value: UInt8) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: value, count: width * height)
        let data = Data(bytes: &pixels, count: pixels.count)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func runPendingSelection(_ model: AppModel) async throws {
        model.startFromPendingSelection()
        let task = try XCTUnwrap(model.currentTask)
        await task.value
    }

    private func makePhoto(named name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data("jpeg".utf8).write(to: url)
        return url
    }

    private func makeNerfstudioZip(named name: String) throws -> URL {
        let payload = base.appendingPathComponent("\(name)-payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: payload.appendingPathComponent("transforms.json"))
        let archive = base.appendingPathComponent("\(name).zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = payload
        zip.arguments = ["-q", "-X", archive.path, "transforms.json"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return archive
    }

    private func folderMetadata(
        regularFile: Bool? = false,
        directory: Bool? = false,
        symbolicLink: Bool? = false,
        hidden: Bool? = false,
        package: Bool? = false,
        name: String? = nil
    ) -> InputFolderResourceMetadata {
        InputFolderResourceMetadata(
            isRegularFile: regularFile,
            isDirectory: directory,
            isSymbolicLink: symbolicLink,
            isHidden: hidden,
            isPackage: package,
            name: name
        )
    }

    private func folderTraversal(
        root: URL,
        events: [InputFolderTraversalEvent]
    ) -> InputFolderTraversal {
        InputFolderTraversal(
            rootMetadata: folderMetadata(directory: true, name: root.lastPathComponent),
            events: AnySequence(events)
        )
    }

    private func countedFolderTraversal(root: URL, entryCount: Int) -> InputFolderTraversal {
        let events = AnySequence<InputFolderTraversalEvent> {
            var index = 0
            return AnyIterator<InputFolderTraversalEvent> {
                guard index < entryCount else { return nil }
                defer { index += 1 }
                let isAcceptedVideo = index == 0
                let name = isAcceptedVideo ? "capture.mp4" : "entry-\(index)"
                return .entry(
                    url: root.appendingPathComponent(name),
                    level: 1,
                    metadata: self.folderMetadata(
                        regularFile: isAcceptedVideo,
                        name: name
                    ),
                    skipDescendants: {}
                )
            }
        }
        return InputFolderTraversal(
            rootMetadata: folderMetadata(directory: true, name: root.lastPathComponent),
            events: events
        )
    }

    // MARK: - Exclusivity

    func testDatasetDropClearsPendingMediaWithWarning() throws {
        let model = makeModel()
        let photo = try makePhoto(named: "a.jpg")
        model.addInputs(urls: [photo])
        XCTAssertEqual(model.pendingPhotoURLs, [photo])

        let dataset = try makeColmapDataset(named: "scene")
        model.addInputs(urls: [dataset])

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertEqual(model.pendingDataset?.kind, .colmap)
        XCTAssertEqual(model.pendingDataset?.sourceURL, dataset)
        XCTAssertEqual(model.pendingDataset?.isZip, false)
        XCTAssertNil(model.pendingDataset?.imageCount)
        XCTAssertEqual(
            model.selectionWarning,
            "Added the COLMAP project. The photos and videos you selected were removed."
        )
    }

    func testDatasetDropWithoutPendingMediaHasNoWarning() throws {
        let model = makeModel()
        let dataset = try makeColmapDataset(named: "scene")
        model.addInputs(urls: [dataset])

        XCTAssertEqual(model.pendingDataset?.kind, .colmap)
        XCTAssertNil(model.selectionWarning)
    }

    func testAppendingPOSIXSymlinkNamedZipDoesNotSniffItsDatasetTarget() throws {
        let model = makeModel()
        let archive = try makeNerfstudioZip(named: "dataset")
        let symlink = base.appendingPathComponent("linked-dataset.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: archive)

        model.selectInputs(urls: [symlink], mode: .append)

        XCTAssertNil(model.pendingDataset)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
    }

    func testReplacingWithPOSIXSymlinkNamedZipPreservesExistingSelection() throws {
        let model = makeModel()
        let oldVideo = base.appendingPathComponent("old.mp4")
        try Data("old".utf8).write(to: oldVideo)
        model.addInputs(urls: [oldVideo])
        let archive = try makeNerfstudioZip(named: "dataset")
        let symlink = base.appendingPathComponent("linked-dataset.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: archive)

        model.selectInputs(urls: [symlink], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
        XCTAssertNil(model.pendingDataset)
    }

    func testWrappedDatasetPreservesSelectedParentAndResolvedChild() throws {
        let model = makeModel()
        let selectedParent = base.appendingPathComponent("Selected Export", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedParent, withIntermediateDirectories: true)
        let dataset = try makeColmapDataset(named: "Selected Export/scene")

        model.addInputs(urls: [selectedParent])

        XCTAssertEqual(model.pendingDataset?.selectedURL, selectedParent)
        XCTAssertEqual(model.pendingDataset?.resolvedRoot, dataset)
        XCTAssertEqual(model.pendingDataset?.sourceURL, selectedParent)
        XCTAssertEqual(model.pendingDataset?.kind, .colmap)
        XCTAssertEqual(model.pendingDataset?.isZip, false)
        XCTAssertNil(model.pendingDataset?.imageCount)
    }

    func testStartRunUsesSelectedParentForWrappedDataset() async throws {
        let recorder = DatasetPreflightSourceRecorder()
        let model = makeModel(
            datasetInputPreflight: DatasetInputPreflightOperation(recorder.run)
        )
        let selectedParent = base.appendingPathComponent("Selected Export", isDirectory: true)
        let dataset = selectedParent.appendingPathComponent("scene", isDirectory: true)
        _ = try makeRunnableNerfstudioDataset(at: dataset)
        model.addInputs(urls: [selectedParent])

        try await runPendingSelection(model)

        XCTAssertEqual(
            recorder.calls,
            [DatasetPreflightSourceRecorder.Call(
                source: .directory(selectedURL: selectedParent, resolvedRoot: dataset),
                kind: .nerfstudio
            )]
        )
        XCTAssertEqual(model.lastError, "Dataset couldn’t be imported")
    }

    func testStartRunDoesNotInferZipFromDirectoryName() async throws {
        let recorder = DatasetPreflightSourceRecorder()
        let model = makeModel(
            datasetInputPreflight: DatasetInputPreflightOperation(recorder.run)
        )
        let dataset = base.appendingPathComponent("scene.zip", isDirectory: true)
        _ = try makeRunnableNerfstudioDataset(at: dataset)
        model.addInputs(urls: [dataset])
        XCTAssertEqual(model.pendingDataset?.isZip, false)

        try await runPendingSelection(model)

        XCTAssertEqual(
            recorder.calls,
            [DatasetPreflightSourceRecorder.Call(
                source: .directory(selectedURL: dataset, resolvedRoot: dataset),
                kind: .nerfstudio
            )]
        )
        XCTAssertEqual(model.lastError, "Dataset couldn’t be imported")
    }

    func testStartRunRejectsSelectedParentReplacedBySymlink() async throws {
        let toolchain = CapabilityRecordingToolchainManager()
        let model = makeModel(toolchainManager: toolchain)
        let selectedParent = base.appendingPathComponent("Selected Export", isDirectory: true)
        let selectedDataset = selectedParent.appendingPathComponent("scene", isDirectory: true)
        _ = try makeRunnableNerfstudioDataset(at: selectedDataset)
        model.addInputs(urls: [selectedParent])
        XCTAssertEqual(model.pendingDataset?.selectedURL, selectedParent)

        let detachedSelection = base.appendingPathComponent("Detached Selection", isDirectory: true)
        try FileManager.default.moveItem(at: selectedParent, to: detachedSelection)
        let replacementParent = base.appendingPathComponent("External Replacement", isDirectory: true)
        _ = try makeRunnableNerfstudioDataset(
            at: replacementParent.appendingPathComponent("scene", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(
            at: selectedParent,
            withDestinationURL: replacementParent
        )

        try await runPendingSelection(model)

        XCTAssertEqual(model.lastError, "Dataset couldn’t be imported")
        XCTAssertEqual(
            model.errorDetails,
            DatasetInputError.unsafeLayout.localizedDescription
        )
        XCTAssertNil(model.currentProjectURL)
        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(toolchain.requestCount, 0)
    }

    func testTrainOnlyNerfstudioFolderFallsThroughToOrdinaryMedia() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("train-only", isDirectory: true)
        let photo = folder.appendingPathComponent("images/frame.jpg")
        try FileManager.default.createDirectory(
            at: photo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: folder.appendingPathComponent("transforms_train.json"))
        try Data("jpeg".utf8).write(to: photo)

        model.addInputs(urls: [folder])

        XCTAssertNil(model.pendingDataset)
        XCTAssertEqual(
            model.pendingPhotoURLs.map { $0.resolvingSymlinksInPath() },
            [photo.resolvingSymlinksInPath()]
        )
    }

    func testMediaDroppedWhileDatasetPendingIsIgnoredWithWarning() throws {
        let model = makeModel()
        let dataset = try makeColmapDataset(named: "scene")
        model.addInputs(urls: [dataset])
        XCTAssertNotNil(model.pendingDataset)

        let photo = try makePhoto(named: "b.jpg")
        model.addInputs(urls: [photo])

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertEqual(model.pendingDataset?.sourceURL, dataset)
        XCTAssertEqual(
            model.selectionWarning,
            "A dataset is selected. Remove it to add photos or videos."
        )
    }

    func testSecondDatasetDropKeepsTheFirstWithWarning() throws {
        let model = makeModel()
        let first = try makeColmapDataset(named: "scene")
        model.addInputs(urls: [first])

        let second = try makeNerfstudioDataset(named: "zother")
        model.addInputs(urls: [second])

        XCTAssertEqual(model.pendingDataset?.sourceURL, first)
        XCTAssertEqual(model.pendingDataset?.kind, .colmap)
        XCTAssertEqual(
            model.selectionWarning,
            "Selected more than one dataset. EasySplat uses one at a time — kept COLMAP project."
        )
    }

    func testTwoDatasetsInOneDropKeepTheFirstByPathOrder() throws {
        let model = makeModel()
        let alpha = try makeColmapDataset(named: "alpha")
        let beta = try makeNerfstudioDataset(named: "beta")

        // Drop order must not matter: the path-sorted winner is deterministic.
        model.addInputs(urls: [beta, alpha])

        XCTAssertEqual(model.pendingDataset?.sourceURL, alpha)
        XCTAssertEqual(model.pendingDataset?.kind, .colmap)
        XCTAssertEqual(
            model.selectionWarning,
            "Selected more than one dataset. EasySplat uses one at a time — kept COLMAP project."
        )
    }

    func testMediaInTheSameDropAsADatasetIsConsumedSilently() throws {
        let model = makeModel()
        let dataset = try makeColmapDataset(named: "scene")
        let photo = try makePhoto(named: "c.jpg")

        model.addInputs(urls: [photo, dataset])

        XCTAssertEqual(model.pendingDataset?.sourceURL, dataset)
        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        // No media was pending before the drop, so there is nothing to warn about.
        XCTAssertNil(model.selectionWarning)
    }

    func testClearPendingInputsClearsDataset() throws {
        let model = makeModel()
        let dataset = try makeColmapDataset(named: "scene")
        model.addInputs(urls: [dataset])
        XCTAssertNotNil(model.pendingDataset)

        model.clearPendingInputs()

        XCTAssertNil(model.pendingDataset)
        XCTAssertNil(model.selectionWarning)
    }

    // MARK: - Spec and title

    func testBuildInputSpecReturnsDataset() throws {
        let model = makeModel()
        let dataset = try makeColmapDataset(named: "scene")
        model.addInputs(urls: [dataset])

        let spec = model.buildInputSpec()
        XCTAssertEqual(spec?.isDataset, true)
        XCTAssertEqual(spec?.datasetKind, .colmap)
        XCTAssertEqual(spec?.photosFolder, dataset.path)
        XCTAssertEqual(spec?.videoFiles, [])
    }

    func testProjectTitleUsesDatasetFolderBasename() throws {
        let model = makeModel()
        let dataset = try makeColmapDataset(named: "Kitchen Scan")
        model.addInputs(urls: [dataset])
        guard let spec = model.buildInputSpec() else {
            XCTFail("Expected a dataset input spec")
            return
        }
        XCTAssertEqual(model.projectTitle(for: spec), "Kitchen Scan")
    }

    func testProjectTitleStripsZipExtension() {
        let model = makeModel()
        let spec = InputSpec.dataset(
            kind: .polycam,
            imagesFolder: "/tmp/exports/Backyard Export.zip"
        )
        XCTAssertEqual(model.projectTitle(for: spec), "Backyard Export")
    }

    // MARK: - UI predicates

    func testOptionsVisibilityForDatasets() {
        let dataset = HomeView.visibleOptionSections(forDataset: true)
        XCTAssertTrue(dataset.detail)
        XCTAssertTrue(dataset.resourceUse)
        XCTAssertFalse(dataset.capturePath)
        XCTAssertFalse(dataset.cameraGrouping)
        XCTAssertFalse(dataset.lensProjection)
        XCTAssertFalse(dataset.inputOrdering)

        let media = HomeView.visibleOptionSections(forDataset: false)
        XCTAssertTrue(media.capturePath)
        XCTAssertTrue(media.detail)
        XCTAssertTrue(media.cameraGrouping)
        XCTAssertTrue(media.lensProjection)
        XCTAssertTrue(media.inputOrdering)
        XCTAssertTrue(media.resourceUse)
    }

    func testReconstructPhraseIsDatasetAware() {
        XCTAssertEqual(ProcessingPhase.reconstruct.phrase(isDataset: true), "Importing camera poses")
        XCTAssertEqual(ProcessingPhase.reconstruct.phrase(isDataset: false), "Reconstructing scene")
        XCTAssertEqual(ProcessingPhase.train.phrase(isDataset: true), "Training splat")
        XCTAssertEqual(ProcessingPhase.prepare.phrase(isDataset: true), "Preparing input")
    }

    func testCreateButtonAcceptsDatasetAsInput() {
        XCTAssertFalse(HomeView.hasSelectableInput(hasMedia: false, hasDataset: false))
        XCTAssertTrue(HomeView.hasSelectableInput(hasMedia: true, hasDataset: false))
        XCTAssertTrue(HomeView.hasSelectableInput(hasMedia: false, hasDataset: true))
    }

    /// A partial-looking capture is allowed only when the folder itself was
    /// completely enumerable. Files that cannot be used still deserve a terse
    /// count, but they do not invalidate readable media beside them.
    func testFolderExpansionReportsDroppedItemsAfterAddingMedia() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: folder.appendingPathComponent("a.jpg"))
        try Data("mp4".utf8).write(to: folder.appendingPathComponent("b.mp4"))
        try Data("ply".utf8).write(to: folder.appendingPathComponent("scene.ply"))
        try Data("t".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("metadata.bin"))

        model.addInputs(urls: [folder])

        XCTAssertEqual(model.pendingPhotoURLs.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(model.pendingVideoURLs.map(\.lastPathComponent), ["b.mp4"])
        XCTAssertEqual(
            model.selectionWarning,
            "Skipped 3 files EasySplat can't use as capture input."
        )
    }

    func testFolderExpansionUsesSingularDroppedItemFeedback() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: folder.appendingPathComponent("a.jpg"))
        try Data("mp4".utf8).write(to: folder.appendingPathComponent("b.mp4"))
        try Data("text".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        model.addInputs(urls: [folder])

        XCTAssertEqual(
            model.selectionWarning,
            "Skipped 1 file EasySplat can't use as capture input."
        )
    }

    func testSkippedFilesAreAggregatedAcrossFoldersAndExplicitFiles() throws {
        let model = makeModel()
        let first = base.appendingPathComponent("First", isDirectory: true)
        let second = base.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: first.appendingPathComponent("a.mp4"))
        try Data("text".utf8).write(to: first.appendingPathComponent("a.txt"))
        try Data("video".utf8).write(to: second.appendingPathComponent("b.mp4"))
        try Data("data".utf8).write(to: second.appendingPathComponent("b.bin"))
        let explicit = base.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: explicit)

        model.addInputs(urls: [first, explicit, second])

        XCTAssertEqual(model.pendingVideoURLs.map(\.lastPathComponent), ["a.mp4", "b.mp4"])
        XCTAssertEqual(
            model.selectionWarning,
            "Skipped 3 files EasySplat can't use as capture input."
        )
    }

    func testPartialDropReportsProviderFailureWithoutRelabelingFolderContents() throws {
        let model = makeModel()
        let video = base.appendingPathComponent("clip.mp4")
        try Data("video".utf8).write(to: video)

        model.addDroppedInputs(DropURLLoadBatch(urls: [video], failedProviderCount: 1))

        XCTAssertEqual(model.pendingVideoURLs, [video])
        XCTAssertEqual(
            model.selectionWarning,
            "Added what EasySplat could read. 1 dropped item couldn’t be opened."
        )
    }

    func testAllFailedDropReportsExactProviderFailureFeedback() {
        let model = makeModel()

        model.addDroppedInputs(DropURLLoadBatch(urls: [], failedProviderCount: 3))

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read 3 dropped items. Try choosing them instead."
        )
    }

    func testFolderWithNoSupportedMediaUsesExactEmptyFeedback() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("ply".utf8).write(to: folder.appendingPathComponent("scene.ply"))

        model.addInputs(urls: [folder])

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "“Capture” contains no photos or videos EasySplat can use."
        )
    }

    func testFolderMediaAreSortedByRelativePath() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("a", isDirectory: true)
        let second = folder.appendingPathComponent("z", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: first.appendingPathComponent("second.jpg"))
        try Data("a".utf8).write(to: second.appendingPathComponent("first.jpg"))

        model.addInputs(urls: [folder])

        XCTAssertEqual(
            model.pendingPhotoURLs.map(\.lastPathComponent),
            ["second.jpg", "first.jpg"]
        )
    }

    func testProjectOutputDirectoriesAreNotImportedAsCaptureMedia() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        let output = folder.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("project".utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("input".utf8).write(to: folder.appendingPathComponent("input.jpg"))
        try Data("generated".utf8).write(to: output.appendingPathComponent("generated.jpg"))

        model.addInputs(urls: [folder])

        XCTAssertEqual(model.pendingPhotoURLs.map(\.lastPathComponent), ["input.jpg"])
    }

    func testTraversalFailureRejectsTheFolderWithoutKeepingItsUsablePrefix() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("early".utf8).write(to: folder.appendingPathComponent("early.jpg"))
        var nested = folder
        for level in 0..<65 {
            nested = nested.appendingPathComponent("level-\(level)", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        }
        try Data("late".utf8).write(to: nested.appendingPathComponent("late.jpg"))

        model.addInputs(urls: [folder])

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "“Capture” is too large or deeply nested to add safely. Choose a smaller folder."
        )
    }

    func testFolderAtDepth64IsAccepted() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var nested = folder
        // NSDirectoryEnumerator counts a direct child as level 1, so 63
        // directories plus this file exercise the permitted level 64.
        for level in 0..<63 {
            nested = nested.appendingPathComponent("level-\(level)", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        }
        let photo = nested.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: photo)

        model.addInputs(urls: [folder])

        XCTAssertEqual(model.pendingPhotoURLs.map(\.lastPathComponent), [photo.lastPathComponent])
    }

    func testMetadataFailureAfterValidPhotoRejectsTheEntireFolderPrefix() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("frame.jpg")
        let unreadable = folder.appendingPathComponent("unknown.dat")
        let traversal = folderTraversal(
            root: folder,
            events: [
                .entry(
                    url: photo,
                    level: 1,
                    metadata: folderMetadata(regularFile: true, name: "frame.jpg"),
                    skipDescendants: {}
                ),
                .entry(
                    url: unreadable,
                    level: 1,
                    metadata: folderMetadata(hidden: nil, name: "unknown.dat"),
                    skipDescendants: {}
                ),
            ]
        )

        model.selectInputs(
            urls: [folder],
            mode: .append,
            folderTraversalProvider: { _ in traversal }
        )

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read all of “Capture”, so nothing from that folder was added. Check its permissions and try again."
        )
    }

    func testTraversalEntryOutsideSelectedRootRejectsTheWholeFolder() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        let outside = base.appendingPathComponent("Capture-escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsidePhoto = outside.appendingPathComponent("frame.jpg")
        try Data("outside".utf8).write(to: outsidePhoto)
        let traversal = folderTraversal(
            root: folder,
            events: [
                .entry(
                    url: outsidePhoto,
                    level: 1,
                    metadata: folderMetadata(regularFile: true, name: "frame.jpg"),
                    skipDescendants: {}
                ),
            ]
        )

        model.selectInputs(
            urls: [folder],
            mode: .append,
            folderTraversalProvider: { _ in traversal }
        )

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read all of “Capture”, so nothing from that folder was added. Check its permissions and try again."
        )
    }

    func testAcceptedMediaDisappearingAfterTraversalRejectsTheWholeFolder() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("frame.jpg")
        try Data("photo".utf8).write(to: photo)
        let traversal = folderTraversal(
            root: folder,
            events: [
                .entry(
                    url: photo,
                    level: 1,
                    metadata: folderMetadata(regularFile: true, name: "frame.jpg"),
                    skipDescendants: {}
                ),
            ]
        )
        try FileManager.default.removeItem(at: photo)

        model.selectInputs(
            urls: [folder],
            mode: .append,
            folderTraversalProvider: { _ in traversal }
        )

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read all of “Capture”, so nothing from that folder was added. Check its permissions and try again."
        )
    }

    func testEveryRequiredEntryMetadataFlagMustBeKnown() throws {
        let incompleteMetadata = [
            folderMetadata(regularFile: nil),
            folderMetadata(directory: nil),
            folderMetadata(symbolicLink: nil),
            folderMetadata(hidden: nil),
            folderMetadata(package: nil),
        ]

        for (index, metadata) in incompleteMetadata.enumerated() {
            let model = makeModel()
            let folder = base.appendingPathComponent("Capture-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let traversal = folderTraversal(
                root: folder,
                events: [
                    .entry(
                        url: folder.appendingPathComponent("entry.dat"),
                        level: 1,
                        metadata: metadata,
                        skipDescendants: {}
                    ),
                ]
            )

            model.selectInputs(
                urls: [folder],
                mode: .append,
                folderTraversalProvider: { _ in traversal }
            )

            XCTAssertTrue(model.pendingPhotoURLs.isEmpty, "metadata case \(index)")
            XCTAssertTrue(model.pendingVideoURLs.isEmpty, "metadata case \(index)")
            XCTAssertEqual(
                model.selectionWarning,
                "Couldn’t read all of “Capture-\(index)”, so nothing from that folder was added. Check its permissions and try again.",
                "metadata case \(index)"
            )
        }
    }

    func testIndeterminateRootSymlinkMetadataRejectsFolder() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let traversal = InputFolderTraversal(
            rootMetadata: folderMetadata(
                directory: true,
                symbolicLink: nil,
                name: folder.lastPathComponent
            ),
            events: AnySequence([])
        )

        model.selectInputs(
            urls: [folder],
            mode: .append,
            folderTraversalProvider: { _ in traversal }
        )

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read all of “Capture”, so nothing from that folder was added. Check its permissions and try again."
        )
    }

    func testHealthyFolderSurvivesIndependentFolderMetadataFailure() throws {
        let model = makeModel()
        let healthy = base.appendingPathComponent("Healthy", isDirectory: true)
        let failed = base.appendingPathComponent("Failed", isDirectory: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        for index in 0..<AppModel.minimumRecommendedPhotos {
            try Data("photo-\(index)".utf8).write(
                to: healthy.appendingPathComponent("photo-\(index).jpg")
            )
        }
        let healthyEvents = (0..<AppModel.minimumRecommendedPhotos).map { index in
            let name = "photo-\(index).jpg"
            return InputFolderTraversalEvent.entry(
                url: healthy.appendingPathComponent(name),
                level: 1,
                metadata: folderMetadata(regularFile: true, name: name),
                skipDescendants: {}
            )
        }
        let healthyTraversal = folderTraversal(root: healthy, events: healthyEvents)
        let failedTraversal = folderTraversal(
            root: failed,
            events: [
                .entry(
                    url: failed.appendingPathComponent("early.jpg"),
                    level: 1,
                    metadata: folderMetadata(regularFile: true, name: "early.jpg"),
                    skipDescendants: {}
                ),
                .entry(
                    url: failed.appendingPathComponent("unknown.dat"),
                    level: 1,
                    metadata: nil,
                    skipDescendants: {}
                ),
            ]
        )

        model.selectInputs(
            urls: [healthy, failed],
            mode: .append,
            folderTraversalProvider: { root in
                root.lastPathComponent == healthy.lastPathComponent
                    ? healthyTraversal
                    : failedTraversal
            }
        )

        XCTAssertEqual(model.pendingPhotoURLs.count, AppModel.minimumRecommendedPhotos)
        XCTAssertTrue(model.pendingPhotoURLs.allSatisfy { $0.path.contains("/Healthy/") })
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read all of “Failed”, so nothing from that folder was added. Check its permissions and try again."
        )
    }

    func testHealthyFileSurvivesIndependentFolderMetadataFailure() throws {
        let model = makeModel()
        let video = base.appendingPathComponent("healthy.mp4")
        try Data("video".utf8).write(to: video)
        let failed = base.appendingPathComponent("Failed", isDirectory: true)
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        let failedTraversal = folderTraversal(
            root: failed,
            events: [
                .entry(
                    url: failed.appendingPathComponent("unknown.dat"),
                    level: 1,
                    metadata: folderMetadata(symbolicLink: nil, name: "unknown.dat"),
                    skipDescendants: {}
                ),
            ]
        )

        model.selectInputs(
            urls: [video, failed],
            mode: .append,
            folderTraversalProvider: { _ in failedTraversal }
        )

        XCTAssertEqual(model.pendingVideoURLs, [video])
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read all of “Failed”, so nothing from that folder was added. Check its permissions and try again."
        )
    }

    func testFolderTraversalAcceptsExactlyFiftyThousandVisitedEntries() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: folder.appendingPathComponent("capture.mp4"))
        let traversal = countedFolderTraversal(root: folder, entryCount: 50_000)

        model.selectInputs(
            urls: [folder],
            mode: .append,
            folderTraversalProvider: { _ in traversal }
        )

        XCTAssertEqual(model.pendingVideoURLs.map(\.lastPathComponent), ["capture.mp4"])
        XCTAssertNil(model.selectionWarning)
    }

    func testReleaseReliabilityFolderAdmissionTraversesTenThousandRealFiles() throws {
        let fixture = try ReleaseReliabilityFixtureSupport.load(
            workload: "folder-admission-10000"
        )
        XCTAssertEqual(fixture.manifest.entryCount, 10_000)
        let model = makeModel()
        let folder = fixture.fixtureRoot.appendingPathComponent("folder", isDirectory: true)

        let clock = ContinuousClock()
        let started = clock.now
        model.addInputs(urls: [folder])
        let elapsed = started.duration(to: clock.now)

        XCTAssertNil(model.pendingDataset)
        XCTAssertNil(model.selectionWarning)
        XCTAssertEqual(model.pendingPhotoURLs.count, 10_000)
        XCTAssertEqual(model.pendingPhotoURLs.first?.lastPathComponent, "frame-00000.jpg")
        XCTAssertEqual(model.pendingPhotoURLs.last?.lastPathComponent, "frame-09999.jpg")
        try fixture.recordSuccess(elapsed: elapsed)
    }

    func testFolderTraversalRejectsFiftyThousandAndOneVisitedEntries() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: folder.appendingPathComponent("capture.mp4"))
        let traversal = countedFolderTraversal(root: folder, entryCount: 50_001)

        model.selectInputs(
            urls: [folder],
            mode: .append,
            folderTraversalProvider: { _ in traversal }
        )

        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "“Capture” is too large or deeply nested to add safely. Choose a smaller folder."
        )
    }

    func testSelectedPOSIXSymlinkFolderIsNotFollowed() throws {
        let model = makeModel()
        let target = base.appendingPathComponent("Capture", isDirectory: true)
        let alias = base.appendingPathComponent("Capture Link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: target.appendingPathComponent("frame.jpg"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        model.addInputs(urls: [alias])

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
    }

    func testUnreadableFolderDoesNotAddAUsablePrefix() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)

        model.addInputs(urls: [folder])

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Couldn’t read all of “Capture”, so nothing from that folder was added. Check its permissions and try again."
        )
    }

    func testReplacingWithAnEmptySelectionPreservesTheExistingCapture() throws {
        let model = makeModel()
        let oldVideo = base.appendingPathComponent("old.mp4")
        try Data("old".utf8).write(to: oldVideo)
        model.addInputs(urls: [oldVideo])

        model.selectInputs(urls: [], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
    }

    func testReplacingWithUnsupportedInputPreservesTheExistingCapture() throws {
        let model = makeModel()
        let oldVideo = base.appendingPathComponent("old.mp4")
        let unsupported = base.appendingPathComponent("notes.txt")
        try Data("old".utf8).write(to: oldVideo)
        try Data("text".utf8).write(to: unsupported)
        model.addInputs(urls: [oldVideo])

        model.selectInputs(urls: [unsupported], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
    }

    func testReplacingWithMissingVideoPreservesTheExistingCapture() throws {
        let model = makeModel()
        let oldVideo = base.appendingPathComponent("old.mp4")
        let missingVideo = base.appendingPathComponent("missing.mp4")
        try Data("old".utf8).write(to: oldVideo)
        model.addInputs(urls: [oldVideo])

        model.selectInputs(urls: [missingVideo], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
        XCTAssertEqual(
            model.selectionWarning,
            "Ignored 1 file. Add photos, a video, or a folder of them."
        )
    }

    func testAppendingAndReplacingMediaUseTheirRequestedMode() throws {
        let model = makeModel()
        let first = base.appendingPathComponent("first.mp4")
        let second = base.appendingPathComponent("second.mp4")
        let replacement = base.appendingPathComponent("replacement.mp4")
        for url in [first, second, replacement] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        model.selectInputs(urls: [first], mode: .append)
        model.selectInputs(urls: [second], mode: .append)
        XCTAssertEqual(model.pendingVideoURLs, [first, second])

        model.selectInputs(urls: [replacement], mode: .replace)
        XCTAssertEqual(model.pendingVideoURLs, [replacement])
    }

    func testImportCancellationAndFailurePreserveExistingInput() throws {
        let model = makeModel()
        let oldVideo = base.appendingPathComponent("old.mp4")
        try Data("old".utf8).write(to: oldVideo)
        model.addInputs(urls: [oldVideo])

        model.handleInputImporterResult(
            .failure(CocoaError(.userCancelled)),
            mode: .replace,
            failureMessage: "Couldn’t choose input"
        )
        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
        XCTAssertNil(model.selectionWarning)

        model.handleInputImporterResult(
            .failure(CocoaError(.fileReadNoPermission)),
            mode: .replace,
            failureMessage: "Couldn’t choose input"
        )
        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
        XCTAssertEqual(model.selectionWarning, "Couldn’t choose input")
    }

    func testWrappedDatasetUsesItsDetectedRootWhenReplacingMedia() throws {
        let model = makeModel()
        let oldVideo = base.appendingPathComponent("old.mp4")
        try Data("old".utf8).write(to: oldVideo)
        model.addInputs(urls: [oldVideo])

        let wrapper = base.appendingPathComponent("Capture", isDirectory: true)
        let dataset = wrapper.appendingPathComponent("Scene", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dataset.appendingPathComponent("transforms.json"))

        model.selectInputs(urls: [wrapper], mode: .replace)

        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertEqual(model.buildInputSpec()?.photosFolder, dataset.path)
    }

    func testIgnoredFilesWarningNamesNoParticularDatasetFormat() throws {
        let model = makeModel()
        let unsupported = base.appendingPathComponent("notes.txt")
        try Data("t".utf8).write(to: unsupported)
        model.addInputs(urls: [unsupported])
        XCTAssertEqual(
            model.selectionWarning,
            "Ignored 1 file. Add photos, a video, or a folder of them."
        )
    }

    // Dropping a finished splat on the input zone is a reasonable thing to expect to
    // work, so it opens rather than being refused.
    func testDroppedSplatIsRoutedToTheViewerInsteadOfBeingIgnored() throws {
        let model = makeModel()
        let splat = base.appendingPathComponent("scene.ply")
        try Data("ply".utf8).write(to: splat)

        model.addInputs(urls: [splat])

        XCTAssertEqual(model.splatOpenRequests, [splat])
        XCTAssertNil(model.selectionWarning)
        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
    }

    // A splat alongside capture input should not cost the capture input.
    func testDroppedSplatOpensWithoutDiscardingPhotosInTheSameDrop() throws {
        let model = makeModel()
        let splat = base.appendingPathComponent("scene.ply")
        let photo = base.appendingPathComponent("frame.jpg")
        try Data("ply".utf8).write(to: splat)
        try Data("jpg".utf8).write(to: photo)

        model.addInputs(urls: [splat, photo])

        XCTAssertEqual(model.splatOpenRequests, [splat])
        XCTAssertEqual(model.pendingPhotoURLs, [photo])
    }

    func testRepeatedDroppedSplatQueuesOneViewerRequest() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let splat = base.appendingPathComponent("scene.ply")
        let equivalentPath = folder.appendingPathComponent("../scene.ply")
        try Data("ply".utf8).write(to: splat)

        model.addInputs(urls: [splat, splat, equivalentPath])

        XCTAssertEqual(model.splatOpenRequests, [splat])
    }

    // A container the reader cannot open still has to say so specifically.
    func testUnreadableSplatContainerSaysWhichFormatOpens() throws {
        let model = makeModel()
        let splat = base.appendingPathComponent("scene.spz")
        try Data("spz".utf8).write(to: splat)

        model.addInputs(urls: [splat])

        XCTAssertTrue(model.splatOpenRequests.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Ignored 1 splat. EasySplat opens .ply splats."
        )
    }

    func testPlainPhotoFolderStillFlowsThroughMediaSelection() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("holiday", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.jpg"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.jpg"))

        model.addInputs(urls: [folder])

        XCTAssertNil(model.pendingDataset)
        XCTAssertEqual(model.pendingPhotoURLs.count, 2)
    }
}

private final class DatasetPreflightSourceRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let source: DatasetInputSource
        let kind: DatasetKind
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func run(
        source: DatasetInputSource,
        kind: DatasetKind,
        stagingParent: URL
    ) async throws -> PreparedDatasetInput {
        _ = stagingParent
        record(Call(source: source, kind: kind))
        throw DatasetInputError.noImages
    }

    private func record(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}
#endif
