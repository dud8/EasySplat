#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class BufferedByteStreamWriterTests: XCTestCase {
    func testWriterWritesAllBytes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let expected = (0..<200_000).map { UInt8($0 % 251) }
        let stream = AsyncStream<UInt8> { continuation in
            for b in expected {
                continuation.yield(b)
            }
            continuation.finish()
        }

        let destination = dir.appendingPathComponent("out.bin")
        let writer = BufferedByteStreamWriter(fileManager: .default)
        try await writer.write(bytes: stream, to: destination, expectedLength: Int64(expected.count), onProgress: { _, _ in })

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(Array(data), expected)
    }

    func testWriterDeletesPartialFileOnThrow() async {
        enum TestError: Error { case boom }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for i in 0..<1024 {
                continuation.yield(UInt8(i % 251))
            }
            continuation.finish(throwing: TestError.boom)
        }

        let destination = dir.appendingPathComponent("partial.bin")
        let writer = BufferedByteStreamWriter(fileManager: .default)

        do {
            try await writer.write(bytes: stream, to: destination, expectedLength: 2048, onProgress: { _, _ in })
            XCTFail("Expected write to throw")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
#endif

