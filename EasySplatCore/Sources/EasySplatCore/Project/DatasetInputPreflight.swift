import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// The adoption-ready result of inspecting a pre-processed dataset import. Everything
/// lives under a caller-owned staging directory: the three converted COLMAP seed text
/// files, verbatim copies of the original geometry metadata, and the resolved list of
/// posed images to hand to the photo admission machinery. Nothing is written inside a
/// project bundle here; `ProjectInputAdoption.adoptDataset` moves this into place.
///
/// `discard()` mirrors `PreparedPhotoInput`'s deferred-discard contract: the caller keeps
/// the prepared input alive across preflight and publication and releases the staging
/// directory once it is either adopted or abandoned.
public struct PreparedDatasetInput: Sendable {
    /// One declared, on-disk posed image resolved from the dataset. `entryID` is the
    /// stable declared identity carried through to the receipt; `sha256` is the content
    /// digest used to bind the image to the file it becomes under `Originals/Photos`.
    public struct StagedImage: Sendable, Equatable {
        public let entryID: String
        public let url: URL
        public let declaredPath: String
        public let sha256: String

        public init(entryID: String, url: URL, declaredPath: String, sha256: String) {
            self.entryID = entryID
            self.url = url
            self.declaredPath = declaredPath
            self.sha256 = sha256
        }
    }

    /// Root of the staging directory that owns every file produced here.
    public let stagingDirectory: URL
    public let plan: DatasetImportPlan
    /// `cameras.txt`, `images.txt`, `points3D.txt` under `<staging>/seed`, in that order.
    public let seedFileURLs: [URL]
    /// Verbatim copies of the original geometry metadata under `<staging>/source`.
    public let sourceFileURLs: [URL]
    public let stagedImages: [StagedImage]
    public let imageCount: Int
    public let totalImageBytes: Int64
    /// The largest single pixel dimension (width or height) across the dataset's images.
    /// Dataset pixels are never resized — the imported calibration describes the original
    /// grid — so downstream planning must see the true ceiling.
    public let maximumImagePixelDimension: Int

    init(
        stagingDirectory: URL,
        plan: DatasetImportPlan,
        seedFileURLs: [URL],
        sourceFileURLs: [URL],
        stagedImages: [StagedImage],
        imageCount: Int,
        totalImageBytes: Int64,
        maximumImagePixelDimension: Int
    ) {
        self.stagingDirectory = stagingDirectory
        self.plan = plan
        self.seedFileURLs = seedFileURLs
        self.sourceFileURLs = sourceFileURLs
        self.stagedImages = stagedImages
        self.imageCount = imageCount
        self.totalImageBytes = totalImageBytes
        self.maximumImagePixelDimension = maximumImagePixelDimension
    }

    /// Removes the staging directory. Safe to call more than once and after adoption, which
    /// copies the staged files into the bundle rather than moving them out.
    public func discard() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}

public enum DatasetInputError: Swift.Error, LocalizedError, Equatable {
    case unreadableDataset
    case noImages
    case missingImages(missing: Int, total: Int)
    case tooManyImages(count: Int, maximum: Int)
    case duplicateImages(count: Int)
    case rotatedImages(count: Int)
    case imageTooLarge(dimension: Int, maximum: Int)
    case unsupportedImageFormat
    case calibrationMismatch(image: String, width: Int, height: Int, expectedWidth: Int, expectedHeight: Int)
    case archiveNotADataset

    public var errorDescription: String? {
        switch self {
        case .unreadableDataset:
            return "This dataset couldn't be read. Make sure it's a complete, unmodified export and try again."
        case .noImages:
            return "This dataset lists no images."
        case .missingImages(let missing, let total):
            return "This dataset is missing \(missing) of its \(total) images. Re-export it with every image included."
        case .tooManyImages(let count, let maximum):
            return "This dataset has \(count) images. EasySplat imports up to \(maximum)."
        case .duplicateImages(let count):
            return "This dataset contains \(count) duplicate images. Remove duplicates and try again."
        case .rotatedImages(let count):
            return "\(count) images use an EXIF rotation EasySplat can't import yet. Export them with the rotation applied."
        case .imageTooLarge(let dimension, let maximum):
            return "This dataset's images are up to \(dimension) pixels wide. EasySplat imports images up to \(maximum) pixels."
        case .unsupportedImageFormat:
            return "This dataset uses image formats EasySplat can't import. Use JPEG or PNG images."
        case let .calibrationMismatch(image, width, height, expectedWidth, expectedHeight):
            return "The image \(image) is \(width)x\(height) but the dataset's camera expects \(expectedWidth)x\(expectedHeight). Re-export the dataset with matching images."
        case .archiveNotADataset:
            return "This archive isn't a COLMAP, Nerfstudio, or Polycam dataset. Choose a supported export, or add photos or videos instead."
        }
    }
}

