@preconcurrency import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
@preconcurrency import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision

struct SubjectIsolationCameraPose: Sendable, Equatable, Hashable {
    let imageIdentity: String
    let nativeCameraIndex: Int
    let center: SIMD3<Double>
}

struct SubjectIsolationAnalysisView: Sendable, Equatable, Hashable {
    let imageIdentity: String
    let imageURL: URL
    let nativeCameraIndex: Int
}

struct SubjectIsolationSampledView: Sendable, Equatable, Hashable {
    let imageIdentity: String
    let imageURL: URL?
    let nativeCameraIndex: Int
    let samplePosition: Int
}

struct SubjectIsolationProgressiveStage: Sendable, Equatable {
    let workViews: [SubjectIsolationSampledView]
    let heldOutViews: [SubjectIsolationSampledView]
}

enum SubjectIsolationColmapPoseReader {
    private static let maximumImageNameBytes = 4_096

    static func read(sparseDirectory: URL) throws -> [SubjectIsolationCameraPose] {
        let binary = sparseDirectory.appendingPathComponent("images.bin")
        let text = sparseDirectory.appendingPathComponent("images.txt")
        let records: [Record]
        if FileManager.default.fileExists(atPath: binary.path) {
            records = try binaryRecords(Data(contentsOf: binary, options: .mappedIfSafe))
        } else {
            records = try textRecords(Data(contentsOf: text))
        }
        guard !records.isEmpty else { throw SubjectIsolationPoseError.emptyModel }
        var identities: Set<String> = []
        for record in records {
            guard identities.insert(record.imageIdentity).inserted else {
                throw SubjectIsolationPoseError.duplicateImageIdentity(record.imageIdentity)
            }
        }
        let ordered = records.sorted {
            $0.imageIdentity.utf8.lexicographicallyPrecedes($1.imageIdentity.utf8)
        }
        return ordered.enumerated().map { index, record in
            SubjectIsolationCameraPose(
                imageIdentity: record.imageIdentity,
                nativeCameraIndex: index,
                center: cameraCenter(qvec: record.qvec, tvec: record.tvec)
            )
        }
    }

