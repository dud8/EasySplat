import XCTest
@testable import EasySplatCore

final class SplatExportTests: XCTestCase {
    func testCopyIfExistsPreservesExistingOutputWhenSourceCopyFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: destination)
        let before = try Data(contentsOf: destination)

        XCTAssertThrowsError(
            try SplatExport.copyIfExists(from: root.appendingPathComponent("missing.ply"), to: destination)
        )

        XCTAssertEqual(try Data(contentsOf: destination), before)
    }

    func testCopyIfExistsReplacesOutputAtomicallyAfterSuccessfulCopy() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("export_00002.ply")
        let destination = root.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)

        try SplatExport.copyIfExists(from: source, to: destination)

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.contains("element vertex 2"))
    }

    func testCopyIfExistsPreservesExistingOutputWhenSourceIsCorrupt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("corrupt.ply")
        let destination = root.appendingPathComponent("splat.ply")
        try Data("ply\nformat ascii 1.0\n".utf8).write(to: source)
        try TestFileBuilder.writeMinimalPly(at: destination)
        let before = try Data(contentsOf: destination)

        XCTAssertThrowsError(try SplatExport.copyIfExists(from: source, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination), before)
    }
}
