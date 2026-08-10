import Foundation

/// Full-fidelity reader for COLMAP sparse models in either the text or the
/// binary layout, producing `ColmapTextModel`. Unlike the membership reader,
/// nothing is skipped: camera parameters, poses, observations, and point
/// tracks all survive, because direct adoption republishes them. Parsing is
/// native so imported `.bin` models never require the toolchain's
/// `model_converter`, which is not installed yet at input preflight time.
public enum ColmapModelReader {
    public enum ReadError: Swift.Error, LocalizedError, Equatable {
        case missingModelFile(String)
        case fileTooLarge(String)
        case malformedText(file: String, line: Int)
        case malformedBinary(String)
        case unsupportedCameraModel(String)
        case unknownBinaryCameraModel(Int)
        case invalidImagePath(String)
        case duplicateImagePath(String)

        public var errorDescription: String? {
            switch self {
            case .missingModelFile(let name):
                return "The COLMAP model is missing \(name)."
            case .fileTooLarge(let name):
                return "The COLMAP model file \(name) is larger than EasySplat can import."
            case .malformedText(let file, let line):
                return "The COLMAP model file \(file) is malformed at line \(line)."
            case .malformedBinary(let name):
                return "The COLMAP model file \(name) is not a valid binary model."
            case .unsupportedCameraModel(let model):
                return "This dataset uses the camera model \(model), which EasySplat can't read. Re-export with a perspective (pinhole) or fisheye camera."
            case .unknownBinaryCameraModel(let id):
                return "The COLMAP model uses an unknown camera model ID \(id)."
            case .invalidImagePath(let path):
                return "The COLMAP model contains an unsafe image path: \(path)."
            case .duplicateImagePath(let path):
                return "The COLMAP model lists a colliding image path: \(path)."
            }
        }
    }

    /// COLMAP camera models by binary model ID, with parameter counts.
    /// Membership in this table is also the import allowlist for text models.
    static let cameraModels: [(id: Int, name: String, parameterCount: Int)] = [
        (0, "SIMPLE_PINHOLE", 3),
        (1, "PINHOLE", 4),
        (2, "SIMPLE_RADIAL", 4),
        (3, "RADIAL", 5),
        (4, "OPENCV", 8),
        (5, "OPENCV_FISHEYE", 8),
        (6, "FULL_OPENCV", 12),
        (7, "FOV", 5),
        (8, "SIMPLE_RADIAL_FISHEYE", 4),
        (9, "RADIAL_FISHEYE", 5),
        (10, "THIN_PRISM_FISHEYE", 12),
    ]

    /// Per-file import ceiling. Large enough for multi-thousand-image scenes
    /// with dense sparse clouds; a bound must exist because these are
    /// untrusted user files read before any pipeline gate.
    static let maximumFileBytes = 2 << 30

    /// COLMAP encodes "no point" as uint64 max in binary observations.
    private static let invalidPoint3DID = UInt64.max

    public enum Format: String, Sendable, Equatable {
        case binary
        case text
    }

    /// Reads a model directory, preferring binary files when both layouts are
    /// present (matching COLMAP's own reader precedence).
    public static func read(modelDirectory: URL) throws -> (model: ColmapTextModel, format: Format) {
        let hasBinary = FileManager.default.fileExists(
            atPath: modelDirectory.appendingPathComponent("cameras.bin").path
        )
        if hasBinary {
            return (try readBinary(modelDirectory: modelDirectory), .binary)
        }
        return (try readText(modelDirectory: modelDirectory), .text)
    }

    // MARK: - Text

