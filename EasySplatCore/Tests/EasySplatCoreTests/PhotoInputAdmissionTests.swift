import Darwin
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class PhotoInputAdmissionTests: XCTestCase {
    private func posixMode(of url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return status.st_mode & mode_t(0o7777)
    }

    func testRawAdmissionUsesPrivateSnapshotAndRetainsOnlyDevelopedPNG() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let raw = source.appendingPathComponent("DSC_0042.dng")
        try Data(repeating: 0x42, count: 4_096).write(to: raw)
        let sourceDigest = try GeometryArtifactStore.sha256(of: raw)
        let decoder = MockRawPhotoDecoder { staged, maximumProxyDimension in
            XCTAssertNotEqual(staged.standardizedFileURL, raw.standardizedFileURL)
            var status = stat()
            XCTAssertEqual(lstat(staged.path, &status), 0)
            XCTAssertEqual(status.st_mode & mode_t(0o7777), 0o600)
            XCTAssertLessThanOrEqual(maximumProxyDimension, 4_096)
            return RawPhotoInspection(
                decoderVersion: "9",
                nativeDimensions: RawPixelDimensions(width: 6_000, height: 4_000),
                sourceOrientation: 6,
                proxySHA256: String(repeating: "c", count: 64),
                analysisMeasurements: mockPhotoAnalysisMeasurements(0x0c),
                companionEvidence: nil
            )
        } develop: { staged, destination, maximumPixelDimension in
            XCTAssertNotEqual(staged.standardizedFileURL, raw.standardizedFileURL)
            try writeTaggedRGBPNG(at: destination, width: 32, height: 48)
            return RawPhotoDevelopment(
                evidence: RawDevelopmentEvidence(
                    decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                    decoderVersion: "9",
                    settings: .production(maximumPixelDimension: maximumPixelDimension),
                    nativePixelWidth: 6_000,
                    nativePixelHeight: 4_000,
                    sourceOrientation: 6
                ),
                controlledDimensions: RawPixelDimensions(width: 32, height: 48)
            )
        }

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 10,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            contentTypeResolver: { _ in UTType.rawImage.identifier },
            rawDecoder: decoder,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        let photo = try XCTUnwrap(prepared.photos.first)
        XCTAssertEqual(photo.stagedURL.pathExtension, "png")
        XCTAssertEqual(photo.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(photo.pixelWidth, 32)
        XCTAssertEqual(photo.pixelHeight, 48)
        XCTAssertEqual(photo.orientation, 1)
        XCTAssertEqual(photo.sha256, try GeometryArtifactStore.sha256(of: photo.stagedURL))
        XCTAssertEqual(
            photo.byteCount,
            try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: photo.stagedURL.path)[.size]
                    as? NSNumber
            ).int64Value
        )
        XCTAssertEqual(photo.source.sha256, sourceDigest)
        XCTAssertEqual(photo.source.typeIdentifier, UTType.rawImage.identifier)
        guard case .rawDevelopment = photo.importMode else {
            return XCTFail("Expected RAW development provenance.")
        }
        XCTAssertFalse(prepared.photos.contains { $0.stagedURL.pathExtension == "dng" })
    }

    func testPhotoListAdmissionMergesFilesFromMultipleFolders() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let folderA = root.appendingPathComponent("ShootA", isDirectory: true)
        let folderB = root.appendingPathComponent("ShootB", isDirectory: true)
        for dir in [library, folderA, folderB] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var photos: [URL] = []
        for (folderIndex, folder) in [folderA, folderB].enumerated() {
            for offset in 0..<2 {
                let url = folder.appendingPathComponent("shot-\(folderIndex)-\(offset).png")
                try writeTaggedRGBPNG(at: url, width: 24 + folderIndex * 4 + offset, height: 32 + offset)
                photos.append(url)
            }
        }

        let prepared = try await PhotoInputPreflight.prepare(
            photos: photos,
            stagingParent: library,
            photoSelection: .useAllValidPhotos,
            inputOrdering: .automatic,
            keyframeBudget: 10,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.summary.validPhotoCount, 4, "Photos from both folders should be admitted.")
        XCTAssertEqual(prepared.photos.count, 4)
    }

    func testPhotoListAdmissionRejectsSymbolicLink() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let real = source.appendingPathComponent("real.png")
        try writeTaggedRGBPNG(at: real, width: 24, height: 24)
        let link = source.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        await XCTAssertThrowsErrorAsync {
            _ = try await PhotoInputPreflight.prepare(
                photos: [link],
                stagingParent: library,
                photoSelection: .useAllValidPhotos,
                inputOrdering: .automatic,
                keyframeBudget: 10,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in 128 * 1_024 * 1_024 },
                progress: { _, _ in }
            )
        } errorHandler: { error in
            guard let failure = error as? PhotoInputPreflightFailure,
                  case .symbolicLink = failure.issue else {
                return XCTFail("Expected a symbolic-link rejection, got \(error)")
            }
        }
    }

    func testRawAdmissionDeduplicatesOriginalsButAllowsIdenticalDevelopedPNGs() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let first = source.appendingPathComponent("capture-a.dng")
        let exactDuplicate = source.appendingPathComponent("capture-a-copy.dng")
        let distinct = source.appendingPathComponent("capture-b.dng")
        try Data(repeating: 0x41, count: 4_096).write(to: first)
        try FileManager.default.copyItem(at: first, to: exactDuplicate)
        try Data(repeating: 0x42, count: 4_096).write(to: distinct)
        let firstSourceSHA256 = try GeometryArtifactStore.sha256(of: first)

        let decoder = MockRawPhotoDecoder { staged, _ in
            let sourceSHA256 = try GeometryArtifactStore.sha256(of: staged)
            return RawPhotoInspection(
                decoderVersion: "9",
                nativeDimensions: RawPixelDimensions(width: 64, height: 48),
                sourceOrientation: 1,
                proxySHA256: String(repeating: "c", count: 64),
                analysisMeasurements: mockPhotoAnalysisMeasurements(
                    sourceSHA256 == firstSourceSHA256 ? 0x11 : 0x22
                ),
                companionEvidence: nil
            )
        } develop: { _, destination, maximumPixelDimension in
            try writeTaggedRGBPNG(at: destination, width: 32, height: 24)
            return RawPhotoDevelopment(
                evidence: RawDevelopmentEvidence(
                    decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                    decoderVersion: "9",
                    settings: .production(maximumPixelDimension: maximumPixelDimension),
                    nativePixelWidth: 64,
                    nativePixelHeight: 48,
                    sourceOrientation: 1
                ),
                controlledDimensions: RawPixelDimensions(width: 32, height: 24)
            )
        }

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .useAllValidPhotos,
            inputOrdering: .unordered,
            keyframeBudget: 3,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            contentTypeResolver: { _ in UTType.rawImage.identifier },
            rawDecoder: decoder,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.summary.discoveredPhotoCount, 3)
        XCTAssertEqual(prepared.summary.validPhotoCount, 2)
        XCTAssertEqual(prepared.summary.duplicatePhotoCount, 1)
        XCTAssertEqual(Set(prepared.photos.map(\.source.sha256)).count, 2)
        XCTAssertEqual(Set(prepared.photos.map(\.sha256)).count, 1)

        let project = library.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = ProjectPaths(root: project)
        var adoption = ProjectInputAdoption(requestedInput: .photos(folder: source.path))
        try adoption.adoptPhotos(prepared, into: paths)
        let receipts = try XCTUnwrap(adoption.photoInputReceipts)
        XCTAssertEqual(Set(receipts.map(\.source.sha256)).count, 2)
        XCTAssertEqual(Set(receipts.map(\.sha256)).count, 1)
        XCTAssertEqual(Set(receipts.map(\.projectRelativePath)).count, 2)
        XCTAssertEqual(Set(receipts.map(\.retainedRank)), Set(0..<2))

        let options = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: adoption.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let metadata = ProjectMetadata(
            title: "RAW collision",
            input: adoption.input,
            photoInputReceipts: receipts,
            photoSelectionReceipt: adoption.photoSelectionReceipt,
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )

        XCTAssertNoThrow(try PhotoInputReceiptValidator.validateFiles(
            metadata: metadata,
            paths: paths
        ))
    }

    func testRawAdmissionRejectsInvalidDevelopedOutput() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 1_024).write(to: source.appendingPathComponent("capture.raw"))
        let decoder = MockRawPhotoDecoder { _, _ in
            RawPhotoInspection(
                decoderVersion: "9",
                nativeDimensions: RawPixelDimensions(width: 100, height: 80),
                sourceOrientation: 1,
                proxySHA256: String(repeating: "d", count: 64),
                analysisMeasurements: mockPhotoAnalysisMeasurements(0x0d),
                companionEvidence: nil
            )
        } develop: { _, destination, maximumPixelDimension in
            try Data("not a png".utf8).write(to: destination)
            return RawPhotoDevelopment(
                evidence: RawDevelopmentEvidence(
                    decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                    decoderVersion: "9",
                    settings: .production(maximumPixelDimension: maximumPixelDimension),
                    nativePixelWidth: 100,
                    nativePixelHeight: 80,
                    sourceOrientation: 1
                ),
                controlledDimensions: RawPixelDimensions(width: 100, height: 80)
            )
        }

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in 128 * 1_024 * 1_024 },
                contentTypeResolver: { _ in UTType.rawImage.identifier },
                rawDecoder: decoder,
                progress: { _, _ in }
            )
            XCTFail("Invalid controlled output must not be admitted.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .copyFailed(relativePath: "capture.raw"))
        }
    }

    func testRawSuffixWithJPEGContentRemainsAnUnchangedJPEG() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source.appendingPathComponent("spoofed.dng"),
            size: 16,
            value: 80,
            utType: .jpeg
        ))

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: root,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 1,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        let photo = try XCTUnwrap(prepared.photos.first)
        XCTAssertEqual(photo.typeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(photo.stagedURL.pathExtension, "jpg")
        XCTAssertEqual(photo.source.typeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(photo.importMode, .unchanged)
    }

    func testRawSuffixWithPNGContentRemainsAnUnchangedPNG() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source.appendingPathComponent("spoofed.cr3"),
            size: 16,
            value: 80,
            utType: .png
        ))

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: root,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 1,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        let photo = try XCTUnwrap(prepared.photos.first)
        XCTAssertEqual(photo.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(photo.stagedURL.pathExtension, "png")
        XCTAssertEqual(photo.source.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(photo.importMode, .unchanged)
    }

    func testInvalidBytesWithRawSuffixNeverReachRawDecoder() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("not raw image data".utf8).write(
            to: source.appendingPathComponent("spoofed.dng")
        )
        let decoder = MockRawPhotoDecoder { _, _ in
            XCTFail("Invalid bytes must not reach the RAW decoder.")
            throw RawPhotoDecodingError.unsupportedOrCorrupt
        } develop: { _, _, _ in
            XCTFail("Invalid bytes must not reach RAW development.")
            throw RawPhotoDecodingError.unsupportedOrCorrupt
        }

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in 128 * 1_024 * 1_024 },
                rawDecoder: decoder,
                progress: { _, _ in }
            )
            XCTFail("Invalid RAW-suffixed bytes must not be admitted.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .noValidPhotos)
        }
    }

    func testDefaultContentTypeResolverAdmitsDescriptorBoundDNGAsRaw() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let raw = source.appendingPathComponent("capture.dng")
        try TestFileBuilder.writeMinimalRawDNG(to: raw)
        let decoder = MockRawPhotoDecoder { _, maximumProxyDimension in
            XCTAssertLessThanOrEqual(maximumProxyDimension, 512)
            return RawPhotoInspection(
                decoderVersion: "fixture-1",
                nativeDimensions: RawPixelDimensions(width: 256, height: 256),
                sourceOrientation: 1,
                proxySHA256: String(repeating: "a", count: 64),
                analysisMeasurements: mockPhotoAnalysisMeasurements(0x0a),
                companionEvidence: nil
            )
        } develop: { _, destination, maximumPixelDimension in
            try writeTaggedRGBPNG(at: destination, width: 16, height: 16)
            return RawPhotoDevelopment(
                evidence: RawDevelopmentEvidence(
                    decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                    decoderVersion: "fixture-1",
                    settings: .production(maximumPixelDimension: maximumPixelDimension),
                    nativePixelWidth: 256,
                    nativePixelHeight: 256,
                    sourceOrientation: 1
                ),
                controlledDimensions: RawPixelDimensions(width: 16, height: 16)
            )
        }

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 1,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            rawDecoder: decoder,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        let photo = try XCTUnwrap(prepared.photos.first)
        XCTAssertEqual(photo.source.typeIdentifier, "com.adobe.raw-image")
        XCTAssertEqual(photo.typeIdentifier, UTType.png.identifier)
        guard case .rawDevelopment = photo.importMode else {
            return XCTFail("Expected the default descriptor path to retain RAW provenance.")
        }
    }

    func testRawDecoderCancellationPropagatesAndCleansStaging() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x22, count: 1_024).write(to: source.appendingPathComponent("capture.dng"))
        let decoder = MockRawPhotoDecoder { _, _ in
            throw CancellationError()
        } develop: { _, _, _ in
            throw CancellationError()
        }

        await XCTAssertThrowsErrorAsync(try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: root,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 1,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 64 * 1_024 * 1_024 },
            contentTypeResolver: { _ in UTType.rawImage.identifier },
            rawDecoder: decoder,
            progress: { _, _ in }
        ))
        let stagingContainer = root.appendingPathComponent(
            ".easysplat-photo-input-staging",
            isDirectory: true
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagingContainer.path),
            []
        )
    }

    func testRawCandidateWithOnlyAnEmbeddedThumbnailIsUnreadable() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 1_024).write(to: source.appendingPathComponent("preview-only.dng"))
        let decoder = MockRawPhotoDecoder { _, _ in
            throw RawPhotoDecodingError.unsupportedOrCorrupt
        } develop: { _, _, _ in
            throw RawPhotoDecodingError.unsupportedOrCorrupt
        }

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in 128 * 1_024 * 1_024 },
                contentTypeResolver: { _ in UTType.rawImage.identifier },
                rawDecoder: decoder,
                progress: { _, _ in }
            )
            XCTFail("Embedded preview availability must not prove RAW development.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .noValidPhotos)
        }
    }

    func testRawDecoderCannotHideExternalSourceMutation() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let raw = source.appendingPathComponent("capture.dng")
        try Data(repeating: 0x33, count: 1_024).write(to: raw)
        let decoder = MockRawPhotoDecoder { _, _ in
            try Data(repeating: 0x44, count: 2_048).write(to: raw)
            return RawPhotoInspection(
                decoderVersion: "9",
                nativeDimensions: RawPixelDimensions(width: 100, height: 80),
                sourceOrientation: 1,
                proxySHA256: String(repeating: "e", count: 64),
                analysisMeasurements: mockPhotoAnalysisMeasurements(0x0e),
                companionEvidence: nil
            )
        } develop: { _, _, _ in
            throw RawPhotoDecodingError.renderFailed
        }

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in 128 * 1_024 * 1_024 },
                contentTypeResolver: { _ in UTType.rawImage.identifier },
                rawDecoder: decoder,
                progress: { _, _ in }
            )
            XCTFail("A changed source must be rejected.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .sourceChanged(relativePath: "capture.dng"))
        }
    }

    func testSameStemRawAndJPEGWithStrongCaptureMetadataPreferRaw() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 1_024).write(to: source.appendingPathComponent("raw.dng"))
        let jpeg = source.appendingPathComponent("raw.jpg")
        let metadata = companionMetadata()
        try writeRGBJPEG(at: jpeg, properties: metadata)
        let companion = try XCTUnwrap(RawPhotoDecoder.companionEvidence(properties: metadata))
        let decoder = MockRawPhotoDecoder { _, _ in
            RawPhotoInspection(
                decoderVersion: "9",
                nativeDimensions: RawPixelDimensions(width: 100, height: 80),
                sourceOrientation: 1,
                proxySHA256: String(repeating: "f", count: 64),
                analysisMeasurements: mockPhotoAnalysisMeasurements(0x0f),
                companionEvidence: companion
            )
        } develop: { _, destination, maximumPixelDimension in
            try writeTaggedRGBPNG(at: destination, width: 100, height: 80)
            return RawPhotoDevelopment(
                evidence: RawDevelopmentEvidence(
                    decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                    decoderVersion: "9",
                    settings: .production(maximumPixelDimension: maximumPixelDimension),
                    nativePixelWidth: 100,
                    nativePixelHeight: 80,
                    sourceOrientation: 1
                ),
                controlledDimensions: RawPixelDimensions(width: 100, height: 80)
            )
        }

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: root,
            photoSelection: .useAllValidPhotos,
            inputOrdering: .continuous,
            keyframeBudget: 2,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 128 * 1_024 * 1_024 },
            contentTypeResolver: { descriptorURL in
                if (try? Data(contentsOf: descriptorURL, options: .mappedIfSafe).first) == 0x42 {
                    return UTType.rawImage.identifier
                }
                guard let source = CGImageSourceCreateWithURL(descriptorURL as CFURL, nil) else {
                    return nil
                }
                return CGImageSourceGetType(source) as String?
            },
            rawDecoder: decoder,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.summary.duplicatePhotoCount, 1)
        XCTAssertEqual(prepared.photos.count, 1)
        XCTAssertEqual(prepared.selectionArtifact.exactDuplicateCount, 0)
        XCTAssertEqual(prepared.selectionArtifact.companionDuplicateCount, 1)
        XCTAssertEqual(prepared.selectionArtifact.acceptedCount, 1)
        guard case .rawDevelopment = prepared.photos[0].importMode else {
            return XCTFail("The exact RAW companion should win.")
        }
    }

    func testCompanionPairingRejectsBurstCrossDirectoryRawRawAndConflictingUniqueID() throws {
        let capture = try XCTUnwrap(RawPhotoDecoder.companionEvidence(properties: companionMetadata()))
        let raw = RawCompanionCandidate(
            relativePath: "Burst/IMG_0042.dng",
            typeIdentifier: UTType.rawImage.identifier,
            isRaw: true,
            dimensions: RawPixelDimensions(width: 100, height: 80),
            orientation: 1,
            evidence: capture
        )
        let jpeg = RawCompanionCandidate(
            relativePath: "Burst/IMG_0042.jpg",
            typeIdentifier: UTType.jpeg.identifier,
            isRaw: false,
            dimensions: RawPixelDimensions(width: 100, height: 80),
            orientation: 1,
            evidence: capture
        )
        XCTAssertTrue(RawPhotoDecoder.areCompanions(raw, jpeg))

        XCTAssertFalse(RawPhotoDecoder.areCompanions(
            raw,
            replacing(jpeg, relativePath: "Burst/unrelated-name.jpg")
        ))
        XCTAssertFalse(RawPhotoDecoder.areCompanions(
            raw,
            replacing(jpeg, relativePath: "Burst/IMG_0043.jpg")
        ), "Coarse subsecond metadata must not merge distinct burst stems.")
        XCTAssertFalse(RawPhotoDecoder.areCompanions(
            raw,
            replacing(jpeg, relativePath: "Elsewhere/IMG_0042.jpg")
        ))
        XCTAssertFalse(RawPhotoDecoder.areCompanions(
            raw,
            replacing(jpeg, relativePath: "Burst/img_0042.jpg")
        ))
        XCTAssertFalse(RawPhotoDecoder.areCompanions(
            raw,
            RawCompanionCandidate(
                relativePath: jpeg.relativePath,
                typeIdentifier: jpeg.typeIdentifier,
                isRaw: false,
                dimensions: RawPixelDimensions(width: 99, height: 80),
                orientation: 1,
                evidence: capture
            )
        ))
        XCTAssertFalse(RawPhotoDecoder.areCompanions(
            raw,
            RawCompanionCandidate(
                relativePath: "Burst/IMG_0042.nef",
                typeIdentifier: UTType.rawImage.identifier,
                isRaw: true,
                dimensions: raw.dimensions,
                orientation: raw.orientation,
                evidence: capture
            )
        ))

        var firstID = companionMetadata()
        var firstExif = try XCTUnwrap(firstID[kCGImagePropertyExifDictionary] as? [CFString: Any])
        firstExif[kCGImagePropertyExifImageUniqueID] = "capture-a"
        firstID[kCGImagePropertyExifDictionary] = firstExif
        var secondID = companionMetadata()
        var secondExif = try XCTUnwrap(secondID[kCGImagePropertyExifDictionary] as? [CFString: Any])
        secondExif[kCGImagePropertyExifImageUniqueID] = "capture-b"
        secondID[kCGImagePropertyExifDictionary] = secondExif
        XCTAssertFalse(RawPhotoDecoder.areCompanions(
            replacing(raw, evidence: try XCTUnwrap(RawPhotoDecoder.companionEvidence(properties: firstID))),
            replacing(jpeg, evidence: try XCTUnwrap(RawPhotoDecoder.companionEvidence(properties: secondID)))
        ))
    }

    func testCompanionPairingAcceptsSameStemJPEGAndHEIFWithStrongEvidence() throws {
        var metadata = companionMetadata()
        var exif = try XCTUnwrap(metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])
        exif[kCGImagePropertyExifExposureTime] = 0.008
        exif[kCGImagePropertyExifFNumber] = 4.0
        exif[kCGImagePropertyExifISOSpeedRatings] = [200]
        exif[kCGImagePropertyExifFocalLength] = 35.0
        exif[kCGImagePropertyExifFocalLenIn35mmFilm] = 52
        exif[kCGImagePropertyExifLensModel] = "Prime 35mm"
        metadata[kCGImagePropertyExifDictionary] = exif
        let evidence = try XCTUnwrap(RawPhotoDecoder.companionEvidence(properties: metadata))
        let raw = RawCompanionCandidate(
            relativePath: "Shoot/Cafe\u{301}.dng",
            typeIdentifier: UTType.rawImage.identifier,
            isRaw: true,
            dimensions: RawPixelDimensions(width: 100, height: 80),
            orientation: 1,
            evidence: evidence
        )
        for type in [UTType.jpeg.identifier, UTType.heic.identifier, "public.heif"] {
            let rendered = RawCompanionCandidate(
                relativePath: "Shoot/Caf\u{e9}.\(type == UTType.jpeg.identifier ? "jpg" : "heic")",
                typeIdentifier: type,
                isRaw: false,
                dimensions: RawPixelDimensions(width: 100, height: 80),
                orientation: 1,
                evidence: evidence
            )
            XCTAssertTrue(RawPhotoDecoder.areCompanions(raw, rendered))
        }

        var missingCameraIdentity = metadata
        missingCameraIdentity.removeValue(forKey: kCGImagePropertyTIFFDictionary)
        XCTAssertNil(RawPhotoDecoder.companionEvidence(properties: missingCameraIdentity))
    }

    func testPrepareUsesConfiguredBoundedDecodeDimension() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source.appendingPathComponent("large.jpg"),
            size: 2_048,
            value: 80,
            utType: .jpeg
        ))

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 1,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumTotalBytes: Int64(32) * 1_024 * 1_024,
                maximumDecodedDimension: 32,
                minimumFreeSpaceReserveBytes: 0
            ),
            availableCapacity: { _ in 32 * 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.photos.count, 1)
        XCTAssertEqual(prepared.photos[0].pixelWidth, 2_048)
        XCTAssertEqual(prepared.photos[0].pixelHeight, 2_048)
    }

    func testZeroDecodeDimensionIsRejectedAsInvalidLimits() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(maximumDecodedDimension: 0),
                availableCapacity: { _ in Int64.max },
                progress: { _, _ in }
            )
            XCTFail("A zero decode dimension must not reach ImageIO.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .invalidLimits)
        }
    }

    func testRecursiveTraversalIsDepthBounded() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos/a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: root.appendingPathComponent("Photos", isDirectory: true),
                stagingParent: root.appendingPathComponent("Projects", isDirectory: true),
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(maximumRecursionDepth: 2),
                availableCapacity: { _ in Int64.max },
                progress: { _, _ in }
            )
            XCTFail("Deep input trees must stop at the configured resource ceiling.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .traversalLimitExceeded)
        }
    }

    func testAutomaticPrepareSnapshotsSelectedPhotosAndAdoptsAfterSourceDeletion() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<5 {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: source.appendingPathComponent("photo-\(index).jpg"),
                size: 16,
                value: UInt8(20 + index * 30),
                utType: .jpeg
            ))
        }

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 3,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: 10,
                maximumTotalBytes: 1_024 * 1_024,
                minimumFreeSpaceReserveBytes: 0
            ),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.summary.discoveredPhotoCount, 5)
        XCTAssertEqual(prepared.summary.validPhotoCount, 5)
        XCTAssertEqual(prepared.photos.count, 3)
        XCTAssertEqual(prepared.photos.map(\.sha256), prepared.photos.map(\.sha256).sorted())
        XCTAssertEqual(Set(prepared.photos.map(\.retainedRank)), Set(0..<3))
        XCTAssertTrue(prepared.photos.allSatisfy {
            $0.analysisEvidence.sourceSHA256 == $0.source.sha256
                && $0.analysisEvidence.analysisRecipeVersion
                    == PhotoAnalysisEvidenceBuilder.recipeVersion
                && $0.analysisEvidence.analysisRecipeSHA256
                    == PhotoAnalysisEvidenceBuilder.recipeSHA256
        })
        XCTAssertEqual(prepared.selectionArtifact.strategy, .visualDiversity)
        XCTAssertEqual(prepared.selectionArtifact.discoveredCount, 5)
        XCTAssertEqual(prepared.selectionArtifact.acceptedCount, 5)
        XCTAssertEqual(prepared.selectionArtifact.admissionCapacity, 3)
        XCTAssertEqual(prepared.selectionArtifact.candidates.count, 5)
        XCTAssertEqual(
            prepared.selectionArtifact.canonicalRetainedSourceSHA256s,
            prepared.photos.map(\.analysisEvidence.sourceSHA256)
        )
        XCTAssertEqual(
            prepared.selectionArtifact.retainedSourceSHA256s,
            prepared.photos.sorted { $0.retainedRank < $1.retainedRank }
                .map(\.analysisEvidence.sourceSHA256)
        )
        XCTAssertNoThrow(
            try PhotoSelectionArtifactStore.validate(prepared.selectionArtifact)
        )
        XCTAssertTrue(prepared.photos.allSatisfy { $0.stagedURL.lastPathComponent.hasPrefix("photo-") })
        XCTAssertTrue(prepared.photos.allSatisfy { (try? posixMode(of: $0.stagedURL)) == 0o600 })

        try FileManager.default.removeItem(at: source)
        let project = library.appendingPathComponent("Result.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let adopted = try prepared.adopt(into: ProjectPaths(root: project).importedPhotosURL)

        XCTAssertEqual(adopted.map(\.sha256), prepared.photos.map(\.sha256))
        XCTAssertTrue(adopted.allSatisfy { $0.stagedURL.path.hasPrefix(project.path + "/") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
    }

    func testContinuousAutomaticArtifactPreservesEndpointSpacedAdmissionOrder() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<5 {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: source.appendingPathComponent("photo-\(index).jpg"),
                size: 16,
                value: UInt8(20 + index * 30),
                utType: .jpeg
            ))
        }

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .continuous,
            keyframeBudget: 3,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.selectionArtifact.strategy, .continuousEvenSpacing)
        XCTAssertEqual(
            prepared.selectionArtifact.retainedSourceSHA256s,
            prepared.photos.map(\.analysisEvidence.sourceSHA256)
        )
        XCTAssertEqual(
            prepared.selectionArtifact.canonicalRetainedSourceSHA256s,
            prepared.selectionArtifact.retainedSourceSHA256s
        )
        XCTAssertEqual(
            prepared.selectionArtifact.candidates.sorted {
                $0.admissionOrdinal < $1.admissionOrdinal
            }.compactMap(\.retainedRank),
            [0, 1, 2]
        )
        XCTAssertNoThrow(
            try PhotoSelectionArtifactStore.validate(prepared.selectionArtifact)
        )
    }

    func testAdoptNeverReplacesDestinationCreatedAfterPrecheck() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source.appendingPathComponent("photo.jpg"),
            size: 16,
            value: 80,
            utType: .jpeg
        ))
        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 1,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        let project = library.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let destination = ProjectPaths(root: project).importedPhotosURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("existing".utf8).write(to: sentinel)

        XCTAssertThrowsError(try prepared.adopt(into: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
    }

    func testUseAllRemovesExactDuplicatesButKeepsDiscoveryOrder() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("a.jpg")
        let duplicate = source.appendingPathComponent("b.jpg")
        let last = source.appendingPathComponent("c.png")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: first, size: 16, value: 40, utType: .jpeg))
        try FileManager.default.copyItem(at: first, to: duplicate)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: last, size: 16, value: 180, utType: .png))

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .useAllValidPhotos,
            inputOrdering: .continuous,
            keyframeBudget: 3,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: 10,
                maximumTotalBytes: 1_024 * 1_024,
                minimumFreeSpaceReserveBytes: 0
            ),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.summary.duplicatePhotoCount, 1)
        XCTAssertEqual(prepared.photos.map(\.safeDisplayName), ["a.jpg", "c.png"])
        XCTAssertEqual(prepared.selectionArtifact.strategy, .useAll)
        XCTAssertEqual(prepared.selectionArtifact.exactDuplicateCount, 1)
        XCTAssertEqual(prepared.selectionArtifact.companionDuplicateCount, 0)
        XCTAssertEqual(prepared.selectionArtifact.candidates.count, 2)
    }

    func testPrepareRejectsSymlinkEntriesInsteadOfSilentlyOmittingThem() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("real.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: image, size: 16, value: 80, utType: .jpeg))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked.jpg"),
            withDestinationURL: image
        )

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: library,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 10,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in 1_024 * 1_024 },
                progress: { _, _ in }
            )
            XCTFail("A structural entry must fail the admission boundary.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .symbolicLink(relativePath: "linked.jpg"))
        }
    }

    func testPrepareRejectsHardLinkedPhotoSources() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("original.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: image,
            size: 16,
            value: 80,
            utType: .jpeg
        ))
        try FileManager.default.linkItem(
            at: image,
            to: source.appendingPathComponent("alias.jpg")
        )

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in Int64.max },
                progress: { _, _ in }
            )
            XCTFail("Hard-linked sources must not enter admission.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .unreadableEntry(relativePath: "alias.jpg"))
        }
    }

    func testPrepareClonesOwnerReadOnlyPhotoIntoPrivateWritableSnapshot() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("readonly.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: image, size: 16, value: 80, utType: .jpeg))
        XCTAssertEqual(chmod(image.path, S_IRUSR), 0)

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 10,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.photos.count, 1)
        XCTAssertEqual(try posixMode(of: prepared.photos[0].stagedURL), 0o600)
    }

    func testArbitraryFolderWithProjectJSONDoesNotExcludeNestedPhotos() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Imported Folder", isDirectory: true)
        let frames = source.appendingPathComponent("Frames", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("project.json"))
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: frames.appendingPathComponent("nested.jpg"),
            size: 16,
            value: 80,
            utType: .jpeg
        ))

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .useAllValidPhotos,
            inputOrdering: .continuous,
            keyframeBudget: 10,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.summary.discoveredPhotoCount, 1)
        XCTAssertEqual(prepared.photos.map(\.safeDisplayName), ["nested.jpg"])
    }

    func testControlledExtensionComesFromDecodedImageType() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source.appendingPathComponent("misleading.jpg"),
            size: 16,
            value: 80,
            utType: .png
        ))

        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 10,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.photos.map { $0.stagedURL.lastPathComponent }, ["photo-0000.png"])
        XCTAssertEqual(prepared.photos.map(\.typeIdentifier), ["public.png"])
    }

    func testExistingStagingSymlinkDoesNotMutateExternalTarget() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(external.path, 0o755), 0)
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent(".easysplat-photo-input-staging"),
            withDestinationURL: external
        )
        let image = source.appendingPathComponent("photo.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: image, size: 16, value: 80, utType: .jpeg))

        await XCTAssertThrowsErrorAsync(try await prepareOnePhoto(source: source, library: library))

        XCTAssertEqual(try posixMode(of: external), 0o755)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
    }

    func testExistingStagingFileIsNotReplacedOrModified() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let stagingFile = library.appendingPathComponent(".easysplat-photo-input-staging")
        try Data("do not replace".utf8).write(to: stagingFile)
        XCTAssertEqual(chmod(stagingFile.path, 0o640), 0)
        let image = source.appendingPathComponent("photo.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: image, size: 16, value: 80, utType: .jpeg))

        await XCTAssertThrowsErrorAsync(try await prepareOnePhoto(source: source, library: library))

        XCTAssertEqual(try posixMode(of: stagingFile), 0o640)
        XCTAssertEqual(try Data(contentsOf: stagingFile), Data("do not replace".utf8))
    }

    func testStagingReplacementRacePreservesReplacementAndDoesNotAdopt() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        let source = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("photo.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: image, size: 16, value: 80, utType: .jpeg))
        let quarantine = library.appendingPathComponent("quarantined-staging", isDirectory: true)
        let sentinelBytes = Data("replacement".utf8)

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: source,
                stagingParent: library,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 10,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { container in
                    try FileManager.default.moveItem(at: container, to: quarantine)
                    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
                    try sentinelBytes.write(to: container.appendingPathComponent("sentinel"))
                    return 1_024 * 1_024
                },
                progress: { _, _ in }
            )
            XCTFail("A rebound staging container must not be used.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(failure.issue, .stagingUnavailable)
        }

        let replacement = library.appendingPathComponent(".easysplat-photo-input-staging/sentinel")
        XCTAssertEqual(try Data(contentsOf: replacement), sentinelBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }

    private func prepareOnePhoto(source: URL, library: URL) async throws -> PreparedPhotoInput {
        try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: library,
            photoSelection: .automatic,
            inputOrdering: .automatic,
            keyframeBudget: 10,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(minimumFreeSpaceReserveBytes: 0),
            availableCapacity: { _ in 1_024 * 1_024 },
            progress: { _, _ in }
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}

