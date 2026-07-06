import XCTest
@testable import EasySplatCore

final class ProjectArtifactValidatorTests: XCTestCase {
    func testValidatePlyRejectsCorruptOutputs() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = root.appendingPathComponent("empty.ply")
        TestFileBuilder.createFile(at: empty)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: empty), .corrupt(reason: "empty.ply is empty"))

        let headerOnly = root.appendingPathComponent("header-only.ply")
        try """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        """.write(to: headerOnly, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: headerOnly), .corrupt(reason: "header-only.ply has no vertex data"))

        let zeroVertex = root.appendingPathComponent("zero.ply")
        try """
        ply
        format ascii 1.0
        element vertex 0
        end_header
        """.write(to: zeroVertex, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: zeroVertex), .corrupt(reason: "zero.ply has invalid vertex count"))
    }

    func testValidatePlyRejectsXYZOnlyPointCloud() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let xyzOnly = root.appendingPathComponent("xyz-only.ply")
        try TestFileBuilder.writeXYZOnlyPly(at: xyzOnly)

        XCTAssertEqual(
            ProjectArtifactValidator.validatePlyFile(at: xyzOnly),
            .corrupt(reason: "xyz-only.ply is missing Gaussian splat property f_dc_0")
        )
    }

    func testValidatePlyRejectsAsciiVertexCountShortage() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let truncated = root.appendingPathComponent("truncated-ascii.ply")
        try """
        ply
        format ascii 1.0
        element vertex 2
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """.write(to: truncated, atomically: true, encoding: .utf8)

        guard case .corrupt(let reason) = ProjectArtifactValidator.validatePlyFile(at: truncated) else {
            return XCTFail("Expected truncated ASCII PLY to be corrupt")
        }
        XCTAssertTrue(reason.contains("expected 2 vertices"))
    }

    func testValidatePlyAcceptsLargeAsciiBodyBeyondHeaderRead() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("large-ascii.ply")
        try TestFileBuilder.writeMinimalPly(at: large, vertexCount: 7_000)

        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: large), .valid)
    }

    func testReadPlyHeaderReturnsVertexCountAndFormat() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("good.ply")
        try TestFileBuilder.writeMinimalPly(at: output, vertexCount: 12_345)
        let info = try XCTUnwrap(ProjectArtifactValidator.readPlyHeader(at: output))
        XCTAssertEqual(info.vertexCount, 12_345)
        XCTAssertEqual(info.format, "ascii")
    }

    func testReadPlyHeaderReturnsNilForMissingFile() {
        let info = ProjectArtifactValidator.readPlyHeader(
            at: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).ply")
        )
        XCTAssertNil(info)
    }

    func testValidatePlyIgnoresEndHeaderMentionInsideComment() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("comment-marker.ply")
        try """
        ply
        format ascii 1.0
        comment this note says end_header but is still part of the header
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """.write(to: output, atomically: true, encoding: .utf8)

        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
    }

    func testValidatePlyRejectsBinaryBodyShortage() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let truncated = root.appendingPathComponent("truncated-binary.ply")
        var data = Data("""
        ply
        format binary_little_endian 1.0
        element vertex 2
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        """.utf8)
        data.append(0x0a)
        data.append(Data(repeating: 0, count: 43))
        try data.write(to: truncated, options: [.atomic])

        guard case .corrupt(let reason) = ProjectArtifactValidator.validatePlyFile(at: truncated) else {
            return XCTFail("Expected truncated binary PLY to be corrupt")
        }
        XCTAssertTrue(reason.contains("expected at least"), reason)
    }

    func testValidatePlyRejectsBinaryVertexByteOverflow() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = root.appendingPathComponent("oversized-binary.ply")
        var data = Data("""
        ply
        format binary_little_endian 1.0
        element vertex 9223372036854775807
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        """.utf8)
        data.append(0x0a)
        data.append(0)
        try data.write(to: oversized, options: [.atomic])

        guard case .corrupt(let reason) = ProjectArtifactValidator.validatePlyFile(at: oversized) else {
            return XCTFail("Expected oversized binary PLY to be corrupt")
        }
        XCTAssertTrue(reason.contains("vertex byte count is too large"), reason)
    }

    func testValidatePlyRejectsNonNumericAsciiVertexRows() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("bad-ascii.ply")
        try """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        bad 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """.write(to: invalid, atomically: true, encoding: .utf8)

        guard case .corrupt(let reason) = ProjectArtifactValidator.validatePlyFile(at: invalid) else {
            return XCTFail("Expected non-numeric ASCII PLY to be corrupt")
        }
        XCTAssertTrue(reason.contains("invalid vertex value"))
    }

    func testValidatePlyRejectsNonFiniteAsciiVertexRows() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("bad-ascii-nan.ply")
        try """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        nan 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """.write(to: invalid, atomically: true, encoding: .utf8)

        guard case .corrupt(let reason) = ProjectArtifactValidator.validatePlyFile(at: invalid) else {
            return XCTFail("Expected non-finite ASCII PLY to be corrupt")
        }
        XCTAssertTrue(reason.contains("invalid vertex value"))
    }

    func testValidatePlyRejectsSplatFieldsOutsideVertexElement() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let spoofed = root.appendingPathComponent("face-fields.ply")
        try """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        element face 1
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0
        1 2 3
        """.write(to: spoofed, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ProjectArtifactValidator.validatePlyFile(at: spoofed),
            .corrupt(reason: "face-fields.ply is missing Gaussian splat property f_dc_0")
        )
    }

    func testResolveAndValidateOutputRejectsSymlinkEscape() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let externalPly = outside.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: externalPly)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.removeItem(at: paths.outputURL)
        try FileManager.default.createSymbolicLink(at: paths.outputURL, withDestinationURL: outside)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.resolveValidatedOutputPly(paths: paths, relativePath: "Output/splat.ply")
        ) { error in
            guard case ProjectPathError.escapesProjectRoot = error else {
                return XCTFail("Expected project root escape, got \(error)")
            }
        }
    }

    func testResolveAndValidateOutputRejectsEscapingPath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.resolveValidatedOutputPly(paths: paths, relativePath: "../outside.ply")
        )
    }

    func testResolveAndValidateOutputAcceptsGoodPly() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output)

        let resolved = try ProjectArtifactValidator.resolveValidatedOutputPly(
            paths: paths,
            relativePath: "Output/splat.ply"
        )

        XCTAssertEqual(resolved.standardizedFileURL, output.standardizedFileURL)
    }
}
