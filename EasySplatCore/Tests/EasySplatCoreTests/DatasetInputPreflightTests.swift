import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class DatasetInputPreflightTests: XCTestCase {
    // MARK: - Fixtures

    private var identityMatrix: [[Double]] {
        [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    }

    private func writeTransformsJSON(
        at url: URL,
        framePaths: [String],
        width: Int = 8,
        height: Int = 8
    ) throws {
        let object: [String: Any] = [
            "camera_model": "PINHOLE",
            "fl_x": 500.0, "fl_y": 500.0, "cx": Double(width) / 2, "cy": Double(height) / 2,
            "w": width, "h": height,
            "frames": framePaths.map {
                ["file_path": $0, "transform_matrix": identityMatrix]
            },
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @discardableResult
    private func writeJPEG(at url: URL, value: UInt8) throws -> URL {
        try TestFileBuilder.createDirectory(url.deletingLastPathComponent())
        guard try TestFileBuilder.writeGrayscaleImage(
            url: url,
            size: 8,
            value: value,
            utType: .jpeg
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private func writeGrayJPEG(
        at url: URL,
        width: Int,
        height: Int,
        value: UInt8 = 96,
        properties: CFDictionary? = nil
    ) throws {
        try TestFileBuilder.createDirectory(url.deletingLastPathComponent())
        var pixels = [UInt8](repeating: value, count: width * height)
        let data = Data(bytes: &pixels, count: pixels.count)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
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
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeRotatedJPEG(at url: URL, orientation: Int) throws {
        try writeGrayJPEG(
            at: url,
            width: 8,
            height: 8,
            properties: [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
    }

    /// A nerfstudio dataset folder with `transforms.json` and three distinct tiny JPEGs.
    private func makeNerfstudioDataset(in root: URL) throws -> URL {
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let framePaths = ["images/frame_0001.jpg", "images/frame_0002.jpg", "images/frame_0003.jpg"]
        for (index, path) in framePaths.enumerated() {
            try writeJPEG(
                at: dataset.appendingPathComponent(path),
                value: UInt8(40 + index * 60)
            )
        }
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: framePaths
        )
        return dataset
    }

    private func polycamCameraJSON(tx: Double) -> String {
        """
        {"fx": 500.0, "fy": 500.0, "cx": 4.0, "cy": 4.0,
         "width": 8, "height": 8, "blur_score": 200.0,
         "t_00": 1, "t_01": 0, "t_02": 0, "t_03": \(tx),
         "t_10": 0, "t_11": 1, "t_12": 0, "t_13": 0,
         "t_20": 0, "t_21": 0, "t_22": 1, "t_23": 0}
        """
    }

    private func prepare(
        source: URL,
        isZip: Bool = false,
        kind: DatasetKind,
        stagingParent: URL,
        runner: SubprocessRunning = SubprocessRunner()
    ) async throws -> PreparedDatasetInput {
        try await DatasetInputPreflight.prepare(
            source: source,
            isZip: isZip,
            kind: kind,
            stagingParent: stagingParent,
            runner: runner
        )
    }

    private func prepare(
        source: DatasetInputSource,
        kind: DatasetKind,
        stagingParent: URL,
        runner: SubprocessRunning = SubprocessRunner(),
        sourceReadObserver: @escaping @Sendable (String) -> Void = { _ in },
        directoryLimits: DatasetSelectedRootReader.Limits = .datasetPreflight
    ) async throws -> PreparedDatasetInput {
        try await DatasetInputPreflight.prepare(
            source: source,
            kind: kind,
            stagingParent: stagingParent,
            runner: runner,
            sourceReadObserver: sourceReadObserver,
            directoryLimits: directoryLimits
        )
    }

    private func assertThrows(
        _ expected: DatasetInputError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected), got success.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DatasetInputError, expected, file: file, line: line)
        }
    }

    // MARK: - Nerfstudio folder

    func testNerfstudioFolderPreparesSeedAndStagedImages() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)

        let prepared = try await prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        defer { prepared.discard() }

        XCTAssertEqual(prepared.plan.kind, .nerfstudio)
        XCTAssertEqual(prepared.plan.route, .seedTriangulate)
        XCTAssertEqual(prepared.imageCount, 3)
        XCTAssertEqual(prepared.stagedImages.count, 3)
        XCTAssertGreaterThan(prepared.totalImageBytes, 0)
        XCTAssertEqual(prepared.maximumImagePixelDimension, 8)
        XCTAssertEqual(
            prepared.stagedImages.map(\.declaredPath),
            ["images/frame_0001.jpg", "images/frame_0002.jpg", "images/frame_0003.jpg"]
        )
        for staged in prepared.stagedImages {
            XCTAssertEqual(staged.sha256, try GeometryArtifactStore.sha256(of: staged.url))
        }

        // The staged seed must be a parseable COLMAP text model naming every image.
        let seedDirectory = prepared.stagingDirectory.appendingPathComponent("seed", isDirectory: true)
        XCTAssertEqual(
            prepared.seedFileURLs.map(\.lastPathComponent),
            ["cameras.txt", "images.txt", "points3D.txt"]
        )
        let parsed = try ColmapModelReader.read(modelDirectory: seedDirectory)
        XCTAssertEqual(parsed.format, .text)
        XCTAssertEqual(parsed.model.images.count, 3)
        XCTAssertEqual(
            parsed.model.images.map(\.name).sorted(),
            prepared.stagedImages.map(\.declaredPath)
        )
        XCTAssertEqual(
            try ColmapResidualAnalyzer.cameraModels(modelDirectory: seedDirectory),
            [1: "PINHOLE"]
        )

        // The original transforms.json rides along verbatim.
        XCTAssertEqual(prepared.sourceFileURLs.map(\.lastPathComponent), ["transforms.json"])
        XCTAssertEqual(
            try Data(contentsOf: prepared.sourceFileURLs[0]),
            try Data(contentsOf: dataset.appendingPathComponent("transforms.json"))
        )

        prepared.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagingDirectory.path))
    }

    func testSelectedParentAndSoleResolvedChildPrepareOneWrapperDataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedParent = root.appendingPathComponent("selected", isDirectory: true)
        try TestFileBuilder.createDirectory(selectedParent)
        let dataset = try makeNerfstudioDataset(in: selectedParent)

        let prepared = try await prepare(
            source: .directory(selectedURL: selectedParent, resolvedRoot: dataset),
            kind: .nerfstudio,
            stagingParent: root
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.imageCount, 3)
        XCTAssertTrue(prepared.stagedImages.allSatisfy {
            $0.url.path.hasPrefix(prepared.stagingDirectory.path + "/")
        })
    }

    func testSelectedParentReplacementBySymlinkIsUnsafe() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedParent = root.appendingPathComponent("selected", isDirectory: true)
        try TestFileBuilder.createDirectory(selectedParent)
        let dataset = try makeNerfstudioDataset(in: selectedParent)
        let source = DatasetInputSource.directory(
            selectedURL: selectedParent,
            resolvedRoot: dataset
        )

        let detached = root.appendingPathComponent("detached", isDirectory: true)
        try FileManager.default.moveItem(at: selectedParent, to: detached)
        let replacementParent = root.appendingPathComponent("replacement", isDirectory: true)
        _ = try makeNerfstudioDataset(in: replacementParent)
        try FileManager.default.createSymbolicLink(
            at: selectedParent,
            withDestinationURL: replacementParent
        )

        await assertThrows(.unsafeLayout) {
            _ = try await self.prepare(
                source: source,
                kind: .nerfstudio,
                stagingParent: root
            )
        }
    }

    func testResolvedRootMoreThanOneChildBelowSelectionIsUnsafe() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedParent = root.appendingPathComponent("selected", isDirectory: true)
        let wrapper = selectedParent.appendingPathComponent("wrapper", isDirectory: true)
        let dataset = try makeNerfstudioDataset(in: wrapper)

        await assertThrows(.unsafeLayout) {
            _ = try await self.prepare(
                source: .directory(selectedURL: selectedParent, resolvedRoot: dataset),
                kind: .nerfstudio,
                stagingParent: root
            )
        }
    }

    func testFolderPreflightOwnsImmutableMetadataAndImageSnapshots() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)

        let prepared = try await prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        defer { prepared.discard() }
        let stagedImageData = try prepared.stagedImages.map { try Data(contentsOf: $0.url) }
        let stagedSourceData = try prepared.sourceFileURLs.map { try Data(contentsOf: $0) }

        try FileManager.default.removeItem(at: dataset)

        XCTAssertEqual(
            try prepared.stagedImages.map { try Data(contentsOf: $0.url) },
            stagedImageData
        )
        XCTAssertEqual(
            try prepared.sourceFileURLs.map { try Data(contentsOf: $0) },
            stagedSourceData
        )
        XCTAssertTrue(prepared.stagedImages.allSatisfy {
            $0.url.path.hasPrefix(prepared.stagingDirectory.path + "/")
        })
        XCTAssertTrue(prepared.sourceFileURLs.allSatisfy {
            $0.path.hasPrefix(prepared.stagingDirectory.path + "/")
        })
        _ = try ColmapModelReader.read(
            modelDirectory: prepared.stagingDirectory.appendingPathComponent("seed", isDirectory: true)
        )
    }

    func testIntermediateSymlinkedImageDirectoryIsUnsafe() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let externalImages = root.appendingPathComponent("external-images", isDirectory: true)
        try TestFileBuilder.createDirectory(dataset)
        try writeJPEG(at: externalImages.appendingPathComponent("a.jpg"), value: 20)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent(DatasetContract.nerfstudioManifestName),
            framePaths: ["images/a.jpg"]
        )
        try FileManager.default.createSymbolicLink(
            at: dataset.appendingPathComponent("images", isDirectory: true),
            withDestinationURL: externalImages
        )

        do {
            _ = try await prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
            XCTFail("Expected unsafe dataset layout.")
        } catch {
            XCTAssertEqual(error as? DatasetInputError, .unsafeLayout)
            XCTAssertEqual(
                error.localizedDescription,
                "This dataset contains a linked or out-of-folder file. Re-export it with regular files inside one folder."
            )
        }
    }

    func testLinkedColmapModelDirectoryIsUnsafe() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let externalSparse = root.appendingPathComponent("external-sparse", isDirectory: true)
        try TestFileBuilder.createDirectory(externalSparse.appendingPathComponent("0", isDirectory: true))
        try TestFileBuilder.createTextFile(
            at: externalSparse.appendingPathComponent("0/cameras.txt"),
            text: "1 PINHOLE 8 8 500 500 4 4\n"
        )
        try TestFileBuilder.createTextFile(
            at: externalSparse.appendingPathComponent("0/images.txt"),
            text: "1 1 0 0 0 0 0 0 1 a.jpg\n\n"
        )
        try TestFileBuilder.createTextFile(
            at: externalSparse.appendingPathComponent("0/points3D.txt"),
            text: ""
        )
        try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 30)
        try FileManager.default.createSymbolicLink(
            at: dataset.appendingPathComponent("sparse", isDirectory: true),
            withDestinationURL: externalSparse
        )

        await assertThrows(.unsafeLayout) {
            _ = try await self.prepare(source: dataset, kind: .colmap, stagingParent: root)
        }
    }

    func testSpecialImageFileIsUnsafe() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let fifo = dataset.appendingPathComponent("images/a.jpg")
        try TestFileBuilder.createDirectory(fifo.deletingLastPathComponent())
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent(DatasetContract.nerfstudioManifestName),
            framePaths: ["images/a.jpg"]
        )

        await assertThrows(.unsafeLayout) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testSourceReplacementDuringDescriptorBindingIsUnsafe() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)
        let manifest = dataset.appendingPathComponent(DatasetContract.nerfstudioManifestName)

        await assertThrows(.unsafeLayout) {
            _ = try await self.prepare(
                source: .directory(selectedURL: dataset, resolvedRoot: dataset),
                kind: .nerfstudio,
                stagingParent: root,
                sourceReadObserver: { relativePath in
                    guard relativePath == DatasetContract.nerfstudioManifestName else { return }
                    try? FileManager.default.removeItem(at: manifest)
                    try? Data("{}".utf8).write(to: manifest)
                }
            )
        }
    }

    func testIntermediateDirectoryReplacementDuringCopyIsUnsafe() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let originalImages = dataset.appendingPathComponent("images", isDirectory: true)
        let detachedImages = root.appendingPathComponent("detached-images", isDirectory: true)
        let replacementImages = root.appendingPathComponent("replacement-images", isDirectory: true)
        let framePath = "images/frame.jpg"
        try writeJPEG(at: dataset.appendingPathComponent(framePath), value: 30)
        try writeJPEG(at: replacementImages.appendingPathComponent("frame.jpg"), value: 220)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent(DatasetContract.nerfstudioManifestName),
            framePaths: [framePath]
        )

        await assertThrows(.unsafeLayout) {
            _ = try await self.prepare(
                source: .directory(selectedURL: dataset, resolvedRoot: dataset),
                kind: .nerfstudio,
                stagingParent: root,
                sourceReadObserver: { relativePath in
                    guard relativePath == framePath else { return }
                    try? FileManager.default.moveItem(at: originalImages, to: detachedImages)
                    try? FileManager.default.moveItem(at: replacementImages, to: originalImages)
                }
            )
        }
    }

    func testFolderMaterializationRejectsMoreThan64RelativeComponents() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let framePath = Array(repeating: "d", count: 64).joined(separator: "/") + "/frame.jpg"
        try writeJPEG(at: dataset.appendingPathComponent(framePath), value: 30)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent(DatasetContract.nerfstudioManifestName),
            framePaths: [framePath]
        )

        await assertThrows(.unreadableDataset) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testFolderMaterializationEnforcesVisitedOperationBudget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)

        await assertThrows(.unreadableDataset) {
            _ = try await self.prepare(
                source: .directory(selectedURL: dataset, resolvedRoot: dataset),
                kind: .nerfstudio,
                stagingParent: root,
                directoryLimits: .init(
                    maximumRelativePathComponents: 64,
                    maximumVisitedOperations: 1,
                    maximumAcceptedEntries: 50_000,
                    maximumTotalCopiedBytes: 64 * 1_024 * 1_024 * 1_024
                )
            )
        }
    }

    func testFolderMaterializationEnforcesAcceptedEntryBudget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)

        await assertThrows(.unreadableDataset) {
            _ = try await self.prepare(
                source: .directory(selectedURL: dataset, resolvedRoot: dataset),
                kind: .nerfstudio,
                stagingParent: root,
                directoryLimits: .init(
                    maximumRelativePathComponents: 64,
                    maximumVisitedOperations: 50_000,
                    maximumAcceptedEntries: 1,
                    maximumTotalCopiedBytes: 64 * 1_024 * 1_024 * 1_024
                )
            )
        }
    }

    func testFolderMaterializationEnforcesCumulativeStagingBudget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)

        await assertThrows(.unreadableDataset) {
            _ = try await self.prepare(
                source: .directory(selectedURL: dataset, resolvedRoot: dataset),
                kind: .nerfstudio,
                stagingParent: root,
                directoryLimits: .init(
                    maximumRelativePathComponents: 64,
                    maximumVisitedOperations: 50_000,
                    maximumAcceptedEntries: 50_000,
                    maximumTotalCopiedBytes: 1
                )
            )
        }
    }

    func testDestinationSyncFailureIsNotReportedAsUnsafeLayout() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try TestFileBuilder.createDirectory(destination)
        let reader = try DatasetSelectedRootReader(
            selectedURL: dataset,
            resolvedRoot: dataset,
            sourceReadObserver: { _ in },
            destinationSync: { _ in false }
        )

        XCTAssertThrowsError(
            try reader.copyRegularFile(
                at: DatasetContract.nerfstudioManifestName,
                to: destination,
                maximumBytes: 64 * 1_024 * 1_024
            )
        ) { error in
            guard case DatasetSelectedRootReader.ReaderError.destinationUnavailable = error else {
                return XCTFail("Expected destinationUnavailable, got \(error)")
            }
        }
    }

    func testDestinationIntermediateSymlinkCannotEscapeStagingRoot() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try TestFileBuilder.createDirectory(destination)
        try TestFileBuilder.createDirectory(outside)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("images", isDirectory: true),
            withDestinationURL: outside
        )
        let reader = try DatasetSelectedRootReader(
            selectedURL: dataset,
            resolvedRoot: dataset,
            sourceReadObserver: { _ in }
        )

        XCTAssertThrowsError(
            try reader.copyRegularFile(
                at: "images/frame_0001.jpg",
                to: destination,
                maximumBytes: 64 * 1_024 * 1_024
            )
        ) { error in
            guard case DatasetSelectedRootReader.ReaderError.destinationUnavailable = error else {
                return XCTFail("Expected destinationUnavailable, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("frame_0001.jpg").path
            )
        )
    }

    // MARK: - Polycam folder

    func testPolycamFolderPrefersCorrectedCamerasAndSkipsUnpairedJSON() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("polycam", isDirectory: true)
        let keyframes = dataset.appendingPathComponent("keyframes", isDirectory: true)
        let corrected = keyframes.appendingPathComponent("corrected_cameras", isDirectory: true)
        let correctedImages = keyframes.appendingPathComponent("corrected_images", isDirectory: true)
        let plain = keyframes.appendingPathComponent("cameras", isDirectory: true)
        for directory in [corrected, correctedImages, plain] {
            try TestFileBuilder.createDirectory(directory)
        }
        try TestFileBuilder.createTextFile(
            at: corrected.appendingPathComponent("100_001.json"),
            text: polycamCameraJSON(tx: 0)
        )
        try TestFileBuilder.createTextFile(
            at: corrected.appendingPathComponent("100_002.json"),
            text: polycamCameraJSON(tx: 0.5)
        )
        // A camera without a paired image contributes no pose.
        try TestFileBuilder.createTextFile(
            at: corrected.appendingPathComponent("100_003.json"),
            text: polycamCameraJSON(tx: 1)
        )
        // A decoy in the uncorrected folder must not be read.
        try TestFileBuilder.createTextFile(
            at: plain.appendingPathComponent("100_001.json"),
            text: "not json"
        )
        try writeJPEG(at: correctedImages.appendingPathComponent("100_001.jpg"), value: 30)
        try writeJPEG(at: correctedImages.appendingPathComponent("100_002.jpg"), value: 200)

        let prepared = try await prepare(source: dataset, kind: .polycam, stagingParent: root)
        defer { prepared.discard() }

        XCTAssertEqual(prepared.plan.kind, .polycam)
        XCTAssertEqual(prepared.imageCount, 2)
        XCTAssertEqual(prepared.stagedImages.map(\.entryID), ["100_001", "100_002"])
        XCTAssertEqual(
            prepared.stagedImages.map(\.declaredPath),
            ["keyframes/corrected_images/100_001.jpg", "keyframes/corrected_images/100_002.jpg"]
        )
        XCTAssertTrue(prepared.plan.notes.contains { $0.contains("corrected cameras") })
        XCTAssertEqual(
            Set(prepared.sourceFileURLs.map(\.lastPathComponent)),
            ["100_001.json", "100_002.json"]
        )
    }

    // MARK: - ZIP archives

    private func metadataLine(mode: String, size: Int, name: String) -> String {
        "\(mode)  3.0 unx \(size) bx \(size) defN 01-Jan-26 00:00 \(name)"
    }

    /// Zips a directory under a single wrapping folder, as a real export would.
    private func makeZip(
        at url: URL,
        wrapping payload: URL,
        as wrapper: String
    ) throws -> URL {
        var entries: [ZipFixtureBuilder.Entry] = []
        let enumerator = FileManager.default.enumerator(
            at: payload,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let base = payload.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let components = item.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > base.count else { continue }
            let relative = components.dropFirst(base.count).joined(separator: "/")
            entries.append(.file(path: "\(wrapper)/\(relative)", contents: try Data(contentsOf: item)))
        }
        return try ZipFixtureBuilder.build(at: url, entries: entries)
    }

    func testZipDescendsSingleWrapperFolderAndPlansNerfstudio() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Real payload files copied into place by the scripted unzip. Directory
        // entries are omitted from the listing: the extractor's entry-path
        // validation accepts regular-file names only.
        let payload = try makeNerfstudioDataset(in: root)
        let archive = try makeZip(
            at: root.appendingPathComponent("export.zip"),
            wrapping: payload,
            as: "wrapper"
        )

        let prepared = try await prepare(
            source: archive,
            isZip: true,
            kind: .nerfstudio,
            stagingParent: root,
            runner: MockSubprocessRunner(scripts: [])
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.imageCount, 3)
        // Extracted images are staged inside the preflight's own directory.
        for staged in prepared.stagedImages {
            XCTAssertTrue(staged.url.path.hasPrefix(prepared.stagingDirectory.path))
        }
    }

    func testZipWithoutDatasetStructureThrowsArchiveNotADataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("export.zip"),
            entries: [.file(path: "wrapper/readme.txt", contents: Data("hello".utf8))]
        )
        let runner = MockSubprocessRunner(scripts: [])

        await assertThrows(.archiveNotADataset) {
            _ = try await self.prepare(
                source: archive,
                isZip: true,
                kind: .nerfstudio,
                stagingParent: root,
                runner: runner
            )
        }
    }

    func testTrainOnlyNerfstudioZipIsNotADataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("train-only.zip"),
            entries: [
                .file(path: "wrapper/transforms_train.json", contents: Data("{}".utf8)),
                .file(path: "wrapper/images/a.jpg", contents: Data([0xFF, 0xD8, 0xFF])),
            ]
        )

        await assertThrows(.archiveNotADataset) {
            _ = try await self.prepare(
                source: archive,
                isZip: true,
                kind: .nerfstudio,
                stagingParent: root,
                runner: MockSubprocessRunner(scripts: [])
            )
        }
    }

    func testDatasetArchiveEntryLimitIsExactly50000() {
        XCTAssertEqual(DatasetContract.maximumEntryCount, 50_000)
        XCTAssertEqual(DatasetInputPreflight.extractionLimits.maxEntryCount, 50_000)
        XCTAssertEqual(
            DatasetSelectedRootReader.Limits.datasetPreflight.maximumAcceptedEntries,
            50_000
        )
    }

    func testZipDatasetLimitsAcceptExactBoundariesAndRejectOverflow() {
        let sixtyFour = Array(repeating: "d", count: 63).joined(separator: "/")
            + "/frame.jpg"
        let sixtyFive = Array(repeating: "d", count: 64).joined(separator: "/")
            + "/frame.jpg"
        XCTAssertTrue(DatasetInputPreflight.archivePathsAreWithinLimits([sixtyFour]))
        XCTAssertFalse(DatasetInputPreflight.archivePathsAreWithinLimits([sixtyFive]))

        let atEntryLimit = Array(
            repeating: DatasetContract.nerfstudioManifestName,
            count: 50_000
        )
        XCTAssertTrue(DatasetInputPreflight.archivePathsAreWithinLimits(atEntryLimit))
        XCTAssertFalse(
            DatasetInputPreflight.archivePathsAreWithinLimits(
                atEntryLimit + ["overflow.txt"]
            )
        )
    }

    // MARK: - Gates

    func testTooManyImagesThrowsBeforeResolvingFiles() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try TestFileBuilder.createDirectory(dataset)
        let count = RunPlanResolver.maximumDatasetImageCount + 1
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: (0..<count).map { String(format: "images/f%05d.jpg", $0) }
        )

        await assertThrows(.tooManyImages(count: count, maximum: RunPlanResolver.maximumDatasetImageCount)) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testMissingImageFileThrowsMissingImages() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 10)
        try writeJPEG(at: dataset.appendingPathComponent("images/b.jpg"), value: 220)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: ["images/a.jpg", "images/b.jpg", "images/gone.jpg"]
        )

        await assertThrows(.missingImages(missing: 1, total: 3)) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testDuplicateImageBytesThrowDuplicateImages() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let original = try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 90)
        try FileManager.default.copyItem(
            at: original,
            to: dataset.appendingPathComponent("images/b.jpg")
        )
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: ["images/a.jpg", "images/b.jpg"]
        )

        await assertThrows(.duplicateImages(count: 1)) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testRotatedImageThrowsRotatedImages() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 10)
        try writeRotatedJPEG(at: dataset.appendingPathComponent("images/b.jpg"), orientation: 6)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: ["images/a.jpg", "images/b.jpg"]
        )

        await assertThrows(.rotatedImages(count: 1)) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testOversizedImageThrowsImageTooLarge() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 10)
        let oversized = RunPlanResolver.maximumDatasetImagePixelDimension + 1
        try writeGrayJPEG(
            at: dataset.appendingPathComponent("images/b.jpg"),
            width: oversized,
            height: 8
        )
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: ["images/a.jpg", "images/b.jpg"]
        )

        await assertThrows(.imageTooLarge(
            dimension: oversized,
            maximum: RunPlanResolver.maximumDatasetImagePixelDimension
        )) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testUnsupportedImageFormatThrowsBeforeStaging() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 10)
        // A HEIC-declared image resolves to a real file but is not a format the
        // pixel-preserving selected-frame contract can carry.
        try writeJPEG(at: dataset.appendingPathComponent("images/b.heic"), value: 220)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: ["images/a.jpg", "images/b.heic"]
        )

        await assertThrows(.unsupportedImageFormat) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testRawBytesNamedJpegThrowUnsupportedImageFormat() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 10)
        // A RAW payload wearing a `.jpg` name: the extension is importable, but
        // the raster magic bytes are not JPEG, so it must die at preflight before
        // photo admission could silently develop it into a real JPEG.
        let rawNamedJpeg = dataset.appendingPathComponent("images/b.jpg")
        try TestFileBuilder.createDirectory(rawNamedJpeg.deletingLastPathComponent())
        try TestFileBuilder.writeMinimalRawDNG(to: rawNamedJpeg)
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: ["images/a.jpg", "images/b.jpg"]
        )

        await assertThrows(.unsupportedImageFormat) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testImageDimensionMismatchThrowsCalibrationMismatch() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        // The seed cameras describe an 8x8 grid, but this image is 16x16: the
        // poses reference a different image than the one on disk.
        try writeJPEG(at: dataset.appendingPathComponent("images/a.jpg"), value: 10)
        try writeGrayJPEG(
            at: dataset.appendingPathComponent("images/b.jpg"),
            width: 16,
            height: 16
        )
        try writeTransformsJSON(
            at: dataset.appendingPathComponent("transforms.json"),
            framePaths: ["images/a.jpg", "images/b.jpg"],
            width: 8,
            height: 8
        )

        await assertThrows(.calibrationMismatch(
            image: "images/b.jpg",
            width: 16,
            height: 16,
            expectedWidth: 8,
            expectedHeight: 8
        )) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testMissingSourceFolderThrowsUnreadableDataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        await assertThrows(.unreadableDataset) {
            _ = try await self.prepare(
                source: root.appendingPathComponent("absent", isDirectory: true),
                kind: .colmap,
                stagingParent: root
            )
        }
    }

    func testNerfstudioFolderWithoutTransformsThrowsUnreadableDataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try TestFileBuilder.createDirectory(dataset)

        await assertThrows(.unreadableDataset) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }

    func testTrainOnlyNerfstudioFolderIsNotAcceptedAsDataset() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try TestFileBuilder.createDirectory(dataset)
        try TestFileBuilder.createTextFile(
            at: dataset.appendingPathComponent("transforms_train.json"),
            text: "{}"
        )

        await assertThrows(.unreadableDataset) {
            _ = try await self.prepare(source: dataset, kind: .nerfstudio, stagingParent: root)
        }
    }
}
