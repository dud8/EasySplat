import Foundation

public enum ProjectArtifactStatus: Equatable, Sendable {
    case valid
    case missing
    case corrupt(reason: String)
}

public enum ProjectArtifactValidationDepth: Sendable {
    case quick
    case full
}

public struct PlyHeaderInfo: Sendable, Equatable {
    public var vertexCount: Int
    public var format: String

    public init(vertexCount: Int, format: String) {
        self.vertexCount = vertexCount
        self.format = format
    }
}

public enum ProjectArtifactValidator {
    private static let maxHeaderBytes = 64 * 1024

    /// Read only the PLY header for a known-good output file and return the
    /// vertex count + format. Returns nil when the file is unreadable, missing,
    /// or not a valid PLY header. Cheap (single bounded read of the header).
    public static func readPlyHeader(at url: URL) -> PlyHeaderInfo? {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxHeaderBytes)) ?? Data()
        guard !data.isEmpty, let bounds = plyHeaderBounds(in: data) else { return nil }
        guard let header = String(data: data.prefix(bounds.headerEnd), encoding: .utf8) else { return nil }
        let lines = header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let vertexLine = lines.first(where: { $0.lowercased().hasPrefix("element vertex ") }),
              let raw = vertexLine.split(separator: " ").last,
              let vertexCount = Int(raw), vertexCount > 0 else {
            return nil
        }
        let format = lines
            .first(where: { $0.lowercased().hasPrefix("format ") })?
            .split(separator: " ")
            .dropFirst()
            .first
            .map(String.init)?
            .lowercased() ?? ""
        return PlyHeaderInfo(vertexCount: vertexCount, format: format)
    }

    public static func resolveValidatedOutputPly(paths: ProjectPaths, relativePath: String) throws -> URL {
        let url = try paths.resolveProjectRelativePath(relativePath)
        guard validatePlyFile(at: url) == .valid else {
            throw ProjectArtifactError.invalidOutput(relativePath)
        }
        return url
    }

    public static func validatePlyFile(
        at url: URL,
        depth: ProjectArtifactValidationDepth = .full
    ) -> ProjectArtifactStatus {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue {
            return .corrupt(reason: "\(url.lastPathComponent) is a directory")
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            return .corrupt(reason: "\(url.lastPathComponent) is empty")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxHeaderBytes)) ?? Data()
        guard !data.isEmpty else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        guard let headerBounds = plyHeaderBounds(in: data) else {
            guard let prefix = String(data: data.prefix(4096), encoding: .utf8),
                  prefix.lowercased().hasPrefix("ply") else {
                return .corrupt(reason: "\(url.lastPathComponent) is not a PLY file")
            }
            return .corrupt(reason: "\(url.lastPathComponent) is missing end_header")
        }
        let bodyStart = headerBounds.bodyStart
        let headerData = data.prefix(headerBounds.headerEnd)
        guard let header = String(data: headerData, encoding: .utf8) else {
            return .corrupt(reason: "\(url.lastPathComponent) is not valid UTF-8 near header")
        }
        guard header.lowercased().hasPrefix("ply") else {
            return .corrupt(reason: "\(url.lastPathComponent) is not a PLY file")
        }
        let lines = header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let vertexLine = lines.first(where: { $0.lowercased().hasPrefix("element vertex ") }) else {
            return .corrupt(reason: "\(url.lastPathComponent) is missing vertex element metadata")
        }
        let comps = vertexLine.split(separator: " ")
        guard let raw = comps.last, let vertexCount = Int(raw), vertexCount > 0 else {
            return .corrupt(reason: "\(url.lastPathComponent) has invalid vertex count")
        }
        guard let format = lines.first(where: { $0.lowercased().hasPrefix("format ") })?.split(separator: " ").dropFirst().first?.lowercased() else {
            return .corrupt(reason: "\(url.lastPathComponent) is missing PLY format")
        }
        var vertexProperties: [(name: String, type: String)] = []
        var isReadingVertexProperties = false
        for line in lines {
            let parts = line.split(separator: " ")
            guard let first = parts.first?.lowercased() else { continue }
            if first == "element" {
                isReadingVertexProperties = parts.count >= 2 && parts[1].lowercased() == "vertex"
                continue
            }
            guard isReadingVertexProperties, first == "property" else { continue }
            if parts.count >= 5, parts[1].lowercased() == "list" {
                return .corrupt(reason: "\(url.lastPathComponent) has unsupported list property in vertex element")
            }
            guard parts.count >= 3 else { continue }
            vertexProperties.append((name: String(parts.last?.lowercased() ?? ""), type: String(parts[1].lowercased())))
        }
        let properties = Set(vertexProperties.map(\.name))
        for required in ["x", "y", "z"] where !properties.contains(required) {
            return .corrupt(reason: "\(url.lastPathComponent) is missing Gaussian splat property \(required)")
        }
        let hasSHColor = ["f_dc_0", "f_dc_1", "f_dc_2"].allSatisfy { properties.contains($0) }
        let hasRGBColor = ["red", "green", "blue"].allSatisfy { properties.contains($0) }
        if !hasSHColor && !hasRGBColor {
            return .corrupt(reason: "\(url.lastPathComponent) is missing Gaussian splat property f_dc_0")
        }
        for required in ["scale_0", "scale_1", "scale_2", "opacity", "rot_0", "rot_1", "rot_2", "rot_3"] where !properties.contains(required) {
            return .corrupt(reason: "\(url.lastPathComponent) is missing Gaussian splat property \(required)")
        }
        let safeBodyStart = min(bodyStart, data.count)
        let body = data[safeBodyStart...]
        let trimmedBody = body.drop { $0 == 10 || $0 == 13 || $0 == 32 || $0 == 9 }
        if trimmedBody.isEmpty {
            guard size > Int64(data.count) else {
                return .corrupt(reason: "\(url.lastPathComponent) has no vertex data")
            }
        }
        switch format {
        case "ascii":
            if depth == .quick {
                return .valid
            }
            if let corrupt = validateAsciiVertexBody(
                at: url,
                bodyStart: bodyStart,
                vertexCount: vertexCount,
                vertexProperties: vertexProperties
            ) {
                return corrupt
            }
        case "binary_little_endian", "binary_big_endian":
            let propertySizes: [String: Int64] = [
                "char": 1,
                "uchar": 1,
                "int8": 1,
                "uint8": 1,
                "short": 2,
                "ushort": 2,
                "int16": 2,
                "uint16": 2,
                "int": 4,
                "uint": 4,
                "int32": 4,
                "uint32": 4,
                "float": 4,
                "float32": 4,
                "double": 8,
                "float64": 8
            ]
            let stride = try? vertexProperties.reduce(Int64(0)) { partial, property in
                guard let size = propertySizes[property.type] else {
                    throw ProjectArtifactValidationInternalError.unsupportedType
                }
                return partial + size
            }
            guard let stride, stride > 0 else {
                return .corrupt(reason: "\(url.lastPathComponent) has unsupported binary vertex property type")
            }
            let vertexCount64 = Int64(vertexCount)
            let multiplied = stride.multipliedReportingOverflow(by: vertexCount64)
            guard !multiplied.overflow else {
                return .corrupt(reason: "\(url.lastPathComponent) vertex byte count is too large")
            }
            let requiredBytes = multiplied.partialValue
            let availableBytes = size - Int64(bodyStart)
            guard availableBytes >= requiredBytes else {
                return .corrupt(reason: "\(url.lastPathComponent) expected at least \(requiredBytes) vertex bytes, found \(max(0, availableBytes))")
            }
        default:
            return .corrupt(reason: "\(url.lastPathComponent) has unsupported PLY format \(format)")
        }
        return .valid
    }

    private static func plyHeaderBounds(in data: Data) -> (headerEnd: Int, bodyStart: Int)? {
        var lineStart = data.startIndex

        while lineStart < data.endIndex {
            var lineEnd = lineStart
            while lineEnd < data.endIndex, data[lineEnd] != 10, data[lineEnd] != 13 {
                lineEnd += 1
            }

            let line = String(decoding: data[lineStart..<lineEnd], as: UTF8.self)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "end_header" {
                var bodyStart = lineEnd
                if bodyStart < data.endIndex {
                    if data[bodyStart] == 13 {
                        bodyStart += 1
                        if bodyStart < data.endIndex, data[bodyStart] == 10 {
                            bodyStart += 1
                        }
                    } else if data[bodyStart] == 10 {
                        bodyStart += 1
                    }
                }
                return (headerEnd: lineEnd, bodyStart: bodyStart)
            }

            guard lineEnd < data.endIndex else { break }
            lineStart = lineEnd
            if data[lineStart] == 13 {
                lineStart += 1
                if lineStart < data.endIndex, data[lineStart] == 10 {
                    lineStart += 1
                }
            } else if data[lineStart] == 10 {
                lineStart += 1
            }
        }

        return nil
    }

    private static func validateAsciiVertexBody(
        at url: URL,
        bodyStart: Int,
        vertexCount: Int,
        vertexProperties: [(name: String, type: String)]
    ) -> ProjectArtifactStatus? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(bodyStart))
        } catch {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }

        var rowCount = 0
        var carry = ""

        func consume(_ row: String) -> ProjectArtifactStatus? {
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            rowCount += 1
            let columns = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= vertexProperties.count else {
                return .corrupt(reason: "\(url.lastPathComponent) has incomplete vertex data")
            }
            for (index, property) in vertexProperties.enumerated() {
                guard asciiValue(String(columns[index]), isValidFor: property.type) else {
                    return .corrupt(reason: "\(url.lastPathComponent) has invalid vertex value for \(property.name)")
                }
            }
            return nil
        }

        while rowCount < vertexCount {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            carry += String(decoding: chunk, as: UTF8.self)
            let parts = carry.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            let endsWithNewline = carry.last == "\n" || carry.last == "\r"
            let completeRows = endsWithNewline ? parts[...] : parts.dropLast()
            for row in completeRows {
                if let corrupt = consume(String(row)) {
                    return corrupt
                }
                if rowCount >= vertexCount {
                    return nil
                }
            }
            carry = endsWithNewline ? "" : String(parts.last ?? "")
        }

        if rowCount < vertexCount, let corrupt = consume(carry) {
            return corrupt
        }
        guard rowCount >= vertexCount else {
            return .corrupt(reason: "\(url.lastPathComponent) expected \(vertexCount) vertices, found \(rowCount)")
        }
        return nil
    }

    private static func asciiValue(_ value: String, isValidFor type: String) -> Bool {
        switch type {
        case "char", "int8", "short", "int16", "int", "int32":
            return Int64(value) != nil
        case "uchar", "uint8", "ushort", "uint16", "uint", "uint32":
            return UInt64(value) != nil
        case "float", "float32", "double", "float64":
            guard let number = Double(value) else { return false }
            return number.isFinite
        default:
            return false
        }
    }
}

private enum ProjectArtifactValidationInternalError: Error {
    case unsupportedType
}

public enum ProjectArtifactError: Error, LocalizedError, Equatable {
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOutput(let path):
            return "Invalid project output: \(path)"
        }
    }
}