private struct MockRawPhotoDecoder: RawPhotoDecoding {
    let inspectHandler: @Sendable (URL, Int) throws -> RawPhotoInspection
    let developHandler: @Sendable (URL, URL, Int) throws -> RawPhotoDevelopment

    init(
        inspect: @escaping @Sendable (URL, Int) throws -> RawPhotoInspection,
        develop: @escaping @Sendable (URL, URL, Int) throws -> RawPhotoDevelopment
    ) {
        inspectHandler = inspect
        developHandler = develop
    }

    func inspect(stagedSource: URL, maximumProxyDimension: Int) throws -> RawPhotoInspection {
        try inspectHandler(stagedSource, maximumProxyDimension)
    }

    func develop(
        stagedSource: URL,
        destination: URL,
        maximumPixelDimension: Int
    ) throws -> RawPhotoDevelopment {
        try developHandler(stagedSource, destination, maximumPixelDimension)
    }
}

private func writeTaggedRGBPNG(at url: URL, width: Int, height: Int) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImagePropertyOrientation: 1] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func mockPhotoAnalysisMeasurements(_ seed: UInt8) -> PhotoAnalysisMeasurements {
    PhotoAnalysisMeasurements(
        spatialDescriptor: [UInt8](
            repeating: seed,
            count: PhotoAnalysisEvidence.spatialDescriptorLength
        ),
        qualityBucket: 128,
        dHash: UInt64(seed),
        proxyPixelWidth: 8,
        proxyPixelHeight: 8,
        proxyPixelSHA256: String(format: "%064llx", UInt64(seed) + 1),
        analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
        analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256
    )
}

