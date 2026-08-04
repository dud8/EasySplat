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

extension SplatExportTests {
    /// The user-selected path cannot open the destination's directory, so it has
    /// to produce the same bytes through the system's replace primitive.
    func testUserSelectedPublicationMatchesTheProjectOwnedResult() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)

        let owned = root.appendingPathComponent("owned.ply")
        let chosen = root.appendingPathComponent("chosen.ply")
        let ownedEvidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: owned
        )
        let chosenEvidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: chosen,
            destinationKind: .userSelected
        )

        XCTAssertEqual(ownedEvidence, chosenEvidence)
        XCTAssertEqual(try Data(contentsOf: owned), try Data(contentsOf: chosen))
    }

    func testUserSelectedPublicationReplacesAnExistingFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("existing.ply")
        try Data("stale bytes that are not a ply".utf8).write(to: destination)

        _ = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: destination,
            destinationKind: .userSelected
        )

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }
}
