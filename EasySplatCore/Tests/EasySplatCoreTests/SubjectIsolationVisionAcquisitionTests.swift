import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class SubjectIsolationVisionAcquisitionTests: XCTestCase {
    func testBinaryAndTextCOLMAPPoseDecodingProduceSameCentersAndIdentities() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("binary", isDirectory: true)
        let text = root.appendingPathComponent("text", isDirectory: true)
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: text, withIntermediateDirectories: true)
        let records = [
            PoseFixture(id: 8, name: "z.png", translation: (1, 0, 0)),
            PoseFixture(id: 3, name: "a.png", translation: (0, 2, 0)),
        ]
        try writeBinaryPoses(records, to: binary.appendingPathComponent("images.bin"))
        try writeTextPoses(records, to: text.appendingPathComponent("images.txt"))

        XCTAssertEqual(
            try SubjectIsolationColmapPoseReader.read(sparseDirectory: binary),
            try SubjectIsolationColmapPoseReader.read(sparseDirectory: text)
        )
        XCTAssertEqual(
            try SubjectIsolationColmapPoseReader.read(sparseDirectory: binary).map(\.imageIdentity),
            ["a.png", "z.png"]
        )
    }

    func testFarthestPoseSamplingUsesFilenameTieBreakAndNativeFilenameOrder() {
        let poses = [
            makePose("z.png", 3, 1, 0, 0),
            makePose("a.png", 0, 0, 0, 0),
            makePose("b.png", 1, -1, 0, 0),
            makePose("c.png", 2, 1, 0, 0),
        ]

        let sampled = SubjectIsolationViewSampler.sample(poses, maximumCount: 3)

        XCTAssertEqual(sampled.map(\.imageIdentity), ["b.png", "c.png", "a.png"])
        XCTAssertEqual(sampled.map(\.nativeCameraIndex), [1, 2, 0])
    }

    func testProgressiveRolesHaveExactCountsAndNeverChangeEarlierRoles() {
        let poses = (0..<24).map { index in
            makePose(String(format: "%02d.png", index), index, Double(index), 0, 0)
        }
        let stages = SubjectIsolationViewSampler.progressiveStages(
            for: SubjectIsolationViewSampler.sample(poses, maximumCount: 24)
        )

        XCTAssertEqual(stages.map(\.workViews).map(\.count), [8, 14, 18])
        XCTAssertEqual(stages.map(\.heldOutViews).map(\.count), [2, 4, 6])
        XCTAssertEqual(stages[0].heldOutViews.map(\.samplePosition), [4, 9])
        XCTAssertEqual(stages[1].heldOutViews.map(\.samplePosition), [4, 9, 13, 17])
        XCTAssertEqual(stages[2].heldOutViews.map(\.samplePosition), [4, 9, 13, 17, 20, 23])
        for earlier in stages.dropLast() {
            let next = stages[stages.firstIndex(of: earlier)! + 1]
            XCTAssertTrue(Set(earlier.heldOutViews).isSubset(of: Set(next.heldOutViews)))
            XCTAssertTrue(Set(earlier.workViews).isSubset(of: Set(next.workViews)))
        }
    }

    func testAcquisitionCapsRequestsAtTwoAndReturnsInputOrder() async throws {
        let fixture = try makeAcquisitionFixture(names: ["c.png", "a.png", "b.png"])
        defer { fixture.cleanup() }
        let gauge = ConcurrencyGauge()
        let acquirer = SubjectIsolationVisionMaskAcquirer { image in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(30))
            await gauge.leave()
            return [SubjectIsolationBinaryMask(sourceInstanceID: 99, width: image.width, height: image.height, pixels: Array(repeating: 255, count: image.width * image.height))]
        }

        let masks = try await acquirer.acquire(views: fixture.views, stagingDirectory: fixture.staging)

        XCTAssertEqual(masks.map(\.imageIdentity), ["c.png", "a.png", "b.png"])
        let maximum = await gauge.maximum
        XCTAssertLessThanOrEqual(maximum, 2)
    }

    func testBlankObservationWritesFullResolutionZeroPNGAndMetadataMatchesBytes() async throws {
        let fixture = try makeAcquisitionFixture(names: ["blank.png"], size: 3)
        defer { fixture.cleanup() }
        let masks = try await SubjectIsolationVisionMaskAcquirer(request: { _ in [] }).acquire(
            views: fixture.views,
            stagingDirectory: fixture.staging
        )
        let mask = try XCTUnwrap(masks.first)

        XCTAssertEqual(mask.pixelWidth, 3)
        XCTAssertEqual(mask.pixelHeight, 3)
        XCTAssertEqual(mask.instanceLabels, [])
        XCTAssertEqual(try grayscalePixels(at: mask.fileURL), Array(repeating: 0, count: 9))
        XCTAssertEqual(mask.imageSHA256, sha256(try Data(contentsOf: fixture.views[0].imageURL)))
        XCTAssertEqual(mask.maskSHA256, sha256(try Data(contentsOf: mask.fileURL)))
    }

    func testFrameLocalSourceIDsDoNotEscapeIntoOutputLabels() async throws {
        let fixture = try makeAcquisitionFixture(names: ["one.png", "two.png"], size: 2)
        defer { fixture.cleanup() }
        let calls = CallCounter()
        let acquirer = SubjectIsolationVisionMaskAcquirer { image in
            let left = [UInt8(255), 0, 255, 0]
            let right = [UInt8(0), 255, 0, 255]
            let ids = await calls.next() == 0 ? [42, 8] : [9, 201]
            return [
                SubjectIsolationBinaryMask(sourceInstanceID: ids[0], width: 2, height: 2, pixels: left),
                SubjectIsolationBinaryMask(sourceInstanceID: ids[1], width: 2, height: 2, pixels: right),
            ]
        }

        let masks = try await acquirer.acquire(views: fixture.views, stagingDirectory: fixture.staging)

        XCTAssertEqual(masks.map(\.instanceLabels), [[1, 2], [1, 2]])
        XCTAssertTrue(masks.allSatisfy { !$0.instanceLabels.contains(8) && !$0.instanceLabels.contains(42) })
    }

    func testOverlappingMasksKeepLowerOutputLabel() async throws {
        let fixture = try makeAcquisitionFixture(names: ["overlap.png"], size: 2)
        defer { fixture.cleanup() }
        let acquirer = SubjectIsolationVisionMaskAcquirer { _ in
            [
                SubjectIsolationBinaryMask(sourceInstanceID: 4, width: 2, height: 2, pixels: [255, 255, 0, 0]),
                SubjectIsolationBinaryMask(sourceInstanceID: 9, width: 2, height: 2, pixels: [0, 255, 255, 0]),
            ]
        }

        let acquired = try await acquirer.acquire(views: fixture.views, stagingDirectory: fixture.staging)
        let mask = try XCTUnwrap(acquired.first)

        XCTAssertEqual(try grayscalePixels(at: mask.fileURL), [1, 1, 2, 0])
        XCTAssertEqual(mask.instanceLabels, [1, 2])
    }

    func testPixelBufferConversionSupportsPaddedFloatAndEightBitInstanceMasks() throws {
        let floatBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_OneComponent32Float,
            width: 2,
            height: 2,
            bytesPerRow: 16
        ) { storage, row, column in
            let values: [[Float]] = [[0.49, 0.5], [1, 0]]
            let offset = row * 16 + column * MemoryLayout<Float>.size
            storage.withUnsafeMutableBytes {
                $0.baseAddress!.advanced(by: offset).storeBytes(of: values[row][column], as: Float.self)
            }
        }
        XCTAssertEqual(
            try SubjectIsolationVisionMaskAcquirer.pixels(from: floatBuffer.buffer),
            [0, 255, 255, 0]
        )

        let eightBitBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_OneComponent8,
            width: 2,
            height: 2,
            bytesPerRow: 8
        ) { storage, row, column in
            let values: [[UInt8]] = [[0, 127], [128, 255]]
            storage[row * 8 + column] = values[row][column]
        }
        XCTAssertEqual(
            try SubjectIsolationVisionMaskAcquirer.pixels(from: eightBitBuffer.buffer),
            [0, 0, 255, 255]
        )
    }

    func testPixelBufferConversionRejectsUnsupportedFormat() throws {
        let buffer = try makePixelBuffer(
            format: kCVPixelFormatType_32BGRA,
            width: 1,
            height: 1,
            bytesPerRow: 4
        ) { _, _, _ in }

        XCTAssertThrowsError(try SubjectIsolationVisionMaskAcquirer.pixels(from: buffer.buffer)) {
            XCTAssertEqual($0 as? SubjectIsolationAcquisitionError, .misalignedMask("Vision"))
        }
    }

    func testCancellationRemovesOnlyMasksCreatedByThisAcquisition() async throws {
        let fixture = try makeAcquisitionFixture(names: ["first.png"])
        defer { fixture.cleanup() }
        let unrelated = fixture.staging.appendingPathComponent("keep.png")
        try Data("keep".utf8).write(to: unrelated)
        let cancellation = CancellationSwitch(cancelAfter: 7)
        let acquirer = SubjectIsolationVisionMaskAcquirer(request: { image in
            [SubjectIsolationBinaryMask(sourceInstanceID: 1, width: image.width, height: image.height, pixels: Array(repeating: 255, count: image.width * image.height))]
        })

        do {
            _ = try await acquirer.acquire(
                views: fixture.views,
                stagingDirectory: fixture.staging,
                shouldCancel: { cancellation.shouldCancel() }
            )
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            XCTAssertEqual(cancellation.callCount, 8)
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), ["keep.png"])
        }
    }
}

