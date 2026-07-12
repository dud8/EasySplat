import CryptoKit
import Foundation

enum Da3LearnedPointInitializer {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidLimit
        case malformedPoint(line: Int)
        case pointCount(expected: Int, actual: Int)
        case malformedCanonicalPoint(line: Int)
        case digestMismatch

        var errorDescription: String? {
            switch self {
            case .invalidLimit:
                return "The learned point limit is invalid."
            case .malformedPoint(let line):
                return "The learned point initializer is malformed at line \(line)."
            case .pointCount(let expected, let actual):
                return "The learned point initializer contains \(actual) points; expected \(expected)."
            case .malformedCanonicalPoint(let line):
                return "The refined point model is malformed at line \(line)."
            case .digestMismatch:
                return "The learned point initializer no longer matches accepted geometry."
            }
        }
    }

    struct Validation: Equatable {
        let pointCount: Int
        let sha256: String
    }

    private struct Point {
        let x: Double
        let y: Double
        let z: Double
        let red: Int
        let green: Int
        let blue: Int
    }

    @discardableResult
    static func validate(
        learnedPointsURL: URL,
        expectedPointCount: Int,
        maximumPointCount: Int,
        expectedSHA256: String? = nil
    ) throws -> Int {
        try inspect(
            learnedPointsURL: learnedPointsURL,
            expectedPointCount: expectedPointCount,
            maximumPointCount: maximumPointCount,
            expectedSHA256: expectedSHA256
        ).pointCount
    }

    static func inspect(
        learnedPointsURL: URL,
        expectedPointCount: Int,
        maximumPointCount: Int,
        expectedSHA256: String? = nil
    ) throws -> Validation {
        let loaded = try load(
            learnedPointsURL: learnedPointsURL,
            expectedPointCount: expectedPointCount,
            maximumPointCount: maximumPointCount,
            expectedSHA256: expectedSHA256
        )
        return Validation(pointCount: loaded.points.count, sha256: loaded.sha256)
    }

    @discardableResult
    static func merge(
        learnedPointsURL: URL,
        into canonicalPointsURL: URL,
        expectedPointCount: Int,
        maximumPointCount: Int,
        expectedSHA256: String? = nil
    ) throws -> Int {
        let learned = try load(
            learnedPointsURL: learnedPointsURL,
            expectedPointCount: expectedPointCount,
            maximumPointCount: maximumPointCount,
            expectedSHA256: expectedSHA256
        ).points
        let canonicalData = try BoundedFileReader.readRegularFile(
            at: canonicalPointsURL,
            maximumBytes: 512 * 1_024 * 1_024
        )
        guard var canonical = String(data: canonicalData, encoding: .utf8) else {
            throw Error.malformedCanonicalPoint(line: 0)
        }

        var maximumID: Int64 = 0
        for (offset, rawLine) in canonical.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10,
                  fields.count.isMultiple(of: 2),
                  let identifier = Int64(fields[0]),
                  identifier > 0 else {
                throw Error.malformedCanonicalPoint(line: offset + 1)
            }
            maximumID = max(maximumID, identifier)
        }
        guard maximumID <= Int64.max - Int64(learned.count) else {
            throw Error.malformedCanonicalPoint(line: 0)
        }

        if !canonical.hasSuffix("\n") { canonical.append("\n") }
        canonical.append("# DA3 confidence-filtered initialization points; no measured tracks.\n")
        for (offset, point) in learned.enumerated() {
            let identifier = maximumID + Int64(offset) + 1
            canonical.append(
                "\(identifier) \(point.x) \(point.y) \(point.z) "
                    + "\(point.red) \(point.green) \(point.blue) -1.0\n"
            )
        }
        guard let merged = canonical.data(using: .utf8) else {
            throw Error.malformedCanonicalPoint(line: 0)
        }
        try merged.write(to: canonicalPointsURL, options: .atomic)
        return learned.count
    }

    private static func load(
        learnedPointsURL: URL,
        expectedPointCount: Int,
        maximumPointCount: Int,
        expectedSHA256: String?
    ) throws -> (points: [Point], sha256: String) {
        guard expectedPointCount > 0,
              maximumPointCount > 0,
              expectedPointCount <= maximumPointCount else {
            throw Error.invalidLimit
        }
        let byteEstimate = maximumPointCount.multipliedReportingOverflow(by: 192)
        let maximumBytes = byteEstimate.overflow
            ? 64 * 1_024 * 1_024
            : min(64 * 1_024 * 1_024, max(4_096, byteEstimate.partialValue))
        let data = try BoundedFileReader.readRegularFile(
            at: learnedPointsURL,
            maximumBytes: maximumBytes
        )
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, sha256 != expectedSHA256 {
            throw Error.digestMismatch
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.malformedPoint(line: 0)
        }
        var points: [Point] = []
        points.reserveCapacity(expectedPointCount)
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 8,
                  let identifier = Int(fields[0]),
                  identifier == points.count + 1,
                  let x = Double(fields[1]), x.isFinite,
                  let y = Double(fields[2]), y.isFinite,
                  let z = Double(fields[3]), z.isFinite,
                  safeForNativeDistanceMath(x, y, z),
                  let red = Int(fields[4]), (0...255).contains(red),
                  let green = Int(fields[5]), (0...255).contains(green),
                  let blue = Int(fields[6]), (0...255).contains(blue),
                  let error = Double(fields[7]), error == -1.0,
                  points.count < maximumPointCount else {
                throw Error.malformedPoint(line: offset + 1)
            }
            points.append(Point(x: x, y: y, z: z, red: red, green: green, blue: blue))
        }
        guard points.count == expectedPointCount else {
            throw Error.pointCount(expected: expectedPointCount, actual: points.count)
        }
        return (points, sha256)
    }

    private static func safeForNativeDistanceMath(_ x: Double, _ y: Double, _ z: Double) -> Bool {
        // MetalSplatter computes squared point-to-camera distances in Float. This bound
        // leaves room to subtract two opposite coordinates and square all three axes.
        let limit = sqrt(Double(Float.greatestFiniteMagnitude) / 16.0)
        return abs(x) <= limit && abs(y) <= limit && abs(z) <= limit
    }
}
