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

    func testDetectsNerfstudioTransforms() throws {
        try makeFile("transforms.json", contents: "{}")
        XCTAssertEqual(DatasetSniffer.detect(at: root), .nerfstudio(root: root))
    }

    func testDetectsNerfstudioTransformsTrain() throws {
        try makeFile("transforms_train.json", contents: "{}")
        XCTAssertEqual(DatasetSniffer.detect(at: root), .nerfstudio(root: root))
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

    func testMissingFolderIsNotADataset() {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNil(DatasetSniffer.detect(at: missing))
    }

    // MARK: - Zip detection (stubbed listing)

    private func detection(forZipEntries entries: [String], exitCode: Int32 = 0) -> DatasetSniffer.DatasetDetection? {
        let zipURL = root.appendingPathComponent("dataset.zip")
        let runner = StubZipListingRunner(lines: entries, exitCode: exitCode)
        return DatasetSniffer.detectInZip(at: zipURL, runner: runner)
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
        XCTAssertNil(detection(forZipEntries: [], exitCode: 1))
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
private struct StubZipListingRunner: SubprocessRunning {
    let lines: [String]
    let exitCode: Int32

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        lines.forEach(onStdout)
        return SubprocessResult(
            exitCode: exitCode,
            terminationReason: .exit,
            stdout: lines.joined(separator: "\n"),
            stderr: ""
        )
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try run(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: removingEnvironmentKeys,
            onStdout: onStdout,
            onStderr: onStderr
        )
    }
}
#endif
