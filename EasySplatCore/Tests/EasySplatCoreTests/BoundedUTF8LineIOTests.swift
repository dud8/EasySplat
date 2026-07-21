import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class BoundedUTF8LineIOTests: XCTestCase {
    func testWriterAndReaderPreserveLineTerminatorsAcrossSmallBuffers() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("model.txt")
        let expected = [
            BoundedUTF8LineReader.Line(number: 1, text: "alpha", terminator: .lf),
            BoundedUTF8LineReader.Line(number: 2, text: "béta", terminator: .crlf),
            BoundedUTF8LineReader.Line(number: 3, text: "omega", terminator: .endOfFile),
        ]

        let writer = try BufferedUTF8LineWriter(at: output, capacity: 3)
        for line in expected {
            try writer.write(line)
        }
        try writer.finish()

        XCTAssertEqual(
            try Data(contentsOf: output),
            Data("alpha\nbéta\r\nomega".utf8)
        )

        let reader = try BoundedUTF8LineReader(
            at: output,
            maximumBytes: 64,
            maximumLineBytes: 16,
            readChunkBytes: 2
        )
        for line in expected {
            XCTAssertEqual(try reader.next(), line)
        }
        XCTAssertNil(try reader.next())
    }

    func testWriterReplacesSelectedTokensWithoutChangingSpacing() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("model.txt")
        let text = "1   9 image name.jpg"
        let first = try XCTUnwrap(text.range(of: "1"))
        let second = try XCTUnwrap(text.range(of: "9"))

        let writer = try BufferedUTF8LineWriter(at: output, capacity: 4)
        try writer.write(
            text: text,
            tokenRanges: [first, second],
            replacements: [0: "12", 1: "42"],
            terminator: .crlf
        )
        try writer.write(fragment: "tail")
        try writer.write(.endOfFile)
        try writer.finish()

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "12   42 image name.jpg\r\ntail"
        )
    }

    func testWriterRefusesToReplaceAnExistingPath() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("model.txt")
        try Data("existing".utf8).write(to: output)

        XCTAssertThrowsError(try BufferedUTF8LineWriter(at: output)) { error in
            XCTAssertEqual(
                error as? BufferedUTF8LineWriter.Error,
                .cannotCreate("model.txt", EEXIST)
            )
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("existing".utf8))
    }

    func testWriterDetectsPathReplacementAndPreservesReplacement() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("model.txt")
        let writer = try BufferedUTF8LineWriter(at: output, capacity: 4)
        try writer.write(fragment: "original")

        try FileManager.default.removeItem(at: output)
        try Data("replacement".utf8).write(to: output)

        XCTAssertThrowsError(try writer.finish()) { error in
            XCTAssertEqual(
                error as? BufferedUTF8LineWriter.Error,
                .changedDuringWrite("model.txt")
            )
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("replacement".utf8))
    }

    func testWriterFinishIsIdempotentAndRejectsFurtherWrites() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("model.txt")
        let writer = try BufferedUTF8LineWriter(at: output)
        try writer.write(fragment: "done")
        try writer.finish()
        try writer.finish()

        XCTAssertThrowsError(try writer.write(fragment: "again")) { error in
            XCTAssertEqual(error as? BufferedUTF8LineWriter.Error, .alreadyFinished)
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("done".utf8))
    }

    func testWriterRejectsInvalidBufferCapacity() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("model.txt")

        XCTAssertThrowsError(try BufferedUTF8LineWriter(at: output, capacity: 0)) { error in
            XCTAssertEqual(error as? BufferedUTF8LineWriter.Error, .invalidCapacity)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testReaderDetectsPathReplacementBeforeReportingEndOfFile() throws {
        let root = try makeTemporaryDirectory()
        let input = root.appendingPathComponent("model.txt")
        try Data("line\n".utf8).write(to: input)
        let reader = try BoundedUTF8LineReader(
            at: input,
            maximumBytes: 16,
            maximumLineBytes: 16,
            readChunkBytes: 2
        )

        XCTAssertEqual(
            try reader.next(),
            BoundedUTF8LineReader.Line(number: 1, text: "line", terminator: .lf)
        )
        try FileManager.default.removeItem(at: input)
        try Data("other\n".utf8).write(to: input)

        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertEqual(
                error as? BoundedUTF8LineReader.Error,
                .changedDuringRead("model.txt")
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