    static func readText(modelDirectory: URL) throws -> ColmapTextModel {
        let camerasLines = try lines(of: "cameras.txt", in: modelDirectory)
        let imagesLines = try lines(of: "images.txt", in: modelDirectory)
        let pointsLines = try lines(of: "points3D.txt", in: modelDirectory, required: false)

        var cameras: [ColmapTextCamera] = []
        for (number, line) in camerasLines {
            var tokens = line.split(separator: " ", omittingEmptySubsequences: true)[...]
            guard tokens.count >= 5,
                  let id = Int(tokens.popFirst()!),
                  let model = tokens.popFirst().map(String.init),
                  let width = Int(tokens.popFirst()!),
                  let height = Int(tokens.popFirst()!) else {
                throw ReadError.malformedText(file: "cameras.txt", line: number)
            }
            guard let expected = cameraModels.first(where: { $0.name == model }) else {
                throw ReadError.unsupportedCameraModel(model)
            }
            let parameters = tokens.compactMap { Double($0) }
            guard parameters.count == tokens.count, parameters.count == expected.parameterCount else {
                throw ReadError.malformedText(file: "cameras.txt", line: number)
            }
            cameras.append(
                ColmapTextCamera(id: id, model: model, width: width, height: height, parameters: parameters)
            )
        }

        var images: [ColmapTextImage] = []
        var seenImagePaths = Set<String>()
        var index = 0
        while index < imagesLines.count {
            let (number, poseLine) = imagesLines[index]
            let image = try parsePoseLine(poseLine, line: number)
            var observations: [ColmapTextObservation] = []
            // The observations line is mandatory in COLMAP text models but may
            // be blank; blank lines were dropped by the line reader, so the
            // next line is observations only when it parses as triples.
            if index + 1 < imagesLines.count {
                let (nextNumber, nextLine) = imagesLines[index + 1]
                if let parsed = parseObservationsLine(nextLine) {
                    observations = parsed
                    index += 1
                    _ = nextNumber
                }
            }
            images.append(
                ColmapTextImage(
                    id: image.id,
                    pose: image.pose,
                    cameraID: image.cameraID,
                    name: try canonicalImagePath(image.name, seen: &seenImagePaths),
                    observations: observations
                )
            )
            index += 1
        }

        var points: [ColmapTextPoint3D] = []
        for (number, line) in pointsLines {
            var tokens = line.split(separator: " ", omittingEmptySubsequences: true)[...]
            guard tokens.count >= 8, (tokens.count - 8).isMultiple(of: 2),
                  let id = Int(tokens.popFirst()!),
                  let x = Double(tokens.popFirst()!),
                  let y = Double(tokens.popFirst()!),
                  let z = Double(tokens.popFirst()!),
                  let red = Int(tokens.popFirst()!),
                  let green = Int(tokens.popFirst()!),
                  let blue = Int(tokens.popFirst()!),
                  let error = Double(tokens.popFirst()!) else {
                throw ReadError.malformedText(file: "points3D.txt", line: number)
            }
            var track: [ColmapTextTrackElement] = []
            while !tokens.isEmpty {
                guard let imageID = Int(tokens.popFirst()!),
                      let pointIndex = Int(tokens.popFirst()!) else {
                    throw ReadError.malformedText(file: "points3D.txt", line: number)
                }
                track.append(ColmapTextTrackElement(imageID: imageID, point2DIndex: pointIndex))
            }
            points.append(
                ColmapTextPoint3D(
                    id: id, x: x, y: y, z: z,
                    red: red, green: green, blue: blue,
                    error: error, track: track
                )
            )
        }

        return ColmapTextModel(cameras: cameras, images: images, points: points)
    }

    private struct ParsedPose {
        let id: Int
        let pose: DatasetPoseConvention.ColmapPose
        let cameraID: Int
        let name: String
    }

    private static func parsePoseLine(_ line: String, line number: Int) throws -> ParsedPose {
        // Consume only the nine whitespace-delimited numeric fields. The
        // unsplit tail is the exact declared image name, including spaces or
        // control characters that the path canonicalizer must inspect rather
        // than silently rewriting.
        guard let (tokens, name) = poseFieldsAndName(line),
              let id = Int(tokens[0]),
              let qw = Double(tokens[1]),
              let qx = Double(tokens[2]),
              let qy = Double(tokens[3]),
              let qz = Double(tokens[4]),
              let tx = Double(tokens[5]),
              let ty = Double(tokens[6]),
              let tz = Double(tokens[7]),
              let cameraID = Int(tokens[8]) else {
            throw ReadError.malformedText(file: "images.txt", line: number)
        }
        guard !name.isEmpty else {
            throw ReadError.malformedText(file: "images.txt", line: number)
        }
        return ParsedPose(
            id: id,
            pose: DatasetPoseConvention.ColmapPose(qw: qw, qx: qx, qy: qy, qz: qz, tx: tx, ty: ty, tz: tz),
            cameraID: cameraID,
            name: String(name)
        )
    }

    private static func poseFieldsAndName(
        _ line: String
    ) -> (fields: [Substring], name: Substring)? {
        var fields: [Substring] = []
        fields.reserveCapacity(9)
        var cursor = line.startIndex

        for _ in 0..<9 {
            while cursor < line.endIndex, line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex else { return nil }
            let start = cursor
            while cursor < line.endIndex, !line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            fields.append(line[start..<cursor])
        }
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex else { return nil }
        return (fields, line[cursor...])
    }

