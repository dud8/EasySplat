import Foundation

/// Imports a user-supplied COLMAP project: locates the sparse model, reads it
/// natively (text or binary), reconciles registered image names with files on
/// disk, and decides the geometry route. A complete model (triangulated
/// points with observations) is eligible for direct adoption; anything less
/// is reduced to a pose seed for toolchain re-triangulation.
public enum ColmapDatasetImporter {
    public enum ImportError: Swift.Error, LocalizedError, Equatable {
        case noModelFound
        case multipleModels
        case noPosedImages
        case missingImageFiles(missing: Int, total: Int)

        public var errorDescription: String? {
            switch self {
            case .noModelFound:
                return "This folder has no readable COLMAP sparse model."
            case .multipleModels:
                return "This COLMAP project contains more than one sparse model. Keep a single model (sparse/0) and try again."
            case .noPosedImages:
                return "This COLMAP model registers no images."
            case .missingImageFiles(let missing, let total):
                return "This dataset is missing \(missing) of its \(total) images. Re-export it with every image included."
            }
        }
    }

    /// Matches `expandFolder`'s ceiling so a hostile dataset cannot force an
    /// unbounded directory walk.
    private static let maximumEnumeratedEntries = 50_000

    /// A model is complete enough for direct adoption only when it carries
    /// triangulated structure the trainer and residual gates can consume.
    static let minimumDirectAdoptionPoints = 100

    public static func plan(datasetRoot: URL) throws -> DatasetImportPlan {
        let modelDirectory = try locateModelDirectory(in: datasetRoot)
        let (model, format) = try ColmapModelReader.read(modelDirectory: modelDirectory)
        guard !model.images.isEmpty else { throw ImportError.noPosedImages }

        let imagesDirectory = locateImagesDirectory(in: datasetRoot)
        let imagesPrefix = imagesDirectory.lastPathComponent == "images" ? "images/" : ""

        var missing = 0
        var imageRefs: [DatasetImageRef] = []
        for image in model.images.sorted(by: { $0.name < $1.name }) {
            let fileURL = imagesDirectory.appendingPathComponent(image.name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                imageRefs.append(
                    DatasetImageRef(entryID: image.name, declaredPath: imagesPrefix + image.name)
                )
            } else {
                missing += 1
            }
        }
        guard missing == 0 else {
            throw ImportError.missingImageFiles(missing: missing, total: model.images.count)
        }

        let observationCount = model.images.reduce(0) { $0 + $1.observations.count }
        let complete = model.points.count >= minimumDirectAdoptionPoints && observationCount > 0

        var notes: [String] = []
        notes.append("Read a \(format == .binary ? "binary" : "text") COLMAP model with \(model.images.count) posed images.")

        let unposed = unposedImageCount(
            in: imagesDirectory,
            registeredNames: Set(model.images.map(\.name))
        )
        if unposed > 0 {
            notes.append("\(unposed) images in the folder have no camera pose and are not used.")
        }

        let planModel: ColmapTextModel
        let route: DatasetGeometryRoute
        if complete {
            route = .adoptDirect
            planModel = model
        } else {
            route = .seedTriangulate
            // Pose seed only: triangulation rebuilds points and observations
            // against the pipeline's own feature database.
            planModel = ColmapTextModel(
                cameras: model.cameras,
                images: model.images.map { image in
                    ColmapTextImage(id: image.id, pose: image.pose, cameraID: image.cameraID, name: image.name)
                }
            )
            if !model.points.isEmpty || observationCount > 0 {
                notes.append("The model's sparse points are too sparse to adopt directly; they will be re-triangulated.")
            }
        }

        return DatasetImportPlan(
            kind: .colmap,
            route: route,
            images: imageRefs,
            model: planModel,
            notes: notes
        )
    }

    /// Ordered discovery mirroring how COLMAP projects are laid out in the
    /// wild: `sparse/0`, then a flat `sparse`, then `model`, then model files
    /// at the root. A project with `sparse/0` and `sparse/1` is ambiguous and
    /// rejected for determinism.
    static func locateModelDirectory(in root: URL) throws -> URL {
        let sparse = root.appendingPathComponent("sparse", isDirectory: true)
        if containsModel(sparse.appendingPathComponent("0", isDirectory: true)) {
            if containsModel(sparse.appendingPathComponent("1", isDirectory: true)) {
                throw ImportError.multipleModels
            }
            return sparse.appendingPathComponent("0", isDirectory: true)
        }
        for candidate in [sparse, root.appendingPathComponent("model", isDirectory: true), root] {
            if containsModel(candidate) {
                return candidate
            }
        }
        throw ImportError.noModelFound
    }

    static func containsModel(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        return ["cameras.bin", "cameras.txt"].contains { name in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        } && ["images.bin", "images.txt"].contains { name in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    private static func locateImagesDirectory(in root: URL) -> URL {
        let images = root.appendingPathComponent("images", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: images.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return images
        }
        return root
    }

    private static func unposedImageCount(in directory: URL, registeredNames: Set<String>) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        let base = directory.standardizedFileURL.path
        var visited = 0
        var unposed = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maximumEnumeratedEntries { break }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            let ext = url.pathExtension.lowercased()
            // Only importable formats count toward the "unposed images" note;
            // formats the pipeline can't import are ignored either way.
            guard ["jpg", "jpeg", "png"].contains(ext) else { continue }
            if !registeredNames.contains(relative) {
                unposed += 1
            }
        }
        return unposed
    }
}
