import XCTest
@testable import EasySplatCore

final class ToolLogWriterTests: XCTestCase {
    func testWritesSectionsAndStripsAnsi() throws {
        let dir = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("tool.log")

        let writer = ToolLogWriter(fileURL: logURL, toolName: "tool")
        writer.beginSection(title: "start", metadata: ["b": "2", "a": "1"])
        writer.append(stream: "stdout", line: "\u{001B}[31mhello\u{001B}[0m")
        writer.append(stream: "stdout", line: "hello")
        writer.append(stream: "stderr", line: "error")

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("tool start"))
        XCTAssertTrue(text.contains("a: 1"))
        XCTAssertTrue(text.contains("b: 2"))
        XCTAssertTrue(text.contains("[stdout] hello"))
        XCTAssertTrue(text.contains("[stderr] error"))
        XCTAssertFalse(text.contains("\u{001B}"))
    }

    func testDeduplicatesSameLinePerStream() throws {
        let dir = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("tool.log")

        let writer = ToolLogWriter(fileURL: logURL, toolName: "tool")
        writer.append(stream: "stdout", line: "dup")
        writer.append(stream: "stdout", line: "dup")
        writer.append(stream: "stdout", line: "dup")

        let text = try String(contentsOf: logURL, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.contains("dup") }
        XCTAssertEqual(lines.count, 1)
    }
}
