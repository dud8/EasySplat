#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

final class DatasetSnifferTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatasetSnifferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ relativePath: String, contents: String = "x") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func makeColmapFixture(at prefix: String = "") throws {
        let base = prefix.isEmpty ? "" : prefix + "/"
        try makeFile("\(base)sparse/0/cameras.bin")
        try makeFile("\(base)sparse/0/images.bin")
        try makeFile("\(base)images/frame001.jpg")
    }

    private func makePolycamFixture(at prefix: String = "", corrected: Bool = false) throws {
        let base = prefix.isEmpty ? "" : prefix + "/"
        let cameras = corrected ? "corrected_cameras" : "cameras"
        let images = corrected ? "corrected_images" : "images"
        _ = try makeDirectory("\(base)keyframes/\(cameras)")
        _ = try makeDirectory("\(base)keyframes/\(images)")
    }

    // MARK: - Folder detection

    func testDetectsColmapWithSparseModelAndImagesFolder() throws {
        try makeColmapFixture()
        XCTAssertEqual(DatasetSniffer.detect(at: root), .colmap(root: root))
        XCTAssertEqual(DatasetSniffer.detect(at: root)?.kind, .colmap)
    }

    func testDetectsColmapWithRootModelAndLooseImages() throws {
        try makeFile("cameras.txt")
        try makeFile("images.txt")
        try makeFile("frame001.jpg")
        XCTAssertEqual(DatasetSniffer.detect(at: root), .colmap(root: root))
    }

    func testColmapModelWithoutAnyImagesIsNotDetected() throws {
        try makeFile("sparse/0/cameras.bin")
        try makeFile("sparse/0/images.bin")
        // A "sparse" child directory alone would qualify for nested descent,
        // but a bare model with no image data cannot train.
        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    func testColmapSymlinkedModelMarkerIsNotDetected() throws {
        let external = root.appendingPathComponent("external-cameras.bin")
        try Data("camera".utf8).write(to: external)
        try makeFile("sparse/0/images.bin")
        try makeFile("images/frame001.jpg")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sparse/0/cameras.bin"),
            withDestinationURL: external
        )

        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    func testDetectsNerfstudioTransforms() throws {
        try makeFile("transforms.json", contents: "{}")
        XCTAssertEqual(DatasetSniffer.detect(at: root), .nerfstudio(root: root))
    }

    func testTrainOnlyNerfstudioFolderFallsThroughDatasetDetection() throws {
        try makeFile("transforms_train.json", contents: "{}")
        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    func testDetectsPolycamKeyframes() throws {
        try makePolycamFixture()
        XCTAssertEqual(DatasetSniffer.detect(at: root), .polycam(root: root))
    }

    func testDetectsPolycamCorrectedKeyframes() throws {
        try makePolycamFixture(corrected: true)
        XCTAssertEqual(DatasetSniffer.detect(at: root), .polycam(root: root))
    }

    func testPolycamRequiresBothCamerasAndImages() throws {
        _ = try makeDirectory("keyframes/cameras")
        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    // MARK: - Precedence

    func testColmapWinsOverNerfstudioMarkers() throws {
        try makeColmapFixture()
        try makeFile("transforms.json", contents: "{}")
        XCTAssertEqual(DatasetSniffer.detect(at: root)?.kind, .colmap)
    }

    func testNerfstudioWinsOverPolycamMarkers() throws {
        try makeFile("transforms.json", contents: "{}")
        try makePolycamFixture()
        XCTAssertEqual(DatasetSniffer.detect(at: root)?.kind, .nerfstudio)
    }

    // MARK: - Nested descent

    func testDescendsIntoSoleChildDirectory() throws {
        try makeColmapFixture(at: "export")
        let child = root.appendingPathComponent("export", isDirectory: true)
        XCTAssertEqual(DatasetSniffer.detect(at: root), .colmap(root: child))
    }

    func testDoesNotDescendIntoSoleSymlinkedChildDirectory() throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatasetSnifferExternal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent("sparse/0", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("c".utf8).write(to: external.appendingPathComponent("sparse/0/cameras.bin"))
        try Data("i".utf8).write(to: external.appendingPathComponent("sparse/0/images.bin"))
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("jpg".utf8).write(to: external.appendingPathComponent("images/frame001.jpg"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("export", isDirectory: true),
            withDestinationURL: external
        )

        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    func testSoleChildDescentIgnoresLooseFilesAtRoot() throws {
        try makeColmapFixture(at: "export")
        try makeFile("readme.txt")
        let child = root.appendingPathComponent("export", isDirectory: true)
        XCTAssertEqual(DatasetSniffer.detect(at: root), .colmap(root: child))
    }

    func testTwoCandidateChildrenAreAmbiguous() throws {
        try makeColmapFixture(at: "exportA")
        try makeColmapFixture(at: "exportB")
        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    func testDescentStopsAtDepthTwo() throws {
        // Marker sits two directories down; the single descent step must not
        // reach it.
        try makeColmapFixture(at: "outer/inner")
        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    func testPlainPhotoFolderIsNotADataset() throws {
        try makeFile("a.jpg")
        try makeFile("b.jpg")
        try makeFile("c.heic")
        XCTAssertNil(DatasetSniffer.detect(at: root))
    }

    func testFolderSniffingStopsAtItsEntryBudget() throws {
        try makeFile("wrapper/transforms.json", contents: "{}")
        try makeFile("readme.txt")

        XCTAssertEqual(
            DatasetSniffer.detect(at: root, maximumEntryCount: 2)?.kind,
            .nerfstudio
        )
        XCTAssertNil(DatasetSniffer.detect(at: root, maximumEntryCount: 1))
        XCTAssertEqual(DatasetContract.maximumEntryCount, 50_000)
    }

    func testMissingFolderIsNotADataset() {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNil(DatasetSniffer.detect(at: missing))
    }

    // MARK: - Zip detection

    /// Builds a real archive holding the named entries; detection reads its
    /// central directory rather than a listing subprocess.
    private func detection(
        forZipEntries entries: [String],
        unreadable: Bool = false
    ) -> DatasetSniffer.DatasetDetection? {
        let zipURL = root.appendingPathComponent("dataset-\(UUID().uuidString).zip")
        if unreadable {
            try? Data("not a zip".utf8).write(to: zipURL)
            return DatasetSniffer.detectInZip(at: zipURL)
        }
        let payload = root.appendingPathComponent("payload-\(UUID().uuidString)", isDirectory: true)
        // Trailing-slash names are directory markers, not files; creating them
        // as files would block the nested entries that follow.
        for entry in entries.sorted() {
            let target = payload.appendingPathComponent(entry)
            if entry.hasSuffix("/") {
                try? FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
                continue
            }
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data("x".utf8).write(to: target)
        }
        guard !entries.isEmpty else {
            try? FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            return DatasetSniffer.detectInZip(at: zipURL)
        }
        // Zip the top-level names rather than ".", so entries do not gain a
        // "./" prefix that would consume the single-root-folder allowance.
        let topLevel = (try? FileManager.default.contentsOfDirectory(
            atPath: payload.path
        )) ?? []
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", "-X", zipURL.path] + topLevel.sorted()
        process.currentDirectoryURL = payload
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return DatasetSniffer.detectInZip(at: zipURL)
    }

    func testZipDetectsColmapEntries() {
        let detection = detection(forZipEntries: [
            "sparse/0/cameras.bin",
            "sparse/0/images.bin",
            "sparse/0/points3D.bin",
            "images/frame001.jpg",
        ])
        XCTAssertEqual(detection?.kind, .colmap)
    }

    func testZipDetectsColmapEntriesBehindSingleRootFolder() {
        let detection = detection(forZipEntries: [
            "export/",
            "export/sparse/0/cameras.txt",
            "export/sparse/0/images.txt",
            "export/images/frame001.jpg",
        ])
        XCTAssertEqual(detection?.kind, .colmap)
    }

    func testZipDetectsNerfstudioEntries() {
        let detection = detection(forZipEntries: [
            "scene/",
            "scene/transforms.json",
            "scene/images/frame001.png",
        ])
        XCTAssertEqual(detection?.kind, .nerfstudio)
    }

    func testTrainOnlyNerfstudioZipIsUnsupported() {
        let detection = detection(forZipEntries: [
            "scene/",
            "scene/transforms_train.json",
            "scene/images/frame001.png",
        ])
        XCTAssertNil(detection)
    }

    func testZipDetectsPolycamEntries() {
        let detection = detection(forZipEntries: [
            "keyframes/cameras/0.json",
            "keyframes/images/0.jpg",
        ])
        XCTAssertEqual(detection?.kind, .polycam)
    }

    func testZipPrecedencePrefersColmap() {
        let detection = detection(forZipEntries: [
            "sparse/cameras.bin",
            "sparse/images.bin",
            "images/frame001.jpg",
            "transforms.json",
        ])
        XCTAssertEqual(detection?.kind, .colmap)
    }

    func testZipOfPhotosIsNotADataset() {
        XCTAssertNil(detection(forZipEntries: ["a.jpg", "b.jpg", "c.jpg"]))
    }

    func testZipListingFailureIsNotADataset() {
        XCTAssertNil(detection(forZipEntries: [], unreadable: true))
    }

    func testZipSniffingAcceptsExactly50000EntriesAndRejects50001() {
        let archive = root.appendingPathComponent("synthetic.zip")
        var names = [DatasetContract.nerfstudioManifestName]
        names.append(contentsOf: (1..<50_000).map { "metadata/\($0).txt" })

        XCTAssertEqual(
            DatasetSniffer.detectInZip(at: archive, entryNameLoader: { _ in names })?.kind,
            .nerfstudio
        )
        names.append("metadata/overflow.txt")
        XCTAssertNil(
            DatasetSniffer.detectInZip(at: archive, entryNameLoader: { _ in names })
        )
    }

    func testZipSniffingAccepts64ComponentsAndRejects65() {
        let archive = root.appendingPathComponent("synthetic.zip")
        let sixtyFour = Array(repeating: "d", count: 63).joined(separator: "/")
            + "/frame.jpg"
        let sixtyFive = Array(repeating: "d", count: 64).joined(separator: "/")
            + "/frame.jpg"

        XCTAssertEqual(
            DatasetSniffer.detectInZip(
                at: archive,
                entryNameLoader: { _ in
                    [DatasetContract.nerfstudioManifestName, sixtyFour]
                }
            )?.kind,
            .nerfstudio
        )
        XCTAssertNil(
            DatasetSniffer.detectInZip(
                at: archive,
                entryNameLoader: { _ in
                    [DatasetContract.nerfstudioManifestName, sixtyFive]
                }
            )
        )
        XCTAssertEqual(DatasetContract.maximumRelativePathComponents, 64)
    }

    // MARK: - Zip detection (real archive)

    func testZipDetectionAgainstARealArchive() throws {
        try makeColmapFixture(at: "export")
        let zipURL = root.appendingPathComponent("export.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-rq", zipURL.path, "export"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        XCTAssertEqual(DatasetSniffer.detectInZip(at: zipURL)?.kind, .colmap)
    }
}

/// Emits a canned `zipinfo -1` listing so signature matching is exercised
/// without touching a real archive.

#endif