    /// Observation lines are `X Y POINT3D_ID` triples. A line whose token
    /// count is not a multiple of three, or whose first token is not a
    /// number, is the next image's pose line instead.
    private static func parseObservationsLine(_ line: String) -> [ColmapTextObservation]? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count.isMultiple(of: 3), !tokens.isEmpty else { return nil }
        var observations: [ColmapTextObservation] = []
        observations.reserveCapacity(tokens.count / 3)
        var cursor = 0
        while cursor < tokens.count {
            guard let x = Double(tokens[cursor]),
                  let y = Double(tokens[cursor + 1]),
                  let pointID = Int(tokens[cursor + 2]) else {
                return nil
            }
            observations.append(ColmapTextObservation(x: x, y: y, point3DID: pointID))
            cursor += 3
        }
        // A pose line also has a numeric prefix but ends with a name token
        // that fails Double parsing, so reaching here means observations.
        return observations
    }

    private static func lines(
        of name: String,
        in directory: URL,
        required: Bool = true
    ) throws -> [(number: Int, text: String)] {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if required { throw ReadError.missingModelFile(name) }
            return []
        }
        let data = try boundedContents(of: url, name: name)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReadError.malformedText(file: name, line: 1)
        }
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [(Int, String)] = []
        for (index, rawSlice) in rawLines.enumerated() {
            var line = String(rawSlice)
            // Strip only the CR that belongs to a CRLF terminator. A control
            // character in an unterminated final image name remains visible to
            // DatasetDeclaredPath and is rejected instead of rewritten.
            if index < rawLines.count - 1, line.last == "\r" {
                line.removeLast()
            }
            let classification = line.trimmingCharacters(in: .whitespaces)
            guard !classification.isEmpty, !classification.hasPrefix("#") else { continue }
            result.append((index + 1, line))
        }
        return result
    }

    // MARK: - Binary

    static func readBinary(modelDirectory: URL) throws -> ColmapTextModel {
        let camerasData = try boundedContents(
            of: modelDirectory.appendingPathComponent("cameras.bin"), name: "cameras.bin"
        )
        let imagesData = try boundedContents(
            of: modelDirectory.appendingPathComponent("images.bin"), name: "images.bin"
        )
        let pointsURL = modelDirectory.appendingPathComponent("points3D.bin")
        let pointsData = FileManager.default.fileExists(atPath: pointsURL.path)
            ? try boundedContents(of: pointsURL, name: "points3D.bin")
            : Data()

        var cameras: [ColmapTextCamera] = []
        var reader = BinaryReader(data: camerasData, name: "cameras.bin")
        // Minimum encoded sizes per record, used to validate declared counts
        // against remaining bytes before trusting them for allocation.
        let cameraCount = try reader.readCount(minimumElementBytes: 4 + 4 + 8 + 8)
        for _ in 0..<cameraCount {
            let id = try reader.readUInt32()
            let modelID = try reader.readInt32()
            let width = try reader.readUInt64()
            let height = try reader.readUInt64()
            guard let model = cameraModels.first(where: { $0.id == Int(modelID) }) else {
                throw ReadError.unknownBinaryCameraModel(Int(modelID))
            }
            var parameters: [Double] = []
            for _ in 0..<model.parameterCount {
                parameters.append(try reader.readDouble())
            }
            cameras.append(
                ColmapTextCamera(
                    id: Int(id), model: model.name,
                    width: Int(width), height: Int(height),
                    parameters: parameters
                )
            )
        }
        try reader.requireEnd()

        var images: [ColmapTextImage] = []
        var seenImagePaths = Set<String>()
        reader = BinaryReader(data: imagesData, name: "images.bin")
        let imageCount = try reader.readCount(minimumElementBytes: 4 + 7 * 8 + 4 + 1 + 8)
        for _ in 0..<imageCount {
            let id = try reader.readUInt32()
            let qw = try reader.readDouble()
            let qx = try reader.readDouble()
            let qy = try reader.readDouble()
            let qz = try reader.readDouble()
            let tx = try reader.readDouble()
            let ty = try reader.readDouble()
            let tz = try reader.readDouble()
            let cameraID = try reader.readUInt32()
            let rawName = try reader.readNullTerminatedString()
            let name = try canonicalImagePath(rawName, seen: &seenImagePaths)
            let observationCount = try reader.readCount(minimumElementBytes: 8 + 8 + 8)
            var observations: [ColmapTextObservation] = []
            observations.reserveCapacity(observationCount)
            for _ in 0..<observationCount {
                let x = try reader.readDouble()
                let y = try reader.readDouble()
                let pointID = try reader.readUInt64()
                observations.append(
                    ColmapTextObservation(
                        x: x, y: y,
                        point3DID: pointID == invalidPoint3DID ? -1 : Int(pointID)
                    )
                )
            }
            images.append(
                ColmapTextImage(
                    id: Int(id),
                    pose: DatasetPoseConvention.ColmapPose(
                        qw: qw, qx: qx, qy: qy, qz: qz, tx: tx, ty: ty, tz: tz
                    ),
                    cameraID: Int(cameraID),
                    name: name,
                    observations: observations
                )
            )
        }
        try reader.requireEnd()

        var points: [ColmapTextPoint3D] = []
        if !pointsData.isEmpty {
            reader = BinaryReader(data: pointsData, name: "points3D.bin")
            let pointCount = try reader.readCount(minimumElementBytes: 8 + 3 * 8 + 3 + 8 + 8)
            points.reserveCapacity(pointCount)
            for _ in 0..<pointCount {
                let id = try reader.readUInt64()
                let x = try reader.readDouble()
                let y = try reader.readDouble()
                let z = try reader.readDouble()
                let red = try reader.readUInt8()
                let green = try reader.readUInt8()
                let blue = try reader.readUInt8()
                let error = try reader.readDouble()
                let trackLength = try reader.readCount(minimumElementBytes: 4 + 4)
                var track: [ColmapTextTrackElement] = []
                track.reserveCapacity(trackLength)
                for _ in 0..<trackLength {
                    let imageID = try reader.readUInt32()
                    let pointIndex = try reader.readUInt32()
                    track.append(
                        ColmapTextTrackElement(imageID: Int(imageID), point2DIndex: Int(pointIndex))
                    )
                }
                points.append(
                    ColmapTextPoint3D(
                        id: Int(id), x: x, y: y, z: z,
                        red: Int(red), green: Int(green), blue: Int(blue),
                        error: error, track: track
                    )
                )
            }
            try reader.requireEnd()
        }

        return ColmapTextModel(cameras: cameras, images: images, points: points)
    }

    /// Canonicalizes before any caller can resolve a model name against disk.
    /// One folded set rejects exact, case-only, and Unicode-normalization
    /// collisions on both case-sensitive and case-insensitive volumes.
    private static func canonicalImagePath(
        _ rawPath: String,
        seen: inout Set<String>
    ) throws -> String {
        guard let path = DatasetDeclaredPath.normalized(rawPath) else {
            throw ReadError.invalidImagePath(rawPath)
        }
        let collisionKey = DatasetDeclaredPath.collisionKey(path)
        guard seen.insert(collisionKey).inserted else {
            throw ReadError.duplicateImagePath(path)
        }
        return path
    }

    private static func boundedContents(of url: URL, name: String) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? Int, size > maximumFileBytes {
            throw ReadError.fileTooLarge(name)
        }
        return try Data(contentsOf: url)
    }

    private struct BinaryReader {
        let data: Data
        let name: String
        var offset = 0

        init(data: Data, name: String) {
            self.data = data
            self.name = name
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset + 1 <= data.count else { throw ReadError.malformedBinary(name) }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func readUInt32() throws -> UInt32 {
            try UInt32(littleEndian: readFixedWidth())
        }

        mutating func readInt32() throws -> Int32 {
            try Int32(littleEndian: readFixedWidth())
        }

        mutating func readUInt64() throws -> UInt64 {
            try UInt64(littleEndian: readFixedWidth())
        }

        mutating func readDouble() throws -> Double {
            Double(bitPattern: try readUInt64())
        }

        mutating func readNullTerminatedString() throws -> String {
            var bytes: [UInt8] = []
            while true {
                let byte = try readUInt8()
                if byte == 0 { break }
                bytes.append(byte)
                if bytes.count > 4096 { throw ReadError.malformedBinary(name) }
            }
            guard let string = String(bytes: bytes, encoding: .utf8), !string.isEmpty else {
                throw ReadError.malformedBinary(name)
            }
            return string
        }

        /// Reads a declared element count and validates it against the bytes
        /// actually remaining, so hostile counts can never drive allocation
        /// or loop bounds past the file's real size.
        mutating func readCount(minimumElementBytes: Int) throws -> Int {
            let declared = try readUInt64()
            let remaining = UInt64(data.count - offset)
            guard declared <= remaining / UInt64(minimumElementBytes) else {
                throw ReadError.malformedBinary(name)
            }
            return Int(declared)
        }

        func requireEnd() throws {
            guard offset == data.count else { throw ReadError.malformedBinary(name) }
        }

        private mutating func readFixedWidth<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw ReadError.malformedBinary(name) }
            var value = T.zero
            withUnsafeMutableBytes(of: &value) { destination in
                data.withUnsafeBytes { source in
                    destination.copyBytes(from: source[offset..<(offset + size)])
                }
            }
            offset += size
            return value
        }
    }
}
