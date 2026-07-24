import Foundation

/// An in-memory COLMAP sparse model destined for the canonical text layout
/// (`cameras.txt`, `images.txt`, `points3D.txt`). All dataset importers
/// converge on this representation; `ColmapTextModelEmitter` renders it
/// byte-deterministically so receipts can bind stable digests.
public struct ColmapTextModel: Sendable, Equatable {
    public var cameras: [ColmapTextCamera]
    public var images: [ColmapTextImage]
    public var points: [ColmapTextPoint3D]

    public init(cameras: [ColmapTextCamera], images: [ColmapTextImage], points: [ColmapTextPoint3D] = []) {
        self.cameras = cameras
        self.images = images
        self.points = points
    }
}

public struct ColmapTextCamera: Sendable, Equatable {
    public var id: Int
    public var model: String
    public var width: Int
    public var height: Int
    public var parameters: [Double]

    public init(id: Int, model: String, width: Int, height: Int, parameters: [Double]) {
        self.id = id
        self.model = model
        self.width = width
        self.height = height
        self.parameters = parameters
    }
}

public struct ColmapTextImage: Sendable, Equatable {
    public var id: Int
    public var pose: DatasetPoseConvention.ColmapPose
    public var cameraID: Int
    public var name: String
    /// `X Y POINT3D_ID` triples; empty for pose-only imports.
    public var observations: [ColmapTextObservation]

    public init(
        id: Int,
        pose: DatasetPoseConvention.ColmapPose,
        cameraID: Int,
        name: String,
        observations: [ColmapTextObservation] = []
    ) {
        self.id = id
        self.pose = pose
        self.cameraID = cameraID
        self.name = name
        self.observations = observations
    }
}

public struct ColmapTextObservation: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// -1 marks an observation with no triangulated point, matching COLMAP.
    public var point3DID: Int

    public init(x: Double, y: Double, point3DID: Int) {
        self.x = x
        self.y = y
        self.point3DID = point3DID
    }
}

public struct ColmapTextPoint3D: Sendable, Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var z: Double
    public var red: Int
    public var green: Int
    public var blue: Int
    public var error: Double
    public var track: [ColmapTextTrackElement]

    public init(
        id: Int,
        x: Double,
        y: Double,
        z: Double,
        red: Int,
        green: Int,
        blue: Int,
        error: Double,
        track: [ColmapTextTrackElement]
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.z = z
        self.red = red
        self.green = green
        self.blue = blue
        self.error = error
        self.track = track
    }
}

public struct ColmapTextTrackElement: Sendable, Equatable {
    public var imageID: Int
    public var point2DIndex: Int

    public init(imageID: Int, point2DIndex: Int) {
        self.imageID = imageID
        self.point2DIndex = point2DIndex
    }
}

public enum ColmapTextModelEmitter {
    public enum EmitError: Swift.Error, LocalizedError, Equatable {
        case noCameras
        case noImages
        case duplicateCameraID(Int)
        case duplicateImageID(Int)
        case duplicateImageName(String)
        case invalidImageName(String)
        case unknownCameraReference(imageID: Int, cameraID: Int)
        case duplicatePointID(Int)
        case unknownTrackImage(pointID: Int, imageID: Int)
        case invalidColorComponent(pointID: Int)
        case nonFiniteValue

        public var errorDescription: String? {
            switch self {
            case .noCameras:
                return "The dataset defines no cameras."
            case .noImages:
                return "The dataset defines no posed images."
            case .duplicateCameraID(let id):
                return "The dataset defines camera ID \(id) more than once."
            case .duplicateImageID(let id):
                return "The dataset defines image ID \(id) more than once."
            case .duplicateImageName(let name):
                return "The dataset lists the image \(name) more than once."
            case .invalidImageName(let name):
                return "The image name \(name) cannot be represented in a COLMAP model."
            case .unknownCameraReference(let imageID, let cameraID):
                return "Image \(imageID) references camera \(cameraID), which the dataset does not define."
            case .duplicatePointID(let id):
                return "The dataset defines point ID \(id) more than once."
            case .unknownTrackImage(let pointID, let imageID):
                return "Point \(pointID) references image \(imageID), which the dataset does not define."
            case .invalidColorComponent(let pointID):
                return "Point \(pointID) has a color component outside 0-255."
            case .nonFiniteValue:
                return "The dataset contains a numeric value that is not finite."
            }
        }
    }

