import Foundation

/// Reprojects COLMAP text-model tracks into their source images.
/// These are measured pixel residuals; mapper summaries and normalized scores are not accepted here.
enum ColmapResidualAnalyzer {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case missingFile(String)
        case malformedRecord(file: String, line: Int)
        case unsupportedCameraModel(String)
        case missingPoint(Int64)
        case duplicateImage(Int)
        case duplicateImageName(String)
        case unprojectableObservation(pointID: Int64, imageLine: Int)
        case noTrackedObservations

        var errorDescription: String? {
            switch self {
            case .missingFile(let name):
                return "COLMAP model is missing \(name)."
            case .malformedRecord(let file, let line):
                return "COLMAP model has a malformed \(file) record at line \(line)."
            case .unsupportedCameraModel(let model):
                return "COLMAP camera model \(model) is not supported for residual measurement."
            case .missingPoint(let id):
                return "COLMAP observation references missing point \(id)."
            case .duplicateImage(let id):
                return "COLMAP model contains duplicate image ID \(id)."
            case .duplicateImageName(let name):
                return "COLMAP model contains duplicate image name \(name)."
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
        let pointCount: Int
        let observationCount: Int
        let medianPixelResidual: Double
        let p90PixelResidual: Double
        let provenance: String
    }

    private struct Point3 {
        let x: Double
        let y: Double
        let z: Double
    }

    private struct Pose {
        let qw: Double
        let qx: Double
        let qy: Double
        let qz: Double
        let tx: Double
        let ty: Double
        let tz: Double

        func cameraPoint(_ point: Point3) -> Point3? {
            let norm = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
            guard norm.isFinite, norm > 0 else { return nil }
            let w = qw / norm
            let x = qx / norm
            let y = qy / norm
            let z = qz / norm

            let r00 = 1 - 2 * (y * y + z * z)
            let r01 = 2 * (x * y - z * w)
            let r02 = 2 * (x * z + y * w)
            let r10 = 2 * (x * y + z * w)
            let r11 = 1 - 2 * (x * x + z * z)
            let r12 = 2 * (y * z - x * w)
            let r20 = 2 * (x * z - y * w)
            let r21 = 2 * (y * z + x * w)
            let r22 = 1 - 2 * (x * x + y * y)

            let result = Point3(
                x: r00 * point.x + r01 * point.y + r02 * point.z + tx,
                y: r10 * point.x + r11 * point.y + r12 * point.z + ty,
                z: r20 * point.x + r21 * point.y + r22 * point.z + tz
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
        let camerasURL = modelDirectory.appendingPathComponent("cameras.txt")
        let imagesURL = modelDirectory.appendingPathComponent("images.txt")
        let pointsURL = modelDirectory.appendingPathComponent("points3D.txt")
        let fileManager = FileManager.default
        for url in [camerasURL, imagesURL, pointsURL] where !fileManager.fileExists(atPath: url.path) {
            throw Error.missingFile(url.lastPathComponent)
        }

        let cameras = try parseCameras(at: camerasURL)
        let points = try parsePoints(at: pointsURL)
        let imagesText = try String(contentsOf: imagesURL, encoding: .utf8)
        let lines = imagesText.components(separatedBy: .newlines)
        var residuals: [Double] = []
        var registeredImageIDs = Set<Int>()
        var registeredImageNames = Set<String>()
        var measuredImageNames = Set<String>()
        var index = 0

        while index < lines.count {
            let header = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let headerLineNumber = index + 1
            index += 1
            if header.isEmpty || header.hasPrefix("#") { continue }

            let fields = header.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10,
                  let imageID = Int(fields[0]),
                  let qw = Double(fields[1]), let qx = Double(fields[2]),
                  let qy = Double(fields[3]), let qz = Double(fields[4]),
                  let tx = Double(fields[5]), let ty = Double(fields[6]), let tz = Double(fields[7]),
                  let cameraID = Int(fields[8]), let camera = cameras[cameraID] else {
                throw Error.malformedRecord(file: "images.txt", line: headerLineNumber)
            }
            let imageName = fields.dropFirst(9).joined(separator: " ")
            guard !imageName.isEmpty else {
                throw Error.malformedRecord(file: "images.txt", line: headerLineNumber)
            }
            guard registeredImageIDs.insert(imageID).inserted else {
                throw Error.duplicateImage(imageID)
            }
            guard registeredImageNames.insert(imageName).inserted else {
                throw Error.duplicateImageName(imageName)
            }
            let pose = Pose(qw: qw, qx: qx, qy: qy, qz: qz, tx: tx, ty: ty, tz: tz)

            guard index < lines.count else {
                throw Error.malformedRecord(file: "images.txt", line: headerLineNumber)
            }
            let observations = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let observationLineNumber = index + 1
            index += 1
            if observations.isEmpty { continue }
            let observationFields = observations.split(whereSeparator: \.isWhitespace)
            guard observationFields.count.isMultiple(of: 3) else {
                throw Error.malformedRecord(file: "images.txt", line: observationLineNumber)
            }

            var imageHasMeasuredObservation = false
            for offset in stride(from: 0, to: observationFields.count, by: 3) {
                guard let observedX = Double(observationFields[offset]),
                      let observedY = Double(observationFields[offset + 1]),
                      let pointID = Int64(observationFields[offset + 2]) else {
                    throw Error.malformedRecord(file: "images.txt", line: observationLineNumber)
                }
                if pointID < 0 { continue }
                guard let worldPoint = points[pointID] else { throw Error.missingPoint(pointID) }
                guard observedX.isFinite,
                      observedY.isFinite,
                      let cameraPoint = pose.cameraPoint(worldPoint),
                      let projected = camera.project(cameraPoint) else {
                    throw Error.unprojectableObservation(
                        pointID: pointID,
                        imageLine: headerLineNumber
                    )
                }
                let residual = hypot(projected.x - observedX, projected.y - observedY)
                guard residual.isFinite else {
                    throw Error.unprojectableObservation(
                        pointID: pointID,
                        imageLine: headerLineNumber
                    )
                }
                residuals.append(residual)
                imageHasMeasuredObservation = true
            }
            if imageHasMeasuredObservation { measuredImageNames.insert(imageName) }
        }

        guard !residuals.isEmpty else { throw Error.noTrackedObservations }
        residuals.sort()
        let middle = residuals.count / 2
        let median = residuals.count.isMultiple(of: 2)
            ? (residuals[middle - 1] + residuals[middle]) / 2
            : residuals[middle]
        let p90Index = max(0, Int(ceil(Double(residuals.count) * 0.90)) - 1)
        return Result(
            registeredViewCount: registeredImageNames.count,
            registeredImageNames: registeredImageNames.sorted(),
            measuredImageNames: measuredImageNames.sorted(),
            pointCount: points.count,
            observationCount: residuals.count,
            medianPixelResidual: median,
            p90PixelResidual: residuals[p90Index],
            provenance: "colmap-text-tracks-v1"
        )
    }

    private static func parseCameras(at url: URL) throws -> [Int: Camera] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var cameras: [Int: Camera] = [:]
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5, let id = Int(fields[0]) else {
                throw Error.malformedRecord(file: "cameras.txt", line: index + 1)
            }
            let model = String(fields[1])
            let parameters = fields.dropFirst(4).compactMap { Double($0) }
            guard parameters.count == fields.count - 4 else {
                throw Error.malformedRecord(file: "cameras.txt", line: index + 1)
            }
            cameras[id] = try camera(model: model, parameters: parameters)
        }
        return cameras
    }

    private static func camera(model: String, parameters: [Double]) throws -> Camera {
        switch (model, parameters.count) {
        case ("SIMPLE_PINHOLE", 3):
            return .simplePinhole(f: parameters[0], cx: parameters[1], cy: parameters[2])
        case ("PINHOLE", 4):
            return .pinhole(fx: parameters[0], fy: parameters[1], cx: parameters[2], cy: parameters[3])
        case ("SIMPLE_RADIAL", 4):
            return .simpleRadial(f: parameters[0], cx: parameters[1], cy: parameters[2], k: parameters[3])
        case ("RADIAL", 5):
            return .radial(f: parameters[0], cx: parameters[1], cy: parameters[2], k1: parameters[3], k2: parameters[4])
        case ("OPENCV", 8):
            return .openCV(
                fx: parameters[0], fy: parameters[1], cx: parameters[2], cy: parameters[3],
                k1: parameters[4], k2: parameters[5], p1: parameters[6], p2: parameters[7]
            )
        case ("OPENCV_FISHEYE", 8):
            return .openCVFisheye(
                fx: parameters[0], fy: parameters[1], cx: parameters[2], cy: parameters[3],
                k1: parameters[4], k2: parameters[5], k3: parameters[6], k4: parameters[7]
            )
        case ("SIMPLE_PINHOLE", _), ("PINHOLE", _), ("SIMPLE_RADIAL", _), ("RADIAL", _),
             ("OPENCV", _), ("OPENCV_FISHEYE", _):
            throw Error.malformedRecord(file: "cameras.txt", line: 0)
        default:
            throw Error.unsupportedCameraModel(model)
        }
    }

    private static func parsePoints(at url: URL) throws -> [Int64: Point3] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var points: [Int64: Point3] = [:]
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, let id = Int64(fields[0]),
                  let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]) else {
                throw Error.malformedRecord(file: "points3D.txt", line: index + 1)
            }
            points[id] = Point3(x: x, y: y, z: z)
        }
        return points
    }
}
