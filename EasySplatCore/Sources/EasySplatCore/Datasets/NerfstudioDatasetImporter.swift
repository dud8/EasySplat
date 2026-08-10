import Foundation

/// Converts a Nerfstudio `transforms.json` into a pose-only COLMAP model.
/// The pure core consumes the decoded JSON and never touches the filesystem;
/// resolving `file_path` entries against real files happens in the preflight
/// shell.
///
/// Convention notes:
/// - `transform_matrix` is camera-to-world in the OpenGL basis; conversion
///   lives in `DatasetPoseConvention`.
/// - `applied_transform` records how the original capture was mapped into the
///   file's world frame. The poses in the file are already self-consistent,
///   and the pipeline treats world frames as arbitrary sim3, so it is
///   surfaced as a note rather than composed.
public enum NerfstudioDatasetImporter {
    public enum ImportError: Swift.Error, LocalizedError, Equatable {
        case unreadableJSON
        case noFrames
        case missingIntrinsics(frame: String)
        case invalidDimensions(frame: String)
        case unsupportedCameraModel(String)
        case inconsistentDistortion(frame: String, model: String)
        case invalidFramePath(String)
        case duplicateFramePath(String)
        case invalidPose(frame: String, underlying: DatasetPoseConvention.ConversionError)

        public var errorDescription: String? {
            switch self {
            case .unreadableJSON:
                return "The transforms.json file could not be read as a Nerfstudio dataset."
            case .noFrames:
                return "This dataset lists no images."
            case .missingIntrinsics(let frame):
                return "The frame \(frame) has no complete camera intrinsics (fl_x, fl_y, cx, cy)."
            case .invalidDimensions(let frame):
                return "The frame \(frame) has no valid image width and height."
            case .unsupportedCameraModel(let model):
                return "This dataset uses the camera model \(model), which EasySplat can't read. Re-export with a perspective (pinhole) or fisheye camera."
            case .inconsistentDistortion(let frame, let model):
                return "The frame \(frame) declares the \(model) camera model but carries distortion it cannot represent."
            case .invalidFramePath(let path):
                return "The frame path \(path) is not a safe dataset-relative path."
            case .duplicateFramePath(let path):
                return "This dataset lists the image \(path) more than once."
            case .invalidPose(let frame, let underlying):
                return "The frame \(frame) has an unusable camera pose. \(underlying.localizedDescription)"
            }
        }
    }

    struct Transforms: Decodable {
        var cameraModel: String?
        var flX: Double?
        var flY: Double?
        var cx: Double?
        var cy: Double?
        var w: Double?
        var h: Double?
        var k1: Double?
        var k2: Double?
        var k3: Double?
        var k4: Double?
        var p1: Double?
        var p2: Double?
        var appliedTransform: [[Double]]?
        var frames: [Frame]

        enum CodingKeys: String, CodingKey {
            case cameraModel = "camera_model"
            case flX = "fl_x"
            case flY = "fl_y"
            case cx, cy, w, h, k1, k2, k3, k4, p1, p2
            case appliedTransform = "applied_transform"
            case frames
        }
    }

