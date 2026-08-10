#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatApp

/// The sandbox refuses to read a user's photos once the grant that came with the
/// selection closes, and the pipeline opens those files long after the picker
/// closed. These cover the holder itself and the two points in selection that
/// have to keep the grant open.
@MainActor
final class SecurityScopedAccessTests: XCTestCase {
    private enum AccessEvent: Equatable {
        case start(URL)
        case stop(URL)
    }

    private final class Recorder {
        private(set) var started: [URL] = []
        private(set) var stopped: [URL] = []
        private(set) var events: [AccessEvent] = []
        var refuse: Set<URL> = []

        func start(_ url: URL) -> Bool {
            started.append(url)
            events.append(.start(url))
            return !refuse.contains(url)
        }

        func stop(_ url: URL) {
            stopped.append(url)
            events.append(.stop(url))
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecurityScopedAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The temporary directory reaches here through a symbolic link. Resolve it
        // once so every path below shares one prefix.
        return url.resolvingSymlinksInPath()
    }

    private func makeAccess(_ recorder: Recorder) -> SecurityScopedAccess {
        SecurityScopedAccess(
            start: { recorder.start($0) },
            stop: { recorder.stop($0) }
        )
    }

    private func makeNerfstudioZip(in base: URL) throws -> URL {
        let payload = base.appendingPathComponent("dataset-payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: payload.appendingPathComponent("transforms.json"))
        let archive = base.appendingPathComponent("dataset.zip")
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

    func testClaimOpensEveryFileURLAndReleaseBalancesIt() {
        let recorder = Recorder()
        let access = makeAccess(recorder)
        let first = URL(fileURLWithPath: "/tmp/one.jpg")
        let second = URL(fileURLWithPath: "/tmp/two.jpg")

        access.claim([first, second])
        XCTAssertEqual(recorder.started, [first, second])
        XCTAssertEqual(access.claimed, [first, second])

        access.releaseAll()
        XCTAssertEqual(recorder.stopped, [first, second])
        XCTAssertTrue(access.claimed.isEmpty)
    }

    /// Outside the sandbox nothing carries a scope, so nothing may be released.
    /// Balancing a claim that was never taken is an over-release.
    func testRefusedClaimIsNotReleased() {
        let recorder = Recorder()
        let unscoped = URL(fileURLWithPath: "/tmp/unscoped.jpg")
        recorder.refuse = [unscoped]
        let access = makeAccess(recorder)

        access.claim([unscoped])
        XCTAssertTrue(access.claimed.isEmpty)

        access.releaseAll()
        XCTAssertTrue(recorder.stopped.isEmpty)
    }

    func testNonFileURLIsIgnored() {
        let recorder = Recorder()
        let access = makeAccess(recorder)

        access.claim([URL(string: "https://example.com/photo.jpg")!])

        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertTrue(access.claimed.isEmpty)
    }

    func testReleaseIsIdempotent() {
        let recorder = Recorder()
        let access = makeAccess(recorder)
        let url = URL(fileURLWithPath: "/tmp/one.jpg")

        access.claim([url])
        access.releaseAll()
        access.releaseAll()

        XCTAssertEqual(recorder.stopped, [url])
    }

    /// Selection expands a picked folder into file paths straight away. Those
    /// paths carry no grant of their own, so what the user actually chose is
    /// what has to stay open.
    func testAddInputsClaimsWhatTheUserPicked() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("a.jpg")
        try Data("jpg".utf8).write(to: photo)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.addInputs(urls: [folder])

        XCTAssertEqual(model.pendingPhotoURLs.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(recorder.started, [folder], "The grant belongs to the folder, not its contents.")
        XCTAssertTrue(recorder.stopped.isEmpty, "The pipeline still has to read these files.")
    }

    /// A grant costs a kernel resource, so one that backs nothing is a leak.
    /// Everything selection is handed gets claimed before it is classified;
    /// what selection then discards has to be handed back.
    func testDiscardedInputsDoNotKeepTheirGrant() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let photo = base.appendingPathComponent("a.jpg")
        try Data("jpg".utf8).write(to: photo)
        let ignored = base.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: ignored)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.addInputs(urls: [photo, ignored])

        XCTAssertEqual(recorder.started, [photo, ignored])
        XCTAssertEqual(recorder.stopped, [ignored], "Nothing selected sits under the ignored file.")
        XCTAssertEqual(model.inputAccess.claimed, [photo])
    }

    func testRemovingTheLastPhotoReleasesTheFolderItCameFrom() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: folder.appendingPathComponent("a.jpg"))

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.addInputs(urls: [folder])
        XCTAssertEqual(model.inputAccess.claimed, [folder])

