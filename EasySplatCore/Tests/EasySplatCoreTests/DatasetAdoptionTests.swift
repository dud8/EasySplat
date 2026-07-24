import Foundation
import XCTest
@testable import EasySplatCore

final class DatasetAdoptionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let paths: ProjectPaths
        let preparedDataset: PreparedDatasetInput
        let preparedPhotos: PreparedPhotoInput
        var adoption: ProjectInputAdoption
    }

    // MARK: - Fixtures

    private var identityMatrix: [[Double]] {
        [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    }

    private func makeNerfstudioDataset(in root: URL) throws -> URL {
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        let framePaths = ["images/frame_0001.jpg", "images/frame_0002.jpg", "images/frame_0003.jpg"]
        for (index, path) in framePaths.enumerated() {
            let url = dataset.appendingPathComponent(path)
            try TestFileBuilder.createDirectory(url.deletingLastPathComponent())
            guard try TestFileBuilder.writeGrayscaleImage(
                url: url,
                size: 8,
                value: UInt8(40 + index * 60),
                utType: .jpeg
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let object: [String: Any] = [
            "camera_model": "PINHOLE",
            "fl_x": 500.0, "fl_y": 500.0, "cx": 4.0, "cy": 4.0,
            "w": 8, "h": 8,
            "frames": framePaths.map {
                ["file_path": $0, "transform_matrix": identityMatrix]
            },
        ]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: dataset.appendingPathComponent("transforms.json"))
        return dataset
    }

    /// Runs the full dataset flow into a fresh bundle: dataset preflight, photo admission
    /// over the staged images, and `adoptDataset`.
    private func makeAdoptedFixture() async throws -> Fixture {
        let root = try TestFileBuilder.makeTempDir()
        let dataset = try makeNerfstudioDataset(in: root)
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try TestFileBuilder.createDirectory(library)

        let preparedDataset = try await DatasetInputPreflight.prepare(
            source: dataset,
            isZip: false,
            kind: .nerfstudio,
            stagingParent: library,
            runner: SubprocessRunner()
        )
        let preparedPhotos = try await PhotoInputPreflight.prepare(
            photos: preparedDataset.stagedImages.map(\.url),
            stagingParent: library,
            photoSelection: .useAllValidPhotos,
            inputOrdering: .unordered,
            keyframeBudget: RunPlanResolver.maximumDatasetImageCount,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            progress: { _, _ in }
        )

        let project = library.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = ProjectPaths(root: project)
        var adoption = ProjectInputAdoption(
            requestedInput: .dataset(kind: .nerfstudio, imagesFolder: dataset.path)
        )
        try adoption.adoptDataset(preparedDataset, into: paths, photoInput: preparedPhotos)
        return Fixture(
            root: root,
            paths: paths,
            preparedDataset: preparedDataset,
            preparedPhotos: preparedPhotos,
            adoption: adoption
        )
    }

    private func discard(_ fixture: Fixture) {
        fixture.preparedPhotos.discard()
        fixture.preparedDataset.discard()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    // MARK: - Adoption

    func testAdoptDatasetProducesReceiptsSeedAndRewritesInput() async throws {
        let fixture = try await makeAdoptedFixture()
        defer { discard(fixture) }
        let adoption = fixture.adoption
        let paths = fixture.paths

        // Every staged image was admitted through the photo machinery.
        let photoReceipts = try XCTUnwrap(adoption.photoInputReceipts)
        XCTAssertEqual(photoReceipts.count, 3)
        XCTAssertNotNil(adoption.photoSelectionReceipt)
        for receipt in photoReceipts {
            XCTAssertTrue(receipt.projectRelativePath.hasPrefix("Originals/Photos/"))
        }

        // The input now points at the controlled folder, still as a dataset.
        guard case .dataset(let kind, let imagesFolder) = adoption.input else {
            return XCTFail("Expected a dataset input, got \(adoption.input)")
        }
        XCTAssertEqual(kind, .nerfstudio)
        XCTAssertEqual(imagesFolder, "Originals/Photos")

        // The receipt binds seed, source, and the entry-to-adopted-file mapping,
        // and verifies bit-for-bit against the bundle.
        let receipt = try XCTUnwrap(adoption.datasetPoseSeed)
        XCTAssertEqual(receipt.kind, .nerfstudio)
        XCTAssertEqual(receipt.route, .seedTriangulate)
        XCTAssertEqual(receipt.imageCount, 3)
        XCTAssertNoThrow(try DatasetPoseSeedReceiptValidator.validateFiles(
            receipt: receipt,
            projectRoot: paths.root
        ))
        for relativePath in DatasetPoseSeedReceipt.seedFileRelativePaths {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: paths.root.appendingPathComponent(relativePath).path
            ))
        }
        XCTAssertEqual(
            receipt.sourceFiles.map(\.projectRelativePath),
            ["Import/source/transforms.json"]
        )

        // Each entry maps its declared image to the controlled file it became.
        XCTAssertEqual(
            receipt.entries.map(\.entryID),
            fixture.preparedDataset.stagedImages.map(\.entryID)
        )
        let receiptByDigest = Dictionary(
            uniqueKeysWithValues: photoReceipts.map { ($0.source.sha256, $0) }
        )
        for entry in receipt.entries {
            let photoReceipt = try XCTUnwrap(receiptByDigest[entry.sourceSHA256])
            XCTAssertEqual(
                entry.adoptedFileName,
                (photoReceipt.projectRelativePath as NSString).lastPathComponent
            )
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: paths.importedPhotosURL.appendingPathComponent(entry.adoptedFileName).path
            ))
        }
    }

    func testAdoptDatasetTwiceThrowsAlreadyAdopted() async throws {
        var fixture = try await makeAdoptedFixture()
        defer { discard(fixture) }

        XCTAssertThrowsError(try fixture.adoption.adoptDataset(
            fixture.preparedDataset,
            into: fixture.paths,
            photoInput: fixture.preparedPhotos
        )) { error in
            XCTAssertEqual(
                error as? ProjectInputAdoptionError,
                .datasetInputAlreadyAdopted
            )
        }
    }

    func testAdoptDatasetRejectsNonDatasetInput() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try makeNerfstudioDataset(in: root)
        let prepared = try await DatasetInputPreflight.prepare(
            source: dataset,
            isZip: false,
            kind: .nerfstudio,
            stagingParent: root,
            runner: SubprocessRunner()
        )
        defer { prepared.discard() }
        let preparedPhotos = try await PhotoInputPreflight.prepare(
            photos: prepared.stagedImages.map(\.url),
            stagingParent: root,
            photoSelection: .useAllValidPhotos,
            inputOrdering: .unordered,
            keyframeBudget: 10,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { preparedPhotos.discard() }
        let project = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var adoption = ProjectInputAdoption(requestedInput: .photos(folder: dataset.path))
        XCTAssertThrowsError(try adoption.adoptDataset(
            prepared,
            into: ProjectPaths(root: project),
            photoInput: preparedPhotos
        )) { error in
            XCTAssertEqual(
                error as? ProjectInputAdoptionError,
                .unexpectedDatasetInput
            )
        }
    }

    // MARK: - Metadata store wiring

    private func metadata(from fixture: Fixture, title: String) -> ProjectMetadata {
        ProjectMetadata(
            title: title,
            input: fixture.adoption.input,
            photoInputReceipts: fixture.adoption.photoInputReceipts,
            photoSelectionReceipt: fixture.adoption.photoSelectionReceipt,
            datasetPoseSeed: fixture.adoption.datasetPoseSeed
        )
    }

    func testMetadataStoreRoundTripsDatasetReceipt() async throws {
        let fixture = try await makeAdoptedFixture()
        defer { discard(fixture) }
        let url = fixture.paths.metadataURL

        try ProjectMetadataStore.save(metadata(from: fixture, title: "Dataset"), to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.datasetPoseSeed, fixture.adoption.datasetPoseSeed)
        XCTAssertEqual(loaded.photoInputReceipts?.count, 3)
        guard case .dataset(let kind, let imagesFolder) = loaded.input else {
            return XCTFail("Expected a dataset input, got \(loaded.input)")
        }
        XCTAssertEqual(kind, .nerfstudio)
        XCTAssertEqual(imagesFolder, "Originals/Photos")
    }

    func testDatasetInputWithoutReceiptFailsSaveAndLoad() async throws {
        let fixture = try await makeAdoptedFixture()
        defer { discard(fixture) }
        var stripped = metadata(from: fixture, title: "No receipt")
        stripped.datasetPoseSeed = nil
        let url = fixture.paths.metadataURL

        XCTAssertThrowsError(try ProjectMetadataStore.save(stripped, to: url)) { error in
            XCTAssertEqual(
                error as? DatasetPoseSeedReceiptValidationError,
                .missingReceipt
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stripped).write(to: url, options: .atomic)
        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            XCTAssertEqual(
                error as? DatasetPoseSeedReceiptValidationError,
                .missingReceipt
            )
        }
    }

    func testReceiptWithoutDatasetInputFailsSaveAndLoad() async throws {
        let fixture = try await makeAdoptedFixture()
        defer { discard(fixture) }
        var mismatched = metadata(from: fixture, title: "Orphan receipt")
        mismatched.input = .photos(folder: "Originals/Photos")
        let url = fixture.paths.metadataURL

        XCTAssertThrowsError(try ProjectMetadataStore.save(mismatched, to: url)) { error in
            XCTAssertEqual(
                error as? DatasetPoseSeedReceiptValidationError,
                .unexpectedReceipt
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(mismatched).write(to: url, options: .atomic)
        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            XCTAssertEqual(
                error as? DatasetPoseSeedReceiptValidationError,
                .unexpectedReceipt
            )
        }
    }
}