    struct Frame: Decodable {
        var filePath: String
        var transformMatrix: [[Double]]
        var flX: Double?
        var flY: Double?
        var cx: Double?
        var cy: Double?
        var w: Double?
        var h: Double?
        var k1: Double?
        var k2: Double?
        var k3: Double?
        var k4: Double?
        var p1: Double?
        var p2: Double?

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case transformMatrix = "transform_matrix"
            case flX = "fl_x"
            case flY = "fl_y"
            case cx, cy, w, h, k1, k2, k3, k4, p1, p2
        }
    }

    /// Distortion at or below this magnitude is treated as zero. Exporters
    /// routinely write exact zeros as tiny float noise.
    private static let distortionEpsilon = 1e-9

    public static func plan(fromTransformsJSON data: Data) throws -> DatasetImportPlan {
        let transforms: Transforms
        do {
            transforms = try JSONDecoder().decode(Transforms.self, from: data)
        } catch {
            throw ImportError.unreadableJSON
        }
        guard !transforms.frames.isEmpty else { throw ImportError.noFrames }

        // Deterministic IDs regardless of the file's frame order.
        let frames = transforms.frames.sorted { $0.filePath < $1.filePath }

        struct CameraKey: Hashable {
            let model: String
            let width: Int
            let height: Int
            let parameters: [Double]
        }
        var cameraIDsByKey: [CameraKey: Int] = [:]
        var cameras: [ColmapTextCamera] = []
        var images: [ColmapTextImage] = []
        var imageRefs: [DatasetImageRef] = []
        var seenPaths = Set<String>()

        for frame in frames {
            guard let path = DatasetDeclaredPath.normalized(frame.filePath) else {
                throw ImportError.invalidFramePath(frame.filePath)
            }
            guard seenPaths.insert(path).inserted else {
                throw ImportError.duplicateFramePath(path)
            }

            guard
                let fx = frame.flX ?? transforms.flX,
                let fy = frame.flY ?? transforms.flY,
                let cx = frame.cx ?? transforms.cx,
                let cy = frame.cy ?? transforms.cy
            else {
                throw ImportError.missingIntrinsics(frame: path)
            }
            guard
                let widthValue = frame.w ?? transforms.w,
                let heightValue = frame.h ?? transforms.h,
                widthValue > 0, heightValue > 0,
                widthValue.rounded() == widthValue, heightValue.rounded() == heightValue
            else {
                throw ImportError.invalidDimensions(frame: path)
            }
            let width = Int(widthValue)
            let height = Int(heightValue)

            let k1 = frame.k1 ?? transforms.k1 ?? 0
            let k2 = frame.k2 ?? transforms.k2 ?? 0
            let k3 = frame.k3 ?? transforms.k3 ?? 0
            let k4 = frame.k4 ?? transforms.k4 ?? 0
            let p1 = frame.p1 ?? transforms.p1 ?? 0
            let p2 = frame.p2 ?? transforms.p2 ?? 0

            let (model, parameters) = try colmapCamera(
                declaredModel: transforms.cameraModel,
                frame: path,
                fx: fx, fy: fy, cx: cx, cy: cy,
                k1: k1, k2: k2, k3: k3, k4: k4, p1: p1, p2: p2
            )

            let key = CameraKey(model: model, width: width, height: height, parameters: parameters)
            let cameraID: Int
            if let existing = cameraIDsByKey[key] {
                cameraID = existing
            } else {
                cameraID = cameraIDsByKey.count + 1
                cameraIDsByKey[key] = cameraID
                cameras.append(
                    ColmapTextCamera(id: cameraID, model: model, width: width, height: height, parameters: parameters)
                )
            }

            let pose: DatasetPoseConvention.ColmapPose
            do {
                pose = try DatasetPoseConvention.colmapPose(
                    fromNerfstudioCameraToWorld: frame.transformMatrix
                )
            } catch let error as DatasetPoseConvention.ConversionError {
                throw ImportError.invalidPose(frame: path, underlying: error)
            }

            let imageID = images.count + 1
            images.append(ColmapTextImage(id: imageID, pose: pose, cameraID: cameraID, name: path))
            imageRefs.append(DatasetImageRef(entryID: path, declaredPath: path))
        }

        var notes: [String] = []
        if transforms.appliedTransform != nil {
            notes.append("The dataset records an applied_transform; poses are used in the file's own frame.")
        }

        return DatasetImportPlan(
            kind: .nerfstudio,
            route: .seedTriangulate,
            images: imageRefs,
            model: ColmapTextModel(cameras: cameras, images: images),
            notes: notes
        )
    }

    private static func colmapCamera(
        declaredModel: String?,
        frame: String,
        fx: Double, fy: Double, cx: Double, cy: Double,
        k1: Double, k2: Double, k3: Double, k4: Double, p1: Double, p2: Double
    ) throws -> (model: String, parameters: [Double]) {
        func isZero(_ value: Double) -> Bool { abs(value) <= distortionEpsilon }
        let radialTangentialFree = isZero(k1) && isZero(k2) && isZero(p1) && isZero(p2)
        let higherRadialFree = isZero(k3) && isZero(k4)

        let model: String
        if let declared = declaredModel {
            switch declared {
            case "PINHOLE", "SIMPLE_PINHOLE":
                model = "PINHOLE"
            case "OPENCV":
                model = "OPENCV"
            case "OPENCV_FISHEYE":
                model = "OPENCV_FISHEYE"
            default:
                throw ImportError.unsupportedCameraModel(declared)
            }
        } else {
            model = radialTangentialFree && higherRadialFree ? "PINHOLE" : "OPENCV"
        }

        switch model {
        case "PINHOLE":
            guard radialTangentialFree, higherRadialFree else {
                throw ImportError.inconsistentDistortion(frame: frame, model: model)
            }
            return (model, [fx, fy, cx, cy])
        case "OPENCV":
            guard higherRadialFree else {
                throw ImportError.inconsistentDistortion(frame: frame, model: model)
            }
            return (model, [fx, fy, cx, cy, k1, k2, p1, p2])
        default:
            guard isZero(p1), isZero(p2) else {
                throw ImportError.inconsistentDistortion(frame: frame, model: model)
            }
            return (model, [fx, fy, cx, cy, k1, k2, k3, k4])
        }
    }
}
