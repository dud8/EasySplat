#if canImport(XCTest)
import Foundation
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

    private func makeModel() -> AppModel {
        AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base.appendingPathComponent("projects", isDirectory: true),
            hardwareProfile: standardHardwareProfile
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

    private func makePhoto(named name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data("jpeg".utf8).write(to: url)
        return url
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

    /// Choosing a folder means taking what it holds. What it holds and cannot be
    /// used is worth saying, rather than leaving the reader to wonder why a count
    /// looks short.
    func testFolderExpansionReportsWhatItCouldNotUse() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: folder.appendingPathComponent("a.jpg"))
        try Data("mp4".utf8).write(to: folder.appendingPathComponent("b.mp4"))
        try Data("ply".utf8).write(to: folder.appendingPathComponent("scene.ply"))
        try Data("t".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        model.addInputs(urls: [folder])

        XCTAssertEqual(model.pendingPhotoURLs.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(model.pendingVideoURLs.map(\.lastPathComponent), ["b.mp4"])
        XCTAssertEqual(
            model.selectionWarning,
            "Skipped 2 files EasySplat can't use as capture input."
        )
    }

    func testFolderHoldingOnlySplatsSaysWhatEasySplatDoesWithThem() throws {
        let model = makeModel()
        let folder = base.appendingPathComponent("Results", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("ply".utf8).write(to: folder.appendingPathComponent("scene.ply"))

        model.addInputs(urls: [folder])

        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Ignored 1 splat. EasySplat opens .ply splats."
        )
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
#endif