    private static func binaryRecords(_ data: Data) throws -> [Record] {
        var reader = BinaryReader(data: data)
        let count = try reader.uint64()
        guard count > 0, count <= 1_000_000 else { throw SubjectIsolationPoseError.malformedModel }
        var result: [Record] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            _ = try reader.uint32()
            let qvec = try (0..<4).map { _ in try reader.double() }
            let tvec = try (0..<3).map { _ in try reader.double() }
            _ = try reader.uint32()
            let name = try reader.nullTerminatedUTF8(maximumBytes: maximumImageNameBytes)
            let points = try reader.uint64()
            let pointBytes = points.multipliedReportingOverflow(by: 24)
            guard !pointBytes.overflow else { throw SubjectIsolationPoseError.malformedModel }
            try reader.skip(pointBytes.partialValue)
            result.append(try Record(name: name, qvec: qvec, tvec: tvec))
        }
        guard reader.isAtEnd else { throw SubjectIsolationPoseError.malformedModel }
        return result
    }

    private static func textRecords(_ data: Data) throws -> [Record] {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw SubjectIsolationPoseError.malformedModel
        }
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var result: [Record] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(maxSplits: 9, whereSeparator: \.isWhitespace)
            guard fields.count == 10,
                  UInt32(fields[0]) != nil,
                  UInt32(fields[8]) != nil else {
                throw SubjectIsolationPoseError.malformedModel
            }
            let qvec = fields[1...4].compactMap { Double($0) }
            let tvec = fields[5...7].compactMap { Double($0) }
            guard qvec.count == 4, tvec.count == 3 else { throw SubjectIsolationPoseError.malformedModel }
            result.append(try Record(name: String(fields[9]), qvec: qvec, tvec: tvec))
            guard index < lines.count else { throw SubjectIsolationPoseError.malformedModel }
            index += 1
        }
        return result
    }

    private static func cameraCenter(qvec: [Double], tvec: [Double]) -> SIMD3<Double> {
        let norm = sqrt(qvec.reduce(0) { $0 + $1 * $1 })
        let qw = qvec[0] / norm
        let qx = qvec[1] / norm
        let qy = qvec[2] / norm
        let qz = qvec[3] / norm
        let r00 = 1 - 2 * (qy * qy + qz * qz)
        let r01 = 2 * (qx * qy - qz * qw)
        let r02 = 2 * (qx * qz + qy * qw)
        let r10 = 2 * (qx * qy + qz * qw)
        let r11 = 1 - 2 * (qx * qx + qz * qz)
        let r12 = 2 * (qy * qz - qx * qw)
        let r20 = 2 * (qx * qz - qy * qw)
        let r21 = 2 * (qy * qz + qx * qw)
        let r22 = 1 - 2 * (qx * qx + qy * qy)
        return SIMD3(
            -(r00 * tvec[0] + r10 * tvec[1] + r20 * tvec[2]),
            -(r01 * tvec[0] + r11 * tvec[1] + r21 * tvec[2]),
            -(r02 * tvec[0] + r12 * tvec[1] + r22 * tvec[2])
        )
    }

    private struct Record {
        let imageIdentity: String
        let qvec: [Double]
        let tvec: [Double]

        init(name: String, qvec: [Double], tvec: [Double]) throws {
            guard !name.isEmpty, !name.contains("\0"), name.utf8.count <= maximumImageNameBytes,
                  qvec.allSatisfy(\.isFinite), tvec.allSatisfy(\.isFinite),
                  qvec.reduce(0, { $0 + $1 * $1 }) > 0 else {
                throw SubjectIsolationPoseError.malformedModel
            }
            imageIdentity = name
            self.qvec = qvec
            self.tvec = tvec
        }
    }

    private struct BinaryReader {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func uint32() throws -> UInt32 { try integer() }
        mutating func uint64() throws -> UInt64 { try integer() }
        mutating func double() throws -> Double { Double(bitPattern: try uint64()) }

        mutating func integer<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard offset <= data.count - size else { throw SubjectIsolationPoseError.malformedModel }
            let value = data[offset..<(offset + size)].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += size
            return T(littleEndian: value)
        }

        mutating func nullTerminatedUTF8(maximumBytes: Int) throws -> String {
            let start = offset
            while offset < data.count, data[offset] != 0, offset - start <= maximumBytes { offset += 1 }
            guard offset < data.count, offset - start > 0, offset - start <= maximumBytes,
                  let value = String(data: data[start..<offset], encoding: .utf8) else {
                throw SubjectIsolationPoseError.malformedModel
            }
            offset += 1
            return value
        }

        mutating func skip(_ count: UInt64) throws {
            guard count <= UInt64(Int.max), offset <= data.count - Int(count) else {
                throw SubjectIsolationPoseError.malformedModel
            }
            offset += Int(count)
        }
    }
}

enum SubjectIsolationPoseError: Error, Equatable {
    case emptyModel
    case malformedModel
    case duplicateImageIdentity(String)
}

enum SubjectIsolationViewSampler {
    static func sample(
        _ poses: [SubjectIsolationCameraPose],
        maximumCount: Int = 24
    ) -> [SubjectIsolationCameraPose] {
        guard maximumCount > 0, !poses.isEmpty else { return [] }
        let ordered = poses.sorted { $0.imageIdentity.utf8.lexicographicallyPrecedes($1.imageIdentity.utf8) }
        let centroid = ordered.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.center } / Double(ordered.count)
        var selected: [SubjectIsolationCameraPose] = []
        var remaining = ordered
        while selected.count < min(maximumCount, ordered.count), !remaining.isEmpty {
            let next: SubjectIsolationCameraPose
            if selected.isEmpty {
                next = remaining.max { lhs, rhs in
                    let left = squaredDistance(lhs.center, centroid)
                    let right = squaredDistance(rhs.center, centroid)
                    return left == right
                        ? rhs.imageIdentity.utf8.lexicographicallyPrecedes(lhs.imageIdentity.utf8)
                        : left < right
                }!
            } else {
                next = remaining.max { lhs, rhs in
                    let left = selected.map { squaredDistance(lhs.center, $0.center) }.min()!
                    let right = selected.map { squaredDistance(rhs.center, $0.center) }.min()!
                    return left == right
                        ? rhs.imageIdentity.utf8.lexicographicallyPrecedes(lhs.imageIdentity.utf8)
                        : left < right
                }!
            }
            selected.append(next)
            remaining.removeAll { $0.imageIdentity == next.imageIdentity }
        }
        return selected
    }

    static func progressiveStages(for sampled: [SubjectIsolationCameraPose]) -> [SubjectIsolationProgressiveStage] {
        guard sampled.count >= 2 else { return [] }
        let prefixes = [10, 18, 24].filter { $0 <= sampled.count }
            + (sampled.count < 24 && ![10, 18].contains(sampled.count) ? [sampled.count] : [])
        return prefixes.map { prefix in
            let views = sampled.prefix(prefix).enumerated().map {
                SubjectIsolationSampledView(
                    imageIdentity: $0.element.imageIdentity,
                    imageURL: nil,
                    nativeCameraIndex: $0.element.nativeCameraIndex,
                    samplePosition: $0.offset
                )
            }
            var heldPositions = Set([4, 9, 13, 17, 20, 23].filter { $0 < prefix })
            if heldPositions.isEmpty { heldPositions.insert(prefix - 1) }
            return SubjectIsolationProgressiveStage(
                workViews: views.filter { !heldPositions.contains($0.samplePosition) },
                heldOutViews: views.filter { heldPositions.contains($0.samplePosition) }
            )
        }
    }

    private static func squaredDistance(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        let delta = lhs - rhs
        return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
    }
}