        model.removeAllPhotos()
        XCTAssertEqual(recorder.stopped, [folder])
        XCTAssertTrue(model.inputAccess.claimed.isEmpty)
    }

    func testEvictedMediaReleasesItsGrantWhenADatasetWins() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let photo = base.appendingPathComponent("a.jpg")
        try Data("jpg".utf8).write(to: photo)
        let dataset = base.appendingPathComponent("scene", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: sparse.appendingPathComponent("cameras.bin"))
        try Data("i".utf8).write(to: sparse.appendingPathComponent("images.bin"))
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: images.appendingPathComponent("frame001.jpg"))

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.addInputs(urls: [photo])
        XCTAssertEqual(model.inputAccess.claimed, [photo])

        model.addInputs(urls: [dataset])
        XCTAssertEqual(model.pendingDataset?.sourceURL, dataset)
        XCTAssertEqual(recorder.stopped, [photo], "The evicted photo's grant backs nothing now.")
        XCTAssertEqual(model.inputAccess.claimed, [dataset])

        model.removeDataset()
        XCTAssertEqual(recorder.stopped, [photo, dataset])
        XCTAssertTrue(model.inputAccess.claimed.isEmpty)
    }

    func testRejectedReplacementKeepsTheOldGrantAndReleasesTheRejectedOne() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let oldVideo = base.appendingPathComponent("old.mp4")
        let rejected = base.appendingPathComponent("notes.txt")
        try Data("video".utf8).write(to: oldVideo)
        try Data("text".utf8).write(to: rejected)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [oldVideo])

        model.selectInputs(urls: [rejected], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
        XCTAssertEqual(recorder.started, [oldVideo, rejected])
        XCTAssertEqual(recorder.stopped, [rejected])
        XCTAssertEqual(model.inputAccess.claimed, [oldVideo])
    }

    func testSymlinkZipReplacementKeepsOldGrantAndReleasesRejectedGrant() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let oldVideo = base.appendingPathComponent("old.mp4")
        try Data("video".utf8).write(to: oldVideo)
        let archive = try makeNerfstudioZip(in: base)
        let symlink = base.appendingPathComponent("linked-dataset.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: archive)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [oldVideo])

        model.selectInputs(urls: [symlink], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
        XCTAssertNil(model.pendingDataset)
        XCTAssertEqual(
            recorder.events,
            [.start(oldVideo), .start(symlink), .stop(symlink)]
        )
        XCTAssertEqual(model.inputAccess.claimed, [oldVideo])
    }

    func testSymlinkZipAppendReleasesItsRejectedGrant() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = try makeNerfstudioZip(in: base)
        let symlink = base.appendingPathComponent("linked-dataset.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: archive)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.selectInputs(urls: [symlink], mode: .append)

        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertNil(model.pendingDataset)
        XCTAssertEqual(recorder.events, [.start(symlink), .stop(symlink)])
        XCTAssertTrue(model.inputAccess.claimed.isEmpty)
    }

    func testExplicitImporterCancellationLeavesExistingSelectionAndGrantUntouched() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let oldVideo = base.appendingPathComponent("old.mp4")
        try Data("video".utf8).write(to: oldVideo)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [oldVideo])
        var presentation = InputImporterPresentation()
        presentation.present(.replaceFiles)

        presentation.presentationChanged(false)
        presentation.cancel()

        XCTAssertEqual(model.pendingVideoURLs, [oldVideo])
        XCTAssertEqual(recorder.events, [.start(oldVideo)])
        XCTAssertEqual(model.inputAccess.claimed, [oldVideo])
    }

    func testSuccessfulReplacementReleasesTheOldGrantOnlyAfterTheNewInputIsClaimed() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let oldVideo = base.appendingPathComponent("old.mp4")
        let replacement = base.appendingPathComponent("replacement.mp4")
        try Data("old".utf8).write(to: oldVideo)
        try Data("new".utf8).write(to: replacement)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [oldVideo])

        model.selectInputs(urls: [replacement], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [replacement])
        XCTAssertEqual(recorder.started, [oldVideo, replacement])
        XCTAssertEqual(recorder.stopped, [oldVideo])
        XCTAssertEqual(
            recorder.events,
            [.start(oldVideo), .start(replacement), .stop(oldVideo)]
        )
        XCTAssertEqual(model.inputAccess.claimed, [replacement])
    }

    func testRepeatedSameURLReplacementKeepsExactlyOneNewClaim() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let video = base.appendingPathComponent("capture.mp4")
        try Data("video".utf8).write(to: video)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [video])

        model.selectInputs(urls: [video], mode: .replace)
        model.selectInputs(urls: [video], mode: .replace)

        XCTAssertEqual(
            recorder.events,
            [
                .start(video),
                .start(video),
                .stop(video),
                .start(video),
                .stop(video),
            ]
        )
        XCTAssertEqual(model.inputAccess.claimed, [video])

        model.clearPendingInputs()
        XCTAssertEqual(recorder.started.count, 3)
        XCTAssertEqual(recorder.stopped.count, 3, "Every successful start must be balanced once.")
    }

    func testParentToChildReplacementReleasesTheParentGeneration() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("frame.jpg")
        try Data("photo".utf8).write(to: photo)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [folder])

        model.selectInputs(urls: [photo], mode: .replace)

        XCTAssertEqual(model.pendingPhotoURLs, [photo])
        XCTAssertEqual(
            recorder.events,
            [.start(folder), .start(photo), .stop(folder)]
        )
        XCTAssertEqual(model.inputAccess.claimed, [photo])
    }

    func testFailedSameURLReplacementReleasesOnlyTheProvisionalClaim() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let video = base.appendingPathComponent("capture.mp4")
        try Data("video".utf8).write(to: video)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [video])
        try FileManager.default.removeItem(at: video)

        model.selectInputs(urls: [video], mode: .replace)

        XCTAssertEqual(model.pendingVideoURLs, [video])
        XCTAssertEqual(
            recorder.events,
            [.start(video), .start(video), .stop(video)]
        )
        XCTAssertEqual(model.inputAccess.claimed, [video])
    }

    func testAppendingAnAlreadySelectedURLDoesNotTakeAnotherClaim() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let video = base.appendingPathComponent("capture.mp4")
        try Data("video".utf8).write(to: video)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [video])

        model.selectInputs(urls: [video], mode: .append)

        XCTAssertEqual(model.pendingVideoURLs, [video])
        XCTAssertEqual(recorder.events, [.start(video)])
        XCTAssertEqual(model.inputAccess.claimed, [video])
    }

    func testCommittedAppendReleasesRejectedParentFolderClaim() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let selectedFolder = base.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        let oldPhoto = selectedFolder.appendingPathComponent("old.jpg")
        let newVideo = base.appendingPathComponent("new.mp4")
        try Data("old".utf8).write(to: oldPhoto)
        try Data("new".utf8).write(to: newVideo)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)
        model.addInputs(urls: [oldPhoto])

        model.selectInputs(
            urls: [selectedFolder, newVideo],
            mode: .append,
            folderTraversalProvider: { _ in
                InputFolderTraversal(
                    rootMetadata: nil,
                    events: AnySequence<InputFolderTraversalEvent>([])
                )
            }
        )

        XCTAssertEqual(model.pendingPhotoURLs, [oldPhoto])
        XCTAssertEqual(model.pendingVideoURLs, [newVideo])
        XCTAssertEqual(
            recorder.events,
            [
                .start(oldPhoto),
                .start(selectedFolder),
                .start(newVideo),
                .stop(selectedFolder),
            ]
        )
        XCTAssertEqual(model.inputAccess.claimed, [oldPhoto, newVideo])
    }

    func testWrappedDatasetRetainsGrantForExactSelectedParent() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let selectedParent = base.appendingPathComponent("Selected Export", isDirectory: true)
        let dataset = selectedParent.appendingPathComponent("scene", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: sparse.appendingPathComponent("cameras.bin"))
        try Data("i".utf8).write(to: sparse.appendingPathComponent("images.bin"))
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: images.appendingPathComponent("frame001.jpg"))

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.addInputs(urls: [selectedParent])

        XCTAssertEqual(model.pendingDataset?.selectedURL, selectedParent)
        XCTAssertEqual(model.pendingDataset?.resolvedRoot, dataset)
        XCTAssertEqual(recorder.started, [selectedParent])
        XCTAssertEqual(model.inputAccess.claimed, [selectedParent])
        XCTAssertTrue(recorder.stopped.isEmpty)
    }

    /// A dropped splat opens in the viewer instead of joining the selection. The
    /// viewer window takes a grant of its own, but only once the request is
    /// drained, so this one has to survive until then.
    func testASplatKeepsItsGrantUntilTheViewerRequestIsDrained() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let splat = base.appendingPathComponent("scene.ply")
        try Data("ply".utf8).write(to: splat)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.addInputs(urls: [splat])
        XCTAssertEqual(model.splatOpenRequests, [splat])
        XCTAssertEqual(model.inputAccess.claimed, [splat])
        XCTAssertTrue(recorder.stopped.isEmpty)

        model.splatOpenRequests.removeAll()
        model.pruneInputAccess()
        XCTAssertEqual(recorder.stopped, [splat])
    }

    func testClearingTheSelectionReleasesTheGrant() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let photo = base.appendingPathComponent("a.jpg")
        try Data("jpg".utf8).write(to: photo)

        let recorder = Recorder()
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        model.inputAccess = makeAccess(recorder)

        model.addInputs(urls: [photo])
        XCTAssertEqual(recorder.started, [photo])

        model.clearPendingInputs()
        XCTAssertEqual(recorder.stopped, [photo])
    }
}
#endif
