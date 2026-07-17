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
        let cameraSamples: [OrientationCameraSample]
        let pointCount: Int
        let observationCount: Int
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
    }

    private struct ParsedPoints {
        let records: [Int64: PointRecord]
        let trackOwners: [ObservationKey: Int64]
    }

    private struct ParsedCameras {
        let records: [Int: Camera]
        let firstModel: String
    }

    private struct Observation {
        let pointID: Int64
        let imageID: Int
        let point2DIndex: Int
        let pixelResidual: Double
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
            guard result.x.isFinite, result.y.isFinite, result.z.isFinite, result.z > 1e-12 else {
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

    private static func makeResult(
        stream: ObservationStream,
        statistics: ResidualStatistics
    ) throws -> Result {
        guard let summary = statistics.finish() else {
            throw Error.noTrackedObservations
        }
        let registeredImageNames = stream.registeredImageNamesByID.values.sorted()
        return Result(
            registeredViewCount: registeredImageNames.count,
            registeredImageNames: registeredImageNames,
            measuredImageNames: stream.observationCountByImage.keys.sorted(),
            observationCountByImage: stream.observationCountByImage,
            cameraModel: stream.cameraModel,
            cameraSamples: stream.cameraSamplesByID.keys.sorted().compactMap {
                stream.cameraSamplesByID[$0]
            },
            pointCount: stream.pointCount,
            observationCount: summary.count,
            meanPixelResidual: summary.mean,
            medianPixelResidual: summary.median,
            p90PixelResidual: summary.p90,
            provenance: "colmap-text-tracks-v1"
        )
    }

    private static func parseCameras(at url: URL) throws -> ParsedCameras {
        let reader = try makeReader(at: url, maximumBytes: ColmapTextFileLimits.cameras)
        var cameras: [Int: Camera] = [:]
        var firstModel: String?
        while let rawLine = try nextLine(from: reader) {
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
            if firstModel == nil { firstModel = model }
        }
        guard let firstModel else {
            throw Error.malformedRecord(file: "cameras.txt", line: 0)
        }
        return ParsedCameras(records: cameras, firstModel: firstModel)
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

    private static func parsePoints(at url: URL) throws -> ParsedPoints {
        let reader = try makeReader(at: url, maximumBytes: ColmapTextFileLimits.points)
        var points: [Int64: PointRecord] = [:]
        var trackOwners: [ObservationKey: Int64] = [:]
        while let rawLine = try nextLine(from: reader) {
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

            var hasTrack = false
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
                hasTrack = true
            }
            guard hasTrack else {
                throw Error.malformedRecord(file: "points3D.txt", line: rawLine.number)
            }
            points[id] = PointRecord(position: Point3(x: x, y: y, z: z))
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
        from reader: BoundedUTF8LineReader
    ) throws -> BoundedUTF8LineReader.Line? {
        do {
            return try reader.next()
        } catch BoundedUTF8LineReader.Error.invalidUTF8(let name) {
            throw Error.malformedTextFile(name)
        }
    }

    private struct TokenScanner {
        private let text: String
        private var index: String.Index

        init(_ text: String) {
            self.text = text
            index = text.startIndex
        }

        mutating func next() -> Substring? {
            while index < text.endIndex, text[index].isWhitespace {
                text.formIndex(after: &index)
            }
            guard index < text.endIndex else { return nil }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                text.formIndex(after: &index)
            }
            return text[start..<index]
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
        private(set) var registeredImageNamesByID: [Int: String] = [:]
        private(set) var observationCountByImage: [String: Int] = [:]
        private(set) var cameraSamplesByID: [Int: OrientationCameraSample] = [:]

        private let reader: BoundedUTF8LineReader
        private let points: [Int64: PointRecord]
        private var unverifiedTracks: [ObservationKey: Int64]
        private var registeredImageNames = Set<String>()
        private var observationFields: TokenScanner?
        private var observationLineNumber = 0
        private var point2DIndex = 0
        private var header: Header?
        private var finished = false

        init(modelDirectory: URL) throws {
            let camerasURL = modelDirectory.appendingPathComponent("cameras.txt")
            let pointsURL = modelDirectory.appendingPathComponent("points3D.txt")
            let imagesURL = modelDirectory.appendingPathComponent("images.txt")
            let parsedCameras = try ColmapResidualAnalyzer.parseCameras(at: camerasURL)
            let parsedPoints = try ColmapResidualAnalyzer.parsePoints(at: pointsURL)
            points = parsedPoints.records
            unverifiedTracks = parsedPoints.trackOwners
            pointCount = parsedPoints.records.count
            expectedObservationCount = parsedPoints.trackOwners.count
            reader = try ColmapResidualAnalyzer.makeReader(
                at: imagesURL,
                maximumBytes: ColmapTextFileLimits.images
            )
            cameras = parsedCameras.records
            cameraModel = parsedCameras.firstModel
        }

        private let cameras: [Int: Camera]

        func next() throws -> Observation? {
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
                    guard let cameraPoint = header.pose.cameraPoint(point.position),
                          let projected = header.camera.project(cameraPoint) else {
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
                    return Observation(
                        pointID: pointID,
                        imageID: header.imageID,
                        point2DIndex: currentPoint2DIndex,
                        pixelResidual: residual
                    )
                }

                guard try beginNextImage() else { return nil }
            }
        }

        private func beginNextImage() throws -> Bool {
            while let rawLine = try ColmapResidualAnalyzer.nextLine(from: reader) {
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
                guard let observations = try ColmapResidualAnalyzer.nextLine(from: reader) else {
                    throw Error.malformedRecord(file: "images.txt", line: rawLine.number)
                }

                registeredImageNamesByID[imageID] = imageName
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