struct SubjectIsolationBinaryMask: Sendable, Equatable {
    let sourceInstanceID: Int
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

struct SubjectIsolationAcquiredMask: Sendable, Equatable {
    let fileURL: URL
    let imageIdentity: String
    let imageSHA256: String
    let maskSHA256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let instanceLabels: [UInt8]
}

struct SubjectIsolationVisionMaskAcquirer: Sendable {
    typealias Request = @Sendable (CGImage) async throws -> [SubjectIsolationBinaryMask]

    private let request: Request

    init(request: @escaping Request = Self.visionRequest) {
        self.request = request
    }

    func acquire(
        views: [SubjectIsolationAnalysisView],
        stagingDirectory: URL,
        startingOrdinal: Int = 0,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) async throws -> [SubjectIsolationAcquiredMask] {
        try checkCancellation(shouldCancel)
        guard startingOrdinal >= 0,
              startingOrdinal <= Int.max - views.count else {
            throw SubjectIsolationAcquisitionError.incompleteResult(startingOrdinal)
        }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let prepared = try views.map { view in
            try checkCancellation(shouldCancel)
            let bytes = try Data(contentsOf: view.imageURL)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw SubjectIsolationAcquisitionError.unreadableImage(view.imageIdentity)
            }
            return PreparedView(view: view, image: image, imageSHA256: digest(bytes))
        }
        let created = CreatedMaskTracker()
        do {
            var results = Array<SubjectIsolationAcquiredMask?>(repeating: nil, count: prepared.count)
            try await withThrowingTaskGroup(of: (Int, SubjectIsolationAcquiredMask).self) { group in
                var next = 0
                func enqueue(_ index: Int) {
                    let value = prepared[index]
                    group.addTask {
                        try checkCancellation(shouldCancel)
                        let masks = try await request(value.image)
                        try checkCancellation(shouldCancel)
                        let result = try Self.writeMask(
                            masks: masks,
                            prepared: value,
                            ordinal: startingOrdinal + index,
                            stagingDirectory: stagingDirectory,
                            shouldCancel: shouldCancel
                        )
                        created.insert(result.fileURL)
                        return (index, result)
                    }
                }
                while next < min(2, prepared.count) { enqueue(next); next += 1 }
                while let (index, result) = try await group.next() {
                    results[index] = result
                    if next < prepared.count { enqueue(next); next += 1 }
                }
            }
            try checkCancellation(shouldCancel)
            return try results.enumerated().map { index, result in
                try result ?? { throw SubjectIsolationAcquisitionError.incompleteResult(index) }()
            }
        } catch is CancellationError {
            for url in created.urls { try? FileManager.default.removeItem(at: url) }
            throw CancellationError()
        }
    }

