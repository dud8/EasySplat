import CryptoKit
import Darwin
import Foundation

/// Reprojects COLMAP text-model tracks into their source images.
/// These are measured pixel residuals; mapper summaries and normalized scores are not accepted here.
enum ColmapResidualAnalyzer {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case missingFile(String)
        case malformedTextFile(String)
        case malformedRecord(file: String, line: Int)
        case unsupportedCameraModel(String)
        case missingPoint(Int64)
        case duplicatePoint(Int64)
        case duplicateImage(Int)
        case duplicateImageName(String)
        case duplicateTrack(imageID: Int, point2DIndex: Int)
        case inconsistentTrack(pointID: Int64, imageID: Int, point2DIndex: Int)
        case nonPositiveDepthObservation(pointID: Int64, imageLine: Int)
        case unprojectableObservation(pointID: Int64, imageLine: Int)
        case noTrackedObservations

        var errorDescription: String? {
            switch self {
            case .missingFile(let name):
                return "COLMAP model is missing \(name)."
            case .malformedTextFile(let name):
                return "COLMAP model contains invalid UTF-8 in \(name)."
            case .malformedRecord(let file, let line):
                return "COLMAP model has a malformed \(file) record at line \(line)."
            case .unsupportedCameraModel(let model):
                return "COLMAP camera model \(model) is not supported for residual measurement."
            case .missingPoint(let id):
                return "COLMAP observation references missing point \(id)."
            case .duplicatePoint(let id):
                return "COLMAP model contains duplicate point ID \(id)."
            case .duplicateImage(let id):
                return "COLMAP model contains duplicate image ID \(id)."
            case .duplicateImageName(let name):
                return "COLMAP model contains duplicate image name \(name)."
            case .duplicateTrack(let imageID, let point2DIndex):
                return "COLMAP track assigns image \(imageID) observation \(point2DIndex) more than once."
            case .inconsistentTrack(let pointID, let imageID, let point2DIndex):
                return "COLMAP point \(pointID) and image \(imageID) observation \(point2DIndex) do not reference each other."
            case .nonPositiveDepthObservation(let pointID, let imageLine):
                return "COLMAP point \(pointID) is not in front of the camera at images.txt line \(imageLine)."
            case .unprojectableObservation(let pointID, let imageLine):
                return "COLMAP observation for point \(pointID) at images.txt line \(imageLine) cannot be projected."
            case .noTrackedObservations:
                return "COLMAP model has no tracked observations with measurable pixel residuals."
            }
        }
    }

    struct Result: Sendable, Equatable {
        let registeredViewCount: Int
        let registeredImageNames: [String]
        let measuredImageNames: [String]
        let observationCountByImage: [String: Int]
        let cameraModel: String
        let cameraModelsByID: [Int: String]
        let cameraIDsByImageName: [String: Int]
        let cameraSamples: [OrientationCameraSample]
        let pointCount: Int
        let observationCount: Int
        /// Stable identity of the image-name/point-index track partition only.
        let pointTrackTopologySHA256: String
        let meanPixelResidual: Double
        let medianPixelResidual: Double
        let p90PixelResidual: Double
        let provenance: String
    }

    private struct Point3 {
        let x: Double
        let y: Double
        let z: Double
    }

    private struct ObservationKey: Hashable {
        let imageID: Int
        let point2DIndex: Int
    }

    private struct PointRecord {
        let position: Point3
        let track: [ObservationKey]
    }

    private struct ParsedPoints {
        let records: [Int64: PointRecord]
        let trackOwners: [ObservationKey: Int64]
    }

    private struct ParsedCameras {
        let records: [Int: Camera]
        let modelsByID: [Int: String]
        let firstModel: String
    }

    private struct Observation {
        let pointID: Int64
        let imageID: Int
        let point2DIndex: Int
        let pixelResidual: Double
        let cameraToPointDistance: Double
        let angularResidualRadians: Double
    }

    private struct Pose {
        let rotationWorldToCamera: OrientationMatrix3
        let translation: OrientationVector3

        init?(
            qw: Double,
            qx: Double,
            qy: Double,
            qz: Double,
            tx: Double,
            ty: Double,
            tz: Double
        ) {
            let norm = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
            guard norm.isFinite, norm > 0,
                  tx.isFinite, ty.isFinite, tz.isFinite else {
                return nil
            }
            let w = qw / norm
            let x = qx / norm
            let y = qy / norm
            let z = qz / norm
            rotationWorldToCamera = OrientationMatrix3(
                rows: OrientationVector3(
                    x: 1 - 2 * (y * y + z * z),
                    y: 2 * (x * y - z * w),
                    z: 2 * (x * z + y * w)
                ),
                OrientationVector3(
                    x: 2 * (x * y + z * w),
                    y: 1 - 2 * (x * x + z * z),
                    z: 2 * (y * z - x * w)
                ),
                OrientationVector3(
                    x: 2 * (x * z - y * w),
                    y: 2 * (y * z + x * w),
                    z: 1 - 2 * (x * x + y * y)
                )
            )
            translation = OrientationVector3(x: tx, y: ty, z: tz)
        }

        func cameraPoint(_ point: Point3) -> Point3? {
            let rotated = rotationWorldToCamera.applied(
                to: OrientationVector3(x: point.x, y: point.y, z: point.z)
            )
            let result = Point3(
                x: rotated.x + translation.x,
                y: rotated.y + translation.y,
                z: rotated.z + translation.z
            )
            guard result.x.isFinite, result.y.isFinite, result.z.isFinite else {
                return nil
            }
            return result
        }
    }

    private enum Camera {
        case simplePinhole(f: Double, cx: Double, cy: Double)
        case pinhole(fx: Double, fy: Double, cx: Double, cy: Double)
        case simpleRadial(f: Double, cx: Double, cy: Double, k: Double)
        case radial(f: Double, cx: Double, cy: Double, k1: Double, k2: Double)
        case openCV(fx: Double, fy: Double, cx: Double, cy: Double, k1: Double, k2: Double, p1: Double, p2: Double)
        case openCVFisheye(fx: Double, fy: Double, cx: Double, cy: Double, k1: Double, k2: Double, k3: Double, k4: Double)

        var conservativeFocalLength: Double {
            switch self {
            case .simplePinhole(let f, _, _),
                 .simpleRadial(let f, _, _, _),
                 .radial(let f, _, _, _, _):
                return f
            case .pinhole(let fx, let fy, _, _),
                 .openCV(let fx, let fy, _, _, _, _, _, _),
                 .openCVFisheye(let fx, let fy, _, _, _, _, _, _):
                return min(fx, fy)
            }
        }

        func project(_ point: Point3) -> (x: Double, y: Double)? {
            let x = point.x / point.z
            let y = point.y / point.z
            guard x.isFinite, y.isFinite else { return nil }

            let pixel: (Double, Double)
            switch self {
            case .simplePinhole(let f, let cx, let cy):
                pixel = (f * x + cx, f * y + cy)
            case .pinhole(let fx, let fy, let cx, let cy):
                pixel = (fx * x + cx, fy * y + cy)
            case .simpleRadial(let f, let cx, let cy, let k):
                let r2 = x * x + y * y
                let scale = 1 + k * r2
                pixel = (f * x * scale + cx, f * y * scale + cy)
            case .radial(let f, let cx, let cy, let k1, let k2):
                let r2 = x * x + y * y
                let scale = 1 + k1 * r2 + k2 * r2 * r2
                pixel = (f * x * scale + cx, f * y * scale + cy)
            case .openCV(let fx, let fy, let cx, let cy, let k1, let k2, let p1, let p2):
                let r2 = x * x + y * y
                let radial = 1 + k1 * r2 + k2 * r2 * r2
                let distortedX = x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
                let distortedY = y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y
                pixel = (fx * distortedX + cx, fy * distortedY + cy)
            case .openCVFisheye(let fx, let fy, let cx, let cy, let k1, let k2, let k3, let k4):
                let radius = sqrt(x * x + y * y)
                let scale: Double
                if radius <= 1e-12 {
                    scale = 1
                } else {
                    let theta = atan(radius)
                    let theta2 = theta * theta
                    let distortedTheta = theta * (
                        1
                            + k1 * theta2
                            + k2 * theta2 * theta2
                            + k3 * theta2 * theta2 * theta2
                            + k4 * theta2 * theta2 * theta2 * theta2
                    )
                    scale = distortedTheta / radius
                }
                pixel = (fx * x * scale + cx, fy * y * scale + cy)
            }
            guard pixel.0.isFinite, pixel.1.isFinite else { return nil }
            return pixel
        }
    }

    static func analyze(modelDirectory: URL) throws -> Result {
        let stream = try ObservationStream(modelDirectory: modelDirectory)
        let statistics = ResidualStatistics(expectedCount: stream.expectedObservationCount)
        while let observation = try stream.next() {
            statistics.add(observation.pixelResidual)
        }
        return try makeResult(stream: stream, statistics: statistics)
    }

    /// Reads and validates only `cameras.txt`. Learned seed models may contain no
    /// triangulated observations yet, so camera-policy validation must not depend
    /// on residual analysis succeeding.
    static func cameraModels(
        modelDirectory: URL,
        checkCancellation: () throws -> Void = {}
    ) throws -> [Int: String] {
        try parseCameras(
            at: modelDirectory.appendingPathComponent("cameras.txt"),
            checkCancellation: checkCancellation
        ).modelsByID
    }

    static func analyzeConditioning(
        modelDirectory: URL,
        maximumRayPairEvaluations: Int = 100_000_000,
        checkCancellation: () throws -> Void = {}
    ) throws -> GeometryConditioningAnalysis {
        guard maximumRayPairEvaluations > 0 else {
            throw GeometryConditioningFailure.rayPairWorkLimitExceeded(
                maximum: maximumRayPairEvaluations
            )
        }
        try checkCancellation()
        let snapshot = try GeometryModelSnapshot.capture(
            in: modelDirectory,
            checkCancellation: checkCancellation
        )
        let stream = try ObservationStream(
            modelDirectory: modelDirectory,
            checkCancellation: checkCancellation
        )
        let statistics = ResidualStatistics(expectedCount: stream.expectedObservationCount)
        var cameraToPointDistances: [Double] = []
        cameraToPointDistances.reserveCapacity(stream.expectedObservationCount)
        while let observation = try stream.next(checkCancellation: checkCancellation) {
            statistics.add(observation.pixelResidual)
            cameraToPointDistances.append(observation.cameraToPointDistance)
        }
        let residuals = try makeResult(
            stream: stream,
            statistics: statistics,
            checkCancellation: checkCancellation
        )
        let measurement = try stream.conditioningMeasurement(
            cameraToPointDistances: cameraToPointDistances,
            maximumRayPairEvaluations: maximumRayPairEvaluations,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        try GeometryModelSnapshot.validate(snapshot, at: modelDirectory)
        return GeometryConditioningAnalysis(
            residuals: residuals,
            measurement: measurement,
            modelSnapshot: snapshot
        )
    }

    private static func makeResult(
        stream: ObservationStream,
        statistics: ResidualStatistics,
        checkCancellation: () throws -> Void = {}
    ) throws -> Result {
        guard let summary = statistics.finish() else {
            throw Error.noTrackedObservations
        }
        let pointTrackTopologySHA256 = try stream.pointTrackTopologySHA256(
            checkCancellation: checkCancellation
        )
        let registeredImageNames = stream.registeredImageNamesByID.values.sorted()
        return Result(
            registeredViewCount: registeredImageNames.count,
            registeredImageNames: registeredImageNames,
            measuredImageNames: stream.observationCountByImage.keys.sorted(),
            observationCountByImage: stream.observationCountByImage,
            cameraModel: stream.cameraModel,
            cameraModelsByID: stream.cameraModelsByID,
            cameraIDsByImageName: stream.cameraIDsByImageName,
            cameraSamples: stream.cameraSamplesByID.keys.sorted().compactMap {
                stream.cameraSamplesByID[$0]
            },
            pointCount: stream.pointCount,
            observationCount: summary.count,
            pointTrackTopologySHA256: pointTrackTopologySHA256,
            meanPixelResidual: summary.mean,
            medianPixelResidual: summary.median,
            p90PixelResidual: summary.p90,
            provenance: "colmap-text-tracks-v1"
        )
    }

    private static func parseCameras(
        at url: URL,
        checkCancellation: () throws -> Void = {}
    ) throws -> ParsedCameras {
        let reader = try makeReader(at: url, maximumBytes: ColmapTextFileLimits.cameras)
        var cameras: [Int: Camera] = [:]
        var modelsByID: [Int: String] = [:]
        var firstModel: String?
        var lineCount = 0
        while let rawLine = try nextLine(
            from: reader,
            checkCancellation: checkCancellation
        ) {
            lineCount += 1
            if lineCount.isMultiple(of: 4_096) { try checkCancellation() }
            let line = rawLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var fields = TokenScanner(line)
            guard let idField = fields.next(),
                  let modelField = fields.next(),
                  let widthField = fields.next(),
                  let heightField = fields.next(),
                  let id = Int(idField), id > 0,
                  let width = Int(widthField), width > 0,
                  let height = Int(heightField), height > 0,
                  cameras[id] == nil else {
                throw Error.malformedRecord(file: "cameras.txt", line: rawLine.number)
            }
            let model = String(modelField)
            var parameters: [Double] = []
            while let field = fields.next() {
                guard let parameter = Double(field), parameter.isFinite else {
                    throw Error.malformedRecord(file: "cameras.txt", line: rawLine.number)
                }
                parameters.append(parameter)
            }
            cameras[id] = try camera(
                model: model,
                parameters: parameters,
                lineNumber: rawLine.number
            )
            modelsByID[id] = model
            if firstModel == nil { firstModel = model }
        }
        guard let firstModel else {
            throw Error.malformedRecord(file: "cameras.txt", line: 0)
        }
        return ParsedCameras(
            records: cameras,
            modelsByID: modelsByID,
            firstModel: firstModel
        )
    }

    private static func camera(
        model: String,
        parameters: [Double],
        lineNumber: Int
    ) throws -> Camera {
        switch (model, parameters.count) {
        case ("SIMPLE_PINHOLE", 3):
            guard parameters[0] > 0 else {
                throw Error.malformedRecord(file: "cameras.txt", line: lineNumber)
            }
            return .simplePinhole(f: parameters[0], cx: parameters[1], cy: parameters[2])
        case ("PINHOLE", 4):
            guard parameters[0] > 0, parameters[1] > 0 else {
                throw Error.malformedRecord(file: "cameras.txt", line: lineNumber)
            }
            return .pinhole(fx: parameters[0], fy: parameters[1], cx: parameters[2], cy: parameters[3])
        case ("SIMPLE_RADIAL", 4):
            guard parameters[0] > 0 else {
                throw Error.malformedRecord(file: "cameras.txt", line: lineNumber)
            }
            return .simpleRadial(f: parameters[0], cx: parameters[1], cy: parameters[2], k: parameters[3])
        case ("RADIAL", 5):
            guard parameters[0] > 0 else {
                throw Error.malformedRecord(file: "cameras.txt", line: lineNumber)
            }
            return .radial(f: parameters[0], cx: parameters[1], cy: parameters[2], k1: parameters[3], k2: parameters[4])
        case ("OPENCV", 8):
            guard parameters[0] > 0, parameters[1] > 0 else {
                throw Error.malformedRecord(file: "cameras.txt", line: lineNumber)
            }
            return .openCV(
                fx: parameters[0], fy: parameters[1], cx: parameters[2], cy: parameters[3],
                k1: parameters[4], k2: parameters[5], p1: parameters[6], p2: parameters[7]
            )
        case ("OPENCV_FISHEYE", 8):
            guard parameters[0] > 0, parameters[1] > 0 else {
                throw Error.malformedRecord(file: "cameras.txt", line: lineNumber)
            }
            return .openCVFisheye(
                fx: parameters[0], fy: parameters[1], cx: parameters[2], cy: parameters[3],
                k1: parameters[4], k2: parameters[5], k3: parameters[6], k4: parameters[7]
            )
        case ("SIMPLE_PINHOLE", _), ("PINHOLE", _), ("SIMPLE_RADIAL", _), ("RADIAL", _),
             ("OPENCV", _), ("OPENCV_FISHEYE", _):
            throw Error.malformedRecord(file: "cameras.txt", line: lineNumber)
        default:
            throw Error.unsupportedCameraModel(model)
        }
    }

    private static func parsePoints(
        at url: URL,
        checkCancellation: () throws -> Void = {}
    ) throws -> ParsedPoints {
        let reader = try makeReader(at: url, maximumBytes: ColmapTextFileLimits.points)
        var points: [Int64: PointRecord] = [:]
        var trackOwners: [ObservationKey: Int64] = [:]
        var lineCount = 0
        var trackPairCount = 0
        while let rawLine = try nextLine(
            from: reader,
            checkCancellation: checkCancellation
        ) {
            lineCount += 1
            if lineCount.isMultiple(of: 4_096) { try checkCancellation() }
            let line = rawLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var fields = TokenScanner(line)
            guard let idField = fields.next(),
                  let xField = fields.next(),
                  let yField = fields.next(),
                  let zField = fields.next(),
                  let redField = fields.next(),
                  let greenField = fields.next(),
                  let blueField = fields.next(),
                  let errorField = fields.next(),
                  let id = Int64(idField), id > 0,
                  let x = Double(xField), x.isFinite,
                  let y = Double(yField), y.isFinite,
                  let z = Double(zField), z.isFinite,
                  let red = Int(redField), (0...255).contains(red),
                  let green = Int(greenField), (0...255).contains(green),
                  let blue = Int(blueField), (0...255).contains(blue),
                  let error = Double(errorField), error.isFinite, error >= 0 else {
                throw Error.malformedRecord(file: "points3D.txt", line: rawLine.number)
            }
            guard points[id] == nil else { throw Error.duplicatePoint(id) }

            var track: [ObservationKey] = []
            while let imageIDField = fields.next() {
                guard let point2DIndexField = fields.next(),
                      let imageID = Int(imageIDField), imageID > 0,
                      let point2DIndex = Int(point2DIndexField), point2DIndex >= 0 else {
                    throw Error.malformedRecord(file: "points3D.txt", line: rawLine.number)
                }
                let key = ObservationKey(imageID: imageID, point2DIndex: point2DIndex)
                guard trackOwners[key] == nil else {
                    throw Error.duplicateTrack(imageID: imageID, point2DIndex: point2DIndex)
                }
                trackOwners[key] = id
                track.append(key)
                trackPairCount += 1
                if trackPairCount.isMultiple(of: 4_096) { try checkCancellation() }
            }
            guard !track.isEmpty else {
                throw Error.malformedRecord(file: "points3D.txt", line: rawLine.number)
            }
            points[id] = PointRecord(
                position: Point3(x: x, y: y, z: z),
                track: track
            )
        }
        return ParsedPoints(records: points, trackOwners: trackOwners)
    }

    private static func makeReader(
        at url: URL,
        maximumBytes: Int
    ) throws -> BoundedUTF8LineReader {
        do {
            return try BoundedUTF8LineReader(
                at: url,
                maximumBytes: maximumBytes,
                maximumLineBytes: min(maximumBytes, ColmapTextFileLimits.maximumLine)
            )
        } catch let readerError as BoundedUTF8LineReader.Error {
            if case .cannotOpen(let name, let code) = readerError, code == ENOENT {
                throw Error.missingFile(name)
            }
            throw readerError
        }
    }

    private static func nextLine(
        from reader: BoundedUTF8LineReader,
        checkCancellation: () throws -> Void = {}
    ) throws -> BoundedUTF8LineReader.Line? {
        do {
            return try reader.next(checkCancellation: checkCancellation)
        } catch BoundedUTF8LineReader.Error.invalidUTF8(let name) {
            throw Error.malformedTextFile(name)
        }
    }

    private struct TokenScanner {
        private let text: String
        private let utf8: String.UTF8View
        private var index: String.Index

        init(_ text: String) {
            self.text = text
            utf8 = text.utf8
            index = text.startIndex
        }

        mutating func next() -> Substring? {
            while index < text.endIndex, isWhitespace(at: index) {
                advanceIndex()
            }
            guard index < text.endIndex else { return nil }
            let start = index
            while index < text.endIndex, !isWhitespace(at: index) {
                advanceIndex()
            }
            return text[start..<index]
        }

        private func isWhitespace(at index: String.Index) -> Bool {
            let byte = utf8[index]
            if byte < 0x80 {
                return byte == 0x20 || (0x09...0x0D).contains(byte)
            }
            return text[index].isWhitespace
        }

        private mutating func advanceIndex() {
            if utf8[index] < 0x80 {
                let next = utf8.index(after: index)
                if next < utf8.endIndex, utf8[next] >= 0x80 {
                    text.formIndex(after: &index)
                } else {
                    index = next
                }
            } else {
                text.formIndex(after: &index)
            }
        }
    }

    private final class ObservationStream {
        private struct Header {
            let imageID: Int
            let imageName: String
            let lineNumber: Int
            let camera: Camera
            let pose: Pose
        }

        let pointCount: Int
        let expectedObservationCount: Int
        let cameraModel: String
        let cameraModelsByID: [Int: String]
        private(set) var registeredImageNamesByID: [Int: String] = [:]
        private(set) var cameraIDsByImageName: [String: Int] = [:]
        private(set) var observationCountByImage: [String: Int] = [:]
        private(set) var cameraSamplesByID: [Int: OrientationCameraSample] = [:]
        private var angularResidualByObservation: [ObservationKey: Double] = [:]

        private let reader: BoundedUTF8LineReader
        private let points: [Int64: PointRecord]
        private var unverifiedTracks: [ObservationKey: Int64]
        private var registeredImageNames = Set<String>()
        private var observationFields: TokenScanner?
        private var observationLineNumber = 0
        private var point2DIndex = 0
        private var scannedImageLineCount = 0
        private var scannedObservationTripleCount = 0
        private var header: Header?
        private var finished = false

        init(
            modelDirectory: URL,
            checkCancellation: () throws -> Void = {}
        ) throws {
            let camerasURL = modelDirectory.appendingPathComponent("cameras.txt")
            let pointsURL = modelDirectory.appendingPathComponent("points3D.txt")
            let imagesURL = modelDirectory.appendingPathComponent("images.txt")
            let parsedCameras = try ColmapResidualAnalyzer.parseCameras(
                at: camerasURL,
                checkCancellation: checkCancellation
            )
            let parsedPoints = try ColmapResidualAnalyzer.parsePoints(
                at: pointsURL,
                checkCancellation: checkCancellation
            )
            points = parsedPoints.records
            unverifiedTracks = parsedPoints.trackOwners
            pointCount = parsedPoints.records.count
            expectedObservationCount = parsedPoints.trackOwners.count
            reader = try ColmapResidualAnalyzer.makeReader(
                at: imagesURL,
                maximumBytes: ColmapTextFileLimits.images
            )
            cameras = parsedCameras.records
            cameraModelsByID = parsedCameras.modelsByID
            cameraModel = parsedCameras.firstModel
        }

        private let cameras: [Int: Camera]

        func next(
            checkCancellation: () throws -> Void = {}
        ) throws -> Observation? {
            guard !finished else { return nil }
            while true {
                if var fields = observationFields {
                    guard let observedXField = fields.next() else {
                        try finalizeCurrentImage()
                        observationFields = nil
                        header = nil
                        continue
                    }
                    guard let observedYField = fields.next(),
                          let pointIDField = fields.next(),
                          let observedX = Double(observedXField),
                          observedX.isFinite,
                          let observedY = Double(observedYField),
                          observedY.isFinite,
                          let pointID = Int64(pointIDField), pointID >= -1,
                          let header else {
                        throw Error.malformedRecord(
                            file: "images.txt",
                            line: observationLineNumber
                        )
                    }
                    observationFields = fields
                    let currentPoint2DIndex = point2DIndex
                    point2DIndex += 1
                    scannedObservationTripleCount += 1
                    if scannedObservationTripleCount.isMultiple(of: 4_096) {
                        try checkCancellation()
                    }
                    if pointID == -1 { continue }

                    let key = ObservationKey(
                        imageID: header.imageID,
                        point2DIndex: currentPoint2DIndex
                    )
                    guard let point = points[pointID] else {
                        throw Error.missingPoint(pointID)
                    }
                    guard unverifiedTracks.removeValue(forKey: key) == pointID else {
                        throw Error.inconsistentTrack(
                            pointID: pointID,
                            imageID: header.imageID,
                            point2DIndex: currentPoint2DIndex
                        )
                    }
                    guard let cameraPoint = header.pose.cameraPoint(point.position) else {
                        throw Error.unprojectableObservation(
                            pointID: pointID,
                            imageLine: header.lineNumber
                        )
                    }
                    guard cameraPoint.z > 1e-12 else {
                        throw Error.nonPositiveDepthObservation(
                            pointID: pointID,
                            imageLine: header.lineNumber
                        )
                    }
                    guard let projected = header.camera.project(cameraPoint) else {
                        throw Error.unprojectableObservation(
                            pointID: pointID,
                            imageLine: header.lineNumber
                        )
                    }
                    let residual = hypot(projected.x - observedX, projected.y - observedY)
                    guard residual.isFinite else {
                        throw Error.unprojectableObservation(
                            pointID: pointID,
                            imageLine: header.lineNumber
                        )
                    }
                    observationCountByImage[header.imageName, default: 0] += 1
                    let angularResidual = atan(
                        residual / header.camera.conservativeFocalLength
                    )
                    angularResidualByObservation[key] = angularResidual
                    return Observation(
                        pointID: pointID,
                        imageID: header.imageID,
                        point2DIndex: currentPoint2DIndex,
                        pixelResidual: residual,
                        cameraToPointDistance: hypot(
                            hypot(cameraPoint.x, cameraPoint.y),
                            cameraPoint.z
                        ),
                        angularResidualRadians: angularResidual
                    )
                }

                guard try beginNextImage(checkCancellation: checkCancellation) else {
                    return nil
                }
            }
        }

        private func beginNextImage(
            checkCancellation: () throws -> Void
        ) throws -> Bool {
            while let rawLine = try nextImageLine(checkCancellation: checkCancellation) {
                let line = rawLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }

                var fields = TokenScanner(line)
                guard let imageIDField = fields.next(),
                      let qwField = fields.next(),
                      let qxField = fields.next(),
                      let qyField = fields.next(),
                      let qzField = fields.next(),
                      let txField = fields.next(),
                      let tyField = fields.next(),
                      let tzField = fields.next(),
                      let cameraIDField = fields.next(),
                      let firstNameField = fields.next(),
                      let imageID = Int(imageIDField),
                      let qw = Double(qwField),
                      let qx = Double(qxField),
                      let qy = Double(qyField),
                      let qz = Double(qzField),
                      let tx = Double(txField),
                      let ty = Double(tyField),
                      let tz = Double(tzField),
                      let cameraID = Int(cameraIDField),
                      let camera = cameras[cameraID],
                      imageID > 0,
                      cameraID > 0,
                      qw.isFinite,
                      qx.isFinite,
                      qy.isFinite,
                      qz.isFinite,
                      tx.isFinite,
                      ty.isFinite,
                      tz.isFinite else {
                    throw Error.malformedRecord(file: "images.txt", line: rawLine.number)
                }
                let quaternionNormSquared = qw * qw + qx * qx + qy * qy + qz * qz
                guard quaternionNormSquared.isFinite, quaternionNormSquared > 0,
                      let pose = Pose(
                          qw: qw,
                          qx: qx,
                          qy: qy,
                          qz: qz,
                          tx: tx,
                          ty: ty,
                          tz: tz
                      ) else {
                    throw Error.malformedRecord(file: "images.txt", line: rawLine.number)
                }

                let imageName = String(line[firstNameField.startIndex...])
                guard registeredImageNamesByID[imageID] == nil else {
                    throw Error.duplicateImage(imageID)
                }
                guard registeredImageNames.insert(imageName).inserted else {
                    throw Error.duplicateImageName(imageName)
                }
                guard let observations = try nextImageLine(
                    checkCancellation: checkCancellation
                ) else {
                    throw Error.malformedRecord(file: "images.txt", line: rawLine.number)
                }

                registeredImageNamesByID[imageID] = imageName
                cameraIDsByImageName[imageName] = cameraID
                header = Header(
                    imageID: imageID,
                    imageName: imageName,
                    lineNumber: rawLine.number,
                    camera: camera,
                    pose: pose
                )
                observationFields = TokenScanner(observations.text)
                observationLineNumber = observations.number
                point2DIndex = 0
                return true
            }

            finished = true
            if let (key, pointID) = unverifiedTracks.first {
                throw Error.inconsistentTrack(
                    pointID: pointID,
                    imageID: key.imageID,
                    point2DIndex: key.point2DIndex
                )
            }
            return false
        }

        private func nextImageLine(
            checkCancellation: () throws -> Void
        ) throws -> BoundedUTF8LineReader.Line? {
            let line = try ColmapResidualAnalyzer.nextLine(
                from: reader,
                checkCancellation: checkCancellation
            )
            if line != nil {
                scannedImageLineCount += 1
                if scannedImageLineCount.isMultiple(of: 4_096) {
                    try checkCancellation()
                }
            }
            return line
        }

        private func finalizeCurrentImage() throws {
            guard let header else { return }
            guard cameraSamplesByID[header.imageID] == nil else {
                throw Error.duplicateImage(header.imageID)
            }
            cameraSamplesByID[header.imageID] = OrientationCameraSample(
                imageName: header.imageName,
                rotationWorldToCamera: header.pose.rotationWorldToCamera,
                translation: header.pose.translation,
                trackedObservationCount: observationCountByImage[header.imageName] ?? 0
            )
        }

        func pointTrackTopologySHA256(
            checkCancellation: () throws -> Void
        ) throws -> String {
            guard finished, unverifiedTracks.isEmpty else {
                throw Error.noTrackedObservations
            }

            struct NamedObservation {
                let imageNameBytes: Data
                let point2DIndex: UInt64
            }

            var pointHashes: [Data] = []
            pointHashes.reserveCapacity(points.count)
            let imageNameBytesByID = registeredImageNamesByID.mapValues {
                Data($0.utf8)
            }
            var encodedObservationCount = 0
            for (pointOffset, entry) in points.enumerated() {
                if pointOffset > 0, pointOffset.isMultiple(of: 4_096) {
                    try checkCancellation()
                }
                let (pointID, point) = entry
                var observations: [NamedObservation] = []
                observations.reserveCapacity(point.track.count)
                for key in point.track {
                    guard let imageNameBytes = imageNameBytesByID[key.imageID] else {
                        throw Error.inconsistentTrack(
                            pointID: pointID,
                            imageID: key.imageID,
                            point2DIndex: key.point2DIndex
                        )
                    }
                    observations.append(
                        NamedObservation(
                            imageNameBytes: imageNameBytes,
                            point2DIndex: UInt64(key.point2DIndex)
                        )
                    )
                    encodedObservationCount += 1
                    if encodedObservationCount.isMultiple(of: 4_096) {
                        try checkCancellation()
                    }
                }
                observations.sort {
                    if $0.imageNameBytes != $1.imageNameBytes {
                        return $0.imageNameBytes.lexicographicallyPrecedes(
                            $1.imageNameBytes
                        )
                    }
                    return $0.point2DIndex < $1.point2DIndex
                }

                var pointHasher = SHA256()
                Self.updateTopologyField(
                    Data("EasySplat COLMAP point-track point v1".utf8),
                    in: &pointHasher
                )
                Self.updateTopologyField(
                    Self.topologyInteger(UInt64(observations.count)),
                    in: &pointHasher
                )
                for observation in observations {
                    Self.updateTopologyField(
                        observation.imageNameBytes,
                        in: &pointHasher
                    )
                    Self.updateTopologyField(
                        Self.topologyInteger(observation.point2DIndex),
                        in: &pointHasher
                    )
                }
                pointHashes.append(Data(pointHasher.finalize()))
            }
            guard encodedObservationCount == expectedObservationCount else {
                throw Error.noTrackedObservations
            }

            try checkCancellation()
            pointHashes.sort { $0.lexicographicallyPrecedes($1) }
            var closureHasher = SHA256()
            Self.updateTopologyField(
                Data("EasySplat COLMAP point-track closure v1".utf8),
                in: &closureHasher
            )
            Self.updateTopologyField(
                Self.topologyInteger(UInt64(pointHashes.count)),
                in: &closureHasher
            )
            Self.updateTopologyField(
                Self.topologyInteger(UInt64(encodedObservationCount)),
                in: &closureHasher
            )
            for (index, pointHash) in pointHashes.enumerated() {
                if (index + 1).isMultiple(of: 4_096) {
                    try checkCancellation()
                }
                Self.updateTopologyField(pointHash, in: &closureHasher)
            }
            return closureHasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        }

        private static func updateTopologyField(
            _ field: Data,
            in hasher: inout SHA256
        ) {
            hasher.update(data: topologyInteger(UInt64(field.count)))
            hasher.update(data: field)
        }

        private static func topologyInteger(_ value: UInt64) -> Data {
            var encoded = value.bigEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }

        func conditioningMeasurement(
            cameraToPointDistances: [Double],
            maximumRayPairEvaluations: Int,
            checkCancellation: () throws -> Void
        ) throws -> GeometryConditioningMeasurement {
            guard finished,
                  cameraToPointDistances.count == expectedObservationCount,
                  !cameraToPointDistances.isEmpty,
                  cameraSamplesByID.count == registeredImageNamesByID.count else {
                throw Error.noTrackedObservations
            }
            let orderedPointIDs = points.keys.sorted()
            var trackLengths: [Int] = []
            trackLengths.reserveCapacity(orderedPointIDs.count)
            for pointID in orderedPointIDs {
                guard let point = points[pointID] else { continue }
                let distinctCount = Set(point.track.map(\.imageID)).count
                guard distinctCount >= 2 else {
                    throw GeometryConditioningFailure.insufficientDistinctTrackViews(
                        pointID: pointID,
                        distinctViewCount: distinctCount
                    )
                }
                trackLengths.append(distinctCount)
            }

            let cameraCenters = cameraSamplesByID.keys.sorted().compactMap {
                cameraSamplesByID[$0]?.centerInWorld
            }
            // Euclidean camera-to-point range is scale equivariant and does not
            // depend on camera aim, unlike world Z or camera-space Z depth.
            let medianDepth = Self.median(cameraToPointDistances)
            var totalPairEvaluations = 0
            var cameraPairEvaluations = 0
            let centerMergeToleranceRatio = 1e-5
            let clusteredCenters = try Self.effectiveCameraCenters(
                cameraCenters,
                mergeTolerance: medianDepth * centerMergeToleranceRatio,
                maximumEvaluations: maximumRayPairEvaluations,
                totalEvaluationCount: &totalPairEvaluations,
                cameraEvaluationCount: &cameraPairEvaluations,
                checkCancellation: checkCancellation
            )
            let nearestBaselines: [Double]
            if let unmergedNearestBaselines = clusteredCenters.unmergedNearestDistances {
                nearestBaselines = unmergedNearestBaselines
            } else {
                nearestBaselines = try Self.nearestNeighborDistances(
                    clusteredCenters.centers,
                    maximumEvaluations: maximumRayPairEvaluations,
                    totalEvaluationCount: &totalPairEvaluations,
                    cameraEvaluationCount: &cameraPairEvaluations,
                    checkCancellation: checkCancellation
                )
            }
            let nearestBaselineRatios = nearestBaselines.map { $0 / medianDepth }
            let baselineRatio = Self.nearestRankPercentile(
                nearestBaselineRatios,
                percentile: 0.10
            )
            let cameraEigenvalues = try Self.normalizedCovarianceEigenvalues(
                cameraCenters,
                winsorizeAtP99: false
            )
            let pointPositions = orderedPointIDs.compactMap { id -> OrientationVector3? in
                guard let point = points[id] else { return nil }
                return OrientationVector3(
                    x: point.position.x,
                    y: point.position.y,
                    z: point.position.z
                )
            }
            let pointEigenvalues = try Self.normalizedCovarianceEigenvalues(
                pointPositions,
                winsorizeAtP99: true
            )

            var pointCounts = [0, 0, 0]
            var observationCounts = [0, 0, 0]
            var numericallyConditionedPointCount = 0
            var numericallyConditionedObservationCount = 0
            var adaptiveThresholdDegrees: [Double] = []
            adaptiveThresholdDegrees.reserveCapacity(orderedPointIDs.count)
            var rayPairEvaluations = 0
            let fixedThresholds = [1.5, 2.0, 3.0].map { $0 * Double.pi / 180 }
            let numericalAngularFloor = 0.05 * Double.pi / 180
            let residualUncertaintyMultiplier = 3.0
            for (pointIndex, pointID) in orderedPointIDs.enumerated() {
                if pointIndex.isMultiple(of: 1_024) { try checkCancellation() }
                guard let point = points[pointID] else { continue }
                let position = OrientationVector3(
                    x: point.position.x,
                    y: point.position.y,
                    z: point.position.z
                )
                let rays = try point.track.map { key -> OrientationVector3 in
                    guard let center = cameraSamplesByID[key.imageID]?.centerInWorld,
                          let ray = (position - center).normalized else {
                        throw Error.unprojectableObservation(pointID: pointID, imageLine: 0)
                    }
                    return ray
                }
                let angularResiduals = try point.track.map { key -> Double in
                    guard let residual = angularResidualByObservation[key],
                          residual.isFinite,
                          residual >= 0 else {
                        throw Error.inconsistentTrack(
                            pointID: pointID,
                            imageID: key.imageID,
                            point2DIndex: key.point2DIndex
                        )
                    }
                    return residual
                }
                let adaptivePointThreshold = max(
                    numericalAngularFloor,
                    residualUncertaintyMultiplier * Self.nearestRankPercentile(
                        angularResiduals,
                        percentile: 0.90
                    )
                )
                adaptiveThresholdDegrees.append(
                    adaptivePointThreshold * 180 / Double.pi
                )
                var fixedObservationSupport = fixedThresholds.map { _ in
                    Array(repeating: false, count: rays.count)
                }
                var adaptiveObservationSupport = Array(
                    repeating: false,
                    count: rays.count
                )
                var maximumRaySeparation = 0.0
                for first in 1..<rays.count {
                    for second in 0..<first {
                        totalPairEvaluations += 1
                        rayPairEvaluations += 1
                        guard totalPairEvaluations <= maximumRayPairEvaluations else {
                            throw GeometryConditioningFailure.rayPairWorkLimitExceeded(
                                maximum: maximumRayPairEvaluations
                            )
                        }
                        if totalPairEvaluations.isMultiple(of: 4_096) {
                            try checkCancellation()
                        }
                        let absoluteCosine = min(
                            1,
                            max(0, abs(rays[first].dot(rays[second])))
                        )
                        let separation = acos(absoluteCosine)
                        maximumRaySeparation = max(maximumRaySeparation, separation)
                        for thresholdIndex in fixedThresholds.indices
                        where separation >= fixedThresholds[thresholdIndex] {
                            fixedObservationSupport[thresholdIndex][first] = true
                            fixedObservationSupport[thresholdIndex][second] = true
                        }
                        let pairThreshold = max(
                            numericalAngularFloor,
                            residualUncertaintyMultiplier * max(
                                angularResiduals[first],
                                angularResiduals[second]
                            )
                        )
                        if separation >= pairThreshold {
                            adaptiveObservationSupport[first] = true
                            adaptiveObservationSupport[second] = true
                        }
                    }
                }
                for thresholdIndex in fixedThresholds.indices {
                    let supportedObservations = fixedObservationSupport[thresholdIndex].count {
                        $0
                    }
                    if supportedObservations > 0 {
                        pointCounts[thresholdIndex] += 1
                    }
                    observationCounts[thresholdIndex] += supportedObservations
                }
                if maximumRaySeparation >= adaptivePointThreshold {
                    numericallyConditionedPointCount += 1
                }
                numericallyConditionedObservationCount += adaptiveObservationSupport.count { $0 }
            }

            let sortedTrackLengths = trackLengths.sorted()
            let sortedViewObservationCounts = registeredImageNamesByID.keys.sorted().compactMap {
                registeredImageNamesByID[$0]
            }.map {
                observationCountByImage[$0, default: 0]
            }.sorted()
            let measurement = GeometryConditioningMeasurement(
                pointCount: points.count,
                observationCount: expectedObservationCount,
                positiveDepthObservationCount: cameraToPointDistances.count,
                stronglyMeasuredViewCount: observationCountByImage.values.count {
                    $0 >= GeometryArtifactStore.minimumLearnedObservationsPerView
                },
                registeredViewCount: registeredImageNamesByID.count,
                perViewObservationMinimum: sortedViewObservationCounts.first ?? 0,
                perViewObservationP10: Self.nearestRankPercentile(
                    sortedViewObservationCounts,
                    percentile: 0.10
                ),
                perViewObservationMedian: Self.median(
                    sortedViewObservationCounts.map(Double.init)
                ),
                perViewObservationP90: Self.nearestRankPercentile(
                    sortedViewObservationCounts,
                    percentile: 0.90
                ),
                distinctTrackLengthMinimum: sortedTrackLengths.first ?? 0,
                distinctTrackLengthP10: Self.nearestRankPercentile(
                    sortedTrackLengths,
                    percentile: 0.10
                ),
                distinctTrackLengthMedian: Self.median(sortedTrackLengths.map(Double.init)),
                distinctTrackLengthP90: Self.nearestRankPercentile(
                    sortedTrackLengths,
                    percentile: 0.90
                ),
                pointsAtLeast1Point5Degrees: pointCounts[0],
                pointsAtLeast2Degrees: pointCounts[1],
                pointsAtLeast3Degrees: pointCounts[2],
                observationsAtLeast1Point5Degrees: observationCounts[0],
                observationsAtLeast2Degrees: observationCounts[1],
                observationsAtLeast3Degrees: observationCounts[2],
                medianObservedDepth: medianDepth,
                cameraBaselineToMedianDepthRatio: baselineRatio,
                effectiveCameraCenterCount: clusteredCenters.centers.count,
                largestCameraCenterClusterSize: clusteredCenters.largestClusterSize,
                cameraCenterMergeToleranceToMedianDepthRatio:
                    centerMergeToleranceRatio,
                numericallyConditionedPointCount: numericallyConditionedPointCount,
                numericallyConditionedObservationCount:
                    numericallyConditionedObservationCount,
                adaptiveParallaxThresholdMedianDegrees: Self.median(
                    adaptiveThresholdDegrees
                ),
                adaptiveParallaxThresholdP90Degrees: Self.nearestRankPercentile(
                    adaptiveThresholdDegrees,
                    percentile: 0.90
                ),
                cameraCenterEigenvalues: cameraEigenvalues,
                pointEigenvalues: pointEigenvalues,
                cameraPairEvaluationCount: cameraPairEvaluations,
                rayPairEvaluationCount: rayPairEvaluations
            )
            guard measurement.positiveDepthObservationCount == measurement.observationCount else {
                throw Error.noTrackedObservations
            }
            let requiredStrongViews = Int(ceil(
                Double(measurement.registeredViewCount)
                    * ReconstructionScorer.minimumRegisteredViewFraction
            ))
            guard measurement.stronglyMeasuredViewCount >= requiredStrongViews else {
                throw GeometryConditioningFailure.insufficientViewSupport(measurement)
            }
            guard measurement.effectiveCameraCenterCount >= 3,
                  measurement.cameraBaselineToMedianDepthRatio
                    > measurement.cameraCenterMergeToleranceToMedianDepthRatio else {
                throw GeometryConditioningFailure.collapsedCameraTrajectory(measurement)
            }
            guard measurement.numericallyConditionedPointCount * 2
                    >= measurement.pointCount else {
                throw GeometryConditioningFailure.insufficientParallax(measurement)
            }
            guard measurement.pointEigenvalues.count == 3,
                  measurement.pointEigenvalues[1] >= 1e-8 else {
                throw GeometryConditioningFailure.degeneratePointDistribution(measurement)
            }
            return measurement
        }

        private struct DisjointSet {
            private var parents: [Int]
            private var sizes: [Int]

            init(count: Int) {
                parents = Array(0..<count)
                sizes = Array(repeating: 1, count: count)
            }

            mutating func root(of value: Int) -> Int {
                var current = value
                while parents[current] != current {
                    parents[current] = parents[parents[current]]
                    current = parents[current]
                }
                return current
            }

            mutating func merge(_ first: Int, _ second: Int) {
                var firstRoot = root(of: first)
                var secondRoot = root(of: second)
                guard firstRoot != secondRoot else { return }
                if sizes[firstRoot] < sizes[secondRoot]
                    || (sizes[firstRoot] == sizes[secondRoot] && firstRoot > secondRoot) {
                    swap(&firstRoot, &secondRoot)
                }
                parents[secondRoot] = firstRoot
                sizes[firstRoot] += sizes[secondRoot]
            }
        }

        private static func effectiveCameraCenters(
            _ points: [OrientationVector3],
            mergeTolerance: Double,
            maximumEvaluations: Int,
            totalEvaluationCount: inout Int,
            cameraEvaluationCount: inout Int,
            checkCancellation: () throws -> Void
        ) throws -> (
            centers: [OrientationVector3],
            largestClusterSize: Int,
            unmergedNearestDistances: [Double]?
        ) {
            guard !points.isEmpty,
                  mergeTolerance.isFinite,
                  mergeTolerance > 0 else {
                throw Error.noTrackedObservations
            }
            var clusters = DisjointSet(count: points.count)
            var nearestDistances = Array(repeating: Double.infinity, count: points.count)
            if points.count >= 2 {
                for first in 1..<points.count {
                    for second in 0..<first {
                        totalEvaluationCount += 1
                        cameraEvaluationCount += 1
                        guard totalEvaluationCount <= maximumEvaluations else {
                            throw GeometryConditioningFailure.rayPairWorkLimitExceeded(
                                maximum: maximumEvaluations
                            )
                        }
                        if totalEvaluationCount.isMultiple(of: 4_096) {
                            try checkCancellation()
                        }
                        let distance = (points[first] - points[second]).length
                        nearestDistances[first] = min(nearestDistances[first], distance)
                        nearestDistances[second] = min(nearestDistances[second], distance)
                        if distance <= mergeTolerance {
                            clusters.merge(first, second)
                        }
                    }
                }
            }
            var membersByRoot: [Int: [OrientationVector3]] = [:]
            for index in points.indices {
                membersByRoot[clusters.root(of: index), default: []].append(points[index])
            }
            let largestClusterSize = membersByRoot.values.map(\.count).max() ?? 0
            let centers = membersByRoot.values
                .map(mean)
                .sorted {
                    if $0.x != $1.x { return $0.x < $1.x }
                    if $0.y != $1.y { return $0.y < $1.y }
                    return $0.z < $1.z
                }
            let unmergedNearestDistances = centers.count == points.count
                && nearestDistances.allSatisfy { $0.isFinite && $0 >= 0 }
                ? nearestDistances
                : nil
            return (centers, largestClusterSize, unmergedNearestDistances)
        }

        private static func nearestNeighborDistances(
            _ points: [OrientationVector3],
            maximumEvaluations: Int,
            totalEvaluationCount: inout Int,
            cameraEvaluationCount: inout Int,
            checkCancellation: () throws -> Void
        ) throws -> [Double] {
            guard points.count >= 2 else { return [0] }
            var nearest = Array(repeating: Double.infinity, count: points.count)
            for first in 1..<points.count {
                for second in 0..<first {
                    totalEvaluationCount += 1
                    cameraEvaluationCount += 1
                    guard totalEvaluationCount <= maximumEvaluations else {
                        throw GeometryConditioningFailure.rayPairWorkLimitExceeded(
                            maximum: maximumEvaluations
                        )
                    }
                    if totalEvaluationCount.isMultiple(of: 4_096) {
                        try checkCancellation()
                    }
                    let distance = (points[first] - points[second]).length
                    nearest[first] = min(nearest[first], distance)
                    nearest[second] = min(nearest[second], distance)
                }
            }
            guard nearest.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw Error.noTrackedObservations
            }
            return nearest
        }

        private static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        }

        private static func nearestRankPercentile<T: Comparable>(
            _ values: [T],
            percentile: Double
        ) -> T {
            precondition(!values.isEmpty && (0...1).contains(percentile))
            let sorted = values.sorted()
            let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
            return sorted[min(sorted.count - 1, rank - 1)]
        }

        private static func normalizedCovarianceEigenvalues(
            _ values: [OrientationVector3],
            winsorizeAtP99: Bool
        ) throws -> [Double] {
            guard !values.isEmpty else { throw Error.noTrackedObservations }
            // Arithmetic centering is rotation equivariant. Coordinate-wise
            // medians are not, so they would make this gate depend on world axes.
            let center = mean(values)
            let offsets = values.map { $0 - center }
            let radiusLimit = winsorizeAtP99
                ? nearestRankPercentile(offsets.map(\.length), percentile: 0.99)
                : .infinity
            let bounded = offsets.map { offset -> OrientationVector3 in
                let length = offset.length
                guard winsorizeAtP99, radiusLimit > 0, length > radiusLimit else {
                    return offset
                }
                return offset * (radiusLimit / length)
            }
            let boundedCenter = mean(bounded)
            var covariance = OrientationMatrix3(repeating: 0)
            for value in bounded {
                let offset = value - boundedCenter
                let components = [offset.x, offset.y, offset.z]
                for row in 0..<3 {
                    for column in 0..<3 {
                        covariance[row, column] += components[row] * components[column]
                    }
                }
            }
            let scale = 1 / Double(bounded.count)
            for row in 0..<3 {
                for column in 0..<3 { covariance[row, column] *= scale }
            }
            var eigenvalues = symmetricEigenvalues(covariance)
            let trace = eigenvalues.reduce(0, +)
            guard trace.isFinite, trace >= 0 else { throw Error.noTrackedObservations }
            if trace == 0 { return [0, 0, 0] }
            eigenvalues = eigenvalues.map { max(0, $0) / trace }.sorted()
            return eigenvalues
        }

        private static func mean(_ values: [OrientationVector3]) -> OrientationVector3 {
            values.reduce(.zero, +) / Double(values.count)
        }

        private static func symmetricEigenvalues(_ input: OrientationMatrix3) -> [Double] {
            var matrix = input
            for _ in 0..<32 {
                var p = 0
                var q = 1
                var largest = abs(matrix[0, 1])
                for pair in [(0, 2), (1, 2)] where abs(matrix[pair.0, pair.1]) > largest {
                    p = pair.0
                    q = pair.1
                    largest = abs(matrix[p, q])
                }
                if largest <= 1e-15 { break }
                let angle = 0.5 * atan2(
                    2 * matrix[p, q],
                    matrix[q, q] - matrix[p, p]
                )
                let cosine = cos(angle)
                let sine = sin(angle)
                let app = matrix[p, p]
                let aqq = matrix[q, q]
                let apq = matrix[p, q]
                matrix[p, p] = cosine * cosine * app - 2 * sine * cosine * apq
                    + sine * sine * aqq
                matrix[q, q] = sine * sine * app + 2 * sine * cosine * apq
                    + cosine * cosine * aqq
                matrix[p, q] = 0
                matrix[q, p] = 0
                for index in 0..<3 where index != p && index != q {
                    let aip = matrix[index, p]
                    let aiq = matrix[index, q]
                    matrix[index, p] = cosine * aip - sine * aiq
                    matrix[p, index] = matrix[index, p]
                    matrix[index, q] = sine * aip + cosine * aiq
                    matrix[q, index] = matrix[index, q]
                }
            }
            return [matrix[0, 0], matrix[1, 1], matrix[2, 2]].sorted()
        }
    }

    private final class ResidualStatistics {
        struct Summary {
            let count: Int
            let mean: Double
            let median: Double
            let p90: Double
        }

        private var residuals: [Double] = []
        private var sum = 0.0

        init(expectedCount: Int) {
            residuals.reserveCapacity(expectedCount)
        }

        func add(_ residual: Double) {
            precondition(residual.isFinite)
            sum += residual
            residuals.append(residual)
        }

        func finish() -> Summary? {
            guard !residuals.isEmpty else { return nil }
            residuals.sort()
            let lowerMedianIndex = (residuals.count - 1) / 2
            let upperMedianIndex = residuals.count / 2
            let p90Index = (residuals.count * 9 + 9) / 10 - 1
            return Summary(
                count: residuals.count,
                mean: sum / Double(residuals.count),
                median: (residuals[lowerMedianIndex] + residuals[upperMedianIndex]) / 2,
                p90: residuals[p90Index]
            )
        }
    }
}