/// Pre-pipeline preflight for a pre-processed dataset import. Resolves the geometry into a
/// converted COLMAP seed, gates the declared images (count, presence, EXIF rotation,
/// duplicate content), and stages everything for adoption. The only subprocess use is the
/// hardened ZIP extraction; all other work is pure filesystem inspection.
public struct DatasetInputPreflight {
    /// A `transforms.json` above this size is treated as unreadable rather than parsed.
    private static let transformsMaximumBytes = 64 * 1024 * 1024
    /// A single Polycam keyframe camera JSON above this size is treated as unreadable.
    private static let keyframeJSONMaximumBytes = 4 * 1024 * 1024
    /// Ceiling on any single original geometry metadata file copied into the source folder.
    private static let sourceMetadataMaximumBytes = 256 * 1024 * 1024
    private static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    /// Frame selection copies dataset images byte-identically, and the release
    /// validator only reproduces jpg/jpeg/png selected frames, so the imported
    /// images themselves must already be in one of those formats.
    static let importableImageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// Dataset-tuned extraction ceilings: pose-only exports carry many small files, so the
    /// entry ceiling is generous while per-entry and total sizes stay bounded.
    static let extractionLimits = SafeArchiveExtractor.ExtractionLimits(
        maxEntryCount: 60_000,
        maxEntryUncompressedBytes: 512 * 1024 * 1024,
        maxTotalUncompressedBytes: 64 * 1024 * 1024 * 1024
    )