    private static func writeMask(
        masks: [SubjectIsolationBinaryMask],
        prepared: PreparedView,
        ordinal: Int,
        stagingDirectory: URL,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> SubjectIsolationAcquiredMask {
        try checkCancellation(shouldCancel)
        guard masks.count <= 255 else { throw SubjectIsolationAcquisitionError.tooManyInstances }
        var labels = [UInt8](repeating: 0, count: prepared.image.width * prepared.image.height)
        let ordered = masks.sorted { $0.sourceInstanceID < $1.sourceInstanceID }
        for (offset, mask) in ordered.enumerated() {
            try checkCancellation(shouldCancel)
            guard mask.width == prepared.image.width, mask.height == prepared.image.height,
                  mask.pixels.count == labels.count else {
                throw SubjectIsolationAcquisitionError.misalignedMask(prepared.view.imageIdentity)
            }
            let label = UInt8(offset + 1)
            for index in labels.indices where mask.pixels[index] != 0 && labels[index] == 0 {
                labels[index] = label
            }
        }
        try checkCancellation(shouldCancel)
        let fileURL = stagingDirectory.appendingPathComponent(String(format: "%04d.png", ordinal))
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SubjectIsolationAcquisitionError.destinationExists(fileURL.lastPathComponent)
        }
        try writeGrayscalePNG(labels, width: prepared.image.width, height: prepared.image.height, to: fileURL)
        let nonzero = Array(Set(labels.filter { $0 != 0 })).sorted()
        return SubjectIsolationAcquiredMask(
            fileURL: fileURL,
            imageIdentity: prepared.view.imageIdentity,
            imageSHA256: prepared.imageSHA256,
            maskSHA256: digest(try Data(contentsOf: fileURL)),
            pixelWidth: prepared.image.width,
            pixelHeight: prepared.image.height,
            instanceLabels: nonzero
        )
    }

    private static func visionRequest(_ image: CGImage) async throws -> [SubjectIsolationBinaryMask] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        return try observation.allInstances.map { instance in
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance),
                from: handler
            )
            return SubjectIsolationBinaryMask(
                sourceInstanceID: instance,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                pixels: try pixels(from: buffer)
            )
        }
    }

    static func pixels(from buffer: CVPixelBuffer) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw SubjectIsolationAcquisitionError.misalignedMask("Vision")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SubjectIsolationAcquisitionError.misalignedMask("Vision")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytesPerPixel: Int
        let foreground: (UnsafeRawPointer) throws -> Bool
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            bytesPerPixel = MemoryLayout<Float>.size
            foreground = { pointer in
                let value = pointer.loadUnaligned(as: Float.self)
                guard value.isFinite else {
                    throw SubjectIsolationAcquisitionError.misalignedMask("Vision")
                }
                return value >= 0.5
            }
        case kCVPixelFormatType_OneComponent8:
            bytesPerPixel = MemoryLayout<UInt8>.size
            foreground = { pointer in pointer.load(as: UInt8.self) >= 128 }
        default:
            throw SubjectIsolationAcquisitionError.misalignedMask("Vision")
        }
        guard width > 0,
              height > 0,
              width <= Int.max / bytesPerPixel,
              rowBytes >= width * bytesPerPixel,
              height <= Int.max / rowBytes,
              CVPixelBufferGetDataSize(buffer) >= rowBytes * height else {
            throw SubjectIsolationAcquisitionError.misalignedMask("Vision")
        }
        var result: [UInt8] = []
        result.reserveCapacity(width * height)
        for row in 0..<height {
            let rowPointer = base.advanced(by: row * rowBytes)
            for column in 0..<width {
                let pointer = rowPointer.advanced(by: column * bytesPerPixel)
                result.append(try foreground(pointer) ? 255 : 0)
            }
        }
        return result
    }

    private struct PreparedView: @unchecked Sendable {
        let view: SubjectIsolationAnalysisView
        let image: CGImage
        let imageSHA256: String
    }

    private final class CreatedMaskTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL] = []

        func insert(_ url: URL) {
            lock.lock()
            values.append(url)
            lock.unlock()
        }

        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }
}

enum SubjectIsolationAcquisitionError: Error, Equatable {
    case unreadableImage(String)
    case misalignedMask(String)
    case tooManyInstances
    case destinationExists(String)
    case incompleteResult(Int)
}

private func checkCancellation(_ shouldCancel: () -> Bool) throws {
    if shouldCancel() { throw CancellationError() }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func writeGrayscalePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let bytes = Data(pixels)
    guard let provider = CGDataProvider(data: bytes as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw SubjectIsolationAcquisitionError.misalignedMask("PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SubjectIsolationAcquisitionError.misalignedMask("PNG")
    }
}