private struct PoseFixture {
    let id: UInt32
    let name: String
    let translation: (Double, Double, Double)
}

private func writeBinaryPoses(_ poses: [PoseFixture], to url: URL) throws {
    var data = Data()
    append(UInt64(poses.count), to: &data)
    for pose in poses {
        append(pose.id, to: &data)
        for value in [1.0, 0.0, 0.0, 0.0, pose.translation.0, pose.translation.1, pose.translation.2] {
            append(value, to: &data)
        }
        append(UInt32(1), to: &data)
        data.append(contentsOf: pose.name.utf8)
        data.append(0)
        append(UInt64(0), to: &data)
    }
    try data.write(to: url)
}

private func writeTextPoses(_ poses: [PoseFixture], to url: URL) throws {
    let content = poses.map { pose in
        "\(pose.id) 1 0 0 0 \(pose.translation.0) \(pose.translation.1) \(pose.translation.2) 1 \(pose.name)\n\n"
    }.joined()
    try content.write(to: url, atomically: true, encoding: .utf8)
}

private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func append(_ value: Double, to data: inout Data) {
    append(value.bitPattern, to: &data)
}

private func makePose(_ name: String, _ nativeIndex: Int, _ x: Double, _ y: Double, _ z: Double) -> SubjectIsolationCameraPose {
    SubjectIsolationCameraPose(
        imageIdentity: name,
        nativeCameraIndex: nativeIndex,
        center: SIMD3(x, y, z)
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func grayscalePixels(at url: URL) throws -> [UInt8] {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { throw NSError(domain: "SubjectIsolationVisionAcquisitionTests", code: 1) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
}

private func makePixelBuffer(
    format: OSType,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    fill: (inout [UInt8], Int, Int) -> Void
) throws -> (buffer: CVPixelBuffer, storage: [UInt8]) {
    var storage = [UInt8](repeating: 0xEE, count: bytesPerRow * height)
    for row in 0..<height {
        for column in 0..<width { fill(&storage, row, column) }
    }
    var buffer: CVPixelBuffer?
    let result = storage.withUnsafeMutableBytes {
        CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            format,
            $0.baseAddress!,
            bytesPerRow,
            nil,
            nil,
            nil,
            &buffer
        )
    }
    guard result == kCVReturnSuccess, let buffer else {
        throw NSError(domain: "SubjectIsolationVisionAcquisitionTests", code: Int(result))
    }
    return (buffer, storage)
}

private struct AcquisitionFixture {
    let root: URL
    let staging: URL
    let views: [SubjectIsolationAnalysisView]

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func makeAcquisitionFixture(names: [String], size: Int = 2) throws -> AcquisitionFixture {
    let root = try TestFileBuilder.makeTempDir()
    let images = root.appendingPathComponent("images", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let views = try names.enumerated().map { index, name -> SubjectIsolationAnalysisView in
        let url = images.appendingPathComponent(name)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(url: url, size: size, value: UInt8(index), utType: .png))
        return SubjectIsolationAnalysisView(imageIdentity: name, imageURL: url, nativeCameraIndex: index)
    }
    return AcquisitionFixture(root: root, staging: staging, views: views)
}

private actor ConcurrencyGauge {
    private var current = 0
    private(set) var maximum = 0

    func enter() {
        current += 1
        maximum = max(maximum, current)
    }

    func leave() { current -= 1 }
}

private actor CallCounter {
    private var value = 0

    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

private final class CancellationSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfter: Int
    private var remaining: Int

    init(cancelAfter: Int) {
        self.cancelAfter = cancelAfter
        remaining = cancelAfter
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        remaining -= 1
        return remaining < 0
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelAfter - remaining
    }
}
