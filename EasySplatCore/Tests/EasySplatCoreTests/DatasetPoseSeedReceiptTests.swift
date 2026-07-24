import Darwin
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class DatasetPoseSeedReceiptTests: XCTestCase {
    // MARK: - Fixtures

    private func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
        let project = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try FileManager.default.createDirectory(at: paths.importSeedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.importSourceURL, withIntermediateDirectories: true)
        return (root, paths)
    }

    private func writeControlledFile(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    /// Writes the three seed files and three source metadata files, returning the
    /// source project-relative paths for the builder.
    @discardableResult
    private func writeSeedAndSource(paths: ProjectPaths) throws -> [String] {
        try writeControlledFile(
            at: paths.importSeedURL.appendingPathComponent("cameras.txt"),
            contents: "# camera model\n1 PINHOLE 640 480 500 500 320 240\n"
        )
        try writeControlledFile(
            at: paths.importSeedURL.appendingPathComponent("images.txt"),
            contents: "# posed images\n1 1 0 0 0 0 0 0 1 frame_0001.jpg\n"
        )
        try writeControlledFile(
            at: paths.importSeedURL.appendingPathComponent("points3D.txt"),
            contents: "# sparse points\n1 0 0 0 255 255 255 0\n"
        )
        try writeControlledFile(
            at: paths.importSourceURL.appendingPathComponent("cameras.txt"),
            contents: "original cameras metadata\n"
        )
        try writeControlledFile(
            at: paths.importSourceURL.appendingPathComponent("images.txt"),
            contents: "original images metadata\n"
        )
        try writeControlledFile(
            at: paths.importSourceURL.appendingPathComponent("points3D.txt"),
            contents: "original points metadata\n"
        )
        return [
            "Import/source/cameras.txt",
            "Import/source/images.txt",
            "Import/source/points3D.txt",
        ]
    }

    private func makeEntries() -> [DatasetReceiptEntry] {
        [
            DatasetReceiptEntry(
                entryID: "images/frame_0001.jpg",
                declaredPath: "images/frame_0001.jpg",
                adoptedFileName: "photo-0000.jpg",
                sourceSHA256: String(repeating: "a", count: 64)
            ),
            DatasetReceiptEntry(
                entryID: "images/frame_0002.jpg",
                declaredPath: "images/frame_0002.jpg",
                adoptedFileName: "photo-0001.jpg",
                sourceSHA256: String(repeating: "b", count: 64)
            ),
        ]
    }

    private func buildReceipt(paths: ProjectPaths) throws -> DatasetPoseSeedReceipt {
        let sourceRelativePaths = try writeSeedAndSource(paths: paths)
        return try DatasetPoseSeedReceipt.build(
            kind: .colmap,
            route: .adoptDirect,
            entries: makeEntries(),
            sourceRelativePaths: sourceRelativePaths,
            projectRoot: paths.root
        )
    }

    /// Structurally valid receipt built without touching disk, for pure metadata checks.
    private func detachedReceipt(
        seedFiles: [DatasetReceiptFile]? = nil,
        sourceFiles: [DatasetReceiptFile]? = nil,
        entries: [DatasetReceiptEntry]? = nil,
        imageCount: Int? = nil
    ) -> DatasetPoseSeedReceipt {
        let resolvedEntries = entries ?? makeEntries()
        let seeds = seedFiles ?? DatasetPoseSeedReceipt.seedFileRelativePaths.map {
            DatasetReceiptFile(projectRelativePath: $0, byteCount: 32, sha256: String(repeating: "c", count: 64))
        }
        let sources = sourceFiles ?? [
            DatasetReceiptFile(
                projectRelativePath: "Import/source/cameras.txt",
                byteCount: 16,
                sha256: String(repeating: "d", count: 64)
            )
        ]
        return DatasetPoseSeedReceipt(
            kind: .colmap,
            route: .adoptDirect,
            seedFiles: seeds,
            sourceFiles: sources,
            entries: resolvedEntries,
            imageCount: imageCount ?? resolvedEntries.count
        )
    }

    // MARK: - Round-trip + happy path

    func testBuilderProducesRoundTrippableReceiptThatValidates() throws {
        let (root, paths) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try buildReceipt(paths: paths)

        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.kind, .colmap)
        XCTAssertEqual(receipt.route, .adoptDirect)
        XCTAssertEqual(receipt.imageCount, 2)
        XCTAssertEqual(receipt.seedFiles.count, 3)
        XCTAssertEqual(receipt.sourceFiles.count, 3)
        XCTAssertEqual(
            Set(receipt.seedFiles.map(\.projectRelativePath)),
            Set(DatasetPoseSeedReceipt.seedFileRelativePaths)
        )
        XCTAssertTrue(receipt.seedFiles.allSatisfy { $0.byteCount > 0 })
        XCTAssertTrue(receipt.seedFiles.allSatisfy { GeometryArtifactStore.isSHA256($0.sha256) })

        let decoded = try JSONDecoder().decode(
            DatasetPoseSeedReceipt.self,
            from: JSONEncoder().encode(receipt)
        )
        XCTAssertEqual(decoded, receipt)

        XCTAssertNoThrow(try DatasetPoseSeedReceiptValidator.validateMetadata(receipt))
        XCTAssertNoThrow(try DatasetPoseSeedReceiptValidator.validateFiles(
            receipt: receipt,
            projectRoot: paths.root
        ))
    }

    // MARK: - File-level tampering

    func testValidatorDetectsSeedByteFlip() throws {
        let (root, paths) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try buildReceipt(paths: paths)

        let cameras = paths.importSeedURL.appendingPathComponent("cameras.txt")
        let original = try String(contentsOf: cameras, encoding: .utf8)
        var flipped = Array(original)
        flipped[flipped.count - 1] = flipped.last == "X" ? "Y" : "X"
        try writeControlledFile(at: cameras, contents: String(flipped))
        XCTAssertEqual(String(flipped).utf8.count, original.utf8.count)

        assertFilesThrow(receipt, projectRoot: paths.root, .digestMismatch(path: "Import/seed/cameras.txt"))
    }

    func testValidatorDetectsTruncatedSeedFile() throws {
        let (root, paths) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try buildReceipt(paths: paths)

        try writeControlledFile(
            at: paths.importSeedURL.appendingPathComponent("images.txt"),
            contents: "x"
        )

        assertFilesThrow(receipt, projectRoot: paths.root, .sizeMismatch(path: "Import/seed/images.txt"))
    }

    func testValidatorDetectsDeletedSeedFile() throws {
        let (root, paths) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try buildReceipt(paths: paths)

        try FileManager.default.removeItem(
            at: paths.importSeedURL.appendingPathComponent("points3D.txt")
        )

        assertFilesThrow(receipt, projectRoot: paths.root, .fileUnavailable(path: "Import/seed/points3D.txt"))
    }

    func testValidatorDetectsSymlinkedSeedFile() throws {
        let (root, paths) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try buildReceipt(paths: paths)

        let cameras = paths.importSeedURL.appendingPathComponent("cameras.txt")
        let decoy = paths.importSourceURL.appendingPathComponent("cameras.txt")
        try FileManager.default.removeItem(at: cameras)
        try FileManager.default.createSymbolicLink(at: cameras, withDestinationURL: decoy)

        assertFilesThrow(receipt, projectRoot: paths.root, .fileUnavailable(path: "Import/seed/cameras.txt"))
    }

    func testValidatorDetectsSourceMetadataTampering() throws {
        let (root, paths) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try buildReceipt(paths: paths)

        let source = paths.importSourceURL.appendingPathComponent("cameras.txt")
        let original = try String(contentsOf: source, encoding: .utf8)
        var flipped = Array(original)
        flipped[0] = flipped.first == "Z" ? "z" : "Z"
        try writeControlledFile(at: source, contents: String(flipped))

        assertFilesThrow(receipt, projectRoot: paths.root, .digestMismatch(path: "Import/source/cameras.txt"))
    }

    // MARK: - Metadata tampering

    func testValidatorRejectsDuplicateEntryID() throws {
        let duplicated = [
            DatasetReceiptEntry(
                entryID: "images/frame_0001.jpg",
                declaredPath: "images/frame_0001.jpg",
                adoptedFileName: "photo-0000.jpg",
                sourceSHA256: String(repeating: "a", count: 64)
            ),
            DatasetReceiptEntry(
                entryID: "images/frame_0001.jpg",
                declaredPath: "images/frame_0002.jpg",
                adoptedFileName: "photo-0001.jpg",
                sourceSHA256: String(repeating: "b", count: 64)
            ),
        ]
        assertMetadataThrows(detachedReceipt(entries: duplicated), .duplicateEntryID(index: 1))
    }

    func testValidatorRejectsDuplicateAdoptedFileName() throws {
        let duplicated = [
            DatasetReceiptEntry(
                entryID: "images/frame_0001.jpg",
                declaredPath: "images/frame_0001.jpg",
                adoptedFileName: "photo-0000.jpg",
                sourceSHA256: String(repeating: "a", count: 64)
            ),
            DatasetReceiptEntry(
                entryID: "images/frame_0002.jpg",
                declaredPath: "images/frame_0002.jpg",
                adoptedFileName: "photo-0000.jpg",
                sourceSHA256: String(repeating: "b", count: 64)
            ),
        ]
        assertMetadataThrows(detachedReceipt(entries: duplicated), .duplicateAdoptedFileName(index: 1))
    }

    func testValidatorRejectsImageCountMismatch() throws {
        assertMetadataThrows(
            detachedReceipt(imageCount: 5),
            .imageCountMismatch(declared: 5, actual: 2)
        )
    }

    func testValidatorRejectsPathWithParentTraversal() throws {
        let escaping = [
            DatasetReceiptFile(
                projectRelativePath: "Import/source/../escape.txt",
                byteCount: 16,
                sha256: String(repeating: "d", count: 64)
            )
        ]
        assertMetadataThrows(
            detachedReceipt(sourceFiles: escaping),
            .unsafePath("Import/source/../escape.txt")
        )
    }

    func testValidatorRejectsUnsupportedSchemaVersion() throws {
        let receipt = DatasetPoseSeedReceipt(
            schemaVersion: 2,
            kind: .colmap,
            route: .adoptDirect,
            seedFiles: DatasetPoseSeedReceipt.seedFileRelativePaths.map {
                DatasetReceiptFile(projectRelativePath: $0, byteCount: 32, sha256: String(repeating: "c", count: 64))
            },
            sourceFiles: [],
            entries: makeEntries(),
            imageCount: 2
        )
        assertMetadataThrows(receipt, .unsupportedSchemaVersion(2))
    }

    func testValidatorRejectsIncompleteSeedManifest() throws {
        let onlyTwo = Array(DatasetPoseSeedReceipt.seedFileRelativePaths.prefix(2)).map {
            DatasetReceiptFile(projectRelativePath: $0, byteCount: 32, sha256: String(repeating: "c", count: 64))
        }
        assertMetadataThrows(detachedReceipt(seedFiles: onlyTwo), .invalidSeedManifest)
    }

    func testValidatorRejectsEmptyEntries() throws {
        assertMetadataThrows(detachedReceipt(entries: [], imageCount: 0), .noEntries)
    }

    // MARK: - Entry closure

    private func makeClosureEvidence(sourceSHA256: String) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: sourceSHA256,
            spatialDescriptor: [UInt8](
                repeating: 0,
                count: PhotoAnalysisEvidence.spatialDescriptorLength
            ),
            qualityBucket: 200,
            dHash: 0,
            proxyPixelWidth: 16,
            proxyPixelHeight: 12,
            proxyPixelSHA256: String(repeating: "e", count: 64),
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256
        )
    }

    private func makeClosurePhotoReceipt(
        leaf: String,
        sha256: String,
        rank: Int
    ) -> PhotoInputReceipt {
        PhotoInputReceipt(
            projectRelativePath: "Originals/Photos/\(leaf)",
            safeDisplayName: leaf,
            byteCount: 100,
            sha256: sha256,
            pixelWidth: 640,
            pixelHeight: 480,
            orientation: 1,
            typeIdentifier: UTType.jpeg.identifier,
            analysisEvidence: makeClosureEvidence(sourceSHA256: sha256),
            retainedRank: rank
        )
    }

    /// Two receipts whose (source digest, leaf) pairs match `makeEntries()`.
    private func matchingClosurePhotoReceipts() -> [PhotoInputReceipt] {
        [
            makeClosurePhotoReceipt(
                leaf: "photo-0000.jpg",
                sha256: String(repeating: "a", count: 64),
                rank: 0
            ),
            makeClosurePhotoReceipt(
                leaf: "photo-0001.jpg",
                sha256: String(repeating: "b", count: 64),
                rank: 1
            ),
        ]
    }

    private func closureSeedModel(names: [String]) -> ColmapTextModel {
        ColmapTextModel(
            cameras: [
                ColmapTextCamera(
                    id: 1,
                    model: "PINHOLE",
                    width: 640,
                    height: 480,
                    parameters: [500, 500, 320, 240]
                )
            ],
            images: names.enumerated().map { index, name in
                ColmapTextImage(
                    id: index + 1,
                    pose: DatasetPoseConvention.ColmapPose(
                        qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 0, tz: 0
                    ),
                    cameraID: 1,
                    name: name
                )
            }
        )
    }

    /// A seed model whose image NAMEs match `makeEntries()` declared paths.
    private func matchingClosureSeedModel() -> ColmapTextModel {
        closureSeedModel(names: ["images/frame_0001.jpg", "images/frame_0002.jpg"])
    }

    func testValidateClosureAcceptsMatchingEntriesPhotosAndSeed() {
        XCTAssertNoThrow(try DatasetPoseSeedReceiptValidator.validateClosure(
            receipt: detachedReceipt(),
            photoReceipts: matchingClosurePhotoReceipts(),
            seedModel: matchingClosureSeedModel()
        ))
    }

    func testValidateClosureRejectsSwappedEntryDigests() {
        // Exchanging two entries' source digests keeps every digest present but
        // breaks each digest's pairing with its recorded adopted file name.
        let swapped = [
            DatasetReceiptEntry(
                entryID: "images/frame_0001.jpg",
                declaredPath: "images/frame_0001.jpg",
                adoptedFileName: "photo-0000.jpg",
                sourceSHA256: String(repeating: "b", count: 64)
            ),
            DatasetReceiptEntry(
                entryID: "images/frame_0002.jpg",
                declaredPath: "images/frame_0002.jpg",
                adoptedFileName: "photo-0001.jpg",
                sourceSHA256: String(repeating: "a", count: 64)
            ),
        ]
        assertClosureThrows(
            detachedReceipt(entries: swapped),
            photoReceipts: matchingClosurePhotoReceipts(),
            seedModel: matchingClosureSeedModel(),
            .photoReceiptClosureMismatch
        )
    }

    func testValidateClosureRejectsUnconsumedPhotoReceipt() {
        let extra = matchingClosurePhotoReceipts() + [
            makeClosurePhotoReceipt(
                leaf: "photo-0002.jpg",
                sha256: String(repeating: "c", count: 64),
                rank: 2
            )
        ]
        assertClosureThrows(
            detachedReceipt(),
            photoReceipts: extra,
            seedModel: matchingClosureSeedModel(),
            .photoReceiptClosureMismatch
        )
    }

    func testValidateClosureRejectsSeedImageMismatch() {
        assertClosureThrows(
            detachedReceipt(),
            photoReceipts: matchingClosurePhotoReceipts(),
            seedModel: closureSeedModel(
                names: ["images/frame_0001.jpg", "images/frame_9999.jpg"]
            ),
            .seedImageClosureMismatch
        )
    }

    private func assertClosureThrows(
        _ receipt: DatasetPoseSeedReceipt,
        photoReceipts: [PhotoInputReceipt],
        seedModel: ColmapTextModel,
        _ expected: DatasetPoseSeedReceiptValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DatasetPoseSeedReceiptValidator.validateClosure(
                receipt: receipt,
                photoReceipts: photoReceipts,
                seedModel: seedModel
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DatasetPoseSeedReceiptValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    // MARK: - Helpers

    private func assertMetadataThrows(
        _ receipt: DatasetPoseSeedReceipt,
        _ expected: DatasetPoseSeedReceiptValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DatasetPoseSeedReceiptValidator.validateMetadata(receipt),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DatasetPoseSeedReceiptValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func assertFilesThrow(
        _ receipt: DatasetPoseSeedReceipt,
        projectRoot: URL,
        _ expected: DatasetPoseSeedReceiptValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DatasetPoseSeedReceiptValidator.validateFiles(receipt: receipt, projectRoot: projectRoot),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DatasetPoseSeedReceiptValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