    public static func prepare(
        source: URL,
        isZip: Bool,
        kind: DatasetKind,
        stagingParent: URL,
        runner: SubprocessRunning
    ) async throws -> PreparedDatasetInput {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let stagingDirectory = stagingParent.appendingPathComponent(
            "dataset-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DatasetInputError.unreadableDataset
        }
        var shouldClean = true
        defer { if shouldClean { try? fileManager.removeItem(at: stagingDirectory) } }

        // a. Resolve the dataset root, extracting a ZIP into staging first.
        let datasetRoot = try resolveDatasetRoot(
            source: source,
            isZip: isZip,
            kind: kind,
            stagingDirectory: stagingDirectory,
            runner: runner
        )

        // b. Dispatch to the right importer for the converted model and source files.
        let planned = try buildPlan(kind: kind, datasetRoot: datasetRoot)
        let plan = planned.plan
        guard !plan.images.isEmpty else { throw DatasetInputError.noImages }

        // c. Enforce the dataset image ceiling before touching any image file.
        guard plan.images.count <= RunPlanResolver.maximumDatasetImageCount else {
            throw DatasetInputError.tooManyImages(
                count: plan.images.count,
                maximum: RunPlanResolver.maximumDatasetImageCount
            )
        }

        // d. Resolve each declared image against the dataset root.
        var resolved: [(ref: DatasetImageRef, url: URL, size: Int64)] = []
        resolved.reserveCapacity(plan.images.count)
        var missing = 0
        for ref in plan.images {
            try Task.checkCancellation()
            let url = datasetRoot.appendingPathComponent(ref.declaredPath)
            var status = stat()
            if lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG {
                resolved.append((ref, url, Int64(status.st_size)))
            } else {
                missing += 1
            }
        }
        guard missing == 0 else {
            throw DatasetInputError.missingImages(missing: missing, total: plan.images.count)
        }

        // d′. Format gate: dataset images are copied byte-identically into the
        // pipeline, so any format the selected-frame contract can't carry
        // (HEIC/HEIF/TIFF and the like) is rejected up front with a clear
        // message rather than failing late in training preparation. The
        // extension alone is not trusted: a RAW file renamed `.jpg` would be
        // silently developed by photo admission, so the raster magic bytes must
        // match the declared JPEG/PNG extension too.
        for item in resolved {
            try Task.checkCancellation()
            let fileExtension = (item.ref.declaredPath as NSString).pathExtension.lowercased()
            guard importableImageExtensions.contains(fileExtension),
                  imageMagicMatches(fileExtension: fileExtension, at: item.url) else {
                throw DatasetInputError.unsupportedImageFormat
            }
        }

        // e. Property gates, without decoding any pixels: an applied EXIF rotation would
        // silently misalign the seed poses, and an oversized grid would fail training prep
        // late — dataset pixels are never resized because the imported calibration
        // describes the original grid.
        var rotated = 0
        var maximumPixelDimension = 0
        var measured: [(ref: DatasetImageRef, width: Int, height: Int)] = []
        measured.reserveCapacity(resolved.count)
        for item in resolved {
            try Task.checkCancellation()
            guard let inspected = imageProperties(item.url) else { continue }
            if inspected.orientation != 1 { rotated += 1 }
            maximumPixelDimension = max(maximumPixelDimension, max(inspected.width, inspected.height))
            measured.append((item.ref, inspected.width, inspected.height))
        }
        guard maximumPixelDimension <= RunPlanResolver.maximumDatasetImagePixelDimension else {
            throw DatasetInputError.imageTooLarge(
                dimension: maximumPixelDimension,
                maximum: RunPlanResolver.maximumDatasetImagePixelDimension
            )
        }
        guard rotated == 0 else {
            throw DatasetInputError.rotatedImages(count: rotated)
        }

        // e′. Calibration gate: each image's raster grid must match the pixel
        // dimensions of the seed camera its model image references. A mismatch
        // means the poses describe a different image than the one on disk, which
        // would silently misalign the whole reconstruction. Orientation is
        // already gated to identity above, so the comparison is orientation-free.
        let camerasByID = Dictionary(
            plan.model.cameras.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var expectedDimensionsByName: [String: (width: Int, height: Int)] = [:]
        for image in plan.model.images {
            guard let camera = camerasByID[image.cameraID] else { continue }
            expectedDimensionsByName[image.name] = (camera.width, camera.height)
        }
        for entry in measured {
            // The model image NAME equals the declared path for nerfstudio and
            // polycam, and the stable entry identity for COLMAP (whose declared
            // path may carry an `images/` prefix).
            guard let expected = expectedDimensionsByName[entry.ref.declaredPath]
                    ?? expectedDimensionsByName[entry.ref.entryID] else {
                continue
            }
            guard entry.width == expected.width, entry.height == expected.height else {
                throw DatasetInputError.calibrationMismatch(
                    image: entry.ref.declaredPath,
                    width: entry.width,
                    height: entry.height,
                    expectedWidth: expected.width,
                    expectedHeight: expected.height
                )
            }
        }

        // f. Duplicate-content gate: a repeated image would let admission drop a file whose
        // pose we still declared, so reject any duplicate up front.
        var stagedImages: [PreparedDatasetInput.StagedImage] = []
        stagedImages.reserveCapacity(resolved.count)
        var seenDigests = Set<String>()
        var duplicates = 0
        var totalBytes: Int64 = 0
        for item in resolved {
            try Task.checkCancellation()
            let digest: String
            do {
                digest = try GeometryArtifactStore.sha256(of: item.url)
            } catch {
                throw DatasetInputError.unreadableDataset
            }
            if seenDigests.insert(digest).inserted {
                totalBytes &+= item.size
                stagedImages.append(
                    PreparedDatasetInput.StagedImage(
                        entryID: item.ref.entryID,
                        url: item.url,
                        declaredPath: item.ref.declaredPath,
                        sha256: digest
                    )
                )
            } else {
                duplicates += 1
            }
        }
        guard duplicates == 0 else {
            throw DatasetInputError.duplicateImages(count: duplicates)
        }

        // g. Persist the converted seed and verbatim source metadata into staging.
        let seedFileURLs = try writeSeed(plan: plan, stagingDirectory: stagingDirectory)
        let sourceFileURLs = try copySourceFiles(
            planned.sourceFileURLs,
            stagingDirectory: stagingDirectory
        )

        shouldClean = false
        return PreparedDatasetInput(
            stagingDirectory: stagingDirectory,
            plan: plan,
            seedFileURLs: seedFileURLs,
            sourceFileURLs: sourceFileURLs,
            stagedImages: stagedImages,
            imageCount: stagedImages.count,
            totalImageBytes: totalBytes,
            maximumImagePixelDimension: maximumPixelDimension
        )
    }

    // MARK: - Dataset root

    private static func resolveDatasetRoot(
        source: URL,
        isZip: Bool,
        kind: DatasetKind,
        stagingDirectory: URL,
        runner: SubprocessRunning
    ) throws -> URL {
        guard isZip else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DatasetInputError.unreadableDataset
            }
            return source
        }
        let extractionRoot = stagingDirectory.appendingPathComponent("extract", isDirectory: true)
        try SafeArchiveExtractor.extract(
            zipURL: source,
            to: extractionRoot,
            limits: extractionLimits
        )
        let root = descendSingleWrapper(extractionRoot)
        guard datasetAnchorPresent(kind: kind, datasetRoot: root) else {
            throw DatasetInputError.archiveNotADataset
        }
        return root
    }

    /// Many exports zip a single wrapper folder. Descend into it so the dataset root sits
    /// where the importers expect, ignoring the `__MACOSX` sidecar some tools add.
    private static func descendSingleWrapper(_ root: URL) -> URL {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return root
        }
        let meaningful = entries.filter { $0.lastPathComponent != "__MACOSX" }
        guard meaningful.count == 1,
              (try? meaningful[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return root
        }
        // Rebuild from the caller's root so the descended URL keeps its path
        // spelling (temporary volumes alias /var and /private/var).
        return root.appendingPathComponent(meaningful[0].lastPathComponent, isDirectory: true)
    }

    private static func datasetAnchorPresent(kind: DatasetKind, datasetRoot: URL) -> Bool {
        switch kind {
        case .colmap:
            let candidates = [
                datasetRoot.appendingPathComponent("sparse/0", isDirectory: true),
                datasetRoot.appendingPathComponent("sparse", isDirectory: true),
                datasetRoot.appendingPathComponent("model", isDirectory: true),
                datasetRoot,
            ]
            return candidates.contains { ColmapDatasetImporter.containsModel($0) }
        case .nerfstudio:
            return isRegularFile(datasetRoot.appendingPathComponent("transforms.json"))
        case .polycam:
            let keyframes = datasetRoot.appendingPathComponent("keyframes", isDirectory: true)
            return isDirectory(keyframes.appendingPathComponent("corrected_cameras", isDirectory: true))
                || isDirectory(keyframes.appendingPathComponent("cameras", isDirectory: true))
        }
    }

    // MARK: - Import planning

    private static func buildPlan(
        kind: DatasetKind,
        datasetRoot: URL
    ) throws -> (plan: DatasetImportPlan, sourceFileURLs: [URL]) {
        switch kind {
        case .colmap:
            let modelDirectory = try ColmapDatasetImporter.locateModelDirectory(in: datasetRoot)
            let sourceFileURLs = [
                "cameras.txt", "cameras.bin",
                "images.txt", "images.bin",
                "points3D.txt", "points3D.bin",
            ]
            .map { modelDirectory.appendingPathComponent($0) }
            .filter { isRegularFile($0) }
            let plan = try ColmapDatasetImporter.plan(datasetRoot: datasetRoot)
            return (plan, sourceFileURLs)
        case .nerfstudio:
            let transformsURL = datasetRoot.appendingPathComponent("transforms.json")
            let data: Data
            do {
                data = try BoundedFileReader.readRegularFile(
                    at: transformsURL,
                    maximumBytes: transformsMaximumBytes
                )
            } catch {
                throw DatasetInputError.unreadableDataset
            }
            let plan = try NerfstudioDatasetImporter.plan(fromTransformsJSON: data)
            return (plan, [transformsURL])
        case .polycam:
            let collected = try collectPolycamKeyframes(datasetRoot: datasetRoot)
            let plan = try PolycamDatasetImporter.plan(
                fromKeyframes: collected.keyframes,
                usedCorrectedCameras: collected.usedCorrectedCameras
            )
            return (plan, collected.sourceFileURLs)
        }
    }

    private static func collectPolycamKeyframes(
        datasetRoot: URL
    ) throws -> (keyframes: [PolycamDatasetImporter.Keyframe], usedCorrectedCameras: Bool, sourceFileURLs: [URL]) {
        let keyframesDir = datasetRoot.appendingPathComponent("keyframes", isDirectory: true)
        let correctedCamerasDir = keyframesDir.appendingPathComponent("corrected_cameras", isDirectory: true)
        let correctedJSONs = jsonFiles(in: correctedCamerasDir)
        let usedCorrected = !correctedJSONs.isEmpty
        let cameraJSONs = usedCorrected
            ? correctedJSONs
            : jsonFiles(in: keyframesDir.appendingPathComponent("cameras", isDirectory: true))
        let imagesDirName = usedCorrected ? "corrected_images" : "images"
        let imageFileByStem = imageFilesByStem(
            in: keyframesDir.appendingPathComponent(imagesDirName, isDirectory: true)
        )

        var keyframes: [PolycamDatasetImporter.Keyframe] = []
        var sourceFileURLs: [URL] = []
        for jsonURL in cameraJSONs {
            let stem = jsonURL.deletingPathExtension().lastPathComponent
            // A camera without a paired image has no file to adopt; skip it rather than
            // orphaning a pose.
            guard let imageFile = imageFileByStem[stem] else { continue }
            let camera: PolycamDatasetImporter.KeyframeCamera
            do {
                let data = try BoundedFileReader.readRegularFile(
                    at: jsonURL,
                    maximumBytes: keyframeJSONMaximumBytes
                )
                camera = try JSONDecoder().decode(
                    PolycamDatasetImporter.KeyframeCamera.self,
                    from: data
                )
            } catch {
                throw DatasetInputError.unreadableDataset
            }
            keyframes.append(
                PolycamDatasetImporter.Keyframe(
                    stem: stem,
                    imagePath: "keyframes/\(imagesDirName)/\(imageFile)",
                    camera: camera
                )
            )
            sourceFileURLs.append(jsonURL)
        }
        return (keyframes, usedCorrected, sourceFileURLs)
    }

    private static func jsonFiles(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter {
                $0.pathExtension.lowercased() == "json"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func imageFilesByStem(in directory: URL) -> [String: String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var map: [String: String] = [:]
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard supportedImageExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let stem = url.deletingPathExtension().lastPathComponent
            if map[stem] == nil { map[stem] = url.lastPathComponent }
        }
        return map
    }

    // MARK: - Seed and source staging

    private static func writeSeed(plan: DatasetImportPlan, stagingDirectory: URL) throws -> [URL] {
        let emitted = try ColmapTextModelEmitter.emit(plan.model)
        let seedDirectory = stagingDirectory.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: seedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let files: [(name: String, contents: String)] = [
            ("cameras.txt", emitted.camerasTxt),
            ("images.txt", emitted.imagesTxt),
            ("points3D.txt", emitted.points3DTxt),
        ]
        var urls: [URL] = []
        for file in files {
            let url = seedDirectory.appendingPathComponent(file.name)
            try Data(file.contents.utf8).write(to: url, options: [.atomic])
            urls.append(url)
        }
        return urls
    }

    private static func copySourceFiles(_ urls: [URL], stagingDirectory: URL) throws -> [URL] {
        let sourceDirectory = stagingDirectory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var stagedURLs: [URL] = []
        var usedNames = Set<String>()
        for (index, url) in urls.enumerated() {
            var name = url.lastPathComponent
            if !usedNames.insert(name).inserted {
                name = "\(index)-\(name)"
                usedNames.insert(name)
            }
            let destination = sourceDirectory.appendingPathComponent(name)
            let data: Data
            do {
                data = try BoundedFileReader.readRegularFile(
                    at: url,
                    maximumBytes: sourceMetadataMaximumBytes
                )
            } catch {
                throw DatasetInputError.unreadableDataset
            }
            try data.write(to: destination, options: [.atomic])
            stagedURLs.append(destination)
        }
        return stagedURLs
    }

    // MARK: - Image inspection

    /// Reads the stored EXIF orientation and pixel dimensions without decoding pixels. An
    /// absent orientation tag or the identity value (1) is upright; anything else is a
    /// rotation we can't yet apply. An unreadable file is left to photo admission to reject.
    private static func imageProperties(
        _ url: URL
    ) -> (orientation: Int, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any] else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (orientation, width, height)
    }

    /// Confirms the file's leading bytes are the real JPEG (`FF D8 FF`) or PNG
    /// (`89 50 4E 47`) signature its extension claims. Reads only the header, so
    /// a mislabeled RAW or other container fails here rather than after admission
    /// has silently developed it into a supported format.
    private static func imageMagicMatches(fileExtension: String, at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 8)) ?? Data()
        let bytes = [UInt8](header)
        switch fileExtension {
        case "jpg", "jpeg":
            return bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
        case "png":
            return bytes.count >= 4
                && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
        default:
            return false
        }
    }

    // MARK: - Filesystem helpers

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
