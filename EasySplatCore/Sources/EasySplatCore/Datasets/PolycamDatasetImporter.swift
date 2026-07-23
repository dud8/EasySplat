import Foundation

/// Converts a Polycam raw export's keyframe cameras into a pose-only COLMAP
/// model. The pure core consumes decoded keyframe records; enumerating
/// `keyframes/cameras` vs `keyframes/corrected_cameras` and pairing JSON files
/// with images happens in the preflight shell.
///
/// Field semantics verified against nerfstudio's `polycam_utils.py`
/// (ns-process-data): `t_00..t_23` is a row-major 3x4 camera-to-world with an
/// OpenGL-style camera basis (nerfstudio consumes the camera columns
/// untouched; its row permutation is a world-frame rotation the pipeline does
/// not need), and intrinsics are undistorted pinhole `fx/fy/cx/cy`. Nerfstudio
/// drops frames below a blur threshold; EasySplat keeps every posed frame —
/// dropping one would orphan its pose — and surfaces blur only as a note.
public enum PolycamDatasetImporter {
    public struct Keyframe: Sendable, Equatable {
        /// Shared basename of the camera JSON and its image, e.g. "1666302_054".
        public var stem: String
        /// Image path relative to the dataset root.
        public var imagePath: String
        public var camera: KeyframeCamera

        public init(stem: String, imagePath: String, camera: KeyframeCamera) {
            self.stem = stem
            self.imagePath = imagePath
            self.camera = camera
        }
    }

    public struct KeyframeCamera: Decodable, Sendable, Equatable {
        public var fx: Double
        public var fy: Double
        public var cx: Double
        public var cy: Double
        public var width: Double
        public var height: Double
        public var blurScore: Double?
        public var transformRowMajor: [Double]

        enum CodingKeys: String, CodingKey {
            case fx, fy, cx, cy, width, height
            case blurScore = "blur_score"
            case t00 = "t_00", t01 = "t_01", t02 = "t_02", t03 = "t_03"
            case t10 = "t_10", t11 = "t_11", t12 = "t_12", t13 = "t_13"
            case t20 = "t_20", t21 = "t_21", t22 = "t_22", t23 = "t_23"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fx = try container.decode(Double.self, forKey: .fx)
            fy = try container.decode(Double.self, forKey: .fy)
            cx = try container.decode(Double.self, forKey: .cx)
            cy = try container.decode(Double.self, forKey: .cy)
            width = try container.decode(Double.self, forKey: .width)
            height = try container.decode(Double.self, forKey: .height)
            blurScore = try container.decodeIfPresent(Double.self, forKey: .blurScore)
            transformRowMajor = try [
                CodingKeys.t00, .t01, .t02, .t03,
                .t10, .t11, .t12, .t13,
                .t20, .t21, .t22, .t23,
            ].map { try container.decode(Double.self, forKey: $0) }
        }

        public init(
            fx: Double, fy: Double, cx: Double, cy: Double,
            width: Double, height: Double,
            blurScore: Double?,
            transformRowMajor: [Double]
        ) {
            self.fx = fx
            self.fy = fy
            self.cx = cx
            self.cy = cy
            self.width = width
            self.height = height
            self.blurScore = blurScore
            self.transformRowMajor = transformRowMajor
        }
    }

    public enum ImportError: Swift.Error, LocalizedError, Equatable {
        case noKeyframes
        case duplicateStem(String)
        case invalidImagePath(String)
        case invalidDimensions(stem: String)
        case invalidPose(stem: String, underlying: DatasetPoseConvention.ConversionError)

        public var errorDescription: String? {
            switch self {
            case .noKeyframes:
                return "This export contains no keyframes with cameras."
            case .duplicateStem(let stem):
                return "This export lists the keyframe \(stem) more than once."
            case .invalidImagePath(let path):
                return "The keyframe image path \(path) is not a safe dataset-relative path."
            case .invalidDimensions(let stem):
                return "The keyframe \(stem) has no valid image width and height."
            case .invalidPose(let stem, let underlying):
                return "The keyframe \(stem) has an unusable camera pose. \(underlying.localizedDescription)"
            }
        }
    }

    /// Blur scores at or below this value are counted as blurry for the
    /// advisory note. Matches the nerfstudio converter's default threshold.
    private static let advisoryBlurThreshold = 25.0

    public static func plan(fromKeyframes keyframes: [Keyframe], usedCorrectedCameras: Bool) throws -> DatasetImportPlan {
        guard !keyframes.isEmpty else { throw ImportError.noKeyframes }

        let ordered = keyframes.sorted { $0.stem < $1.stem }

        struct CameraKey: Hashable {
            let width: Int
            let height: Int
            let parameters: [Double]
        }
        var cameraIDsByKey: [CameraKey: Int] = [:]
        var cameras: [ColmapTextCamera] = []
        var images: [ColmapTextImage] = []
        var imageRefs: [DatasetImageRef] = []
        var seenStems = Set<String>()
        var blurryCount = 0

        for keyframe in ordered {
            guard seenStems.insert(keyframe.stem).inserted else {
                throw ImportError.duplicateStem(keyframe.stem)
            }
            guard let path = DatasetDeclaredPath.normalized(keyframe.imagePath) else {
                throw ImportError.invalidImagePath(keyframe.imagePath)
            }
            let camera = keyframe.camera
            guard camera.width > 0, camera.height > 0,
                  camera.width.rounded() == camera.width,
                  camera.height.rounded() == camera.height else {
                throw ImportError.invalidDimensions(stem: keyframe.stem)
            }

            let key = CameraKey(
                width: Int(camera.width),
                height: Int(camera.height),
                parameters: [camera.fx, camera.fy, camera.cx, camera.cy]
            )
            let cameraID: Int
            if let existing = cameraIDsByKey[key] {
                cameraID = existing
            } else {
                cameraID = cameraIDsByKey.count + 1
                cameraIDsByKey[key] = cameraID
                cameras.append(
                    ColmapTextCamera(
                        id: cameraID,
                        model: "PINHOLE",
                        width: key.width,
                        height: key.height,
                        parameters: key.parameters
                    )
                )
            }

            let pose: DatasetPoseConvention.ColmapPose
            do {
                pose = try DatasetPoseConvention.colmapPose(
                    fromPolycamCameraToWorld: camera.transformRowMajor
                )
            } catch let error as DatasetPoseConvention.ConversionError {
                throw ImportError.invalidPose(stem: keyframe.stem, underlying: error)
            }

            if let blur = camera.blurScore, blur <= advisoryBlurThreshold {
                blurryCount += 1
            }

            let imageID = images.count + 1
            images.append(ColmapTextImage(id: imageID, pose: pose, cameraID: cameraID, name: path))
            imageRefs.append(DatasetImageRef(entryID: keyframe.stem, declaredPath: path))
        }

        var notes: [String] = []
        if usedCorrectedCameras {
            notes.append("Used the export's corrected cameras.")
        }
        if blurryCount > 0 {
            notes.append("\(blurryCount) of \(ordered.count) keyframes look blurry. All posed keyframes are kept.")
        }

        return DatasetImportPlan(
            kind: .polycam,
            route: .seedTriangulate,
            images: imageRefs,
            model: ColmapTextModel(cameras: cameras, images: images),
            notes: notes
        )
    }
}
