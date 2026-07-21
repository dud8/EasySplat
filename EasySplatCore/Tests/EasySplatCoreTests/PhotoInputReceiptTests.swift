import Darwin
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class PhotoInputReceiptTests: XCTestCase {
    func testRawDevelopmentReceiptPersistsCompleteSourceAndDecoderProvenance() throws {
        let sourceSHA256 = digest("b")
        let receipt = PhotoInputReceipt(
            projectRelativePath: "Originals/Photos/photo-0000.png",
            safeDisplayName: "DSC_0042.CR3",
            byteCount: 1_024,
            sha256: digest("a"),
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            orientation: 1,
            typeIdentifier: "public.png",
            source: PhotoSourceProvenance(
                byteCount: 24_000_000,
                sha256: sourceSHA256,
                typeIdentifier: "com.canon.cr3-raw-image"
            ),
            importMode: .rawDevelopment(RawDevelopmentEvidence(
                decoderIdentifier: "com.apple.CoreImage.CIRAWFilter",
                decoderVersion: "9",
                settings: .production(maximumPixelDimension: 4_096),
                nativePixelWidth: 6_000,
                nativePixelHeight: 4_000,
                sourceOrientation: 6
            )),
            analysisEvidence: evidence(sourceSHA256: sourceSHA256),
            retainedRank: 0
        )

        let encoded = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(PhotoInputReceipt.self, from: encoded)

        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.schemaVersion, 3)
        guard case .rawDevelopment(let evidence) = decoded.importMode else {
            return XCTFail("Expected typed RAW development evidence.")
        }
        XCTAssertEqual(evidence.settings.outputTypeIdentifier, "public.png")
        XCTAssertEqual(evidence.settings.outputColorSpace, "sRGB IEC61966-2.1")
        XCTAssertEqual(evidence.settings.outputBitDepth, 8)
        XCTAssertEqual(evidence.settings.extendedDynamicRangeAmount, 0)
        XCTAssertTrue(evidence.settings.lensCorrectionEnabled)
        XCTAssertEqual(evidence.settings.version, 2)

        let paths = ProjectPaths(root: URL(fileURLWithPath: "/tmp/Receipt.easysplatproj"))
        XCTAssertNoThrow(try PhotoInputReceiptValidator.validateMetadata(
            ProjectMetadata(
                title: "RAW",
                input: .photos(folder: "Originals/Photos"),
                photoInputReceipts: [receipt],
                photoSelectionReceipt: placeholderSelectionReceipt()
            ),
            paths: paths
        ))
        XCTAssertNotEqual(receipt.sha256, receipt.source.sha256)
        XCTAssertEqual(receipt.analysisEvidence.sourceSHA256, receipt.source.sha256)
    }

    func testPhotoSelectionReceiptPersistsCompletePolicyClosure() throws {
        let receipt = PhotoSelectionReceipt(
            projectRelativePath: "Frames/photo_selection.json",
            byteCount: 12_345,
            sha256: digest("a"),
            artifactSchemaVersion: PhotoSelectionArtifact.currentSchemaVersion,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256
        )

        let decoded = try JSONDecoder().decode(
            PhotoSelectionReceipt.self,
            from: JSONEncoder().encode(receipt)
        )

        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.projectRelativePath, "Frames/photo_selection.json")

        let metadata = ProjectMetadata(
            title: "Photos",
            input: .photos(folder: "Originals/Photos"),
            photoSelectionReceipt: receipt
        )
        let decodedMetadata = try JSONDecoder().decode(
            ProjectMetadata.self,
            from: JSONEncoder().encode(metadata)
        )
        XCTAssertEqual(decodedMetadata.photoSelectionReceipt, receipt)
    }

    func testReceiptDecodeRejectsMissingAnalysisEvidence() throws {
        let receipt = makeReceipt(index: 0, digestCharacter: "a", retainedRank: 0)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
                as? [String: Any]
        )
        object.removeValue(forKey: "analysisEvidence")
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(PhotoInputReceipt.self, from: data)) {
            error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected missing required analysis evidence, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "analysisEvidence")
        }
    }

    func testReceiptValidatorAcceptsCanonicalReceiptOrderWithIndependentRanks() throws {
        let paths = temporaryProjectPaths()
        let receipts = [
            makeReceipt(index: 0, digestCharacter: "a", retainedRank: 1),
            makeReceipt(index: 1, digestCharacter: "b", retainedRank: 0)
        ]

        XCTAssertNoThrow(try PhotoInputReceiptValidator.validateMetadata(
            metadata(receipts),
            paths: paths
        ))
    }

    func testReceiptValidatorRejectsMissingSelectionReceiptForRetainedPhotos() throws {
        let paths = temporaryProjectPaths()
        let receipt = makeReceipt(index: 0, digestCharacter: "a", retainedRank: 0)
        let metadata = ProjectMetadata(
            title: "Photos",
            input: .photos(folder: "Originals/Photos"),
            photoInputReceipts: [receipt]
        )

        XCTAssertThrowsError(try PhotoInputReceiptValidator.validateMetadata(
            metadata,
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoInputReceiptValidationError,
                .missingSelectionReceipt
            )
        }
    }

    func testReceiptValidatorRejectsSelectionReceiptWithoutRetainedPhotos() throws {
        let paths = temporaryProjectPaths()
        let metadata = ProjectMetadata(
            title: "Mixed",
            input: .mixed(videos: ["Originals/video-0000.mov"], photosFolder: "Originals/Photos"),
            photoInputReceipts: [],
            photoSelectionReceipt: placeholderSelectionReceipt()
        )

        XCTAssertThrowsError(try PhotoInputReceiptValidator.validateMetadata(
            metadata,
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoInputReceiptValidationError,
                .unexpectedSelectionReceipt
            )
        }
    }

    func testReceiptValidatorRejectsAnalysisEvidenceForAnotherSource() throws {
        let paths = temporaryProjectPaths()
        let receipt = makeReceipt(
            index: 0,
            digestCharacter: "a",
            retainedRank: 0,
            evidenceSourceSHA256: digest("b")
        )

        assertInvalidReceipt([receipt], paths: paths, index: 0)
    }

    func testReceiptValidatorRejectsStaleAnalysisRecipe() throws {
        let paths = temporaryProjectPaths()
        var staleVersion = evidence(sourceSHA256: digest("a"))
        staleVersion = PhotoAnalysisEvidence(
            sourceSHA256: staleVersion.sourceSHA256,
            spatialDescriptor: staleVersion.spatialDescriptor,
            qualityBucket: staleVersion.qualityBucket,
            dHash: staleVersion.dHash,
            proxyPixelWidth: staleVersion.proxyPixelWidth,
            proxyPixelHeight: staleVersion.proxyPixelHeight,
            proxyPixelSHA256: staleVersion.proxyPixelSHA256,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion + 1,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256
        )
        let receipt = makeReceipt(
            index: 0,
            digestCharacter: "a",
            retainedRank: 0,
            analysisEvidence: staleVersion
        )

        assertInvalidReceipt([receipt], paths: paths, index: 0)
    }

    func testReceiptValidatorRejectsDifferentAnalysisRecipeHash() throws {
        let paths = temporaryProjectPaths()
        let sourceSHA256 = digest("a")
        let current = evidence(sourceSHA256: sourceSHA256)
        let staleHash = PhotoAnalysisEvidence(
            sourceSHA256: current.sourceSHA256,
            spatialDescriptor: current.spatialDescriptor,
            qualityBucket: current.qualityBucket,
            dHash: current.dHash,
            proxyPixelWidth: current.proxyPixelWidth,
            proxyPixelHeight: current.proxyPixelHeight,
            proxyPixelSHA256: current.proxyPixelSHA256,
            analysisRecipeVersion: PhotoAnalysisEvidence.currentRecipeVersion,
            analysisRecipeSHA256: digest("e")
        )
        let receipt = makeReceipt(
            index: 0,
            digestCharacter: "a",
            retainedRank: 0,
            analysisEvidence: staleHash
        )

        assertInvalidReceipt([receipt], paths: paths, index: 0)
    }

    func testReceiptValidatorRejectsStructurallyInvalidAnalysisEvidence() throws {
        let paths = temporaryProjectPaths()
        let sourceSHA256 = digest("a")
        let invalid = PhotoAnalysisEvidence(
            sourceSHA256: sourceSHA256,
            spatialDescriptor: [UInt8](repeating: 0, count: 63),
            qualityBucket: 128,
            dHash: 0,
            proxyPixelWidth: 256,
            proxyPixelHeight: 192,
            proxyPixelSHA256: digest("c"),
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256
        )
        let receipt = makeReceipt(
            index: 0,
            digestCharacter: "a",
            retainedRank: 0,
            analysisEvidence: invalid
        )

        assertInvalidReceipt([receipt], paths: paths, index: 0)
    }

    func testReceiptValidatorRejectsNegativeRetainedRank() throws {
        let paths = temporaryProjectPaths()
        assertInvalidReceipt(
            [makeReceipt(index: 0, digestCharacter: "a", retainedRank: -1)],
            paths: paths,
            index: 0
        )
    }

    func testReceiptValidatorRejectsPreviousReceiptSchema() throws {
        let paths = temporaryProjectPaths()
        assertInvalidReceipt(
            [makeReceipt(
                index: 0,
                digestCharacter: "a",
                retainedRank: 0,
                schemaVersion: 2
            )],
            paths: paths,
            index: 0
        )
    }

    func testReceiptValidatorRejectsDuplicateRetainedRanks() throws {
        let paths = temporaryProjectPaths()
        let receipts = [
            makeReceipt(index: 0, digestCharacter: "a", retainedRank: 0),
            makeReceipt(index: 1, digestCharacter: "b", retainedRank: 0)
        ]

        XCTAssertThrowsError(try PhotoInputReceiptValidator.validateMetadata(
            metadata(receipts),
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoInputReceiptValidationError,
                .duplicateRetainedRank(index: 1)
            )
        }
    }

    func testReceiptValidatorAllowsIdenticalRawOutputsFromDistinctSources() throws {
        let paths = temporaryProjectPaths()
        let receipts = [
            makeRawReceipt(
                index: 0,
                controlledDigestCharacter: "a",
                sourceDigestCharacter: "c",
                retainedRank: 0
            ),
            makeRawReceipt(
                index: 1,
                controlledDigestCharacter: "a",
                sourceDigestCharacter: "d",
                retainedRank: 1
            )
        ]

        XCTAssertNoThrow(try PhotoInputReceiptValidator.validateMetadata(
            metadata(receipts),
            paths: paths
        ))
    }

    func testReceiptValidatorRejectsDuplicateRawSourcesWithDifferentControlledOutputs() throws {
        let paths = temporaryProjectPaths()
        let receipts = [
            makeRawReceipt(
                index: 0,
                controlledDigestCharacter: "a",
                sourceDigestCharacter: "c",
                retainedRank: 0
            ),
            makeRawReceipt(
                index: 1,
                controlledDigestCharacter: "b",
                sourceDigestCharacter: "c",
                retainedRank: 1
            )
        ]

        XCTAssertThrowsError(try PhotoInputReceiptValidator.validateMetadata(
            metadata(receipts),
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoInputReceiptValidationError,
                .duplicateDigest(index: 1)
            )
        }
    }

    func testReceiptValidatorRejectsGappedRetainedRanks() throws {
        let paths = temporaryProjectPaths()
        let receipts = [
            makeReceipt(index: 0, digestCharacter: "a", retainedRank: 0),
            makeReceipt(index: 1, digestCharacter: "b", retainedRank: 2)
        ]

        XCTAssertThrowsError(try PhotoInputReceiptValidator.validateMetadata(
            metadata(receipts),
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? PhotoInputReceiptValidationError,
                .noncontiguousRetainedRanks
            )
        }
    }

    func testUnchangedReceiptRejectsSourceProvenanceThatDoesNotMatchControlledFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        let receipt = PhotoInputReceipt(
            projectRelativePath: "Originals/Photos/photo-0000.jpg",
            safeDisplayName: "capture.jpg",
            byteCount: 10,
            sha256: String(repeating: "a", count: 64),
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: 1,
            typeIdentifier: "public.jpeg",
            source: PhotoSourceProvenance(
                byteCount: 11,
                sha256: String(repeating: "b", count: 64),
                typeIdentifier: "public.jpeg"
            ),
            importMode: .unchanged,
            analysisEvidence: evidence(sourceSHA256: digest("b")),
            retainedRank: 0
        )

        XCTAssertThrowsError(try PhotoInputReceiptValidator.validateMetadata(
            ProjectMetadata(
                title: "Mismatch",
                input: .photos(folder: "Originals/Photos"),
                photoInputReceipts: [receipt]
            ),
            paths: paths
        )) { error in
            XCTAssertEqual(error as? PhotoInputReceiptValidationError, .invalidReceipt(index: 0))
        }
    }

    func testReceiptFilesRemainValidAfterProjectMoveAndMetadataHasNoExternalPath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Original.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.importedPhotosURL, withIntermediateDirectories: true)
        let photo = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: photo,
            size: 16,
            value: 80,
            utType: .jpeg
        ))
        XCTAssertEqual(chmod(photo.path, 0o600), 0)
        let metadata = try fileBoundMetadata(
            receipts: [try receipt(for: photo, typeIdentifier: "public.jpeg")],
            paths: paths
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let json = try String(contentsOf: paths.metadataURL, encoding: .utf8)
        XCTAssertFalse(json.contains(root.path))

        let moved = root.appendingPathComponent("Moved.easysplatproj", isDirectory: true)
        try FileManager.default.moveItem(at: project, to: moved)
        let movedPaths = ProjectPaths(root: moved)
        let loaded = try ProjectMetadataStore.load(from: movedPaths.metadataURL)
        try PhotoInputReceiptValidator.validateFiles(metadata: loaded, paths: movedPaths)
    }

    func testReceiptValidatorRejectsTypeAndControlledExtensionMismatch() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.importedPhotosURL, withIntermediateDirectories: true)
        let photo = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: photo,
            size: 16,
            value: 80,
            utType: .png
        ))
        XCTAssertEqual(chmod(photo.path, 0o600), 0)
        let metadata = ProjectMetadata(
            title: "Mismatch",
            input: .photos(folder: "Originals/Photos"),
            photoInputReceipts: [try receipt(for: photo, typeIdentifier: "public.png")]
        )

        XCTAssertThrowsError(
            try PhotoInputReceiptValidator.validateMetadata(metadata, paths: paths)
        ) { error in
            XCTAssertEqual(error as? PhotoInputReceiptValidationError, .invalidReceipt(index: 0))
        }
    }

    func testReceiptValidatorDetectsControlledPhotoMutation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.importedPhotosURL, withIntermediateDirectories: true)
        let photo = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: photo,
            size: 16,
            value: 80,
            utType: .jpeg
        ))
        XCTAssertEqual(chmod(photo.path, 0o600), 0)
        let metadata = try fileBoundMetadata(
            receipts: [try receipt(for: photo, typeIdentifier: "public.jpeg")],
            paths: paths
        )
        try Data("tampered".utf8).write(to: photo)

        XCTAssertThrowsError(
            try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
        ) { error in
            XCTAssertEqual(error as? PhotoInputReceiptValidationError, .sizeMismatch(index: 0))
        }
    }

    func testReceiptValidatorRejectsNonPrivateControlledPhoto() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.importedPhotosURL, withIntermediateDirectories: true)
        let photo = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: photo,
            size: 16,
            value: 80,
            utType: .jpeg
        ))
        XCTAssertEqual(chmod(photo.path, 0o644), 0)
        let metadata = try fileBoundMetadata(
            receipts: [try receipt(for: photo, typeIdentifier: "public.jpeg")],
            paths: paths
        )

        XCTAssertThrowsError(
            try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
        ) { error in
            XCTAssertEqual(error as? PhotoInputReceiptValidationError, .fileUnavailable(index: 0))
        }
    }

    private func receipt(for photo: URL, typeIdentifier: String) throws -> PhotoInputReceipt {
        let attributes = try FileManager.default.attributesOfItem(atPath: photo.path)
        let sha256 = try GeometryArtifactStore.sha256(of: photo)
        return PhotoInputReceipt(
            projectRelativePath: "Originals/Photos/\(photo.lastPathComponent)",
            safeDisplayName: "capture.jpg",
            byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
            sha256: sha256,
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: 1,
            typeIdentifier: typeIdentifier,
            analysisEvidence: evidence(sourceSHA256: sha256),
            retainedRank: 0
        )
    }

    private func temporaryProjectPaths() -> ProjectPaths {
        ProjectPaths(root: URL(fileURLWithPath: "/tmp/PhotoReceiptTests.easysplatproj"))
    }

    private func metadata(_ receipts: [PhotoInputReceipt]) -> ProjectMetadata {
        ProjectMetadata(
            title: "Photos",
            input: .photos(folder: "Originals/Photos"),
            photoInputReceipts: receipts,
            photoSelectionReceipt: placeholderSelectionReceipt()
        )
    }

    private func fileBoundMetadata(
        receipts: [PhotoInputReceipt],
        paths: ProjectPaths
    ) throws -> ProjectMetadata {
        let ranked = try PhotoDiversitySelector.rank(
            receipts.map(\.analysisEvidence),
            targetCount: receipts.count
        )
        let rankBySHA256 = Dictionary(
            uniqueKeysWithValues: ranked.enumerated().map {
                ($0.element.sourceSHA256, $0.offset)
            }
        )
        let artifact = PhotoSelectionArtifact(
            strategy: .visualDiversity,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: .unordered,
            requestedPhotoSelection: .automatic,
            admissionCapacity: receipts.count,
            discoveredCount: receipts.count,
            acceptedCount: receipts.count,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: receipts.enumerated().map { index, receipt in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: index,
                    evidence: receipt.analysisEvidence,
                    retainedRank: rankBySHA256[receipt.source.sha256]
                )
            },
            retainedSourceSHA256s: ranked.map(\.sourceSHA256),
            canonicalRetainedSourceSHA256s: receipts.map(\.source.sha256)
        )
        let file = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let input = InputSpec.photos(folder: "Originals/Photos")
        let options = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        return ProjectMetadata(
            title: "Photos",
            input: input,
            photoInputReceipts: receipts,
            photoSelectionReceipt: PhotoSelectionReceipt(
                projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
                byteCount: file.byteCount,
                sha256: file.sha256,
                artifactSchemaVersion: artifact.schemaVersion,
                analysisRecipeVersion: artifact.analysisRecipeVersion,
                analysisRecipeSHA256: artifact.analysisRecipeSHA256,
                selectorPolicyVersion: artifact.selectorPolicyVersion,
                selectorPolicySHA256: artifact.selectorPolicySHA256
            ),
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )
    }

    private func placeholderSelectionReceipt() -> PhotoSelectionReceipt {
        PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: 1,
            sha256: digest("a"),
            artifactSchemaVersion: PhotoSelectionArtifact.currentSchemaVersion,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256
        )
    }

    private func assertInvalidReceipt(
        _ receipts: [PhotoInputReceipt],
        paths: ProjectPaths,
        index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try PhotoInputReceiptValidator.validateMetadata(metadata(receipts), paths: paths),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? PhotoInputReceiptValidationError,
                .invalidReceipt(index: index),
                file: file,
                line: line
            )
        }
    }

    private func makeReceipt(
        index: Int,
        digestCharacter: Character,
        retainedRank: Int,
        schemaVersion: Int = PhotoInputReceipt.currentSchemaVersion,
        evidenceSourceSHA256: String? = nil,
        analysisEvidence explicitEvidence: PhotoAnalysisEvidence? = nil
    ) -> PhotoInputReceipt {
        let sourceSHA256 = digest(digestCharacter)
        return PhotoInputReceipt(
            schemaVersion: schemaVersion,
            projectRelativePath: String(format: "Originals/Photos/photo-%04d.jpg", index),
            safeDisplayName: "capture-\(index).jpg",
            byteCount: Int64(100 + index),
            sha256: sourceSHA256,
            pixelWidth: 64,
            pixelHeight: 48,
            orientation: 1,
            typeIdentifier: "public.jpeg",
            analysisEvidence: explicitEvidence ?? evidence(
                sourceSHA256: evidenceSourceSHA256 ?? sourceSHA256
            ),
            retainedRank: retainedRank
        )
    }

    private func makeRawReceipt(
        index: Int,
        controlledDigestCharacter: Character,
        sourceDigestCharacter: Character,
        retainedRank: Int
    ) -> PhotoInputReceipt {
        let sourceSHA256 = digest(sourceDigestCharacter)
        return PhotoInputReceipt(
            projectRelativePath: String(format: "Originals/Photos/photo-%04d.png", index),
            safeDisplayName: "capture-\(index).dng",
            byteCount: 1_024,
            sha256: digest(controlledDigestCharacter),
            pixelWidth: 64,
            pixelHeight: 48,
            orientation: 1,
            typeIdentifier: UTType.png.identifier,
            source: PhotoSourceProvenance(
                byteCount: 4_096,
                sha256: sourceSHA256,
                typeIdentifier: UTType.rawImage.identifier
            ),
            importMode: .rawDevelopment(RawDevelopmentEvidence(
                decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                decoderVersion: "9",
                settings: .production(maximumPixelDimension: 4_096),
                nativePixelWidth: 64,
                nativePixelHeight: 48,
                sourceOrientation: 1
            )),
            analysisEvidence: evidence(sourceSHA256: sourceSHA256),
            retainedRank: retainedRank
        )
    }

    private func evidence(sourceSHA256: String) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: sourceSHA256,
            spatialDescriptor: [UInt8](repeating: 128, count: 64),
            qualityBucket: 128,
            dHash: 0,
            proxyPixelWidth: 256,
            proxyPixelHeight: 192,
            proxyPixelSHA256: digest("f"),
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