private func companionMetadata() -> [CFString: Any] {
    [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:07:19 12:34:56",
            kCGImagePropertyExifSubsecTimeOriginal: "123",
            kCGImagePropertyExifBodySerialNumber: "CAMERA-42",
            kCGImagePropertyExifExposureTime: 0.008,
            kCGImagePropertyExifFNumber: 4.0,
            kCGImagePropertyExifISOSpeedRatings: [200],
            kCGImagePropertyExifFocalLength: 35.0,
            kCGImagePropertyExifFocalLenIn35mmFilm: 52,
            kCGImagePropertyExifLensModel: "Prime 35mm",
        ] as [CFString: Any],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Camera Maker",
            kCGImagePropertyTIFFModel: "Camera Model",
        ] as [CFString: Any],
    ]
}

private func replacing(
    _ candidate: RawCompanionCandidate,
    relativePath: String? = nil,
    evidence: RawCompanionEvidence? = nil
) -> RawCompanionCandidate {
    RawCompanionCandidate(
        relativePath: relativePath ?? candidate.relativePath,
        typeIdentifier: candidate.typeIdentifier,
        isRaw: candidate.isRaw,
        dimensions: candidate.dimensions,
        orientation: candidate.orientation,
        evidence: evidence ?? candidate.evidence
    )
}

private func writeRGBJPEG(at url: URL, properties: [CFString: Any]) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: 100,
        height: 80,
        bitsPerComponent: 8,
        bytesPerRow: 400,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}