    /// Renders the model as the three canonical text files. Entries are
    /// emitted sorted by ID so identical models always produce identical
    /// bytes regardless of importer iteration order.
    public static func emit(_ model: ColmapTextModel) throws -> (camerasTxt: String, imagesTxt: String, points3DTxt: String) {
        guard !model.cameras.isEmpty else { throw EmitError.noCameras }
        guard !model.images.isEmpty else { throw EmitError.noImages }

        var cameraIDs = Set<Int>()
        for camera in model.cameras {
            guard cameraIDs.insert(camera.id).inserted else {
                throw EmitError.duplicateCameraID(camera.id)
            }
            guard camera.parameters.allSatisfy({ $0.isFinite }) else {
                throw EmitError.nonFiniteValue
            }
        }

        var imageIDs = Set<Int>()
        var imageNames = Set<String>()
        for image in model.images {
            guard imageIDs.insert(image.id).inserted else {
                throw EmitError.duplicateImageID(image.id)
            }
            guard !image.name.isEmpty,
                  !image.name.contains("\n"),
                  !image.name.contains("\r"),
                  image.name == image.name.trimmingCharacters(in: .whitespaces) else {
                throw EmitError.invalidImageName(image.name)
            }
            guard imageNames.insert(image.name).inserted else {
                throw EmitError.duplicateImageName(image.name)
            }
            guard cameraIDs.contains(image.cameraID) else {
                throw EmitError.unknownCameraReference(imageID: image.id, cameraID: image.cameraID)
            }
            let pose = image.pose
            let poseValues = [pose.qw, pose.qx, pose.qy, pose.qz, pose.tx, pose.ty, pose.tz]
            guard poseValues.allSatisfy({ $0.isFinite }) else {
                throw EmitError.nonFiniteValue
            }
            guard image.observations.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw EmitError.nonFiniteValue
            }
        }

        var pointIDs = Set<Int>()
        for point in model.points {
            guard pointIDs.insert(point.id).inserted else {
                throw EmitError.duplicatePointID(point.id)
            }
            for component in [point.red, point.green, point.blue] where !(0...255).contains(component) {
                throw EmitError.invalidColorComponent(pointID: point.id)
            }
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite, point.error.isFinite else {
                throw EmitError.nonFiniteValue
            }
            for element in point.track where !imageIDs.contains(element.imageID) {
                throw EmitError.unknownTrackImage(pointID: point.id, imageID: element.imageID)
            }
        }

        let cameras = model.cameras.sorted { $0.id < $1.id }
        let images = model.images.sorted { $0.id < $1.id }
        let points = model.points.sorted { $0.id < $1.id }

        var camerasTxt = """
        # Camera list with one line of data per camera:
        #   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]
        # Number of cameras: \(cameras.count)

        """
        for camera in cameras {
            let params = camera.parameters.map(format).joined(separator: " ")
            camerasTxt += "\(camera.id) \(camera.model) \(camera.width) \(camera.height) \(params)\n"
        }

        var imagesTxt = """
        # Image list with two lines of data per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        #   POINTS2D[] as (X, Y, POINT3D_ID)
        # Number of images: \(images.count)

        """
        for image in images {
            let p = image.pose
            let poseFields = [p.qw, p.qx, p.qy, p.qz, p.tx, p.ty, p.tz].map(format).joined(separator: " ")
            imagesTxt += "\(image.id) \(poseFields) \(image.cameraID) \(image.name)\n"
            imagesTxt += image.observations
                .map { "\(format($0.x)) \(format($0.y)) \($0.point3DID)" }
                .joined(separator: " ")
            imagesTxt += "\n"
        }

        var points3DTxt = """
        # 3D point list with one line of data per point:
        #   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)
        # Number of points: \(points.count)

        """
        for point in points {
            var line = "\(point.id) \(format(point.x)) \(format(point.y)) \(format(point.z))"
            line += " \(point.red) \(point.green) \(point.blue) \(format(point.error))"
            for element in point.track {
                line += " \(element.imageID) \(element.point2DIndex)"
            }
            points3DTxt += line + "\n"
        }

        return (camerasTxt, imagesTxt, points3DTxt)
    }

    /// Swift's default `Double` description: shortest representation that
    /// round-trips exactly, locale-independent. COLMAP and the in-repo text
    /// parsers both read scientific notation.
    private static func format(_ value: Double) -> String {
        "\(value)"
    }
}
